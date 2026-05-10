import AppKit
import Foundation

/// V-M1 minimal observer: only watches whether Safari (or Safari Tech
/// Preview) is the frontmost application via `NSWorkspace`. AX observers
/// for focus changes / URL changes / focused-window changes arrive in
/// V-M2; AppleScript bridge in V-M4.
///
/// Lives on `@MainActor` because `NSWorkspace.shared.frontmostApplication`
/// is main-thread-affine and the observer callbacks land on the queue
/// they were registered with.
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
    /// `@unchecked Sendable` class so cleanup can run from a nonisolated
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
    private let tokens = Tokens()
    private var lastReportedFrontmost: Bool = false

    init(onFrontmostChange: @escaping (Bool) -> Void) {
        self.onFrontmostChange = onFrontmostChange
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
    }

    /// Re-reads the frontmost application and emits a change iff the
    /// Safari-or-not value flipped since the last report.
    private func refresh() {
        let isFrontmost = Self.isSafariFrontmost()
        guard isFrontmost != lastReportedFrontmost else { return }
        lastReportedFrontmost = isFrontmost
        onFrontmostChange(isFrontmost)
    }

    static func isSafariFrontmost() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return safariBundleIDs.contains(bundleID)
    }
}
