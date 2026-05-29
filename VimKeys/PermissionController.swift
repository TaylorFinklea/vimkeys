import ApplicationServices
import CoreGraphics
import Foundation

/// V-M1 keeps the same three-case Input-Monitoring shape as LayerKeys (which
/// drives the menu-bar variant resolver). Accessibility-trust and
/// Apple-Events checks are exposed as separate properties so V-M2 (which
/// promotes Accessibility from optional to required) and V-M4 (which adds
/// Apple-Events) can fold them into the user-facing state without a
/// breaking rename.
enum PermissionState: Equatable {
    case granted
    case listenOnly
    case denied

    var isGranted: Bool {
        self != .denied
    }

    var title: String {
        switch self {
        case .granted:
            return "Keyboard Permissions Enabled"
        case .listenOnly:
            return "Input Monitoring Enabled"
        case .denied:
            return "Input Monitoring Required"
        }
    }

    var detail: String {
        switch self {
        case .granted:
            return "VimKeys can listen for keyboard events and post scroll events globally."
        case .listenOnly:
            return "VimKeys can read keyboard events globally, but Accessibility is needed to post scroll events. Grant Accessibility to enable scroll bindings."
        case .denied:
            return "Grant Input Monitoring so VimKeys can listen for global key events."
        }
    }
}

enum PermissionController {
    static func currentState() -> PermissionState {
        let hasListenAccess = CGPreflightListenEventAccess()
        let hasPostAccess = CGPreflightPostEventAccess()

        if hasListenAccess && hasPostAccess {
            return .granted
        }
        if hasListenAccess {
            return .listenOnly
        }
        return .denied
    }

    @discardableResult
    static func requestListenAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    @discardableResult
    static func requestPostAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    /// Triggers the standard Accessibility prompt with the
    /// `AXTrustedCheckOptionPrompt` option. This is the documented path
    /// for registering an app in the Accessibility TCC list and is more
    /// reliable than `CGRequestPostEventAccess` at populating the list
    /// after a prior denial.
    @discardableResult
    static func requestAccessibilityWithPrompt() -> Bool {
        // Literal matches `kAXTrustedCheckOptionPrompt` — the constant
        // isn't Sendable under Swift 6 strict concurrency, and the docs
        // explicitly allow the string form here.
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Forces TCC to register VimKeys in the Input Monitoring list by
    /// attempting to create a listen-only session event tap. When
    /// permission is denied the tap creation returns nil — the side
    /// effect is the TCC daemon noticing our bundle and adding it to
    /// the visible list. `CGRequestListenEventAccess` alone has been
    /// observed to silently fail to populate the list, particularly
    /// after a previous denial or removal.
    static func probeInputMonitoringRegistration() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        guard let tap else { return }
        // Tap creation succeeded — permission is already granted. Tear
        // it down immediately so the real EventTapEngine owns the tap.
        CGEvent.tapEnable(tap: tap, enable: false)
    }

    static var hasListenEventAccess: Bool {
        CGPreflightListenEventAccess()
    }

    static var hasPostEventAccess: Bool {
        CGPreflightPostEventAccess()
    }

    /// AX-tree trust check, separate from event posting. V-M2 uses this to
    /// read focused-element role for insert-mode auto-detect; V-M3 uses it
    /// for link-hint traversal of `AXWebArea`. Calling with `nil` is
    /// non-prompting — use `requestAccessibilityWithPrompt()` to prompt.
    static var hasAccessibilityTrust: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Real Apple-Events (Automation) TCC check for vanilla Safari — the app
    /// VimKeys scripts by default and the one the Settings → Permissions row
    /// reports on. `promptIfNeeded: false` keeps reading it side-effect-free;
    /// the consent dialog is raised only by an explicit user action
    /// (`SafariBridge.requestAccess()` or sending an Apple Event via a
    /// keypress), never by a status read. Settings is never open while a
    /// Safari-family app is frontmost, so targeting `com.apple.Safari` here
    /// matches what the runtime `SafariBridge` will hit.
    static var hasAppleEventsAccess: Bool {
        var addressDesc = AEDesc()
        let bundleID = Data("com.apple.Safari".utf8)
        let createStatus = bundleID.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bundleID.count, &addressDesc)
        }
        guard createStatus == noErr else { return false }
        defer { AEDisposeDesc(&addressDesc) }
        return AEDeterminePermissionToAutomateTarget(
            &addressDesc, typeWildCard, typeWildCard, false
        ) == noErr
    }
}
