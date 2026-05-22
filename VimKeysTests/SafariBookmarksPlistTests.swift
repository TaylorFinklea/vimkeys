import XCTest
@testable import VimKeys

/// Tests for the binary-plist reader that parses Safari's own
/// `~/Library/Safari/Bookmarks.plist`. HTML-export reader tests live in
/// `SafariBookmarksTests.swift`.
final class SafariBookmarksPlistTests: XCTestCase {
    /// DFS flatten: a leaf at the top level, then a nested folder's
    /// leaves, in source order. Folder hierarchy itself is discarded.
    func testReadPlistFlattensNestedFolders() throws {
        let url = try writePlist(root: list(children: [
            leaf(title: "Apple", url: "https://apple.com/"),
            list(title: "Dev", children: [
                leaf(title: "GitHub", url: "https://github.com/"),
                leaf(title: "Swift", url: "https://swift.org/"),
            ]),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .success(let entries) = SafariBookmarks.readPlist(at: url) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(entries.map(\.title), ["Apple", "GitHub", "Swift"])
        XCTAssertEqual(entries.map(\.url.absoluteString), [
            "https://apple.com/",
            "https://github.com/",
            "https://swift.org/",
        ])
    }

    /// A leaf's display title comes from the nested `URIDictionary`, not
    /// from a top-level key.
    func testReadPlistUsesURIDictionaryTitle() throws {
        let url = try writePlist(root: list(children: [
            leaf(title: "Hacker News", url: "https://news.ycombinator.com/"),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .success(let entries) = SafariBookmarks.readPlist(at: url),
              entries.count == 1 else {
            return XCTFail("expected one entry")
        }
        XCTAssertEqual(entries[0].title, "Hacker News")
    }

    /// Empty title → fall back to host, mirroring the HTML/JSON readers.
    func testReadPlistEmptyTitleFallsBackToHost() throws {
        let url = try writePlist(root: list(children: [
            leaf(title: "", url: "https://example.com/path"),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .success(let entries) = SafariBookmarks.readPlist(at: url),
              entries.count == 1 else {
            return XCTFail("expected one entry")
        }
        XCTAssertEqual(entries[0].title, "example.com")
    }

    /// `WebBookmarkTypeProxy` nodes (History, Bonjour) carry no real URL
    /// and must be skipped.
    func testReadPlistSkipsProxyNodes() throws {
        let url = try writePlist(root: list(children: [
            proxy(title: "History"),
            leaf(title: "Real", url: "https://real.example/"),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .success(let entries) = SafariBookmarks.readPlist(at: url) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(entries.map(\.title), ["Real"])
    }

    /// The `com.apple.ReadingList` folder is excluded — Safari's HTML
    /// export omits it, and reading-list items aren't bookmarks.
    func testReadPlistSkipsReadingList() throws {
        let url = try writePlist(root: list(children: [
            leaf(title: "Bookmark", url: "https://bookmark.example/"),
            list(title: "com.apple.ReadingList", children: [
                leaf(title: "Saved Article", url: "https://article.example/"),
            ]),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .success(let entries) = SafariBookmarks.readPlist(at: url) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(entries.map(\.title), ["Bookmark"])
    }

    /// Non-navigable schemes (about:, javascript:) are filtered to match
    /// the other readers.
    func testReadPlistSkipsNonNavigableSchemes() throws {
        let url = try writePlist(root: list(children: [
            leaf(title: "Blank", url: "about:blank"),
            leaf(title: "JS", url: "javascript:alert(1)"),
            leaf(title: "OK", url: "https://ok.example/"),
        ]))
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .success(let entries) = SafariBookmarks.readPlist(at: url) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(entries.map(\.title), ["OK"])
    }

    /// A user with zero bookmarks has a valid-but-empty file — that's
    /// success with an empty list, not an error.
    func testReadPlistEmptyBookmarksSucceedsWithEmptyList() throws {
        let url = try writePlist(root: list(children: []))
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .success(let entries) = SafariBookmarks.readPlist(at: url) else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(entries.isEmpty)
    }

    func testReadPlistMissingFileReturnsFileMissing() {
        let url = URL(fileURLWithPath: "/tmp/vimkeys-missing-\(UUID()).plist")
        XCTAssertEqual(SafariBookmarks.readPlist(at: url), .failure(.fileMissing))
    }

    /// An unreadable file (the real-world cause: Full Disk Access not
    /// granted, so macOS denies the read) surfaces as `.permissionDenied`
    /// so the UI can point the user at System Settings.
    func testReadPlistUnreadableFileReturnsPermissionDenied() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-noperm-\(UUID()).plist")
        try writePlistData(root: list(children: []), to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: url.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path
            )
            try? FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(SafariBookmarks.readPlist(at: url), .failure(.permissionDenied))
    }

    /// Bytes that aren't a property list at all → malformed.
    func testReadPlistGarbageDataReturnsMalformed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-garbage-\(UUID()).plist")
        try Data("not a plist".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SafariBookmarks.readPlist(at: url), .failure(.malformed))
    }

    /// A valid plist whose root isn't a Safari bookmark list (e.g. a bare
    /// array) → malformed rather than a silent empty list.
    func testReadPlistWrongShapeReturnsMalformed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-wrongshape-\(UUID()).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["just", "an", "array"], format: .binary, options: 0
        )
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SafariBookmarks.readPlist(at: url), .failure(.malformed))
    }

    // MARK: - Fixture builders

    private func leaf(title: String, url: String) -> [String: Any] {
        [
            "WebBookmarkType": "WebBookmarkTypeLeaf",
            "URLString": url,
            "URIDictionary": ["title": title],
        ]
    }

    private func list(title: String = "", children: [[String: Any]]) -> [String: Any] {
        [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Title": title,
            "Children": children,
        ]
    }

    private func proxy(title: String) -> [String: Any] {
        [
            "WebBookmarkType": "WebBookmarkTypeProxy",
            "Title": title,
        ]
    }

    private func writePlist(root: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-bookmarks-\(UUID()).plist")
        try writePlistData(root: root, to: url)
        return url
    }

    private func writePlistData(root: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        )
        try data.write(to: url)
    }
}
