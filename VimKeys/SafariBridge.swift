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

    /// Vanilla Safari's bundle ID — the fallback target when no
    /// Safari-family app is frontmost.
    private static let fallbackBundleID = "com.apple.Safari"

    /// The Safari-family bundle ID to script. `SafariObserver` activates
    /// VimKeys for both Safari and Safari Technology Preview, so when one
    /// of those is frontmost we target THAT app — otherwise the URL poll,
    /// `yy` copy, `o`/`O` open, and tab-group nav would all hit a possibly
    /// closed or background vanilla-Safari window (and the Automation
    /// permission check would target the wrong app). Falls back to vanilla
    /// Safari when nothing Safari-family is frontmost. Resolved per call
    /// because the frontmost app changes at runtime.
    private var activeBundleID: String {
        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           SafariObserver.safariBundleIDs.contains(frontmost) {
            return frontmost
        }
        return Self.fallbackBundleID
    }

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
        let bundleID = activeBundleID
        let result = run(script: """
        tell application id "\(bundleID)"
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
        let bundleID = activeBundleID
        let result = run(script: """
        tell application id "\(bundleID)"
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
        let bundleID = activeBundleID
        let script: String
        if inNewTab {
            script = """
            tell application id "\(bundleID)"
                tell window 1 to set newTab to make new tab with properties {URL:"\(url.absoluteString.aeEscaped)"}
                set current tab of window 1 to newTab
                activate
            end tell
            """
        } else {
            script = """
            tell application id "\(bundleID)"
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

    /// Trigger Safari's `Window → Go to Previous Tab Group` / `Go to
    /// Next Tab Group` menu items by walking Safari's AX tree directly.
    ///
    /// **Why not AppleScript via System Events?** That path requires a
    /// separate "VimKeys → System Events" Automation TCC grant on top
    /// of the existing "VimKeys → Safari" grant the user already has —
    /// macOS treats every Apple-Event target as its own grant. The AX
    /// path piggybacks on Accessibility trust, which the event tap
    /// already requires, so there are no new permission prompts.
    @discardableResult
    func goToTabGroup(forward: Bool) -> Bool {
        let target = forward ? "Go to Next Tab Group" : "Go to Previous Tab Group"
        let bundleID = activeBundleID
        guard let pid = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?
            .processIdentifier
        else { return false }

        let app = AXUIElementCreateApplication(pid)
        guard let windowMenu = findMenuBarItem(in: app, titled: "Window"),
              let item = findMenuItem(under: windowMenu, titled: target)
        else { return false }

        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Walks the app's menu bar children and returns the bar item with
    /// the given title (e.g. "Window", "File", "View"). Localized
    /// builds will need a different lookup — for now we target English.
    private func findMenuBarItem(in app: AXUIElement, titled title: String) -> AXUIElement? {
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef
        else { return nil }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            menuBar as! AXUIElement,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }

        for child in children {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &t)
            if (t as? String) == title { return child }
        }
        return nil
    }

    /// Descends into a menu-bar item's child menu and returns the item
    /// with the given title. Lazy-load nuance: AX populates the menu's
    /// `Children` only on first traversal, but calling `Copy…` here
    /// triggers that load synchronously, so we don't need to "open"
    /// the menu visually.
    private func findMenuItem(under barItem: AXUIElement, titled title: String) -> AXUIElement? {
        var menuRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barItem, kAXChildrenAttribute as CFString, &menuRef) == .success,
              let menus = menuRef as? [AXUIElement],
              let menu = menus.first
        else { return nil }

        var itemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
              let items = itemsRef as? [AXUIElement]
        else { return nil }

        for item in items {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &t)
            if (t as? String) == title { return item }
        }
        return nil
    }

    /// Focus a specific tab (by its URL — since AppleScript identifies
    /// tabs by index per window, easier to find by URL). Used by the tab
    /// vomnibar to jump.
    @discardableResult
    func focusTab(matching url: URL) -> Bool {
        let bundleID = activeBundleID
        let script = """
        tell application id "\(bundleID)"
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
        var addressDesc = AEAddressDescriptor.descriptor(forBundleID: activeBundleID)
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
