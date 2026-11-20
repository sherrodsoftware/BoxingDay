import Foundation
import XCTest
@testable import Boxing_Day

@MainActor
final class JamfSettingsModelTests: XCTestCase {
    private func store(withSecret secret: String? = nil) -> MemorySettingsStore {
        let store = MemorySettingsStore()
        store.settings.serverURL = "https://example.jamfcloud.com"
        store.settings.clientID = "example-client"
        store.secret = secret
        return store
    }

    // MARK: - Secret

    func testSecretIsReadWhenSettingsOpenAndForgottenWhenItCloses() {
        let store = store(withSecret: "example-secret")
        let model = JamfSettingsModel(store: store)
        XCTAssertEqual(model.clientSecret, "", "Not read until Settings opens")

        model.settingsDidOpen()
        XCTAssertEqual(model.clientSecret, "example-secret")

        model.settingsDidClose()
        XCTAssertEqual(model.clientSecret, "")

        // Reopening reads it from the store again.
        model.settingsDidOpen()
        XCTAssertEqual(model.clientSecret, "example-secret")
        model.settingsDidClose()
    }

    // MARK: - Save availability

    func testSaveNeedsServerClientIDAndSecret() {
        let model = JamfSettingsModel(store: store())
        XCTAssertFalse(model.canSave)

        model.clientSecret = "example-secret"
        XCTAssertTrue(model.canSave)

        model.serverURL = "   "
        XCTAssertFalse(model.canSave, "Whitespace isn't a server")
    }

    func testSaveStoresTheNormalizedConnectionAndSecret() {
        let store = store()
        let model = JamfSettingsModel(store: store)
        model.serverURL = "example.jamfcloud.com/"
        model.clientID = "  example-client  "
        model.clientSecret = "example-secret"

        model.save()

        XCTAssertEqual(model.status, .saved)
        XCTAssertEqual(store.settings.serverURL, "https://example.jamfcloud.com")
        XCTAssertEqual(store.settings.clientID, "example-client")
        XCTAssertEqual(store.secret, "example-secret")
        XCTAssertEqual(model.serverURL, "https://example.jamfcloud.com")
    }

    func testSaveRejectsAnInsecureServer() {
        let store = store()
        let model = JamfSettingsModel(store: store)
        model.serverURL = "http://example.jamfcloud.com"
        model.clientSecret = "example-secret"

        model.save()

        guard case .failure = model.status else {
            return XCTFail("Expected a failure, got \(model.status)")
        }
        XCTAssertNil(store.secret, "Nothing is saved when the connection is invalid")
    }

    // MARK: - Forget

    func testForgetClearsTheConnectionAndStore() {
        let store = store(withSecret: "example-secret")
        let model = JamfSettingsModel(store: store)
        model.settingsDidOpen()

        model.forgetConnection()

        XCTAssertEqual(model.serverURL, "")
        XCTAssertEqual(model.clientID, "")
        XCTAssertEqual(model.clientSecret, "")
        XCTAssertEqual(model.defaultCategoryID, JamfCategory.noCategory.id)
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(store.secret)
        XCTAssertEqual(store.settings.serverURL, "")
    }

    // MARK: - Default category

    func testLoadedCategoriesSelectTheSavedDefault() {
        let store = store()
        store.settings.defaultCategoryID = "7"
        store.settings.defaultCategoryName = "Utilities"
        let model = JamfSettingsModel(store: store)

        model.applyLoadedCategories([
            JamfCategory(id: "3", name: "Browsers"),
            JamfCategory(id: "7", name: "Utilities")
        ])

        XCTAssertEqual(model.defaultCategoryID, "7")
        XCTAssertEqual(model.categories.first, JamfCategory.noCategory)
        XCTAssertEqual(model.categories.count, 3)
    }

    func testRecreatedCategoryIsMatchedByName() {
        let store = store()
        store.settings.defaultCategoryID = "7"
        store.settings.defaultCategoryName = "Utilities"
        let model = JamfSettingsModel(store: store)

        model.applyLoadedCategories([JamfCategory(id: "12", name: "utilities")])

        XCTAssertEqual(model.defaultCategoryID, "12")
        XCTAssertEqual(store.settings.defaultCategoryID, "12")
    }

    func testMissingDefaultFallsBackToNoCategory() {
        let store = store()
        store.settings.defaultCategoryID = "7"
        store.settings.defaultCategoryName = "Retired"
        let model = JamfSettingsModel(store: store)

        model.applyLoadedCategories([JamfCategory(id: "3", name: "Browsers")])

        XCTAssertEqual(model.defaultCategoryID, JamfCategory.noCategory.id)
    }

    func testPickingACategorySavesIt() {
        let store = store()
        let model = JamfSettingsModel(store: store)
        model.applyLoadedCategories([JamfCategory(id: "3", name: "Browsers")])
        store.savedCategories = []

        model.defaultCategoryChanged(to: "3")

        XCTAssertEqual(store.savedCategories, [JamfCategory(id: "3", name: "Browsers")])
    }

    func testPickingAnUnknownCategorySavesNothing() {
        let store = store()
        let model = JamfSettingsModel(store: store)

        model.defaultCategoryChanged(to: "99")

        XCTAssertTrue(store.savedCategories.isEmpty)
    }
}
