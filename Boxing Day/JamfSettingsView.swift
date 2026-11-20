import SwiftUI

// Each section is its own View that reads only what it shows, so typing in a
// connection field doesn't redraw the category picker or status.

struct JamfSettingsView: View {
    // Private, so SwiftUI creates the model once rather than on every init.
    @State private var model = JamfSettingsModel()

    var body: some View {
        JamfSettingsForm(model: model)
    }
}

/// Settings' content for a given model, so tests can supply one with
/// in-memory settings.
struct JamfSettingsForm: View {
    let model: JamfSettingsModel

    var body: some View {
        Form {
            ConnectionFieldsSection(model: model)
            ConnectionActionsSection(model: model)
            PrivilegesSection()
            UploadDefaultsSection(model: model)
            ConnectionStatusSection(model: model)
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .frame(minHeight: 620)
        .onAppear {
            model.settingsDidOpen()
        }
        .onDisappear {
            model.settingsDidClose()
        }
        .forgetConnectionConfirmation(model: model)
    }
}

// MARK: - Connection

private struct ConnectionFieldsSection: View {
    @Bindable var model: JamfSettingsModel

    var body: some View {
        let isTesting = model.isTesting

        Section {
            TextField(
                "Jamf Pro URL",
                text: $model.serverURL,
                prompt: Text(verbatim: "https://company.jamfcloud.com")
            )
            .disabled(isTesting)

            TextField(
                "API Client ID",
                text: $model.clientID,
                prompt: Text("Client ID")
            )
            .disabled(isTesting)

            SecureField(
                "API Client Secret",
                text: $model.clientSecret,
                prompt: Text("Client secret")
            )
            .disabled(isTesting)
        } header: {
            Text("Jamf Pro Connection")
        } footer: {
            Text(
                """
                Use a dedicated Jamf Pro API client. The client secret is \
                stored only in this Mac's Keychain.
                """
            )
        }
    }
}

private struct ConnectionActionsSection: View {
    let model: JamfSettingsModel

    var body: some View {
        let canSave = model.canSave

        Section {
            HStack {
                Button("Forget Connection…", role: .destructive) {
                    model.showingForgetConfirmation = true
                }
                .disabled(model.isTesting)

                Spacer()

                Button("Save") {
                    model.save()
                }
                .disabled(!canSave)

                Button("Save & Test Connection") {
                    model.saveAndTest()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
    }
}

/// Asks before forgetting the connection. As a modifier, it keeps the
/// confirmation's state out of the Settings body.
private struct ForgetConnectionConfirmation: ViewModifier {
    @Bindable var model: JamfSettingsModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Forget this Jamf Pro connection?",
                isPresented: $model.showingForgetConfirmation
            ) {
                Button("Forget Connection", role: .destructive) {
                    model.forgetConnection()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    """
                    Boxing Day will remove the saved server, client ID, and \
                    client secret from this Mac.
                    """
                )
            }
    }
}

private extension View {
    func forgetConnectionConfirmation(model: JamfSettingsModel) -> some View {
        modifier(ForgetConnectionConfirmation(model: model))
    }
}

private struct PrivilegesSection: View {
    var body: some View {
        Section("Required API Role Privileges") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create Packages")
                Text("Read Packages")
                Text("Update Packages")
                Text("Read Cloud Distribution Point")
                Text("Read Categories")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Upload defaults

private struct UploadDefaultsSection: View {
    @Bindable var model: JamfSettingsModel

    var body: some View {
        Section {
            Picker("Default Category", selection: $model.defaultCategoryID) {
                ForEach(model.categories) { category in
                    Text(category.name).tag(category.id)
                }
            }
            .disabled(model.isLoadingCategories || model.isTesting)

            HStack {
                Button("Reload Categories") {
                    model.loadCategoriesIfPossible()
                }
                .disabled(!model.canReloadCategories)

                if model.isLoadingCategories {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let categoryError = model.categoryError {
                Label(categoryError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Package Upload Defaults")
        } footer: {
            Text(
                "Choose the Jamf Pro category preselected for new package uploads. Changes save immediately."
            )
        }
        .onChange(of: model.defaultCategoryID) { _, newValue in
            model.defaultCategoryChanged(to: newValue)
        }
    }
}

// MARK: - Status

private struct ConnectionStatusSection: View {
    let model: JamfSettingsModel

    var body: some View {
        if model.status != .idle {
            Section("Connection Status") {
                ConnectionStatusView(status: model.status)
            }
        }
    }
}

private struct ConnectionStatusView: View {
    let status: JamfSettingsStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .saved:
            Label(
                "Connection settings saved",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .testing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting to Jamf Pro…")
            }
        case .connected(let summary):
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    "Connected to \(summary.server)",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)

                LabeledContent("Cloud distribution point") {
                    Text(summary.cloudDistributionPoint)
                }
                .font(.caption)

                if summary.cloudUploadReady {
                    Text(
                        "Authentication, package and category access, and cloud distribution point access are working."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Label(
                        "A cloud distribution point must be configured before package uploads can be added.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    JamfSettingsView()
}
