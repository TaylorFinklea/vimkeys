import AppKit
import CoreGraphics

/// Bridges the two global coordinate spaces macOS hands VimKeys:
///
/// - **Cocoa / AppKit** (`NSScreen.frame`): origin at the *bottom-left* of
///   the primary display, Y increasing upward.
/// - **Accessibility / Quartz** (`AXFrame`, `kAXFocusedWindow` frames):
///   origin at the *top-left* of the primary display, Y increasing
///   downward.
///
/// The two spaces coincide only on the primary display, so code that
/// intersected an AX rect against an `NSScreen.frame` — or positioned hint
/// badges with raw AX coordinates inside a Cocoa-framed panel — worked on a
/// single monitor but silently broke on secondary displays (badges landed
/// off-window, the wrong screen was picked, visibility filtering culled the
/// wrong targets). These helpers centralize the conversion.
enum ScreenCoordinates {
    /// Flip a rect between Cocoa and AX global space. The transform is its
    /// own inverse (an involution), so the same call converts Cocoa→AX and
    /// AX→Cocoa. `primaryHeight` is the height of the primary (menu-bar)
    /// display — the pivot both spaces share.
    static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Position of an AX-space point inside an overlay panel whose Cocoa
    /// frame is `panelCocoaFrame`, expressed in the panel's top-left
    /// (Y-down) local space — i.e. SwiftUI's `.topLeading` coordinates.
    /// Used to place hint badges at their targets' AX frames regardless of
    /// which display the panel covers. On the primary display this reduces
    /// to the identity (panel AX origin is `(0, 0)`).
    static func pointInPanel(
        axPoint: CGPoint,
        panelCocoaFrame: CGRect,
        primaryHeight: CGFloat
    ) -> CGPoint {
        let panelAX = flip(panelCocoaFrame, primaryHeight: primaryHeight)
        return CGPoint(x: axPoint.x - panelAX.minX, y: axPoint.y - panelAX.minY)
    }

    /// Height of the primary (menu-bar) display — the one anchored at the
    /// Cocoa origin `(0, 0)`. This is the pivot height for `flip`.
    @MainActor
    static var primaryDisplayHeight: CGFloat {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        return primary?.frame.height ?? 0
    }
}
