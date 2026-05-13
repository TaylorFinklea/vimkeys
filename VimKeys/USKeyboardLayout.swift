import CoreGraphics
import Foundation

/// Pure, thread-safe US-QWERTY keycode → character lookup.
///
/// The original engine resolved characters by calling
/// `NSEvent(cgEvent:)?.charactersIgnoringModifiers` from the
/// `VimKeys.EventTap` thread. That path goes through HIToolbox
/// (`TSMGetInputSourceProperty` → `islGetInputSourceListWithAdditions`),
/// and macOS 26 added a `dispatch_assert_queue` check requiring the main
/// thread — calling it from a tap callback now `SIGTRAP`s.
///
/// A static US-QWERTY table sidesteps the problem entirely: dictionary
/// lookup, no system calls, safe from any thread. The trade-off is that
/// non-US physical layouts (Dvorak, Colemak, ISO, etc.) won't see the
/// expected vim chars under their fingers — keycode 0x26 stays "j" even
/// if the user has Dvorak's "h" engraved there. Layout-aware resolution
/// (a main-thread cache rebuilt on `kTISNotifySelectedKeyboardInputSourceChanged`)
/// is the right long-term answer and is filed for V-M5+.
enum USKeyboardLayout {
    /// keycode → (unshifted, shifted) character pair. Hex constants match
    /// `Carbon.HIToolbox.Events`'s `kVK_ANSI_*` values.
    private static let table: [CGKeyCode: (unshifted: String, shifted: String)] = [
        // Letters
        0x00: ("a", "A"), 0x01: ("s", "S"), 0x02: ("d", "D"), 0x03: ("f", "F"),
        0x04: ("h", "H"), 0x05: ("g", "G"), 0x06: ("z", "Z"), 0x07: ("x", "X"),
        0x08: ("c", "C"), 0x09: ("v", "V"), 0x0B: ("b", "B"), 0x0C: ("q", "Q"),
        0x0D: ("w", "W"), 0x0E: ("e", "E"), 0x0F: ("r", "R"), 0x10: ("y", "Y"),
        0x11: ("t", "T"), 0x1F: ("o", "O"), 0x20: ("u", "U"), 0x22: ("i", "I"),
        0x23: ("p", "P"), 0x25: ("l", "L"), 0x26: ("j", "J"), 0x28: ("k", "K"),
        0x2D: ("n", "N"), 0x2E: ("m", "M"),

        // Digits (and their shifted symbols)
        0x12: ("1", "!"), 0x13: ("2", "@"), 0x14: ("3", "#"), 0x15: ("4", "$"),
        0x17: ("5", "%"), 0x16: ("6", "^"), 0x1A: ("7", "&"), 0x1C: ("8", "*"),
        0x19: ("9", "("), 0x1D: ("0", ")"),

        // Punctuation VimKeys consults (slash for find / help, brackets for
        // history, etc.) plus the rest so unbound keys still get a useful
        // chars value for forward-compat.
        0x18: ("=", "+"), 0x1B: ("-", "_"),
        0x1E: ("]", "}"), 0x21: ("[", "{"),
        0x27: ("'", "\""), 0x29: (";", ":"),
        0x2A: ("\\", "|"), 0x2B: (",", "<"), 0x2F: (".", ">"),
        0x2C: ("/", "?"),
        0x32: ("`", "~"),
    ]

    /// Returns the US-QWERTY character for `keyCode`, applying Shift when
    /// `shifted` is true. Returns `nil` for keycodes outside the table —
    /// the state machine treats those as `.passThrough`.
    static func characters(forKeyCode keyCode: CGKeyCode, shifted: Bool) -> String? {
        guard let pair = table[keyCode] else { return nil }
        return shifted ? pair.shifted : pair.unshifted
    }
}
