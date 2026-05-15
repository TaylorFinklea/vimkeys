import Foundation

/// Reads Safari's bookmarks plist into a flat list of `(title, url)`
/// tuples, recursively descending its tree of folders.
///
/// **TCC scope:** Safari's bookmarks live at
/// `~/Library/Safari/Bookmarks.plist`. The default sandbox policy
/// prevents arbitrary processes from reading the file even though it's
/// in the user's home directory; macOS requires the reader to be on the
/// Full Disk Access list. VimKeys surfaces a clear error when the read
/// fails so the user knows where to look (Settings → Privacy & Security
/// → Full Disk Access).
///
/// **Plist format:** top-level dict with `WebBookmarkType` =
/// `WebBookmarkTypeList` and a `Children` array. Each child is either a
/// `WebBookmarkTypeLeaf` (has `URLString` + `URIDictionary.title`) or a
/// nested `WebBookmarkTypeList`. The reader ignores folder hierarchy —
/// users can filter by title in the vomnibar.
enum SafariBookmarks {
    struct Entry: Equatable, Identifiable {
        let title: String
        let url: URL
        var id: URL { url }
    }

    enum ReadError: Error, Equatable {
        case fileMissing
        case permissionDenied
        case malformed
    }

    /// Default location. Override for tests via `read(at:)`.
    static var defaultPath: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")
    }

    static func read() -> Result<[Entry], ReadError> {
        read(at: defaultPath)
    }

    static func read(at url: URL) -> Result<[Entry], ReadError> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                    return .failure(.fileMissing)
                case NSFileReadNoPermissionError:
                    return .failure(.permissionDenied)
                default:
                    return .failure(.malformed)
                }
            }
            // Common signal for "this path is sandboxed away from us"
            // is POSIX EACCES (errno 13).
            if error.domain == NSPOSIXErrorDomain, error.code == 13 {
                return .failure(.permissionDenied)
            }
            return .failure(.malformed)
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else {
            return .failure(.malformed)
        }
        return .success(flatten(node: root, accumulator: []))
    }

    private static func flatten(node: Any, accumulator: [Entry]) -> [Entry] {
        var result = accumulator
        guard let dict = node as? [String: Any] else { return result }

        let type = dict["WebBookmarkType"] as? String
        if type == "WebBookmarkTypeLeaf" {
            if let urlString = dict["URLString"] as? String,
               let url = URL(string: urlString),
               let uri = dict["URIDictionary"] as? [String: Any] {
                let title = (uri["title"] as? String) ?? url.host ?? urlString
                result.append(Entry(title: title, url: url))
            }
            return result
        }

        // WebBookmarkTypeList (or anything else with Children) — recurse.
        if let children = dict["Children"] as? [Any] {
            for child in children {
                result = flatten(node: child, accumulator: result)
            }
        }
        return result
    }
}
