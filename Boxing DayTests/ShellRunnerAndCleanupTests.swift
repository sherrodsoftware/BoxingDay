import Foundation
import XCTest
@testable import Boxing_Day

final class ShellRunnerTests: XCTestCase {
    func testCapturesStandardOutputAndError() throws {
        let result = try ShellRunner.run(
            "/bin/sh",
            ["-c", "printf output; printf error >&2"]
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "output")
        XCTAssertEqual(result.stderr, "error")
    }

    func testReportsNonZeroExitAndStandardError() {
        XCTAssertThrowsError(
            try ShellRunner.run(
                "/bin/sh",
                ["-c", "printf failure >&2; exit 7"]
            )
        ) {
            guard case ShellError.nonZeroExit(_, let result) = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(result.exitCode, 7)
            XCTAssertEqual(result.stderr, "failure")
        }
    }

    func testReportsLaunchFailure() {
        XCTAssertThrowsError(
            try ShellRunner.run("/path/that/does/not/exist", [])
        ) {
            guard case ShellError.launchFailed = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }
}

final class TemporaryCleanupTests: XCTestCase {
    func testAbandonedWorkspaceIsRemoved() throws {
        let directory = try createManagedWorkspace(processID: 2_000_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        AppResolver.cleanupAbandonedWorkDirs()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testActiveWorkspaceIsPreserved() throws {
        let processID = ProcessInfo.processInfo.processIdentifier
        let directory = try createManagedWorkspace(processID: processID)
        defer { AppResolver.removeWorkDir(at: directory) }

        AppResolver.cleanupAbandonedWorkDirs()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCleanupRefusesUnmanagedDirectory() throws {
        let fixture = try TestWorkspace()

        AppResolver.removeWorkDir(at: fixture.url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    private func createManagedWorkspace(processID: Int32) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppToPkg-\(processID)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

