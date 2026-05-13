import XCTest
@testable import VimKeys

final class USKeyboardLayoutTests: XCTestCase {
    /// Every character VimKeys' default bindings dispatch on must be
    /// reachable from some keycode + shift state — otherwise the engine
    /// would treat its own bindings as passThrough.
    func testEveryBoundCharacterIsReachable() {
        let bindings = VimBindings.v1Default
        var dispatchChars = Set<String>()
        dispatchChars.formUnion(bindings.singleChar.keys)
        dispatchChars.formUnion(bindings.gPrefix.keys)
        dispatchChars.formUnion(bindings.yPrefix.keys)

        for chars in dispatchChars {
            XCTAssertTrue(
                isReachable(chars),
                "VimKeys binds \(chars.debugDescription) but USKeyboardLayout can't produce that char from any keycode"
            )
        }
    }

    func testDigitsZeroThroughNine() {
        // 0..9 are how counts get typed; every one must resolve.
        let pairs: [(CGKeyCode, String)] = [
            (0x1D, "0"), (0x12, "1"), (0x13, "2"), (0x14, "3"),
            (0x15, "4"), (0x17, "5"), (0x16, "6"), (0x1A, "7"),
            (0x1C, "8"), (0x19, "9"),
        ]
        for (keyCode, expected) in pairs {
            XCTAssertEqual(
                USKeyboardLayout.characters(forKeyCode: keyCode, shifted: false),
                expected
            )
        }
    }

    func testShiftedFormForLetters() {
        // Shift+g → "G", not "g" — vim's `G` binding depends on this.
        XCTAssertEqual(USKeyboardLayout.characters(forKeyCode: 0x05, shifted: false), "g")
        XCTAssertEqual(USKeyboardLayout.characters(forKeyCode: 0x05, shifted: true), "G")
        XCTAssertEqual(USKeyboardLayout.characters(forKeyCode: 0x26, shifted: false), "j")
        XCTAssertEqual(USKeyboardLayout.characters(forKeyCode: 0x26, shifted: true), "J")
    }

    func testQuestionMarkIsShiftedSlash() {
        // `?` binds to help and is shift+/. Both forms must resolve.
        XCTAssertEqual(USKeyboardLayout.characters(forKeyCode: 0x2C, shifted: false), "/")
        XCTAssertEqual(USKeyboardLayout.characters(forKeyCode: 0x2C, shifted: true), "?")
    }

    func testUnmappedKeyCodeReturnsNil() {
        // Modifier keys, function keys, Return / Tab / Esc — those aren't in
        // the dispatch table and must not invent a phantom character.
        XCTAssertNil(USKeyboardLayout.characters(forKeyCode: 0x35, shifted: false)) // Esc
        XCTAssertNil(USKeyboardLayout.characters(forKeyCode: 0x24, shifted: false)) // Return
        XCTAssertNil(USKeyboardLayout.characters(forKeyCode: 0x30, shifted: false)) // Tab
        XCTAssertNil(USKeyboardLayout.characters(forKeyCode: 0x7E, shifted: false)) // Up arrow
    }

    private func isReachable(_ chars: String) -> Bool {
        // Brute-force sweep: every (keyCode in 0..0x7F, shifted in {false,
        // true}) — return true if any pair produces `chars`.
        for raw in 0...0x7F {
            let keyCode = CGKeyCode(raw)
            if USKeyboardLayout.characters(forKeyCode: keyCode, shifted: false) == chars { return true }
            if USKeyboardLayout.characters(forKeyCode: keyCode, shifted: true) == chars { return true }
        }
        return false
    }
}
