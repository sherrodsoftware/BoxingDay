import Foundation
import XCTest
@testable import Boxing_Day

final class PkgBuilderTests: XCTestCase {
    func testDefaultOptionsUseShortVersion() throws {
        let fixture = try TestWorkspace()
        let app = try fixture.app(
            "Metadata.app",
            bundleIdentifier: "com.example.Metadata",
            shortVersion: "4.5.6",
            bundleVersion: "456"
        )

        let options = try PkgBuilder.defaultOptions(for: app)

        XCTAssertEqual(options.identifier, "com.example.Metadata.pkg")
        XCTAssertEqual(options.version, "4.5.6")
    }

    func testDefaultOptionsFallBackToBundleVersion() throws {
        let fixture = try TestWorkspace()
        let app = try fixture.app(
            "Metadata.app",
            bundleIdentifier: "com.example.Metadata",
            shortVersion: nil,
            bundleVersion: "789"
        )

        let options = try PkgBuilder.defaultOptions(for: app)

        XCTAssertEqual(options.version, "789")
    }

    func testDerivesVersionedFilenameFromEnclosedAppBeforePackageMetadata() throws {
        let fixture = try TestWorkspace()
        let app = try fixture.app("Versioned.app")
        _ = try fixture.app(
            "Versioned.app/Contents/MacOS/Versioned Helper.app",
            shortVersion: "1.0"
        )
        let workDirectory = try fixture.directory("Work")
        let packageURL = fixture.url.appendingPathComponent("Versioned.pkg")
        _ = try PkgBuilder.buildPkg(
            appURL: app,
            workDir: workDirectory,
            outputURL: packageURL,
            options: PkgOptions(
                identifier: "com.example.Versioned.pkg",
                version: "1.0"
            )
        )

        XCTAssertEqual(PkgBuilder.packageVersion(for: packageURL), "1.2.3")
        XCTAssertEqual(
            PkgBuilder.filename(for: packageURL, appending: "1.2.3"),
            "Versioned 1.2.3.pkg"
        )
    }

    func testPreservesFilenameThatAlreadyContainsAVersionNumber() {
        let packageURL = URL(fileURLWithPath: "/tmp/Vendor Installer 1.9.pkg")

        XCTAssertEqual(
            PkgBuilder.filename(for: packageURL, appending: "2.3.4"),
            "Vendor Installer 1.9.pkg"
        )
    }

    func testRenamesCopiedPackageToIncludeItsVersion() throws {
        let fixture = try TestWorkspace()
        let copiedPackage = try fixture.file("Qfinder Pro.pkg")

        let renamedPackage = try PkgBuilder.appendVersionToCopiedPackage(
            at: copiedPackage,
            version: "1.5.0"
        )

        XCTAssertEqual(renamedPackage.lastPathComponent, "Qfinder Pro 1.5.0.pkg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedPackage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedPackage.path))
    }

    func testRemovesQuarantineFromOnlyTheOuterAppBundle() {
        let appURL = URL(fileURLWithPath: "/tmp/Example.app")

        XCTAssertEqual(
            PkgBuilder.quarantineRemovalArguments(for: appURL),
            ["-d", "com.apple.quarantine", appURL.path]
        )
    }

    func testBuildCanBeRepeatedWithoutLeavingStagingDirectories() throws {
        let fixture = try TestWorkspace()
        let app = try fixture.app("Unsigned.app")
        let workDirectory = try fixture.directory("Work")
        let options = PkgOptions(
            identifier: "com.example.Unsigned.pkg",
            version: "1.2.3"
        )

        let firstResult = try PkgBuilder.buildPkg(
            appURL: app,
            workDir: workDirectory,
            outputURL: fixture.url.appendingPathComponent("First.pkg"),
            options: options
        )
        let secondResult = try PkgBuilder.buildPkg(
            appURL: app,
            workDir: workDirectory,
            outputURL: fixture.url.appendingPathComponent("Second.pkg"),
            options: options
        )

        XCTAssertNotNil(firstResult.signatureWarning)
        XCTAssertNotNil(secondResult.signatureWarning)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.url.appendingPathComponent("First.pkg").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.url.appendingPathComponent("Second.pkg").path
            )
        )
        XCTAssertTrue(try stagingDirectories(in: workDirectory).isEmpty)
    }

    func testValidSourceSignatureRemainsValidDuringStaging() throws {
        let fixture = try TestWorkspace()
        let app = try fixture.app("Signed.app", executable: true)
        try ShellRunner.run(
            "/usr/bin/codesign",
            ["--force", "--deep", "--sign", "-", app.path]
        )
        try ShellRunner.run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", app.path]
        )
        let workDirectory = try fixture.directory("Work")

        let result = try PkgBuilder.buildPkg(
            appURL: app,
            workDir: workDirectory,
            outputURL: fixture.url.appendingPathComponent("Signed.pkg"),
            options: PkgOptions(
                identifier: "com.example.Signed.pkg",
                version: "1.0"
            )
        )

        XCTAssertNil(result.signatureWarning)
        XCTAssertTrue(try stagingDirectories(in: workDirectory).isEmpty)
    }

    func testBuiltPackageDisablesBundleRelocation() throws {
        let fixture = try TestWorkspace()
        let app = try fixture.app(
            "FixedPath.app",
            bundleIdentifier: "com.example.FixedPath"
        )
        let workDirectory = try fixture.directory("Work")
        let packageURL = fixture.url.appendingPathComponent("FixedPath.pkg")

        _ = try PkgBuilder.buildPkg(
            appURL: app,
            workDir: workDirectory,
            outputURL: packageURL,
            options: PkgOptions(
                identifier: "com.example.FixedPath.pkg",
                version: "1.0"
            )
        )

        let expandedURL = fixture.url.appendingPathComponent("Expanded")
        try ShellRunner.run(
            "/usr/sbin/pkgutil",
            ["--expand", packageURL.path, expandedURL.path]
        )
        let packageInfo = try String(
            contentsOf: expandedURL.appendingPathComponent("PackageInfo"),
            encoding: .utf8
        )

        XCTAssertTrue(
            packageInfo.contains(
                #"path="./Applications/FixedPath.app""#
            )
        )
        XCTAssertNil(
            packageInfo.range(
                of: #"<relocate>\s*<bundle"#,
                options: .regularExpression
            ),
            "The package must not allow Installer to relocate the app."
        )
        XCTAssertTrue(try temporaryBuildItems(in: workDirectory).isEmpty)
    }

    private func stagingDirectories(in workDirectory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: workDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("staging-root-")
        }
    }

    private func temporaryBuildItems(in workDirectory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: workDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("staging-root-")
                || $0.lastPathComponent.hasPrefix("components-")
        }
    }
}
