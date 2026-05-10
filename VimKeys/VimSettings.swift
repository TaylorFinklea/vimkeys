import Foundation

/// User-tunable behavior of the state machine.
struct VimSettings: Equatable {
    var bindings: VimBindings
    var insertModeBehavior: InsertModeBehavior

    init(
        bindings: VimBindings = .v1Default,
        insertModeBehavior: InsertModeBehavior = .autoDetect
    ) {
        self.bindings = bindings
        self.insertModeBehavior = insertModeBehavior
    }

    static let v1Default = VimSettings()
}

/// Whether the state machine auto-flips into `.insert` when Safari's
/// focused element becomes editable, or only enters insert mode when the
/// user presses `i`.
enum InsertModeBehavior: String, Codable, Equatable, CaseIterable, Identifiable {
    case autoDetect
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoDetect: return "Auto-detect via Accessibility"
        case .manual:     return "Manual only (i to enter)"
        }
    }
}
