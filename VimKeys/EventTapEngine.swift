import AppKit
import CoreGraphics
import Foundation

/// Owns the `CGEvent.tapCreate` handle on a dedicated `VimKeys.EventTap`
/// thread with its own `CFRunLoop`. Pure-value `VimStateMachine` lives
/// inside; per-event `decide(...)` runs on the tap thread, intent
/// dispatch (scroll wheel, Cmd+Up/Down, etc.) runs in the same callback
/// for latency.
final class EventTapEngine: NSObject, @unchecked Sendable {
    /// Tag stamped onto every event we synthesize (scroll wheel,
    /// Cmd+Up/Down for scroll-to-edge). On re-entry the tap callback
    /// notices the tag and passes through without re-processing — never
    /// strip this or the engine will loop on its own emissions.
    private static let syntheticEventTag: Int64 = 0x564B595300000000  // "VKYS\0\0\0\0"

    /// One-shot timer that fires after 1500 ms of no follow-up to reset a
    /// pending count / `g` / `y` prefix. Lives on `timerQueue` so it
    /// doesn't block the tap callback; on fire, hops back to the tap
    /// thread to mutate state machine.
    private static let prefixTimeoutNanoseconds: UInt64 = 1_500_000_000

    private let stateMachineLock = NSLock()
    private var stateMachine: VimStateMachine
    private let onModeChange: (VimMode) -> Void
    private let onTapError: (String) -> Void
    private let onShowHelp: () -> Void
    private let onDismissOverlay: () -> Void
    private let onRequestHints: (Bool, Bool, HintFilter) -> Void
    private let onForwardHintKey: (String) -> Void
    private let onRequestVomnibar: (VomnibarFlavor) -> Void
    private let onForwardVomnibarKey: (String) -> Void
    private let onCopyCurrentURL: () -> Void
    private let onOpenClipboardURL: (Bool) -> Void
    private let onToggleSuspended: () -> Void
    private let onTabGroupNavigation: (Bool) -> Void

    private var thread: Thread?
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    private let timerQueue = DispatchQueue(label: "io.taylorfinklea.vimkeys.prefixTimer")
    private var pendingTimeoutTimer: DispatchSourceTimer?

    init(
        settings: VimSettings,
        onModeChange: @escaping (VimMode) -> Void,
        onTapError: @escaping (String) -> Void,
        onShowHelp: @escaping () -> Void = {},
        onDismissOverlay: @escaping () -> Void = {},
        onRequestHints: @escaping (Bool, Bool, HintFilter) -> Void = { _, _, _ in },
        onForwardHintKey: @escaping (String) -> Void = { _ in },
        onRequestVomnibar: @escaping (VomnibarFlavor) -> Void = { _ in },
        onForwardVomnibarKey: @escaping (String) -> Void = { _ in },
        onCopyCurrentURL: @escaping () -> Void = {},
        onOpenClipboardURL: @escaping (Bool) -> Void = { _ in },
        onToggleSuspended: @escaping () -> Void = {},
        onTabGroupNavigation: @escaping (Bool) -> Void = { _ in }
    ) {
        stateMachine = VimStateMachine(settings: settings)
        self.onModeChange = onModeChange
        self.onTapError = onTapError
        self.onShowHelp = onShowHelp
        self.onDismissOverlay = onDismissOverlay
        self.onRequestHints = onRequestHints
        self.onForwardHintKey = onForwardHintKey
        self.onRequestVomnibar = onRequestVomnibar
        self.onForwardVomnibarKey = onForwardVomnibarKey
        self.onCopyCurrentURL = onCopyCurrentURL
        self.onOpenClipboardURL = onOpenClipboardURL
        self.onToggleSuspended = onToggleSuspended
        self.onTabGroupNavigation = onTabGroupNavigation
    }

    /// Called by AppModel after the user binds `Esc-Esc` from a UI button
    /// (vs. the engine emitting `.toggleSuspended` from a chord). Safe
    /// from any thread.
    func toggleSuspendOnCurrentURL() {
        guard let thread else { return }
        perform(#selector(toggleSuspendOnThread), on: thread, with: nil, waitUntilDone: false)
    }

    @objc
    private func toggleSuspendOnThread() {
        stateMachineLock.lock()
        let decision = stateMachine.toggleSuspendOnCurrentURL()
        let mode = stateMachine.mode
        stateMachineLock.unlock()
        if decision != nil {
            onModeChange(mode)
        }
    }

    func updateSettings(_ settings: VimSettings) {
        stateMachineLock.lock()
        stateMachine.settings = settings
        stateMachineLock.unlock()
    }

    /// Tells the state machine whether Safari (or Safari Tech Preview) is
    /// frontmost. Safe to call from any thread; hops to the engine thread
    /// so the state machine is only ever mutated from one place.
    func updateSafariFrontmost(_ isFrontmost: Bool) {
        guard let thread else { return }
        let flag = BoolBox(value: isFrontmost)
        perform(#selector(updateSafariFrontmostOnThread(_:)), on: thread, with: flag, waitUntilDone: false)
    }

    /// Tells the state machine whether Safari's focused element is editable.
    /// Honored only when `InsertModeBehavior == .autoDetect`. Safe to call
    /// from any thread.
    func updateFocusEditable(_ isEditable: Bool) {
        guard let thread else { return }
        let flag = BoolBox(value: isEditable)
        perform(#selector(updateFocusEditableOnThread(_:)), on: thread, with: flag, waitUntilDone: false)
    }

    /// Tells the state machine the current Safari URL so it can disable
    /// itself per-site. Safe to call from any thread; debounced by the
    /// AppModel poll loop.
    func updateCurrentURL(_ url: URL?) {
        guard let thread else { return }
        let carrier = URLBox(value: url)
        perform(#selector(updateCurrentURLOnThread(_:)), on: thread, with: carrier, waitUntilDone: false)
    }

    @objc
    private func updateCurrentURLOnThread(_ carrier: URLBox) {
        stateMachineLock.lock()
        let decision = stateMachine.updateCurrentURL(carrier.value)
        let mode = stateMachine.mode
        stateMachineLock.unlock()
        if decision != nil {
            onModeChange(mode)
        }
    }

    /// Called by `LinkHintCoordinator` after a hint session ends (clicked,
    /// copied, or cancelled). Steps the state machine back to `.normal`.
    /// Safe to call from any thread; hops to the engine thread.
    func exitHintMode() {
        guard let thread else { return }
        perform(#selector(exitHintModeOnThread), on: thread, with: nil, waitUntilDone: false)
    }

    @objc
    private func exitHintModeOnThread() {
        stateMachineLock.lock()
        let decision = stateMachine.exitHintMode()
        let mode = stateMachine.mode
        stateMachineLock.unlock()

        if decision != nil {
            onModeChange(mode)
        }
    }

    /// Called by `VomnibarCoordinator` after a session ends.
    func exitVomnibarMode() {
        guard let thread else { return }
        perform(#selector(exitVomnibarModeOnThread), on: thread, with: nil, waitUntilDone: false)
    }

    @objc
    private func exitVomnibarModeOnThread() {
        stateMachineLock.lock()
        let decision = stateMachine.exitVomnibarMode()
        let mode = stateMachine.mode
        stateMachineLock.unlock()

        if decision != nil {
            onModeChange(mode)
        }
    }

    /// Idempotently re-enables the event tap on the engine thread. Safe to
    /// call from any thread. If the tap port no longer exists this is a no-op.
    func reEnableTap() {
        guard let thread else { return }
        perform(#selector(reEnableTapOnThread), on: thread, with: nil, waitUntilDone: true)
    }

    /// Whether the kernel still considers our tap active. Synchronously hops
    /// to the engine thread to read `tapPort`.
    func isTapAlive() -> Bool {
        guard let thread else { return false }
        let probe = TapLivenessProbe()
        perform(#selector(checkTapAliveOnThread(_:)), on: thread, with: probe, waitUntilDone: true)
        return probe.isAlive
    }

    @objc
    private func reEnableTapOnThread() {
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: true)
        }
    }

    @objc
    private func checkTapAliveOnThread(_ probe: TapLivenessProbe) {
        if let tapPort {
            probe.isAlive = CGEvent.tapIsEnabled(tap: tapPort)
        } else {
            probe.isAlive = false
        }
    }

    @objc
    private func updateSafariFrontmostOnThread(_ flag: BoolBox) {
        stateMachineLock.lock()
        let decision = stateMachine.updateSafariFrontmost(flag.value)
        let mode = stateMachine.mode
        stateMachineLock.unlock()

        if let decision {
            onModeChange(mode)
            cancelPrefixTimeout()
            // Backgrounding out of an overlay mode asks us to dismiss it
            // (otherwise the panel is orphaned — see updateSafariFrontmost).
            // Unlike the keystroke path, this entry point doesn't run
            // through `apply(intent:)`, so dispatch the dismiss directly.
            if decision.intent == .dismissOverlay {
                onDismissOverlay()
            }
        }
    }

    @objc
    private func updateFocusEditableOnThread(_ flag: BoolBox) {
        stateMachineLock.lock()
        let decision = stateMachine.updateFocusEditable(flag.value)
        let mode = stateMachine.mode
        stateMachineLock.unlock()

        if decision != nil {
            onModeChange(mode)
        }
    }

    func start() -> Bool {
        let startup = EventTapStartup()
        let thread = Thread(target: self, selector: #selector(runEventTapThread(_:)), object: startup)

        self.thread = thread
        thread.start()
        startup.semaphore.wait()
        return startup.didStart
    }

    func stop() {
        cancelPrefixTimeout()

        guard let thread else {
            return
        }

        perform(#selector(stopRunLoop), on: thread, with: nil, waitUntilDone: true)
        self.thread = nil
    }

    @objc
    private func stopRunLoop() {
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
        }

        if let runLoopSource, let runLoop {
            CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
        }

        tapPort = nil
        runLoopSource = nil
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        runLoop = nil
    }

    @objc
    private func runEventTapThread(_ startup: EventTapStartup) {
        Thread.current.name = "VimKeys.EventTap"
        runLoop = CFRunLoopGetCurrent()

        let eventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let engine = Unmanaged<EventTapEngine>.fromOpaque(userInfo).takeUnretainedValue()
                return engine.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            onTapError("VimKeys could not create the keyboard event tap.")
            startup.semaphore.signal()
            return
        }

        self.tapPort = tapPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tapPort, 0)
        runLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tapPort, enable: true)

        startup.didStart = true
        startup.semaphore.signal()
        CFRunLoopRun()
    }

    private func handle(
        proxy _: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reEnableTapOnThread()
            return Unmanaged.passUnretained(event)
        }

        // Skip events we synthesized ourselves.
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        // Resolve characters against the *current* keyboard layout via a
        // MainActor-refreshed snapshot. UCKeyTranslate is a pure function
        // over the cached layout data so it's safe to call from the tap
        // thread — no HIToolbox TextInputSources path, hence no macOS-26
        // main-thread assertion.
        let characters = KeyboardLayoutCache.shared.characters(
            forKeyCode: keyCode,
            flags: event.flags
        )

        stateMachineLock.lock()
        let decision = stateMachine.decide(
            eventType: type,
            keyCode: keyCode,
            characters: characters,
            flags: event.flags,
            timestamp: event.timestamp
        )
        let modeAfter = stateMachine.mode
        stateMachineLock.unlock()

        if decision.modeDidChange {
            onModeChange(modeAfter)
        }

        scheduleOrCancelTimeout(for: modeAfter)

        return apply(intent: decision.intent, originalEvent: event)
    }

    private func apply(intent: VimIntent, originalEvent: CGEvent) -> Unmanaged<CGEvent>? {
        switch intent {
        case .passThrough:
            return Unmanaged.passUnretained(originalEvent)

        case .consume:
            return nil

        case let .scroll(direction, amount):
            postScroll(direction: direction, amount: amount)
            return nil

        case let .scrollToEdge(edge):
            postScrollToEdge(edge)
            return nil

        case let .postKey(virtualKey, flags):
            postKey(virtualKey: virtualKey, flags: flags)
            return nil

        case .showOverlay(.help):
            onShowHelp()
            return nil

        case .dismissOverlay:
            onDismissOverlay()
            return nil

        case let .requestHintTraversal(openInNewTab, copyOnly, filter):
            onRequestHints(openInNewTab, copyOnly, filter)
            return nil

        case let .forwardHintKey(chars):
            onForwardHintKey(chars)
            return nil

        case let .requestVomnibar(flavor):
            onRequestVomnibar(flavor)
            return nil

        case let .forwardVomnibarKey(chars):
            onForwardVomnibarKey(chars)
            return nil

        case .copyCurrentURL:
            onCopyCurrentURL()
            return nil

        case let .openClipboardURL(inNewTab):
            onOpenClipboardURL(inNewTab)
            return nil

        case .toggleSuspended:
            onToggleSuspended()
            return nil

        case .previousTabGroup:
            onTabGroupNavigation(false)
            return nil

        case .nextTabGroup:
            onTabGroupNavigation(true)
            return nil

        case .unfocusActiveElement:
            // Post a plain Escape: Safari uses it to blur the focused field.
            postKey(virtualKey: VimKeyCode.escape, flags: [])
            return nil

        case .updateOverlay,
             .dispatchHintClick,
             .requestSafariURL, .requestBookmarks, .requestOpenTabs,
             .openURL, .copyToClipboard,
             .showHelp:
            // Forward-compat: future milestones bind these. Falling back
            // to passThrough means a binding case that escapes into the
            // catalog accidentally won't silently swallow keystrokes.
            return Unmanaged.passUnretained(originalEvent)
        }
    }

    private func postScroll(direction: ScrollDirection, amount: ScrollAmount) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let lineMagnitude: Int32
        switch amount {
        case .lines(let n):
            lineMagnitude = Int32(n)
        case .halfPage(let n):
            lineMagnitude = Int32(n * VimStateMachine.halfPageLinesApprox)
        }

        let wheel1: Int32
        let wheel2: Int32
        switch direction {
        case .vertical:
            wheel1 = lineMagnitude
            wheel2 = 0
        case .horizontal:
            wheel1 = 0
            wheel2 = lineMagnitude
        }

        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ) else { return }

        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        event.post(tap: .cghidEventTap)
    }

    private func postScrollToEdge(_ edge: VerticalEdge) {
        let virtualKey: CGKeyCode
        switch edge {
        case .top:
            virtualKey = VimKeyCode.upArrow
        case .bottom:
            virtualKey = VimKeyCode.downArrow
        }

        postKey(virtualKey: virtualKey, flags: .maskCommand)
    }

    /// Synthesize a keyDown + keyUp for `virtualKey` with `flags`. Each
    /// posted event is tagged with `syntheticEventTag` so the tap callback
    /// passes them through on re-entry instead of re-processing.
    private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        for isKeyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: virtualKey,
                keyDown: isKeyDown
            ) else { continue }

            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Prefix timeout

    private func scheduleOrCancelTimeout(for mode: VimMode) {
        let needsTimeout: Bool
        switch mode {
        case .normal(let prefix):
            needsTimeout = prefix != .none
        default:
            needsTimeout = false
        }

        if needsTimeout {
            schedulePrefixTimeout()
        } else {
            cancelPrefixTimeout()
        }
    }

    private func schedulePrefixTimeout() {
        timerQueue.async { [weak self] in
            guard let self else { return }
            self.pendingTimeoutTimer?.cancel()

            let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
            timer.schedule(
                deadline: .now() + .nanoseconds(Int(Self.prefixTimeoutNanoseconds))
            )
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.handlePrefixTimeoutFired()
            }
            self.pendingTimeoutTimer = timer
            timer.resume()
        }
    }

    private func cancelPrefixTimeout() {
        timerQueue.async { [weak self] in
            self?.pendingTimeoutTimer?.cancel()
            self?.pendingTimeoutTimer = nil
        }
    }

    private func handlePrefixTimeoutFired() {
        pendingTimeoutTimer = nil
        guard let thread else { return }
        perform(#selector(commandTimeoutOnThread), on: thread, with: nil, waitUntilDone: false)
    }

    @objc
    private func commandTimeoutOnThread() {
        stateMachineLock.lock()
        let decision = stateMachine.commandTimeout()
        let mode = stateMachine.mode
        stateMachineLock.unlock()

        if decision.modeDidChange {
            onModeChange(mode)
        }
    }
}

final class EventTapStartup: NSObject {
    let semaphore = DispatchSemaphore(value: 0)
    var didStart = false
}

final class TapLivenessProbe: NSObject {
    var isAlive = false
}

/// Single-field Objective-C-bridgeable carrier so we can hop a `Bool` over
/// to the tap thread via `perform(_:on:thread:with:)`.
final class BoolBox: NSObject {
    let value: Bool
    init(value: Bool) {
        self.value = value
    }
}

/// Same idea for `URL?`.
final class URLBox: NSObject {
    let value: URL?
    init(value: URL?) {
        self.value = value
    }
}
