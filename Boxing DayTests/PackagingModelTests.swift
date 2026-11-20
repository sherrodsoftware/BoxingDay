import Foundation
import XCTest
@testable import Boxing_Day

/// The menu bar enables its items from these rules, so they're checked here
/// rather than through the menus themselves.
@MainActor
final class PackagingModelMenuTests: XCTestCase {
    private func completedDetails() -> PackageCompletionDetails {
        PackageCompletionDetails(
            url: URL(fileURLWithPath: "/tmp/Example 1.0.pkg"),
            identifier: "com.example.app.pkg",
            version: "1.0",
            installLocation: "/Applications",
            fileSize: nil,
            signatureWarning: nil
        )
    }

    func testIdleModelOnlyOffersOpen() {
        let model = PackagingModel()

        XCTAssertTrue(model.canChooseFile)
        XCTAssertFalse(model.canBuildFromMenu)
        XCTAssertFalse(model.canUpload)
        XCTAssertFalse(model.canRevealCompletedPackage)
    }

    func testCompletedBuildOffersUploadAndReveal() {
        let model = PackagingModel()
        model.status = .success(completedDetails())

        XCTAssertTrue(model.canChooseFile)
        XCTAssertTrue(model.canUpload)
        XCTAssertTrue(model.canRevealCompletedPackage)
    }

    func testWorkInProgressDisablesEveryCommand() {
        for status in [BuildStatus.resolving("Example.dmg"), .building("Example.app")] {
            let model = PackagingModel()
            model.status = status

            XCTAssertFalse(model.canChooseFile, "\(status)")
            XCTAssertFalse(model.canBuildFromMenu, "\(status)")
            XCTAssertFalse(model.canUpload, "\(status)")
            XCTAssertFalse(model.canRevealCompletedPackage, "\(status)")
        }
    }

    func testOpenUploadSheetDisablesEveryCommand() {
        let model = PackagingModel()
        model.status = .success(completedDetails())
        model.showingJamfUpload = true

        XCTAssertFalse(model.canChooseFile)
        XCTAssertFalse(model.canBuildFromMenu)
        XCTAssertFalse(model.canUpload)
        XCTAssertFalse(model.canRevealCompletedPackage)
    }

    func testFailedBuildStillOffersOpen() {
        let model = PackagingModel()
        model.status = .failure("pkgbuild failed")

        XCTAssertTrue(model.canChooseFile)
        XCTAssertFalse(model.canUpload)
        XCTAssertFalse(model.canRevealCompletedPackage)
    }

    func testPresentUploadRequiresAPackage() {
        let model = PackagingModel()
        model.presentUpload()
        XCTAssertFalse(model.showingJamfUpload)

        model.status = .success(completedDetails())
        model.presentUpload()
        XCTAssertTrue(model.showingJamfUpload)
    }
}
