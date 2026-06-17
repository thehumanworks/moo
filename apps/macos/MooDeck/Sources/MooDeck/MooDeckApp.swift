import MooDeckCore
import SwiftUI

@main
struct MooDeckApp: App {
    @StateObject private var store = MooStore(client: LocalMooClient())

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            MooDeckCommands(store: store)
        }
    }
}

struct MooDeckCommands: Commands {
    @ObservedObject var store: MooStore

    var body: some Commands {
        CommandMenu("Moo") {
            Button("Refresh") {
                Task { await store.refresh() }
            }
            .keyboardShortcut("r")

            Button("New Pane") {
                Task { await store.createPane() }
            }
            .keyboardShortcut("n")

            Button("Kill Pane") {
                Task { await store.killSelectedPane() }
            }
            .keyboardShortcut(.delete)
            .disabled(store.selectedSessionName == nil)
        }
    }
}
