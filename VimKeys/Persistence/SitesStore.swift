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

    /// A parsed disable rule: a canonical `host` plus an optional `port`.
    /// The host is lowercased, `www.`- and trailing-dot-stripped, and
    /// (for non-IPv6 hosts) punycoded so it matches the form Foundation's
    /// `URL.host` reports — see `canonicalHost`.
    nonisolated private struct Authority: Equatable {
        let host: String
        let port: Int?
    }

    /// Reduces a user-entered rule to the stored form: a bare `host` or
    /// `host:port`, lowercased, with scheme / path / query / userinfo and
    /// a leading `www.` stripped. Accepts pasted full URLs
    /// (`http://localhost:5174/v4` → `localhost:5174`) as well as bare
    /// hosts. IPv6 literals are bracketed (`[::1]`, `[::1]:5174`) so the
    /// stored string round-trips unambiguously. Returns nil when there's
    /// no usable host. `nonisolated` so both the @MainActor store and the
    /// engine-thread matcher can use it.
    nonisolated static func normalizeEntry(_ raw: String) -> String? {
        guard let authority = parseAuthority(raw) else { return nil }
        return canonicalString(authority)
    }

    /// True iff the given URL matches any entry. Bare-host entries match
    /// by suffix (port-agnostic); `host:port` entries match the exact
    /// host+port. Both the URL and each entry are parsed to a canonical
    /// `Authority` so legacy raw rows, IPv6 literals, IDN domains, and
    /// trailing-dot FQDNs all resolve consistently. `nonisolated` so the
    /// state machine (no actor context) can call it during `decide(...)`
    /// on the engine thread.
    nonisolated static func isDisabled(url: URL, in hosts: [String]) -> Bool {
        guard let rawHost = url.host?.lowercased() else { return false }
        let runtime = Authority(host: canonicalHost(rawHost), port: url.port)
        guard !runtime.host.isEmpty else { return false }
        return hosts.contains { raw in
            guard let entry = parseAuthority(raw) else { return false }
            if let entryPort = entry.port {
                return runtime.host == entry.host && runtime.port == entryPort
            }
            return runtime.host == entry.host
                || runtime.host.hasSuffix("." + entry.host)
        }
    }

    /// Parses a rule or URL-ish string into `(host, port?)`. Handles
    /// scheme / path / userinfo stripping, bracketed and bare IPv6
    /// literals, and `host:port`. IPv6 is disambiguated from `host:port`
    /// by the brackets or by a multi-colon count — a single trailing
    /// `:digits` is a port, anything with two-plus colons and no brackets
    /// is a bare IPv6 literal.
    nonisolated private static func parseAuthority(_ raw: String) -> Authority? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let schemeRange = s.range(of: "://") {
            s = String(s[schemeRange.upperBound...])
        }
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<cut])
        }
        if let at = s.lastIndex(of: "@") {
            s = String(s[s.index(after: at)...])
        }
        guard !s.isEmpty else { return nil }

        var hostPart: String
        var port: Int?
        if s.hasPrefix("[") {
            // [ipv6] or [ipv6]:port
            guard let close = s.firstIndex(of: "]") else { return nil }
            hostPart = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.hasPrefix(":") { port = Int(rest.dropFirst()) }
        } else if s.filter({ $0 == ":" }).count >= 2 {
            // Bare IPv6 literal, no port.
            hostPart = s
        } else if let colon = s.lastIndex(of: ":"),
                  let parsed = Int(s[s.index(after: colon)...]) {
            hostPart = String(s[..<colon])
            port = parsed
        } else {
            hostPart = s
        }

        hostPart = canonicalHost(hostPart)
        return hostPart.isEmpty ? nil : Authority(host: hostPart, port: port)
    }

    /// Canonicalizes a bare host: strips a leading `www.` and any trailing
    /// FQDN dot, then (for non-IPv6 hosts) punycodes via a URL round-trip
    /// so an IDN entry like `bücher.de` matches the `xn--bcher-kva.de`
    /// form Foundation surfaces from `URL.host`.
    nonisolated private static func canonicalHost(_ raw: String) -> String {
        var host = raw
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        while host.hasSuffix(".") { host = String(host.dropLast()) }
        guard !host.isEmpty else { return host }
        // IPv6 literals are already ASCII; only DNS hostnames need IDNA.
        if host.contains(":") { return host }
        if let punycoded = URL(string: "http://\(host)")?.host {
            return punycoded.lowercased()
        }
        return host
    }

    /// Renders a parsed `Authority` back to its canonical stored string.
    /// IPv6 hosts are bracketed so the result re-parses unambiguously.
    nonisolated private static func canonicalString(_ authority: Authority) -> String {
        let isIPv6 = authority.host.contains(":")
        let host = isIPv6 ? "[\(authority.host)]" : authority.host
        if let port = authority.port { return "\(host):\(port)" }
        return host
    }
}
