import Foundation
import XCTest
@testable import MooDeckCore

/// In-memory MooClient that records calls and can delay per workspace, so tests
/// can simulate a slow or wedged `moo` subprocess without touching the real CLI.
final class MockMooClient: MooClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []

    var workspaces: [MooWorkspace] = []
    var sessionsByWorkspace: [String: [MooSession]] = [:]
    var screensBySession: [String: MooScreen] = [:]
    var agentBySession: [String: MooAgentReport] = [:]
    var delaysByWorkspace: [String: Duration] = [:]
    var peekDelaysBySession: [String: Duration] = [:]

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func callCount(prefix: String) -> Int {
        calls.filter { $0.hasPrefix(prefix) }.count
    }

    private func record(_ entry: String) {
        lock.lock(); _calls.append(entry); lock.unlock()
    }

    func listWorkspaces() async throws -> [MooWorkspace] {
        record("listWorkspaces")
        return workspaces
    }

    func listSessions(workspace: String?) async throws -> [MooSession] {
        let key = workspace ?? ""
        record("listSessions:\(key)")
        if let delay = delaysByWorkspace[key] {
            try await Task.sleep(for: delay)
        }
        return sessionsByWorkspace[key] ?? []
    }

    func peek(session: String, workspace: String?) async throws -> MooScreen {
        record("peek:\(session)")
        if let delay = peekDelaysBySession[session] {
            try await Task.sleep(for: delay)
        }
        return screensBySession[session]
            ?? MooScreen(session: session, title: "", rows: 24, cols: 80, cursor: MooCursor(row: 1, col: 1), screen: "")
    }

    func send(text: String, enter: Bool, session: String, workspace: String?) async throws {
        record("send:\(session):\(text)")
    }

    func createSession(name: String, workspace: String?, command: [String]) async throws {
        record("createSession:\(name)")
    }

    func createAgent(name: String, agent: MooAgentKind, workspace: String?) async throws {
        record("createAgent:\(name)")
    }

    func readAgent(session: String, workspace: String?) async throws -> MooAgentReport {
        record("readAgent:\(session)")
        return agentBySession[session] ?? MooAgentReport(state: nil, agent: nil)
    }

    func kill(session: String, workspace: String?) async throws {
        record("kill:\(session)")
    }
}

@MainActor
final class MooStoreTests: XCTestCase {
    private func makeStore() -> (MooStore, MockMooClient) {
        let mock = MockMooClient()
        mock.workspaces = [
            MooWorkspace(workspace: "", sessions: 3),
            MooWorkspace(workspace: "moo", sessions: 2),
        ]
        mock.sessionsByWorkspace = [
            "": [MooSession(name: "stale", attached: false, idleMs: 0, title: "")],
            "moo": [
                MooSession(name: "one", attached: true, idleMs: 5, title: "Claude"),
                MooSession(name: "codex-moo", attached: false, idleMs: 99, title: "moo"),
            ],
        ]
        return (MooStore(client: mock), mock)
    }

    /// Core regression: a slow/hung load for one workspace must not stop the user
    /// from selecting another workspace and seeing its panes. The default workspace
    /// here never returns (simulating a wedged daemon); selecting "moo" must still
    /// load moo's panes promptly.
    func testSelectingWorkspaceLoadsPanesDespiteHungOtherWorkspace() async throws {
        let (store, mock) = makeStore()
        mock.delaysByWorkspace[""] = .seconds(30) // default workspace "hangs"

        let initial = Task { await store.refresh() }
        defer { initial.cancel() }

        // Wait until the initial load is stuck inside the default workspace listing.
        try await waitUntil { mock.callCount(prefix: "listSessions:") >= 1 }
        let moo = try XCTUnwrap(store.workspaces.first { $0.id == "moo" })

        store.selectWorkspace(moo)

        try await waitUntil { store.sessions.map(\.name) == ["one", "codex-moo"] }
        XCTAssertEqual(store.selectedSessionName, "one")
        XCTAssertFalse(store.isRefreshing, "store should not stay stuck refreshing after the load completes")
    }

    /// Selecting a pane must render it: the store fetches that session's screen.
    func testSelectingSessionLoadsItsScreen() async throws {
        let (store, mock) = makeStore()
        mock.screensBySession["codex-moo"] = MooScreen(
            session: "codex-moo", title: "moo", rows: 24, cols: 80,
            cursor: MooCursor(row: 1, col: 1), screen: "hello from codex-moo"
        )
        let moo = MooWorkspace(workspace: "moo", sessions: 2)
        store.selectWorkspace(moo)
        try await waitUntil { store.sessions.count == 2 }

        let target = try XCTUnwrap(store.sessions.first { $0.name == "codex-moo" })
        store.selectSession(target)

        try await waitUntil { store.screen?.session == "codex-moo" }
        XCTAssertEqual(store.screen?.screen, "hello from codex-moo")
        XCTAssertEqual(store.selectedSessionName, "codex-moo")
    }

    /// Regression: selecting a different pane while the structural load is still
    /// fetching the first pane's screen must not leave `isRefreshing` stuck true
    /// (which would silently kill the periodic poll).
    func testSelectingSessionMidLoadDoesNotWedgeRefreshing() async throws {
        let (store, mock) = makeStore()
        mock.peekDelaysBySession["one"] = .seconds(30) // first pane's screen "hangs"

        let moo = MooWorkspace(workspace: "moo", sessions: 2)
        store.selectWorkspace(moo)

        // Structural load has listed sessions, auto-selected "one", and is now stuck
        // peeking its screen.
        try await waitUntil { mock.callCount(prefix: "peek:one") >= 1 }
        XCTAssertTrue(store.isRefreshing)

        let other = try XCTUnwrap(store.sessions.first { $0.name == "codex-moo" })
        store.selectSession(other)

        try await waitUntil { store.isRefreshing == false }
        XCTAssertEqual(store.selectedSessionName, "codex-moo")
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition not met within \(timeout)", file: file, line: line)
    }
}

final class ProcessRunnerTimeoutTests: XCTestCase {
    func testRunThrowsTimeoutWhenProcessHangs() async throws {
        let runner = ProcessRunner(timeout: .milliseconds(400))
        let start = ContinuousClock.now

        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                environment: [:]
            )
            XCTFail("Expected the hung process to time out")
        } catch let error as MooClientError {
            guard case .timedOut = error else {
                return XCTFail("Expected .timedOut, got \(error)")
            }
        }

        let elapsed = start.duration(to: ContinuousClock.now)
        XCTAssertLessThan(elapsed, .seconds(3), "timeout should fire quickly, not wait for the process")
    }

    func testRunReturnsNormallyForFastProcess() async throws {
        let runner = ProcessRunner(timeout: .seconds(5))
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hi"],
            environment: [:]
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    }
}
