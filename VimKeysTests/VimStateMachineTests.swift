import CoreGraphics
import XCTest
@testable import VimKeys

final class VimStateMachineTests: XCTestCase {
    private let baseTimestamp: UInt64 = 1_000_000_000

    private func defaultSettings() -> VimSettings {
        // Pre-0.7.1 tests assume `.normal` is the floor mode after
        // becoming Safari-frontmost. Pin `.autoDetect` here so the
        // existing scroll / hint / find expectations still hold;
        // dedicated `.insertFirst` tests live further down the file.
        VimSettings(insertModeBehavior: .autoDetect)
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

    /// `b`/`B` enter bookmark-flavored vomnibar sessions. Verify the
    /// flavor + intent shape.
    func testDecideBLowercaseOpensBookmarkVomnibar() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let decision = machine.decide(
            eventType: .keyDown, keyCode: 0x0B, characters: "b",
            flags: [], timestamp: baseTimestamp
        )
        XCTAssertEqual(
            decision.intent,
            .requestVomnibar(.bookmarks(openInNewTab: false))
        )
    }

    func testDecideBUppercaseOpensBookmarkVomnibarNewTab() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let decision = machine.decide(
            eventType: .keyDown, keyCode: 0x0B, characters: "B",
            flags: .maskShift, timestamp: baseTimestamp
        )
        XCTAssertEqual(
            decision.intent,
            .requestVomnibar(.bookmarks(openInNewTab: true))
        )
    }

    // MARK: - V-M2 bindings: find / history / reload / insert / Esc / help

    func testDecideSlashEmitsCmdF() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x2C, characters: "/",
                               flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.f, flags: .maskCommand))
    }

    func testDecideNEmitsCmdG() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x2D, characters: "n",
                               flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.g, flags: .maskCommand))
    }

    func testDecideShiftNEmitsCmdShiftG() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x2D, characters: "N",
                               flags: .maskShift, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.g, flags: [.maskCommand, .maskShift]))
    }

    func testDecideShiftHEmitsCmdLeftBracket() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x04, characters: "H",
                               flags: .maskShift, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.leftBracket, flags: .maskCommand))
    }

    func testDecideShiftLEmitsCmdRightBracket() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x25, characters: "L",
                               flags: .maskShift, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.rightBracket, flags: .maskCommand))
    }

    func testDecideREmitsCmdR() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x0F, characters: "r",
                               flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.r, flags: .maskCommand))
    }

    func testDecideShiftREmitsCmdOptionR() {
        // Safari binds Cmd+Shift+R to "Show Reader" on macOS 14+, so we
        // synthesize Cmd+Option+R (Develop menu's "Reload Page From
        // Origin") for hard-reload semantics.
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x0F, characters: "R",
                               flags: .maskShift, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.r, flags: [.maskCommand, .maskAlternate]))
    }

    func testDecideXClosesTab() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x07, characters: "x",
                               flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.w, flags: .maskCommand))
    }

    func testDecideShiftXReopensClosedTab() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x07, characters: "X",
                               flags: .maskShift, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.t, flags: [.maskCommand, .maskShift]))
    }

    /// Cmd+H — remap to previous tab (Cmd+Shift+[). Active in any mode
    /// so users don't have to switch out of insert first.
    func testCmdHRemapsToPreviousTab() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.h, characters: "h",
                               flags: .maskCommand, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.leftBracket, flags: [.maskCommand, .maskShift]))
    }

    func testCmdLRemapsToNextTab() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.l, characters: "l",
                               flags: .maskCommand, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.rightBracket, flags: [.maskCommand, .maskShift]))
    }

    /// Cmd+Option+H (Hide Others under macOS) must NOT be eaten by the
    /// Cmd+H tab remap — the exact-modifier check is critical so users
    /// keep their three-modifier system bindings.
    func testCmdOptionHPassesThrough() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.h, characters: "h",
                               flags: [.maskCommand, .maskAlternate], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .passThrough)
    }

    /// Tab remap also fires in insert mode (the new default) — the
    /// user shouldn't have to leave insert to navigate tabs.
    func testCmdHFiresInInsertMode() {
        var machine = VimStateMachine(settings: VimSettings(insertModeBehavior: .insertFirst))
        machine.updateSafariFrontmost(true)
        XCTAssertEqual(machine.mode, .insert)
        let d = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.h, characters: "h",
                               flags: .maskCommand, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.leftBracket, flags: [.maskCommand, .maskShift]))
    }

    /// Cmd+Shift+H emits `.previousTabGroup`; AppModel handles by
    /// triggering Safari's "Window → Go to Previous Tab Group" menu item.
    func testCmdShiftHEmitsPreviousTabGroup() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.h, characters: "H",
                               flags: [.maskCommand, .maskShift], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .previousTabGroup)
    }

    func testCmdShiftLEmitsNextTabGroup() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.l, characters: "L",
                               flags: [.maskCommand, .maskShift], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .nextTabGroup)
    }

    /// Critical: adding a third modifier (Option) must NOT match the
    /// tab-group chord. Users still keep all their three-modifier
    /// system bindings.
    func testCmdShiftOptionHPassesThrough() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.h, characters: "H",
                               flags: [.maskCommand, .maskShift, .maskAlternate], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .passThrough)
    }

    func testDecideIEntersInsertMode() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x22, characters: "i",
                               flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .consume)
        XCTAssertTrue(d.modeDidChange)
        XCTAssertEqual(machine.mode, .insert)
    }

    func testDecideEscInInsertReturnsToNormalAndUnfocuses() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.decide(eventType: .keyDown, keyCode: 0x22, characters: "i",
                           flags: [], timestamp: baseTimestamp)

        let esc = machine.decide(
            eventType: .keyDown,
            keyCode: VimKeyCode.escape,
            characters: nil,
            flags: [],
            timestamp: baseTimestamp + 100_000_000
        )
        XCTAssertEqual(esc.intent, .unfocusActiveElement)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testDecideEscInNormalNoneIsPassThrough() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let esc = machine.decide(
            eventType: .keyDown,
            keyCode: VimKeyCode.escape,
            characters: nil,
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(esc.intent, .passThrough)
        XCTAssertFalse(esc.modeDidChange)
    }

    func testDecideEscInNormalWithCountCancelsPrefix() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.decide(eventType: .keyDown, keyCode: 0x17, characters: "5",
                           flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(machine.mode, .normal(prefix: .count(5)))

        let esc = machine.decide(
            eventType: .keyDown,
            keyCode: VimKeyCode.escape,
            characters: nil,
            flags: [],
            timestamp: baseTimestamp + 50_000_000
        )
        XCTAssertEqual(esc.intent, .consume)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testDecideEscInDisabledPassesThrough() {
        var machine = VimStateMachine(settings: defaultSettings())
        let esc = machine.decide(
            eventType: .keyDown,
            keyCode: VimKeyCode.escape,
            characters: nil,
            flags: [],
            timestamp: baseTimestamp
        )
        XCTAssertEqual(esc.intent, .passThrough)
    }

    func testDecideQuestionMarkShowsHelp() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x2C, characters: "?",
                               flags: .maskShift, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .showOverlay(.help))
        XCTAssertEqual(machine.mode, .help)
    }

    func testDecideAnyKeyDuringHelpDismisses() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.decide(eventType: .keyDown, keyCode: 0x2C, characters: "?",
                           flags: .maskShift, timestamp: baseTimestamp)
        XCTAssertEqual(machine.mode, .help)

        let dismiss = machine.decide(
            eventType: .keyDown,
            keyCode: 0x26,
            characters: "j",
            flags: [],
            timestamp: baseTimestamp + 100_000_000
        )
        XCTAssertEqual(dismiss.intent, .dismissOverlay)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testDecideEscDuringHelpDismisses() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.decide(eventType: .keyDown, keyCode: 0x2C, characters: "?",
                           flags: .maskShift, timestamp: baseTimestamp)

        let esc = machine.decide(
            eventType: .keyDown,
            keyCode: VimKeyCode.escape,
            characters: nil,
            flags: [],
            timestamp: baseTimestamp + 100_000_000
        )
        XCTAssertEqual(esc.intent, .dismissOverlay)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    // MARK: - Insert mode + AX focus auto-detect

    func testUpdateFocusEditableEntersInsertWhenAutoDetect() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let decision = machine.updateFocusEditable(true)
        XCTAssertNotNil(decision)
        XCTAssertEqual(decision?.modeDidChange, true)
        XCTAssertEqual(machine.mode, .insert)
    }

    func testUpdateFocusEditableExitsInsertWhenAutoDetect() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.updateFocusEditable(true)
        XCTAssertEqual(machine.mode, .insert)

        let decision = machine.updateFocusEditable(false)
        XCTAssertEqual(decision?.modeDidChange, true)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testUpdateFocusEditableNoOpWhenManual() {
        var settings = VimSettings.v1Default
        settings.insertModeBehavior = .manual
        var machine = VimStateMachine(settings: settings)
        machine.updateSafariFrontmost(true)

        XCTAssertNil(machine.updateFocusEditable(true))
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testUpdateFocusEditableNoOpWhenDisabled() {
        var machine = VimStateMachine(settings: defaultSettings())
        XCTAssertNil(machine.updateFocusEditable(true))
        XCTAssertEqual(machine.mode, .disabled)
    }

    func testInsertModePassesThroughNonEscKeys() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.updateFocusEditable(true)
        XCTAssertEqual(machine.mode, .insert)

        for char in ["j", "k", "h", "g", "G", "?", "/"] {
            let d = machine.decide(
                eventType: .keyDown,
                keyCode: 0x00,
                characters: char,
                flags: [],
                timestamp: baseTimestamp
            )
            XCTAssertEqual(d.intent, .passThrough,
                           "Insert mode must pass '\(char)' through to Safari")
            XCTAssertEqual(machine.mode, .insert,
                           "Insert mode must not change on character keys")
        }
    }

    // MARK: - V-M3 hint-mode entry / forwarding / exit

    func testDecideFEntersHintModeWithAnyClickable() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x03, characters: "f",
                               flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .requestHintTraversal(openInNewTab: false, copyOnly: false, filter: .anyClickable))
        guard case .hint(let state) = machine.mode else {
            return XCTFail("Expected .hint mode, got \(machine.mode)")
        }
        XCTAssertEqual(state.openInNewTab, false)
        XCTAssertEqual(state.filter, .anyClickable)
    }

    func testDecideShiftFEntersHintModeWithNewTab() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x03, characters: "F",
                               flags: .maskShift, timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .requestHintTraversal(openInNewTab: true, copyOnly: false, filter: .anyClickable))
        guard case .hint(let state) = machine.mode else {
            return XCTFail("Expected .hint mode, got \(machine.mode)")
        }
        XCTAssertEqual(state.openInNewTab, true)
    }

    func testDecideGIEntersHintModeForInputs() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.decide(eventType: .keyDown, keyCode: 0x05, characters: "g",
                           flags: [], timestamp: baseTimestamp)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x22, characters: "i",
                               flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .requestHintTraversal(openInNewTab: false, copyOnly: false, filter: .textInputsOnly))
        guard case .hint(let state) = machine.mode else {
            return XCTFail("Expected .hint mode, got \(machine.mode)")
        }
        XCTAssertEqual(state.filter, .textInputsOnly)
    }

    func testDecideGSPostsCmdOptionU() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.decide(eventType: .keyDown, keyCode: 0x05, characters: "g",
                           flags: [], timestamp: baseTimestamp)
        let d = machine.decide(eventType: .keyDown, keyCode: 0x01, characters: "s",
                               flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .postKey(virtualKey: VimKeyCode.u, flags: [.maskCommand, .maskAlternate]))
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testDecideCharacterInHintModeForwardsToCoordinator() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.decide(eventType: .keyDown, keyCode: 0x03, characters: "f",
                           flags: [], timestamp: baseTimestamp)

        let d = machine.decide(eventType: .keyDown, keyCode: 0x01, characters: "s",
                               flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(d.intent, .forwardHintKey("s"))
        guard case .hint = machine.mode else {
            return XCTFail("Hint mode should persist while typing labels")
        }
    }

    func testDecideEscInHintModeDismissesOverlay() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.decide(eventType: .keyDown, keyCode: 0x03, characters: "f",
                           flags: [], timestamp: baseTimestamp)

        let esc = machine.decide(
            eventType: .keyDown,
            keyCode: VimKeyCode.escape,
            characters: nil,
            flags: [],
            timestamp: baseTimestamp + 50_000_000
        )
        XCTAssertEqual(esc.intent, .dismissOverlay)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testExitHintModeReturnsToNormal() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        _ = machine.decide(eventType: .keyDown, keyCode: 0x03, characters: "f",
                           flags: [], timestamp: baseTimestamp)

        let decision = machine.exitHintMode()
        XCTAssertNotNil(decision)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testExitHintModeNoOpWhenAlreadyNormal() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        XCTAssertNil(machine.exitHintMode())
    }

    // MARK: - 0.7.1: insertFirst behavior

    private func insertFirstSettings() -> VimSettings {
        VimSettings(insertModeBehavior: .insertFirst)
    }

    /// In `.insertFirst`, becoming Safari-frontmost should land us in
    /// `.insert` (not `.normal`). This is the whole point — keystrokes
    /// hit the page by default, no `i` ceremony.
    func testInsertFirstStartsInInsertOnSafariFrontmost() {
        var machine = VimStateMachine(settings: insertFirstSettings())
        let d = machine.updateSafariFrontmost(true)
        XCTAssertNotNil(d)
        XCTAssertEqual(machine.mode, .insert)
    }

    /// Esc in `.insert` always returns to `.normal(.none)` regardless
    /// of behavior — this lets the user opt into vim mode on demand.
    func testInsertFirstEscFromInsertEntersNormal() {
        var machine = VimStateMachine(settings: insertFirstSettings())
        machine.updateSafariFrontmost(true)
        XCTAssertEqual(machine.mode, .insert)

        let esc = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.escape,
                                 characters: nil, flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
        XCTAssertEqual(esc.intent, .unfocusActiveElement)
    }

    /// Esc in `.normal(.none)` under `.insertFirst` is the round-trip
    /// back to `.insert`. Critically: the intent is `.consume` so the
    /// Esc keystroke doesn't reach the page (where it would close
    /// random Safari dialogs).
    func testInsertFirstEscFromNormalReturnsToInsert() {
        var machine = VimStateMachine(settings: insertFirstSettings())
        machine.updateSafariFrontmost(true)
        // Esc once: insert -> normal
        _ = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.escape,
                           characters: nil, flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))

        // Esc again: normal -> insert (round trip)
        let esc = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.escape,
                                 characters: nil, flags: [], timestamp: baseTimestamp + 1_000_000_000)
        XCTAssertEqual(machine.mode, .insert)
        XCTAssertEqual(esc.intent, .consume)
    }

    /// Esc in `.normal(.none)` under `.autoDetect` must NOT eat the
    /// keypress (it should pass through to the page) — regression guard
    /// against the insertFirst change leaking into autoDetect users.
    func testAutoDetectEscFromNormalPassesThrough() {
        var machine = VimStateMachine(settings: defaultSettings())
        machine.updateSafariFrontmost(true)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))

        let esc = machine.decide(eventType: .keyDown, keyCode: VimKeyCode.escape,
                                 characters: nil, flags: [], timestamp: baseTimestamp)
        XCTAssertEqual(esc.intent, .passThrough)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    /// `defaultMode` should reflect the setting — verifying the helper
    /// since several other call sites depend on it.
    func testDefaultModeReflectsSetting() {
        let insertFirst = VimStateMachine(settings: insertFirstSettings())
        XCTAssertEqual(insertFirst.defaultMode, .insert)

        let auto = VimStateMachine(settings: defaultSettings())
        XCTAssertEqual(auto.defaultMode, .normal(prefix: .none))
    }

    // MARK: - 0.7.1: mode indicator labels

    /// The pill copy is part of the user's UI; it should not silently
    /// drift between releases. One assertion per state covers the
    /// switch's exhaustiveness too — if a new case is added, this fails
    /// to compile until the helper handles it.
    func testModeIndicatorTextCovers() {
        XCTAssertNil(AppModel.modeIndicatorText(for: .disabled))
        XCTAssertNil(AppModel.modeIndicatorText(for: .insert))
        XCTAssertNil(AppModel.modeIndicatorText(for: .help))
        XCTAssertEqual(AppModel.modeIndicatorText(for: .disabledBySite), "-- OFF (site) --")
        XCTAssertEqual(AppModel.modeIndicatorText(for: .normal(prefix: .none)), "-- NORMAL --")
        XCTAssertEqual(AppModel.modeIndicatorText(for: .normal(prefix: .count(5))), "-- NORMAL -- 5")
        XCTAssertEqual(AppModel.modeIndicatorText(for: .normal(prefix: .g(count: nil))), "-- NORMAL -- g")
        XCTAssertEqual(AppModel.modeIndicatorText(for: .vomnibar(VomnibarState(flavor: .url(openInNewTab: false)))), "-- VOMNIBAR --")
    }
}
