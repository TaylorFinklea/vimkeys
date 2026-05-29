import XCTest
@testable import VimKeys

@MainActor
final class BindingsStoreTests: XCTestCase {
    private let suiteName = "io.taylorfinklea.vimkeys.tests.bindings"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLoadsDefaultWhenEmpty() {
        XCTAssertEqual(BindingsStore(defaults: defaults).load(), .v1Default)
    }

    func testRoundTripsCustomBinding() {
        let store = BindingsStore(defaults: defaults)
        let custom = VimBindings.v1Default.rebinding(.scrollDown, to: .single("z"))
        store.save(custom)
        XCTAssertEqual(store.load(), custom)
        XCTAssertEqual(store.load().command(for: .single("z")), .scrollDown)
    }

    func testLoadsDefaultOnCorruptedData() {
        defaults.set(Data("not json".utf8), forKey: "settings.bindings")
        XCTAssertEqual(BindingsStore(defaults: defaults).load(), .v1Default)
    }

    func testResetClearsToDefault() {
        let store = BindingsStore(defaults: defaults)
        store.save(VimBindings.v1Default.rebinding(.scrollUp, to: .single("w")))
        store.reset()
        XCTAssertEqual(store.load(), .v1Default)
    }

    func testLoadFillsCommandMissingFromPersistedBlob() {
        // Simulate an older blob that predates a command by persisting a
        // table with one command dropped; load() must restore it.
        var incomplete = VimBindings.v1Default
        incomplete.singleChar.removeValue(forKey: "j") // scrollDown
        BindingsStore(defaults: defaults).save(incomplete)

        let loaded = BindingsStore(defaults: defaults).load()
        XCTAssertTrue(loaded.unboundCommands.isEmpty)
        XCTAssertEqual(loaded.command(for: .single("j")), .scrollDown)
    }
}
