import AppKit
import Observation

struct SelectedAppDetails {
    let name: String
    let icon: NSImage
    let signatureStatus: AppSignatureStatus
}

struct PackageCompletionDetails: Equatable {
    let url: URL
    let identifier: String
    let version: String
    let installLocation: String
    let fileSize: Int64?
    let signatureWarning: String?
}

enum BuildStatus: Equatable {
    case idle
    case resolving(String)
    case building(String)
    case success(PackageCompletionDetails)
    case failure(String)

    /// What VoiceOver announces when the status changes to this value.
    var accessibilityAnnouncement: String? {
        switch self {
        case .idle:
            return nil
        case .resolving(let name):
            return "Reading \(name)"
        case .building(let name):
            return "Building package for \(name)"
        case .success(let details):
            return "Package created: \(details.url.lastPathComponent)"
        case .failure(let message):
            return "Error: \(message)"
        }
    }

    var isWorking: Bool {
        switch self {
        case .resolving, .building:
            return true
        case .idle, .success, .failure:
            return false
        }
    }
}

/// The main window's state: the selected app or package, its temporary
/// workspace, the package details being edited, and build progress.
/// File-system and shell work runs off the main actor; results are applied
/// here on the main actor.
@MainActor
@Observable
final class PackagingModel {
    private static let lastPackageSaveDirectoryKey = "lastPackageSaveDirectory"

    var status: BuildStatus = .idle
    var identifier = ""
    var version = ""
    var showingJamfUpload = false

    private(set) var selectedApp: SelectedAppDetails?
    private(set) var selectedPackageURL: URL?
    private(set) var selectedPackageSuggestedFileName: String?

    private var pendingAppURL: URL?
    private var pendingWorkDir: URL?
    private var selectedPackageWorkDir: URL?
    private var buildCancellation: ShellCancellation?
    private var didRunStartupCleanup = false

    var identifierError: String? {
        PackageFieldValidator.identifierError(identifier)
    }

    var versionError: String? {
        PackageFieldValidator.versionError(version)
    }

    var canBuild: Bool {
        pendingAppURL != nil
            && identifierError == nil
            && versionError == nil
            && !status.isWorking
    }

    var completedPackageURL: URL? {
        guard case .success(let details) = status else { return nil }
        return details.url
    }

    var uploadablePackageURL: URL? {
        completedPackageURL ?? selectedPackageURL
    }

    var suggestedPackageFileName: String? {
        guard let pendingAppURL else { return nil }
        let appName = pendingAppURL.deletingPathExtension().lastPathComponent
        return "\(appName) \(version).pkg"
    }

    // MARK: - Lifecycle

    func runStartupCleanupOnce() {
        guard !didRunStartupCleanup else { return }
        didRunStartupCleanup = true
        Task.detached(priority: .utility) {
            AppResolver.cleanupAbandonedWorkDirs()
            JamfClient.cleanupAbandonedUploadBodies()
        }
    }

    /// Stops any build and removes temporary files synchronously, for use
    /// while the app is quitting.
    func tearDown() {
        buildCancellation?.cancel()
        discardSelection(force: true)
    }

    // MARK: - Selection

    func resolveSelectedFile(at url: URL) async {
        guard !status.isWorking else { return }

        discardSelection(force: false)

        if url.pathExtension.lowercased() == "pkg" {
            guard FileManager.default.fileExists(atPath: url.path) else {
                status = .failure("The selected package could not be found.")
                return
            }
            selectedPackageURL = url
            status = .idle
            return
        }

        status = .resolving(url.lastPathComponent)

        do {
            let selection = try await Task.detached(priority: .userInitiated) {
                try Self.resolve(url)
            }.value
            apply(selection)
            status = .idle
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func apply(_ selection: ResolvedSelection) {
        switch selection.kind {
        case .app(let appURL, let defaults, let signatureStatus):
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 64, height: 64)
            pendingAppURL = appURL
            pendingWorkDir = selection.workDir
            selectedApp = SelectedAppDetails(
                name: appURL.deletingPathExtension().lastPathComponent,
                icon: icon,
                signatureStatus: signatureStatus
            )
            identifier = defaults?.identifier ?? ""
            version = defaults?.version ?? "1.0"
        case .package(let packageURL, let suggestedFileName):
            selectedPackageURL = packageURL
            selectedPackageWorkDir = selection.workDir
            selectedPackageSuggestedFileName = suggestedFileName
        }
    }

    // MARK: - Building

    func preferredPackageSaveDirectory() -> URL? {
        let fileManager = FileManager.default
        if let savedPath = UserDefaults.standard.string(
            forKey: Self.lastPackageSaveDirectoryKey
        ) {
            let savedDirectory = URL(fileURLWithPath: savedPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: savedDirectory.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                return savedDirectory
            }
        }

        return fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    func build(to outputURL: URL) async {
        guard canBuild,
              let appURL = pendingAppURL,
              let workDir = pendingWorkDir
        else {
            return
        }

        UserDefaults.standard.set(
            outputURL.deletingLastPathComponent().path,
            forKey: Self.lastPackageSaveDirectoryKey
        )

        let options = PkgOptions(identifier: identifier, version: version)
        status = .building(appURL.lastPathComponent)
        let cancellation = ShellCancellation()
        buildCancellation = cancellation
        defer { buildCancellation = nil }

        do {
            let details = try await Task.detached(priority: .userInitiated) {
                let result = try PkgBuilder.buildPkg(
                    appURL: appURL,
                    workDir: workDir,
                    outputURL: outputURL,
                    options: options,
                    cancellation: cancellation
                )
                let fileSize = try? outputURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize
                return PackageCompletionDetails(
                    url: outputURL,
                    identifier: options.identifier,
                    version: options.version,
                    installLocation: options.installLocation,
                    fileSize: fileSize.map(Int64.init),
                    signatureWarning: result.signatureWarning
                )
            }.value
            status = .success(details)
        } catch ShellError.cancelled {
            // Return to the package details so the user can adjust them or
            // build again.
            status = .idle
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func cancelBuild() {
        buildCancellation?.cancel()
    }

    // MARK: - Cleanup

    /// Clears the selection and removes its workspace. Removal runs in the
    /// background unless `force` is set, which also skips the busy check.
    func discardSelection(force: Bool) {
        guard force || !status.isWorking else { return }

        let workDirs = [pendingWorkDir, selectedPackageWorkDir].compactMap { $0 }
        pendingAppURL = nil
        pendingWorkDir = nil
        selectedApp = nil
        selectedPackageURL = nil
        selectedPackageWorkDir = nil
        selectedPackageSuggestedFileName = nil

        if force {
            workDirs.forEach(AppResolver.removeWorkDir(at:))
        } else {
            Task.detached(priority: .utility) {
                workDirs.forEach(AppResolver.removeWorkDir(at:))
            }
        }
    }
}

// MARK: - Background resolution

/// The result of reading a dropped item, produced off the main actor.
nonisolated private struct ResolvedSelection: Sendable {
    enum Kind: Sendable {
        case app(URL, defaults: PkgOptions?, signatureStatus: AppSignatureStatus)
        case package(URL, suggestedFileName: String)
    }

    let kind: Kind
    let workDir: URL?
}

extension PackagingModel {
    nonisolated fileprivate static func resolve(_ url: URL) throws -> ResolvedSelection {
        let result = try AppResolver.resolveInput(from: url)
        do {
            switch result.input {
            case .app(let appURL):
                // codesign --deep can take seconds on large apps.
                return ResolvedSelection(
                    kind: .app(
                        appURL,
                        defaults: try? PkgBuilder.defaultOptions(for: appURL),
                        signatureStatus: PkgBuilder.codeSignatureStatus(for: appURL)
                    ),
                    workDir: result.workDir
                )
            case .package(let packageURL):
                let packageVersion = PkgBuilder.packageVersion(for: packageURL)
                let renamedURL = try PkgBuilder.appendVersionToCopiedPackage(
                    at: packageURL,
                    version: packageVersion
                )
                return ResolvedSelection(
                    kind: .package(
                        renamedURL,
                        suggestedFileName: PkgBuilder.filename(
                            for: renamedURL,
                            appending: packageVersion
                        )
                    ),
                    workDir: result.workDir
                )
            }
        } catch {
            if let workDir = result.workDir {
                AppResolver.removeWorkDir(at: workDir)
            }
            throw error
        }
    }
}
