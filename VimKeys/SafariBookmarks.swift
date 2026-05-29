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
        /// The file exists but macOS denied the read — the real-world
        /// cause is the user not having granted Full Disk Access, which
        /// `~/Library/Safari/Bookmarks.plist` requires.
        case permissionDenied
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

    /// Cheap Full Disk Access probe, co-located with `readPlist` so the
    /// permission-denied detection can't drift from the real read path.
    /// Memory-maps the file (`.mappedIfSafe`, no eager whole-file read) and
    /// skips the plist parse entirely — the only question is whether the
    /// *open* was permitted. `.permissionDenied` means FDA is off;
    /// `.fileMissing` means Safari hasn't written bookmarks yet. Used by the
    /// Settings permission probe, which runs on the main thread on every
    /// appearance, so it must not do the multi-MB read + parse `readPlist`
    /// does.
    static func probeReadable(at url: URL) -> Result<Void, ReadError> {
        do {
            _ = try Data(contentsOf: url, options: .mappedIfSafe)
            return .success(())
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                return .failure(.fileMissing)
            }
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoPermissionError {
                return .failure(.permissionDenied)
            }
            return .failure(.malformed)
        }
    }

    /// Reads Safari's own bookmark store at `~/Library/Safari/Bookmarks.plist`.
    /// This is the live-sync path — Safari rewrites the file whenever the
    /// user adds, edits, or removes a bookmark, so VimKeys always sees
    /// current data with no manual export step.
    ///
    /// `~/Library/Safari` is TCC-protected, so the read only succeeds when
    /// the user has granted VimKeys Full Disk Access; otherwise the read
    /// is denied and this returns `.permissionDenied`.
    ///
    /// **Format:** a binary plist whose root is a `WebBookmarkTypeList`
    /// dict. Every node carries a `WebBookmarkType`: `...TypeList` (a
    /// folder, with a `Children` array), `...TypeLeaf` (a bookmark, with a
    /// `URLString` and a nested `URIDictionary` holding `title`), or
    /// `...TypeProxy` (History and similar — skipped). The
    /// `com.apple.ReadingList` folder is skipped to match what Safari's
    /// own HTML export omits.
    static func readPlist(at url: URL) -> Result<[Entry], ReadError> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                return .failure(.fileMissing)
            }
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoPermissionError {
                return .failure(.permissionDenied)
            }
            return .failure(.malformed)
        }

        guard let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ),
            let rootDict = root as? [String: Any],
            rootDict["WebBookmarkType"] as? String == "WebBookmarkTypeList"
        else {
            return .failure(.malformed)
        }

        var entries: [Entry] = []
        collectLeaves(in: rootDict, into: &entries)
        return .success(entries)
    }

    /// Depth-first walk of one bookmark-tree node, appending navigable
    /// leaves to `entries`. Folder hierarchy is discarded — the vomnibar
    /// filters by title, matching the HTML and JSON readers.
    private static func collectLeaves(in node: [String: Any], into entries: inout [Entry]) {
        switch node["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            guard let urlString = node["URLString"] as? String,
                  let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "ftp" || scheme == "file"
            else { return }
            let rawTitle = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
            let title = rawTitle.isEmpty ? (url.host ?? urlString) : rawTitle
            entries.append(Entry(title: title, url: url))
        case "WebBookmarkTypeList":
            // Reading List is a list node Safari's HTML export omits — its
            // entries are saved articles, not bookmarks.
            guard node["Title"] as? String != "com.apple.ReadingList",
                  let children = node["Children"] as? [[String: Any]]
            else { return }
            for child in children {
                collectLeaves(in: child, into: &entries)
            }
        default:
            // WebBookmarkTypeProxy (History, Bonjour) and anything
            // unrecognized carry no navigable URL.
            return
        }
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
