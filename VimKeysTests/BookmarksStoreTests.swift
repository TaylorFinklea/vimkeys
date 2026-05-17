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

        let store = BookmarksStore(htmlPath: file, containerPath: nil)
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

        let store = BookmarksStore(htmlPath: file, containerPath: nil)
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

        let store = BookmarksStore(htmlPath: file, containerPath: nil)
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

    /// When the App Group container has a JSON snapshot, it wins over
    /// the HTML export. This is the 0.7.0 live-sync path.
    func testContainerJSONIsPreferredOverHTML() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let htmlFile = dir.appendingPathComponent("bookmarks.html")
        let containerFile = dir.appendingPathComponent("bookmarks.json")

        try writeMinimalExport(at: htmlFile, sites: [("FromHTML", "https://html.example/")])
        let json: [[String: Any]] = [
            ["title": "FromExtension", "url": "https://ext.example/"],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: containerFile)

        let store = BookmarksStore(htmlPath: htmlFile, containerPath: containerFile)
        store.start()
        defer { store.stop() }

        guard case .success(let entries) = store.current() else {
            return XCTFail("expected success from container")
        }
        XCTAssertEqual(entries.map(\.title), ["FromExtension"])
    }

    /// When the container path is configured but no JSON file exists,
    /// fall back to HTML. This matches the typical user state after
    /// installing 0.7.0 but before enabling the Safari extension (or
    /// before registering the App Group on developer.apple.com).
    func testFallsBackToHTMLWhenContainerMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let htmlFile = dir.appendingPathComponent("bookmarks.html")
        let containerFile = dir.appendingPathComponent("bookmarks.json")
        // Container file deliberately not created.

        try writeMinimalExport(at: htmlFile, sites: [("FromHTML", "https://html.example/")])

        let store = BookmarksStore(htmlPath: htmlFile, containerPath: containerFile)
        store.start()
        defer { store.stop() }

        guard case .success(let entries) = store.current() else {
            return XCTFail("expected HTML fallback")
        }
        XCTAssertEqual(entries.map(\.title), ["FromHTML"])
        XCTAssertFalse(store.isUsingExtension)
    }

    /// When the extension drops a fresh container snapshot, the watcher
    /// should pick it up and switch the cache from HTML to JSON.
    func testWatcherPicksUpContainerJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let htmlFile = dir.appendingPathComponent("bookmarks.html")
        let containerFile = dir.appendingPathComponent("bookmarks.json")
        try writeMinimalExport(at: htmlFile, sites: [("FromHTML", "https://html.example/")])

        let store = BookmarksStore(htmlPath: htmlFile, containerPath: containerFile)
        store.start()
        defer { store.stop() }
        XCTAssertEqual(try titles(of: store), ["FromHTML"])

        // Extension dropping a snapshot:
        let json: [[String: Any]] = [
            ["title": "Live", "url": "https://live.example/"],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: containerFile)

        waitForTitles(in: store, expected: ["Live"])
        XCTAssertTrue(store.isUsingExtension)
    }

    /// `folder` must point at the HTML parent dir — the menu item
    /// reveals that in Finder. A regression here would Finder-bounce.
    func testFolderIsParentOfHTMLPath() throws {
        let path = URL(fileURLWithPath: "/tmp/foo/bar/bookmarks.html")
        let store = BookmarksStore(htmlPath: path, containerPath: nil)
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
