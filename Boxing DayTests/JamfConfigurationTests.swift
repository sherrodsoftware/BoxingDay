import Foundation
import XCTest
@testable import Boxing_Day

final class JamfConfigurationTests: XCTestCase {
    func testNormalizesJamfCloudURL() throws {
        let configuration = JamfConfiguration(
            serverURL: " company.jamfcloud.com/ ",
            clientID: " client-id "
        )

        let validated = try configuration.validated()

        XCTAssertEqual(
            validated.serverURL,
            "https://company.jamfcloud.com"
        )
        XCTAssertEqual(validated.clientID, "client-id")
    }

    func testRemovesAccidentalAPISuffix() throws {
        let configuration = JamfConfiguration(
            serverURL: "https://company.jamfcloud.com/api/",
            clientID: "client-id"
        )

        XCTAssertEqual(
            try configuration.normalizedBaseURL().absoluteString,
            "https://company.jamfcloud.com"
        )
    }

    func testRejectsInsecureOrCredentialBearingURLs() {
        XCTAssertThrowsError(
            try JamfConfiguration(
                serverURL: "http://company.example.com",
                clientID: "client-id"
            ).validated()
        )
        XCTAssertThrowsError(
            try JamfConfiguration(
                serverURL: "https://user:password@company.example.com",
                clientID: "client-id"
            ).validated()
        )
    }

    func testBuildsAPIURLWithQueryParameters() throws {
        let configuration = JamfConfiguration(
            serverURL: "https://company.jamfcloud.com",
            clientID: "client-id"
        )

        let url = try configuration.apiURL(
            path: "v1/packages?page=0&page-size=1"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://company.jamfcloud.com/api/v1/packages?page=0&page-size=1"
        )
    }

    func testReadsCloudDistributionPointType() throws {
        let data = Data(
            #"{"configuration":{"cdnType":"JAMF_CLOUD"}}"#.utf8
        )

        XCTAssertEqual(
            try JamfClient.cloudDistributionPointType(from: data),
            "JAMF_CLOUD"
        )
        XCTAssertEqual(
            JamfClient.displayName(for: "JAMF_CLOUD"),
            "Jamf Cloud"
        )
    }
}
