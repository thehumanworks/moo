import MooDeckCore
import SwiftUI

struct AppToolbar: View {
    @ObservedObject var store: MooStore
    @Binding var chromeStyleRaw: String
    @Binding var agentKind: MooAgentKind

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(store.isRefreshing ? 0.4 : 1)
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh")

            Button("New Pane") {
                Task { await store.createPane() }
            }
            .buttonStyle(MooChipButtonStyle())

            HStack(spacing: 6) {
                Picker("", selection: $agentKind) {
                    ForEach(MooAgentKind.allCases) { agent in
                        Text(agent.rawValue).tag(agent)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 82)
                .help("Agent")

                Button("New Agent") {
                    Task { await store.createAgent(agentKind) }
                }
                .buttonStyle(MooChipButtonStyle())
            }

            Spacer(minLength: 12)

            if let workspace = store.selectedWorkspace {
                Text(workspace.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160, alignment: .trailing)
            }

            Picker("", selection: $chromeStyleRaw) {
                ForEach(ChromeStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 230)
            .help("Window chrome")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
