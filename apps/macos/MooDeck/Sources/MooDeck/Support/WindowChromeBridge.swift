import AppKit
import MooDeckCore
import SwiftUI

struct WindowChromeBridge: NSViewRepresentable {
    let style: ChromeStyle

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            WindowChromeApplier.apply(style, to: window)
        }
    }
}

enum WindowChromeApplier {
    static func apply(_ style: ChromeStyle, to window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = style != .native
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = style == .native ? 12 : 18
        window.contentView?.layer?.masksToBounds = true

        switch style {
        case .native:
            window.styleMask.insert(.titled)
            window.styleMask.remove(.fullSizeContentView)
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.toolbarStyle = .automatic
        case .compact:
            window.styleMask.insert(.titled)
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unifiedCompact
        case .borderless:
            window.styleMask.remove(.titled)
            window.styleMask.insert(.resizable)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
    }
}
