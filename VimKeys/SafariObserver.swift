import AppKit
import ApplicationServices
import Foundation

/// V-M2 observer: NSWorkspace tells us when Safari is frontmost, and an AX
/// focus observer (attached only while Safari is frontmost AND
/// Accessibility is granted) tells us whether the focused element inside
/// Safari is a text input. Two callbacks: `onFrontmostChange` and
/// `onFocusEditableChange`.
@MainActor
final class SafariObserver {
    /// Bundle identifiers that count as "Safari" for activation purposes.
    /// `nonisolated` so tests and `isSafariFrontmost()` can read it without
    /// hopping to the MainActor.
    nonisolated static let safariBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
    ]

    /// Holds the NotificationCenter observer tokens. Lifted into a separate
    /// `@unchecked Sendable` class so cleanup runs from a nonisolated
    /// deinit without Swift-6 actor-isolation errors. `NSWorkspace`'s
    /// notification center is thread-safe for `removeObserver(_:)`.
    private final class Tokens: @unchecked Sendable {
        var activate: NSObjectProtocol?
        var launch: NSObjectProtocol?
        var terminate: NSObjectProtocol?

        deinit {
            let center = NSWorkspace.shared.notificationCenter
            if let activate { center.removeObserver(activate) }
            if let launch { center.removeObserver(launch) }
            if let terminate { center.removeObserver(terminate) }
        }
    }

    private let onFrontmostChange: (Bool) -> Void
    private let onFocusEditableChange: (Bool) -> Void
    private let tokens = Tokens()
    private var lastReportedFrontmost: Bool = false
    private var axFocusObserver: AXFocusObserver?

    init(
        onFrontmostChange: @escaping (Bool) -> Void,
        onFocusEditableChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.onFrontmostChange = onFrontmostChange
        self.onFocusEditableChange = onFocusEditableChange
    }

    func start() {
        stop()

        let center = NSWorkspace.shared.notificationCenter
        tokens.activate = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        tokens.launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        tokens.terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        refresh()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let activate = tokens.activate {
            center.removeObserver(activate)
            tokens.activate = nil
        }
        if let launch = tokens.launch {
            center.removeObserver(launch)
            tokens.launch = nil
        }
        if let terminate = tokens.terminate {
            center.removeObserver(terminate)
            tokens.terminate = nil
        }
        detachAXFocusObserver()
    }

    /// Re-reads the frontmost application and emits a change iff the
    /// Safari-or-not value flipped since the last report. AX-observer
    /// reconciliation runs unconditionally on every refresh: AX trust can
    /// be granted between workspace notifications, so we must (re)attach
    /// without waiting for a frontmost transition. Callable externally
    /// when the caller has reason to suspect AX trust changed.
    func refresh() {
        let isFrontmost = Self.isSafariFrontmost()

        if isFrontmost {
            if axFocusObserver == nil {
                attachAXFocusObserverIfPossible()
            }
        } else {
            detachAXFocusObserver()
        }

        guard isFrontmost != lastReportedFrontmost else { return }
        lastReportedFrontmost = isFrontmost
        onFrontmostChange(isFrontmost)
    }

    private func attachAXFocusObserverIfPossible() {
        // Skip silently if Accessibility isn't granted — scroll/find/etc.
        // still work via Input Monitoring; only insert-mode auto-detect
        // is missing until the user grants AX trust.
        guard PermissionController.hasAccessibilityTrust else { return }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }

        detachAXFocusObserver()
        let observer = AXFocusObserver(pid: pid) { [weak self] isEditable in
            self?.onFocusEditableChange(isEditable)
        }
        observer.start()
        axFocusObserver = observer
    }

    private func detachAXFocusObserver() {
        axFocusObserver?.stop()
        axFocusObserver = nil
    }

    static func isSafariFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return safariBundleIDs.contains(bundleID)
    }
}

/// Wraps an `AXObserver` subscribed to `kAXFocusedUIElementChangedNotification`
/// on Safari's `AXApplication`. On every focus change, reads the focused
/// element's role/subrole/AXEditable and emits `Bool` to its callback.
///
/// AX callback runs on whatever run loop the observer source was added to
/// (we add to the main run loop, so it lands on main); the C callback
/// hops to `@MainActor` via `Task` before invoking the @MainActor-isolated
/// onFocusChange closure.
@MainActor
final class AXFocusObserver {
    /// `@unchecked Sendable` carrier for the closure so the C callback can
    /// read it across the actor boundary. The closure itself runs on
    /// `@MainActor` via `Task`.
    private final class Bridge: @unchecked Sendable {
        var onFocusChange: ((Bool) -> Void)?
    }

    private let pid: pid_t
    private let bridge = Bridge()
    private var axObserver: AXObserver?
    private var appElement: AXUIElement?

    init(pid: pid_t, onFocusChange: @escaping (Bool) -> Void) {
        self.pid = pid
        bridge.onFocusChange = onFocusChange
    }

    func start() {
        let app = AXUIElementCreateApplication(pid)
        appElement = app

        var rawObserver: AXObserver?
        let createResult = AXObserverCreate(pid, Self.axCallback, &rawObserver)
        guard createResult == .success, let observer = rawObserver else {
            return
        }
        axObserver = observer

        let userInfo = Unmanaged.passUnretained(bridge).toOpaque()
        AXObserverAddNotification(
            observer,
            app,
            kAXFocusedUIElementChangedNotification as CFString,
            userInfo
        )
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        // Seed initial focus state — AX observers don't fire on attach,
        // only on subsequent transitions.
        emitCurrentFocus(app: app)
    }

    func stop() {
        if let axObserver, let appElement {
            AXObserverRemoveNotification(
                axObserver,
                appElement,
                kAXFocusedUIElementChangedNotification as CFString
            )
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(axObserver),
                .defaultMode
            )
        }
        axObserver = nil
        appElement = nil
    }

    private func emitCurrentFocus(app: AXUIElement) {
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focused = focusedRef else {
            bridge.onFocusChange?(false)
            return
        }
        if CFGetTypeID(focused) == AXUIElementGetTypeID() {
            // Force-cast is safe under the typeID guard. AXUIElement
            // doesn't bridge implicitly via `as?`.
            // swiftlint:disable:next force_cast
            let element = focused as! AXUIElement
            let snapshot = Self.readRoleSnapshot(of: element)
            bridge.onFocusChange?(isEditableFocus(snapshot))
        } else {
            bridge.onFocusChange?(false)
        }
    }

    private static let axCallback: AXObserverCallback = { _, element, _, userInfo in
        guard let userInfo else { return }
        let snapshot = readRoleSnapshot(of: element)
        let isEditable = isEditableFocus(snapshot)
        Task { @MainActor in
            let bridge = Unmanaged<Bridge>.fromOpaque(userInfo).takeUnretainedValue()
            bridge.onFocusChange?(isEditable)
        }
    }

    private static func readRoleSnapshot(of element: AXUIElement) -> AXRoleSnapshot {
        var snapshot = AXRoleSnapshot()

        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success {
            snapshot.role = role as? String
        }

        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success {
            snapshot.subrole = subrole as? String
        }

        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, AXRoleConstants.editableAttribute as CFString, &editable) == .success {
            snapshot.isEditableAttribute = editable as? Bool
        }

        return snapshot
    }
}
