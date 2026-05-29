import AppKit
import SwiftUI

/// Full-screen, non-activating overlay panel that draws hint label badges
/// at each target's AX frame. Mirrors `HelpOverlayWindow`'s "never steal
/// focus" pattern — the global event tap routes keys to the coordinator,
/// the panel just paints.
@MainActor
final class HintOverlayWindow: NSPanel {
    /// View model the SwiftUI content observes. Mutated as the user types;
    /// SwiftUI re-renders only the affected labels.
    final class ViewModel: ObservableObject {
        @Published var labels: [LinkHintEngine.Assignment] = []
        @Published var typedPrefix: String = ""
        @Published var matching: Set<UUID> = []
        /// Top-left of the overlay panel in AX global coordinates. Badge
        /// positions (also AX coords) are made panel-relative by subtracting
        /// this. `(0, 0)` on the primary display; non-zero on any other.
        @Published var panelAXOrigin: CGPoint = .zero
    }

    let viewModel = ViewModel()

    init() {
        super.init(
            contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = NSHostingView(rootView: HintOverlayContent(viewModel: viewModel))
    }

    /// Resize to span the entire screen Safari is on (or main screen) so
    /// label badges can be positioned anywhere a target might live.
    func present(on screen: NSScreen? = nil) {
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let target {
            setFrame(target.frame, display: true)
            // The panel's frame is Cocoa (bottom-left); badge frames are AX
            // (top-left). Record the panel's top-left in AX space so the
            // SwiftUI content can place each badge relative to it — without
            // this the badges only landed correctly on the primary display.
            let panelAX = ScreenCoordinates.flip(
                target.frame,
                primaryHeight: ScreenCoordinates.primaryDisplayHeight
            )
            viewModel.panelAXOrigin = CGPoint(x: panelAX.minX, y: panelAX.minY)
        }
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

/// SwiftUI overlay: a single ZStack of label pills, one per assignment.
/// Each badge's AX frame (top-left origin, global) is made panel-relative
/// by subtracting the panel's AX origin, then placed via `.offset` so the
/// badge's *top-left* sits at the target's top-left. (The previous
/// `.position` anchored the badge's *center* there — a half-badge offset —
/// and ignored the panel origin entirely, so both broke off the primary
/// display.)
private struct HintOverlayContent: View {
    @ObservedObject var viewModel: HintOverlayWindow.ViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(viewModel.labels, id: \.target.id) { assignment in
                HintBadge(
                    label: assignment.label,
                    typedPrefix: viewModel.typedPrefix,
                    active: viewModel.matching.isEmpty || viewModel.matching.contains(assignment.target.id),
                    kind: assignment.target.kind
                )
                .offset(
                    x: assignment.target.frame.minX - viewModel.panelAXOrigin.x,
                    y: assignment.target.frame.minY - viewModel.panelAXOrigin.y
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

private struct HintBadge: View {
    let label: String
    let typedPrefix: String
    let active: Bool
    let kind: HintTargetKind

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(label.enumerated()), id: \.offset) { idx, char in
                Text(String(char))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(idx < typedPrefix.count ? Color.secondary : Color.primary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(border, lineWidth: 0.5)
        )
        .opacity(active ? 1.0 : 0.25)
    }

    private var background: Color {
        switch kind {
        case .link:   return Color.yellow
        case .button: return Color.orange
        case .input:  return Color.green
        case .other:  return Color.gray
        }
    }

    private var border: Color {
        Color.black.opacity(0.4)
    }
}
