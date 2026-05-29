import XCTest
@testable import VimKeys

final class BindingsRemapTests: XCTestCase {
    func testDefaultTableBindsEveryCommand() {
        XCTAssertTrue(VimBindings.v1Default.unboundCommands.isEmpty)
        // Reverse index has an entry for every command.
        XCTAssertEqual(Set(VimBindings.v1Default.reverseIndex.keys),
                       Set(VimCommand.allCases))
    }

    func testForwardAndReverseLookup() {
        let b = VimBindings.v1Default
        XCTAssertEqual(b.command(for: .single("j")), .scrollDown)
        XCTAssertEqual(b.command(for: .g("g")), .top)
        XCTAssertEqual(b.command(for: .y("y")), .copyURL)
        XCTAssertEqual(b.command(for: .escape), .escape)
        XCTAssertEqual(b.chords(for: .scrollDown), [.single("j")])
    }

    func testChordDisplay() {
        XCTAssertEqual(Chord.single("j").display, "j")
        XCTAssertEqual(Chord.g("g").display, "gg")
        XCTAssertEqual(Chord.y("f").display, "yf")
        XCTAssertEqual(Chord.escape.display, "Esc")
        XCTAssertEqual(Chord.escapeEscape.display, "Esc Esc")
    }

    func testRebindingMovesCommandAndRemovesOldChord() {
        let b = VimBindings.v1Default.rebinding(.scrollDown, to: .single("z"))
        XCTAssertEqual(b.command(for: .single("z")), .scrollDown)
        XCTAssertNil(b.command(for: .single("j")))            // old chord freed
        XCTAssertEqual(b.chords(for: .scrollDown), [.single("z")])
    }

    func testConflictDetection() {
        let b = VimBindings.v1Default
        XCTAssertEqual(b.conflict(forAssigning: .single("k")), .scrollUp) // taken
        XCTAssertNil(b.conflict(forAssigning: .single("z")))              // free
    }

    func testRebindingIsNoOpForFixedEscapeChords() {
        XCTAssertEqual(VimBindings.v1Default.rebinding(.scrollDown, to: .escape),
                       VimBindings.v1Default)
        XCTAssertFalse(Chord.escape.isEditable)
        XCTAssertFalse(Chord.escapeEscape.isEditable)
        XCTAssertTrue(Chord.single("j").isEditable)
    }

    func testFilledWithDefaultsRestoresMissingCommand() {
        var b = VimBindings.v1Default
        b.singleChar.removeValue(forKey: "j")                 // drop scrollDown
        XCTAssertTrue(b.unboundCommands.contains(.scrollDown))

        let filled = b.filledWithDefaults()
        XCTAssertTrue(filled.unboundCommands.isEmpty)
        XCTAssertEqual(filled.command(for: .single("j")), .scrollDown)
    }

    func testWithKeyPreservesShape() {
        XCTAssertEqual(Chord.single("j").withKey("z"), .single("z"))
        XCTAssertEqual(Chord.g("g").withKey("t"), .g("t"))
        XCTAssertEqual(Chord.y("y").withKey("p"), .y("p"))
    }

    func testWithKeyRejectsInvalidKeys() {
        XCTAssertNil(Chord.single("j").withKey("5"))   // digit on single-char
        XCTAssertNil(Chord.single("j").withKey("ab"))  // multi-char
        XCTAssertNil(Chord.single("j").withKey(""))    // empty
        XCTAssertNil(Chord.escape.withKey("x"))        // fixed chord
        XCTAssertEqual(Chord.single("j").withKey("/"), .single("/")) // symbol ok
        XCTAssertEqual(Chord.g("g").withKey("5"), .g("5"))           // digit ok after g
    }

    func testFilledWithDefaultsDoesNotClobberUserRemap() {
        // User moved scrollUp onto "j" (scrollDown's default chord) and
        // scrollDown is now unbound. Filling must NOT overwrite "j".
        var b = VimBindings.v1Default
        b.singleChar["j"] = .scrollUp
        b.singleChar.removeValue(forKey: "k")                 // scrollUp's old chord
        let filled = b.filledWithDefaults()
        XCTAssertEqual(filled.command(for: .single("j")), .scrollUp) // preserved
    }
}
