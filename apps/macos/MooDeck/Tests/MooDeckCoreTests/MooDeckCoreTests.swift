import Foundation
import XCTest
@testable import MooDeckCore

final class MooDeckCoreTests: XCTestCase {
    func testDecodesMooWorkspaceAndSessionJSON() throws {
        let workspacesJSON = """
        [{"workspace":"","sessions":1},{"workspace":"proj","sessions":2}]
        """.data(using: .utf8)!
        let sessionsJSON = """
        [{"name":"api","attached":false,"idle_ms":42,"title":"zsh"}]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let workspaces = try decoder.decode([MooWorkspace].self, from: workspacesJSON)
        let sessions = try decoder.decode([MooSession].self, from: sessionsJSON)

        XCTAssertEqual(workspaces[0].displayName, "Default")
        XCTAssertEqual(workspaces[1].workspace, "proj")
        XCTAssertEqual(sessions[0].idleMs, 42)
        XCTAssertEqual(sessions[0].displayTitle, "zsh")
    }

    func testDecodesPeekJSON() throws {
        let json = """
        {"session":"api","title":"zsh","rows":24,"cols":80,"cursor":{"row":2,"col":4},"screen":"one\\ntwo"}
        """.data(using: .utf8)!

        let screen = try JSONDecoder().decode(MooScreen.self, from: json)

        XCTAssertEqual(screen.session, "api")
        XCTAssertEqual(screen.cursor.row, 2)
        XCTAssertEqual(screen.lines, ["one", "two"])
    }

    func testWorkspaceArgumentsOnlyIncludeNamedWorkspaces() {
        XCTAssertEqual(LocalMooClient.workspaceArguments(nil), [])
        XCTAssertEqual(LocalMooClient.workspaceArguments(""), [])
        XCTAssertEqual(LocalMooClient.workspaceArguments("proj"), ["-w", "proj"])
    }

    func testBinaryResolverPrefersExplicitMooBin() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = temp.appendingPathComponent("moo")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: bin.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let resolved = MooBinaryResolver.resolve(environment: ["MOO_BIN": bin.path], bundleURL: nil)

        XCTAssertEqual(resolved?.path, bin.path)
    }

    func testBinaryResolverFindsRepoMooBesideDistBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let binDir = root.appendingPathComponent("zig-out/bin", isDirectory: true)
        let distDir = root.appendingPathComponent("dist", isDirectory: true)
        let bundleURL = distDir.appendingPathComponent("MooDeck.app", isDirectory: true)
        let bin = binDir.appendingPathComponent("moo")

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: bin.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = MooBinaryResolver.resolve(environment: [:], bundleURL: bundleURL)

        XCTAssertEqual(resolved?.standardizedFileURL.path, bin.standardizedFileURL.path)
    }
}
