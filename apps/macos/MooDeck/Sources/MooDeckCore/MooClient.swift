import Foundation

public protocol MooClient {
    func listWorkspaces() async throws -> [MooWorkspace]
    func listSessions(workspace: String?) async throws -> [MooSession]
    func peek(session: String, workspace: String?) async throws -> MooScreen
    func send(text: String, enter: Bool, session: String, workspace: String?) async throws
    func createSession(name: String, workspace: String?, command: [String]) async throws
    func createAgent(name: String, agent: MooAgentKind, workspace: String?) async throws
    func readAgent(session: String, workspace: String?) async throws -> MooAgentReport
    func kill(session: String, workspace: String?) async throws
}

public enum MooClientError: Error, LocalizedError, Equatable {
    case binaryNotFound
    case commandFailed(arguments: [String], exitCode: Int32, stdout: String, stderr: String)
    case invalidOutput(String)
    case timedOut(arguments: [String], seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "Could not find the moo binary. Build the CLI first or set MOO_BIN."
        case let .commandFailed(arguments, exitCode, stdout, stderr):
            "moo \(arguments.joined(separator: " ")) exited \(exitCode): \(stderr.isEmpty ? stdout : stderr)"
        case let .invalidOutput(output):
            "moo returned invalid output: \(output)"
        case let .timedOut(arguments, seconds):
            "moo \(arguments.joined(separator: " ")) timed out after \(String(format: "%.1f", seconds))s"
        }
    }
}

public struct CommandResult: Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol ProcessRunning {
    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> CommandResult
}

public struct ProcessRunner: ProcessRunning {
    private let timeout: Duration

    /// `timeout` bounds how long a single `moo` invocation may block. A wedged
    /// session daemon makes control calls (e.g. `ls`/`peek`) hang forever, so an
    /// upper bound keeps one bad session from freezing every caller.
    public init(timeout: Duration = .seconds(6)) {
        self.timeout = timeout
    }

    public func run(executable: URL, arguments: [String], environment: [String: String] = [:]) async throws -> CommandResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment

        let box = ProcessContinuationBox()
        let seconds = timeout.seconds

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                box.store(continuation)

                process.terminationHandler = { finished in
                    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                    box.resume(returning: CommandResult(
                        stdout: String(decoding: stdoutData, as: UTF8.self),
                        stderr: String(decoding: stderrData, as: UTF8.self),
                        exitCode: finished.terminationStatus
                    ))
                }

                do {
                    try process.run()
                } catch {
                    box.resume(throwing: error)
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    guard process.isRunning else { return }
                    // Resume the awaiting caller before SIGTERM so the timeout wins
                    // the race against `terminationHandler`; the later resume is a no-op.
                    box.resume(throwing: MooClientError.timedOut(arguments: arguments, seconds: seconds))
                    process.terminate()
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

/// Guards a process continuation so exactly one of {success, failure, timeout}
/// resumes it, even though the termination handler and timeout fire on
/// independent queues.
private final class ProcessContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var resumed = false

    func store(_ continuation: CheckedContinuation<CommandResult, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func resume(returning value: CommandResult) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation?.resume(throwing: error)
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
