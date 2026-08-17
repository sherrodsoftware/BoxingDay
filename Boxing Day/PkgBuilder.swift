import Foundation

struct PkgOptions {
    var identifier: String
    var version: String
    var installLocation: String = "/Applications"
    /// Optional path to a Developer ID Installer certificate name for signing, e.g.
    /// "Developer ID Installer: Your Name (TEAMID)". Leave nil to skip signing.
    var signingIdentity: String? = nil
}

struct PkgBuildResult {
    var signatureWarning: String?
}

enum AppSignatureStatus: Equatable {
    case valid
    case unsignedOrInvalid(String)
}

enum PkgBuilderError: LocalizedError {
    case couldNotReadBundleInfo(String)
    case couldNotPrepareComponentMetadata(String)
    case stagedCodeSignatureInvalid(String)
    case outputDirectoryNotWritable(String)

    var errorDescription: String? {
        switch self {
        case .couldNotReadBundleInfo(let reason):
            return "Could not read app bundle info: \(reason)"
        case .couldNotPrepareComponentMetadata(let reason):
            return """
            Could not prepare non-relocatable package metadata. The package \
            was not created. \(reason)
            """
        case .stagedCodeSignatureInvalid(let reason):
            return """
            The source app had a valid code signature, but its staged copy \
            failed verification. The package was not created. \(reason)
            """
        case .outputDirectoryNotWritable(let path):
            return "Boxing Day can’t save a package in \(path). Choose a folder you can write to, such as Downloads."
        }
    }
}

enum PkgBuilder {

    /// Reads the version of an app enclosed by an existing installer package.
    /// The Installer package's own version is only a fallback: vendors often
    /// leave that at 1.0 even when the enclosed app has a newer version.
    static func packageVersion(for packageURL: URL) -> String? {
        let expandedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxingDayPackageInfo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: expandedURL) }

        guard (try? ShellRunner.run(
            "/usr/sbin/pkgutil",
            ["--expand-full", packageURL.path, expandedURL.path]
        )) != nil else {
            return nil
        }

        if let appVersion = enclosedAppVersion(in: expandedURL) {
            return appVersion
        }

        // Some packages do not contain an app bundle. In that case, retain
        // the previous best-effort behavior of using Installer metadata.
        let preferredNames = ["PackageInfo", "Distribution"]
        for name in preferredNames {
            guard let enumerator = FileManager.default.enumerator(
                at: expandedURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let candidate as URL in enumerator
                where candidate.lastPathComponent == name {
                guard let manifest = try? String(
                    contentsOf: candidate,
                    encoding: .utf8
                ),
                      let version = versionAttribute(in: manifest)
                else {
                    continue
                }
                return version
            }
        }
        return nil
    }

    private static func enclosedAppVersion(in expandedPackageURL: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: expandedPackageURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var appBundles: [(url: URL, info: [String: Any])] = []
        for case let infoPlistURL as URL in enumerator
            where infoPlistURL.lastPathComponent == "Info.plist" {
            let appURL = infoPlistURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            guard appURL.pathExtension.lowercased() == "app",
                  let data = try? Data(contentsOf: infoPlistURL),
                  let info = try? PropertyListSerialization.propertyList(
                    from: data,
                    format: nil
                  ) as? [String: Any],
                  info["CFBundlePackageType"] as? String == "APPL"
            else {
                continue
            }

            appBundles.append((appURL, info))
        }

        // Some vendors place helper apps within the main app's Contents
        // directory. Their versions are often generic (for example, 1.0), so
        // prefer the outermost app bundle that the package installs.
        for (_, info) in appBundles.sorted(by: {
            $0.url.pathComponents.count < $1.url.pathComponents.count
        }) {
            if let shortVersion = info["CFBundleShortVersionString"] as? String,
               !shortVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return shortVersion
            }
            if let buildVersion = info["CFBundleVersion"] as? String,
               !buildVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return buildVersion
            }
        }
        return nil
    }

    static func filename(for packageURL: URL, appending version: String?) -> String {
        guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty
        else {
            return packageURL.lastPathComponent
        }

        let basename = packageURL.deletingPathExtension().lastPathComponent
        // Vendors often use a filename version that differs slightly from the
        // package manifest (for example, a build suffix). Preserve it instead
        // of creating a confusing second version number.
        if containsVersionNumber(basename) {
            return packageURL.lastPathComponent
        }
        guard basename.range(
            of: version,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == nil else {
            return packageURL.lastPathComponent
        }
        return "\(basename) \(version).pkg"
    }

    /// Renames Boxing Day's temporary copy of an existing package to include
    /// its version. Callers must not use this for the vendor's original file.
    static func appendVersionToCopiedPackage(
        at packageURL: URL,
        version: String?
    ) throws -> URL {
        let filename = filename(for: packageURL, appending: version)
        guard filename != packageURL.lastPathComponent else { return packageURL }

        let renamedURL = packageURL
            .deletingLastPathComponent()
            .appendingPathComponent(filename)
        try FileManager.default.moveItem(at: packageURL, to: renamedURL)
        return renamedURL
    }

    private static func containsVersionNumber(_ filename: String) -> Bool {
        let pattern = #"(?:^|[^A-Za-z0-9])v?\d+(?:\.\d+)+(?:[^A-Za-z0-9]|$)"#
        return (try? NSRegularExpression(pattern: pattern))?.firstMatch(
            in: filename,
            range: NSRange(filename.startIndex..., in: filename)
        ) != nil
    }

    private static func versionAttribute(in manifest: String) -> String? {
        let pattern = #"<(?:pkg-info|pkg-ref)\b[^>]*(?:^|\s)version\s*=\s*\"([^\"]+)\""#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: manifest,
                range: NSRange(manifest.startIndex..., in: manifest)
              ),
              let range = Range(match.range(at: 1), in: manifest)
        else {
            return nil
        }
        return String(manifest[range])
    }

    /// Reads CFBundleIdentifier / CFBundleShortVersionString from the app's
    /// Info.plist to pre-fill sensible defaults for the package identifier/version.
    static func defaultOptions(for appURL: URL) throws -> PkgOptions {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw PkgBuilderError.couldNotReadBundleInfo("Missing or unreadable Info.plist at \(infoPlistURL.path)")
        }

        let bundleID = (plist["CFBundleIdentifier"] as? String) ?? "com.example.unknownapp"
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "1.0"

        return PkgOptions(identifier: "\(bundleID).pkg", version: version)
    }

    /// Stages the app bundle and runs pkgbuild to produce
    /// an installer package at `outputURL`.
    ///
    /// Ownership: we deliberately do NOT try to chown the staged files to
    /// root:wheel ourselves (that would require elevated privileges). Instead
    /// we pass `--ownership recommended` to pkgbuild, which assigns root:wheel
    /// ownership to the installed files automatically at packaging time -
    /// this is exactly the behavior Jamf/macOS installers expect and requires
    /// no sudo prompt from this app.
    static func buildPkg(
        appURL: URL,
        workDir: URL,
        outputURL: URL,
        options: PkgOptions
    ) throws -> PkgBuildResult {
        let outputDirectory = outputURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            throw PkgBuilderError.outputDirectoryNotWritable(outputDirectory.path)
        }

        let sourceSignatureStatus = codeSignatureStatus(for: appURL)

        // 1. Build a staging root that mirrors the install location, e.g.
        //    stagingRoot/Applications/MyApp.app
        let stagingRoot = workDir.appendingPathComponent(
            "staging-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
        }

        let installLocationRelative = options.installLocation.hasPrefix("/")
            ? String(options.installLocation.dropFirst())
            : options.installLocation
        let stagedInstallDir = stagingRoot.appendingPathComponent(installLocationRelative, isDirectory: true)
        try FileManager.default.createDirectory(at: stagedInstallDir, withIntermediateDirectories: true)

        let stagedAppURL = stagedInstallDir.appendingPathComponent(appURL.lastPathComponent)
        try FileManager.default.copyItem(at: appURL, to: stagedAppURL)

        // 2a. Strip quarantine from the app bundle itself. This prevents
        //     macOS from translocating the installed app at launch without
        //     attempting to rewrite protected files within the bundle.
        try removeQuarantine(from: stagedAppURL)

        // 2b. Ensure the top-level app bundle directory is traversable while
        //     preserving the developer's modes for every enclosed item.
        try ShellRunner.run("/bin/chmod", ["755", stagedAppURL.path])

        // 2c. If the source signature was valid, require the staged app to
        //     remain valid after copying and preparation. An unsigned or
        //     already-invalid source is packaged with a visible warning.
        if sourceSignatureStatus == .valid,
           case .unsignedOrInvalid(let reason) = codeSignatureStatus(for: stagedAppURL) {
            throw PkgBuilderError.stagedCodeSignatureInvalid(reason)
        }

        // 3. Analyze every bundle in the staging root and explicitly disable
        //    Installer relocation. Without this metadata, macOS 26 can find
        //    another copy of the app (including Boxing Day's temporary copy)
        //    and update it there instead of installing in /Applications.
        let componentPlistURL = workDir.appendingPathComponent(
            "components-\(UUID().uuidString).plist"
        )
        defer {
            try? FileManager.default.removeItem(at: componentPlistURL)
        }
        try createNonRelocatableComponentPlist(
            stagingRoot: stagingRoot,
            outputURL: componentPlistURL
        )

        // 4. Run pkgbuild. Preserve the enclosed files' modes while
        //    applying recommended ownership recursively to the package payload
        //    (generally root:wheel for an app installed in /Applications).
        var args = [
            "--root", stagingRoot.path,
            "--component-plist", componentPlistURL.path,
            "--identifier", options.identifier,
            "--version", options.version,
            "--install-location", "/",
            "--ownership", "recommended"
        ]

        if let signingIdentity = options.signingIdentity, !signingIdentity.isEmpty {
            args += ["--sign", signingIdentity]
        }

        args.append(outputURL.path)

        try ShellRunner.run("/usr/bin/pkgbuild", args)

        let signatureWarning: String?
        switch sourceSignatureStatus {
        case .valid:
            signatureWarning = nil
        case .unsignedOrInvalid(let reason):
            signatureWarning =
            """
            The source app was unsigned or its code signature was already \
            invalid. The package was created, but signature integrity could \
            not be verified. \(reason)
            """
        }
        return PkgBuildResult(signatureWarning: signatureWarning)
    }

    static func quarantineRemovalArguments(for appURL: URL) -> [String] {
        ["-d", "com.apple.quarantine", appURL.path]
    }

    private static func removeQuarantine(from appURL: URL) throws {
        do {
            try ShellRunner.run(
                "/usr/bin/xattr",
                quarantineRemovalArguments(for: appURL)
            )
        } catch let ShellError.nonZeroExit(_, result)
            where result.stderr.contains("No such xattr") {
            // The app was not quarantined, so there is nothing to remove.
        }
    }

    private static func createNonRelocatableComponentPlist(
        stagingRoot: URL,
        outputURL: URL
    ) throws {
        do {
            try ShellRunner.run(
                "/usr/bin/pkgbuild",
                ["--analyze", "--root", stagingRoot.path, outputURL.path]
            )

            let data = try Data(contentsOf: outputURL)
            guard let components = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [[String: Any]] else {
                throw PkgBuilderError.couldNotPrepareComponentMetadata(
                    "pkgbuild returned an unexpected component property list."
                )
            }

            let nonRelocatableComponents = disableRelocation(in: components)
            let updatedData = try PropertyListSerialization.data(
                fromPropertyList: nonRelocatableComponents,
                format: .xml,
                options: 0
            )
            try updatedData.write(to: outputURL, options: .atomic)
        } catch let error as PkgBuilderError {
            throw error
        } catch {
            throw PkgBuilderError.couldNotPrepareComponentMetadata(
                error.localizedDescription
            )
        }
    }

    private static func disableRelocation(
        in components: [[String: Any]]
    ) -> [[String: Any]] {
        components.map { component in
            var updatedComponent = component
            updatedComponent["BundleIsRelocatable"] = false

            if let children = component["ChildBundles"] as? [[String: Any]] {
                updatedComponent["ChildBundles"] = disableRelocation(
                    in: children
                )
            }

            return updatedComponent
        }
    }

    static func codeSignatureStatus(for appURL: URL) -> AppSignatureStatus {
        do {
            try ShellRunner.run("/usr/bin/codesign", [
                "--verify",
                "--deep",
                "--strict",
                "--verbose=2",
                appURL.path
            ])
            return .valid
        } catch {
            return .unsignedOrInvalid(
                error.localizedDescription
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
