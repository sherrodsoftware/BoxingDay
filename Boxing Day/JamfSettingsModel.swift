import Foundation
import Observation

/// Where Settings reads and writes the Jamf Pro connection. The live store
/// uses UserDefaults and the Keychain; tests use an in-memory store so they
/// never touch the real settings.
protocol JamfSettingsStore {
    func loadSettings() -> SavedJamfSettings
    func saveConnection(_ configuration: JamfConfiguration)
    func saveDefaultCategory(_ category: JamfCategory)
    func removeSettings()
    func loadClientSecret() throws -> String?
    func saveClientSecret(_ secret: String) throws
    func removeClientSecret() throws
}

struct LiveJamfSettingsStore: JamfSettingsStore {
    func loadSettings() -> SavedJamfSettings { JamfPreferences.load() }
    func saveConnection(_ configuration: JamfConfiguration) { JamfPreferences.save(configuration) }
    func saveDefaultCategory(_ category: JamfCategory) { JamfPreferences.saveDefaultCategory(category) }
    func removeSettings() { JamfPreferences.remove() }
    func loadClientSecret() throws -> String? { try KeychainStore.loadClientSecret() }
    func saveClientSecret(_ secret: String) throws { try KeychainStore.saveClientSecret(secret) }
    func removeClientSecret() throws { try KeychainStore.removeClientSecret() }
}

enum JamfSettingsStatus: Equatable {
    case idle
    case saved
    case testing
    case connected(JamfConnectionSummary)
    case failure(String)
}

/// Settings' state: the Jamf Pro connection being edited, its status, and
/// the default upload category.
@MainActor
@Observable
final class JamfSettingsModel {
    var serverURL: String
    var clientID: String
    var clientSecret = ""
    var defaultCategoryID: String
    var showingForgetConfirmation = false

    private(set) var categories = [JamfCategory.noCategory]
    private(set) var isLoadingCategories = false
    private(set) var categoryError: String?
    private(set) var status: JamfSettingsStatus = .idle

    @ObservationIgnored private let store: JamfSettingsStore

    init(store: JamfSettingsStore = LiveJamfSettingsStore()) {
        self.store = store
        let saved = store.loadSettings()
        serverURL = saved.serverURL
        clientID = saved.clientID
        defaultCategoryID = saved.defaultCategoryID ?? JamfCategory.noCategory.id
    }

    var hasRequiredValues: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.isEmpty
    }

    var isTesting: Bool {
        status == .testing
    }

    var canSave: Bool {
        hasRequiredValues && !isTesting
    }

    var canReloadCategories: Bool {
        hasRequiredValues && !isLoadingCategories && !isTesting
    }

    // MARK: - Window lifecycle

    /// Reads the secret from the Keychain each time Settings opens, then
    /// loads categories if the connection is complete.
    func settingsDidOpen() {
        do {
            clientSecret = try store.loadClientSecret() ?? ""
        } catch {
            status = .failure(error.localizedDescription)
        }
        loadCategoriesIfPossible()
    }

    /// Forgets the secret once Settings closes, so it isn't kept in memory
    /// while the app runs. It's read from the Keychain again on reopening.
    func settingsDidClose() {
        clientSecret = ""
    }

    // MARK: - Saving and testing

    func save() {
        do {
            let configuration = try currentConfiguration()
            try save(configuration)
            status = .saved
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    func saveAndTest() {
        do {
            let configuration = try currentConfiguration()
            try save(configuration)
            status = .testing

            let clientSecret = clientSecret
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

    func forgetConnection() {
        do {
            try store.removeClientSecret()
            store.removeSettings()
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

    private func currentConfiguration() throws -> JamfConfiguration {
        guard !clientSecret.isEmpty else {
            throw JamfConfigurationError.missingClientSecret
        }
        return try JamfConfiguration(
            serverURL: serverURL,
            clientID: clientID
        ).validated()
    }

    private func save(_ configuration: JamfConfiguration) throws {
        try store.saveClientSecret(clientSecret)
        store.saveConnection(configuration)
        serverURL = configuration.serverURL
        clientID = configuration.clientID
    }

    // MARK: - Categories

    /// Saves a category the user picked. Ignored while categories load,
    /// since loading chooses and saves the default itself.
    func defaultCategoryChanged(to id: String) {
        guard !isLoadingCategories,
              let category = categories.first(where: { $0.id == id })
        else {
            return
        }
        store.saveDefaultCategory(category)
    }

    func loadCategoriesIfPossible() {
        guard let configuration = try? currentConfiguration() else { return }
        loadCategories(using: configuration)
    }

    private func loadCategories(using configuration: JamfConfiguration) {
        isLoadingCategories = true
        categoryError = nil

        let clientSecret = clientSecret
        Task {
            do {
                let loaded = try await JamfClient(
                    configuration: configuration,
                    clientSecret: clientSecret
                ).categories()
                applyLoadedCategories(loaded)
            } catch {
                categories = [JamfCategory.noCategory]
                defaultCategoryID = JamfCategory.noCategory.id
                categoryError = "Boxing Day could not load categories from Jamf Pro. \(error.localizedDescription)"
            }
            isLoadingCategories = false
        }
    }

    /// Shows loaded categories and selects the saved default among them,
    /// falling back to No Category, then saves that choice.
    func applyLoadedCategories(_ loaded: [JamfCategory]) {
        let allCategories = [JamfCategory.noCategory] + loaded
        let preferred = JamfPreferences.preferredCategory(
            in: allCategories,
            saved: store.loadSettings()
        ) ?? JamfCategory.noCategory

        categories = allCategories
        defaultCategoryID = preferred.id
        store.saveDefaultCategory(preferred)
    }
}
