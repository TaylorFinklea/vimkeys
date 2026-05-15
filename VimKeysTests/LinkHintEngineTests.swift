import XCTest
@testable import VimKeys

final class LinkHintEngineTests: XCTestCase {
    private let testAlphabet = "sadfjkl;"

    func testLabelLengthForSmallSet() {
        // 5 targets, 8-char alphabet → single-char labels (8 >= 5).
        XCTAssertEqual(LinkHintEngine.labelLength(n: 5, k: 8), 1)
    }

    func testLabelLengthForExactPower() {
        // 64 targets, 8-char alphabet → two-char labels (8^2 = 64).
        XCTAssertEqual(LinkHintEngine.labelLength(n: 64, k: 8), 2)
    }

    func testLabelLengthForOverflow() {
        // 65 targets, 8-char alphabet → three-char labels.
        XCTAssertEqual(LinkHintEngine.labelLength(n: 65, k: 8), 3)
    }

    func testEmptyAlphabetFallsBackToDefault() {
        let targets = [HintTarget(frame: CGRect(x: 0, y: 0, width: 10, height: 10), kind: .link)]
        let engine = LinkHintEngine(alphabet: "", targets: targets)
        XCTAssertEqual(engine.alphabet, Array(LinkHintEngine.defaultAlphabet))
    }

    func testSingleTargetGetsFirstAlphabetChar() {
        let targets = [HintTarget(frame: .zero, kind: .link)]
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: targets)
        XCTAssertEqual(engine.labels.count, 1)
        XCTAssertEqual(engine.labels[0].label, "s")
    }

    func testFiveTargetsGetFiveDistinctSingleCharLabels() {
        let targets = (0..<5).map { _ in HintTarget(frame: .zero, kind: .link) }
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: targets)
        XCTAssertEqual(engine.labels.map(\.label), ["s", "a", "d", "f", "j"])
    }

    func testNineTargetsGetTwoCharLabels() {
        // 9 targets, 8-char alphabet → two-char labels.
        let targets = (0..<9).map { _ in HintTarget(frame: .zero, kind: .link) }
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: targets)
        XCTAssertEqual(engine.labels.count, 9)
        XCTAssertTrue(engine.labels.allSatisfy { $0.label.count == 2 })
        XCTAssertEqual(engine.labels[0].label, "ss")
        XCTAssertEqual(engine.labels[1].label, "sa")
    }

    func testFilterEmptyPrefixReturnsAllAmbiguous() {
        let targets = (0..<3).map { _ in HintTarget(frame: .zero, kind: .link) }
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: targets)
        let result = engine.filter(typedPrefix: "")
        guard case .ambiguous(let matching) = result else {
            return XCTFail("Empty prefix should be ambiguous, got \(result)")
        }
        XCTAssertEqual(matching.count, 3)
    }

    func testFilterPartialPrefixNarrows() {
        let targets = (0..<9).map { _ in HintTarget(frame: .zero, kind: .link) }
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: targets)
        // Labels: ss, sa, sd, sf, sj, sk, sl, s;, as
        let result = engine.filter(typedPrefix: "s")
        guard case .ambiguous(let matching) = result else {
            return XCTFail("Prefix 's' should narrow, got \(result)")
        }
        XCTAssertEqual(matching.count, 8) // all labels starting with 's'
    }

    func testFilterFullLabelCommits() {
        let targets = [
            HintTarget(frame: .zero, kind: .link),
            HintTarget(frame: .zero, kind: .link),
        ]
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: targets)
        let result = engine.filter(typedPrefix: "a")
        XCTAssertEqual(result, .committed(targets[1].id))
    }

    func testFilterUnknownPrefixReturnsNone() {
        let targets = [HintTarget(frame: .zero, kind: .link)]
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: targets)
        let result = engine.filter(typedPrefix: "z")
        XCTAssertEqual(result, .none)
    }

    func testFilterIsCaseInsensitive() {
        let targets = [HintTarget(frame: .zero, kind: .link)]
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: targets)
        XCTAssertEqual(engine.filter(typedPrefix: "S"), .committed(targets[0].id))
    }

    func testIsAlphabetCharacter() {
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: [])
        XCTAssertTrue(engine.isAlphabetCharacter("s"))
        XCTAssertTrue(engine.isAlphabetCharacter("S"))
        XCTAssertFalse(engine.isAlphabetCharacter("z"))
        XCTAssertFalse(engine.isAlphabetCharacter("1"))
    }

    func testEmptyTargetsProducesNoLabels() {
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: [])
        XCTAssertTrue(engine.labels.isEmpty)
    }

    func testAssignmentMatchingFindsLabel() {
        let targets = [HintTarget(frame: .zero, kind: .link)]
        let engine = LinkHintEngine(alphabet: testAlphabet, targets: targets)
        XCTAssertNotNil(engine.assignment(matching: "s"))
        XCTAssertNotNil(engine.assignment(matching: "S")) // case-insensitive
        XCTAssertNil(engine.assignment(matching: "z"))
    }
}
