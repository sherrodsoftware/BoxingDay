import Foundation
@testable import Boxing_Day

/// Keeps settings in memory, so these tests never read or write the real
/// UserDefaults or Keychain.
final class MemorySettingsStore: JamfSettingsStore {
    var settings = SavedJamfSettings(
        serverURL: "",
        clientID: "",
        defaultCategoryID: nil,
        defaultCategoryName: JamfCategory.noCategory.name
    )
    var secret: String?
    var savedCategories: [JamfCategory] = []

    func loadSettings() -> SavedJamfSettings { settings }

    func saveConnection(_ configuration: JamfConfiguration) {
        settings.serverURL = configuration.serverURL
        settings.clientID = configuration.clientID
    }

    func saveDefaultCategory(_ category: JamfCategory) {
        settings.defaultCategoryID = category.id
        settings.defaultCategoryName = category.name
        savedCategories.append(category)
    }

    func removeSettings() {
        settings = SavedJamfSettings(
            serverURL: "",
            clientID: "",
            defaultCategoryID: nil,
            defaultCategoryName: JamfCategory.noCategory.name
        )
    }

    func loadClientSecret() throws -> String? { secret }
    func saveClientSecret(_ secret: String) throws { self.secret = secret }
    func removeClientSecret() throws { secret = nil }
}

/// A fake Jamf Pro server for `https://example.jamfcloud.com`. Requests to
/// that placeholder host are answered here and never reach the network.
final class FakeJamfServer: URLProtocol {
    static let host = "example.jamfcloud.com"
    static let categoriesJSON = """
    {"totalCount": 2, "results": [{"id": "3", "name": "Browsers"}, {"id": "7", "name": "Utilities"}]}
    """

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: String
        switch path {
        case "/api/v1/oauth/token":
            body = #"{"access_token": "example-token", "expires_in": 1200}"#
        case "/api/v1/cloud-distribution-point":
            body = #"{"cdnType": "JAMF_CLOUD"}"#
        case "/api/v1/packages":
            body = #"{"totalCount": 0, "results": []}"#
        case "/api/v1/categories":
            body = Self.categoriesJSON
        default:
            respond(status: 404, body: "{}")
            return
        }
        respond(status: 200, body: body)
    }

    override func stopLoading() {}

    private func respond(status: Int, body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
