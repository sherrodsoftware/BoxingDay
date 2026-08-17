import XCTest
@testable import Boxing_Day

final class PackageFieldValidatorTests: XCTestCase {
    func testAcceptsTypicalPackageIdentifier() {
        XCTAssertNil(
            PackageFieldValidator.identifierError(
                "com.example.sample.pkg"
            )
        )
    }

    func testRejectsMalformedPackageIdentifiers() {
        XCTAssertNotNil(PackageFieldValidator.identifierError(""))
        XCTAssertNotNil(PackageFieldValidator.identifierError("Granola"))
        XCTAssertNotNil(PackageFieldValidator.identifierError("com..Granola"))
        XCTAssertNotNil(PackageFieldValidator.identifierError("com.example.bad value"))
        XCTAssertNotNil(PackageFieldValidator.identifierError("com.example.-bad"))
    }

    func testAcceptsCommonVersionFormats() {
        XCTAssertNil(PackageFieldValidator.versionError("7.447.2"))
        XCTAssertNil(PackageFieldValidator.versionError("2.0-beta_1+42"))
    }

    func testRejectsUnsafeVersions() {
        XCTAssertNotNil(PackageFieldValidator.versionError(""))
        XCTAssertNotNil(PackageFieldValidator.versionError(" 1.0"))
        XCTAssertNotNil(PackageFieldValidator.versionError("1.0/preview"))
        XCTAssertNotNil(PackageFieldValidator.versionError("1.0 beta"))
    }
}
