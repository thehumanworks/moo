import Foundation

public enum ChromeStyle: String, CaseIterable, Codable, Identifiable {
    case native
    case compact
    case borderless

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .native: "Native"
        case .compact: "Compact"
        case .borderless: "Borderless"
        }
    }
}

public enum MooAgentKind: String, CaseIterable, Codable, Identifiable {
    case claude
    case codex
    case pi

    public var id: String { rawValue }
}

public struct MooWorkspace: Codable, Equatable, Identifiable {
    public let workspace: String
    public let sessions: Int

    public var id: String { workspace.isEmpty ? "__default__" : workspace }
    public var name: String { workspace }
    public var displayName: String { workspace.isEmpty ? "Default" : workspace }

    public init(workspace: String, sessions: Int) {
        self.workspace = workspace
        self.sessions = sessions
    }
}

public struct MooSession: Codable, Equatable, Identifiable {
    public let name: String
    public let attached: Bool
    public let idleMs: Int
    public let title: String

    public var id: String { name }
    public var displayTitle: String { title.isEmpty ? name : title }

    public init(name: String, attached: Bool, idleMs: Int, title: String) {
        self.name = name
        self.attached = attached
        self.idleMs = idleMs
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case attached
        case idleMs = "idle_ms"
        case title
    }
}

public struct MooCursor: Codable, Equatable {
    public let row: Int
    public let col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }
}

public struct MooScreen: Codable, Equatable {
    public let session: String
    public let title: String
    public let rows: Int
    public let cols: Int
    public let cursor: MooCursor
    public let screen: String

    public var lines: [String] {
        screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    public init(session: String, title: String, rows: Int, cols: Int, cursor: MooCursor, screen: String) {
        self.session = session
        self.title = title
        self.rows = rows
        self.cols = cols
        self.cursor = cursor
        self.screen = screen
    }
}

public struct MooAgentReport: Codable, Equatable {
    public let state: String?
    public let agent: String?

    public init(state: String?, agent: String?) {
        self.state = state
        self.agent = agent
    }
}
