import MooDeckCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var store: MooStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PaneDetails(session: store.selectedSession, screen: store.screen)
                    AgentDetails(report: store.selectedAgentReport)

                    if store.selectedSession != nil {
                        Button {
                            Task { await store.killSelectedPane() }
                        } label: {
                            Text("Kill Pane")
                                .font(.callout)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(MooColors.selectionStroke, lineWidth: 1)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .mooGlass()
        .mooHairline(.leading)
    }
}

struct PaneDetails: View {
    let session: MooSession?
    let screen: MooScreen?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Pane")

            InfoRow(label: "Name", value: session?.name ?? "—")
            InfoRow(label: "Title", value: session?.displayTitle ?? "—")
            InfoRow(label: "Attached", value: session?.attached == true ? "Yes" : "No")
            InfoRow(label: "Idle", value: session.map { "\($0.idleMs) ms" } ?? "—")
            InfoRow(label: "Size", value: screen.map { "\($0.cols) × \($0.rows)" } ?? "—")
            InfoRow(label: "Cursor", value: screen.map { "\($0.cursor.col), \($0.cursor.row)" } ?? "—")
        }
    }
}

struct AgentDetails: View {
    let report: MooAgentReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeader(title: "Agent")

            InfoRow(label: "Kind", value: report?.agent ?? "—")
            InfoRow(label: "State", value: report?.state ?? "—")
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
