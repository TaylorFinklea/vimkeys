import CoreGraphics
import XCTest
@testable import VimKeys

final class VimStateMachineTests: XCTestCase {
    private let baseTimestamp: UInt64 = 1_000_000_000

    private func defaultSettings() -> VimSettings {
        .v1Default
    }

    // MARK: - Disabled-mode pass-through

    func testDecidePassesThroughWhenDisabled() {
        var machine = VimStateMachine(settings: defaultSettings())
        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x26, // j
            characters: "j",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .passThrough)
        XCTAssertFalse(decision.modeDidChange)
        XCTAssertEqual(machine.mode, .disabled)
    }

    func testDecidePassesThroughKeyUpInNormalMode() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyUp,
            keyCode: 0x26,
            characters: "j",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .passThrough)
        XCTAssertFalse(decision.modeDidChange)
    }

    // MARK: - Safari-frontmost transitions

    func testUpdateSafariFrontmostEntersNormalFromDisabled() {
        var machine = VimStateMachine(settings: defaultSettings())
        let decision = machine.updateSafariFrontmost(true)
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.modeDidChange, true)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testUpdateSafariFrontmostExitsToDisabled() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.updateSafariFrontmost(false)
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.modeDidChange, true)
        XCTAssertEqual(machine.mode, .disabled)
    }

    func testUpdateSafariFrontmostNoOpWhenAlreadyMatching() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let secondActivate = machine.updateSafariFrontmost(true)
        XCTAssertNil(secondActivate)
    }

    // MARK: - Single-character scroll bindings

    func testDecideJScrollsDown() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x26,
            characters: "j",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .scroll(direction: .vertical, amount: .lines(-3)))
    }

    func testDecideKScrollsUp() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x28,
            characters: "k",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .scroll(direction: .vertical, amount: .lines(3)))
    }

    func testDecideHScrollsLeft() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x04,
            characters: "h",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .scroll(direction: .horizontal, amount: .lines(-3)))
    }

    func testDecideLScrollsRight() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x25,
            characters: "l",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .scroll(direction: .horizontal, amount: .lines(3)))
    }

    // MARK: - Half-page (d / u)

    func testDecideDHalfPageDown() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x02,
            characters: "d",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .scroll(direction: .vertical, amount: .halfPage(-1)))
    }

    func testDecideUHalfPageUp() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x20,
            characters: "u",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .scroll(direction: .vertical, amount: .halfPage(1)))
    }

    // MARK: - Edge bindings (gg / G)

    func testDecideGgScrollsToTop() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let firstG = machine.decide(
            eventType: .keyDown,
            keyCode: 0x05,
            characters: "g",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(firstG.intent, .consume)
        XCTAssertEqual(machine.mode, .normal(prefix: .g(count: nil)))

        let secondG = machine.decide(
            eventType: .keyDown,
            keyCode: 0x05,
            characters: "g",
            flags: [],
            timestamp: baseTimestamp + 100_000_000
        )
        XCTAssertEqual(secondG.intent, .scrollToEdge(.top))
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testDecideShiftGScrollsToBottom() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x05,
            characters: "G",
            flags: .maskShift,
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .scrollToEdge(.bottom))
    }

    func testDecideGFollowedByUnknownCharCancelsPrefix() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        _ = machine.decide(
            eventType: .keyDown,
            keyCode: 0x05,
            characters: "g",
            flags: [],
            timestamp: baseTimestamp
        )
        let cancel = machine.decide(
            eventType: .keyDown,
            keyCode: 0x06, // z
            characters: "z",
            flags: [],
            timestamp: baseTimestamp + 50_000_000
        )
        XCTAssertEqual(cancel.intent, .passThrough)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    // MARK: - Repeat counts

    func testDecideCountThenJScrollsNTimes() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let five = machine.decide(
            eventType: .keyDown,
            keyCode: 0x17, // 5
            characters: "5",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(five.intent, .consume)
        XCTAssertEqual(machine.mode, .normal(prefix: .count(5)))

        let scroll = machine.decide(
            eventType: .keyDown,
            keyCode: 0x26,
            characters: "j",
            flags: [],
            timestamp: baseTimestamp + 100_000_000
        )
        XCTAssertEqual(scroll.intent, .scroll(direction: .vertical, amount: .lines(-15)))
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testDecideMultiDigitCount() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        _ = machine.decide(
            eventType: .keyDown, keyCode: 0x12, characters: "1",
            flags: [], timestamp: baseTimestamp
        )
        _ = machine.decide(
            eventType: .keyDown, keyCode: 0x13, characters: "2",
            flags: [], timestamp: baseTimestamp + 10_000_000
        )
        XCTAssertEqual(machine.mode, .normal(prefix: .count(12)))

        let scroll = machine.decide(
            eventType: .keyDown, keyCode: 0x28, characters: "k",
            flags: [], timestamp: baseTimestamp + 20_000_000
        )
        XCTAssertEqual(scroll.intent, .scroll(direction: .vertical, amount: .lines(36)))
    }

    func testDecideCountCapsAt999() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        // Type "9" five times — would be 99999 without the cap.
        for _ in 0..<5 {
            _ = machine.decide(
                eventType: .keyDown, keyCode: 0x19, characters: "9",
                flags: [], timestamp: baseTimestamp
            )
        }
        XCTAssertEqual(machine.mode, .normal(prefix: .count(999)))
    }

    func testDecideZeroDoesNotStartCount() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown, keyCode: 0x1D, characters: "0",
            flags: [], timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .passThrough)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testDecideZeroExtendsExistingCount() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        _ = machine.decide(
            eventType: .keyDown, keyCode: 0x12, characters: "1",
            flags: [], timestamp: baseTimestamp
        )
        _ = machine.decide(
            eventType: .keyDown, keyCode: 0x1D, characters: "0",
            flags: [], timestamp: baseTimestamp + 10_000_000
        )
        XCTAssertEqual(machine.mode, .normal(prefix: .count(10)))
    }

    /// `5gg` jumps to the absolute top regardless of count, matching Vimium.
    func testDecideGgAfterCountIgnoresCount() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        _ = machine.decide(
            eventType: .keyDown, keyCode: 0x17, characters: "5",
            flags: [], timestamp: baseTimestamp
        )
        _ = machine.decide(
            eventType: .keyDown, keyCode: 0x05, characters: "g",
            flags: [], timestamp: baseTimestamp + 10_000_000
        )
        XCTAssertEqual(machine.mode, .normal(prefix: .g(count: 5)))

        let top = machine.decide(
            eventType: .keyDown, keyCode: 0x05, characters: "g",
            flags: [], timestamp: baseTimestamp + 20_000_000
        )
        XCTAssertEqual(top.intent, .scrollToEdge(.top))
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    // MARK: - Prefix timeout

    func testDecideCommandTimeoutClearsPrefix() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        _ = machine.decide(
            eventType: .keyDown, keyCode: 0x05, characters: "g",
            flags: [], timestamp: baseTimestamp
        )
        XCTAssertEqual(machine.mode, .normal(prefix: .g(count: nil)))

        let timeout = machine.commandTimeout()
        XCTAssertTrue(timeout.modeDidChange)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testCommandTimeoutNoOpInNormalNonePrefix() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let timeout = machine.commandTimeout()
        XCTAssertFalse(timeout.modeDidChange)
        XCTAssertEqual(timeout.intent, .passThrough)
    }

    // MARK: - Modifier policy

    func testDecidePassesThroughWhenCommandModifierHeld() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x26,
            characters: "j",
            flags: .maskCommand,
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .passThrough)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testDecidePassesThroughWhenOptionModifierHeld() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x26,
            characters: "j",
            flags: .maskAlternate,
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .passThrough)
    }

    func testDecidePassesThroughWhenControlModifierHeld() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x26,
            characters: "j",
            flags: .maskControl,
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .passThrough)
    }

    // MARK: - Unbound keys

    func testDecidePassesThroughUnboundKey() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        let decision = machine.decide(
            eventType: .keyDown,
            keyCode: 0x06, // z
            characters: "z",
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(decision.intent, .passThrough)
    }

    /// Single-character bindings whose owning milestone (V-M2..V-M4) hasn't
    /// landed yet must still be defined in the catalog but resolve to
    /// `.passThrough` — never silently consumed.
    func testDecideForwardCompatBindingsPassThroughAtVM1() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)

        for char in ["f", "F", "/", "n", "N", "H", "L", "r", "R",
                     "o", "O", "b", "B", "T", "p", "P", "i", "?"] {
            let decision = machine.decide(
                eventType: .keyDown,
                keyCode: 0x00, // keycode is ignored for character-keyed bindings
                characters: char,
                flags: char == char.uppercased() && char != char.lowercased() ? .maskShift : [],
                timestamp: baseTimestamp
            )
            XCTAssertEqual(decision.intent, .passThrough,
                           "Forward-compat char '\(char)' should pass through at V-M1")
        }
    }
}
