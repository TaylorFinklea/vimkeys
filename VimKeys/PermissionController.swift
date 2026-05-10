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
        let listenGranted = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()
        return listenGranted
    }

    static var hasPostEventAccess: Bool {
        CGPreflightPostEventAccess()
    }

    /// AX-tree trust check, separate from event posting. V-M2 starts using
    /// this to read focused-element role for insert-mode auto-detect; V-M3
    /// uses it for link-hint traversal of `AXWebArea`. Calling with `nil`
    /// is non-prompting; the prompting form lands in V-M6 onboarding.
    static var hasAccessibilityTrust: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// V-M1 stub. V-M4 wires this to the real Apple Events TCC check so the
    /// vomnibar / yy bindings can prompt + degrade gracefully if the user
    /// hasn't granted "control Safari".
    static var hasAppleEventsAccess: Bool {
        false
    }
}
