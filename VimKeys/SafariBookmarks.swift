import Foundation

/// Reads bookmarks the user has exported from Safari into a flat list of
/// `(title, url)` entries.
///
/// **Why not `~/Library/Safari/Bookmarks.plist`?** That path lives under
/// Apple's Full Disk Access TCC scope — granting FDA is a non-starter for
/// any user with even loosely-managed security, since it exposes Mail,
/// Messages, browser cookies, and every other app's data store. Reading a
/// user-exported file from `~/Documents` is unprivileged on macOS and
/// requires no TCC grant.
///
/// **Workflow:** In Safari, choose **File → Export → Bookmarks…** and save
/// the resulting HTML file at the path returned by `defaultPath` (the
/// containing folder will be auto-created on first import, or the user
/// can create it themselves). VimKeys then reads that file on every `b`/
/// `B` press; re-export whenever bookmarks change.
///
/// **Format:** Safari emits the standard Netscape Bookmark File format
/// (`<!DOCTYPE NETSCAPE-Bookmark-file-1>`). Entries are simple
/// `<DT><A HREF="…">title</A>` lines under nested `<DL>` folders. We
/// ignore folder hierarchy (users filter by title in the vomnibar) and
/// extract anchors via a regex.
enum SafariBookmarks {
    struct Entry: Equatable, Identifiable {
        let title: String
        let url: URL
        var id: URL { url }
    }

    enum ReadError: Error, Equatable {
        case fileMissing
        case malformed
    }

    /// `~/Documents/VimKeys/bookmarks.html`. The user picks this path when
    /// running Safari's export dialog; we don't try to be clever about
    /// detecting an alternate location.
    static var defaultPath: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/VimKeys/bookmarks.html")
    }

    /// Human-readable instruction surfaced when the file is missing.
    /// Lives here rather than in the UI layer so unit tests can assert it
    /// stays in sync with the actual `defaultPath`.
    static var exportInstructions: String {
        "In Safari: File \u{2192} Export \u{2192} Bookmarks\u{2026} and save to ~/Documents/VimKeys/bookmarks.html"
    }

    static func read() -> Result<[Entry], ReadError> {
        read(at: defaultPath)
    }

    static func read(at url: URL) -> Result<[Entry], ReadError> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                return .failure(.fileMissing)
            }
            // Anything else (POSIX EACCES from a perms-broken file, IO
            // errors, etc.) we treat as malformed — the user can re-export
            // to fix.
            return .failure(.malformed)
        }

        guard let html = String(data: data, encoding: .utf8) else {
            return .failure(.malformed)
        }
        let entries = parseAnchors(in: html)
        // An empty bookmark export is technically valid HTML, but the more
        // common cause is "user pointed at a non-bookmarks HTML file", so
        // surface it as malformed rather than silently showing an empty
        // vomnibar.
        if entries.isEmpty && !html.lowercased().contains("netscape-bookmark-file") {
            return .failure(.malformed)
        }
        return .success(entries)
    }

    /// Reads the JSON snapshot dropped into the App Group container by
    /// VimKeysSafariExtension. This is the 0.7.0 live-sync path —
    /// preferred over the HTML export when present.
    ///
    /// **Shape:** `[{"title": "...", "url": "..."}, ...]`. Identical
    /// semantics to the HTML reader (folder hierarchy already flattened
    /// by the JS side; non-navigable schemes filtered).
    static func readJSON(at url: URL) -> Result<[Entry], ReadError> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                return .failure(.fileMissing)
            }
            return .failure(.malformed)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let array = raw as? [[String: Any]] else {
            return .failure(.malformed)
        }

        var entries: [Entry] = []
        for item in array {
            guard let urlString = item["url"] as? String,
                  let url = URL(string: urlString) else { continue }
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "ftp" || scheme == "file"
            else { continue }
            let rawTitle = (item["title"] as? String) ?? ""
            let title = rawTitle.isEmpty ? (url.host ?? urlString) : rawTitle
            entries.append(Entry(title: title, url: url))
        }
        return .success(entries)
    }

    /// Pulls every `<A HREF="…">title</A>` from the document. Case-
    /// insensitive on the tag name because Safari's export uses uppercase
    /// while some browsers (and hand-edited files) use lowercase. Title
    /// text gets HTML-entity-decoded for the common entities (`&amp;`,
    /// `&lt;`, `&gt;`, `&quot;`, numeric `&#NN;` / `&#xHH;`).
    private static func parseAnchors(in html: String) -> [Entry] {
        // Pattern explanation:
        //   <a\s+              opening tag with at least one whitespace
        //   [^>]*?             any attributes before HREF (non-greedy)
        //   href\s*=\s*"       the href attribute
        //   ([^"]+)            URL — group 1
        //   "[^>]*>            close the opening tag
        //   ([\s\S]*?)         title — group 2 (any chars including \n)
        //   </a>               closing tag
        let pattern = #"<a\s+[^>]*?href\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var results: [Entry] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 3,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html)
            else { return }

            let rawURL = String(html[urlRange])
            guard let url = URL(string: decodeEntities(rawURL)) else { return }

            // Skip Safari's "place:" / "about:" pseudo-URLs that don't
            // resolve to real navigations.
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "ftp" || scheme == "file"
            else { return }

            let rawTitle = String(html[titleRange])
            let title = decodeEntities(rawTitle)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = title.isEmpty ? (url.host ?? rawURL) : title
            results.append(Entry(title: displayTitle, url: url))
        }
        return results
    }

    /// Decodes the small set of HTML entities Safari emits in exports.
    /// Not a full HTML decoder — those require WebKit and are overkill
    /// for the four named entities plus numeric refs that appear here.
    private static func decodeEntities(_ raw: String) -> String {
        var result = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")

        // Numeric entities: &#1234; (decimal) and &#x1F4A9; (hex).
        let numericPattern = #"&#(x?)([0-9a-fA-F]+);"#
        guard let regex = try? NSRegularExpression(pattern: numericPattern) else {
            return result
        }
        var working = result
        while let match = regex.firstMatch(
            in: working,
            range: NSRange(working.startIndex..<working.endIndex, in: working)
        ) {
            guard let fullRange = Range(match.range, in: working),
                  let hexFlagRange = Range(match.range(at: 1), in: working),
                  let digitsRange = Range(match.range(at: 2), in: working) else {
                break
            }
            let isHex = !working[hexFlagRange].isEmpty
            let digits = String(working[digitsRange])
            let radix = isHex ? 16 : 10
            guard let code = UInt32(digits, radix: radix),
                  let scalar = Unicode.Scalar(code) else {
                // Unparseable: leave it in place and stop replacing so we
                // don't infinite-loop.
                break
            }
            working.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        result = working
        return result
    }
}
