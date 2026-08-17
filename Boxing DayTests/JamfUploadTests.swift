import Foundation
import XCTest
@testable import Boxing_Day

final class JamfUploadTests: XCTestCase {
    func testValidatesUploadMetadata() {
        let valid = JamfPackageUploadOptions(
            packageName: "Example App",
            fileName: "Example App 1.0.pkg"
        )
        XCTAssertNil(valid.validationError)

        var invalid = valid
        invalid.fileName = "Example@1.0.pkg"
        XCTAssertNotNil(invalid.validationError)

        invalid = valid
        invalid.categoryID = "Utilities"
        XCTAssertNotNil(invalid.validationError)
    }

    func testCreatePackageRequestIncludesSafeDefaults() throws {
        let request = JamfCreatePackageRequest(
            options: JamfPackageUploadOptions(
                packageName: "Example App",
                fileName: "Example App 1.0.pkg",
                categoryID: "-1",
                priority: 10,
                notes: "Built by Boxing Day"
            )
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["packageName"] as? String, "Example App")
        XCTAssertEqual(json["fileName"] as? String, "Example App 1.0.pkg")
        XCTAssertEqual(json["categoryId"] as? String, "-1")
        XCTAssertEqual(json["priority"] as? Int, 10)
        XCTAssertEqual(json["rebootRequired"] as? Bool, false)
        XCTAssertEqual(json["osInstall"] as? Bool, false)
        XCTAssertEqual(json["suppressUpdates"] as? Bool, false)
    }

    func testFindsDuplicatePackageByFilename() {
        let data = Data(
            """
            {
              "totalCount": 2,
              "results": [
                {"id": "41", "fileName": "Other.pkg"},
                {"id": "42", "fileName": "Example App.pkg"}
              ]
            }
            """.utf8
        )

        XCTAssertEqual(
            JamfClient.existingPackageID(
                from: data,
                fileName: "example app.pkg"
            ),
            "42"
        )
    }

    func testParsesCreatedPackageIDAndCloudStatus() {
        XCTAssertEqual(
            JamfClient.packageID(from: Data(#"{"id":123}"#.utf8)),
            "123"
        )
        XCTAssertEqual(
            JamfClient.cloudTransferStatus(
                from: Data(
                    #"{"id":"123","cloudTransferStatus":"COMPLETE"}"#.utf8
                )
            ),
            "COMPLETE"
        )
    }

    func testParsesCategoryPage() throws {
        let page = try JamfClient.categoryPage(
            from: Data(
                """
                {
                  "totalCount": 3,
                  "results": [
                    {"id": "7", "name": "Apps", "priority": 10},
                    {"id": 9, "name": "Utilities", "priority": 20}
                  ]
                }
                """.utf8
            )
        )

        XCTAssertEqual(page.totalCount, 3)
        XCTAssertEqual(
            page.categories,
            [
                JamfCategory(id: "7", name: "Apps"),
                JamfCategory(id: "9", name: "Utilities")
            ]
        )
    }

    func testInitialDefaultCategoryIsNoCategory() {
        XCTAssertEqual(
            JamfPreferences.initialDefaultCategory,
            JamfCategory.noCategory
        )
    }

    func testReadyIsACompletedCloudTransferStatus() {
        XCTAssertTrue(
            JamfClient.isSuccessfulCloudTransferStatus("READY")
        )
        XCTAssertTrue(
            JamfClient.isSuccessfulCloudTransferStatus("available")
        )
        XCTAssertFalse(
            JamfClient.isSuccessfulCloudTransferStatus("PROCESSING")
        )
    }

    func testRecognizesFailedCloudTransferStatuses() {
        XCTAssertTrue(
            JamfClient.isFailedCloudTransferStatus("TRANSFER_FAILED")
        )
        XCTAssertTrue(
            JamfClient.isFailedCloudTransferStatus("ERROR")
        )
        XCTAssertFalse(
            JamfClient.isFailedCloudTransferStatus("READY")
        )
    }
}
