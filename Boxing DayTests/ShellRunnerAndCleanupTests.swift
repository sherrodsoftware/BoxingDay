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

    func testCancellationTerminatesRunningCommand() {
        let cancellation = ShellCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            cancellation.cancel()
        }

        let start = Date()
        XCTAssertThrowsError(
            try ShellRunner.run(
                "/bin/sleep",
                ["10"],
                cancellation: cancellation
            )
        ) {
            guard case ShellError.cancelled = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCancelledTokenPreventsLaunch() {
        let cancellation = ShellCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(
            try ShellRunner.run(
                "/usr/bin/true",
                [],
                cancellation: cancellation
            )
        ) {
            guard case ShellError.cancelled = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
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

    func testSharedListingRemovesOnlyAbandonedBoxingDayItems() throws {
        let fileManager = FileManager.default
        let temp = fileManager.temporaryDirectory
        let abandonedPID: Int32 = 2_000_000_000
        let unique = UUID().uuidString

        let abandonedWorkspace = try createManagedWorkspace(processID: abandonedPID)
        let abandonedUpload = temp.appendingPathComponent(
            "BoxingDayUpload-\(abandonedPID)-\(unique).multipart"
        )
        let activeUpload = temp.appendingPathComponent(
            "BoxingDayUpload-\(ProcessInfo.processInfo.processIdentifier)-\(unique).multipart"
        )
        // Another app's items with similar names must never be touched.
        let otherAppFile = temp.appendingPathComponent("OtherApp-\(abandonedPID)-\(unique)")
        for url in [abandonedUpload, activeUpload, otherAppFile] {
            XCTAssertTrue(fileManager.createFile(atPath: url.path, contents: Data()))
        }
        defer {
            for url in [activeUpload, otherAppFile] {
                try? fileManager.removeItem(at: url)
            }
        }

        let names = AppResolver.temporaryDirectoryNames()
        XCTAssertTrue(names.contains(abandonedWorkspace.lastPathComponent))
        AppResolver.cleanupAbandonedWorkDirs(temporaryItemNames: names)
        JamfClient.cleanupAbandonedUploadBodies(temporaryItemNames: names)

        XCTAssertFalse(fileManager.fileExists(atPath: abandonedWorkspace.path))
        XCTAssertFalse(fileManager.fileExists(atPath: abandonedUpload.path))
        XCTAssertTrue(fileManager.fileExists(atPath: activeUpload.path), "Owned by a running process")
        XCTAssertTrue(fileManager.fileExists(atPath: otherAppFile.path), "Not Boxing Day's")
    }

    func testCleanupWithoutAListingStillFindsAbandonedItems() throws {
        let directory = try createManagedWorkspace(processID: 2_000_000_001)

        AppResolver.cleanupAbandonedWorkDirs(temporaryItemNames: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
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

