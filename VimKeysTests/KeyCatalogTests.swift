import XCTest
@testable import VimKeys

final class KeyCatalogTests: XCTestCase {
    func testNoDuplicateBindingChords() {
        let bindings = VimBindings.v1Default

        // Single-character chords are inherently unique (Dictionary keys),
        // but `g`-prefix and `y`-prefix can collide with each other across
        // tables. Asserting per-table dictionary count == declared-pairs
        // count guards against a future literal accidentally collapsing.
        XCTAssertEqual(bindings.singleChar.count, declaredSinglePairCount,
                       "singleChar binding literal collapsed a duplicate key")
        XCTAssertEqual(bindings.gPrefix.count, declaredGPrefixCount,
                       "gPrefix binding literal collapsed a duplicate key")
        XCTAssertEqual(bindings.yPrefix.count, declaredYPrefixCount,
                       "yPrefix binding literal collapsed a duplicate key")
    }

    func testEveryVimCommandHasABinding() {
        let bound = VimBindings.v1Default.allBoundCommands
        let all = Set(VimCommand.allCases)
        let orphans = all.subtracting(bound)
        XCTAssertTrue(orphans.isEmpty,
                      "VimCommand cases without any binding: \(orphans.map(\.rawValue).sorted())")
    }

    func testV1ScrollBindingsResolveToScrollCommands() {
        let bindings = VimBindings.v1Default
        XCTAssertEqual(bindings.singleChar["j"], .scrollDown)
        XCTAssertEqual(bindings.singleChar["k"], .scrollUp)
        XCTAssertEqual(bindings.singleChar["h"], .scrollLeft)
        XCTAssertEqual(bindings.singleChar["l"], .scrollRight)
        XCTAssertEqual(bindings.singleChar["d"], .halfPageDown)
        XCTAssertEqual(bindings.singleChar["u"], .halfPageUp)
        XCTAssertEqual(bindings.singleChar["G"], .bottom)
        XCTAssertEqual(bindings.gPrefix["g"], .top)
    }

    func testEscapeBindingsAreSetForVM2AndVM5() {
        let bindings = VimBindings.v1Default
        XCTAssertEqual(bindings.escapeAlone, .escape)
        XCTAssertEqual(bindings.escapeChord, .suspendChord)
    }

    func testSafariBundleIDsContainTechPreview() {
        XCTAssertTrue(SafariObserver.safariBundleIDs.contains("com.apple.Safari"))
        XCTAssertTrue(SafariObserver.safariBundleIDs.contains("com.apple.SafariTechnologyPreview"))
    }

    // MARK: - Declared-pair counts (kept in sync with VimBindings.v1Default)
    //
    // If a future commit adds or removes a binding row in
    // `VimBindings.v1Default`, update the counts here too — the duplicate-
    // chord assertion above relies on them.
    private let declaredSinglePairCount = 25  // j k h l d u G f F / n N H L r R o O b B T p P i ?
    private let declaredGPrefixCount = 3      // g i s
    private let declaredYPrefixCount = 2      // y f
}
