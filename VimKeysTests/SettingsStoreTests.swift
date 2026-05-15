import XCTest
@testable import VimKeys

@MainActor
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        // Skipping `super.setUp()` on purpose: under Swift 6 strict mode
        // the `super` reference is non-Sendable, so awaiting through it
        // is a data-race risk. XCTestCase's base setUp is a no-op, so
        // skipping is safe.
        suiteName = "VimKeysTests.SettingsStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testLoadReturnsDefaultsWhenNothingPersisted() {
        let store = SettingsStore(defaults: defaults)
        let settings = store.load()
        XCTAssertEqual(settings.insertModeBehavior, .autoDetect)
    }

    func testRoundTripsInsertModeBehavior() {
        let store = SettingsStore(defaults: defaults)
        var settings = VimSettings.v1Default
        settings.insertModeBehavior = .manual
        store.save(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded.insertModeBehavior, .manual)
    }

    func testResetClearsPersistedValue() {
        let store = SettingsStore(defaults: defaults)
        var settings = VimSettings.v1Default
        settings.insertModeBehavior = .manual
        store.save(settings)
        XCTAssertEqual(store.load().insertModeBehavior, .manual)

        store.reset()
        XCTAssertEqual(store.load().insertModeBehavior, .autoDetect)
    }

    func testIgnoresUnrecognizedRawValue() {
        defaults.set("garbage", forKey: "settings.insertModeBehavior")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.load().insertModeBehavior, .autoDetect)
    }
}
