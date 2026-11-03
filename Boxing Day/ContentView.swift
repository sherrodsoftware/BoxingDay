import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = PackagingModel()
    @State private var isTargeted = false

    private let acceptedTypes: [UTType] = [
        .application,
        .diskImage,
        .zip,
        UTType("com.apple.installer-package-archive") ?? .data
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text("Build an Installer Package")
                        .font(.title2)
                        .bold()
                    Text("Choose an app, disk image, or ZIP archive to begin.")
                        .foregroundStyle(.secondary)
                }

                dropZone

                if let selectedApp = model.selectedApp {
                    selectedAppCard(selectedApp)
                    optionsForm
                } else if let selectedPackageURL = model.selectedPackageURL {
                    selectedPackageCard(selectedPackageURL)
                    existingPackageActions
                }

                statusView
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .onAppear {
            model.runStartupCleanupOnce()
        }
        .onDisappear {
            // Closing the window quits the app, so clean up right away.
            model.tearDown()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            model.tearDown()
        }
        .focusedSceneValue(\.packageCommands, commandActions)
        .onChange(of: model.status) { _, newStatus in
            if let announcement = newStatus.accessibilityAnnouncement {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
        .sheet(isPresented: $model.showingJamfUpload) {
            if let uploadablePackageURL = model.uploadablePackageURL {
                JamfUploadView(
                    packageURL: uploadablePackageURL,
                    suggestedFileName: model.selectedPackageSuggestedFileName
                )
            }
        }
    }

    /// Menu bar actions for this window; a nil action disables its menu item.
    private var commandActions: PackageCommandActions {
        guard !model.showingJamfUpload, !model.status.isWorking else {
            return PackageCommandActions()
        }
        var actions = PackageCommandActions()
        actions.chooseFile = { chooseFile() }
        if model.canBuild {
            actions.build = { buildPackage() }
        }
        if model.uploadablePackageURL != nil {
            actions.upload = { model.showingJamfUpload = true }
        }
        if let url = model.completedPackageURL {
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
                    isTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            isTargeted
                                ? AnyShapeStyle(Color.accentColor.opacity(0.08))
                                : AnyShapeStyle(.quinary)
                        )
                )

            VStack(spacing: 10) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Drop a .app, .dmg, .zip, or .pkg here")
                    .foregroundStyle(.secondary)
                Button("Choose File…") {
                    chooseFile()
                }
                .buttonStyle(.bordered)
                .disabled(model.status.isWorking)
            }
        }
        .frame(height: 160)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return !model.status.isWorking
        }
        .allowsHitTesting(!model.status.isWorking)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop zone for an app, disk image, ZIP archive, or package")
        .accessibilityAction(named: "Choose File") {
            chooseFile()
        }
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
                .fill(.quinary)
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
                .fill(.quinary)
        )
    }

    // MARK: - Options

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Package Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Identifier") {
                    TextField("com.example.app.pkg", text: $model.identifier)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.status.isWorking)
                }
                if let identifierError = model.identifierError {
                    validationMessage(identifierError)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Version") {
                    TextField("1.0", text: $model.version)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.status.isWorking)
                }
                if let versionError = model.versionError {
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
                .disabled(!model.canBuild)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator)
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
                Button("Upload to Jamf Pro…") {
                    model.showingJamfUpload = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator)
        )
    }

    private func validationMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buildButtonTitle: String {
        switch model.status {
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
        switch model.status {
        case .idle:
            EmptyView()
        case .resolving(let name):
            progressCard("Reading \(name)…")
        case .building(let name):
            progressCard("Building package for \(name)…") {
                model.cancelBuild()
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
                    HStack {
                        Button("Copy Error") {
                            ErrorReportExporter.copy(message: message)
                        }
                        Button("Save Error as Text…") {
                            ErrorReportExporter.save(
                                message: message,
                                suggestedFileName: "Boxing Day Build Error.txt"
                            )
                        }
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
                    model.showingJamfUpload = true
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
        guard !model.status.isWorking else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = acceptedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose a .app, .dmg, .zip, or .pkg file."
        panel.prompt = "Choose"

        panel.presentAttachedToKeyWindow { url in
            Task { await model.resolveSelectedFile(at: url) }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        guard !model.status.isWorking, let provider = providers.first else { return }

        _ = provider.loadDataRepresentation(
            for: .fileURL
        ) { data, error in
            let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            let message = error?.localizedDescription
            Task { @MainActor in
                if let url {
                    await model.resolveSelectedFile(at: url)
                } else {
                    model.status = .failure(
                        message ?? "The dropped file could not be read."
                    )
                }
            }
        }
    }

    private func buildPackage() {
        guard model.canBuild else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType("com.apple.installer-package-archive") ?? .data
        ]
        panel.nameFieldStringValue = model.suggestedPackageFileName ?? ""
        panel.directoryURL = model.preferredPackageSaveDirectory()

        panel.presentAttachedToKeyWindow { outputURL in
            Task { await model.build(to: outputURL) }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 560, height: 640)
}
