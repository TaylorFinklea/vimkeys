import XCTest
@testable import VimKeys

@MainActor
final class SafariURLPollerTests: XCTestCase {
    private let urlA = URL(string: "https://gmail.com/inbox")!
    private let urlB = URL(string: "https://github.com/")!

    /// The background poll must gate on permission without prompting: no
    /// access → no report; access → reports.
    func testGatesOnAccess() {
        var reported: [URL?] = []
        var access = false
        let poller = SafariURLPoller(
            hasAccess: { access },
            currentURL: { self.urlA },
            onURLChange: { reported.append($0) }
        )
        XCTAssertFalse(poller.poll())
        XCTAssertTrue(reported.isEmpty)

        access = true
        XCTAssertTrue(poller.poll())
        XCTAssertEqual(reported.compactMap { $0 }, [urlA])
    }

    /// A transient nil must NOT be forwarded (forwarding nil would reconcile
    /// a disabled site back to enabled) and must NOT disturb the dedupe
    /// state — the disabled URL is preserved across the hiccup. (F20)
    func testTransientNilIsSkippedAndPreservesState() {
        var reported: [URL?] = []
        var current: URL? = urlA
        let poller = SafariURLPoller(
            hasAccess: { true },
            currentURL: { current },
            onURLChange: { reported.append($0) }
        )
        XCTAssertTrue(poller.poll())          // reports A

        current = nil
        XCTAssertFalse(poller.poll())         // transient nil: skipped, not forwarded

        current = urlA
        XCTAssertFalse(poller.poll())         // still A: deduped, no re-report

        current = urlB
        XCTAssertTrue(poller.poll())          // navigation to B: reported

        XCTAssertEqual(reported, [urlA, urlB]) // never a nil in the stream
    }

    /// Identical URLs dedupe to a single report.
    func testDedupesRepeatedURL() {
        var reported: [URL?] = []
        let poller = SafariURLPoller(
            hasAccess: { true },
            currentURL: { self.urlA },
            onURLChange: { reported.append($0) }
        )
        XCTAssertTrue(poller.poll())
        XCTAssertFalse(poller.poll())
        XCTAssertFalse(poller.poll())
        XCTAssertEqual(reported.count, 1)
    }

    /// stop() clears the dedupe cache (so a resume re-confirms the URL) but
    /// must never push nil to the sink. (F21)
    func testStopClearsDedupeWithoutPushingNil() {
        var reported: [URL?] = []
        let poller = SafariURLPoller(
            hasAccess: { true },
            currentURL: { self.urlA },
            onURLChange: { reported.append($0) }
        )
        XCTAssertTrue(poller.poll())          // reports A
        poller.stop()                         // must NOT push nil
        XCTAssertTrue(poller.poll())          // dedupe cleared → re-reports A

        XCTAssertEqual(reported, [urlA, urlA]) // two A's, zero nils
    }
}
