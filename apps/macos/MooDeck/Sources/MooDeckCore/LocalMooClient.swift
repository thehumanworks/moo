import Foundation

public struct LocalMooClient: MooClient {
    private let binary: URL?
    private let runner: ProcessRunning
    private let decoder: JSONDecoder
    private let environment: [String: String]

    public init(
        binary: URL? = MooBinaryResolver.resolve(),
        runner: ProcessRunning = ProcessRunner(),
        environment: [String: String] = [:]
    ) {
        self.binary = binary
        self.runner = runner
        self.decoder = JSONDecoder()
        self.environment = environment
    }

    public func listWorkspaces() async throws -> [MooWorkspace] {
        try await decode([ "ws", "--json" ], as: [MooWorkspace].self)
    }

    public func listSessions(workspace: String?) async throws -> [MooSession] {
        try await decode([ "ls" ] + Self.workspaceArguments(workspace) + [ "--json" ], as: [MooSession].self)
    }

    public func peek(session: String, workspace: String?) async throws -> MooScreen {
        try await decode([ "peek", session ] + Self.workspaceArguments(workspace) + [ "--json" ], as: MooScreen.self)
    }

    public func send(text: String, enter: Bool, session: String, workspace: String?) async throws {
        var args = [ "send", session, "--text", text ]
        if enter {
            args.append("--enter")
        }
        args += Self.workspaceArguments(workspace)
        _ = try await run(args)
    }

    public func createSession(name: String, workspace: String?, command: [String]) async throws {
        var args = [ "new", name ] + Self.workspaceArguments(workspace) + [ "-d" ]
        if !command.isEmpty {
            args.append("--")
            args += command
        }
        _ = try await run(args)
    }

    public func createAgent(name: String, agent: MooAgentKind, workspace: String?) async throws {
        let args = [ "new", name ] + Self.workspaceArguments(workspace) + [ "--agent", agent.rawValue, "-d" ]
        _ = try await run(args)
    }

    public func readAgent(session: String, workspace: String?) async throws -> MooAgentReport {
        try await decode([ "read", session ] + Self.workspaceArguments(workspace) + [ "--json" ], as: MooAgentReport.self)
    }

    public func kill(session: String, workspace: String?) async throws {
        _ = try await run([ "kill", session ] + Self.workspaceArguments(workspace))
    }

    public static func workspaceArguments(_ workspace: String?) -> [String] {
        guard let workspace, !workspace.isEmpty else { return [] }
        return [ "-w", workspace ]
    }

    private func decode<T: Decodable>(_ arguments: [String], as type: T.Type) async throws -> T {
        let result = try await run(arguments)
        guard let data = result.stdout.data(using: .utf8) else {
            throw MooClientError.invalidOutput(result.stdout)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MooClientError.invalidOutput(result.stdout)
        }
    }

    private func run(_ arguments: [String]) async throws -> CommandResult {
        guard let binary else {
            throw MooClientError.binaryNotFound
        }

        let result = try await runner.run(executable: binary, arguments: arguments, environment: environment)
        guard result.exitCode == 0 else {
            throw MooClientError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr
            )
        }
        return result
    }
}
