import Darwin
import Foundation

struct JamfConnectionSummary: Equatable {
    let server: String
    let cloudDistributionPoint: String
    let cloudUploadReady: Bool
}

struct JamfCategory: Identifiable, Equatable {
    static let noCategory = JamfCategory(id: "-1", name: "No Category")

    let id: String
    let name: String
}

struct JamfPackageUploadOptions: Equatable {
    var packageName: String
    var fileName: String
    var categoryID: String = "-1"
    var priority: Int = 10
    var notes: String = ""

    var validationError: String? {
        if packageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a package name."
        }
        if fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a package filename."
        }
        if (fileName as NSString).pathExtension.lowercased() != "pkg" {
            return "The uploaded filename must end in .pkg."
        }

        let forbidden = CharacterSet(charactersIn: "/:?<>\\*|\"”[]{}@!%^#")
        if fileName.rangeOfCharacter(from: forbidden) != nil {
            return "The filename contains a character Jamf Pro does not allow."
        }
        if Int(categoryID) == nil {
            return "The category ID must be a number. Use -1 for No Category."
        }
        if !(1...20).contains(priority) {
            return "Package priority must be between 1 and 20."
        }
        return nil
    }
}

struct JamfPackageUploadResult: Equatable {
    let packageID: String
    let fileName: String
    let cloudTransferStatus: String
}

enum JamfUploadStage: Equatable {
    case authenticating
    case checkingForDuplicate
    case creatingRecord
    case preparingUpload
    case uploading
    case refreshingAuthentication
    case processingCloud(String?)
}

enum JamfClientError: LocalizedError {
    case invalidResponse
    case authenticationRejected
    case requestFailed(statusCode: Int, message: String?)
    case missingAccessToken
    case invalidUploadOptions(String)
    case duplicatePackage(fileName: String, packageID: String?)
    case packageRecordCreated(packageID: String, reason: String)
    case packageUploadedStatusUnknown(packageID: String, reason: String)
    case cloudTransferFailed(String)
    case cloudTransferTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Jamf Pro returned an unreadable response."
        case .authenticationRejected:
            return """
            Jamf Pro rejected the API client credentials. Confirm the client \
            is enabled and the client ID and secret are current.
            """
        case .requestFailed(let statusCode, let message):
            let detail = message?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let detail, !detail.isEmpty {
                return "Jamf Pro returned HTTP \(statusCode): \(detail)"
            }
            return "Jamf Pro returned HTTP \(statusCode)."
        case .missingAccessToken:
            return "Jamf Pro authenticated the client but returned no access token."
        case .invalidUploadOptions(let reason):
            return reason
        case .duplicatePackage(let fileName, let packageID):
            let idDetail = packageID.map { " (package ID \($0))" } ?? ""
            return """
            Jamf Pro already contains \(fileName)\(idDetail). Choose a \
            different filename to avoid replacing or duplicating it.
            """
        case .packageRecordCreated(let packageID, let reason):
            return """
            Jamf Pro package record \(packageID) was created, but the file \
            upload did not finish. \(reason)
            """
        case .packageUploadedStatusUnknown(let packageID, let reason):
            return """
            The package was uploaded to Jamf Pro as package ID \(packageID), \
            but Boxing Day could not confirm its final cloud status. \(reason)
            """
        case .cloudTransferFailed(let status):
            return "Jamf Pro reported that cloud processing failed: \(status)."
        case .cloudTransferTimedOut:
            return """
            The file was uploaded, but Jamf Pro did not finish cloud \
            processing within five minutes. Check the package in Jamf Pro.
            """
        }
    }
}

struct JamfClient {
    let configuration: JamfConfiguration
    let clientSecret: String
    var session: URLSession = .shared

    static func cleanupAbandonedUploadBodies() {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        for candidate in contents {
            guard let ownerPID = uploadBodyOwnerPID(candidate),
                  ownerPID != currentPID,
                  !processIsRunning(ownerPID) else {
                continue
            }
            try? fileManager.removeItem(at: candidate)
        }
    }

    func testConnection() async throws -> JamfConnectionSummary {
        let validatedConfiguration = try configuration.validated()
        guard !clientSecret.isEmpty else {
            throw JamfConfigurationError.missingClientSecret
        }

        let token = try await accessToken(
            configuration: validatedConfiguration
        )
        let cloudData = try await authenticatedGET(
            path: "v1/cloud-distribution-point",
            token: token,
            configuration: validatedConfiguration
        )

        // This verifies the Read Packages privilege without mutating Jamf.
        _ = try await authenticatedGET(
            path: "v1/packages?page=0&page-size=1",
            token: token,
            configuration: validatedConfiguration
        )

        // This verifies the category privileges used by the upload picker.
        _ = try await authenticatedGET(
            path: "v1/categories",
            queryItems: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "1")
            ],
            token: token,
            configuration: validatedConfiguration
        )

        let cloudType = try Self.cloudDistributionPointType(
            from: cloudData
        )
        return JamfConnectionSummary(
            server: try validatedConfiguration
                .normalizedBaseURL()
                .host(percentEncoded: false) ?? validatedConfiguration.serverURL,
            cloudDistributionPoint: Self.displayName(for: cloudType),
            cloudUploadReady: cloudType.uppercased() != "NONE"
        )
    }

    func categories() async throws -> [JamfCategory] {
        let validatedConfiguration = try configuration.validated()
        guard !clientSecret.isEmpty else {
            throw JamfConfigurationError.missingClientSecret
        }

        let token = try await accessToken(
            configuration: validatedConfiguration
        )
        let pageSize = 100
        var page = 0
        var categories: [JamfCategory] = []

        while true {
            let data = try await authenticatedGET(
                path: "v1/categories",
                queryItems: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "page-size", value: String(pageSize)),
                    URLQueryItem(name: "sort", value: "name:asc")
                ],
                token: token,
                configuration: validatedConfiguration
            )
            let responsePage = try Self.categoryPage(from: data)
            categories.append(contentsOf: responsePage.categories)

            if responsePage.categories.isEmpty
                || categories.count >= responsePage.totalCount {
                break
            }
            page += 1
        }

        var seenIDs = Set<String>()
        return categories
            .filter { seenIDs.insert($0.id).inserted }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
    }

    func uploadPackage(
        at packageURL: URL,
        options: JamfPackageUploadOptions,
        stageChanged: @escaping (JamfUploadStage) -> Void,
        progressChanged: @escaping (Double) -> Void
    ) async throws -> JamfPackageUploadResult {
        let validatedConfiguration = try configuration.validated()
        guard !clientSecret.isEmpty else {
            throw JamfConfigurationError.missingClientSecret
        }
        if let validationError = options.validationError {
            throw JamfClientError.invalidUploadOptions(validationError)
        }
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw JamfClientError.invalidUploadOptions(
                "The package file no longer exists."
            )
        }

        stageChanged(.authenticating)
        let token = try await accessToken(
            configuration: validatedConfiguration
        )

        stageChanged(.checkingForDuplicate)
        if let existingID = try await existingPackageID(
            fileName: options.fileName,
            token: token,
            configuration: validatedConfiguration
        ) {
            throw JamfClientError.duplicatePackage(
                fileName: options.fileName,
                packageID: existingID
            )
        }

        stageChanged(.creatingRecord)
        let packageID = try await createPackageRecord(
            options: options,
            token: token,
            configuration: validatedConfiguration
        )

        do {
            stageChanged(.preparingUpload)
            let multipart = try await Task.detached(priority: .utility) {
                try Self.createMultipartBody(
                    packageURL: packageURL,
                    uploadFileName: options.fileName
                )
            }.value
            defer {
                try? FileManager.default.removeItem(at: multipart.url)
            }

            stageChanged(.uploading)
            progressChanged(0)
            try await uploadMultipartBody(
                multipart,
                packageID: packageID,
                token: token,
                configuration: validatedConfiguration,
                progressChanged: progressChanged
            )
            progressChanged(1)
        } catch {
            throw JamfClientError.packageRecordCreated(
                packageID: packageID,
                reason: error.localizedDescription
            )
        }

        do {
            let finalStatus = try await waitForCloudTransfer(
                packageID: packageID,
                token: token,
                configuration: validatedConfiguration,
                stageChanged: stageChanged
            )
            return JamfPackageUploadResult(
                packageID: packageID,
                fileName: options.fileName,
                cloudTransferStatus: finalStatus
            )
        } catch {
            throw JamfClientError.packageUploadedStatusUnknown(
                packageID: packageID,
                reason: error.localizedDescription
            )
        }
    }

    private func existingPackageID(
        fileName: String,
        token: String,
        configuration: JamfConfiguration
    ) async throws -> String? {
        let data = try await authenticatedGET(
            path: "v1/packages",
            queryItems: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "100"),
                URLQueryItem(
                    name: "filter",
                    value: #"fileName=="\#(fileName)""#
                )
            ],
            token: token,
            configuration: configuration
        )
        return Self.existingPackageID(from: data, fileName: fileName)
    }

    private func createPackageRecord(
        options: JamfPackageUploadOptions,
        token: String,
        configuration: JamfConfiguration
    ) async throws -> String {
        var request = URLRequest(
            url: try configuration.apiURL(path: "v1/packages")
        )
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONEncoder().encode(
            JamfCreatePackageRequest(options: options)
        )

        let data = try await perform(request)
        guard let packageID = Self.packageID(from: data) else {
            throw JamfClientError.invalidResponse
        }
        return packageID
    }

    private func uploadMultipartBody(
        _ multipart: MultipartBody,
        packageID: String,
        token: String,
        configuration: JamfConfiguration,
        progressChanged: @escaping (Double) -> Void
    ) async throws {
        var request = URLRequest(
            url: try configuration.apiURL(
                path: "v1/packages/\(packageID)/upload"
            )
        )
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "multipart/form-data; boundary=\(multipart.boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let (data, response) = try await upload(
            request: request,
            bodyURL: multipart.url,
            progressChanged: progressChanged
        )
        try Self.validate(response: response, data: data)
    }

    private func waitForCloudTransfer(
        packageID: String,
        token: String,
        configuration: JamfConfiguration,
        stageChanged: @escaping (JamfUploadStage) -> Void
    ) async throws -> String {
        var activeToken = token
        var refreshedAuthentication = false

        for _ in 0..<150 {
            let data: Data
            do {
                data = try await authenticatedGET(
                    path: "v1/packages/\(packageID)",
                    token: activeToken,
                    configuration: configuration
                )
            } catch JamfClientError.authenticationRejected
                where !refreshedAuthentication {
                refreshedAuthentication = true
                stageChanged(.refreshingAuthentication)
                activeToken = try await accessToken(
                    configuration: configuration
                )
                continue
            }

            let status = Self.cloudTransferStatus(from: data)
            stageChanged(.processingCloud(status))

            if let status {
                if Self.isSuccessfulCloudTransferStatus(status) {
                    return status
                }
                if Self.isFailedCloudTransferStatus(status) {
                    throw JamfClientError.cloudTransferFailed(status)
                }
            }

            try await Task.sleep(for: .seconds(2))
        }
        throw JamfClientError.cloudTransferTimedOut
    }

    private func accessToken(
        configuration: JamfConfiguration
    ) async throws -> String {
        var request = URLRequest(
            url: try configuration.apiURL(path: "v1/oauth/token")
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(
                name: "client_id",
                value: configuration.normalizedClientID
            ),
            URLQueryItem(name: "client_secret", value: clientSecret)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let data = try await perform(request)
        let response = try JSONDecoder().decode(
            OAuthTokenResponse.self,
            from: data
        )
        guard !response.accessToken.isEmpty else {
            throw JamfClientError.missingAccessToken
        }
        return response.accessToken
    }

    private func authenticatedGET(
        path: String,
        queryItems: [URLQueryItem]? = nil,
        token: String,
        configuration: JamfConfiguration
    ) async throws -> Data {
        var request = URLRequest(
            url: try configuration.apiURL(
                path: path,
                queryItems: queryItems
            )
        )
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return data
    }

    private func upload(
        request: URLRequest,
        bodyURL: URL,
        progressChanged: @escaping (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(
                with: request,
                fromFile: bodyURL
            ) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let response else {
                    continuation.resume(
                        throwing: JamfClientError.invalidResponse
                    )
                    return
                }
                continuation.resume(returning: (data ?? Data(), response))
            }
            task.resume()

            Task {
                while task.state == .running {
                    let fraction = task.progress.fractionCompleted
                    progressChanged(
                        fraction.isFinite
                            ? min(max(fraction, 0), 1)
                            : 0
                    )
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    nonisolated private static func createMultipartBody(
        packageURL: URL,
        uploadFileName: String
    ) throws -> MultipartBody {
        let boundary = "BoxingDay-\(UUID().uuidString)"
        let processID = ProcessInfo.processInfo.processIdentifier
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BoxingDayUpload-\(processID)-\(UUID().uuidString).multipart"
            )
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil
        ) else {
            throw JamfClientError.invalidUploadOptions(
                "Boxing Day could not prepare the package upload."
            )
        }

        do {
            let output = try FileHandle(forWritingTo: outputURL)
            defer {
                try? output.close()
            }
            let escapedFileName = uploadFileName.replacingOccurrences(
                of: "\"",
                with: "\\\""
            )
            let header =
                "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"file\"; "
                + "filename=\"\(escapedFileName)\"\r\n"
                + "Content-Type: application/octet-stream\r\n"
                + "\r\n"
            try output.write(contentsOf: Data(header.utf8))

            let input = try FileHandle(forReadingFrom: packageURL)
            defer {
                try? input.close()
            }
            while let chunk = try input.read(upToCount: 1_048_576),
                  !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(
                contentsOf: Data("\r\n--\(boundary)--\r\n".utf8)
            )
            return MultipartBody(url: outputURL, boundary: boundary)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func validate(
        response: URLResponse,
        data: Data
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JamfClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw JamfClientError.authenticationRejected
            }
            throw JamfClientError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: errorMessage(from: data)
            )
        }
    }

    static func existingPackageID(
        from data: Data,
        fileName: String
    ) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return findPackageID(in: object, fileName: fileName)
    }

    static func packageID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return stringValue(dictionary["id"])
    }

    static func cloudTransferStatus(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return findString(named: "cloudTransferStatus", in: object)
    }

    static func isSuccessfulCloudTransferStatus(_ status: String) -> Bool {
        ["READY", "COMPLETE", "COMPLETED", "SUCCESS", "AVAILABLE"]
            .contains(status.uppercased())
    }

    static func isFailedCloudTransferStatus(_ status: String) -> Bool {
        let normalized = status.uppercased()
        return normalized.contains("FAIL") || normalized.contains("ERROR")
    }

    static func categoryPage(from data: Data) throws -> JamfCategoryPage {
        guard let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let results = object["results"] as? [[String: Any]] else {
            throw JamfClientError.invalidResponse
        }

        let categories = results.compactMap { result -> JamfCategory? in
            guard let id = stringValue(result["id"]),
                  let name = result["name"] as? String,
                  !name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty else {
                return nil
            }
            return JamfCategory(id: id, name: name)
        }
        let totalCount = (object["totalCount"] as? NSNumber)?.intValue
            ?? categories.count
        return JamfCategoryPage(
            categories: categories,
            totalCount: totalCount
        )
    }

    static func cloudDistributionPointType(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let type = findString(
            named: "cdnType",
            in: object
        ) else {
            throw JamfClientError.invalidResponse
        }
        return type
    }

    static func displayName(for cloudType: String) -> String {
        switch cloudType.uppercased() {
        case "JAMF_CLOUD":
            return "Jamf Cloud"
        case "AMAZON_S3":
            return "Amazon S3"
        case "RACKSPACE_CLOUD_FILES":
            return "Rackspace Cloud Files"
        case "AKAMAI":
            return "Akamai"
        case "NONE":
            return "Not configured"
        default:
            return cloudType
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private static func findPackageID(
        in object: Any,
        fileName: String
    ) -> String? {
        if let dictionary = object as? [String: Any] {
            if let candidateFileName = dictionary["fileName"] as? String,
               candidateFileName.caseInsensitiveCompare(fileName)
                == .orderedSame {
                return stringValue(dictionary["id"])
            }
            for value in dictionary.values {
                if let match = findPackageID(
                    in: value,
                    fileName: fileName
                ) {
                    return match
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let match = findPackageID(
                    in: value,
                    fileName: fileName
                ) {
                    return match
                }
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func uploadBodyOwnerPID(_ url: URL) -> Int32? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(
            separator: "-",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard parts.count == 3,
              parts[0] == "BoxingDayUpload",
              let processID = Int32(parts[1]) else {
            return nil
        }
        return processID
    }

    private static func processIsRunning(_ processID: Int32) -> Bool {
        if kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func findString(
        named key: String,
        in object: Any
    ) -> String? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] as? String {
                return value
            }
            for value in dictionary.values {
                if let match = findString(named: key, in: value) {
                    return match
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let match = findString(named: key, in: value) {
                    return match
                }
            }
        }
        return nil
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let message = findString(named: "message", in: object)
                ?? findString(named: "error_description", in: object)
                ?? findString(named: "error", in: object) {
            return message
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

struct JamfCreatePackageRequest: Encodable {
    let packageName: String
    let fileName: String
    let categoryId: String
    let info: String?
    let notes: String?
    let priority: Int
    let fillUserTemplate = false
    let fillExistingUsers = false
    let swu = false
    let rebootRequired = false
    let selfHealNotify = false
    let osInstall = false
    let suppressUpdates = false
    let ignoreConflicts = false
    let suppressFromDock = false
    let suppressEula = false
    let suppressRegistration = false

    init(options: JamfPackageUploadOptions) {
        packageName = options.packageName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        fileName = options.fileName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        categoryId = options.categoryID
        info = nil
        notes = options.notes.isEmpty ? nil : options.notes
        priority = options.priority
    }
}

private struct MultipartBody {
    let url: URL
    let boundary: String
}

struct JamfCategoryPage: Equatable {
    let categories: [JamfCategory]
    let totalCount: Int
}
