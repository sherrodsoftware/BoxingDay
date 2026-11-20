import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Each section is its own View that reads only what it shows, so Observation
// redraws just that section when the model changes. For example, typing in
// Identifier redraws the package details, not the drop zone or status card.

struct ContentView: View {
    @State private var model = PackagingModel()

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

                DropZoneView(model: model)
                SelectionSection(model: model)
                StatusSection(model: model)
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
        .focusedSceneValue(\.packagingModel, model)
        .statusAnnouncements(model: model)
        .sheet(isPresented: $model.showingJamfUpload) {
            JamfUploadSheet(model: model)
        }
    }
}

// MARK: - Accessibility

/// Announces status changes for VoiceOver. As a modifier, it keeps the
/// status read out of ContentView's body.
private struct StatusAnnouncements: ViewModifier {
    let model: PackagingModel

    func body(content: Content) -> some View {
        content
            .onChange(of: model.status) { _, newStatus in
                if let announcement = newStatus.accessibilityAnnouncement {
                    AccessibilityNotification.Announcement(announcement).post()
                }
            }
    }
}

private extension View {
    func statusAnnouncements(model: PackagingModel) -> some View {
        modifier(StatusAnnouncements(model: model))
    }
}

// MARK: - Upload sheet

private struct JamfUploadSheet: View {
    let model: PackagingModel

    var body: some View {
        if let uploadablePackageURL = model.uploadablePackageURL {
            JamfUploadView(
                packageURL: uploadablePackageURL,
                suggestedFileName: model.selectedPackageSuggestedFileName
            )
        }
    }
}

// MARK: - File selection

private struct DropZoneView: View {
    let model: PackagingModel
    @State private var isTargeted = false

    var body: some View {
        let isWorking = model.status.isWorking

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
                    model.chooseFile()
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
        .frame(height: 160)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return !model.status.isWorking
        }
        .allowsHitTesting(!isWorking)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop zone for an app, disk image, ZIP archive, or package")
        .accessibilityAction(named: "Choose File") {
            model.chooseFile()
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
}

/// Shows the selected app and its package details, or the selected package.
private struct SelectionSection: View {
    let model: PackagingModel

    var body: some View {
        if let selectedApp = model.selectedApp {
            SelectedAppCard(app: selectedApp)
            PackageDetailsForm(model: model)
        } else if let selectedPackageURL = model.selectedPackageURL {
            SelectedPackageCard(packageURL: selectedPackageURL)
            ExistingPackageActions(model: model)
        }
    }
}

private struct SelectedAppCard: View {
    let app: SelectedAppDetails

    var body: some View {
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
}

private struct SelectedPackageCard: View {
    let packageURL: URL

    var body: some View {
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
}

// MARK: - Package details

private struct PackageDetailsForm: View {
    @Bindable var model: PackagingModel

    var body: some View {
        let isWorking = model.status.isWorking

        VStack(alignment: .leading, spacing: 14) {
            Text("Package Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Identifier") {
                    TextField("com.example.app.pkg", text: $model.identifier)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                }
                if let identifierError = model.identifierError {
                    ValidationMessage(message: identifierError)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("Version") {
                    TextField("1.0", text: $model.version)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                }
                if let versionError = model.versionError {
                    ValidationMessage(message: versionError)
                }
            }

            HStack {
                Text("Installs in /Applications")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(buildButtonTitle) {
                    model.chooseBuildDestination()
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
}

private struct ExistingPackageActions: View {
    let model: PackagingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Package Details")
                .font(.headline)

            Text("This file is already a .pkg, so no build is needed.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Upload to Jamf Pro…") {
                    model.presentUpload()
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
}

private struct ValidationMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Status

private struct StatusSection: View {
    let model: PackagingModel

    var body: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .resolving(let name):
            ProgressCard(message: "Reading \(name)…", model: nil)
        case .building(let name):
            ProgressCard(message: "Building package for \(name)…", model: model)
        case .success(let details):
            CompletionCard(details: details, model: model)
        case .failure(let message):
            FailureCard(message: message)
        }
    }
}

/// Shows work in progress. Pass the model to offer Cancel for a build.
private struct ProgressCard: View {
    let message: String
    let model: PackagingModel?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(message)
            Spacer(minLength: 0)
            if let model {
                Button("Cancel") {
                    model.cancelBuild()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
    }
}

private struct FailureCard: View {
    let message: String

    var body: some View {
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

private struct CompletionCard: View {
    let details: PackageCompletionDetails
    let model: PackagingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Package created successfully", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 6) {
                CompletionRow(label: "File", value: details.url.lastPathComponent)
                CompletionRow(label: "Saved to", value: details.url.deletingLastPathComponent().path)
                CompletionRow(label: "Identifier", value: details.identifier)
                CompletionRow(label: "Version", value: details.version)
                CompletionRow(label: "Install location", value: details.installLocation)
                if let fileSize = details.fileSize {
                    CompletionRow(
                        label: "Package size",
                        value: ByteCountFormatter.string(
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
                    model.revealCompletedPackage()
                }

                Button("Upload to Jamf Pro…") {
                    model.presentUpload()
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
}

private struct CompletionRow: View {
    let label: String
    let value: String

    var body: some View {
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
}

#Preview {
    ContentView()
        .frame(width: 560, height: 640)
}
