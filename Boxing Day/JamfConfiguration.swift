import Foundation

struct JamfConfiguration: Equatable {
    var serverURL: String
    var clientID: String

    var normalizedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalizedBaseURL() throws -> URL {
        var candidate = serverURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !candidate.isEmpty else {
            throw JamfConfigurationError.missingServerURL
        }

        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }

        guard var components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false
        else {
            throw JamfConfigurationError.invalidServerURL
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw JamfConfigurationError.invalidServerURL
        }

        components.scheme = "https"
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" || path == "/api" {
            path = ""
        }
        components.path = path

        guard let url = components.url else {
            throw JamfConfigurationError.invalidServerURL
        }
        return url
    }

    func apiURL(path: String) throws -> URL {
        try apiURL(path: path, queryItems: nil)
    }

    func apiURL(
        path: String,
        queryItems: [URLQueryItem]?
    ) throws -> URL {
        let baseURL = try normalizedBaseURL()
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw JamfConfigurationError.invalidServerURL
        }

        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        let apiPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let pathAndQuery = apiPath.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        components.path = "\(basePath)/api/\(pathAndQuery[0])"
        if let queryItems {
            components.queryItems = queryItems
        } else {
            components.percentEncodedQuery = pathAndQuery.count == 2
                ? String(pathAndQuery[1])
                : nil
        }

        guard let url = components.url else {
            throw JamfConfigurationError.invalidServerURL
        }
        return url
    }

    func validated() throws -> JamfConfiguration {
        _ = try normalizedBaseURL()
        guard !normalizedClientID.isEmpty else {
            throw JamfConfigurationError.missingClientID
        }
        return JamfConfiguration(
            serverURL: try normalizedBaseURL().absoluteString,
            clientID: normalizedClientID
        )
    }
}

enum JamfConfigurationError: LocalizedError {
    case missingServerURL
    case invalidServerURL
    case missingClientID
    case missingClientSecret

    var errorDescription: String? {
        switch self {
        case .missingServerURL:
            return "Enter your Jamf Pro server URL."
        case .invalidServerURL:
            return """
            Enter a valid HTTPS Jamf Pro URL, such as \
            https://company.jamfcloud.com.
            """
        case .missingClientID:
            return "Enter the Jamf Pro API client ID."
        case .missingClientSecret:
            return "Enter the Jamf Pro API client secret."
        }
    }
}

struct SavedJamfSettings {
    var serverURL: String
    var clientID: String
    var defaultCategoryID: String?
    var defaultCategoryName: String
}

enum JamfPreferences {
    static let initialDefaultCategory = JamfCategory.noCategory

    private static let serverURLKey = "jamf.serverURL"
    private static let clientIDKey = "jamf.clientID"
    private static let defaultCategoryIDKey = "jamf.defaultCategoryID"
    private static let defaultCategoryNameKey = "jamf.defaultCategoryName"

    static func load() -> SavedJamfSettings {
        let defaults = UserDefaults.standard
        return SavedJamfSettings(
            serverURL: defaults.string(forKey: serverURLKey) ?? "",
            clientID: defaults.string(forKey: clientIDKey) ?? "",
            defaultCategoryID: defaults.string(
                forKey: defaultCategoryIDKey
            ),
            defaultCategoryName: defaults.string(
                forKey: defaultCategoryNameKey
            ) ?? initialDefaultCategory.name
        )
    }

    static func save(_ configuration: JamfConfiguration) {
        let defaults = UserDefaults.standard
        defaults.set(configuration.serverURL, forKey: serverURLKey)
        defaults.set(configuration.clientID, forKey: clientIDKey)
    }

    static func saveDefaultCategory(_ category: JamfCategory) {
        let defaults = UserDefaults.standard
        defaults.set(category.id, forKey: defaultCategoryIDKey)
        defaults.set(category.name, forKey: defaultCategoryNameKey)
    }

    static func remove() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: serverURLKey)
        defaults.removeObject(forKey: clientIDKey)
        defaults.removeObject(forKey: defaultCategoryIDKey)
        defaults.removeObject(forKey: defaultCategoryNameKey)
    }
}
