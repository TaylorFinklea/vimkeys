import AppKit
import SwiftUI

/// Settings → Keys: edit the normal-mode key bindings. Each remappable
/// command shows its current chord and a press-to-capture button. The
/// modifier chords (Cmd+H/L, Cmd+Shift+J/K) and Escape are resolved by
/// keycode outside the bindings table, so they're not editable here.
///
/// Recording state (which row is capturing + the single live NSEvent
/// monitor) lives here, not per-row, so only one capture can be active at a
/// time — clicking a second row's button cancels the first.
struct KeysView: View {
    @ObservedObject var model: AppModel

    @State private var recordingCommand: VimCommand?
    @State private var monitor: Any?
    @State private var messages: [VimCommand: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keys")
                .font(.title2.weight(.semibold))

            Text("Click a key to record a new one. Only the character changes \u{2014} a command keeps its shape (single key, or \u{0060}g\u{0060} / \u{0060}y\u{0060} prefix). Shift counts (\u{0060}g\u{0060} vs \u{0060}G\u{0060}); digits and \u{0060}g\u{0060} / \u{0060}y\u{0060} are reserved. Cmd+H/L, Cmd+Shift+J/K, and Esc are fixed.")
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
                                bindingRow(command)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            Divider()
            Button("Reset all keys to defaults") {
                model.resetBindingsToDefault()
                messages = [:]
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func bindingRow(_ command: VimCommand) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(command.displayName)
                .frame(width: 220, alignment: .leading)

            Button(recordingCommand == command ? "Press a key\u{2026}" : currentChord(command)) {
                recordingCommand == command ? stopRecording() : startRecording(command)
            }
            .font(.system(.body, design: .monospaced))
            .frame(width: 120)

            if let message = messages[command] {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
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

    private func currentChord(_ command: VimCommand) -> String {
        model.settings.bindings.chords(for: command).first?.display ?? "\u{2014}"
    }

    /// Records the next keystroke for `command` via a single local NSEvent
    /// monitor (VimKeys' own tap is inert while Settings is frontmost).
    /// Cancels any in-progress recording first, so only one monitor is ever
    /// live. Esc cancels.
    private func startRecording(_ command: VimCommand) {
        stopRecording()
        recordingCommand = command
        messages[command] = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {            // Esc cancels
                stopRecording()
                return nil
            }
            if let chars = event.charactersIgnoringModifiers,
               let first = chars.first, !first.isWhitespace {
                capture(command, String(first))
            }
            stopRecording()
            return nil                          // consume so it doesn't beep
        }
    }

    private func stopRecording() {
        recordingCommand = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func capture(_ command: VimCommand, _ key: String) {
        switch model.rebindCommand(command, toKey: key) {
        case .ok:
            messages[command] = nil
        case .invalidKey:
            messages[command] = "Pick a single key (not a digit, g, or y)"
        case .conflict(let holder):
            messages[command] = "\u{0060}\(key)\u{0060} is bound to \(holder.displayName)"
        }
    }
}
