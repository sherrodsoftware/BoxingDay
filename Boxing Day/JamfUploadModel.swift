import Foundation
import Observation

/// One step in the upload sheet's Jamf Activity list. Each step has a stable
/// ID and its own state, so its row doesn't depend on where it sits in the list.
struct UploadActivity: Identifiable, Equatable {
    enum State: Equatable {
        case inProgress, done, failed, cancelled
    }

    let id: Int
    let message: String
    var state: State
}

/// The upload sheet's state: the Jamf package record fields, the saved
/// connection, categories, and the upload's progress and outcome.
@MainActor
@Observable
final class JamfUploadModel {
    let packageURL: URL

    // Jamf package record fields, edited in the sheet.
    var packageName: String
    var fileName: String
    var categoryID = JamfCategory.noCategory.id
    var priority = 10
    var notes = ""

    private(set) var categories = [JamfCategory.noCategory]
    private(set) var isLoadingCategories = false
    private(set) var categoryError: String?

    private(set) var configuration: JamfConfiguration?
    private(set) var clientSecret = ""
    private(set) var configurationError: String?

    private(set) var isUploading = false
    private(set) var uploadStage: JamfUploadStage = .checkingForDuplicate
    private(set) var uploadProgress = 0.0
    private(set) var uploadResult: JamfPackageUploadResult?
    private(set) var uploadError: String?
    private(set) var uploadWasCancelled = false
    /// A filename that now has a Jamf Pro package record from an
    /// unfinished upload. Uploading it again would fail the duplicate check.
    private(set) var fileNameInUse: String?
    private(set) var activity: [UploadActivity] = []
    /// Never reused, so a second upload's steps get new identities.
    private var nextActivityID = 0
    private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private let store: JamfSettingsStore

    init(
        packageURL: URL,
        suggestedFileName: String? = nil,
        store: JamfSettingsStore = LiveJamfSettingsStore()
    ) {
        self.packageURL = packageURL
        self.store = store
        let initialFileName = suggestedFileName ?? packageURL.lastPathComponent
        fileName = initialFileName
        packageName = (initialFileName as NSString).deletingPathExtension
    }

    var options: JamfPackageUploadOptions {
        JamfPackageUploadOptions(
            packageName: packageName,
            fileName: fileName,
            categoryID: categoryID,
            priority: priority,
            notes: notes
        )
    }

    /// Whether the record fields can still be edited.
    var isEditable: Bool {
        !isUploading && uploadResult == nil
    }

    var canUpload: Bool {
        configuration != nil
            && !clientSecret.isEmpty
            && !isLoadingCategories
            && categoryError == nil
            && options.validationError == nil
            && isEditable
            && fileNameInUse != fileName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }

    var stageDescription: String {
        switch uploadStage {
        case .authenticating:
            return "Authenticating with Jamf Pro…"
        case .checkingForDuplicate:
            return "Checking for an existing filename…"
        case .creatingRecord:
            return "Creating the Jamf package record…"
        case .preparingUpload:
            return "Preparing the package upload…"
        case .uploading:
            return "Uploading \(fileName)…"
        case .refreshingAuthentication:
            return "Renewing the Jamf Pro connection…"
        case .processingCloud(let status):
            if let status, !status.isEmpty {
                return "Jamf cloud processing: \(status)"
            }
            return "Waiting for Jamf cloud processing…"
        }
    }

    // MARK: - Connection and categories

    func loadConnection() {
        do {
            let saved = store.loadSettings()
            let loadedConfiguration = try JamfConfiguration(
                serverURL: saved.serverURL,
                clientID: saved.clientID
            ).validated()
            guard let loadedSecret = try store.loadClientSecret(),
                  !loadedSecret.isEmpty else {
                throw JamfConfigurationError.missingClientSecret
            }
            useConnection(loadedConfiguration, clientSecret: loadedSecret)
            loadCategories()
        } catch {
            configuration = nil
            clientSecret = ""
            configurationError = """
            Configure and test a Jamf Pro connection before uploading. \
            \(error.localizedDescription)
            """
        }
    }

    /// Uses a connection without reading Settings or the Keychain.
    func useConnection(_ configuration: JamfConfiguration, clientSecret: String) {
        self.configuration = configuration
        self.clientSecret = clientSecret
        configurationError = nil
    }

    /// Forgets the client secret once the sheet closes.
    func forgetSecret() {
        clientSecret = ""
    }

    func loadCategories() {
        guard let configuration, !clientSecret.isEmpty else { return }

        isLoadingCategories = true
        categoryError = nil
        Task {
            do {
                let loaded = try await JamfClient(
                    configuration: configuration,
                    clientSecret: clientSecret
                ).categories()
                let allCategories = [JamfCategory.noCategory] + loaded
                let preferred = JamfPreferences.preferredCategory(
                    in: allCategories,
                    saved: store.loadSettings()
                )

                categories = allCategories
                categoryID = preferred?.id ?? JamfCategory.noCategory.id
                categoryError = nil
            } catch {
                categories = [JamfCategory.noCategory]
                categoryID = JamfCategory.noCategory.id
                categoryError = """
                Boxing Day could not load categories from Jamf Pro. \
                \(error.localizedDescription)
                """
            }
            isLoadingCategories = false
        }
    }

    // MARK: - Upload

    func startUpload() {
        guard let configuration, canUpload else { return }

        isUploading = true
        uploadError = nil
        uploadWasCancelled = false
        uploadResult = nil
        uploadProgress = 0
        uploadStage = .authenticating
        activity = []

        let options = options
        uploadTask = Task {
            do {
                let result = try await JamfClient(
                    configuration: configuration,
                    clientSecret: clientSecret
                ).uploadPackage(
                    at: packageURL,
                    options: options,
                    stageChanged: { stage in
                        self.recordActivity(for: stage)
                    },
                    progressChanged: { progress in
                        self.uploadProgress = progress
                    }
                )
                recordSuccess(result)
            } catch {
                applyFailure(error, cancelled: Task.isCancelled, fileName: options.fileName)
            }
            isUploading = false
            uploadTask = nil
        }
    }

    /// Stops the upload. The sheet stays open so the user can see what state
    /// Jamf Pro was left in.
    func cancelUpload() {
        uploadTask?.cancel()
    }

    /// Records a new upload stage as the step in progress, finishing the
    /// step before it. A repeated stage, such as cloud polling, adds nothing.
    func recordActivity(for stage: JamfUploadStage) {
        uploadStage = stage
        let message = stageDescription
            .replacingOccurrences(of: "…", with: "")
        guard activity.last?.message != message else { return }
        appendActivity(message, state: .inProgress)
    }

    func recordSuccess(_ result: JamfPackageUploadResult) {
        uploadResult = result
        appendActivity(
            "Jamf Pro reported the package \(result.cloudTransferStatus.lowercased()).",
            state: .done
        )
    }

    /// Marks earlier steps as done and appends a step.
    private func appendActivity(_ message: String, state: UploadActivity.State) {
        for index in activity.indices where activity[index].state == .inProgress {
            activity[index].state = .done
        }
        activity.append(UploadActivity(id: nextActivityID, message: message, state: state))
        nextActivityID += 1
    }

    /// Records a failed or cancelled upload.
    func applyFailure(_ error: Error, cancelled: Bool, fileName: String) {
        let outcome = Self.failureOutcome(for: error, cancelled: cancelled)
        uploadWasCancelled = cancelled
        uploadError = outcome.message
        if outcome.blocksFileName {
            fileNameInUse = fileName
        }
        appendActivity(
            cancelled ? "Upload cancelled" : "Boxing Day encountered an error.",
            state: cancelled ? .cancelled : .failed
        )
    }

    struct FailureOutcome: Equatable {
        let message: String
        /// True when Jamf Pro now has a package record with this filename.
        let blocksFileName: Bool
    }

    nonisolated static func failureOutcome(
        for error: Error,
        cancelled: Bool
    ) -> FailureOutcome {
        let clientError = error as? JamfClientError
        guard cancelled else {
            switch clientError {
            case .packageRecordCreated, .packageUploadedStatusUnknown:
                return FailureOutcome(message: error.localizedDescription, blocksFileName: true)
            default:
                return FailureOutcome(message: error.localizedDescription, blocksFileName: false)
            }
        }

        switch clientError {
        case .packageRecordCreated(let packageID, _):
            return FailureOutcome(
                message: """
                Upload cancelled. Jamf Pro package record \(packageID) was \
                created without a file. Delete it in Jamf Pro, or choose a \
                different filename, before uploading again.
                """,
                blocksFileName: true
            )
        case .packageUploadedStatusUnknown(let packageID, _):
            return FailureOutcome(
                message: """
                Stopped waiting for Jamf Pro. The file was already uploaded \
                as package ID \(packageID); check its status in Jamf Pro.
                """,
                blocksFileName: true
            )
        default:
            return FailureOutcome(
                message: "Upload cancelled. Nothing was added to Jamf Pro.",
                blocksFileName: false
            )
        }
    }
}
