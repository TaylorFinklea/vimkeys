import CoreGraphics
import Foundation

/// Forward-compat mode set. V-M1 only entered `.disabled` and
/// `.normal(prefix:)`. V-M2 reaches `.insert` and `.help` too. The
/// remaining cases (`.find`, `.hint`, `.vomnibar`) stay defined for
/// V-M3 / V-M4 wiring without renaming the public surface.
enum VimMode: Equatable {
    case disabled
    /// Safari is frontmost but the current page's host is in the user's
    /// disabled-sites list. Behaves like `.disabled` (every key passes
    /// through) but is visible to the menu bar so we can surface "Off on
    /// this site" rather than "Off".
    case disabledBySite
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

/// V-M4 vomnibar marker. Coordinator owns the query buffer + suggestions;
/// the state machine just remembers what flavor of session is running
/// so Esc forwards correctly.
struct VomnibarState: Equatable {
    let flavor: VomnibarFlavor
}

/// What kind of vomnibar session is active. `url(openInNewTab:)` covers
/// `o` / `O`; `tabs` covers `T`; `bookmarks(openInNewTab:)` covers `b` /
/// `B` (requires Full Disk Access for Safari's Bookmarks.plist).
enum VomnibarFlavor: Equatable {
    case url(openInNewTab: Bool)
    case tabs
    case bookmarks(openInNewTab: Bool)
}

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
    /// V-M4: open the vomnibar window with a particular flavor. Engine
    /// forwards to `VomnibarCoordinator.start(flavor:)`.
    case requestVomnibar(VomnibarFlavor)
    /// V-M4: forward a keystroke into the vomnibar (query updates, Enter,
    /// arrow keys, Ctrl-N/P).
    case forwardVomnibarKey(String)
    /// V-M4: copy the URL of Safari's frontmost tab to the clipboard.
    /// Engine bounces to `AppModel` (MainActor) which uses `SafariBridge`.
    case copyCurrentURL
    /// V-M4: open the URL currently on the clipboard.
    case openClipboardURL(inNewTab: Bool)
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
    private(set) var currentURL: URL?
    /// Session-scoped suspend — set by the Esc-Esc chord. Lives only in
    /// memory; navigating away clears it (mirrors Vimium's "suspend until
    /// reload" semantics with the simplest possible bookkeeping).
    private(set) var sessionSuspendedURL: URL?
    /// Timestamp of the last `Esc` keydown, in CG event nanoseconds. Used
    /// to detect the double-press chord. Cleared on any non-Esc key.
    private var lastEscTimestamp: UInt64?
    /// Window inside which two `Esc` presses count as a chord. 350 ms is
    /// loose enough to absorb hesitation, tight enough that a single Esc
    /// followed by typing doesn't accidentally suspend.
    static let chordWindowNanoseconds: UInt64 = 350_000_000

    var settings: VimSettings {
        didSet {
            // Re-evaluate disabled-by-site state when the user edits the
            // sites list while VimKeys is running. Without this, adding a
            // host wouldn't take effect until the next URL change.
            reconcileDisabledBySite(safariFrontmost: !isModeOff)
        }
    }

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

    /// What mode VimKeys lands in when Safari first comes frontmost (or
    /// when a previously-disabled site is re-enabled). Driven by the
    /// user's `InsertModeBehavior` setting — `.insertFirst` enters
    /// `.insert` so the user's typing reaches the page by default;
    /// everything else enters `.normal(.none)` and the vim bindings
    /// are immediately live.
    var defaultMode: VimMode {
        settings.insertModeBehavior == .insertFirst ? .insert : .normal(prefix: .none)
    }

    /// Called by the engine when `SafariObserver` reports Safari frontmost
    /// changed. Returns a decision iff mode changed.
    @discardableResult
    mutating func updateSafariFrontmost(_ isFrontmost: Bool) -> VimDecision? {
        if isFrontmost {
            guard isModeOff else { return nil }
            if isCurrentHostDisabled {
                return setMode(.disabledBySite, intent: .passThrough)
            }
            return setMode(defaultMode, intent: .passThrough)
        } else {
            guard !isModeOff else { return nil }
            return setMode(.disabled, intent: .passThrough)
        }
    }

    /// Called by AppModel when Safari's frontmost URL changes (via polling
    /// `SafariBridge.currentURL()`). Triggers a mode transition iff the
    /// host's disabled-state flips. Navigating away from a session-
    /// suspended URL also clears that suspend.
    @discardableResult
    mutating func updateCurrentURL(_ url: URL?) -> VimDecision? {
        if url != sessionSuspendedURL {
            sessionSuspendedURL = nil
        }
        currentURL = url
        return reconcileDisabledBySite(safariFrontmost: !isModeOff || mode == .disabledBySite)
    }

    /// Esc-Esc chord. Toggles session suspend on the current URL: enters
    /// `.disabledBySite` if not already suspended, exits if it was.
    @discardableResult
    mutating func toggleSuspendOnCurrentURL() -> VimDecision? {
        guard let url = currentURL else { return nil }
        if sessionSuspendedURL == url {
            sessionSuspendedURL = nil
        } else {
            sessionSuspendedURL = url
        }
        return reconcileDisabledBySite(safariFrontmost: !isModeOff || mode == .disabledBySite)
    }

    @discardableResult
    private mutating func reconcileDisabledBySite(safariFrontmost: Bool) -> VimDecision? {
        guard safariFrontmost else { return nil }
        let disabled = isCurrentHostDisabled
        switch mode {
        case .disabled:
            return nil  // Safari not frontmost; ignore.
        case .disabledBySite where !disabled:
            return setMode(defaultMode, intent: .passThrough)
        case .normal where disabled:
            return setMode(.disabledBySite, intent: .passThrough)
        default:
            return nil
        }
    }

    private var isCurrentHostDisabled: Bool {
        guard let url = currentURL else { return false }
        if sessionSuspendedURL == url { return true }
        return SitesStore.isDisabled(url: url, in: settings.disabledHosts)
    }

    private var isModeOff: Bool {
        switch mode {
        case .disabled, .disabledBySite: return true
        default: return false
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

    /// Called by the engine after `VomnibarCoordinator` finishes a
    /// session (opened a URL / cancelled). Drops back to `.normal`.
    @discardableResult
    mutating func exitVomnibarMode() -> VimDecision? {
        guard case .vomnibar = mode else { return nil }
        return setMode(.normal(prefix: .none), intent: .passThrough)
    }

    // MARK: - Per-event decide

    mutating func decide(
        eventType: CGEventType,
        keyCode: CGKeyCode,
        characters: String?,
        flags: CGEventFlags,
        timestamp: UInt64
    ) -> VimDecision {
        // Only act on keyDown. Pass keyUp through transparently.
        guard eventType == .keyDown else {
            return VimDecision(intent: .passThrough)
        }

        // Esc-Esc chord detection — runs BEFORE the disabled-mode pass-
        // through so the user can un-suspend a page they previously
        // suspended. First Esc records the timestamp; second Esc within
        // the window emits `.toggleSuspended`.
        if keyCode == VimKeyCode.escape {
            if let last = lastEscTimestamp, timestamp &- last <= Self.chordWindowNanoseconds {
                lastEscTimestamp = nil
                return VimDecision(intent: .toggleSuspended)
            }
            lastEscTimestamp = timestamp
        } else {
            lastEscTimestamp = nil
        }

        // Disabled (Safari not frontmost) or disabled-by-site: pass
        // through everything (incl. Esc).
        if case .disabled = mode {
            return VimDecision(intent: .passThrough)
        }
        if case .disabledBySite = mode {
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

        // Cmd+H / Cmd+L — tab navigation. Intercepted in any mode
        // (including insert) so users don't have to switch to normal
        // mode first. The exact-modifier check (`== .maskCommand`)
        // means Cmd+Shift+H still hides app via macOS, Cmd+Option+L
        // still works for whatever Safari has there, etc. — only the
        // unmodified Cmd+H/L chord is rerouted.
        if flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]) == .maskCommand {
            switch keyCode {
            case VimKeyCode.h:
                return VimDecision(intent: .postKey(
                    virtualKey: VimKeyCode.leftBracket,
                    flags: [.maskCommand, .maskShift]
                ))
            case VimKeyCode.l:
                return VimDecision(intent: .postKey(
                    virtualKey: VimKeyCode.rightBracket,
                    flags: [.maskCommand, .maskShift]
                ))
            default:
                break
            }
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
        case .vomnibar:
            return decideVomnibar(keyCode: keyCode, characters: characters)
        case .disabled, .disabledBySite, .insert, .find, .help:
            // Disabled / insert / help are handled above; .find arrives
            // in V-M5 (it's currently a postKey to Cmd+F).
            return VimDecision(intent: .passThrough)
        }
    }

    private func decideHint(characters: String?) -> VimDecision {
        guard let chars = characters, !chars.isEmpty else {
            return VimDecision(intent: .consume)
        }
        return VimDecision(intent: .forwardHintKey(chars))
    }

    private func decideVomnibar(keyCode: CGKeyCode, characters: String?) -> VimDecision {
        // Translate non-character keys to sentinel strings the coordinator
        // recognises. Vomnibar needs Return / backspace / up / down on
        // top of the character keys USKeyboardLayout can resolve.
        switch keyCode {
        case VimKeyCode.delete:  return VimDecision(intent: .forwardVomnibarKey("\u{08}"))
        case VimKeyCode.returnKey: return VimDecision(intent: .forwardVomnibarKey("\u{0D}"))
        case VimKeyCode.upArrow: return VimDecision(intent: .forwardVomnibarKey("\u{0B}"))
        case VimKeyCode.downArrow: return VimDecision(intent: .forwardVomnibarKey("\u{0C}"))
        default: break
        }
        guard let chars = characters, !chars.isEmpty else {
            return VimDecision(intent: .consume)
        }
        return VimDecision(intent: .forwardVomnibarKey(chars))
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
            // Esc in normal-no-prefix:
            //   - In `.insertFirst`, this is the user's way back to the
            //     default mode (.insert) — we own Esc as the toggle.
            //   - In `.autoDetect` / `.manual`, the user is already in
            //     the "active" mode by design, so we don't intercept
            //     Esc — pass it through to the page so any web-side
            //     Esc handler (modal dialogs, etc.) still works.
            if settings.insertModeBehavior == .insertFirst {
                return setMode(.insert, intent: .consume)
            }
            return VimDecision(intent: .passThrough)
        case .help:
            return setMode(.normal(prefix: .none), intent: .dismissOverlay)
        case .hint:
            return setMode(.normal(prefix: .none), intent: .dismissOverlay)
        case .vomnibar:
            return setMode(.normal(prefix: .none), intent: .dismissOverlay)
        case .disabled, .disabledBySite, .find:
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
        case .y(let count):
            return decideAfterY(count: count, chars: chars)
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

        if chars == "y" {
            // V-M4: `y` starts the yank prefix. Waits for `yy` (copy URL)
            // or `yf` (copy hint URL).
            return setMode(.normal(prefix: .y(count: nil)), intent: .consume)
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

    private mutating func decideAfterY(count: Int?, chars: String) -> VimDecision {
        guard let command = settings.bindings.yPrefix[chars] else {
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
        case .copyHintURL:
            // V-M4: `yf` — hint, but on commit copy the URL instead of
            // clicking. Coordinator branches on `copyOnly`.
            let state = HintState(openInNewTab: false, copyOnly: true, filter: .anyClickable)
            return setMode(.hint(state), intent: .requestHintTraversal(
                openInNewTab: false, copyOnly: true, filter: .anyClickable
            ))
        case .vomnibarURL:
            let flavor = VomnibarFlavor.url(openInNewTab: false)
            return setMode(.vomnibar(VomnibarState(flavor: flavor)),
                           intent: .requestVomnibar(flavor))
        case .vomnibarURLNewTab:
            let flavor = VomnibarFlavor.url(openInNewTab: true)
            return setMode(.vomnibar(VomnibarState(flavor: flavor)),
                           intent: .requestVomnibar(flavor))
        case .vomnibarTabs:
            let flavor = VomnibarFlavor.tabs
            return setMode(.vomnibar(VomnibarState(flavor: flavor)),
                           intent: .requestVomnibar(flavor))
        case .vomnibarBookmarks:
            let flavor = VomnibarFlavor.bookmarks(openInNewTab: false)
            return setMode(.vomnibar(VomnibarState(flavor: flavor)),
                           intent: .requestVomnibar(flavor))
        case .vomnibarBookmarksNewTab:
            let flavor = VomnibarFlavor.bookmarks(openInNewTab: true)
            return setMode(.vomnibar(VomnibarState(flavor: flavor)),
                           intent: .requestVomnibar(flavor))
        case .copyURL:
            // V-M4: `yy` — copy current Safari tab URL via SafariBridge.
            if fromPrefix { return setMode(.normal(prefix: .none), intent: .copyCurrentURL) }
            return VimDecision(intent: .copyCurrentURL)
        case .openClipboard:
            if fromPrefix { return setMode(.normal(prefix: .none), intent: .openClipboardURL(inNewTab: false)) }
            return VimDecision(intent: .openClipboardURL(inNewTab: false))
        case .openClipboardNewTab:
            if fromPrefix { return setMode(.normal(prefix: .none), intent: .openClipboardURL(inNewTab: true)) }
            return VimDecision(intent: .openClipboardURL(inNewTab: true))
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
        case .closeTab:
            return .postKey(virtualKey: VimKeyCode.w, flags: .maskCommand)
        case .reopenTab:
            // Cmd+Shift+T is Safari's "Reopen Last Closed Tab", stack
            // depth ≈ 10. The shortcut also works for whole-window restore
            // — if no tab was just closed but a window was, Safari opens
            // the last closed window instead.
            return .postKey(virtualKey: VimKeyCode.t, flags: [.maskCommand, .maskShift])

        // Mode-affecting commands handled by `resolveCommand`; never
        // reach here.
        case .enterInsert, .escape, .help,
             .hint, .hintNewTab, .focusInput,
             .copyURL, .copyHintURL,
             .vomnibarURL, .vomnibarURLNewTab, .vomnibarTabs,
             .vomnibarBookmarks, .vomnibarBookmarksNewTab,
             .openClipboard, .openClipboardNewTab:
            return .consume

        case .viewSource:
            // Cmd+Option+U opens Safari's View Source inspector. Posted
            // here (no hint UI needed) so `gs` round-trips through the
            // standard postKey path.
            return .postKey(virtualKey: VimKeyCode.u, flags: [.maskCommand, .maskAlternate])

        case .suspendChord:
            // Triggered by the Esc-Esc chord, not by character keys.
            // Reaching here is a forward-compat safety net.
            return .toggleSuspended
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
