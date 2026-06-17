import MooDeckCore
import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: MooStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionTitle("Workspaces")

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.workspaces) { workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            isSelected: workspace.id == store.selectedWorkspaceID
                        ) {
                            store.selectWorkspace(workspace)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 190)

            Divider()
                .overlay(MooColors.hairline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            SidebarSectionTitle("Panes")

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.sessions) { session in
                        SessionRow(
                            session: session,
                            isSelected: session.name == store.selectedSessionName
                        ) {
                            store.selectSession(session)
                        }
                    }

                    if store.sessions.isEmpty {
                        EmptySidebarState(title: "No panes")
                            .padding(.top, 18)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .mooGlass()
        .mooHairline(.trailing)
    }
}

struct SidebarSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
    }
}

struct WorkspaceRow: View {
    let workspace: MooWorkspace
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(workspace.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(workspace.sessions)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
            }
            .foregroundStyle(.primary)
            .mooRow(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

struct SessionRow: View {
    let session: MooSession
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(session.attached ? Color.primary : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                    Text(session.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)
            }
            .foregroundStyle(.primary)
            .mooRow(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

struct EmptySidebarState: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
    }
}
