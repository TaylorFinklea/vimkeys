import Foundation

/// Minimal UserDefaults-backed persistence for user-facing settings. V-M2
/// only stores `insertModeBehavior`; later milestones (V-M3 hint alphabet,
/// V-M5 launch/update toggles surfaced under the same store) extend this
/// surface. Keys are namespaced under `settings.` so the eventual
/// `SitesStore` (V-M5) can coexist without prefix collisions.
@MainActor
struct SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    private enum Key {
        static let insertModeBehavior = "settings.insertModeBehavior"
        static let hintAlphabet = "settings.hintAlphabet"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> VimSettings {
        var settings = VimSettings.v1Default
        if let raw = defaults.string(forKey: Key.insertModeBehavior),
           let behavior = InsertModeBehavior(rawValue: raw) {
            settings.insertModeBehavior = behavior
        }
        if let alphabet = defaults.string(forKey: Key.hintAlphabet),
           !alphabet.isEmpty {
            settings.hintAlphabet = alphabet
        }
        return settings
    }

    func save(_ settings: VimSettings) {
        defaults.set(settings.insertModeBehavior.rawValue, forKey: Key.insertModeBehavior)
        defaults.set(settings.hintAlphabet, forKey: Key.hintAlphabet)
    }

    func reset() {
        defaults.removeObject(forKey: Key.insertModeBehavior)
        defaults.removeObject(forKey: Key.hintAlphabet)
    }
}
