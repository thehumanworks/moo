import MooDeckCore
import SwiftUI

struct TerminalPaneView: View {
    @ObservedObject var store: MooStore

    var body: some View {
        VStack(spacing: 0) {
            TerminalHeader(session: store.selectedSession, screen: store.screen)
                .mooHairline(.bottom)

            Group {
                if let session = store.selectedSessionName {
                    SessionTerminalView(session: session, workspace: store.selectedWorkspaceName)
                        .id(identity(of: session))
                } else {
                    TerminalPlaceholder()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MooColors.terminalBackground)
        }
    }

    private func identity(of session: String) -> String {
        "\(store.selectedWorkspaceName ?? "")/\(session)"
    }
}

struct TerminalHeader: View {
    let session: MooSession?
    let screen: MooScreen?

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(session?.attached == true ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)

            Text(session?.name ?? "No pane selected")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(session == nil ? .secondary : .primary)
                .lineLimit(1)

            if let title = screen?.title, !title.isEmpty {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let screen {
                Text("\(screen.cols)×\(screen.rows)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .mooGlass()
    }
}

struct TerminalPlaceholder: View {
    var body: some View {
        Text("Select a pane")
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(MooColors.terminalDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
