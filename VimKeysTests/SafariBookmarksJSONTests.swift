import XCTest
@testable import VimKeys

/// Tests for the JSON-snapshot reader used by the 0.7.0 Safari Web
/// Extension path. HTML-export reader tests live in
/// `SafariBookmarksTests.swift`.
final class SafariBookmarksJSONTests: XCTestCase {
    /// Happy path: the JS side flattens its tree and emits an array of
    /// `{title, url}` dicts. The reader must preserve order and titles.
    func testReadsFlatArray() throws {
        let json: [[String: Any]] = [
            ["title": "Apple", "url": "https://apple.com/"],
            ["title": "GitHub", "url": "https://github.com/"],
        ]
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .success(let entries) = SafariBookmarks.readJSON(at: url) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(entries.map(\.title), ["Apple", "GitHub"])
    }

    func testMissingFileReturnsFileMissing() {
        let url = URL(fileURLWithPath: "/tmp/vimkeys-missing-\(UUID()).json")
        XCTAssertEqual(SafariBookmarks.readJSON(at: url), .failure(.fileMissing))
    }

    func testInvalidJSONReturnsMalformed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-bad-\(UUID()).json")
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SafariBookmarks.readJSON(at: url), .failure(.malformed))
    }

    /// Non-array root (e.g. someone hand-edited it into a dict) should
    /// surface as malformed rather than silently showing nothing.
    func testNonArrayJSONReturnsMalformed() throws {
        let url = try writeJSONRaw(Data("{\"wrong\": true}".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SafariBookmarks.readJSON(at: url), .failure(.malformed))
    }

    /// Missing title → fall back to host. Mirrors the HTML reader's
    /// behavior so the vomnibar always has something to filter on.
    func testMissingTitleFallsBackToHost() throws {
        let json: [[String: Any]] = [
            ["url": "https://example.com/path"],
        ]
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let entries) = SafariBookmarks.readJSON(at: url),
              entries.count == 1 else {
            return XCTFail("expected one entry")
        }
        XCTAssertEqual(entries[0].title, "example.com")
    }

    /// Non-navigable schemes (about:, javascript:, etc.) are filtered
    /// to match the HTML reader.
    func testNonNavigableSchemesAreSkipped() throws {
        let json: [[String: Any]] = [
            ["title": "Blank", "url": "about:blank"],
            ["title": "JS", "url": "javascript:alert(1)"],
            ["title": "OK", "url": "https://ok.example/"],
        ]
        let url = try writeJSON(json)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .success(let entries) = SafariBookmarks.readJSON(at: url) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(entries.map(\.title), ["OK"])
    }

    private func writeJSON(_ object: [[String: Any]]) throws -> URL {
        try writeJSONRaw(
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }

    private func writeJSONRaw(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-bookmarks-json-\(UUID()).json")
        try data.write(to: url)
        return url
    }
}
