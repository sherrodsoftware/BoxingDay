import Foundation
import Darwin

enum AppResolverError: LocalizedError {
    case unsupportedFileType(String)
    case noAppFound(in: String)
    case multipleAppsFound(in: String, apps: [String])
    case dmgMountFailed(String)
    case multiplePackagesFound(in: String, packages: [String])

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "Unsupported file type: .\(ext). Drop a .app, .dmg, or .zip."
        case .noAppFound(let source):
            return "No .app bundle was found inside \(source)."
        case .multipleAppsFound(let source, let apps):
            let appList = apps.joined(separator: ", ")
            return """
            Multiple .app bundles were found inside \(source): \(appList). \
            Boxing Day needs an archive containing one app.
            """
        case .dmgMountFailed(let reason):
            return "Could not mount the .dmg: \(reason)"
        case .multiplePackagesFound(let source, let packages):
            return "Multiple .pkg files were found inside \(source): \(packages.joined(separator: ", "))."
        }
    }
}

enum ResolvedInput {
    case app(URL)
    case package(URL)
}

/// Resolves dropped files into an app or package, copying archive contents
/// into a fresh temporary workspace so the original source is never modified.
enum AppResolver {

    /// Resolves a dropped item. A disk image containing one installer package
    /// is returned as a package; all other supported inputs resolve to an app.
    static func resolveInput(from sourceURL: URL) throws -> (input: ResolvedInput, workDir: URL?) {
        if sourceURL.pathExtension.lowercased() == "dmg" {
            return try resolveDMGInput(from: sourceURL)
        }

        let result = try resolveApp(from: sourceURL)
        return (.app(result.appURL), result.workDir)
    }

    /// Returns the URL of an .app bundle, and the temp directory it lives in
    /// (caller is responsible for cleaning up the temp directory when done).
    static func resolveApp(from sourceURL: URL) throws -> (appURL: URL, workDir: URL) {
        let ext = sourceURL.pathExtension.lowercased()
        guard ["app", "zip", "dmg"].contains(ext) else {
            throw AppResolverError.unsupportedFileType(ext)
        }

        let workDir = try makeTempDir()

        do {
            switch ext {
            case "app":
                let dest = workDir.appendingPathComponent(sourceURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceURL, to: dest)
                return (dest, workDir)

            case "zip":
                let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
                // ditto handles zips created by macOS (preserves resource forks, symlinks, etc.)
                try ShellRunner.run("/usr/bin/ditto", ["-xk", sourceURL.path, extractDir.path])
                let appURL = try findAppBundle(
                    in: extractDir,
                    sourceName: sourceURL.lastPathComponent
                )
                return (appURL, workDir)

            case "dmg":
                return try resolveFromDMG(sourceURL, workDir: workDir)

            default:
                // The extension was validated before creating the workspace.
                throw AppResolverError.unsupportedFileType(ext)
            }
        } catch {
            removeWorkDir(at: workDir)
            throw error
        }
    }

    /// Removes abandoned workspaces created by Boxing Day processes that are
    /// no longer running. Active workspaces from this or another instance are
    /// left untouched.
    static func cleanupAbandonedWorkDirs() {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        for candidate in contents {
            guard let ownerPID = workDirOwnerPID(candidate),
                  ownerPID != currentPID,
                  !processIsRunning(ownerPID)
            else {
                continue
            }
            removeWorkDir(at: candidate)
        }
    }

    static func removeWorkDir(at workDir: URL) {
        guard isManagedWorkDir(workDir) else { return }
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - DMG handling

    private static func resolveFromDMG(_ dmgURL: URL, workDir: URL) throws -> (appURL: URL, workDir: URL) {
        let mountPoint = workDir.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        var isMounted = false
        defer {
            if isMounted {
                // Best-effort detach; the outer resolver removes the workspace.
                _ = try? ShellRunner.run(
                    "/usr/bin/hdiutil",
                    ["detach", mountPoint.path, "-quiet", "-force"]
                )
            }
        }

        // Attach without mounting in Finder, without user interaction.
        do {
            try ShellRunner.run("/usr/bin/hdiutil", [
                "attach", dmgURL.path,
                "-nobrowse",
                "-noautoopen",
                "-mountpoint", mountPoint.path,
                "-plist"
            ])
            isMounted = true
        } catch {
            // A failed attach can occasionally leave a partial mount behind.
            _ = try? ShellRunner.run(
                "/usr/bin/hdiutil",
                ["detach", mountPoint.path, "-quiet", "-force"]
            )
            throw AppResolverError.dmgMountFailed(error.localizedDescription)
        }

        let appURL = try findAppBundle(
            in: mountPoint,
            sourceName: dmgURL.lastPathComponent
        )

        // Copy the app OUT of the disk image before detaching, into its own
        // location in workDir, since the mount point disappears on detach.
        let copiedDest = workDir.appendingPathComponent(appURL.lastPathComponent)
        try FileManager.default.copyItem(at: appURL, to: copiedDest)

        return (copiedDest, workDir)
    }

    private static func resolveDMGInput(from dmgURL: URL) throws -> (input: ResolvedInput, workDir: URL?) {
        let workDir = try makeTempDir()
        let mountPoint = workDir.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        var isMounted = false
        defer {
            if isMounted {
                _ = try? ShellRunner.run(
                    "/usr/bin/hdiutil",
                    ["detach", mountPoint.path, "-quiet", "-force"]
                )
            }
        }

        do {
            try ShellRunner.run("/usr/bin/hdiutil", [
                "attach", dmgURL.path,
                "-nobrowse",
                "-noautoopen",
                "-mountpoint", mountPoint.path,
                "-plist"
            ])
            isMounted = true

            if let packageURL = try findSinglePackage(
                in: mountPoint,
                sourceName: dmgURL.lastPathComponent
            ) {
                let copiedPackage = workDir.appendingPathComponent(packageURL.lastPathComponent)
                try FileManager.default.copyItem(at: packageURL, to: copiedPackage)
                return (.package(copiedPackage), workDir)
            }

            let appURL = try findAppBundle(in: mountPoint, sourceName: dmgURL.lastPathComponent)
            let copiedApp = workDir.appendingPathComponent(appURL.lastPathComponent)
            try FileManager.default.copyItem(at: appURL, to: copiedApp)
            return (.app(copiedApp), workDir)
        } catch {
            if !isMounted {
                _ = try? ShellRunner.run(
                    "/usr/bin/hdiutil",
                    ["detach", mountPoint.path, "-quiet", "-force"]
                )
            }
            removeWorkDir(at: workDir)
            if error is AppResolverError {
                throw error
            }
            throw AppResolverError.dmgMountFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static func findAppBundle(
        in directory: URL,
        sourceName: String
    ) throws -> URL {
        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            throw AppResolverError.noAppFound(in: sourceName)
        }

        var appURLs: [URL] = []
        for case let candidate as URL in enumerator {
            let values = try candidate.resourceValues(forKeys: Set(resourceKeys))
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  candidate.pathExtension.lowercased() == "app"
            else {
                continue
            }

            appURLs.append(candidate)
            // An app can contain helper apps and frameworks. Once the outer
            // bundle is a candidate, none of its descendants are candidates.
            enumerator.skipDescendants()
        }

        let sortedApps = appURLs.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        guard !sortedApps.isEmpty else {
            throw AppResolverError.noAppFound(in: sourceName)
        }
        guard sortedApps.count == 1 else {
            let baseComponents = directory
                .resolvingSymlinksInPath()
                .pathComponents
            let relativePaths = sortedApps.map {
                $0.resolvingSymlinksInPath()
                    .pathComponents
                    .dropFirst(baseComponents.count)
                    .joined(separator: "/")
            }
            throw AppResolverError.multipleAppsFound(
                in: sourceName,
                apps: relativePaths
            )
        }

        return sortedApps[0]
    }

    static func findSinglePackage(
        in directory: URL,
        sourceName: String
    ) throws -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var packages: [URL] = []
        for case let candidate as URL in enumerator {
            guard candidate.pathExtension.lowercased() == "pkg" else { continue }
            packages.append(candidate)
            if (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
            }
        }

        let sortedPackages = packages.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        guard sortedPackages.count <= 1 else {
            let baseComponents = directory.resolvingSymlinksInPath().pathComponents
            let relativePaths = sortedPackages.map {
                $0.resolvingSymlinksInPath().pathComponents
                    .dropFirst(baseComponents.count)
                    .joined(separator: "/")
            }
            throw AppResolverError.multiplePackagesFound(
                in: sourceName,
                packages: relativePaths
            )
        }
        return sortedPackages.first
    }

    private static func makeTempDir() throws -> URL {
        let processID = ProcessInfo.processInfo.processIdentifier
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AppToPkg-\(processID)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func workDirOwnerPID(_ workDir: URL) -> Int32? {
        let parts = workDir.lastPathComponent.split(
            separator: "-",
            maxSplits: 2,
            omittingEmptySubsequences: true
        )
        guard parts.count == 3,
              parts[0] == "AppToPkg",
              let processID = Int32(parts[1])
        else {
            return nil
        }
        return processID
    }

    private static func processIsRunning(_ processID: Int32) -> Bool {
        if kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private static func isManagedWorkDir(_ workDir: URL) -> Bool {
        guard workDirOwnerPID(workDir) != nil else { return false }

        let expectedParent = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let actualParent = workDir
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return actualParent == expectedParent
    }
}
