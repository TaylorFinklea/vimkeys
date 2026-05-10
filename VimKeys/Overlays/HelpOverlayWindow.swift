import AppKit
import SwiftUI

/// Non-activating, non-mouse-capturing `NSPanel` hosting the V-M2 bindings
/// reference. Floats above other windows but never steals focus from
/// Safari — keystrokes flow through the global event tap, which dispatches
/// `.dismissOverlay` on any key (handled by `VimStateMachine.decide` in
/// `.help` mode).
@MainActor
final class HelpOverlayWindow: NSPanel {
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
        contentView = NSHostingView(rootView: HelpOverlayContent())
    }

    /// Center on whichever screen Safari's focused window is on. Falls back
    /// to the main screen when Safari isn't placeable.
    func presentCentered() {
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
/// reference of the v1 bindings rendered in three columns.
private struct HelpOverlayContent: View {
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
                    ForEach(HelpEntry.allSections) { section in
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
                                        .frame(width: 180, alignment: .leading)
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

private struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let entries: [HelpEntry]
}

private struct HelpEntry: Identifiable {
    let id = UUID()
    let chord: String
    let command: String
    let detail: String

    static let allSections: [HelpSection] = [
        HelpSection(title: "Scroll", entries: [
            HelpEntry(chord: "j / k", command: "Scroll down / up", detail: "3 lines per press"),
            HelpEntry(chord: "h / l", command: "Scroll left / right", detail: "3 columns per press"),
            HelpEntry(chord: "d / u", command: "Half-page down / up", detail: "Approx 15 lines"),
            HelpEntry(chord: "gg / G", command: "Top / bottom", detail: "Jump to extremes"),
            HelpEntry(chord: "<count>", command: "Repeat next motion", detail: "5j → scroll down 5×, capped at 999"),
        ]),
        HelpSection(title: "Find & history", entries: [
            HelpEntry(chord: "/", command: "Find in page", detail: "Synthesizes Cmd+F"),
            HelpEntry(chord: "n / N", command: "Find next / previous", detail: "Cmd+G / Cmd+Shift+G"),
            HelpEntry(chord: "H / L", command: "History back / forward", detail: "Cmd+[ / Cmd+]"),
            HelpEntry(chord: "r / R", command: "Reload / hard reload", detail: "Cmd+R / Cmd+Shift+R"),
        ]),
        HelpSection(title: "Mode", entries: [
            HelpEntry(chord: "i", command: "Enter insert mode", detail: "Manual insert override"),
            HelpEntry(chord: "Esc", command: "Exit insert / cancel prefix", detail: "Returns to normal mode"),
            HelpEntry(chord: "?", command: "Show / dismiss help", detail: "This window"),
        ]),
        HelpSection(title: "Coming later", entries: [
            HelpEntry(chord: "f / F / gi", command: "Link hints (V-M3)", detail: "Click any visible link by typing a label"),
            HelpEntry(chord: "yy / yf", command: "Copy URL / link (V-M4)", detail: "Yank to clipboard"),
            HelpEntry(chord: "o O b B T", command: "Vomnibar (V-M4)", detail: "URL / bookmark / tab search"),
            HelpEntry(chord: "Esc Esc", command: "Suspend until reload (V-M5)", detail: "Quick chord to silence VimKeys on this page"),
        ]),
    ]
}
