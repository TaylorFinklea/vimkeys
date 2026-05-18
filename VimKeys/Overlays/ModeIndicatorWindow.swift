import AppKit
import Combine
import SwiftUI

/// Persistent on-screen mode indicator — a small floating pill in the
/// bottom-right of the active screen, vim-status-line aesthetic. Driven
/// by `OverlayManager.modeIndicatorText`; hides itself whenever the
/// text is nil (which is what we want during `.insert` — no chrome while
/// the user is typing).
@MainActor
final class ModeIndicatorWindow: NSPanel {
    private let viewModel = ModeIndicatorViewModel()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        // Follows the user across Spaces + survives fullscreen Safari.
        // Without `.canJoinAllSpaces` the indicator would disappear the
        // moment the user fullscreens a Safari tab.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = NSHostingView(rootView: ModeIndicatorView(viewModel: viewModel))
    }

    func update(text: String?) {
        viewModel.text = text
        if let text, !text.isEmpty {
            positionInBottomRight(for: text)
            if !isVisible {
                orderFrontRegardless()
            }
        } else {
            orderOut(nil)
        }
    }

    /// Anchors to the bottom-right of the screen containing the mouse
    /// (a good proxy for "the screen the user is working on" when we
    /// can't reliably read Safari's window position from outside its
    /// process). 24pt inset matches the visual breathing room of macOS
    /// notification banners.
    private func positionInBottomRight(for text: String) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else { return }

        // Pill width scales with text so single-word labels don't waste
        // space and longer ones (like `VOMNIBAR (bookmarks)`) don't get
        // truncated. Floor at 140 to keep it readable.
        let approxWidth = max(140, CGFloat(text.count) * 11 + 40)
        let height: CGFloat = 32
        let inset: CGFloat = 24
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.maxX - approxWidth - inset,
            y: frame.minY + inset
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: approxWidth, height: height)), display: false)
    }
}

@MainActor
private final class ModeIndicatorViewModel: ObservableObject {
    @Published var text: String?
}

private struct ModeIndicatorView: View {
    @ObservedObject var viewModel: ModeIndicatorViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.78))
            Text(viewModel.text ?? "")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .lineLimit(1)
        }
        .padding(2)
    }
}
