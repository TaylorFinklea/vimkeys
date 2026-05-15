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
}
