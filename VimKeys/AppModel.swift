import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: VimMode = .disabled
    @Published var permissionState: PermissionState
    @Published var settings: VimSettings
    @Published var lastError: String?
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var tapErrorActive: Bool = false
    @Published private(set) var updateAvailable: Bool = false

    private let eventTapService: EventTapService
    private let safariObserver: SafariObserver
    private let launchAtLoginController: LaunchAtLoginController
    private let userDefaults: UserDefaults

    static let didShowLaunchAtLoginPromptKey = "didShowLaunchAtLoginPrompt"

    init(
        settings: VimSettings = .v1Default,
        eventTapService: EventTapService? = nil,
        launchAtLoginController: LaunchAtLoginController? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.userDefaults = userDefaults
        permissionState = PermissionController.currentState()

        let service = eventTapService ?? EventTapService(settings: settings)
        self.eventTapService = service

        let controller = launchAtLoginController ?? LaunchAtLoginController()
        self.launchAtLoginController = controller
        launchAtLoginEnabled = controller.isEnabled

        // Construct observer with a placeholder closure first; rewire after
        // self is fully initialized (Swift can't capture self in a property
        // initializer until init returns).
        var safariCallback: ((Bool) -> Void)?
        safariObserver = SafariObserver(onFrontmostChange: { isFrontmost in
            safariCallback?(isFrontmost)
        })
        safariCallback = { [weak self] isFrontmost in
            self?.safariFrontmostChanged(isFrontmost)
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

        if permissionState.isGranted {
            if !service.start() {
                lastError = "VimKeys could not start the global event tap."
            }
        }

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

    func requestPermission() {
        let granted = PermissionController.requestListenAccess()
        refreshPermissionState()
        if granted {
            restartEventTap()
        }
    }

    func refreshPermissionState() {
        permissionState = PermissionController.currentState()
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
            // Re-seed Safari frontmost state into the new engine.
            eventTapService.updateSafariFrontmost(SafariObserver.isSafariFrontmost())
        }
    }

    func safariFrontmostChanged(_ isFrontmost: Bool) {
        eventTapService.updateSafariFrontmost(isFrontmost)
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
