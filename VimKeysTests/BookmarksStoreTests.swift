import XCTest
@testable import VimKeys

final class BookmarksStoreTests: XCTestCase {
    /// `start()` should seed the cache from disk synchronously so the
    /// vomnibar has data on the very first `b` press, before any
    /// directory event fires.
    func testStartSeedsCacheFromExistingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bookmarks.html")
        try minimalExport(at: file)

        let store = BookmarksStore(path: file)
        store.start()
        defer { store.stop() }

        guard case .success(let entries) = store.current() else {
            return XCTFail("expected cache to seed from file")
        }
        XCTAssertEqual(entries.map(\.title), ["Apple"])
    }

    /// When the file doesn't exist at start time, the cache should
    /// reflect that — the vomnibar surfaces the export instructions
    /// instead of showing an empty list.
    func testStartWithMissingFileCachesFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bookmarks.html")
        // Deliberately do not create the file.

        let store = BookmarksStore(path: file)
        store.start()
        defer { store.stop() }

        XCTAssertEqual(store.current(), .failure(.fileMissing))
    }

    /// Re-export from Safari atomically replaces the file (write tmp +
    /// rename over). The directory watcher should pick that up and
    /// refresh the cache without a process restart.
    func testWatcherPicksUpNewExport() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bookmarks.html")
        try minimalExport(at: file, sites: [("Apple", "https://apple.com/")])

        let store = BookmarksStore(path: file)
        store.start()
        defer { store.stop() }

        // Simulate Safari's atomic rename: write to .tmp, then rename
        // over the target.
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

        // Wait for debounced refresh (200 ms debounce + queue hop).
        let updated = expectation(description: "cache reflects new file")
        let deadline = Date().addingTimeInterval(2.0)
        DispatchQueue.global().async {
            while Date() < deadline {
                if case .success(let entries) = store.current(),
                   entries.map(\.title) == ["GitHub", "Swift"] {
                    updated.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        wait(for: [updated], timeout: 3.0)
    }

    /// The `folder` property must point at the parent of the configured
    /// file — `openBookmarksFolder()` reveals this in Finder, so a
    /// regression here would Finder-bounce the user to ~/Documents.
    func testFolderIsParentOfPath() throws {
        let path = URL(fileURLWithPath: "/tmp/foo/bar/bookmarks.html")
        let store = BookmarksStore(path: path)
        XCTAssertEqual(store.folder.path, "/tmp/foo/bar")
    }

    /// `refresh()` should reflect a manual edit even without going
    /// through the watcher (covers the menu's "Re-import" button).
    func testRefreshReadsCurrentFileContents() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bookmarks.html")
        try minimalExport(at: file, sites: [("Apple", "https://apple.com/")])

        let store = BookmarksStore(path: file)
        store.start()
        defer { store.stop() }
        XCTAssertEqual(try titlesFromCurrent(store), ["Apple"])

        try minimalExport(at: file, sites: [("Reddit", "https://reddit.com/")])
        store.refresh()
        XCTAssertEqual(try titlesFromCurrent(store), ["Reddit"])
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-bookmarks-store-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func minimalExport(
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

    private func titlesFromCurrent(_ store: BookmarksStore) throws -> [String] {
        switch store.current() {
        case .success(let entries): return entries.map(\.title)
        case .failure(let e): throw e
        }
    }
}
