import Foundation

/// Result of running a shell command.
struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum ShellError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(command: String, result: ShellResult)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Failed to launch process: \(reason)"
        case .nonZeroExit(let command, let result):
            let trimmedErr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Command failed (\(result.exitCode)): \(command)\n\(trimmedErr)"
        }
    }
}

/// Thin wrapper around Process for running command-line tools like
/// pkgbuild, hdiutil, ditto, etc. and capturing their output.
enum ShellRunner {

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let result = ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )

        if !result.succeeded {
            let commandDescription = (["/usr/bin/env", launchPath] + arguments).joined(separator: " ")
            throw ShellError.nonZeroExit(command: commandDescription, result: result)
        }

        return result
    }
}
