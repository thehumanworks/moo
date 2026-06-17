import Foundation
import XCTest
@testable import MooDeckCore

final class LocalMooClientIntegrationTests: XCTestCase {
    func testLocalClientDrivesRealMooCLI() async throws {
        guard let mooBin = ProcessInfo.processInfo.environment["MOO_BIN"], !mooBin.isEmpty else {
            throw XCTSkip("Set MOO_BIN to run the real moo CLI integration test.")
        }

        let runtimeDir = URL(fileURLWithPath: "/tmp/md-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeDir) }

        let client = LocalMooClient(
            binary: URL(fileURLWithPath: mooBin),
            environment: ["MOO_DIR": runtimeDir.path]
        )

        try await client.createSession(
            name: "deck-smoke",
            workspace: "deck",
            command: ["/bin/sh", "-c", "printf ready; exec cat"]
        )

        do {
            let sessions = try await client.listSessions(workspace: "deck")
            XCTAssertEqual(sessions.map(\.name), ["deck-smoke"])

            let readyScreen = try await eventuallyPeek(client: client, session: "deck-smoke", workspace: "deck", contains: "ready")
            XCTAssertEqual(readyScreen.session, "deck-smoke")

            try await client.send(text: "from-moodeck", enter: true, session: "deck-smoke", workspace: "deck")
            let sentScreen = try await eventuallyPeek(client: client, session: "deck-smoke", workspace: "deck", contains: "from-moodeck")
            XCTAssertTrue(sentScreen.screen.contains("from-moodeck"))

            let workspaces = try await client.listWorkspaces()
            XCTAssertTrue(workspaces.contains { $0.workspace == "deck" && $0.sessions == 1 })
        } catch {
            try? await client.kill(session: "deck-smoke", workspace: "deck")
            throw error
        }

        try await client.kill(session: "deck-smoke", workspace: "deck")
    }

    private func eventuallyPeek(
        client: LocalMooClient,
        session: String,
        workspace: String,
        contains needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> MooScreen {
        var lastScreen: MooScreen?
        for _ in 0..<20 {
            let screen = try await client.peek(session: session, workspace: workspace)
            if screen.screen.contains(needle) {
                return screen
            }
            lastScreen = screen
            try await Task.sleep(for: .milliseconds(100))
        }

        XCTFail("Screen never contained \(needle). Last screen: \(lastScreen?.screen ?? "-")", file: file, line: line)
        throw MooClientError.invalidOutput(lastScreen?.screen ?? "")
    }
}
