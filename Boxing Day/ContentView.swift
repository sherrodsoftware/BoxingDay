import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    var isWorking: Bool {
        switch self {
        case .resolving, .building:
            return true
        case .idle, .success, .failure:
            return false
        }
    }
}

struct ContentView: View {
    private static let lastPackageSaveDirectoryKey = "lastPackageSaveDirectory"

    @State private var status: BuildStatus = .idle
    @State private var isTargeted = false
    @State private var identifier = ""
    @State private var version = ""
    @State private var pendingAppURL: URL?
    @State private var pendingWorkDir: URL?
    @State private var selectedPackageURL: URL?
    @State private var selectedPackageWorkDir: URL?
    @State private var selectedPackageSuggestedFileName: String?
    @State private var selectedApp: SelectedAppDetails?
    @State private var isViewActive = true
    @State private var didRunStartupCleanup = false
    @State private var showingJamfUpload = false
    @State private var buildCancellation: ShellCancellation?

    private let acceptedTypes: [UTType] = [
        UTType.application,
        UTType(filenameExtension: "dmg")!,
        UTType.zip,
        UTType(filenameExtension: "pkg")!
    ]

    private var identifierError: String? {
        PackageFieldValidator.identifierError(identifier)
    }

    private var versionError: String? {
        PackageFieldValidator.versionError(version)
    }

    private var canBuild: Bool {
        pendingAppURL != nil
            && identifierError == nil
            && versionError == nil
            && !status.isWorking
    }

    private var completedPackageURL: URL? {
        guard case .success(let details) = status else { return nil }
        return details.url
    }

    private var uploadablePackageURL: URL? {
        completedPackageURL ?? selectedPackageURL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text("App → .pkg")
                        .font(.title2)
                        .bold()
                    Text("Choose an app, disk image, or ZIP archive to begin.")
                        .foregroundStyle(.secondary)
                }

                dropZone

                if let selectedApp {
                    selectedAppCard(selectedApp)
                    optionsForm
                } else if let selectedPackageURL {
                    selectedPackageCard(selectedPackageURL)
                    existingPackageActions
                }

                statusView
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .onAppear {
            isViewActive = true
            if !didRunStartupCleanup {
                didRunStartupCleanup = true
                DispatchQueue.global(qos: .utility).async {
                    AppResolver.cleanupAbandonedWorkDirs()
                    JamfClient.cleanupAbandonedUploadBodies()
                }
            }
        }
        .onDisappear {
            isViewActive = false
            discardPendingAppIfIdle()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            buildCancellation?.cancel()
            discardPendingApp(force: true)
        }
        .focusedSceneValue(\.packageCommands, commandActions)
        .sheet(isPresented: $showingJamfUpload) {
            if let uploadablePackageURL {
                JamfUploadView(
                    packageURL: uploadablePackageURL,
                    suggestedFileName: selectedPackageSuggestedFileName
                )
            }
        }
    }

    /// Menu bar actions for this window; a nil action disables its menu item.
    private var commandActions: PackageCommandActions {
        guard !showingJamfUpload, !status.isWorking else {
            return PackageCommandActions()
        }
        var actions = PackageCommandActions()
        actions.chooseFile = { chooseFile() }
        if canBuild {
            actions.build = { buildPackage() }
        }
        if uploadablePackageURL != nil {
            actions.upload = { showingJamfUpload = true }
        }
        if let url = completedPackageURL {
            actions.reveal = {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        return actions
    }

    // MARK: - File selection

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .foregroundStyle(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.5)
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            isTargeted
                                ? Color.accentColor.opacity(0.08)
                                : Color.secondary.opacity(0.04)
                        )
                )

            VStack(spacing: 10) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Drop a .app, .dmg, .zip, or .pkg here")
                    .foregroundStyle(.secondary)
                Button("Choose File…") {
                    chooseFile()
                }
                .buttonStyle(.bordered)
                .disabled(status.isWorking)
            }
        }
        .frame(height: 160)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return !status.isWorking
        }
        .allowsHitTesting(!status.isWorking)
    }

    private func selectedAppCard(_ app: SelectedAppDetails) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 5) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)

                switch app.signatureStatus {
                case .valid:
                    Label("Code signature valid", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                case .unsignedOrInvalid(let reason):
                    Label(
                        "Unsigned or signature invalid",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(reason)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func selectedPackageCard(_ packageURL: URL) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 5) {
                Text(packageURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                Text("Existing package ready to upload")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    // MARK: - Options

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Package Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Identifier") {
                    TextField("com.example.app.pkg", text: $identifier)
                        .textFieldStyle(.roundedBorder)
                        .disabled(status.isWorking)
                }
                if let identifierError {
                    validationMessage(identifierError)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Version") {
                    TextField("1.0", text: $version)
                        .textFieldStyle(.roundedBorder)
                        .disabled(status.isWorking)
                }
                if let versionError {
                    validationMessage(versionError)
                }
            }

            HStack {
                Text("Installs in /Applications")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(buildButtonTitle) {
                    buildPackage()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canBuild)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    private var existingPackageActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Package Details")
                .font(.headline)

            Text("This file is already a .pkg, so no build is needed.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Build .pkg…") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                Button("Upload to Jamf Pro…") {
                    showingJamfUpload = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    private func validationMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buildButtonTitle: String {
        switch status {
        case .success:
            return "Build Again…"
        case .failure:
            return "Retry Build…"
        default:
            return "Build .pkg…"
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .resolving(let name):
            progressCard("Reading \(name)…")
        case .building(let name):
            progressCard("Building package for \(name)…") {
                buildCancellation?.cancel()
            }
        case .success(let details):
            completionCard(details)
        case .failure(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 10) {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Save Error as Text…") {
                        ErrorReportExporter.save(
                            message: message,
                            suggestedFileName: "Boxing Day Build Error.txt"
                        )
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.red.opacity(0.08))
            )
        }
    }

    private func progressCard(
        _ message: String,
        cancel: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
            Spacer(minLength: 0)
            if let cancel {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private func completionCard(_ details: PackageCompletionDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Package created successfully", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 6) {
                completionRow("File", details.url.lastPathComponent)
                completionRow("Saved to", details.url.deletingLastPathComponent().path)
                completionRow("Identifier", details.identifier)
                completionRow("Version", details.version)
                completionRow("Install location", details.installLocation)
                if let fileSize = details.fileSize {
                    completionRow(
                        "Package size",
                        ByteCountFormatter.string(
                            fromByteCount: fileSize,
                            countStyle: .file
                        )
                    )
                }
            }

            if let signatureWarning = details.signatureWarning {
                Label(
                    signatureWarning,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([details.url])
                }

                Button("Upload to Jamf Pro…") {
                    showingJamfUpload = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.green.opacity(0.08))
        )
    }

    private func completionRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(value)
        }
        .font(.caption)
    }

    // MARK: - Actions

    private func chooseFile() {
        guard !status.isWorking else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = acceptedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a .app, .dmg, .zip, or .pkg file."
        panel.prompt = "Choose"

        panel.presentAttachedToKeyWindow { url in
            resolveSelectedFile(at: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        guard !status.isWorking, let provider = providers.first else { return }

        provider.loadItem(
            forTypeIdentifier: UTType.fileURL.identifier,
            options: nil
        ) { item, error in
            guard error == nil,
                  let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil)
            else {
                DispatchQueue.main.async {
                    status = .failure(
                        error?.localizedDescription
                            ?? "The dropped file could not be read."
                    )
                }
                return
            }

            DispatchQueue.main.async {
                resolveSelectedFile(at: url)
            }
        }
    }

    private func resolveSelectedFile(at url: URL) {
        guard !status.isWorking else { return }

        discardPendingAppIfIdle()
        selectedApp = nil
        selectedPackageURL = nil
        selectedPackageSuggestedFileName = nil

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

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try AppResolver.resolveInput(from: url)
                let packageVersion: String?
                if case .package(let packageURL) = result.input {
                    packageVersion = PkgBuilder.packageVersion(for: packageURL)
                } else {
                    packageVersion = nil
                }
                let resolvedInput: ResolvedInput
                if case .package(let packageURL) = result.input {
                    resolvedInput = .package(
                        try PkgBuilder.appendVersionToCopiedPackage(
                            at: packageURL,
                            version: packageVersion
                        )
                    )
                } else {
                    resolvedInput = result.input
                }
                // codesign --deep can take seconds on large apps, so verify
                // here rather than on the main thread.
                var appDefaults: PkgOptions?
                var appSignatureStatus: AppSignatureStatus?
                if case .app(let appURL) = resolvedInput {
                    appDefaults = try? PkgBuilder.defaultOptions(for: appURL)
                    appSignatureStatus = PkgBuilder.codeSignatureStatus(for: appURL)
                }

                DispatchQueue.main.async {
                    guard isViewActive else {
                        if let workDir = result.workDir {
                            removeWorkDirAsync(workDir)
                        }
                        return
                    }
                    switch resolvedInput {
                    case .app(let appURL):
                        let defaults = appDefaults
                        let signatureStatus = appSignatureStatus
                            ?? .unsignedOrInvalid("The signature was not checked.")
                        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                        icon.size = NSSize(width: 64, height: 64)
                        pendingAppURL = appURL
                        pendingWorkDir = result.workDir
                        selectedApp = SelectedAppDetails(
                            name: appURL.deletingPathExtension().lastPathComponent,
                            icon: icon,
                            signatureStatus: signatureStatus
                        )
                        identifier = defaults?.identifier ?? ""
                        version = defaults?.version ?? "1.0"
                    case .package(let packageURL):
                        selectedPackageURL = packageURL
                        selectedPackageWorkDir = result.workDir
                        selectedPackageSuggestedFileName = PkgBuilder.filename(
                            for: packageURL,
                            appending: packageVersion
                        )
                    }
                    status = .idle
                }
            } catch {
                DispatchQueue.main.async {
                    guard isViewActive else { return }
                    status = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func buildPackage() {
        guard canBuild,
              let appURL = pendingAppURL,
              let workDir = pendingWorkDir
        else {
            return
        }

        let appName = appURL.deletingPathExtension().lastPathComponent
        let suggestedName = "\(appName) \(version).pkg"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pkg")!]
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = preferredPackageSaveDirectory()

        panel.presentAttachedToKeyWindow { outputURL in
            startBuild(appURL: appURL, workDir: workDir, outputURL: outputURL)
        }
    }

    private func startBuild(appURL: URL, workDir: URL, outputURL: URL) {
        guard canBuild else { return }
        UserDefaults.standard.set(
            outputURL.deletingLastPathComponent().path,
            forKey: Self.lastPackageSaveDirectoryKey
        )

        let options = PkgOptions(identifier: identifier, version: version)
        status = .building(appURL.lastPathComponent)
        let cancellation = ShellCancellation()
        buildCancellation = cancellation

        DispatchQueue.global(qos: .userInitiated).async {
            do {
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
                let details = PackageCompletionDetails(
                    url: outputURL,
                    identifier: options.identifier,
                    version: options.version,
                    installLocation: options.installLocation,
                    fileSize: fileSize.map(Int64.init),
                    signatureWarning: result.signatureWarning
                )

                DispatchQueue.main.async {
                    buildCancellation = nil
                    guard isViewActive else {
                        if pendingWorkDir == workDir {
                            pendingAppURL = nil
                            pendingWorkDir = nil
                            selectedApp = nil
                        }
                        removeWorkDirAsync(workDir)
                        return
                    }
                    status = .success(details)
                }
            } catch {
                DispatchQueue.main.async {
                    buildCancellation = nil
                    guard isViewActive else {
                        if pendingWorkDir == workDir {
                            pendingAppURL = nil
                            pendingWorkDir = nil
                            selectedApp = nil
                        }
                        removeWorkDirAsync(workDir)
                        return
                    }
                    if case ShellError.cancelled = error {
                        // Return to the package details so the user can
                        // adjust them or build again.
                        status = .idle
                    } else {
                        status = .failure(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func preferredPackageSaveDirectory() -> URL? {
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

    private func discardPendingAppIfIdle() {
        discardPendingApp(force: false)
    }

    private func discardPendingApp(force: Bool) {
        guard force || !status.isWorking else { return }

        let workDir = pendingWorkDir
        pendingAppURL = nil
        pendingWorkDir = nil
        selectedApp = nil
        selectedPackageURL = nil
        selectedPackageSuggestedFileName = nil

        if let packageWorkDir = selectedPackageWorkDir {
            selectedPackageWorkDir = nil
            AppResolver.removeWorkDir(at: packageWorkDir)
        }

        guard let workDir else { return }
        if force {
            AppResolver.removeWorkDir(at: workDir)
        } else {
            removeWorkDirAsync(workDir)
        }
    }

    private func removeWorkDirAsync(_ workDir: URL) {
        DispatchQueue.global(qos: .utility).async {
            AppResolver.removeWorkDir(at: workDir)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 560, height: 640)
}
