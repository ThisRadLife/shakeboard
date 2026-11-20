//
//  GlassStyle.swift
//  ShakeBoard -- one place for the "Liquid Glass" look. macOS 26+ uses SwiftUI's real glassEffect; macOS 14/15
//  falls back to a behind-window NSVisualEffectView material plus a light rim. Reduce Transparency always
//  wins and gets a solid, high-contrast surface. Presentation only: no window hierarchy changes.
//

import SwiftUI
import AppKit

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

enum PerchGlassRole { case panel, card }

// A glass surface for panels/bars/cards.
struct PerchGlass<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    var interactive = false
    var role: PerchGlassRole = .panel
    @EnvironmentObject private var themes: ThemeStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if !themes.current.isSystem {
            let theme = themes.current
            let base = role == .panel ? theme.background.color : theme.card.color
            content
                .background(shape.fill(base).overlay(shape.fill(tint ?? .clear)))
                .overlay(shape.strokeBorder(theme.text.color.opacity(0.12), lineWidth: 1))
        } else if reduceTransparency {
            content
                .background((tint ?? Color(nsColor: .windowBackgroundColor)), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.25), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(VisualEffectBackground(material: .popover).clipShape(shape))
                .background((tint ?? .clear), in: shape)
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: contrast == .increased ? 1.5 : 1))
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g = Glass.regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    func shakeboardGlass(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false,
                    role: PerchGlassRole = .panel) -> some View {
        modifier(PerchGlass(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                            tint: tint, interactive: interactive, role: role))
    }
    func shakeboardGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(PerchGlass(shape: Capsule(style: .continuous), tint: tint, interactive: interactive, role: .card))
    }
}

@MainActor
enum ThemeAppearance {
    static func apply(_ theme: PerchTheme, to window: NSWindow?) {
        window?.appearance = theme.isSystem ? nil : NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
    }
}

enum GlassMetrics {
    static let panelRadius: CGFloat = 22
    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 9
}
