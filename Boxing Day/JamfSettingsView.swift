import SwiftUI

private enum JamfSettingsStatus: Equatable {
    case idle
    case saved
    case testing
    case connected(JamfConnectionSummary)
    case failure(String)
}

struct JamfSettingsView: View {
    @State private var serverURL: String
    @State private var clientID: String
    @State private var clientSecret = ""
    @State private var defaultCategoryID: String
    @State private var categories = [JamfCategory.noCategory]
    @State private var isLoadingCategories = false
    @State private var categoryError: String?
    @State private var status: JamfSettingsStatus = .idle
    @State private var didLoadSecret = false
    @State private var showingForgetConfirmation = false

    init() {
        let saved = JamfPreferences.load()
        _serverURL = State(initialValue: saved.serverURL)
        _clientID = State(initialValue: saved.clientID)
        _defaultCategoryID = State(
            initialValue: saved.defaultCategoryID ?? JamfCategory.noCategory.id
        )
    }

    private var hasRequiredValues: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.isEmpty
    }

    private var isTesting: Bool {
        status == .testing
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    "Jamf Pro URL",
                    text: $serverURL,
                    prompt: Text("https://company.jamfcloud.com")
                )
                .disabled(isTesting)

                TextField(
                    "API Client ID",
                    text: $clientID,
                    prompt: Text("Client ID")
                )
                .disabled(isTesting)

                SecureField(
                    "API Client Secret",
                    text: $clientSecret,
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

            Section {
                HStack {
                    Button("Forget Connection…", role: .destructive) {
                        showingForgetConfirmation = true
                    }
                    .disabled(isTesting)

                    Spacer()

                    Button("Save") {
                        save()
                    }
                    .disabled(!hasRequiredValues || isTesting)

                    Button("Save & Test Connection") {
                        saveAndTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasRequiredValues || isTesting)
                }
            }

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

            Section {
                Picker("Default Category", selection: $defaultCategoryID) {
                    ForEach(categories) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .disabled(isLoadingCategories || isTesting)

                HStack {
                    Button("Reload Categories") {
                        loadCategoriesIfPossible()
                    }
                    .disabled(!hasRequiredValues || isLoadingCategories || isTesting)

                    if isLoadingCategories {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let categoryError {
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

            if status != .idle {
                Section("Connection Status") {
                    statusView
                }
            }

        }
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
        .onAppear {
            loadSecretOnce()
            loadCategoriesIfPossible()
        }
        .onChange(of: defaultCategoryID) { _, newValue in
            guard !isLoadingCategories,
                  let category = categories.first(where: { $0.id == newValue })
            else {
                return
            }
            JamfPreferences.saveDefaultCategory(category)
        }
        .confirmationDialog(
            "Forget this Jamf Pro connection?",
            isPresented: $showingForgetConfirmation
        ) {
            Button("Forget Connection", role: .destructive) {
                forgetConnection()
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

    @ViewBuilder
    private var statusView: some View {
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

    private func loadSecretOnce() {
        guard !didLoadSecret else { return }
        didLoadSecret = true
        do {
            clientSecret = try KeychainStore.loadClientSecret() ?? ""
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func currentConfiguration() throws -> JamfConfiguration {
        guard !clientSecret.isEmpty else {
            throw JamfConfigurationError.missingClientSecret
        }
        return try JamfConfiguration(
            serverURL: serverURL,
            clientID: clientID
        ).validated()
    }

    private func save() {
        do {
            let configuration = try currentConfiguration()
            try save(configuration)
            status = .saved
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func saveAndTest() {
        do {
            let configuration = try currentConfiguration()
            try save(configuration)
            status = .testing

            Task {
                do {
                    let summary = try await JamfClient(
                        configuration: configuration,
                        clientSecret: clientSecret
                    ).testConnection()
                    status = .connected(summary)
                    loadCategories(using: configuration)
                } catch {
                    status = .failure(error.localizedDescription)
                }
            }
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func save(_ configuration: JamfConfiguration) throws {
        try KeychainStore.saveClientSecret(clientSecret)
        JamfPreferences.save(configuration)
        serverURL = configuration.serverURL
        clientID = configuration.clientID
    }

    private func loadCategoriesIfPossible() {
        guard let configuration = try? currentConfiguration() else { return }
        loadCategories(using: configuration)
    }

    private func loadCategories(using configuration: JamfConfiguration) {
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
                } ?? JamfCategory.noCategory

                categories = allCategories
                defaultCategoryID = preferred.id
                JamfPreferences.saveDefaultCategory(preferred)
            } catch {
                categories = [JamfCategory.noCategory]
                defaultCategoryID = JamfCategory.noCategory.id
                categoryError = "Boxing Day could not load categories from Jamf Pro. \(error.localizedDescription)"
            }
            isLoadingCategories = false
        }
    }

    private func forgetConnection() {
        do {
            try KeychainStore.removeClientSecret()
            JamfPreferences.remove()
            serverURL = ""
            clientID = ""
            clientSecret = ""
            defaultCategoryID = JamfCategory.noCategory.id
            categories = [JamfCategory.noCategory]
            categoryError = nil
            status = .idle
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}

#Preview {
    JamfSettingsView()
}
