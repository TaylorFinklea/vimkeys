import AppKit
import SwiftUI

/// Menu-bar icon: a bold downward chevron — vim's modal-`v` shape — as the
/// brand silhouette, with mode signalled by stroke weight, opacity, or
/// glyph swap. Intentionally distinct from LayerKeys (rectangular keycap
/// with shelf line) so the two apps don't look identical.
///
/// Variants reached at V-M2: `off`, `normal`, `insert`, `denied`,
/// `listenOnly`, `tapError`. Disabled-by-site / suspended visuals arrive
/// in V-M5.
struct MenuBarIconView: View {
    enum Variant: Equatable {
        case off
        case normal
        case insert
        case denied
        case listenOnly
        case tapError

        /// Color drawn into the rendered NSImage. For template-rendered
        /// variants AppKit replaces the color with the menu-bar text color,
        /// so the value here only needs to be opaque. Colored variants
        /// (denied / tapError) opt out of template rendering and keep
        /// their pixel color.
        var drawColor: Color {
            switch self {
            case .denied:   return .orange
            case .tapError: return .red
            default:        return .black
            }
        }

        /// Monochrome variants render as template images so macOS auto-tints
        /// them for the current menu-bar appearance. Colored variants opt
        /// out so orange / red survive into the rendered image.
        var usesTemplateRendering: Bool {
            switch self {
            case .denied, .tapError: return false
            default:                 return true
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

    /// Rendered point size of the menu-bar image. Matches the frame
    /// `VimKeysApp` applies to the `MenuBarExtra` label.
    private static let pointSize: CGFloat = 18

    /// Native viewBox the paths are authored in. All draw calls happen
    /// in this 24-unit space and the Canvas scales to the actual size.
    private static let viewBox: CGFloat = 24

    let variant: Variant
    let updateBadge: Bool

    var body: some View {
        Image(nsImage: renderedImage())
            .interpolation(.high)
            .accessibilityLabel(variant.accessibilityLabel)
    }

    /// Renders the icon into an NSImage. Template flag is set per variant so
    /// AppKit auto-tints monochrome variants to the menu-bar text color
    /// (white on dark menu bar, black on light) while preserving pixel
    /// color for orange / red signal states.
    @MainActor
    private func renderedImage() -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let renderer = ImageRenderer(content: drawing)
        renderer.scale = scale

        let pointSize = NSSize(width: Self.pointSize, height: Self.pointSize)
        let image = renderer.nsImage ?? NSImage(size: pointSize)
        image.size = pointSize
        image.isTemplate = variant.usesTemplateRendering
        return image
    }

    /// SwiftUI content that ImageRenderer rasterizes. Addressed by
    /// `variant.drawColor` rather than `.primary`, because `.primary`
    /// resolves to a transparent / context-dependent color inside
    /// MenuBarExtra's label and renders as invisible.
    private var drawing: some View {
        Canvas { ctx, size in
            let scale = min(size.width, size.height) / Self.viewBox
            ctx.scaleBy(x: scale, y: scale)

            drawForVariant(in: &ctx)
            if updateBadge { drawUpdateBadge(in: &ctx) }
        }
        .frame(width: Self.pointSize, height: Self.pointSize)
    }

    // MARK: - Drawing primitives

    /// The chevron is the constant brand mark. Helper so several variants
    /// can render it at different weights / alphas without duplicating the
    /// path geometry.
    private func chevronPath() -> Path {
        Path { p in
            p.move(to: CGPoint(x: 5, y: 6.5))
            p.addLine(to: CGPoint(x: 12, y: 18.5))
            p.addLine(to: CGPoint(x: 19, y: 6.5))
        }
    }

    private func drawForVariant(in ctx: inout GraphicsContext) {
        let base = variant.drawColor

        switch variant {
        case .off:
            // Faded chevron — Safari isn't frontmost. Alpha survives
            // template tinting (only the color channel is replaced),
            // so this reads as a quieter version of the same brand mark.
            ctx.stroke(
                chevronPath(),
                with: .color(base.opacity(0.4)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )

        case .normal:
            // Bold chevron — VimKeys is alive and listening.
            ctx.stroke(
                chevronPath(),
                with: .color(base),
                style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round)
            )

        case .insert:
            // I-beam glyph — universal "text cursor" symbol. VimKeys has
            // stepped aside so the user can type. Brand chevron is
            // intentionally absent in this mode: the silhouette itself
            // communicates "you're typing", same way vim's mode-line
            // signals INSERT by replacing the cursor shape.
            let stem = Path { p in
                p.move(to: CGPoint(x: 12, y: 5.5))
                p.addLine(to: CGPoint(x: 12, y: 19.5))
            }
            ctx.stroke(stem, with: .color(base), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            let serifs = Path { p in
                p.move(to: CGPoint(x: 8.5, y: 5.5)); p.addLine(to: CGPoint(x: 15.5, y: 5.5))
                p.move(to: CGPoint(x: 8.5, y: 19.5)); p.addLine(to: CGPoint(x: 15.5, y: 19.5))
            }
            ctx.stroke(serifs, with: .color(base), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        case .denied:
            // Chevron + diagonal slash — denied. Orange (non-template) so
            // the warning color survives.
            ctx.stroke(
                chevronPath(),
                with: .color(base),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
            let slash = Path { p in
                p.move(to: CGPoint(x: 4.5, y: 4.5))
                p.addLine(to: CGPoint(x: 19.5, y: 19.5))
            }
            ctx.stroke(slash, with: .color(base), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        case .listenOnly:
            // Chevron rendered as three dash segments per leg — visually
            // "partial / passive listening". Same brand silhouette but
            // interrupted strokes signal degraded function.
            let stroke = StrokeStyle(lineWidth: 1.9, lineCap: .round)
            let segments = Path { p in
                // Left leg: (5,6.5) → (12,18.5)
                p.move(to: CGPoint(x: 5.7, y: 7.7)); p.addLine(to: CGPoint(x: 7.3, y: 10.4))
                p.move(to: CGPoint(x: 8.6, y: 12.6)); p.addLine(to: CGPoint(x: 10.2, y: 15.3))
                // Right leg: (12,18.5) → (19,6.5)
                p.move(to: CGPoint(x: 13.8, y: 15.3)); p.addLine(to: CGPoint(x: 15.4, y: 12.6))
                p.move(to: CGPoint(x: 16.7, y: 10.4)); p.addLine(to: CGPoint(x: 18.3, y: 7.7))
            }
            ctx.stroke(segments, with: .color(base), style: stroke)

        case .tapError:
            // ✕ centered — event tap died. Red (non-template).
            let cross = Path { p in
                p.move(to: CGPoint(x: 6.5, y: 7.5)); p.addLine(to: CGPoint(x: 17.5, y: 17.5))
                p.move(to: CGPoint(x: 17.5, y: 7.5)); p.addLine(to: CGPoint(x: 6.5, y: 17.5))
            }
            ctx.stroke(cross, with: .color(base), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawUpdateBadge(in ctx: inout GraphicsContext) {
        let color = GraphicsContext.Shading.color(variant.drawColor)
        // Upper-right corner badge: filled disc with a down-arrow punched
        // out via `.destinationOut` so a separate overlay color isn't
        // needed; works for both template and non-template renders.
        let disc = Path(ellipseIn: CGRect(x: 16.5, y: 1.5, width: 6, height: 6))
        ctx.fill(disc, with: color)
        ctx.drawLayer { layer in
            layer.blendMode = .destinationOut
            let arrow = Path { p in
                p.move(to: CGPoint(x: 19.5, y: 2.9))
                p.addLine(to: CGPoint(x: 19.5, y: 6.1))
                p.move(to: CGPoint(x: 18.1, y: 4.7))
                p.addLine(to: CGPoint(x: 19.5, y: 6.2))
                p.addLine(to: CGPoint(x: 20.9, y: 4.7))
            }
            layer.stroke(arrow, with: .color(.black), style: StrokeStyle(lineWidth: 0.95, lineCap: .round, lineJoin: .round))
        }
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
