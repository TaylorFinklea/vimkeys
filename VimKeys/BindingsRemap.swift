import Foundation

/// A bindable key chord, across the shapes `VimBindings` supports. Used by
/// the reverse index (command → chord) that the help overlay and the remap
/// UI read, and by the rebinding / conflict-detection helpers.
///
/// The `.escape` chords are included so the reverse index is complete, but
/// they're resolved by keycode in `VimStateMachine.decide(...)` — outside
/// the bindings table — so they're fixed (`isEditable == false`) in v1.
enum Chord: Equatable, Hashable {
    case single(String)    // a char typed in normal mode, e.g. "j"
    case g(String)         // `g` then this char: "g" (gg), "i" (gi), "s" (gs)
    case y(String)         // `y` then this char: "y" (yy), "f" (yf)
    case escape            // a single Escape
    case escapeEscape      // double Escape within the chord window

    /// Human-readable form for help / settings: "j", "gg", "yf", "Esc".
    var display: String {
        switch self {
        case .single(let c): return c
        case .g(let c): return "g\(c)"
        case .y(let c): return "y\(c)"
        case .escape: return "Esc"
        case .escapeEscape: return "Esc Esc"
        }
    }

    /// Whether the remap UI may edit this chord. Escape chords are fixed.
    var isEditable: Bool {
        switch self {
        case .single, .g, .y: return true
        case .escape, .escapeEscape: return false
        }
    }

    /// A chord of the SAME shape with a different key character — used by
    /// the remap UI, which changes a command's key while keeping its
    /// single / g-prefix / y-prefix shape. Returns nil for a multi-character
    /// key, for a digit on a single-char chord (`1`–`9` start counts, `0`
    /// can't begin one), or for the fixed Escape chords.
    func withKey(_ key: String) -> Chord? {
        guard key.count == 1 else { return nil }
        switch self {
        case .single:
            guard !(key.first?.isNumber ?? false) else { return nil }
            return .single(key)
        case .g: return .g(key)
        case .y: return .y(key)
        case .escape, .escapeEscape: return nil
        }
    }
}

extension VimBindings {
    /// Forward lookup: the command (if any) this chord is bound to.
    func command(for chord: Chord) -> VimCommand? {
        switch chord {
        case .single(let c): return singleChar[c]
        case .g(let c): return gPrefix[c]
        case .y(let c): return yPrefix[c]
        case .escape: return escapeAlone
        case .escapeEscape: return escapeChord
        }
    }

    /// command → its bound chords (usually one), ordered stably so the UI
    /// doesn't jitter between launches.
    var reverseIndex: [VimCommand: [Chord]] {
        var index: [VimCommand: [Chord]] = [:]
        for (key, command) in singleChar { index[command, default: []].append(.single(key)) }
        for (key, command) in gPrefix { index[command, default: []].append(.g(key)) }
        for (key, command) in yPrefix { index[command, default: []].append(.y(key)) }
        index[escapeAlone, default: []].append(.escape)
        index[escapeChord, default: []].append(.escapeEscape)
        for command in index.keys {
            index[command]?.sort { $0.display < $1.display }
        }
        return index
    }

    /// Every chord bound to `command`.
    func chords(for command: VimCommand) -> [Chord] {
        reverseIndex[command] ?? []
    }

    /// The command currently holding `chord`, if any — for a conflict
    /// warning before an overwrite. Nil means the chord is free.
    func conflict(forAssigning chord: Chord) -> VimCommand? {
        command(for: chord)
    }

    /// Commands with no binding (should be empty for a valid table).
    var unboundCommands: Set<VimCommand> {
        Set(VimCommand.allCases).subtracting(allBoundCommands)
    }

    /// A copy with `command` rebound to `chord`: drops the command's
    /// previous editable chord(s), then assigns the new one, overwriting
    /// whatever held it (the caller checks `conflict(forAssigning:)` first).
    /// No-ops for the fixed Escape chords.
    func rebinding(_ command: VimCommand, to chord: Chord) -> VimBindings {
        guard chord.isEditable else { return self }
        var copy = self
        copy.singleChar = copy.singleChar.filter { $0.value != command }
        copy.gPrefix = copy.gPrefix.filter { $0.value != command }
        copy.yPrefix = copy.yPrefix.filter { $0.value != command }
        copy.assign(command, to: chord)
        return copy
    }

    /// Restores any command missing from this table to its default chord —
    /// forward-compat for a command added in a newer build that an older
    /// persisted blob won't contain. Only fills when the default chord is
    /// free, so it never clobbers a user remap.
    func filledWithDefaults(_ defaults: VimBindings = .v1Default) -> VimBindings {
        let missing = unboundCommands
        guard !missing.isEmpty else { return self }
        var copy = self
        let defaultIndex = defaults.reverseIndex
        for command in missing {
            for chord in defaultIndex[command] ?? [] where chord.isEditable && copy.command(for: chord) == nil {
                copy.assign(command, to: chord)
                break  // one chord is enough to make it reachable
            }
        }
        return copy
    }

    private mutating func assign(_ command: VimCommand, to chord: Chord) {
        switch chord {
        case .single(let c): singleChar[c] = command
        case .g(let c): gPrefix[c] = command
        case .y(let c): yPrefix[c] = command
        case .escape, .escapeEscape: break
        }
    }
}
