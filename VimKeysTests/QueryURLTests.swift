import XCTest
@testable import VimKeys

final class QueryURLTests: XCTestCase {
    func testCandidateAcceptsExplicitURL() {
        XCTAssertEqual(QueryURL.candidate(from: "https://example.com/x")?.absoluteString,
                       "https://example.com/x")
    }

    func testCandidatePrependsSchemeForBareHost() {
        XCTAssertEqual(QueryURL.candidate(from: "example.com")?.absoluteString,
                       "https://example.com")
        XCTAssertEqual(QueryURL.candidate(from: "  github.com/a  ")?.absoluteString,
                       "https://github.com/a") // trimmed
    }

    func testCandidateRejectsSearchyText() {
        XCTAssertNil(QueryURL.candidate(from: "how to tie a tie")) // has spaces
        XCTAssertNil(QueryURL.candidate(from: "swift concurrency")) // no dot
        XCTAssertNil(QueryURL.candidate(from: "   "))
    }

    func testDuckDuckGoSearchEncodesQuery() {
        let url = QueryURL.duckDuckGoSearch(for: "swift concurrency")
        XCTAssertEqual(url?.host, "duckduckgo.com")
        let q = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(q, "swift concurrency")
        XCTAssertNil(QueryURL.duckDuckGoSearch(for: "  "))
    }

    func testResolvePrefersURLThenFallsBackToSearch() {
        XCTAssertEqual(QueryURL.resolve("example.com")?.host, "example.com")
        XCTAssertEqual(QueryURL.resolve("a search query")?.host, "duckduckgo.com")
    }
}
