import SwiftUI

/// Menu-bar icon: stylized lowercase "v" inside a keycap silhouette,
/// tinted by `Variant`. V-M1 reaches five variants — `off`, `normal`,
/// `denied`, `listenOnly`, `tapError` — plus a corner badge for "update
/// available". Insert / disabled-by-site / suspended visuals arrive in
/// V-M2 and V-M5; defining them now would ship unused art.
struct MenuBarIconView: View {
    enum Variant: Equatable {
        case off
        case normal
        case insert
        case denied
        case listenOnly
        case tapError

        var tint: Color {
            switch self {
            case .denied:   return .orange
            case .tapError: return .red
            default:        return .primary
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .off:        return "VimKeys, Safari not frontmost"
            case .normal:     return "VimKeys, normal mode active"
            case .insert:     return "VimKeys, insert mode \u{2014} typing into text input"
            case .denied:     return "VimKeys, input monitoring permission denied"
            case .listenOnly: return "VimKeys, listen-only mode \u{2014} scroll bindings disabled"
            case .tapError:   return "VimKeys, event tap error"
            }
        }
    }

    /// Native viewBox the SVG paths are authored in. All draw calls happen
    /// in this 24-unit space and the Canvas scales to the actual size.
    private static let viewBox: CGFloat = 24

    let variant: Variant
    let updateBadge: Bool

    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width, size.height) / Self.viewBox
            ctx.scaleBy(x: scale, y: scale)

            drawCapShell(in: &ctx)
            drawInnerContent(in: &ctx)
            if updateBadge { drawUpdateBadge(in: &ctx) }
        }
        .foregroundStyle(variant.tint)
        .accessibilityLabel(variant.accessibilityLabel)
    }

    private func drawCapShell(in ctx: inout GraphicsContext) {
        let cap = Path(roundedRect: CGRect(x: 3, y: 5, width: 18, height: 14),
                       cornerSize: CGSize(width: 2.5, height: 2.5))
        ctx.stroke(cap, with: .color(variant.tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        let shelf = Path { p in
            p.move(to: CGPoint(x: 3, y: 11))
            p.addLine(to: CGPoint(x: 21, y: 11))
        }
        ctx.stroke(shelf, with: .color(variant.tint), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawInnerContent(in ctx: inout GraphicsContext) {
        switch variant {
        case .off:
            // Single dim dot — Safari isn't frontmost.
            let dot = Path(ellipseIn: CGRect(x: 12 - 0.6, y: 15 - 0.6, width: 1.2, height: 1.2))
            ctx.fill(dot, with: .color(variant.tint.opacity(0.55)))

        case .normal:
            // Lowercase "v" glyph filling the lower face: two strokes
            // converging at the bottom point.
            let stroke = StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
            let v = Path { p in
                p.move(to: CGPoint(x: 9.0, y: 12.5))
                p.addLine(to: CGPoint(x: 12.0, y: 17.8))
                p.addLine(to: CGPoint(x: 15.0, y: 12.5))
            }
            ctx.stroke(v, with: .color(variant.tint), style: stroke)

        case .insert:
            // Same v glyph, plus a small "I" in the lower-left corner so
            // the user knows VimKeys has stepped aside for typing.
            let stroke = StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
            let v = Path { p in
                p.move(to: CGPoint(x: 10.0, y: 13.0))
                p.addLine(to: CGPoint(x: 12.5, y: 17.5))
                p.addLine(to: CGPoint(x: 15.0, y: 13.0))
            }
            ctx.stroke(v, with: .color(variant.tint.opacity(0.55)), style: stroke)
            let iStroke = StrokeStyle(lineWidth: 1.4, lineCap: .round)
            let iBadge = Path { p in
                p.move(to: CGPoint(x: 5.5, y: 13.5)); p.addLine(to: CGPoint(x: 7.5, y: 13.5))
                p.move(to: CGPoint(x: 6.5, y: 13.5)); p.addLine(to: CGPoint(x: 6.5, y: 17.0))
                p.move(to: CGPoint(x: 5.5, y: 17.0)); p.addLine(to: CGPoint(x: 7.5, y: 17.0))
            }
            ctx.stroke(iBadge, with: .color(variant.tint), style: iStroke)

        case .denied:
            // Diagonal slash from (5,6) to (19,18) — denied.
            let slash = Path { p in
                p.move(to: CGPoint(x: 5, y: 6))
                p.addLine(to: CGPoint(x: 19, y: 18))
            }
            ctx.stroke(slash, with: .color(variant.tint), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        case .listenOnly:
            // Six dash segments suggesting partial / passive — same pattern
            // as LayerKeys' listenOnly to keep the visual family.
            let dashStroke = StrokeStyle(lineWidth: 1.7, lineCap: .round)
            let segments = Path { p in
                let xs: [(CGFloat, CGFloat)] = [(6, 8), (11, 13), (16, 18)]
                for y in [CGFloat(14.5), CGFloat(17)] {
                    for (x1, x2) in xs {
                        p.move(to: CGPoint(x: x1, y: y))
                        p.addLine(to: CGPoint(x: x2, y: y))
                    }
                }
            }
            ctx.stroke(segments, with: .color(variant.tint), style: dashStroke)

        case .tapError:
            // ✕ — event tap died.
            let cross = Path { p in
                p.move(to: CGPoint(x: 9,  y: 13.5)); p.addLine(to: CGPoint(x: 15, y: 17.5))
                p.move(to: CGPoint(x: 15, y: 13.5)); p.addLine(to: CGPoint(x: 9,  y: 17.5))
            }
            ctx.stroke(cross, with: .color(variant.tint), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }

    private func drawUpdateBadge(in ctx: inout GraphicsContext) {
        let disc = Path(ellipseIn: CGRect(x: 17, y: 3, width: 6, height: 6))
        ctx.fill(disc, with: .color(variant.tint))

        let arrow = Path { p in
            p.move(to: CGPoint(x: 20,   y: 4.6))
            p.addLine(to: CGPoint(x: 20, y: 7.4))
            p.move(to: CGPoint(x: 18.7, y: 6.2))
            p.addLine(to: CGPoint(x: 20, y: 7.5))
            p.addLine(to: CGPoint(x: 21.3, y: 6.2))
        }
        ctx.stroke(arrow, with: .color(.white), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
    }
}

/// Pure resolver: maps current state to (variant, badge). Every menu-bar
/// state goes through this so tests can exhaustively assert variant
/// priority without spinning up an `AppModel`.
func resolveMenuBarVariant(
    mode: VimMode,
    perm: PermissionState,
    tapErrorActive: Bool,
    updateAvailable: Bool
) -> (variant: MenuBarIconView.Variant, badge: Bool) {
    if tapErrorActive { return (.tapError, false) }
    if perm == .denied { return (.denied, false) }
    if perm == .listenOnly { return (.listenOnly, updateAvailable) }
    switch mode {
    case .disabled:
        return (.off, updateAvailable)
    case .insert:
        return (.insert, updateAvailable)
    case .normal, .find, .hint, .vomnibar, .help:
        // .help is transient; treat as normal for icon. Disabled-by-site
        // and suspended visuals arrive in V-M5.
        return (.normal, updateAvailable)
    }
}

/// Display title for the current mode, surfaced in `StatusMenuView`.
extension VimMode {
    var menuTitle: String {
        switch self {
        case .disabled: return "Off"
        case .normal:   return "Normal"
        case .insert:   return "Insert"
        case .find:     return "Find"
        case .hint:     return "Hint"
        case .vomnibar: return "Vomnibar"
        case .help:     return "Help"
        }
    }
}
