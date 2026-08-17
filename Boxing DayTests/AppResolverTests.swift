import Foundation
import XCTest
@testable import Boxing_Day

final class AppResolverTests: XCTestCase {
    func testResolvesDirectAppIntoManagedWorkspace() throws {
        let fixture = try TestWorkspace()
        let sourceApp = try fixture.app("Direct.app")

        let result = try AppResolver.resolveApp(from: sourceApp)
        defer { AppResolver.removeWorkDir(at: result.workDir) }

        XCTAssertEqual(result.appURL.lastPathComponent, "Direct.app")
        XCTAssertNotEqual(result.appURL, sourceApp)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: result.appURL.appendingPathComponent(
                    "Contents/Info.plist"
                ).path
            )
        )
    }

    func testFindsNestedAppAndIgnoresItsHelperApp() throws {
        let fixture = try TestWorkspace()
        let archiveRoot = try fixture.directory("Archive")
        let outerApp = try fixture.app("Archive/Wrapper/Product.app")
        _ = try fixture.app(
            "Archive/Wrapper/Product.app/Contents/Helpers/Helper.app"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outerApp.path))
        let archive = try fixture.zip(
            directory: archiveRoot,
            name: "Nested.zip"
        )

        let result = try AppResolver.resolveApp(from: archive)
        defer { AppResolver.removeWorkDir(at: result.workDir) }

        XCTAssertEqual(result.appURL.lastPathComponent, "Product.app")
    }

    func testRejectsArchiveContainingMultipleOuterApps() throws {
        let fixture = try TestWorkspace()
        let archiveRoot = try fixture.directory("Archive")
        _ = try fixture.app("Archive/One.app")
        _ = try fixture.app("Archive/Nested/Two.app")
        let archive = try fixture.zip(
            directory: archiveRoot,
            name: "Multiple.zip"
        )

        XCTAssertThrowsError(try AppResolver.resolveApp(from: archive)) {
            guard case AppResolverError.multipleAppsFound(
                let source,
                let apps
            ) = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(source, "Multiple.zip")
            XCTAssertEqual(apps, ["Nested/Two.app", "One.app"])
        }
    }

    func testNoAppFailureLeavesNoManagedWorkspace() throws {
        let fixture = try TestWorkspace()
        let archiveRoot = try fixture.directory("Archive")
        _ = try fixture.file("Archive/readme.txt")
        let archive = try fixture.zip(
            directory: archiveRoot,
            name: "NoApp.zip"
        )
        let before = managedWorkspacesForCurrentProcess()

        XCTAssertThrowsError(try AppResolver.resolveApp(from: archive)) {
            guard case AppResolverError.noAppFound = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }

        XCTAssertEqual(managedWorkspacesForCurrentProcess(), before)
    }

    func testUnsupportedFileDoesNotCreateWorkspace() throws {
        let fixture = try TestWorkspace()
        let input = try fixture.file("Unsupported.txt")
        let before = managedWorkspacesForCurrentProcess()

        XCTAssertThrowsError(try AppResolver.resolveApp(from: input)) {
            guard case AppResolverError.unsupportedFileType("txt") = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }

        XCTAssertEqual(managedWorkspacesForCurrentProcess(), before)
    }

    func testFindsSinglePackageInsideDiskImageContents() throws {
        let fixture = try TestWorkspace()
        let contents = try fixture.directory("DiskImageContents")
        let package = try fixture.file("DiskImageContents/Installer.pkg")

        XCTAssertEqual(
            try AppResolver.findSinglePackage(
                in: contents,
                sourceName: "Installer.dmg"
            )?.resolvingSymlinksInPath(),
            package.resolvingSymlinksInPath()
        )
    }

    func testRejectsDiskImageContentsWithMultiplePackages() throws {
        let fixture = try TestWorkspace()
        let contents = try fixture.directory("DiskImageContents")
        _ = try fixture.file("DiskImageContents/One.pkg")
        _ = try fixture.file("DiskImageContents/Nested/Two.pkg")

        XCTAssertThrowsError(
            try AppResolver.findSinglePackage(
                in: contents,
                sourceName: "Installers.dmg"
            )
        ) {
            guard case AppResolverError.multiplePackagesFound(
                let source,
                let packages
            ) = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(source, "Installers.dmg")
            XCTAssertEqual(packages, ["Nested/Two.pkg", "One.pkg"])
        }
    }

    private func managedWorkspacesForCurrentProcess() -> Set<String> {
        let processID = ProcessInfo.processInfo.processIdentifier
        let prefix = "AppToPkg-\(processID)-"
        let contents = (
            try? FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            )
        ) ?? []
        return Set(
            contents
                .map(\.lastPathComponent)
                .filter { $0.hasPrefix(prefix) }
        )
    }
}
