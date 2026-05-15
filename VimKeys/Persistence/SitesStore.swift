import Foundation

/// Per-domain disable rules. Stored as an ordered list of host strings
/// in `UserDefaults` so Settings → Sites can edit them in place.
///
/// Matching is host-only: an entry `"gmail.com"` disables VimKeys on
/// `https://gmail.com/...` AND `https://mail.gmail.com/...` (suffix
/// match on the host). Path / query are ignored — vim navigation
/// doesn't have a path-scoped use case yet.
@MainActor
struct SitesStore {
    static let shared = SitesStore()

    private let defaults: UserDefaults
    private static let key = "settings.disabledHosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the persisted list, ordered as the user entered it so
    /// removal-by-row index is stable across launches.
    func load() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    func save(_ hosts: [String]) {
        let normalized = hosts
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        defaults.set(Array(NSOrderedSet(array: normalized)) as? [String] ?? [], forKey: Self.key)
    }

    func reset() {
        defaults.removeObject(forKey: Self.key)
    }

    /// True iff the given URL's host matches any persisted entry by
    /// suffix. Hosts are compared case-insensitively after stripping a
    /// leading `www.`. `nonisolated` so the state machine (no actor
    /// context) can call it during `decide(...)` on the engine thread.
    nonisolated static func isDisabled(url: URL, in hosts: [String]) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return hosts.contains { entry in
            let normalized = entry.lowercased()
            return host == normalized || host.hasSuffix("." + normalized)
        }
    }
}
