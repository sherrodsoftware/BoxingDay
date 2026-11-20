import SwiftUI

// Each section is its own View that reads only what it shows, so Observation
// redraws just that section when the model changes. Upload progress, which
// changes most often, is read only by UploadProgressRow.

struct JamfUploadView: View {
    @State private var model: JamfUploadModel

    init(packageURL: URL, suggestedFileName: String? = nil) {
        self.init(model: JamfUploadModel(
            packageURL: packageURL,
            suggestedFileName: suggestedFileName
        ))
    }

    init(model: JamfUploadModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            UploadHeader(packageURL: model.packageURL)

            Divider()

            Form {
                RecordFieldsSection(model: model)
                CategoryStatusSection(model: model)
                ValidationSection(model: model)
                ConnectionSection(model: model)
                ActivitySection(model: model)
                ResultSection(model: model)
                ErrorSection(model: model)
            }
            .formStyle(.grouped)

            Divider()

            UploadFooter(model: model)
        }
        .frame(minWidth: 580, idealWidth: 580, minHeight: 520, idealHeight: 650)
        .uploadDismissal(model: model)
        .uploadAnnouncements(model: model)
        .onAppear {
            model.loadConnection()
        }
        .onDisappear {
            model.forgetSecret()
        }
    }
}

// MARK: - Sheet-wide behavior

/// Prevents closing the sheet while an upload runs.
private struct UploadDismissal: ViewModifier {
    let model: JamfUploadModel

    func body(content: Content) -> some View {
        content.interactiveDismissDisabled(model.isUploading)
    }
}

/// Announces upload steps and the outcome for VoiceOver. As a modifier, it
/// keeps those reads out of the sheet's body.
private struct UploadAnnouncements: ViewModifier {
    let model: JamfUploadModel

    func body(content: Content) -> some View {
        content
            .onChange(of: model.activity.last?.id) {
                // The activity list is the upload's progress, so read each
                // new step aloud; the final result is announced separately.
                if model.isUploading, let latest = model.activity.last {
                    AccessibilityNotification.Announcement(latest.message).post()
                }
            }
            .onChange(of: model.uploadResult) { _, result in
                if result != nil {
                    AccessibilityNotification.Announcement(
                        "Upload complete. Package is available in Jamf Pro."
                    ).post()
                }
            }
            .onChange(of: model.uploadError) { _, error in
                if let error {
                    AccessibilityNotification.Announcement(error).post()
                }
            }
    }
}

private extension View {
    func uploadDismissal(model: JamfUploadModel) -> some View {
        modifier(UploadDismissal(model: model))
    }

    func uploadAnnouncements(model: JamfUploadModel) -> some View {
        modifier(UploadAnnouncements(model: model))
    }
}

// MARK: - Header and footer

private struct UploadHeader: View {
    let packageURL: URL

    var body: some View {
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
    }
}

private struct UploadFooter: View {
    @Environment(\.dismiss) private var dismiss
    let model: JamfUploadModel

    var body: some View {
        HStack {
            Button(model.uploadResult == nil ? "Cancel" : "Done") {
                if model.isUploading {
                    // Stop the upload but keep the sheet open so the
                    // user can see what state Jamf Pro was left in.
                    model.cancelUpload()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Upload") {
                model.startUpload()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canUpload)
        }
        .padding(16)
    }
}

// MARK: - Record fields

private struct RecordFieldsSection: View {
    @Bindable var model: JamfUploadModel

    var body: some View {
        let isEditable = model.isEditable

        Section("Jamf Package Record") {
            TextField("Package name", text: $model.packageName)
                .disabled(!isEditable)
            TextField("Filename", text: $model.fileName)
                .disabled(!isEditable)
            Picker("Category", selection: $model.categoryID) {
                ForEach(model.categories) { category in
                    Text(category.name).tag(category.id)
                }
            }
            .disabled(!isEditable)
            Stepper(
                "Priority: \(model.priority)",
                value: $model.priority,
                in: 1...20
            )
            .disabled(!isEditable)

            TextField(
                "Notes (optional)",
                text: $model.notes,
                axis: .vertical
            )
            .lineLimit(2...4)
            .disabled(!isEditable)
        }
    }
}

private struct CategoryStatusSection: View {
    let model: JamfUploadModel

    var body: some View {
        if model.isLoadingCategories {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading categories from Jamf Pro…")
                }
            }
        }

        if let categoryError = model.categoryError {
            Section("Categories") {
                Label(
                    categoryError,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") {
                    model.loadCategories()
                }
                .disabled(model.isLoadingCategories)
            }
        }
    }
}

private struct ValidationSection: View {
    let model: JamfUploadModel

    var body: some View {
        if let validationError = model.options.validationError,
           model.uploadResult == nil {
            Section {
                Label(
                    validationError,
                    systemImage: "exclamationmark.circle.fill"
                )
                .foregroundStyle(.red)
            }
        }
    }
}

private struct ConnectionSection: View {
    @Environment(\.openSettings) private var openSettings
    let model: JamfUploadModel

    var body: some View {
        if let configurationError = model.configurationError {
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
    }
}

// MARK: - Activity

private struct ActivitySection: View {
    let model: JamfUploadModel

    var body: some View {
        if model.isUploading || !model.activity.isEmpty {
            Section("Jamf Activity") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.activity) { step in
                        ActivityRow(step: step)
                    }

                    if model.isUploading {
                        UploadProgressRow(model: model)
                    }
                }
            }
        }
    }
}

/// One step, drawn from its own state, so adding a step redraws only the
/// new row and the one it finished.
private struct ActivityRow: View {
    let step: UploadActivity

    var body: some View {
        Label {
            Text(step.message)
        } icon: {
            Image(systemName: symbolName)
                .foregroundStyle(color)
        }
    }

    private var symbolName: String {
        switch step.state {
        case .inProgress: "arrow.right.circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var color: Color {
        switch step.state {
        case .inProgress: .accentColor
        case .done: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

/// The only view that reads upload progress, so a progress update redraws
/// just the bar and percentage.
private struct UploadProgressRow: View {
    let model: JamfUploadModel

    var body: some View {
        if model.uploadStage == .uploading {
            ProgressView(value: model.uploadProgress)
            Text(
                model.uploadProgress,
                format: .percent.precision(.fractionLength(0))
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}

// MARK: - Outcome

private struct ResultSection: View {
    let model: JamfUploadModel

    var body: some View {
        if let uploadResult = model.uploadResult {
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
    }
}

private struct ErrorSection: View {
    let model: JamfUploadModel

    var body: some View {
        if let uploadError = model.uploadError {
            let cancelled = model.uploadWasCancelled
            Section(cancelled ? "Upload Cancelled" : "Upload Failed") {
                Label(
                    uploadError,
                    systemImage: cancelled
                        ? "stop.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(cancelled ? .orange : .red)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Copy Error") {
                        ErrorReportExporter.copy(message: uploadError)
                    }
                    Button("Save Error as Text…") {
                        ErrorReportExporter.save(
                            message: uploadError,
                            suggestedFileName: "Boxing Day Jamf Upload Error.txt"
                        )
                    }
                }
            }
        }
    }
}

#Preview {
    JamfUploadView(
        packageURL: URL(fileURLWithPath: "/tmp/Example App 1.0.pkg")
    )
}
