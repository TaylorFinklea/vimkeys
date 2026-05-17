import Foundation
import os.log
import SafariServices

/// Receives bookmark snapshots from background.js (via Safari's
/// `browser.runtime.sendNativeMessage` bridge) and persists them as
/// JSON in the App Group container shared with VimKeys.app.
///
/// **Why an extension at all?** The non-extension path (parsing a
/// user-exported HTML file) is what 0.6.x ships and works without any
/// Safari-side install. The extension trades a one-time enable step in
/// Safari for live, always-fresh bookmarks — no re-export needed.
///
/// **Wire diagram:**
/// ```
/// Safari (extension JS)
///   browser.bookmarks.onChanged → background.js → sendNativeMessage
///     → SafariWebExtensionHandler.beginRequest
///         → write JSON to App Group container
/// VimKeys.app (main process)
///   BookmarksStore reads container if present, falls back to HTML
/// ```
///
/// **App Group:** `group.io.taylorfinklea.vimkeys` must be registered
/// on developer.apple.com under the K7CBQW6MPG team — without that
/// step, `containerURL(forSecurityApplicationGroupIdentifier:)` returns
/// nil and the extension silently no-ops (main app falls back to HTML).
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    static let appGroupIdentifier = "group.io.taylorfinklea.vimkeys"
    static let bookmarksFileName = "bookmarks.json"

    private let logger = Logger(
        subsystem: "io.taylorfinklea.vimkeys.SafariExtension",
        category: "bookmark-sync"
    )

    func beginRequest(with context: NSExtensionContext) {
        defer {
            // Always complete — leaving the request open hangs the
            // extension's runloop and Safari starts warning about it.
            let response = NSExtensionItem()
            response.userInfo = [SFExtensionMessageKey: ["status": "ok"]]
            context.completeRequest(returningItems: [response], completionHandler: nil)
        }

        guard let item = context.inputItems.first as? NSExtensionItem,
              let payload = item.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
            return
        }

        guard let action = payload["action"] as? String, action == "syncBookmarks" else {
            return
        }
        guard let bookmarks = payload["bookmarks"] as? [[String: Any]] else {
            return
        }

        writeBookmarks(bookmarks)
    }

    /// Atomically writes the bookmark snapshot to the shared container.
    /// JSON shape: `[{"title": "...", "url": "..."}, ...]`.
    private func writeBookmarks(_ bookmarks: [[String: Any]]) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            // Most common cause: the App Group isn't registered in the
            // Developer Portal for team K7CBQW6MPG. The extension still
            // loads (entitlement claim is in the binary) but at runtime
            // macOS refuses to vend a container URL.
            logger.error("App Group container unavailable; check developer.apple.com registration for \(Self.appGroupIdentifier, privacy: .public)")
            return
        }

        let url = container.appendingPathComponent(Self.bookmarksFileName)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: bookmarks,
                options: [.sortedKeys]
            )
            try data.write(to: url, options: .atomic)
            logger.debug("Synced \(bookmarks.count) bookmarks to container")
        } catch {
            logger.error("Bookmark write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
