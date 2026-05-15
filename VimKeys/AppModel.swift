import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: VimMode = .disabled
    @Published var permissionState: PermissionState
    @Published var accessibilityGranted: Bool
    @Published var settings: VimSettings
    @Published var lastError: String?
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var tapErrorActive: Bool = false
    @Published private(set) var updateAvailable: Bool = false

    /// True only when both Input Monitoring and Accessibility are granted.
    /// The status-menu permission rows hide themselves on this condition —
    /// once everything is wired up the user shouldn't have to see green
    /// checkmarks in the menu every time they open it.
    var allPermissionsGranted: Bool {
        permissionState != .denied && accessibilityGranted
    }

    private let settingsStore: SettingsStore
    private let eventTapService: EventTapService
    private let safariObserver: SafariObserver
    private let launchAtLoginController: LaunchAtLoginController
    private let overlayManager: OverlayManager
    private let linkHintCoordinator: LinkHintCoordinator
    private let vomnibarCoordinator: VomnibarCoordinator
    private let safariBridge: SafariBridge
    private let userDefaults: UserDefaults

    /// Repeating timer that polls `SafariBridge.currentURL()` while Safari
    /// is frontmost. Cancelled when Safari becomes background. Cheap —
    /// the AE call is local. Cadence (1.5s) is the trade-off between
    /// per-site latency and CPU; bump down if it feels sluggish.
    private var urlPollTimer: DispatchSourceTimer?
    private static let urlPollInterval: DispatchTimeInterval = .milliseconds(1500)
    private var lastReportedURL: URL?

    static let didShowLaunchAtLoginPromptKey = "didShowLaunchAtLoginPrompt"

    init(
        settingsStore: SettingsStore = .shared,
        eventTapService: EventTapService? = nil,
        launchAtLoginController: LaunchAtLoginController? = nil,
        overlayManager: OverlayManager? = nil,
        linkHintCoordinator: LinkHintCoordinator? = nil,
        vomnibarCoordinator: VomnibarCoordinator? = nil,
        safariBridge: SafariBridge = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.settingsStore = settingsStore
        self.userDefaults = userDefaults
        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings
        permissionState = PermissionController.currentState()
        accessibilityGranted = PermissionController.hasPostEventAccess

        let service = eventTapService ?? EventTapService(settings: loadedSettings)
        self.eventTapService = service

        let controller = launchAtLoginController ?? LaunchAtLoginController()
        self.launchAtLoginController = controller
        launchAtLoginEnabled = controller.isEnabled

        let manager = overlayManager ?? OverlayManager()
        self.overlayManager = manager

        let hintCoordinator = linkHintCoordinator ?? LinkHintCoordinator()
        self.linkHintCoordinator = hintCoordinator
        hintCoordinator.onExitHintMode = { [weak service] in
            service?.exitHintMode()
        }

        let vomnibar = vomnibarCoordinator ?? VomnibarCoordinator(bridge: safariBridge)
        self.vomnibarCoordinator = vomnibar
        vomnibar.onExitVomnibar = { [weak service] in
            service?.exitVomnibarMode()
        }
        // `onError` captures `self` weakly so it has to be installed after
        // every stored property is initialized — done lower in init().
        self.safariBridge = safariBridge

        // Wire SafariObserver callbacks via a deferred closure so we can
        // reference `self` once init returns. The Bool flows through
        // SafariObserver -> AppModel -> EventTapService -> EventTapEngine ->
        // VimStateMachine on the engine thread.
        var frontmostCallback: ((Bool) -> Void)?
        var focusCallback: ((Bool) -> Void)?
        safariObserver = SafariObserver(
            onFrontmostChange: { isFrontmost in frontmostCallback?(isFrontmost) },
            onFocusEditableChange: { isEditable in focusCallback?(isEditable) }
        )
        frontmostCallback = { [weak self] isFrontmost in
            self?.safariFrontmostChanged(isFrontmost)
        }
        focusCallback = { [weak self] isEditable in
            self?.safariFocusEditableChanged(isEditable)
        }

        service.onModeChange = { [weak self] mode in
            Task { @MainActor in
                self?.mode = mode
            }
        }
        service.onTapError = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
                self?.tapErrorActive = true
            }
        }
        service.onTapRecovered = { [weak self] in
            Task { @MainActor in
                self?.tapErrorActive = false
            }
        }
        service.onShowHelp = { [weak self] in
            Task { @MainActor in
                self?.overlayManager.showHelp()
            }
        }
        service.onDismissOverlay = { [weak self] in
            Task { @MainActor in
                self?.overlayManager.dismiss()
                self?.linkHintCoordinator.cancel()
                self?.vomnibarCoordinator.cancel()
            }
        }
        service.onRequestHints = { [weak self] openInNewTab, copyOnly, filter in
            Task { @MainActor in
                guard let self else { return }
                self.linkHintCoordinator.start(
                    openInNewTab: openInNewTab,
                    copyOnly: copyOnly,
                    filter: filter,
                    alphabet: self.settings.hintAlphabet
                )
            }
        }
        service.onForwardHintKey = { [weak self] chars in
            Task { @MainActor in
                self?.linkHintCoordinator.handleKey(chars: chars)
            }
        }
        service.onRequestVomnibar = { [weak self] flavor in
            Task { @MainActor in
                self?.vomnibarCoordinator.start(flavor: flavor)
            }
        }
        service.onForwardVomnibarKey = { [weak self] chars in
            Task { @MainActor in
                self?.vomnibarCoordinator.handleKey(chars: chars)
            }
        }
        service.onCopyCurrentURL = { [weak self] in
            Task { @MainActor in
                self?.copyCurrentSafariURL()
            }
        }
        service.onOpenClipboardURL = { [weak self] inNewTab in
            Task { @MainActor in
                self?.openClipboardURL(inNewTab: inNewTab)
            }
        }
        service.onToggleSuspended = { [weak service] in
            // Esc-Esc chord. State machine already detected the chord
            // and emitted the intent; engine routes it back to itself
            // (via service) so the toggle happens on the engine thread
            // where the state machine lives.
            service?.toggleSuspendOnCurrentURL()
        }

        // Vomnibar error sink (deferred from above): bookmarks reads
        // surface FDA-denied messages here so the user has a breadcrumb.
        vomnibar.onError = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
            }
        }

        if permissionState.isGranted {
            if !service.start() {
                lastError = "VimKeys could not start the global event tap."
            }
        }

        // Seed the keyboard layout cache so the engine's character
        // resolver can use UCKeyTranslate from the tap thread on the very
        // first keystroke. Refreshed automatically on input-source change.
        KeyboardLayoutCache.shared.start()

        safariObserver.start()
        // Seed the engine with the current frontmost state — SafariObserver
        // emits only on transitions, so the very first one is silent.
        service.updateSafariFrontmost(SafariObserver.isSafariFrontmost())

        if !didShowLaunchAtLoginPrompt && !Self.isRunningUnderXCTest {
            Task { @MainActor [weak self] in
                self?.showLaunchAtLoginPromptIfNeeded()
            }
        }
    }

    /// True when the host process is the XCTest runner. We skip the
    /// first-launch NSAlert in that case because `runModal()` blocks the host
    /// app's run loop, which makes the test runner time out before it can
    /// start executing tests on a fresh CI runner where
    /// `didShowLaunchAtLoginPrompt` is still false.
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func showLaunchAtLoginPromptIfNeeded() {
        guard !didShowLaunchAtLoginPrompt else { return }

        let alert = NSAlert()
        alert.messageText = "Start VimKeys at login?"
        alert.informativeText = "Run VimKeys automatically when you sign in. You can change this anytime in Settings → General."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start at Login")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        markLaunchAtLoginPromptShown()
        if response == .alertFirstButtonReturn {
            setLaunchAtLogin(true)
        }
    }

    var didShowLaunchAtLoginPrompt: Bool {
        userDefaults.bool(forKey: Self.didShowLaunchAtLoginPromptKey)
    }

    func markLaunchAtLoginPromptShown() {
        userDefaults.set(true, forKey: Self.didShowLaunchAtLoginPromptKey)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginController.setEnabled(enabled)
            launchAtLoginEnabled = launchAtLoginController.isEnabled
            lastError = nil
        } catch {
            lastError = "Couldn't change launch-at-login: \(error.localizedDescription)"
        }
    }

    func toggleLaunchAtLogin() {
        setLaunchAtLogin(!launchAtLoginEnabled)
    }

    func setInsertModeBehavior(_ behavior: InsertModeBehavior) {
        guard settings.insertModeBehavior != behavior else { return }
        settings.insertModeBehavior = behavior
        settingsStore.save(settings)
        eventTapService.updateSettings(settings)
    }

    func setHintAlphabet(_ alphabet: String) {
        // Strip whitespace and case-normalize so the persisted value
        // matches what `LinkHintEngine` consumes. Empty string falls back
        // to the default alphabet inside the engine.
        let normalized = alphabet.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard settings.hintAlphabet != normalized else { return }
        settings.hintAlphabet = normalized
        settingsStore.save(settings)
        eventTapService.updateSettings(settings)
    }

    /// Backwards-compatible entry point — requests both permissions. Kept
    /// for any caller that still wants a single nudge; new UI uses the
    /// per-permission methods below so each row has its own button.
    func requestPermission() {
        requestInputMonitoring()
        requestAccessibility()
    }

    func requestInputMonitoring() {
        // `CGRequestListenEventAccess` is the documented entry point, but
        // empirically it doesn't always populate the Input Monitoring list
        // after a prior denial. Combining the request with a real
        // `CGEvent.tapCreate` attempt forces TCC to notice us — the tap
        // fails to instantiate when permission is missing, and that
        // failure is what triggers the daemon to add VimKeys to the
        // visible list.
        let granted = PermissionController.requestListenAccess()
        PermissionController.probeInputMonitoringRegistration()
        refreshPermissionState()
        if granted {
            restartEventTap()
            return
        }
        openSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func requestAccessibility() {
        // `AXIsProcessTrustedWithOptions` with the prompt option is the
        // standard mechanism for registering an app in the Accessibility
        // TCC list and reliably populates the list even after a prior
        // denial — more so than `CGRequestPostEventAccess`. We still
        // call the CG variant as a belt-and-braces measure.
        let granted = PermissionController.requestAccessibilityWithPrompt()
            || PermissionController.requestPostAccess()
        refreshPermissionState()
        if granted {
            restartEventTap()
            return
        }
        openSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func openSettings(url: String) {
        // TCC's auto-add happens via XPC after the request returns, so
        // we wait briefly before opening Settings — otherwise the pane
        // is painted before VimKeys has been added to the list and the
        // user sees an empty entry. 500 ms is enough in practice and
        // short enough to feel responsive.
        guard let url = URL(string: url) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunches VimKeys. The kernel binds an event tap's permission
    /// snapshot at creation time and won't upgrade it even after TCC says
    /// yes, so granting Input Monitoring or Accessibility to a running
    /// instance still produces a dead tap. A fresh process is the only
    /// reliable way to pick the new permissions up.
    func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        // Brief delay so the current process is fully gone before `open`
        // looks for a duplicate; otherwise LaunchServices reuses the
        // dying instance and silently no-ops.
        task.arguments = ["-c", "sleep 0.4 && /usr/bin/open \"\(bundlePath)\""]
        do {
            try task.run()
        } catch {
            lastError = "Couldn't relaunch VimKeys: \(error.localizedDescription)"
            return
        }
        NSApp.terminate(nil)
    }

    func refreshPermissionState() {
        permissionState = PermissionController.currentState()
        accessibilityGranted = PermissionController.hasPostEventAccess
        // AX trust may have flipped since the last workspace notification —
        // poke SafariObserver so the AX focus observer reconciles. Without
        // this, granting Accessibility while Safari is already frontmost
        // leaves the focus observer detached until the next Cmd-Tab.
        safariObserver.refresh()
    }

    func restartEventTap() {
        mode = .disabled
        eventTapService.updateSettings(settings)
        guard permissionState.isGranted else {
            eventTapService.stop()
            return
        }

        if !eventTapService.start() {
            lastError = "VimKeys could not start the global event tap."
        } else {
            lastError = nil
            // Re-seed Safari frontmost state into the new engine. The AX
            // focus observer (if attached) will fire its own seed.
            eventTapService.updateSafariFrontmost(SafariObserver.isSafariFrontmost())
        }
    }

    func safariFrontmostChanged(_ isFrontmost: Bool) {
        eventTapService.updateSafariFrontmost(isFrontmost)
        if isFrontmost {
            startURLPoll()
        } else {
            stopURLPoll()
        }
    }

    /// Begin polling Safari's frontmost URL. AppleScript polling is
    /// cheaper than continuous AX observation here — AX's URL-changed
    /// notification isn't reliable on all Safari versions, and a 1.5s
    /// poll matches Vimium's "couple-second" latency expectations.
    private func startURLPoll() {
        stopURLPoll()
        guard safariBridge.hasAccess else { return }
        // Fire once immediately so the disabled-by-site state is current
        // before the user has a chance to press a key.
        pollSafariURL()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.urlPollInterval, repeating: Self.urlPollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollSafariURL()
        }
        urlPollTimer = timer
        timer.resume()
    }

    private func stopURLPoll() {
        urlPollTimer?.cancel()
        urlPollTimer = nil
        lastReportedURL = nil
        eventTapService.updateCurrentURL(nil)
    }

    private func pollSafariURL() {
        let url = safariBridge.currentURL()
        if url != lastReportedURL {
            lastReportedURL = url
            eventTapService.updateCurrentURL(url)
        }
    }

    func addDisabledHost(_ host: String) {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty, !settings.disabledHosts.contains(normalized) else { return }
        settings.disabledHosts.append(normalized)
        settingsStore.save(settings)
        eventTapService.updateSettings(settings)
    }

    func removeDisabledHost(at index: Int) {
        guard settings.disabledHosts.indices.contains(index) else { return }
        settings.disabledHosts.remove(at: index)
        settingsStore.save(settings)
        eventTapService.updateSettings(settings)
    }

    func disableCurrentHost() {
        guard let host = lastReportedURL?.host else { return }
        addDisabledHost(host)
    }

    func safariFocusEditableChanged(_ isEditable: Bool) {
        eventTapService.updateFocusEditable(isEditable)
    }

    /// Yank the URL of Safari's frontmost tab into the system clipboard
    /// via `SafariBridge`. Surfaces missing Apple-Events trust as a flash
    /// in `lastError` so users have a breadcrumb pointing at Privacy &
    /// Security → Automation.
    func copyCurrentSafariURL() {
        guard let url = safariBridge.currentURL() else {
            if !safariBridge.hasAccess {
                lastError = "Grant Apple Events access (Privacy & Security \u{2192} Automation \u{2192} Safari)."
            }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Open whatever URL is currently on the clipboard. Falls back to a
    /// DuckDuckGo search if the clipboard contents don't parse as a URL.
    /// Used by `p` / `P` ("paste and go" — Vimium convention).
    func openClipboardURL(inNewTab: Bool) {
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.isEmpty else { return }
        let url: URL
        if let parsed = URL(string: raw), parsed.scheme != nil {
            url = parsed
        } else if raw.contains("."), !raw.contains(" "),
                  let stripped = URL(string: "https://" + raw) {
            url = stripped
        } else if var components = URLComponents(string: "https://duckduckgo.com/") {
            components.queryItems = [URLQueryItem(name: "q", value: raw)]
            guard let search = components.url else { return }
            url = search
        } else {
            return
        }
        safariBridge.open(url: url, inNewTab: inNewTab)
    }

    var menuBarVariant: (variant: MenuBarIconView.Variant, badge: Bool) {
        resolveMenuBarVariant(
            mode: mode,
            perm: permissionState,
            tapErrorActive: tapErrorActive,
            updateAvailable: updateAvailable
        )
    }

    func setUpdateAvailable(_ available: Bool) {
        updateAvailable = available
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
