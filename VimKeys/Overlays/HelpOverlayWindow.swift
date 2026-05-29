import AppKit
import SwiftUI

/// Non-activating, non-mouse-capturing `NSPanel` hosting the V-M2 bindings
/// reference. Floats above other windows but never steals focus from
/// Safari — keystrokes flow through the global event tap, which dispatches
/// `.dismissOverlay` on any key (handled by `VimStateMachine.decide` in
/// `.help` mode).
@MainActor
final class HelpOverlayWindow: NSPanel {
    /// Holds the live bindings the content renders, so a custom remap shows
    /// the user's chords rather than the defaults.
    final class ViewModel: ObservableObject {
        @Published var bindings: VimBindings = .v1Default
    }

    let viewModel = ViewModel()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: HelpOverlayContent(viewModel: viewModel))
    }

    /// Center on the active screen (`NSScreen.main` — the one with keyboard
    /// focus). The help overlay is only shown while Safari is frontmost, so
    /// the active screen is Safari's screen in practice; falls back to
    /// `center()` if there's somehow no main screen.
    func presentCentered(bindings: VimBindings) {
        viewModel.bindings = bindings
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = self.frame.size
            let origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2
            )
            setFrameOrigin(origin)
        } else {
            center()
        }
        orderFrontRegardless()
    }
}

/// Help-overlay SwiftUI content: app title, dismiss hint, and a grouped
/// reference rendered from the LIVE bindings (`HelpReference`), so custom
/// remaps are reflected.
private struct HelpOverlayContent: View {
    @ObservedObject var viewModel: HelpOverlayWindow.ViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("VimKeys")
                    .font(.title.weight(.semibold))
                Spacer()
                Text("Press any key or Esc to dismiss")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(HelpReference.sections(for: viewModel.bindings)) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.headline)
                                .padding(.bottom, 2)

                            ForEach(section.entries) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(entry.chord)
                                        .font(.system(.body, design: .monospaced))
                                        .frame(width: 90, alignment: .leading)
                                    Text(entry.command)
                                        .frame(width: 200, alignment: .leading)
                                    Text(entry.detail)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(20)
        .frame(width: 700, height: 500, alignment: .topLeading)
        .background(.regularMaterial)
        .cornerRadius(12)
    }
}
