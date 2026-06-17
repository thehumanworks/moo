import SwiftUI

enum MooColors {
    /// Terminal surface — a near-black neutral so the glass chrome reads as clear.
    static let terminalBackground = Color(red: 0.05, green: 0.05, blue: 0.055)
    static let terminalText = Color(white: 0.90)
    static let terminalDim = Color(white: 0.46)

    /// Monochrome chrome tokens. Selection and borders are plain white at low
    /// opacity so nothing competes with the terminal content.
    static let hairline = Color.white.opacity(0.08)
    static let selection = Color.white.opacity(0.10)
    static let selectionStroke = Color.white.opacity(0.18)
}

extension View {
    /// A clear Liquid Glass chrome surface (macOS 26+) with a frosted-material
    /// fallback. Used for side panels, the toolbar, and floating overlays.
    @ViewBuilder
    func mooGlass(cornerRadius: CGFloat = 0) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// A single 1px hairline drawn on one edge, for clean panel separators.
    func mooHairline(_ edge: Edge) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle()
                .fill(MooColors.hairline)
                .frame(
                    width: (edge == .leading || edge == .trailing) ? 1 : nil,
                    height: (edge == .top || edge == .bottom) ? 1 : nil
                )
        }
    }
}

extension Edge {
    fileprivate var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

extension View {
    /// Selectable list-row chrome: a subtle white fill plus a thin stroke when
    /// selected, nothing when not. Keeps sidebar rows monochrome and quiet.
    func mooRow(isSelected: Bool) -> some View {
        modifier(MooRowStyle(isSelected: isSelected))
    }
}

private struct MooRowStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? MooColors.selection : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isSelected ? MooColors.selectionStroke : Color.clear, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? MooColors.selection : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// A quiet, hairline-bordered text button for toolbar actions.
struct MooChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? MooColors.selection : Color.white.opacity(0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(MooColors.hairline, lineWidth: 1)
                    }
            }
            .contentShape(Rectangle())
    }
}
