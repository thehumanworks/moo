import Combine
import Foundation

@MainActor
public final class MooStore: ObservableObject {
    @Published public private(set) var workspaces: [MooWorkspace] = []
    @Published public private(set) var sessions: [MooSession] = []
    @Published public private(set) var screen: MooScreen?
    @Published public private(set) var selectedAgentReport: MooAgentReport?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?
    @Published public var selectedWorkspaceID: String?
    @Published public var selectedSessionName: String?

    private let client: MooClient
    private var pollTimer: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var isPolling = false

    public init(client: MooClient) {
        self.client = client
    }

    deinit {
        pollTimer?.cancel()
        loadTask?.cancel()
    }

    public var selectedWorkspace: MooWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    public var selectedWorkspaceName: String? {
        guard let selectedWorkspace else { return nil }
        return selectedWorkspace.workspace.isEmpty ? nil : selectedWorkspace.workspace
    }

    public var selectedSession: MooSession? {
        sessions.first { $0.name == selectedSessionName }
    }

    public func startAutoRefresh() {
        guard pollTimer == nil else { return }

        pollTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_000))
                await self?.poll()
            }
        }
    }

    public func stopAutoRefresh() {
        pollTimer?.cancel()
        pollTimer = nil
        loadTask?.cancel()
        loadTask = nil
    }

    /// Manual, awaitable structural reload. Supersedes any in-flight load so a
    /// slow or wedged call can never block a fresh request.
    public func refresh() async {
        await beginLoad().value
    }

    public func selectWorkspace(_ workspace: MooWorkspace) {
        guard selectedWorkspaceID != workspace.id else { return }
        selectedWorkspaceID = workspace.id
        selectedSessionName = nil
        sessions = []
        screen = nil
        selectedAgentReport = nil
        _ = beginLoad()
    }

    public func selectSession(_ session: MooSession) {
        guard selectedSessionName != session.name else { return }
        selectedSessionName = session.name
        screen = nil
        selectedAgentReport = nil

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performScreenLoad()
        }
    }

    public func createPane() async {
        await perform {
            let name = Self.generatedName(prefix: "pane")
            try await client.createSession(name: name, workspace: selectedWorkspaceName, command: Self.defaultShellCommand())
        }
    }

    public func createAgent(_ agent: MooAgentKind) async {
        await perform {
            let name = Self.generatedName(prefix: agent.rawValue)
            try await client.createAgent(name: name, agent: agent, workspace: selectedWorkspaceName)
        }
    }

    public func killSelectedPane() async {
        guard let selectedSessionName else { return }
        await perform {
            try await client.kill(session: selectedSessionName, workspace: selectedWorkspaceName)
            self.selectedSessionName = nil
        }
    }

    public func clearError() {
        lastError = nil
    }

    // MARK: - Loading

    @discardableResult
    private func beginLoad() -> Task<Void, Never> {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        isRefreshing = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStructuralLoad(generation: generation)
        }
        loadTask = task
        return task
    }

    private func performStructuralLoad(generation: Int) async {
        // Owned by generation, not by cancellation: a structural load cancelled by
        // `selectSession` (which starts a screen-only load) still clears the flag,
        // while one superseded by a newer `beginLoad` leaves it set for that newer load.
        defer {
            if generation == loadGeneration { isRefreshing = false }
        }

        do {
            let loadedWorkspaces = try await client.listWorkspaces()
            try Task.checkCancellation()
            workspaces = normalizedWorkspaces(loadedWorkspaces)
            selectWorkspaceIfNeeded()

            let loadedSessions = try await client.listSessions(workspace: selectedWorkspaceName)
            try Task.checkCancellation()
            sessions = loadedSessions
            selectSessionIfNeeded()

            try await loadSelectedScreen()
            lastError = nil
        } catch {
            // A superseded load is cancelled mid-flight; its subprocess is killed,
            // so ignore whatever error that produced and let the newer load win.
            if Task.isCancelled { return }
            lastError = error.localizedDescription
        }
    }

    private func performScreenLoad() async {
        do {
            try await loadSelectedScreen()
            lastError = nil
        } catch {
            if Task.isCancelled { return }
            lastError = error.localizedDescription
        }
    }

    private func loadSelectedScreen() async throws {
        guard let target = selectedSessionName else {
            screen = nil
            selectedAgentReport = nil
            return
        }

        let loadedScreen = try await client.peek(session: target, workspace: selectedWorkspaceName)
        try Task.checkCancellation()
        // The selection can change while a peek is in flight (e.g. an overlapping
        // poll); don't write a screen that belongs to a now-deselected session.
        guard selectedSessionName == target else { return }
        screen = loadedScreen

        let report = try? await client.readAgent(session: target, workspace: selectedWorkspaceName)
        guard selectedSessionName == target else { return }
        selectedAgentReport = report
    }

    private func poll() async {
        // Skip while a structural load is running (it already refreshes the screen)
        // and never overlap a previous poll still draining a slow workspace.
        guard !isPolling, !isRefreshing else { return }
        isPolling = true
        defer { isPolling = false }

        do {
            let loadedSessions = try await client.listSessions(workspace: selectedWorkspaceName)
            sessions = loadedSessions
            selectSessionIfNeeded()
            try await loadSelectedScreen()
        } catch {
            // Polling is best-effort; keep the last good state for the next tick.
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Selection helpers

    private func normalizedWorkspaces(_ loaded: [MooWorkspace]) -> [MooWorkspace] {
        if loaded.contains(where: { $0.workspace.isEmpty }) {
            return loaded.sorted(by: Self.workspaceSort)
        }

        return ([MooWorkspace(workspace: "", sessions: 0)] + loaded).sorted(by: Self.workspaceSort)
    }

    private static func workspaceSort(lhs: MooWorkspace, rhs: MooWorkspace) -> Bool {
        if lhs.workspace.isEmpty { return true }
        if rhs.workspace.isEmpty { return false }
        return lhs.workspace.localizedStandardCompare(rhs.workspace) == .orderedAscending
    }

    private func selectWorkspaceIfNeeded() {
        if let selectedWorkspaceID, workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            return
        }
        selectedWorkspaceID = workspaces.first?.id
    }

    private func selectSessionIfNeeded() {
        if let selectedSessionName, sessions.contains(where: { $0.name == selectedSessionName }) {
            return
        }
        selectedSessionName = sessions.first?.name
    }

    private static func generatedName(prefix: String) -> String {
        let value = Int(Date().timeIntervalSince1970 * 1_000)
        return "\(prefix)-\(value)"
    }

    private static func defaultShellCommand() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return [shell, "-l"]
    }
}
