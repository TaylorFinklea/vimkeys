import AppKit
import SwiftUI

/// Settings → Keys: edit the normal-mode key bindings. Each remappable
/// command shows its current chord and a press-to-capture button. The
/// modifier chords (Cmd+H/L, Cmd+Shift+J/K) and Escape are resolved by
/// keycode outside the bindings table, so they're not editable here.
struct KeysView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keys")
                .font(.title2.weight(.semibold))

            Text("Click a key to record a new one. Only the character changes \u{2014} a command keeps its shape (single key, or \u{0060}g\u{0060} / \u{0060}y\u{0060} prefix). Shift counts (\u{0060}g\u{0060} vs \u{0060}G\u{0060}); digits are reserved for counts. Cmd+H/L, Cmd+Shift+J/K, and Esc are fixed.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hintAlphabetSection

                    ForEach(model.remappableCommandsByCategory, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.category.title)
                                .font(.headline)
                            ForEach(group.commands, id: \.self) { command in
                                BindingRow(model: model, command: command)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()
            Button("Reset all keys to defaults") {
                model.resetBindingsToDefault()
            }
        }
    }

    private var hintAlphabetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Link-hint alphabet")
                .font(.headline)
            HStack {
                TextField(
                    "Hint alphabet",
                    text: Binding(
                        get: { model.settings.hintAlphabet },
                        set: { model.setHintAlphabet($0) }
                    )
                )
                .frame(maxWidth: 280)
                Button("Reset") {
                    model.setHintAlphabet(LinkHintEngine.defaultAlphabet)
                }
            }
            Text("Characters used to label clickable elements in hint mode (\u{0060}f\u{0060} / \u{0060}F\u{0060}). Lowercase; the matcher is case-insensitive.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BindingRow: View {
    @ObservedObject var model: AppModel
    let command: VimCommand
    @State private var message: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(command.displayName)
                .frame(width: 220, alignment: .leading)
            KeyCaptureButton(label: currentChord, onCapture: capture)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }

    private var currentChord: String {
        model.settings.bindings.chords(for: command).first?.display ?? "\u{2014}"
    }

    private func capture(_ key: String) {
        switch model.rebindCommand(command, toKey: key) {
        case .ok:
            message = nil
        case .invalidKey:
            message = "Use a single non-digit key"
        case .conflict(let holder):
            message = "\u{0060}\(key)\u{0060} is bound to \(holder.displayName)"
        }
    }
}

/// Shows the current chord; on click, records the next keystroke (via a
/// local NSEvent monitor) and reports it. VimKeys' own tap is inert while
/// the Settings window is frontmost (Safari isn't), so there's no conflict.
/// Esc cancels recording.
private struct KeyCaptureButton: View {
    let label: String
    let onCapture: (String) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press a key\u{2026}" : label) {
            recording ? stop() : start()
        }
        .font(.system(.body, design: .monospaced))
        .frame(width: 120)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {            // Esc cancels
                stop()
                return nil
            }
            if let chars = event.charactersIgnoringModifiers,
               let first = chars.first, !first.isWhitespace {
                onCapture(String(first))
            }
            stop()
            return nil                          // consume so it doesn't beep
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
