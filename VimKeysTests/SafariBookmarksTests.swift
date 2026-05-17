import XCTest
@testable import VimKeys

final class SafariBookmarksTests: XCTestCase {
    /// Realistic Safari export: nested folders with anchor tags, mixed
    /// case in attribute names. Should yield three entries in source
    /// order, folder hierarchy ignored.
    func testReadFlattensNestedFolders() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <HTML>
        <HEAD><Title>Bookmarks</Title></HEAD>
        <BODY>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><A HREF="https://apple.com/" ADD_DATE="123">Apple</A>
            <DT><H3 FOLDED>Dev</H3>
            <DL><p>
                <DT><A HREF="https://github.com/">GitHub</A>
                <DT><a href="https://swift.org/">Swift</a>
            </DL><p>
        </DL><p>
        </BODY>
        </HTML>
        """
        let url = try writeHTML(html)
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
        let url = URL(fileURLWithPath: "/tmp/vimkeys-missing-bookmarks-\(UUID()).html")
        let result = SafariBookmarks.read(at: url)
        XCTAssertEqual(result, .failure(.fileMissing))
    }

    /// A file that's not an HTML bookmarks export at all — random text —
    /// must surface as malformed so the user knows to re-export rather
    /// than seeing a silent empty list.
    func testReadGarbageDataReturnsMalformed() throws {
        let url = try writeHTML("just some plain text, no bookmarks here")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SafariBookmarks.read(at: url), .failure(.malformed))
    }

    /// Empty bookmarks file (valid Netscape header, zero anchors). This
    /// is a legitimate state — the user has no bookmarks — and should
    /// succeed with an empty list rather than report malformed.
    func testEmptyButValidExportSucceedsWithEmptyList() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <HTML><BODY><H1>Bookmarks</H1><DL><p></DL></BODY></HTML>
        """
        let url = try writeHTML(html)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = SafariBookmarks.read(at: url)
        guard case .success(let entries) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(entries.isEmpty)
    }

    /// Anchor tags that don't have a usable title (or carry an empty
    /// one) fall back to the URL host so the vomnibar always has
    /// something to filter on.
    func testEmptyTitleFallsBackToHost() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><DT><A HREF="https://example.com/path"></A></DL>
        """
        let url = try writeHTML(html)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = SafariBookmarks.read(at: url)
        guard case .success(let entries) = result, entries.count == 1 else {
            return XCTFail("expected one entry, got \(result)")
        }
        XCTAssertEqual(entries[0].title, "example.com")
    }

    /// HTML entities in titles get decoded. Safari emits `&amp;`,
    /// numeric refs, and the curly-quote chars used in folder names.
    func testTitleEntitiesAreDecoded() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL>
            <DT><A HREF="https://a.example/">Tom &amp; Jerry</A>
            <DT><A HREF="https://b.example/">Foo &#39;bar&#39;</A>
            <DT><A HREF="https://c.example/">&#x2014; dash</A>
        </DL>
        """
        let url = try writeHTML(html)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = SafariBookmarks.read(at: url)
        guard case .success(let entries) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(entries.map(\.title), [
            "Tom & Jerry",
            "Foo 'bar'",
            "\u{2014} dash",
        ])
    }

    /// Non-navigable schemes (about:, place:, javascript:) shouldn't end
    /// up in the suggestion list — opening them is either a no-op or
    /// actively unhelpful.
    func testNonNavigableSchemesAreSkipped() throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL>
            <DT><A HREF="about:blank">Blank</A>
            <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
            <DT><A HREF="place:type=6">Smart folder</A>
            <DT><A HREF="https://ok.example/">OK</A>
        </DL>
        """
        let url = try writeHTML(html)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = SafariBookmarks.read(at: url)
        guard case .success(let entries) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(entries.map(\.title), ["OK"])
    }

    /// `defaultPath` and the export-instruction string need to stay in
    /// sync — the instruction text is the user's only breadcrumb pointing
    /// at the right path, so a divergence between the two would silently
    /// teach users to export to the wrong place.
    func testDefaultPathAndInstructionsAreConsistent() {
        XCTAssertTrue(
            SafariBookmarks.defaultPath.path.hasSuffix("Documents/VimKeys/bookmarks.html"),
            "defaultPath unexpectedly changed; update exportInstructions to match"
        )
        XCTAssertTrue(
            SafariBookmarks.exportInstructions.contains("~/Documents/VimKeys/bookmarks.html"),
            "exportInstructions drifted from defaultPath"
        )
    }

    private func writeHTML(_ html: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vimkeys-bookmarks-\(UUID()).html")
        try Data(html.utf8).write(to: url)
        return url
    }
}
