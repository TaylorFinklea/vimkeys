import Foundation

/// UserDefaults-backed persistence for the user's key bindings, mirroring
/// `SitesStore`. Stored as a schema-versioned JSON blob under
/// `settings.bindings` so a future binding-set change can migrate rather
/// than silently reset. Until the user customizes anything, nothing is
/// written and `load()` returns `VimBindings.v1Default`.
@MainActor
struct BindingsStore {
    static let shared = BindingsStore()

    private let defaults: UserDefaults
    private static let key = "settings.bindings"
    /// Bump when the default binding set changes shape in a way that needs a
    /// migration. `load()` already restores newly-added commands via
    /// `filledWithDefaults`, so a plain command addition doesn't need a bump.
    private static let schemaVersion = 1

    private struct Persisted: Codable {
        var version: Int
        var bindings: VimBindings
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> VimBindings {
        guard let data = defaults.data(forKey: Self.key),
              let persisted = try? JSONDecoder().decode(Persisted.self, from: data)
        else {
            return .v1Default
        }
        // Restore any command added in a newer build that this blob predates.
        return persisted.bindings.filledWithDefaults()
    }

    func save(_ bindings: VimBindings) {
        let persisted = Persisted(version: Self.schemaVersion, bindings: bindings)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
