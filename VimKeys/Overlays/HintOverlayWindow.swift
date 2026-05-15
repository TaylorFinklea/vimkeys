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
        }
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

/// SwiftUI overlay: a single ZStack of label pills, one per assignment.
/// Position is computed from the target's AX frame (screen coordinates)
/// flipped into Cocoa coordinates relative to the overlay window.
private struct HintOverlayContent: View {
    @ObservedObject var viewModel: HintOverlayWindow.ViewModel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(viewModel.labels, id: \.target.id) { assignment in
                    HintBadge(
                        label: assignment.label,
                        typedPrefix: viewModel.typedPrefix,
                        active: viewModel.matching.isEmpty || viewModel.matching.contains(assignment.target.id),
                        kind: assignment.target.kind
                    )
                    .position(
                        x: assignment.target.frame.minX - flipOriginX(proxy: proxy),
                        y: flippedY(for: assignment.target.frame, proxy: proxy)
                    )
                }
            }
        }
        .ignoresSafeArea()
    }

    /// AX frames are in screen coords with origin at the upper-left of the
    /// primary display. The overlay panel covers a single screen so we
    /// subtract that screen's origin to get window-relative X.
    private func flipOriginX(proxy: GeometryProxy) -> CGFloat {
        // GeometryReader's frame doesn't expose the screen origin directly,
        // but since we set the panel frame to screen.frame, the X conversion
        // simplifies to "subtract panel origin", which SwiftUI takes care
        // of by treating (0, 0) as the top-left of the panel.
        _ = proxy
        return 0
    }

    /// Convert AX frame (top-left origin, Y growing downward in some
    /// contexts, upward in others depending on macOS version) to SwiftUI
    /// position. On macOS AX returns Y growing downward from the top of
    /// the primary display, matching what SwiftUI expects for a top-leading
    /// ZStack alignment.
    private func flippedY(for frame: CGRect, proxy _: GeometryProxy) -> CGFloat {
        frame.minY
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
