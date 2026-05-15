import XCTest
@testable import VimKeys

final class SitesStoreTests: XCTestCase {
    func testIsDisabledExactHost() {
        let url = URL(string: "https://gmail.com/inbox")!
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["gmail.com"]))
    }

    func testIsDisabledSubdomain() {
        let url = URL(string: "https://mail.gmail.com/inbox")!
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["gmail.com"]))
    }

    func testIsDisabledStripsWWW() {
        let url = URL(string: "https://www.example.com/")!
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["example.com"]))
    }

    func testIsDisabledCaseInsensitive() {
        let url = URL(string: "https://NEWS.ycombinator.com/")!
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["ycombinator.com"]))
    }

    func testIsDisabledNoMatch() {
        let url = URL(string: "https://github.com/")!
        XCTAssertFalse(SitesStore.isDisabled(url: url, in: ["gmail.com", "example.com"]))
    }

    func testIsDisabledEmptyList() {
        let url = URL(string: "https://anywhere.com/")!
        XCTAssertFalse(SitesStore.isDisabled(url: url, in: []))
    }

    func testIsDisabledNoHost() {
        let url = URL(string: "file:///tmp")!
        XCTAssertFalse(SitesStore.isDisabled(url: url, in: ["tmp"]))
    }

    func testDoesNotMatchUnrelatedSuffix() {
        // "notgmail.com" must NOT match "gmail.com".
        let url = URL(string: "https://notgmail.com/")!
        XCTAssertFalse(SitesStore.isDisabled(url: url, in: ["gmail.com"]))
    }
}

final class VimStateMachineSitesTests: XCTestCase {
    func testDecideDisablesWhenHostMatches() {
        var settings = VimSettings.v1Default
        settings.disabledHosts = ["gmail.com"]
        var machine = VimStateMachine(settings: settings)
        machine.updateSafariFrontmost(true)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))

        machine.updateCurrentURL(URL(string: "https://gmail.com/inbox"))
        XCTAssertEqual(machine.mode, .disabledBySite)

        let d = machine.decide(eventType: .keyDown, keyCode: 0x26, characters: "j",
                               flags: [], timestamp: 0)
        XCTAssertEqual(d.intent, .passThrough)
    }

    func testNavigatingOffDisabledHostReturnsToNormal() {
        var settings = VimSettings.v1Default
        settings.disabledHosts = ["gmail.com"]
        var machine = VimStateMachine(settings: settings)
        machine.updateSafariFrontmost(true)
        machine.updateCurrentURL(URL(string: "https://gmail.com/inbox"))
        XCTAssertEqual(machine.mode, .disabledBySite)

        machine.updateCurrentURL(URL(string: "https://github.com/"))
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testAddingHostWhileOnPageDisables() {
        var settings = VimSettings.v1Default
        var machine = VimStateMachine(settings: settings)
        machine.updateSafariFrontmost(true)
        machine.updateCurrentURL(URL(string: "https://gmail.com/inbox"))
        XCTAssertEqual(machine.mode, .normal(prefix: .none))

        settings.disabledHosts = ["gmail.com"]
        machine.settings = settings
        XCTAssertEqual(machine.mode, .disabledBySite)
    }

    func testEscChordSuspendsCurrentURL() {
        var machine = VimStateMachine(settings: .v1Default)
        machine.updateSafariFrontmost(true)
        machine.updateCurrentURL(URL(string: "https://github.com/foo"))

        // First Esc just records; mode stays normal.
        let first = machine.decide(
            eventType: .keyDown, keyCode: VimKeyCode.escape, characters: nil,
            flags: [], timestamp: 1_000_000_000
        )
        XCTAssertEqual(first.intent, .passThrough)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))

        // Second Esc within window → chord fires.
        let second = machine.decide(
            eventType: .keyDown, keyCode: VimKeyCode.escape, characters: nil,
            flags: [], timestamp: 1_100_000_000
        )
        XCTAssertEqual(second.intent, .toggleSuspended)
    }

    func testEscChordOutsideWindowDoesNotFire() {
        var machine = VimStateMachine(settings: .v1Default)
        machine.updateSafariFrontmost(true)
        machine.updateCurrentURL(URL(string: "https://github.com/foo"))

        _ = machine.decide(
            eventType: .keyDown, keyCode: VimKeyCode.escape, characters: nil,
            flags: [], timestamp: 1_000_000_000
        )
        // 500 ms later — outside the 350 ms window.
        let second = machine.decide(
            eventType: .keyDown, keyCode: VimKeyCode.escape, characters: nil,
            flags: [], timestamp: 1_500_000_000
        )
        XCTAssertNotEqual(second.intent, .toggleSuspended)
    }

    func testNonEscBetweenResetsChord() {
        var machine = VimStateMachine(settings: .v1Default)
        machine.updateSafariFrontmost(true)
        machine.updateCurrentURL(URL(string: "https://github.com/foo"))

        _ = machine.decide(
            eventType: .keyDown, keyCode: VimKeyCode.escape, characters: nil,
            flags: [], timestamp: 1_000_000_000
        )
        _ = machine.decide(
            eventType: .keyDown, keyCode: 0x26, characters: "j",
            flags: [], timestamp: 1_050_000_000
        )
        // Esc now should NOT fire chord even within timing window of first.
        let third = machine.decide(
            eventType: .keyDown, keyCode: VimKeyCode.escape, characters: nil,
            flags: [], timestamp: 1_100_000_000
        )
        XCTAssertNotEqual(third.intent, .toggleSuspended)
    }

    func testToggleSuspendEntersDisabledBySite() {
        var machine = VimStateMachine(settings: .v1Default)
        machine.updateSafariFrontmost(true)
        let url = URL(string: "https://github.com/foo")!
        machine.updateCurrentURL(url)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))

        machine.toggleSuspendOnCurrentURL()
        XCTAssertEqual(machine.mode, .disabledBySite)
        XCTAssertEqual(machine.sessionSuspendedURL, url)
    }

    func testNavigatingAwayClearsSessionSuspend() {
        var machine = VimStateMachine(settings: .v1Default)
        machine.updateSafariFrontmost(true)
        let url = URL(string: "https://github.com/foo")!
        machine.updateCurrentURL(url)
        machine.toggleSuspendOnCurrentURL()
        XCTAssertEqual(machine.mode, .disabledBySite)

        machine.updateCurrentURL(URL(string: "https://news.ycombinator.com"))
        XCTAssertNil(machine.sessionSuspendedURL)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testReToggleSuspendOnSameURLUnsuspends() {
        var machine = VimStateMachine(settings: .v1Default)
        machine.updateSafariFrontmost(true)
        let url = URL(string: "https://github.com/foo")!
        machine.updateCurrentURL(url)
        machine.toggleSuspendOnCurrentURL()
        XCTAssertEqual(machine.mode, .disabledBySite)

        machine.toggleSuspendOnCurrentURL()
        XCTAssertNil(machine.sessionSuspendedURL)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }
}
