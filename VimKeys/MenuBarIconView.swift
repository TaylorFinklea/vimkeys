import AppKit
import SwiftUI

/// Menu-bar icon: vim's command prompt (`:_`) — two stacked dots plus a
/// cursor block — as the brand silhouette, matching the app icon. Mode is
/// signalled by swapping the cursor shape (block for NORMAL, vertical
/// I-beam for INSERT, mirroring vim's own modeline) and by opacity / color
/// for off / denied / tap-error states. Intentionally distinct from
/// LayerKeys (rectangular keycap with shelf line) so the two apps don't
/// look identical when sitting side-by-side in the menu bar.
///
/// Variants: `off`, `normal`, `insert`, `denied`, `listenOnly`, `tapError`.
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

    /// Geometry of the brand mark (`:` + cursor block). Centered horizontally
    /// in the 24-unit viewBox with enough negative space that the three
    /// sub-shapes stay distinct after downscaling to 18pt menu-bar size.
    private enum Geometry {
        static let topDotCenter = CGPoint(x: 9, y: 8.5)
        static let bottomDotCenter = CGPoint(x: 9, y: 14.5)
        static let dotRadius: CGFloat = 2.1
        static let cursorRect = CGRect(x: 13.5, y: 13.7, width: 5.0, height: 1.8)
    }

    /// Filled colon dots — the constant half of the brand mark. Variants
    /// stroke or fill this with their own color/opacity.
    private func colonPath() -> Path {
        Path { p in
            p.addEllipse(in: CGRect(
                x: Geometry.topDotCenter.x - Geometry.dotRadius,
                y: Geometry.topDotCenter.y - Geometry.dotRadius,
                width: Geometry.dotRadius * 2, height: Geometry.dotRadius * 2
            ))
            p.addEllipse(in: CGRect(
                x: Geometry.bottomDotCenter.x - Geometry.dotRadius,
                y: Geometry.bottomDotCenter.y - Geometry.dotRadius,
                width: Geometry.dotRadius * 2, height: Geometry.dotRadius * 2
            ))
        }
    }

    /// Horizontal cursor block — the NORMAL-mode cursor, matching the
    /// app-icon brand mark.
    private func cursorBlockPath() -> Path {
        Path(roundedRect: Geometry.cursorRect, cornerRadius: 0.4)
    }

    /// Vertical I-beam line — the INSERT-mode cursor. Same vertical extent
    /// as the colon so the icon's silhouette balance is preserved when the
    /// dots disappear.
    private func insertCursorPath() -> Path {
        Path { p in
            p.move(to: CGPoint(x: 12, y: 6))
            p.addLine(to: CGPoint(x: 12, y: 18))
        }
    }

    private func drawForVariant(in ctx: inout GraphicsContext) {
        let base = variant.drawColor

        switch variant {
        case .off:
            // Full brand mark at reduced opacity — Safari isn't frontmost.
            // Alpha survives template tinting (only the color channel gets
            // replaced), so this reads as a quieter version of NORMAL.
            ctx.fill(colonPath(), with: .color(base.opacity(0.45)))
            ctx.fill(cursorBlockPath(), with: .color(base.opacity(0.45)))

        case .normal:
            // Full brand mark — VimKeys is alive and listening. Mirrors the
            // app icon: filled colon + horizontal cursor block.
            ctx.fill(colonPath(), with: .color(base))
            ctx.fill(cursorBlockPath(), with: .color(base))

        case .insert:
            // Vertical I-beam — vim has stepped aside so the user can type.
            // Colon and block cursor disappear; the thin vertical line is
            // the universal text-input cursor, the same shape vim itself
            // uses to signal INSERT in its modeline.
            ctx.stroke(
                insertCursorPath(),
                with: .color(base),
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
            )

        case .denied:
            // Brand mark + diagonal slash — input monitoring denied. Orange
            // (non-template) so the warning color survives the render.
            ctx.fill(colonPath(), with: .color(base))
            ctx.fill(cursorBlockPath(), with: .color(base))
            let slash = Path { p in
                p.move(to: CGPoint(x: 4.5, y: 4.5))
                p.addLine(to: CGPoint(x: 19.5, y: 19.5))
            }
            ctx.stroke(slash, with: .color(base), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))

        case .listenOnly:
            // Hollow colon (rings) + filled cursor block — partial function.
            // The unfilled dots read as "the prompt is there but quieter",
            // while the cursor stays solid because input is still flowing.
            ctx.stroke(
                colonPath(),
                with: .color(base),
                style: StrokeStyle(lineWidth: 1.0)
            )
            ctx.fill(cursorBlockPath(), with: .color(base))

        case .tapError:
            // ✕ centered — event tap died. Red (non-template).
            let cross = Path { p in
                p.move(to: CGPoint(x: 6.5, y: 7.5)); p.addLine(to: CGPoint(x: 17.5, y: 17.5))
                p.move(to: CGPoint(x: 17.5, y: 7.5)); p.addLine(to: CGPoint(x: 6.5, y: 17.5))
            }
            ctx.stroke(cross, with: .color(base), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
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
    case .disabled, .disabledBySite:
        return (.off, updateAvailable)
    case .insert:
        return (.insert, updateAvailable)
    case .normal, .find, .hint, .vomnibar, .help:
        // .help is transient; treat as normal for icon.
        return (.normal, updateAvailable)
    }
}

/// Display title for the current mode, surfaced in `StatusMenuView`.
extension VimMode {
    var menuTitle: String {
        switch self {
        case .disabled:      return "Off"
        case .disabledBySite: return "Off (this site)"
        case .normal:        return "Normal"
        case .insert:        return "Insert"
        case .find:          return "Find"
        case .hint:          return "Hint"
        case .vomnibar:      return "Vomnibar"
        case .help:          return "Help"
        }
    }
}
