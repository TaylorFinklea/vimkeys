import CoreGraphics
import Foundation

/// Forward-compat mode set. V-M1 only enters `.disabled` and
/// `.normal(prefix:)`. The other cases are defined so subsequent milestones
/// can land without renaming or migrating the state machine's public
/// surface.
enum VimMode: Equatable {
    case disabled
    case insert
    case normal(prefix: CommandPrefix)
    case find(buffer: String)
    case hint(HintState)
    case vomnibar(VomnibarState)
}

enum CommandPrefix: Equatable {
    case none
    case count(Int)        // "5", "12" — buffered before a motion
    case g(count: Int?)    // `g` pressed, awaiting gg/gi/gs
    case y(count: Int?)    // `y` pressed, awaiting yy/yf (V-M4)
}

/// V-M1 stub. Real shape arrives in V-M3 with link hints.
struct HintState: Equatable {}

/// V-M1 stub. Real shape arrives in V-M4 with vomnibar.
struct VomnibarState: Equatable {}

enum ScrollDirection: Equatable {
    case vertical
    case horizontal
}

/// Signed magnitude. Sign convention matches `CGEvent.scrollWheelEvent2`'s
/// `wheel1` (vertical) and `wheel2` (horizontal): positive is up / right,
/// negative is down / left.
enum ScrollAmount: Equatable {
    case lines(Int)
    case halfPage(Int)
}

enum VerticalEdge: Equatable {
    case top
    case bottom
}

/// Forward-compat overlay placeholders. V-M1 doesn't render overlays.
enum OverlayKind: Equatable {
    case help
}

enum OverlayUpdate: Equatable {
    case noop
}

enum HintFilter: Equatable {
    case anyClickable
    case textInputsOnly
}

/// Every action the engine executes on behalf of the state machine. V-M1
/// only exercises `.passThrough`, `.consume`, `.scroll(...)`, and
/// `.scrollToEdge(...)`. Everything else exists for forward-compat with
/// V-M2 / V-M3 / V-M4 / V-M5.
enum VimIntent: Equatable {
    case passThrough
    case consume
    case scroll(direction: ScrollDirection, amount: ScrollAmount)
    case scrollToEdge(VerticalEdge)
    case postKey(virtualKey: CGKeyCode, flags: CGEventFlags)
    case showOverlay(OverlayKind)
    case updateOverlay(OverlayUpdate)
    case dismissOverlay
    case requestHintTraversal(openInNewTab: Bool, copyOnly: Bool, filter: HintFilter)
    case dispatchHintClick(at: CGPoint, modifierFlags: CGEventFlags)
    case requestSafariURL
    case requestBookmarks
    case requestOpenTabs
    case openURL(String, inNewTab: Bool)
    case copyToClipboard(String)
    case unfocusActiveElement
    case toggleSuspended
    case showHelp
}

struct VimDecision: Equatable {
    let intent: VimIntent
    let modeDidChange: Bool
    let newMode: VimMode?

    init(intent: VimIntent, modeDidChange: Bool = false, newMode: VimMode? = nil) {
        self.intent = intent
        self.modeDidChange = modeDidChange
        self.newMode = newMode
    }
}

/// Pure value-type state machine. The engine calls `decide(...)` on every
/// `keyDown` / `keyUp`; never holds state across calls beyond what lives
/// inside this struct. Tests construct one directly and exercise the seam
/// without ever touching `CGEventTap`.
struct VimStateMachine {
    private(set) var mode: VimMode = .disabled
    var settings: VimSettings

    /// Lines per single press of `j` / `k` / `h` / `l`. Multiplied by repeat
    /// count when one is buffered.
    static let scrollLinesPerPress: Int = 3

    /// Approximate "half page" in line units. Until V-M3 wires AX viewport
    /// queries, the engine multiplies this by repeat count for `d` / `u`.
    /// Refined in V-M3.
    static let halfPageLinesApprox: Int = 15

    /// Repeat-count cap. Prevents `999999999999j` posting a billion scroll
    /// events.
    static let countCap: Int = 999

    init(settings: VimSettings = .v1Default) {
        self.settings = settings
    }

    // MARK: - External event sources

    /// Called by the engine when `SafariObserver` reports Safari frontmost
    /// changed. Returns a decision iff mode changed.
    @discardableResult
    mutating func updateSafariFrontmost(_ isFrontmost: Bool) -> VimDecision? {
        if isFrontmost {
            guard case .disabled = mode else { return nil }
            return setMode(.normal(prefix: .none), intent: .passThrough)
        } else {
            guard mode != .disabled else { return nil }
            return setMode(.disabled, intent: .passThrough)
        }
    }

    /// Called by the engine on a 1500 ms one-shot timer after each prefix
    /// change. Cancels any pending count / `g` / `y` prefix.
    @discardableResult
    mutating func commandTimeout() -> VimDecision {
        guard case .normal(let prefix) = mode, prefix != .none else {
            return VimDecision(intent: .passThrough)
        }
        return setMode(.normal(prefix: .none), intent: .passThrough)
    }

    // MARK: - Per-event decide

    mutating func decide(
        eventType: CGEventType,
        keyCode: CGKeyCode,
        characters: String?,
        flags: CGEventFlags,
        timestamp _: UInt64
    ) -> VimDecision {
        // Only act on keyDown. Pass keyUp through transparently — V-M1's
        // bindings are all keyDown-driven.
        guard eventType == .keyDown else {
            return VimDecision(intent: .passThrough)
        }

        // Disabled: pass through everything.
        if case .disabled = mode {
            return VimDecision(intent: .passThrough)
        }

        // Modifier policy: any user-applied Cmd / Option / Control on a vim
        // key means the user wants the chord to reach Safari intact, not be
        // intercepted as a vim binding. Shift is allowed (it distinguishes
        // `g` vs `G`, etc.).
        let suppressors: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        if !flags.intersection(suppressors).isEmpty {
            return VimDecision(intent: .passThrough)
        }

        switch mode {
        case .normal(let prefix):
            return decideNormal(prefix: prefix, keyCode: keyCode, characters: characters)
        case .disabled, .insert, .find, .hint, .vomnibar:
            // Unreachable at V-M1 (insert/find/hint/vomnibar arrive in
            // V-M2..V-M4); .disabled is handled above.
            return VimDecision(intent: .passThrough)
        }
    }

    // MARK: - Normal-mode dispatch

    private mutating func decideNormal(
        prefix: CommandPrefix,
        keyCode: CGKeyCode,
        characters: String?
    ) -> VimDecision {
        guard let chars = characters, !chars.isEmpty else {
            return VimDecision(intent: .passThrough)
        }

        switch prefix {
        case .none:
            return decideNormalNoPrefix(chars: chars)
        case .count(let n):
            return decideNormalWithCount(n: n, chars: chars)
        case .g(let count):
            return decideAfterG(count: count, chars: chars)
        case .y:
            // Y-prefix not enterable at V-M1; if somehow set, cancel and
            // re-evaluate the keystroke from `.normal(.none)`.
            _ = setMode(.normal(prefix: .none), intent: .passThrough)
            return decideNormalNoPrefix(chars: chars)
        }
    }

    private mutating func decideNormalNoPrefix(chars: String) -> VimDecision {
        if let digit = digitValue(chars), digit >= 1 {
            // `0` cannot start a count; it's only a count digit when
            // appended to an existing one.
            return setMode(.normal(prefix: .count(digit)), intent: .consume)
        }

        if chars == "g" {
            return setMode(.normal(prefix: .g(count: nil)), intent: .consume)
        }

        return dispatchSingleChar(chars: chars, count: 1)
    }

    private mutating func decideNormalWithCount(n: Int, chars: String) -> VimDecision {
        if let digit = digitValue(chars) {
            let next = min(n * 10 + digit, Self.countCap)
            return setMode(.normal(prefix: .count(next)), intent: .consume)
        }

        if chars == "g" {
            return setMode(.normal(prefix: .g(count: n)), intent: .consume)
        }

        return dispatchSingleChar(chars: chars, count: n)
    }

    private mutating func decideAfterG(count: Int?, chars: String) -> VimDecision {
        guard let command = settings.bindings.gPrefix[chars] else {
            // Unknown follow-up: cancel prefix, pass through (don't try to
            // re-dispatch — Vim cancels the prefix and ignores).
            return setMode(.normal(prefix: .none), intent: .passThrough)
        }

        let intent = intentFor(command: command, count: count ?? 1)
        return setMode(.normal(prefix: .none), intent: intent)
    }

    /// Resolve a single-character chord against the bindings table. If the
    /// command exists but is not yet behavioral at V-M1, returns
    /// `.passThrough` (forward-compat — character is not silently consumed
    /// just because a future milestone will bind it).
    private mutating func dispatchSingleChar(chars: String, count: Int) -> VimDecision {
        guard let command = settings.bindings.singleChar[chars] else {
            // Truly unbound: pass through and reset prefix if any.
            if case .normal(let prefix) = mode, prefix != .none {
                return setMode(.normal(prefix: .none), intent: .passThrough)
            }
            return VimDecision(intent: .passThrough)
        }

        let intent = intentFor(command: command, count: count)
        let modeChange = currentPrefixIsNonEmpty()
        if modeChange {
            return setMode(.normal(prefix: .none), intent: intent)
        }
        return VimDecision(intent: intent)
    }

    // MARK: - Command → intent

    /// Maps a `VimCommand` to a `VimIntent` given a repeat count. V-M1 only
    /// resolves scroll-family commands to non-passThrough intents; every
    /// other command exists in the enum but produces `.passThrough` here
    /// until its owning milestone wires behavior.
    private func intentFor(command: VimCommand, count: Int) -> VimIntent {
        let n = max(1, count)
        switch command {
        case .scrollDown:
            return .scroll(direction: .vertical, amount: .lines(-Self.scrollLinesPerPress * n))
        case .scrollUp:
            return .scroll(direction: .vertical, amount: .lines(Self.scrollLinesPerPress * n))
        case .scrollLeft:
            return .scroll(direction: .horizontal, amount: .lines(-Self.scrollLinesPerPress * n))
        case .scrollRight:
            return .scroll(direction: .horizontal, amount: .lines(Self.scrollLinesPerPress * n))
        case .halfPageDown:
            return .scroll(direction: .vertical, amount: .halfPage(-n))
        case .halfPageUp:
            return .scroll(direction: .vertical, amount: .halfPage(n))
        case .top:
            return .scrollToEdge(.top)
        case .bottom:
            return .scrollToEdge(.bottom)
        case .find, .findNext, .findPrev, .historyBack, .historyForward,
             .reload, .hardReload, .enterInsert, .escape, .help, .suspendChord,
             .hint, .hintNewTab, .focusInput, .viewSource,
             .copyURL, .copyHintURL,
             .vomnibarURL, .vomnibarURLNewTab,
             .vomnibarBookmarks, .vomnibarBookmarksNewTab, .vomnibarTabs,
             .openClipboard, .openClipboardNewTab:
            // Defined for forward-compat; behavior arrives in V-M2..V-M5.
            return .passThrough
        }
    }

    // MARK: - Helpers

    private mutating func setMode(_ newMode: VimMode, intent: VimIntent) -> VimDecision {
        let didChange = newMode != mode
        mode = newMode
        return VimDecision(intent: intent, modeDidChange: didChange, newMode: didChange ? newMode : nil)
    }

    private func currentPrefixIsNonEmpty() -> Bool {
        guard case .normal(let prefix) = mode else { return false }
        return prefix != .none
    }

    private func digitValue(_ chars: String) -> Int? {
        guard chars.count == 1, let scalar = chars.unicodeScalars.first else { return nil }
        guard scalar.value >= 0x30, scalar.value <= 0x39 else { return nil }
        return Int(scalar.value - 0x30)
    }
}
