import Foundation
import XCTest
@testable import Boxing_Day

/// Settings and the upload sheet end to end, against the fake Jamf Pro
/// server and in-memory settings, so nothing real is read or changed.
@MainActor
final class JamfSettingsFlowTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(FakeJamfServer.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(FakeJamfServer.self)
        super.tearDown()
    }

    private func savedStore() -> MemorySettingsStore {
        let store = MemorySettingsStore()
        store.settings.serverURL = "https://\(FakeJamfServer.host)"
        store.settings.clientID = "example-client"
        store.settings.defaultCategoryID = "7"
        store.settings.defaultCategoryName = "Utilities"
        store.secret = "example-secret"
        return store
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Timed out waiting until \(description)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testOpeningFillsTheConnectionAndSelectsTheSavedDefault() async throws {
        let model = JamfSettingsModel(store: savedStore())

        model.settingsDidOpen()
        try await waitUntil("categories load") {
            !model.isLoadingCategories && model.categories.count == 3
        }

        XCTAssertEqual(model.serverURL, "https://\(FakeJamfServer.host)")
        XCTAssertEqual(model.clientID, "example-client")
        XCTAssertEqual(model.clientSecret, "example-secret")
        XCTAssertEqual(model.defaultCategoryID, "7")
        XCTAssertNil(model.categoryError)
    }

    func testSaveAndTestConnectsAndClearingTheClientIDDisablesSave() async throws {
        let model = JamfSettingsModel(store: savedStore())
        model.settingsDidOpen()

        model.saveAndTest()
        XCTAssertEqual(model.status, .testing)
        try await waitUntil("the connection test finishes") {
            model.status != .testing
        }

        XCTAssertEqual(model.status, .connected(JamfConnectionSummary(
            server: FakeJamfServer.host,
            cloudDistributionPoint: "Jamf Cloud",
            cloudUploadReady: true
        )))

        model.clientID = ""
        XCTAssertFalse(model.canSave)
    }

    func testDefaultPickedInSettingsIsPreselectedInTheUploadSheet() async throws {
        let store = savedStore()
        let settings = JamfSettingsModel(store: store)
        settings.settingsDidOpen()
        try await waitUntil("Settings loads categories") {
            !settings.isLoadingCategories && settings.categories.count == 3
        }

        // What the Default Category picker does when you choose Browsers.
        settings.defaultCategoryID = "3"
        settings.defaultCategoryChanged(to: "3")
        settings.settingsDidClose()

        let upload = JamfUploadModel(
            packageURL: URL(fileURLWithPath: "/tmp/Example App 1.0.pkg"),
            store: store
        )
        upload.loadConnection()
        try await waitUntil("the upload sheet loads categories") {
            !upload.isLoadingCategories && upload.categories.count == 3
        }

        XCTAssertEqual(upload.categoryID, "3")
        XCTAssertTrue(upload.canUpload)
    }

    func testForgetLeavesNothingForTheUploadSheet() async throws {
        let store = savedStore()
        let settings = JamfSettingsModel(store: store)
        settings.settingsDidOpen()

        settings.forgetConnection()

        let upload = JamfUploadModel(
            packageURL: URL(fileURLWithPath: "/tmp/Example App 1.0.pkg"),
            store: store
        )
        upload.loadConnection()
        XCTAssertNotNil(upload.configurationError)
        XCTAssertFalse(upload.canUpload)
    }
}
