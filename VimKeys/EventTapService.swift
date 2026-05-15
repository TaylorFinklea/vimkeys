import AppKit
import CoreGraphics
import Foundation

struct SleepWakeHandler {
    var reEnableTap: () -> Void
    var isTapAlive: () -> Bool
    var restartEngine: () -> Void
    var onError: (String) -> Void
    var onRecover: () -> Void

    private(set) var sleepPending = false

    mutating func willSleep() {
        sleepPending = true
    }

    mutating func didWake() {
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
