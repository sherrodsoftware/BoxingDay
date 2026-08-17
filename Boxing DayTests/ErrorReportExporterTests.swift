import XCTest
@testable import Boxing_Day

final class ErrorReportExporterTests: XCTestCase {
    func testAddsTrailingNewlineToErrorMessage() {
        XCTAssertEqual(
            ErrorReportExporter.text(for: "Something went wrong."),
            "Something went wrong.\n"
        )
    }

    func testDoesNotDuplicateExistingTrailingNewline() {
        XCTAssertEqual(
            ErrorReportExporter.text(for: "Something went wrong.\n"),
            "Something went wrong.\n"
        )
    }
}
