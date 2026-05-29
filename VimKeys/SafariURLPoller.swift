import Foundation

/// Polls Safari's frontmost URL on a timer while Safari is frontmost and
/// reports changes to a sink (the event-tap engine, which drives the
/// per-site ignorelist + Esc-Esc). Extracted from `AppModel` so the poll
/// *decision* logic — the permission gate, the transient-nil skip, and the
/// dedupe — is unit-testable without a live `CGEventTap` or Safari.
///
/// Dependencies are injected as closures so tests can drive `poll()`
/// synchronously with a fake bridge:
/// - `currentURL` / `hasAccess` read from `SafariBridge` in production.
/// - `onURLChange` forwards to `EventTapService.updateCurrentURL`.
@MainActor
final class SafariURLPoller {
    private let interval: DispatchTimeInterval
    private let currentURL: @MainActor () -> URL?
    private let hasAccess: @MainActor () -> Bool
    private let onURLChange: @MainActor (URL?) -> Void

    private var timer: DispatchSourceTimer?
    private var lastReportedURL: URL?

    init(
        interval: DispatchTimeInterval = .milliseconds(1500),
        hasAccess: @escaping @MainActor () -> Bool,
        currentURL: @escaping @MainActor () -> URL?,
        onURLChange: @escaping @MainActor (URL?) -> Void
    ) {
        self.interval = interval
        self.hasAccess = hasAccess
        self.currentURL = currentURL
        self.onURLChange = onURLChange
    }

    /// Begin polling. Fires once immediately so the disabled-by-site state
    /// is current before the user can press a key, then on `interval`. The
    /// timer keeps running even before Automation is granted; each tick
    /// re-checks permission (without prompting) and starts feeding URLs the
    /// moment the user grants access via a gesture or the Permissions button.
    func start() {
        stop()
        poll()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()
    }

    /// Stop polling. Deliberately does NOT push `onURLChange(nil)` — nulling
    /// the URL on every Cmd-Tab away cleared the disabled-by-site state, so
    /// returning to a disabled site flashed VimKeys back on (live) until the
    /// next poll round-tripped. Retaining the last URL lets the frontmost
    /// transition re-enter `.disabledBySite` immediately on return; the
    /// resumed poll then re-confirms.
    func stop() {
        timer?.cancel()
        timer = nil
        lastReportedURL = nil
    }

    /// One poll tick. Returns `true` iff it reported a new URL (used by
    /// tests). Gates on permission WITHOUT prompting — the background poll
    /// must never raise the Automation consent dialog. A nil URL (transient
    /// AppleScript failure, or no windows which the frontmost transition
    /// already handles) is skipped rather than forwarded, so it can't
    /// reconcile a genuinely disabled site back to enabled.
    @discardableResult
    func poll() -> Bool {
        guard hasAccess() else { return false }
        guard let url = currentURL() else { return false }
        guard url != lastReportedURL else { return false }
        lastReportedURL = url
        onURLChange(url)
        return true
    }
}
