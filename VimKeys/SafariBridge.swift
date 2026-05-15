import AppKit
import ApplicationServices
import Foundation

/// Apple-Events facade for Safari. All scripting calls go through here so
/// the rest of the codebase doesn't have to know about NSAppleScript.
///
/// TCC: Sending Apple Events to another app on macOS 10.14+ requires the
/// "Automation" permission. Callers should check `hasAccess` before
/// invoking and fall back to a graceful no-op if false (the TCC prompt
/// is triggered the first time we try; after that, the user sees us in
/// System Settings → Privacy & Security → Automation → Safari).
@MainActor
struct SafariBridge {
    static let shared = SafariBridge()

    /// Bundle ID of vanilla Safari. Tech Preview has a different bundle
    /// and would need separate scripting targets if we ever wanted to
    /// support it — for now, all scripts target `com.apple.Safari`.
    private static let safariBundleID = "com.apple.Safari"

    /// True iff TCC has approved this app's right to send Apple Events to
    /// Safari. `false` while we haven't asked yet (prompt-driven) OR
    /// after the user has explicitly denied.
    var hasAccess: Bool {
        checkAutomationPermission(promptIfNeeded: false) == noErr
    }

    /// Prompts for the Apple Events / Automation grant if necessary.
    /// Returns true if we already had access OR the user just granted it,
    /// false if we don't have access and the user denied (or can't be
    /// asked because we're in the background).
    @discardableResult
    func requestAccess() -> Bool {
        checkAutomationPermission(promptIfNeeded: true) == noErr
    }

    /// Returns the URL of Safari's frontmost tab, or nil if Safari has no
    /// open windows OR we don't have Automation permission.
    func currentURL() -> URL? {
        let result = run(script: """
        tell application id "\(Self.safariBundleID)"
            if (count of windows) = 0 then return ""
            return URL of current tab of front window as string
        end tell
        """)
        guard case .string(let value) = result, !value.isEmpty else { return nil }
        return URL(string: value)
    }

    /// Returns titles + URLs of every tab across every Safari window.
    func openTabs() -> [Tab] {
        // AppleScript returns two parallel lists of strings; the bridge
        // returns them as a single tab-delimited string we split here.
        let result = run(script: """
        tell application id "\(Self.safariBundleID)"
            set tabList to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set end of tabList to (name of t & "\t" & URL of t as string)
                end repeat
            end repeat
            return tabList
        end tell
        """)

        guard case .list(let rows) = result else { return [] }
        return rows.compactMap { row -> Tab? in
            let parts = row.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let url = URL(string: String(parts[1])) else { return nil }
            return Tab(title: String(parts[0]), url: url)
        }
    }

    /// Opens `url` in the front window's current tab (or a new window if
    /// Safari has none). Returns true if the script ran without error.
    @discardableResult
    func open(url: URL, inNewTab: Bool) -> Bool {
        let script: String
        if inNewTab {
            script = """
            tell application id "\(Self.safariBundleID)"
                tell window 1 to set newTab to make new tab with properties {URL:"\(url.absoluteString.aeEscaped)"}
                set current tab of window 1 to newTab
                activate
            end tell
            """
        } else {
            script = """
            tell application id "\(Self.safariBundleID)"
                if (count of windows) = 0 then
                    make new document with properties {URL:"\(url.absoluteString.aeEscaped)"}
                else
                    set URL of current tab of front window to "\(url.absoluteString.aeEscaped)"
                end if
                activate
            end tell
            """
        }
        return run(script: script) != .error
    }

    /// Focus a specific tab (by its URL — since AppleScript identifies
    /// tabs by index per window, easier to find by URL). Used by the tab
    /// vomnibar to jump.
    @discardableResult
    func focusTab(matching url: URL) -> Bool {
        let script = """
        tell application id "\(Self.safariBundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    if (URL of t as string) = "\(url.absoluteString.aeEscaped)" then
                        set index of w to 1
                        set current tab of w to t
                        activate
                        return true
                    end if
                end repeat
            end repeat
            return false
        end tell
        """
        return run(script: script) != .error
    }

    // MARK: - Internal

    private enum ScriptResult: Equatable {
        case string(String)
        case list([String])
        case empty
        case error
    }

    /// Runs `AEDeterminePermissionToAutomateTarget`. Returns the raw
    /// `OSStatus` so callers can compare against `noErr` /
    /// `errAEEventNotPermitted` without an intermediate enum (which
    /// trips Swift's overload resolver on the `.success` case name).
    private func checkAutomationPermission(promptIfNeeded: Bool) -> OSStatus {
        var addressDesc = AEAddressDescriptor.descriptor(forBundleID: Self.safariBundleID)
        defer { AEDisposeDesc(&addressDesc) }
        return AEDeterminePermissionToAutomateTarget(
            &addressDesc,
            typeWildCard,
            typeWildCard,
            promptIfNeeded
        )
    }

    /// Runs `script` synchronously and returns the result coerced into one
    /// of three shapes. Errors are swallowed and reported as `.error` —
    /// callers degrade gracefully (we're best-effort with Safari).
    private func run(script: String) -> ScriptResult {
        var errorInfo: NSDictionary?
        guard let apple = NSAppleScript(source: script) else { return .error }
        let descriptor = apple.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return .error }

        if descriptor.descriptorType == typeAEList {
            var rows: [String] = []
            for i in 1...max(1, descriptor.numberOfItems) {
                if let item = descriptor.atIndex(i)?.stringValue {
                    rows.append(item)
                }
            }
            return .list(rows)
        }
        if let str = descriptor.stringValue, !str.isEmpty {
            return .string(str)
        }
        return .empty
    }

}

extension SafariBridge {
    struct Tab: Equatable, Identifiable {
        let title: String
        let url: URL

        var id: URL { url }
    }
}

private enum AEAddressDescriptor {
    static func descriptor(forBundleID bundleID: String) -> AEDesc {
        var desc = AEDesc()
        let data = bundleID.data(using: .utf8) ?? Data()
        data.withUnsafeBytes { bytes in
            _ = AECreateDesc(typeApplicationBundleID, bytes.baseAddress, data.count, &desc)
        }
        return desc
    }
}

private extension String {
    /// Escape `"` and `\` so the string interpolates safely into the
    /// AppleScript source. Doesn't need to handle every edge case — URLs
    /// from `URL.absoluteString` are already URL-encoded.
    var aeEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
