import Foundation

/// Per-domain disable rules. Stored as an ordered list of `host` or
/// `host:port` strings in `UserDefaults` so Settings → Sites can edit
/// them in place.
///
/// Entries are normalized to a bare authority (`normalizeEntry`): a
/// pasted full URL like `http://localhost:5174/v4` is reduced to
/// `localhost:5174`, scheme / path / query / `www.` all stripped.
///
/// Matching:
/// - A bare-host entry `"gmail.com"` disables VimKeys on `gmail.com`
///   AND `mail.gmail.com` (suffix match) regardless of port.
/// - A `host:port` entry `"localhost:5174"` matches only that exact
///   authority, so `localhost:3000` stays enabled. This is what makes
///   per-dev-server disabling work.
/// Path / query are never part of the match.
@MainActor
struct SitesStore {
    static let shared = SitesStore()

    private let defaults: UserDefaults
    private static let key = "settings.disabledHosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the persisted list, normalized and de-duplicated, ordered
    /// as the user entered it so removal-by-row index is stable across
    /// launches. Normalizing on load migrates legacy raw entries (e.g. a
    /// full URL pasted by an earlier build) to the matchable `host[:port]`
    /// form without the user having to re-enter them.
    func load() -> [String] {
        let raw = defaults.stringArray(forKey: Self.key) ?? []
        return Self.dedupe(raw.compactMap(Self.normalizeEntry))
    }

    func save(_ hosts: [String]) {
        defaults.set(Self.dedupe(hosts.compactMap(Self.normalizeEntry)), forKey: Self.key)
    }

    func reset() {
        defaults.removeObject(forKey: Self.key)
    }

    private static func dedupe(_ entries: [String]) -> [String] {
        Array(NSOrderedSet(array: entries)) as? [String] ?? []
    }

    /// Reduces a user-entered rule to the stored form: a bare `host` or
    /// `host:port`, lowercased, with scheme / path / query / userinfo and
    /// a leading `www.` stripped. Accepts pasted full URLs
    /// (`http://localhost:5174/v4` → `localhost:5174`) as well as bare
    /// hosts. Returns nil when there's no usable host. `nonisolated` so
    /// both the @MainActor store and the engine-thread matcher can use it.
    nonisolated static func normalizeEntry(_ raw: String) -> String? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let schemeRange = s.range(of: "://") {
            s = String(s[schemeRange.upperBound...])
        }
        // Authority ends at the first path / query / fragment delimiter.
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<cut])
        }
        // Drop any user:pass@ userinfo prefix.
        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s.isEmpty ? nil : s
    }

    /// True iff the given URL matches any entry. Bare-host entries match
    /// by suffix (port-agnostic); `host:port` entries match the exact
    /// authority. Entries are normalized at match time so legacy raw rows
    /// still resolve. `nonisolated` so the state machine (no actor
    /// context) can call it during `decide(...)` on the engine thread.
    nonisolated static func isDisabled(url: URL, in hosts: [String]) -> Bool {
        guard var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let authority = url.port.map { "\(host):\($0)" }
        return hosts.contains { raw in
            guard let entry = normalizeEntry(raw) else { return false }
            if entry.contains(":") {
                return authority == entry
            }
            return host == entry || host.hasSuffix("." + entry)
        }
    }
}
