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

    // MARK: - Entry normalization (pasted URLs → host[:port])

    func testNormalizeStripsSchemeAndPath() {
        XCTAssertEqual(SitesStore.normalizeEntry("http://localhost:5174/v4"), "localhost:5174")
        XCTAssertEqual(SitesStore.normalizeEntry("https://www.example.com/foo?x=1"), "example.com")
        XCTAssertEqual(SitesStore.normalizeEntry("  GMAIL.com  "), "gmail.com")
    }

    func testNormalizeBareInputUnchanged() {
        XCTAssertEqual(SitesStore.normalizeEntry("gmail.com"), "gmail.com")
        XCTAssertEqual(SitesStore.normalizeEntry("localhost:5174"), "localhost:5174")
    }

    func testNormalizeRejectsEmptyOrHostless() {
        XCTAssertNil(SitesStore.normalizeEntry(""))
        XCTAssertNil(SitesStore.normalizeEntry("   "))
        XCTAssertNil(SitesStore.normalizeEntry("https://"))
    }

    // MARK: - Matching against pasted-URL and host:port entries (bug #1)

    func testMatchesPastedFullURLEntry() {
        // The exact reported bug: entry was pasted as a full URL.
        let url = URL(string: "http://localhost:5174/v4")!
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["http://localhost:5174/v4"]))
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["localhost:5174"]))
    }

    func testHostPortEntryIsPortSpecific() {
        XCTAssertTrue(SitesStore.isDisabled(
            url: URL(string: "http://localhost:5174/")!, in: ["localhost:5174"]))
        XCTAssertFalse(SitesStore.isDisabled(
            url: URL(string: "http://localhost:3000/")!, in: ["localhost:5174"]))
    }

    func testBareHostEntryMatchesAllPorts() {
        XCTAssertTrue(SitesStore.isDisabled(
            url: URL(string: "http://localhost:5174/")!, in: ["localhost"]))
        XCTAssertTrue(SitesStore.isDisabled(
            url: URL(string: "http://localhost:3000/")!, in: ["localhost"]))
    }

    // MARK: - IPv6 literal hosts (F11)

    func testNormalizeIPv6WithPortBrackets() {
        XCTAssertEqual(SitesStore.normalizeEntry("http://[::1]:5174/v4"), "[::1]:5174")
        XCTAssertEqual(SitesStore.normalizeEntry("[::1]:5174"), "[::1]:5174")
    }

    func testIPv6HostPortMatchesAndIsPortSpecific() {
        let url = URL(string: "http://[::1]:5174/v4")!
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["http://[::1]:5174/v4"]))
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["[::1]:5174"]))
        XCTAssertFalse(SitesStore.isDisabled(
            url: URL(string: "http://[::1]:3000/")!, in: ["[::1]:5174"]))
    }

    func testBareIPv6EntryMatchesAllPorts() {
        XCTAssertEqual(SitesStore.normalizeEntry("[2001:db8::1]"), "[2001:db8::1]")
        XCTAssertTrue(SitesStore.isDisabled(
            url: URL(string: "http://[2001:db8::1]/x")!, in: ["[2001:db8::1]"]))
        XCTAssertTrue(SitesStore.isDisabled(
            url: URL(string: "http://[2001:db8::1]:8080/")!, in: ["[2001:db8::1]"]))
    }

    // MARK: - Internationalized domains (F12)

    func testNormalizeIDNToPunycode() {
        XCTAssertEqual(SitesStore.normalizeEntry("bücher.de"), "xn--bcher-kva.de")
    }

    func testIDNEntryMatchesPunycodeURL() {
        let url = URL(string: "https://xn--bcher-kva.de/x")!
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["bücher.de"]))
        XCTAssertTrue(SitesStore.isDisabled(url: url, in: ["xn--bcher-kva.de"]))
    }

    // MARK: - Trailing-dot FQDN (F13)

    func testTrailingDotHostMatches() {
        // Runtime host carries the trailing dot.
        XCTAssertTrue(SitesStore.isDisabled(
            url: URL(string: "https://gmail.com./inbox")!, in: ["gmail.com"]))
        // Entry carries the trailing dot.
        XCTAssertTrue(SitesStore.isDisabled(
            url: URL(string: "https://gmail.com/")!, in: ["gmail.com."]))
        XCTAssertEqual(SitesStore.normalizeEntry("gmail.com."), "gmail.com")
    }
}

final class VimStateMachineSitesTests: XCTestCase {
    func testDecideDisablesWhenHostMatches() {
        var settings = VimSettings(insertModeBehavior: .autoDetect)
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
        var settings = VimSettings(insertModeBehavior: .autoDetect)
        settings.disabledHosts = ["gmail.com"]
        var machine = VimStateMachine(settings: settings)
        machine.updateSafariFrontmost(true)
        machine.updateCurrentURL(URL(string: "https://gmail.com/inbox"))
        XCTAssertEqual(machine.mode, .disabledBySite)

        machine.updateCurrentURL(URL(string: "https://github.com/"))
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testAddingHostWhileOnPageDisables() {
        var settings = VimSettings(insertModeBehavior: .autoDetect)
        var machine = VimStateMachine(settings: settings)
        machine.updateSafariFrontmost(true)
        machine.updateCurrentURL(URL(string: "https://gmail.com/inbox"))
        XCTAssertEqual(machine.mode, .normal(prefix: .none))

        settings.disabledHosts = ["gmail.com"]
        machine.settings = settings
        XCTAssertEqual(machine.mode, .disabledBySite)
    }

    func testEscChordSuspendsCurrentURL() {
        var machine = VimStateMachine(settings: VimSettings(insertModeBehavior: .autoDetect))
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
        var machine = VimStateMachine(settings: VimSettings(insertModeBehavior: .autoDetect))
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
        var machine = VimStateMachine(settings: VimSettings(insertModeBehavior: .autoDetect))
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
        var machine = VimStateMachine(settings: VimSettings(insertModeBehavior: .autoDetect))
        machine.updateSafariFrontmost(true)
        let url = URL(string: "https://github.com/foo")!
        machine.updateCurrentURL(url)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))

        machine.toggleSuspendOnCurrentURL()
        XCTAssertEqual(machine.mode, .disabledBySite)
        XCTAssertEqual(machine.sessionSuspendedURL, url)
    }

    func testNavigatingAwayClearsSessionSuspend() {
        var machine = VimStateMachine(settings: VimSettings(insertModeBehavior: .autoDetect))
        machine.updateSafariFrontmost(true)
        let url = URL(string: "https://github.com/foo")!
        machine.updateCurrentURL(url)
        machine.toggleSuspendOnCurrentURL()
        XCTAssertEqual(machine.mode, .disabledBySite)

        machine.updateCurrentURL(URL(string: "https://news.ycombinator.com"))
        XCTAssertNil(machine.sessionSuspendedURL)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))
    }

    func testBackgroundingSafariDismissesOpenVomnibar() {
        var machine = VimStateMachine(settings: VimSettings(insertModeBehavior: .autoDetect))
        machine.updateSafariFrontmost(true)
        let open = machine.decide(eventType: .keyDown, keyCode: 0, characters: "T",
                                  flags: [], timestamp: 0)
        XCTAssertEqual(open.intent, .requestVomnibar(.tabs))
        XCTAssertEqual(machine.mode, .vomnibar(VomnibarState(flavor: .tabs)))

        // Safari goes background while the vomnibar is open: the overlay
        // must be dismissed, not orphaned (the tap stops intercepting, so
        // the user could never Esc it away otherwise).
        let bg = machine.updateSafariFrontmost(false)
        XCTAssertEqual(bg?.intent, .dismissOverlay)
        XCTAssertEqual(machine.mode, .disabled)
    }

    func testBackgroundingSafariInNormalModeJustDisables() {
        var machine = VimStateMachine(settings: VimSettings(insertModeBehavior: .autoDetect))
        machine.updateSafariFrontmost(true)
        XCTAssertEqual(machine.mode, .normal(prefix: .none))

        // No overlay open — backgrounding is a plain pass-through disable,
        // not a dismiss.
        let bg = machine.updateSafariFrontmost(false)
        XCTAssertEqual(bg?.intent, .passThrough)
        XCTAssertEqual(machine.mode, .disabled)
    }

    func testReToggleSuspendOnSameURLUnsuspends() {
        var machine = VimStateMachine(settings: VimSettings(insertModeBehavior: .autoDetect))
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
