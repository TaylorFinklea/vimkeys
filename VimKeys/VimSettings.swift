import Foundation

/// User-tunable behavior of the state machine.
struct VimSettings: Equatable {
    var bindings: VimBindings
    var insertModeBehavior: InsertModeBehavior
    /// Characters used to label hints in `f`/`F` mode. Empty string falls
    /// back to `LinkHintEngine.defaultAlphabet` at session start.
    var hintAlphabet: String
    /// Hosts (suffix-matched) on which VimKeys passes every key through
    /// to Safari. Editable in Settings → Sites.
    var disabledHosts: [String]

    init(
        bindings: VimBindings = .v1Default,
        insertModeBehavior: InsertModeBehavior = .insertFirst,
        hintAlphabet: String = LinkHintEngine.defaultAlphabet,
        disabledHosts: [String] = []
    ) {
        self.bindings = bindings
        self.insertModeBehavior = insertModeBehavior
        self.hintAlphabet = hintAlphabet
        self.disabledHosts = disabledHosts
    }

    static let v1Default = VimSettings()
}

/// How VimKeys decides which mode to be in when Safari is frontmost.
///
/// `.insertFirst` (default): start in insert (passive). Press `Esc` to
/// enter normal mode and use vim keys. Press `Esc` (or move focus into
/// a text field) to drop back to insert. Matches the mental model most
/// browser-vim tools use, and means VimKeys never "ate" a keystroke
/// the user expected to land in the page.
///
/// `.autoDetect` (pre-0.7.1 default): start in normal (active). Listen
/// to Safari's AX focus events; auto-flip to insert when the focused
/// element advertises itself as editable. Relies on Safari setting the
/// `AXEditable` attribute, which it does for `<input>` and `<textarea>`
/// but inconsistently for `contenteditable` divs — so apps like Notion
/// and ChatGPT could stay stuck in normal mode and swallow the user's
/// keystrokes. That's why this is no longer the default.
///
/// `.manual`: start in normal, never auto-flip. User toggles explicitly
/// with `i` and `Esc`. For people who want full control.
enum InsertModeBehavior: String, Codable, Equatable, CaseIterable, Identifiable {
    case insertFirst
    case autoDetect
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insertFirst: return "Insert by default (Esc enters normal)"
        case .autoDetect:  return "Normal, auto-switch on text fields"
        case .manual:      return "Normal, never auto-switch"
        }
    }

    var detail: String {
        switch self {
        case .insertFirst:
            return "VimKeys stays out of your way. Press Esc to use vim keys; Esc again or click into a text field to return to insert."
        case .autoDetect:
            return "Vim keys active by default. Switches to insert when Safari's AX reports an editable element focused. Misses many contenteditable divs."
        case .manual:
            return "Vim keys always active. Press i to enter insert mode and Esc to leave."
        }
    }
}
