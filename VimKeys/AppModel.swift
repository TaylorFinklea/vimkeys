import AppKit
import Combine
import Foundation

/// Marshal an engine-thread callback onto the main actor while preserving
/// FIFO order. Independently-created `Task { @MainActor in }` instances are
/// serialized on the main actor but NOT guaranteed to run in *creation*
/// order, so a burst of per-keystroke callbacks (e.g. the two characters of
/// a hint label "sa") could be reordered and corrupt the typed buffer.
/// `DispatchQueue.main` is strictly FIFO for asyncs from a single source
/// thread; `assumeIsolated` bridges synchronously to the main actor — the
/// main queue *is* the main actor's executor, so the assertion always holds.
private func hopToMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: VimMode = .disabled
    @Published var permissionState: PermissionState
    @Published var accessibilityGranted: Bool
    /// Full Disk Access has no query API; this is probed by attempting the
    /// Safari `Bookmarks.plist` read VimKeys uses FDA for. Optional — the
    /// bookmarks vomnibar falls back to the HTML export without it.
    @Published private(set) var fullDiskAccessGranted: Bool
    /// Apple-Events ("control Safari") TCC grant. Drives the per-site
    /// ignorelist + Esc-Esc poll, `yy` copy, `o`/`O`/`p`/`P` open, and the
    /// `T` tab switcher. Optional in the same sense as FDA — VimKeys still
    /// scrolls / hints without it — but the ignorelist and URL-aware
    /// features stay dark until it's granted, so the Permissions tab
    /// surfaces it with a one-tap request button.
    @Published private(set) var automationAccessGranted: Bool
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

    /// Polls Safari's frontmost URL (1.5s) while Safari is frontmost to
    /// drive the per-site ignorelist + Esc-Esc. Owns the timer + dedupe;
    /// see `SafariURLPoller`.
    private let urlPoller: SafariURLPoller
    private var cancellables = Set<AnyCancellable>()

    static let didShowLaunchAtLoginPromptKey = "didShowLaunchAtLoginPrompt"
    /// One-time migration: 0.6.x defaulted to `.autoDetect`, which turned
    /// out to be brittle on modern contenteditable-heavy web apps (Notion,
    /// ChatGPT, Linear). 0.7.1 flips the default to `.insertFirst`; this
    /// sentinel lets us migrate existing users who never explicitly chose
    /// `.autoDetect` (since they look indistinguishable from new users
    /// who got `.autoDetect` by default).
    static let didMigrateInsertFirstKey = "didMigrateTo071InsertFirst"

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
        var loadedSettings = settingsStore.load()

        // One-shot migration to the 0.7.1 default. See
        // `didMigrateInsertFirstKey` above for why.
        if !userDefaults.bool(forKey: Self.didMigrateInsertFirstKey) {
            if loadedSettings.insertModeBehavior == .autoDetect {
                loadedSettings.insertModeBehavior = .insertFirst
                settingsStore.save(loadedSettings)
            }
            userDefaults.set(true, forKey: Self.didMigrateInsertFirstKey)
        }

        self.settings = loadedSettings
        permissionState = PermissionController.currentState()
        accessibilityGranted = PermissionController.hasPostEventAccess
        fullDiskAccessGranted = Self.probeFullDiskAccess()
        automationAccessGranted = PermissionController.hasAppleEventsAccess

        let service = eventTapService ?? EventTapService(settings: loadedSettings)
        self.eventTapService = service

        urlPoller = SafariURLPoller(
            hasAccess: { safariBridge.hasAccess },
            currentURL: { safariBridge.currentURL() },
            onURLChange: { [weak service] url in service?.updateCurrentURL(url) }
        )

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

        // All engine-thread callbacks below hop to the main actor through
        // `hopToMain` (FIFO) rather than independent `Task`s, so a burst of
        // per-keystroke callbacks can't be reordered on arrival.
        service.onModeChange = { [weak self] mode in
            hopToMain { self?.mode = mode }
        }
        service.onTapError = { [weak self] message in
            hopToMain {
                self?.lastError = message
                self?.tapErrorActive = true
            }
        }
        service.onTapRecovered = { [weak self] in
            hopToMain { self?.tapErrorActive = false }
        }
        service.onShowHelp = { [weak self] in
            hopToMain { self?.overlayManager.showHelp() }
        }
        service.onDismissOverlay = { [weak self] in
            hopToMain {
                self?.overlayManager.dismiss()
                self?.linkHintCoordinator.cancel()
                self?.vomnibarCoordinator.cancel()
            }
        }
        service.onRequestHints = { [weak self] openInNewTab, copyOnly, filter in
            hopToMain {
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
            hopToMain { self?.linkHintCoordinator.handleKey(chars: chars) }
        }
        service.onRequestVomnibar = { [weak self] flavor in
            hopToMain { self?.vomnibarCoordinator.start(flavor: flavor) }
        }
        service.onForwardVomnibarKey = { [weak self] chars in
            hopToMain { self?.vomnibarCoordinator.handleKey(chars: chars) }
        }
        service.onCopyCurrentURL = { [weak self] in
            hopToMain { self?.copyCurrentSafariURL() }
        }
        service.onOpenClipboardURL = { [weak self] inNewTab in
            hopToMain { self?.openClipboardURL(inNewTab: inNewTab) }
        }
        service.onToggleSuspended = { [weak service] in
            // Esc-Esc chord. State machine already detected the chord
            // and emitted the intent; engine routes it back to itself
            // (via service) so the toggle happens on the engine thread
            // where the state machine lives.
            service?.toggleSuspendOnCurrentURL()
        }
        service.onTabGroupNavigation = { [weak self] forward in
            hopToMain { self?.navigateTabGroup(forward: forward) }
        }

        // Coordinator error sinks (deferred to here, where all stored
        // properties are initialized so `self` is capturable): the vomnibar
        // surfaces FDA-denied bookmark reads, the hint coordinator surfaces
        // the Accessibility-trust-missing case, so f/F doing nothing isn't
        // mistaken for an empty page.
        vomnibar.onError = { [weak self] message in
            hopToMain { self?.lastError = message }
        }
        hintCoordinator.onError = { [weak self] message in
            hopToMain { self?.lastError = message }
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

        // Seed the bookmarks cache + start watching ~/Documents/VimKeys/
        // for fresh exports. The vomnibar reads from the cache on each
        // `b` / `B` press instead of re-parsing the HTML file every time.
        BookmarksStore.shared.start()

        safariObserver.start()
        // Seed the engine with the current frontmost state — SafariObserver
        // emits only on transitions, so the very first one is silent. Start
        // the URL poll here too if Safari is already frontmost at launch:
        // otherwise the poll only ever starts on a later frontmost
        // transition, leaving `currentURL` nil (and the per-site ignorelist
        // + Esc-Esc dead) for a Safari window that was already frontmost.
        let safariFrontmostAtLaunch = SafariObserver.isSafariFrontmost()
        service.updateSafariFrontmost(safariFrontmostAtLaunch)
        if safariFrontmostAtLaunch {
            urlPoller.start()
        }

        if !didShowLaunchAtLoginPrompt && !Self.isRunningUnderXCTest {
            Task { @MainActor [weak self] in
                self?.showLaunchAtLoginPromptIfNeeded()
            }
        }

        // Drive the on-screen mode indicator. `$mode` fires every time
        // the state machine reports a transition; the helper computes
        // the user-facing label (or `nil` to hide the overlay during
        // insert / disabled).
        $mode
            .sink { [weak self] newMode in
                self?.overlayManager.updateModeIndicator(text: Self.modeIndicatorText(for: newMode))
            }
            .store(in: &cancellables)
    }

    /// User-facing label for the bottom-right mode-indicator pill.
    /// Returns nil to suppress the pill entirely — used during `.insert`
    /// (no chrome while typing), `.help` (its own overlay is up), and
    /// `.disabled` (Safari isn't frontmost).
    nonisolated static func modeIndicatorText(for mode: VimMode) -> String? {
        switch mode {
        case .disabled, .insert, .help:
            return nil
        case .disabledBySite:
            return "-- OFF (site) --"
        case .normal(let prefix):
            switch prefix {
            case .none: return "-- NORMAL --"
            case .count(let n): return "-- NORMAL -- \(n)"
            case .g: return "-- NORMAL -- g"
            case .y: return "-- NORMAL -- y"
            }
        case .find: return "-- FIND --"
        case .hint: return "-- HINT --"
        case .vomnibar: return "-- VOMNIBAR --"
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
        fullDiskAccessGranted = Self.probeFullDiskAccess()
        automationAccessGranted = PermissionController.hasAppleEventsAccess
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
            urlPoller.start()
        } else {
            urlPoller.stop()
        }
    }

    /// Adds a disable rule. `raw` may be a bare host, a `host:port`, or a
    /// full pasted URL — `SitesStore.normalizeEntry` reduces it to the
    /// matchable authority before storing.
    func addDisabledHost(_ raw: String) {
        guard let normalized = SitesStore.normalizeEntry(raw),
              !settings.disabledHosts.contains(normalized) else { return }
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

    /// "Disable current site" button. Queries Safari's frontmost URL
    /// *live* via Apple Events rather than reading `lastReportedURL` —
    /// that polled value is cleared whenever Safari loses frontmost, and
    /// Safari is never frontmost while this button's Settings window is
    /// open. AppleScript reads Safari's front window regardless of which
    /// app macOS considers focused. The full URL is handed to
    /// `addDisabledHost`, which extracts `host:port`.
    func disableCurrentHost() {
        guard let url = safariBridge.currentURL() else {
            if !safariBridge.hasAccess {
                lastError = "Grant Apple Events access (Privacy & Security \u{2192} Automation \u{2192} Safari)."
            }
            return
        }
        addDisabledHost(url.absoluteString)
    }

    /// Full Disk Access has no TCC query API, so infer it from the one
    /// thing VimKeys needs it for: reading Safari's `Bookmarks.plist`. A
    /// `.permissionDenied` means FDA is off; success or any other error
    /// (e.g. the file simply not existing) means the read wasn't blocked
    /// by TCC. Uses `probeReadable` (memory-map, no whole-file read or
    /// plist parse) rather than `readPlist` — this runs on the main thread
    /// at launch and on every Settings appearance, so it must stay cheap
    /// even for multi-MB bookmark libraries.
    private static func probeFullDiskAccess() -> Bool {
        if case .failure(.permissionDenied) =
            SafariBookmarks.probeReadable(at: BookmarksStore.defaultPlistPath) {
            return false
        }
        return true
    }

    /// Deep-links to System Settings → Privacy & Security → Full Disk
    /// Access. Unlike Input Monitoring / Accessibility there's no API to
    /// trigger a TCC prompt for FDA — the user adds VimKeys manually — so
    /// this only opens the pane. After granting, VimKeys must be relaunched
    /// for the read to take effect. Re-probes immediately in case access
    /// was already in place.
    func openFullDiskAccessSettings() {
        openSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        fullDiskAccessGranted = Self.probeFullDiskAccess()
    }

    /// Request the Apple-Events ("control Safari") grant from an explicit
    /// user gesture (the Permissions-tab button). `requestAccess()` raises
    /// the macOS consent dialog when the grant is still undetermined; if the
    /// user previously denied it — macOS won't re-prompt in that case — we
    /// deep-link the Automation pane so they can toggle Safari by hand. The
    /// background URL poll never does this (it must not surprise the user
    /// mid-task), which is why obtaining the grant lives here.
    func requestAutomationAccess() {
        if safariBridge.requestAccess() {
            automationAccessGranted = true
        } else {
            openSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            automationAccessGranted = PermissionController.hasAppleEventsAccess
        }
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

    /// Cmd+Shift+H / Cmd+Shift+L handler. Drives Safari's
    /// `Window → Go to Previous / Next Tab Group` menu item via the
    /// SafariBridge. If the click fails we surface a flash in `lastError`.
    /// The message names the real constraints — VimKeys locates the menu
    /// item by its English title, so a non-English Safari is the most
    /// common cause, alongside Accessibility access and "no tab groups
    /// defined yet" — rather than the previous misleading "menu wasn't
    /// reachable", which pointed non-English users at the wrong thing.
    func navigateTabGroup(forward: Bool) {
        if !safariBridge.goToTabGroup(forward: forward) {
            lastError = "Couldn't switch tab group. This works on an "
                + "English-language Safari (the menu item is matched by name) "
                + "with Accessibility access, and only when tab groups exist."
        }
    }

    /// Reveal the bookmarks-export folder in Finder. Creates the folder
    /// first if the user hasn't run an export yet so they don't get a
    /// "folder doesn't exist" Finder bounce.
    func openBookmarksFolder() {
        let folder = BookmarksStore.shared.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
