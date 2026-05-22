import XCTest
@testable import VimKeys

final class BookmarksStoreTests: XCTestCase {
    /// `start()` should seed the cache from disk synchronously so the
    /// vomnibar has data on the very first `b` press, before any
    /// directory event fires.
    func testStartSeedsCacheFromExistingHTMLFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bookmarks.html")
        try writeMinimalExport(at: file)

        let store = BookmarksStore(htmlPath: file, plistPath: nil)
        store.start()
        defer { store.stop() }

        guard case .success(let entries) = store.current() else {
            return XCTFail("expected cache to seed from file")
        }
        XCTAssertEqual(entries.map(\.title), ["Apple"])
    }

    /// When neither source exists at start time, the cache should
    /// reflect that — the vomnibar surfaces the export instructions
    /// instead of showing an empty list.
    func testStartWithNothingCachesFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bookmarks.html")
        // Deliberately do not create the file.

        let store = BookmarksStore(htmlPath: file, plistPath: nil)
        store.start()
        defer { store.stop() }

        XCTAssertEqual(store.current(), .failure(.fileMissing))
    }

    /// Re-export from Safari atomically replaces the file (write tmp +
    /// rename over). The directory watcher should pick that up and
    /// refresh the cache without a process restart.
    func testWatcherPicksUpNewHTMLExport() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bookmarks.html")
        try writeMinimalExport(at: file, sites: [("Apple", "https://apple.com/")])

        let store = BookmarksStore(htmlPath: file, plistPath: nil)
        store.start()
        defer { store.stop() }

        let tmp = dir.appendingPathComponent("bookmarks.html.tmp")
        try minimalExportData(sites: [
            ("GitHub", "https://github.com/"),
            ("Swift", "https://swift.org/"),
        ]).write(to: tmp)
        try FileManager.default.replaceItem(
            at: file, withItemAt: tmp,
            backupItemName: nil, options: [],
            resultingItemURL: nil
        )

        waitForTitles(in: store, expected: ["GitHub", "Swift"])
    }

    /// When Safari's `Bookmarks.plist` is readable, it wins over the HTML
    /// export — it's the always-fresh live-sync source.
    func testPlistIsPreferredOverHTML() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let htmlFile = dir.appendingPathComponent("bookmarks.html")
        let plistFile = dir.appendingPathComponent("Bookmarks.plist")

        try writeMinimalExport(at: htmlFile, sites: [("FromHTML", "https://html.example/")])
        try bookmarksPlistData(sites: [("FromPlist", "https://plist.example/")])
            .write(to: plistFile)

        let store = BookmarksStore(htmlPath: htmlFile, plistPath: plistFile)
        store.start()
        defer { store.stop() }

        guard case .success(let entries) = store.current() else {
            return XCTFail("expected success from plist")
        }
        XCTAssertEqual(entries.map(\.title), ["FromPlist"])
        XCTAssertTrue(store.isUsingLiveSync)
    }

    /// When the plist path is configured but the file doesn't exist,
    /// fall back to the HTML export.
    func testFallsBackToHTMLWhenPlistMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let htmlFile = dir.appendingPathComponent("bookmarks.html")
        let plistFile = dir.appendingPathComponent("Bookmarks.plist")
        // Plist file deliberately not created.

        try writeMinimalExport(at: htmlFile, sites: [("FromHTML", "https://html.example/")])

        let store = BookmarksStore(htmlPath: htmlFile, plistPath: plistFile)
        store.start()
        defer { store.stop() }

        guard case .success(let entries) = store.current() else {
            return XCTFail("expected HTML fallback")
        }
        XCTAssertEqual(entries.map(\.title), ["FromHTML"])
        XCTAssertFalse(store.isUsingLiveSync)
    }

    /// An unreadable plist (Full Disk Access not granted) with an HTML
    /// export present degrades gracefully to HTML — no error surfaced,
    /// the user keeps working.
    func testFallsBackToHTMLWhenPlistUnreadable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let htmlFile = dir.appendingPathComponent("bookmarks.html")
        let plistFile = dir.appendingPathComponent("Bookmarks.plist")

        try writeMinimalExport(at: htmlFile, sites: [("FromHTML", "https://html.example/")])
        try bookmarksPlistData(sites: [("FromPlist", "https://plist.example/")])
            .write(to: plistFile)
        try makeUnreadable(plistFile)
        defer { try? makeReadable(plistFile) }

        let store = BookmarksStore(htmlPath: htmlFile, plistPath: plistFile)
        store.start()
        defer { store.stop() }

        guard case .success(let entries) = store.current() else {
            return XCTFail("expected HTML fallback")
        }
        XCTAssertEqual(entries.map(\.title), ["FromHTML"])
        XCTAssertFalse(store.isUsingLiveSync)
    }

    /// An unreadable plist with no HTML export to fall back on surfaces
    /// `.permissionDenied` — the vomnibar then tells the user to grant
    /// Full Disk Access rather than to export bookmarks.
    func testPermissionDeniedSurfacedWhenPlistUnreadableAndNoHTML() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let htmlFile = dir.appendingPathComponent("bookmarks.html")
        let plistFile = dir.appendingPathComponent("Bookmarks.plist")
        // HTML file deliberately not created.

        try bookmarksPlistData(sites: [("FromPlist", "https://plist.example/")])
            .write(to: plistFile)
        try makeUnreadable(plistFile)
        defer { try? makeReadable(plistFile) }

        let store = BookmarksStore(htmlPath: htmlFile, plistPath: plistFile)
        store.start()
        defer { store.stop() }

        XCTAssertEqual(store.current(), .failure(.permissionDenied))
    }

    /// When Safari rewrites `Bookmarks.plist`, the watcher should pick it
    /// up and refresh the cache without a process restart.
    func testWatcherPicksUpPlist() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let htmlFile = dir.appendingPathComponent("bookmarks.html")
        let plistFile = dir.appendingPathComponent("Bookmarks.plist")
        try bookmarksPlistData(sites: [("Before", "https://before.example/")])
            .write(to: plistFile)

        let store = BookmarksStore(htmlPath: htmlFile, plistPath: plistFile)
        store.start()
        defer { store.stop() }
        XCTAssertEqual(try titles(of: store), ["Before"])

        // Safari rewriting its store (atomic replace):
        let tmp = dir.appendingPathComponent("Bookmarks.plist.tmp")
        try bookmarksPlistData(sites: [("After", "https://after.example/")]).write(to: tmp)
        try FileManager.default.replaceItem(
            at: plistFile, withItemAt: tmp,
            backupItemName: nil, options: [],
            resultingItemURL: nil
        )

        waitForTitles(in: store, expected: ["After"])
        XCTAssertTrue(store.isUsingLiveSync)
    }

    /// `folder` must point at the HTML parent dir — the menu item
    /// reveals that in Finder. A regression here would Finder-bounce.
    func testFolderIsParentOfHTMLPath() throws {
        let path = URL(fileURLWithPath: "/tmp/foo/bar/bookmarks.html")
        let store = BookmarksStore(htmlPath: path, plistPath: nil)
        XCTAssertEqual(store.folder.path, "/tmp/foo/bar")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-bookmarks-store-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMinimalExport(
        at url: URL,
        sites: [(String, String)] = [("Apple", "https://apple.com/")]
    ) throws {
        try minimalExportData(sites: sites).write(to: url)
    }

    private func minimalExportData(sites: [(String, String)]) -> Data {
        var html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL>\n"
        for (title, urlString) in sites {
            html += "<DT><A HREF=\"\(urlString)\">\(title)</A>\n"
        }
        html += "</DL>\n"
        return Data(html.utf8)
    }

    /// Builds a Safari-shaped binary `Bookmarks.plist` with a flat list
    /// of leaf bookmarks.
    private func bookmarksPlistData(sites: [(String, String)]) throws -> Data {
        let children: [[String: Any]] = sites.map { title, url in
            [
                "WebBookmarkType": "WebBookmarkTypeLeaf",
                "URLString": url,
                "URIDictionary": ["title": title],
            ]
        }
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Title": "",
            "Children": children,
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        )
    }

    private func makeUnreadable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: url.path
        )
    }

    private func makeReadable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path
        )
    }

    private func titles(of store: BookmarksStore) throws -> [String] {
        switch store.current() {
        case .success(let entries): return entries.map(\.title)
        case .failure(let e): throw e
        }
    }

    /// Polls the store until its cached titles match, or fails after a
    /// few seconds. Used because the watcher fires asynchronously after
    /// a 200ms debounce.
    private func waitForTitles(
        in store: BookmarksStore,
        expected: [String],
        timeout: TimeInterval = 3.0,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let exp = expectation(description: "cache reflects \(expected)")
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global().async {
            while Date() < deadline {
                if case .success(let entries) = store.current(),
                   entries.map(\.title) == expected {
                    exp.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [exp], timeout: timeout + 0.5)
    }
}
