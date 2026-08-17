import SwiftUI

struct JamfUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    let packageURL: URL

    @State private var packageName: String
    @State private var fileName: String
    @State private var categoryID = "-1"
    @State private var categories = [JamfCategory.noCategory]
    @State private var isLoadingCategories = false
    @State private var categoryError: String?
    @State private var priority = 10
    @State private var notes = ""

    @State private var configuration: JamfConfiguration?
    @State private var clientSecret = ""
    @State private var configurationError: String?
    @State private var isUploading = false
    @State private var uploadStage: JamfUploadStage = .checkingForDuplicate
    @State private var uploadProgress = 0.0
    @State private var uploadResult: JamfPackageUploadResult?
    @State private var uploadError: String?
    @State private var activityMessages: [String] = []

    init(packageURL: URL, suggestedFileName: String? = nil) {
        self.packageURL = packageURL
        let initialFileName = suggestedFileName ?? packageURL.lastPathComponent
        let initialName = (initialFileName as NSString).deletingPathExtension
        _packageName = State(initialValue: initialName)
        _fileName = State(initialValue: initialFileName)
    }

    private var options: JamfPackageUploadOptions {
        JamfPackageUploadOptions(
            packageName: packageName,
            fileName: fileName,
            categoryID: categoryID,
            priority: priority,
            notes: notes
        )
    }

    private var canUpload: Bool {
        configuration != nil
            && !clientSecret.isEmpty
            && !isLoadingCategories
            && categoryError == nil
            && options.validationError == nil
            && !isUploading
            && uploadResult == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Upload to Jamf Pro")
                        .font(.title2)
                        .bold()
                    Text(packageURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(packageURL.path)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Jamf Package Record") {
                    TextField("Package name", text: $packageName)
                        .disabled(isUploading || uploadResult != nil)
                    TextField("Filename", text: $fileName)
                        .disabled(isUploading || uploadResult != nil)
                    Picker("Category", selection: $categoryID) {
                        ForEach(categories) { category in
                            Text(category.name).tag(category.id)
                        }
                    }
                    .disabled(isUploading || uploadResult != nil)
                    Stepper(
                        "Priority: \(priority)",
                        value: $priority,
                        in: 1...20
                    )
                    .disabled(isUploading || uploadResult != nil)

                    TextField(
                        "Notes (optional)",
                        text: $notes,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .disabled(isUploading || uploadResult != nil)
                }

                if isLoadingCategories {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading categories from Jamf Pro…")
                        }
                    }
                }

                if let categoryError {
                    Section("Categories") {
                        Label(
                            categoryError,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") {
                            loadCategories()
                        }
                        .disabled(isLoadingCategories)
                    }
                }

                if let validationError = options.validationError,
                   uploadResult == nil {
                    Section {
                        Label(
                            validationError,
                            systemImage: "exclamationmark.circle.fill"
                        )
                        .foregroundStyle(.red)
                    }
                }

                if let configurationError {
                    Section("Jamf Connection") {
                        Label(
                            configurationError,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        Button("Open Settings…") {
                            openSettings()
                        }
                    }
                }

                if isUploading || !activityMessages.isEmpty {
                    Section("Jamf Activity") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(
                                Array(activityMessages.enumerated()),
                                id: \.offset
                            ) { index, message in
                                Label {
                                    Text(message)
                                } icon: {
                                    Image(
                                        systemName: activityIcon(
                                            at: index
                                        )
                                    )
                                    .foregroundStyle(
                                        activityColor(at: index)
                                    )
                                }
                            }

                            if isUploading && uploadStage == .uploading {
                                ProgressView(value: uploadProgress)
                                Text(
                                    uploadProgress,
                                    format: .percent.precision(
                                        .fractionLength(0)
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else if isUploading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                if let uploadResult {
                    Section("Upload Complete") {
                        Label(
                            "Package is available in Jamf Pro",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        LabeledContent("Package ID", value: uploadResult.packageID)
                        LabeledContent("Filename", value: uploadResult.fileName)
                        LabeledContent(
                            "Cloud status",
                            value: uploadResult.cloudTransferStatus
                        )
                    }
                }

                if let uploadError {
                    Section("Upload Failed") {
                        Label(
                            uploadError,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)

                        Button("Save Error as Text…") {
                            ErrorReportExporter.save(
                                message: uploadError,
                                suggestedFileName: "Boxing Day Jamf Upload Error.txt"
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button(uploadResult == nil ? "Cancel" : "Done") {
                    dismiss()
                }
                .disabled(isUploading)

                Spacer()

                Button("Upload") {
                    startUpload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUpload)
            }
            .padding(16)
        }
        .frame(width: 580, height: 650)
        .interactiveDismissDisabled(isUploading)
        .onAppear {
            loadConnection()
        }
        .onDisappear {
            clientSecret = ""
        }
        .onChange(of: categoryID) { _, newValue in
            guard !isLoadingCategories,
                  let category = categories.first(
                    where: { $0.id == newValue }
                  ) else {
                return
            }
            JamfPreferences.saveDefaultCategory(category)
        }
    }

    private var stageDescription: String {
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

    private func activityIcon(at index: Int) -> String {
        if uploadResult != nil {
            return "checkmark.circle.fill"
        }
        if uploadError != nil && index == activityMessages.indices.last {
            return "exclamationmark.triangle.fill"
        }
        if isUploading && index == activityMessages.indices.last {
            return "arrow.right.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    private func activityColor(at index: Int) -> Color {
        if uploadError != nil && index == activityMessages.indices.last {
            return .red
        }
        if isUploading && index == activityMessages.indices.last {
            return .accentColor
        }
        return .green
    }

    private func recordActivity(for stage: JamfUploadStage) {
        uploadStage = stage
        let message = stageDescription
            .replacingOccurrences(of: "…", with: "")
        guard activityMessages.last != message else { return }
        activityMessages.append(message)
    }

    private func loadConnection() {
        do {
            let saved = JamfPreferences.load()
            let loadedConfiguration = try JamfConfiguration(
                serverURL: saved.serverURL,
                clientID: saved.clientID
            ).validated()
            guard let loadedSecret = try KeychainStore.loadClientSecret(),
                  !loadedSecret.isEmpty else {
                throw JamfConfigurationError.missingClientSecret
            }
            configuration = loadedConfiguration
            clientSecret = loadedSecret
            configurationError = nil
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

    private func loadCategories() {
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
                let saved = JamfPreferences.load()
                let preferred = allCategories.first {
                    $0.id == saved.defaultCategoryID
                        && $0.name.caseInsensitiveCompare(
                            saved.defaultCategoryName
                        ) == .orderedSame
                } ?? allCategories.first {
                    $0.name.caseInsensitiveCompare(
                        saved.defaultCategoryName
                    ) == .orderedSame
                }

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

    private func startUpload() {
        guard let configuration, canUpload else { return }

        isUploading = true
        uploadError = nil
        uploadResult = nil
        uploadProgress = 0
        uploadStage = .authenticating
        activityMessages = []

        Task {
            do {
                let result = try await JamfClient(
                    configuration: configuration,
                    clientSecret: clientSecret
                ).uploadPackage(
                    at: packageURL,
                    options: options,
                    stageChanged: { stage in
                        recordActivity(for: stage)
                    },
                    progressChanged: { progress in
                        uploadProgress = progress
                    }
                )
                uploadResult = result
                activityMessages.append(
                    "Jamf Pro reported the package \(result.cloudTransferStatus.lowercased())."
                )
            } catch {
                uploadError = error.localizedDescription
                activityMessages.append("Boxing Day encountered an error.")
            }
            isUploading = false
        }
    }
}

#Preview {
    JamfUploadView(
        packageURL: URL(fileURLWithPath: "/tmp/Example App 1.0.pkg")
    )
}
