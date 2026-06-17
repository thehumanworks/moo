import MooDeckCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var store: MooStore
    @AppStorage("mooDeckChromeStyle") private var chromeStyleRaw = ChromeStyle.compact.rawValue
    @State private var agentKind = MooAgentKind.codex

    private var chromeStyle: ChromeStyle {
        ChromeStyle(rawValue: chromeStyleRaw) ?? .compact
    }

    var body: some View {
        VStack(spacing: 0) {
            AppToolbar(
                store: store,
                chromeStyleRaw: $chromeStyleRaw,
                agentKind: $agentKind
            )
            .mooGlass()
            .mooHairline(.bottom)

            HStack(spacing: 0) {
                SidebarView(store: store)
                    .frame(width: 248)

                TerminalPaneView(store: store)
                    .frame(minWidth: 460, maxWidth: .infinity)

                InspectorView(store: store)
                    .frame(width: 264)
            }
        }
        .background { backdrop }
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let lastError = store.lastError {
                ErrorBanner(message: lastError) {
                    store.clearError()
                }
                .padding(.bottom, 16)
            }
        }
        .task {
            store.startAutoRefresh()
            await store.refresh()
        }
        .onDisappear {
            store.stopAutoRefresh()
        }
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.12), Color(white: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            WindowChromeBridge(style: chromeStyle)
                .frame(width: 0, height: 0)
        }
        .ignoresSafeArea()
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(message)
                .lineLimit(2)
                .font(.callout)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .mooGlass(cornerRadius: 10)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(MooColors.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
    }
}
