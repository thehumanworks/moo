import AppKit
import MooDeckCore
import SwiftTerm
import SwiftUI

/// A real terminal (SwiftTerm) that attaches to a moo session by running
/// `moo attach <session>` inside a pseudo-terminal. Keystrokes go straight to
/// the session — there is no separate input field. The view is recreated per
/// session via `.id(...)` upstream, so selecting a pane starts a fresh attach.
struct SessionTerminalView: NSViewRepresentable {
    let session: String
    let workspace: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        applyStyle(to: view)
        startAttach(in: view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        // Tearing down the view (session switch / deselect) ends the attach
        // client; the moo session itself keeps running detached.
        nsView.terminate()
    }

    private func applyStyle(to view: LocalProcessTerminalView) {
        view.nativeBackgroundColor = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.90, alpha: 1)
        view.caretColor = NSColor(white: 0.85, alpha: 1)
        view.font = NSFont(name: "SF Mono", size: 13)
            ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    private func startAttach(in view: LocalProcessTerminalView) {
        guard let binary = MooBinaryResolver.resolve() else { return }

        var args = ["attach", session]
        if let workspace, !workspace.isEmpty {
            args += ["-w", workspace]
        }

        // Pass the launch environment through (MOO_DIR, MOO_BIN, PATH, …) but
        // drop ambient workspace scoping so the explicit `-w` above is the only
        // thing that decides which workspace we attach in.
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment.removeValue(forKey: "MOO_WORKSPACE")
        environment.removeValue(forKey: "MOO")
        let environmentList = environment.map { "\($0.key)=\($0.value)" }

        view.startProcess(executable: binary.path, args: args, environment: environmentList)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {}
    }
}
