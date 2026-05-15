import XCTest
@testable import VimKeys

final class SafariBookmarksTests: XCTestCase {
    /// Build a synthetic Bookmarks.plist in tmp, point `read(at:)` at it,
    /// confirm we get the expected flat list. Mirrors Safari's shape:
    /// nested folders containing leaf entries with URIDictionary.title.
    func testReadFlattensNestedFolders() throws {
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Title": "Bookmarks",
            "Children": [
                [
                    "WebBookmarkType": "WebBookmarkTypeLeaf",
                    "URLString": "https://apple.com/",
                    "URIDictionary": ["title": "Apple"],
                ],
                [
                    "WebBookmarkType": "WebBookmarkTypeList",
                    "Title": "Dev",
                    "Children": [
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://github.com/",
                            "URIDictionary": ["title": "GitHub"],
                        ],
                        [
                            "WebBookmarkType": "WebBookmarkTypeLeaf",
                            "URLString": "https://swift.org/",
                            "URIDictionary": ["title": "Swift"],
                        ],
                    ] as [Any],
                ],
            ] as [Any],
        ]

        let url = try writePlistToTmp(plist)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SafariBookmarks.read(at: url)
        guard case .success(let entries) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.title), ["Apple", "GitHub", "Swift"])
        XCTAssertEqual(entries.map(\.url.absoluteString), [
            "https://apple.com/",
            "https://github.com/",
            "https://swift.org/",
        ])
    }

    func testReadMissingFileReturnsFileMissing() {
        let url = URL(fileURLWithPath: "/tmp/vimkeys-missing-bookmarks.plist")
        let result = SafariBookmarks.read(at: url)
        XCTAssertEqual(result, .failure(.fileMissing))
    }

    func testReadMalformedDataReturnsMalformed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-malformed.plist")
        try Data("not a plist".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SafariBookmarks.read(at: url)
        XCTAssertEqual(result, .failure(.malformed))
    }

    func testLeafWithoutTitleFallsBackToHost() throws {
        let plist: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "Children": [
                [
                    "WebBookmarkType": "WebBookmarkTypeLeaf",
                    "URLString": "https://example.com/path",
                    "URIDictionary": [String: Any](),
                ],
            ] as [Any],
        ]
        let url = try writePlistToTmp(plist)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = SafariBookmarks.read(at: url)
        guard case .success(let entries) = result, entries.count == 1 else {
            return XCTFail("expected one entry, got \(result)")
        }
        XCTAssertEqual(entries[0].title, "example.com")
    }

    private func writePlistToTmp(_ plist: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-bookmarks-\(UUID()).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
        return url
    }
}
