import CoreGraphics
import Foundation

/// Forward-compat mode set. V-M1 only entered `.disabled` and
/// `.normal(prefix:)`. V-M2 reaches `.insert` and `.help` too. The
/// remaining cases (`.find`, `.hint`, `.vomnibar`) stay defined for
/// V-M3 / V-M4 wiring without renaming the public surface.
enum VimMode: Equatable {
    case disabled
    case insert
    case normal(prefix: CommandPrefix)
    case find(buffer: String)
    case hint(HintState)
    case vomnibar(VomnibarState)
    /// Transient overlay: any keystroke dismisses and is not re-dispatched.
    case help
}

enum CommandPrefix: Equatable {
    case none
    case count(Int)        // "5", "12" — buffered before a motion
    case g(count: Int?)    // `g` pressed, awaiting gg/gi/gs
    case y(count: Int?)    // `y` pressed, awaiting yy/yf (V-M4)
}

/// V-M3 hint-mode marker. Coordinator owns typed-prefix + label state;
/// the state machine just remembers what flavor of hint session is
/// running so Esc/key forwarding can be dispatched.
struct HintState: Equatable {
    let openInNewTab: Bool
    let copyOnly: Bool
    let filter: HintFilter
}

/// V-M4 stub.
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

/// Every action the engine executes on behalf of the state machine. V-M2
/// reaches `.passThrough`, `.consume`, `.scroll(...)`, `.scrollToEdge(...)`,
/// `.postKey(...)`, `.showOverlay(.help)`, `.dismissOverlay`, and
/// `.unfocusActiveElement`. Everything else exists for forward-compat
/// with V-M3 / V-M4 / V-M5.
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
    /// Fires for every character typed while in `.hint` mode. The engine
    /// forwards to `LinkHintCoordinator.handleKey(chars:)`; the state
    /// machine itself never inspects the buffer.
    case forwardHintKey(String)
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

    /// Called by the engine when `SafariObserver`'s AX focus observer
    /// reports the focused element's editability changed. Honors
    /// `InsertModeBehavior`: in `.manual` mode, focus changes are ignored
    /// and the user must press `i` / `Esc` explicitly.
    @discardableResult
    mutating func updateFocusEditable(_ isEditable: Bool) -> VimDecision? {
        guard settings.insertModeBehavior == .autoDetect else { return nil }

        switch mode {
        case .normal where isEditable:
            return setMode(.insert, intent: .passThrough)
        case .insert where !isEditable:
            return setMode(.normal(prefix: .none), intent: .passThrough)
        default:
            return nil
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

    /// Called by the engine after `LinkHintCoordinator` finishes a hint
    /// session (clicked / copied / cancelled). Drops back to `.normal`.
    @discardableResult
    mutating func exitHintMode() -> VimDecision? {
        guard case .hint = mode else { return nil }
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
        // Only act on keyDown. Pass keyUp through transparently.
        guard eventType == .keyDown else {
            return VimDecision(intent: .passThrough)
        }

        // Disabled: pass through everything (incl. Esc).
        if case .disabled = mode {
            return VimDecision(intent: .passThrough)
        }

        // Help overlay: any key dismisses and is not re-dispatched.
        if case .help = mode {
            return setMode(.normal(prefix: .none), intent: .dismissOverlay)
        }

        // Esc handling is keycode-based, before character / modifier
        // resolution, so it works in insert mode regardless of layout.
        if keyCode == VimKeyCode.escape {
            return decideEscape()
        }

        // Insert mode: every non-Esc key passes through to Safari.
        if case .insert = mode {
            return VimDecision(intent: .passThrough)
        }

        // Modifier policy on vim keys: any user-applied Cmd / Option /
        // Control means the user wants the chord to reach Safari intact.
        // Shift is allowed (it distinguishes `g` vs `G`, etc.).
        let suppressors: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        if !flags.intersection(suppressors).isEmpty {
            return VimDecision(intent: .passThrough)
        }

        switch mode {
        case .normal(let prefix):
            return decideNormal(prefix: prefix, keyCode: keyCode, characters: characters)
        case .hint:
            return decideHint(characters: characters)
        case .disabled, .insert, .find, .vomnibar, .help:
            // Disabled / insert / help are handled above; .find /
            // .vomnibar arrive in V-M4.
            return VimDecision(intent: .passThrough)
        }
    }

    private func decideHint(characters: String?) -> VimDecision {
        guard let chars = characters, !chars.isEmpty else {
            return VimDecision(intent: .consume)
        }
        return VimDecision(intent: .forwardHintKey(chars))
    }

    // MARK: - Esc handling

    private mutating func decideEscape() -> VimDecision {
        switch mode {
        case .insert:
            // Return to normal AND post Escape to Safari so the focused
            // input blurs (Safari handles Escape natively for inputs).
            return setMode(.normal(prefix: .none), intent: .unfocusActiveElement)
        case .normal(let prefix):
            if prefix != .none {
                // Cancel pending count / g prefix.
                return setMode(.normal(prefix: .none), intent: .consume)
            }
            // Esc in normal-no-prefix is a no-op for vim; pass through so
            // any app-level Esc handler (none expected, but be conservative)
            // still sees it.
            return VimDecision(intent: .passThrough)
        case .help:
            return setMode(.normal(prefix: .none), intent: .dismissOverlay)
        case .hint:
            return setMode(.normal(prefix: .none), intent: .dismissOverlay)
        case .disabled, .find, .vomnibar:
            return VimDecision(intent: .passThrough)
        }
    }

    // MARK: - Normal-mode dispatch

    private mutating func decideNormal(
        prefix: CommandPrefix,
        keyCode _: CGKeyCode,
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
            // Y-prefix not enterable at V-M2; if somehow set, cancel and
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

        return resolveCommand(command, count: count ?? 1, fromPrefix: true)
    }

    /// Resolve a single-character chord against the bindings table. Mode-
    /// affecting commands (`enterInsert`, `help`) mutate state inline; the
    /// rest go through `intentFor` for a pure mapping.
    private mutating func dispatchSingleChar(chars: String, count: Int) -> VimDecision {
        guard let command = settings.bindings.singleChar[chars] else {
            // Truly unbound: pass through and reset prefix if any.
            if currentPrefixIsNonEmpty() {
                return setMode(.normal(prefix: .none), intent: .passThrough)
            }
            return VimDecision(intent: .passThrough)
        }

        return resolveCommand(command, count: count, fromPrefix: currentPrefixIsNonEmpty())
    }

    /// Resolves a `VimCommand` to a `VimDecision`. Handles mode-affecting
    /// commands (`enterInsert`, `help`) inline; everything else is a pure
    /// `intentFor` lookup with the prefix reset if needed.
    private mutating func resolveCommand(
        _ command: VimCommand,
        count: Int,
        fromPrefix: Bool
    ) -> VimDecision {
        switch command {
        case .enterInsert:
            return setMode(.insert, intent: .consume)
        case .help:
            return setMode(.help, intent: .showOverlay(.help))
        case .hint:
            let state = HintState(openInNewTab: false, copyOnly: false, filter: .anyClickable)
            return setMode(.hint(state), intent: .requestHintTraversal(
                openInNewTab: false, copyOnly: false, filter: .anyClickable
            ))
        case .hintNewTab:
            let state = HintState(openInNewTab: true, copyOnly: false, filter: .anyClickable)
            return setMode(.hint(state), intent: .requestHintTraversal(
                openInNewTab: true, copyOnly: false, filter: .anyClickable
            ))
        case .focusInput:
            let state = HintState(openInNewTab: false, copyOnly: false, filter: .textInputsOnly)
            return setMode(.hint(state), intent: .requestHintTraversal(
                openInNewTab: false, copyOnly: false, filter: .textInputsOnly
            ))
        default:
            let intent = intentFor(command: command, count: count)
            if fromPrefix {
                return setMode(.normal(prefix: .none), intent: intent)
            }
            return VimDecision(intent: intent)
        }
    }

    // MARK: - Command → intent

    /// Maps a `VimCommand` to a `VimIntent` given a repeat count. V-M2
    /// resolves scroll-family + key-pass-through commands. Mode-affecting
    /// commands (`enterInsert`, `help`) are handled separately by
    /// `resolveCommand` because they need to mutate `mode`. Everything
    /// not yet wired (V-M3 hints, V-M4 vomnibar) is `.passThrough`.
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

        // V-M2 key-pass-through bindings: synthesize Safari's native
        // shortcut so this app stays a thin remap layer rather than
        // re-implementing find / history / reload.
        case .find:
            return .postKey(virtualKey: VimKeyCode.f, flags: .maskCommand)
        case .findNext:
            return .postKey(virtualKey: VimKeyCode.g, flags: .maskCommand)
        case .findPrev:
            return .postKey(virtualKey: VimKeyCode.g, flags: [.maskCommand, .maskShift])
        case .historyBack:
            return .postKey(virtualKey: VimKeyCode.leftBracket, flags: .maskCommand)
        case .historyForward:
            return .postKey(virtualKey: VimKeyCode.rightBracket, flags: .maskCommand)
        case .reload:
            return .postKey(virtualKey: VimKeyCode.r, flags: .maskCommand)
        case .hardReload:
            // Safari binds Cmd+Shift+R to "Show Reader" on macOS 14+, so
            // we synthesize Cmd+Option+R instead — that's Safari's
            // Develop-menu "Reload Page From Origin" shortcut. Users must
            // enable Develop menu (Settings → Advanced → Show features
            // for web developers) for this to take effect; otherwise the
            // chord is a no-op rather than triggering Reader Mode.
            return .postKey(virtualKey: VimKeyCode.r, flags: [.maskCommand, .maskAlternate])

        // Mode-affecting commands handled by `resolveCommand`; never
        // reach here.
        case .enterInsert, .escape, .help,
             .hint, .hintNewTab, .focusInput:
            return .consume

        case .viewSource:
            // Cmd+Option+U opens Safari's View Source inspector. Posted
            // here (no hint UI needed) so `gs` round-trips through the
            // standard postKey path.
            return .postKey(virtualKey: VimKeyCode.u, flags: [.maskCommand, .maskAlternate])

        case .suspendChord,
             .copyURL, .copyHintURL,
             .vomnibarURL, .vomnibarURLNewTab,
             .vomnibarBookmarks, .vomnibarBookmarksNewTab, .vomnibarTabs,
             .openClipboard, .openClipboardNewTab:
            // Defined for forward-compat; behavior arrives in V-M4..V-M5.
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
