import AppKit
import CoreGraphics
import Foundation

/// Reference type on purpose. `didWake()` re-enters `EventTapService`'s
/// `stop()`/`start()` via `restartEngine`, and `start()` reassigns the
/// service's `sleepWakeHandler` to a brand-new handler. With a *value*
/// type, the optional-chained mutating call (`sleepWakeHandler?.didWake()`)
/// writes the stale struct back when it returns, clobbering that
/// freshly-installed handler — so every sleep/wake after the first finds
/// its `[weak engine]` captures pointing at the dead engine and silently
/// stops re-enabling the tap. A class mutates in place, so the
/// reassignment sticks. Main-thread-confined (the willSleep/didWake
/// observers use `queue: .main`), so no extra synchronization is needed.
final class SleepWakeHandler {
    private let reEnableTap: () -> Void
    private let isTapAlive: () -> Bool
    private let restartEngine: () -> Void
    private let onError: (String) -> Void
    private let onRecover: () -> Void

    private var sleepPending = false

    init(
        reEnableTap: @escaping () -> Void,
        isTapAlive: @escaping () -> Bool,
        restartEngine: @escaping () -> Void,
        onError: @escaping (String) -> Void,
        onRecover: @escaping () -> Void
    ) {
        self.reEnableTap = reEnableTap
        self.isTapAlive = isTapAlive
        self.restartEngine = restartEngine
        self.onError = onError
        self.onRecover = onRecover
    }

    func willSleep() {
        sleepPending = true
    }

    func didWake() {
        guard sleepPending else { return }
        sleepPending = false

        reEnableTap()
        if isTapAlive() {
            onRecover()
            return
        }

        onError("Restarting event tap after sleep recovery.")
        restartEngine()

        if isTapAlive() {
            onRecover()
        }
    }
}

final class EventTapService {
    var onModeChange: ((VimMode) -> Void)?
    var onTapError: ((String) -> Void)?
    var onTapRecovered: (() -> Void)?
    var onShowHelp: (() -> Void)?
    var onDismissOverlay: (() -> Void)?
    var onRequestHints: ((Bool, Bool, HintFilter) -> Void)?
    var onForwardHintKey: ((String) -> Void)?
    var onRequestVomnibar: ((VomnibarFlavor) -> Void)?
    var onForwardVomnibarKey: ((String) -> Void)?
    var onCopyCurrentURL: (() -> Void)?
    var onOpenClipboardURL: ((Bool) -> Void)?
    var onToggleSuspended: (() -> Void)?
    var onTabGroupNavigation: ((Bool) -> Void)?

    private let lock = NSLock()
    private var settings: VimSettings
    private var engine: EventTapEngine?

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sleepWakeHandler: SleepWakeHandler?

    init(settings: VimSettings = .v1Default) {
        self.settings = settings
    }

    func updateSettings(_ settings: VimSettings) {
        lock.lock()
        self.settings = settings
        engine?.updateSettings(settings)
        lock.unlock()
    }

    func updateSafariFrontmost(_ isFrontmost: Bool) {
        lock.lock()
        let engine = engine
        lock.unlock()
        engine?.updateSafariFrontmost(isFrontmost)
    }

    func updateFocusEditable(_ isEditable: Bool) {
        lock.lock()
        let engine = engine
        lock.unlock()
        engine?.updateFocusEditable(isEditable)
    }

    func updateCurrentURL(_ url: URL?) {
        lock.lock()
        let engine = engine
        lock.unlock()
        engine?.updateCurrentURL(url)
    }

    func exitHintMode() {
        lock.lock()
        let engine = engine
        lock.unlock()
        engine?.exitHintMode()
    }

    func exitVomnibarMode() {
        lock.lock()
        let engine = engine
        lock.unlock()
        engine?.exitVomnibarMode()
    }

    func toggleSuspendOnCurrentURL() {
        lock.lock()
        let engine = engine
        lock.unlock()
        engine?.toggleSuspendOnCurrentURL()
    }

    @discardableResult
    func start() -> Bool {
        stop()

        guard PermissionController.currentState().isGranted else {
            onTapError?("Input Monitoring permission has not been granted.")
            return false
        }

        let engine = EventTapEngine(
            settings: lockedSettings(),
            onModeChange: { [weak self] mode in
                self?.onModeChange?(mode)
            },
            onTapError: { [weak self] message in
                self?.onTapError?(message)
            },
            onShowHelp: { [weak self] in
                self?.onShowHelp?()
            },
            onDismissOverlay: { [weak self] in
                self?.onDismissOverlay?()
            },
            onRequestHints: { [weak self] openInNewTab, copyOnly, filter in
                self?.onRequestHints?(openInNewTab, copyOnly, filter)
            },
            onForwardHintKey: { [weak self] chars in
                self?.onForwardHintKey?(chars)
            },
            onRequestVomnibar: { [weak self] flavor in
                self?.onRequestVomnibar?(flavor)
            },
            onForwardVomnibarKey: { [weak self] chars in
                self?.onForwardVomnibarKey?(chars)
            },
            onCopyCurrentURL: { [weak self] in
                self?.onCopyCurrentURL?()
            },
            onOpenClipboardURL: { [weak self] inNewTab in
                self?.onOpenClipboardURL?(inNewTab)
            },
            onToggleSuspended: { [weak self] in
                self?.onToggleSuspended?()
            },
            onTabGroupNavigation: { [weak self] forward in
                self?.onTabGroupNavigation?(forward)
            }
        )
        let started = engine.start()
        if started {
            self.engine = engine
            installSleepWakeObservers(for: engine)
        }
        return started
    }

    func stop() {
        removeSleepWakeObservers()

        lock.lock()
        let engine = engine
        self.engine = nil
        lock.unlock()

        engine?.stop()
    }

    private func lockedSettings() -> VimSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    private func installSleepWakeObservers(for engine: EventTapEngine) {
        sleepWakeHandler = SleepWakeHandler(
            reEnableTap: { [weak engine] in engine?.reEnableTap() },
            isTapAlive: { [weak engine] in engine?.isTapAlive() ?? false },
            restartEngine: { [weak self] in
                guard let self else { return }
                self.stop()
                _ = self.start()
            },
            onError: { [weak self] message in
                self?.onTapError?(message)
            },
            onRecover: { [weak self] in
                self?.onTapRecovered?()
            }
        )

        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sleepWakeHandler?.willSleep()
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sleepWakeHandler?.didWake()
        }
    }

    private func removeSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver {
            center.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            center.removeObserver(wakeObserver)
        }
        sleepObserver = nil
        wakeObserver = nil
        sleepWakeHandler = nil
    }
}
