import Foundation

/// Result of running a shell command.
nonisolated struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

nonisolated enum ShellError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(command: String, result: ShellResult)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .launchFailed(let reason):
            return "Failed to launch process: \(reason)"
        case .nonZeroExit(let command, let result):
            let trimmedErr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Command failed (\(result.exitCode)): \(command)\n\(trimmedErr)"
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}

/// Lets another thread stop a sequence of shell commands. Cancelling
/// terminates the command that is running, and any later run throws
/// `ShellError.cancelled` without launching.
nonisolated final class ShellCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var runningProcess: Process?

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            return runningProcess
        }
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func throwIfCancelled() throws {
        if isCancelled { throw ShellError.cancelled }
    }

    /// Records the running process; returns false if already cancelled.
    fileprivate func register(_ process: Process?) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            runningProcess = process
            return true
        }
    }
}

/// Thin wrapper around Process for running command-line tools like
/// pkgbuild, hdiutil, ditto, etc. and capturing their output.
/// Holds output read on another queue. The DispatchGroup wait orders the
/// write before the read, so no lock is needed.
nonisolated private final class DrainedOutput: @unchecked Sendable {
    var data = Data()
}

nonisolated enum ShellRunner {

    @discardableResult
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        cancellation: ShellCancellation? = nil
    ) throws -> ShellResult {
        try cancellation?.throwIfCancelled()

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
        if let cancellation, !cancellation.register(process) {
            process.terminate()
        }
        defer { _ = cancellation?.register(nil) }

        // Drain stderr concurrently so a child that fills the stderr pipe
        // cannot block while we wait on stdout.
        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrBuffer = DrainedOutput()
        let stderrGroup = DispatchGroup()
        stderrGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBuffer.data = stderrHandle.readDataToEndOfFile()
            stderrGroup.leave()
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stderrGroup.wait()
        let stderrData = stderrBuffer.data
        process.waitUntilExit()

        let result = ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )

        try cancellation?.throwIfCancelled()
        if !result.succeeded {
            let commandDescription = (["/usr/bin/env", launchPath] + arguments).joined(separator: " ")
            throw ShellError.nonZeroExit(command: commandDescription, result: result)
        }

        return result
    }
}
