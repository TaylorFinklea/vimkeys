import CoreGraphics
import Foundation

/// Every binding the v1 spec defines. Forward-compat: V-M1 only resolves the
/// scroll/edge subset to non-`.passThrough` intents — every other command
/// case exists so the state-machine and overlay surfaces can be wired in
/// later milestones without renaming.
enum VimCommand: String, CaseIterable, Hashable {
    // Scroll / edge (V-M1)
    case scrollDown
    case scrollUp
    case scrollLeft
    case scrollRight
    case halfPageDown
    case halfPageUp
    case top
    case bottom

    // Find + history + reload (V-M2)
    case find
    case findNext
    case findPrev
    case historyBack
    case historyForward
    case reload
    case hardReload

    // Insert + escape + help (V-M2)
    case enterInsert
    case escape
    case help
    case suspendChord

    // Link hints (V-M3)
    case hint
    case hintNewTab
    case focusInput
    case viewSource

    // Vomnibar + clipboard (V-M4)
    case copyURL
    case copyHintURL
    case vomnibarURL
    case vomnibarURLNewTab
    case vomnibarBookmarks
    case vomnibarBookmarksNewTab
    case vomnibarTabs
    case openClipboard
    case openClipboardNewTab
}

/// The default binding table. Maps single characters and prefix-second
/// characters to `VimCommand`s. Multi-key chords (e.g. `gg`, `yy`) are
/// represented as `(prefix, secondChar)` entries so the state machine can
/// resolve them via two single-character lookups.
struct VimBindings: Equatable {
    /// Direct single-character chords typed in `.normal(.none)`.
    var singleChar: [String: VimCommand]

    /// Second character following `g` in `.normal(.g)`.
    var gPrefix: [String: VimCommand]

    /// Second character following `y` in `.normal(.y)`.
    var yPrefix: [String: VimCommand]

    /// Single Escape press (resolved by keycode, not character).
    var escapeAlone: VimCommand

    /// Two Escape presses within 300 ms (resolved by keycode + chord state).
    var escapeChord: VimCommand

    static let v1Default = VimBindings(
        singleChar: [
            "j": .scrollDown,
            "k": .scrollUp,
            "h": .scrollLeft,
            "l": .scrollRight,
            "d": .halfPageDown,
            "u": .halfPageUp,
            "G": .bottom,
            "f": .hint,
            "F": .hintNewTab,
            "/": .find,
            "n": .findNext,
            "N": .findPrev,
            "H": .historyBack,
            "L": .historyForward,
            "r": .reload,
            "R": .hardReload,
            "o": .vomnibarURL,
            "O": .vomnibarURLNewTab,
            "b": .vomnibarBookmarks,
            "B": .vomnibarBookmarksNewTab,
            "T": .vomnibarTabs,
            "p": .openClipboard,
            "P": .openClipboardNewTab,
            "i": .enterInsert,
            "?": .help,
        ],
        gPrefix: [
            "g": .top,
            "i": .focusInput,
            "s": .viewSource,
        ],
        yPrefix: [
            "y": .copyURL,
            "f": .copyHintURL,
        ],
        escapeAlone: .escape,
        escapeChord: .suspendChord
    )

    /// Every command this table resolves to, across all chord shapes. Used by
    /// `KeyCatalogTests.testEveryVimCommandHasABinding` to guard against
    /// orphaned `VimCommand` cases.
    var allBoundCommands: Set<VimCommand> {
        var commands = Set<VimCommand>()
        commands.formUnion(singleChar.values)
        commands.formUnion(gPrefix.values)
        commands.formUnion(yPrefix.values)
        commands.insert(escapeAlone)
        commands.insert(escapeChord)
        return commands
    }
}

/// Vim-style virtual keys VimKeys cares about that don't have a printable
/// character. Only used at V-M1 for `Esc`; expand as later milestones add
/// keycode-keyed bindings.
enum VimKeyCode {
    static let escape: CGKeyCode = 0x35
    static let upArrow: CGKeyCode = 0x7E
    static let downArrow: CGKeyCode = 0x7D
}
