import Foundation

/// Resolves a raw query / clipboard string to a URL: an explicit URL, a
/// bare host (prepend `https://`), or a DuckDuckGo search. Shared by the
/// vomnibar (`o` / `O`) and clipboard "paste and go" (`p` / `P`) so the two
/// stay in sync. Pure + non-isolated, so it's unit-testable.
enum QueryURL {
    /// A direct or bare-host URL for `raw`, or nil if it isn't URL-like.
    /// Always carries a scheme when non-nil.
    static func candidate(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        // Bare host: prepend https://.
        if trimmed.contains("."), !trimmed.contains(" "),
           let url = URL(string: "https://" + trimmed) {
            return url
        }
        return nil
    }

    /// A DuckDuckGo search URL for `raw`. DDG over Google avoids the
    /// tracking-cookie chain; we can't read Safari's preferred engine via
    /// AppleScript without poking the prefs plist.
    static func duckDuckGoSearch(for raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: "https://duckduckgo.com/") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }

    /// "Paste and go": a direct / bare-host URL, else a DuckDuckGo search.
    static func resolve(_ raw: String) -> URL? {
        candidate(from: raw) ?? duckDuckGoSearch(for: raw)
    }
}
