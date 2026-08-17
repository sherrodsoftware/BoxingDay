import Foundation
@testable import Boxing_Day

final class TestWorkspace {
    let url: URL

    init(function: String = #function) throws {
        let safeFunction = function.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BoxingDayTests-\(safeFunction)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func directory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(
            relativePath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func file(
        _ relativePath: String,
        contents: Data = Data("fixture".utf8)
    ) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL)
        return fileURL
    }

    func app(
        _ relativePath: String,
        bundleIdentifier: String = "com.example.TestApp",
        shortVersion: String? = "1.2.3",
        bundleVersion: String? = "123",
        executable: Bool = false
    ) throws -> URL {
        let appURL = try directory(relativePath)
        let contentsURL = appURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )

        var info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL"
        ]
        if let shortVersion {
            info["CFBundleShortVersionString"] = shortVersion
        }
        if let bundleVersion {
            info["CFBundleVersion"] = bundleVersion
        }

        if executable {
            let executableName = "TestApp"
            info["CFBundleExecutable"] = executableName
            let macOSDirectory = contentsURL.appendingPathComponent(
                "MacOS",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: macOSDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: macOSDirectory.appendingPathComponent(executableName)
            )
        }

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plistData.write(
            to: contentsURL.appendingPathComponent("Info.plist")
        )
        return appURL
    }

    func zip(directory sourceDirectory: URL, name: String) throws -> URL {
        let zipURL = url.appendingPathComponent(name)
        try ShellRunner.run(
            "/usr/bin/ditto",
            ["-c", "-k", sourceDirectory.path, zipURL.path]
        )
        return zipURL
    }
}

