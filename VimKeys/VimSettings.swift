import Foundation

/// Tunable knobs for `VimStateMachine` and the engine. V-M1 ships with a
/// single binding table; later milestones add the hint alphabet, insert-mode
/// auto-detect toggle, etc.
struct VimSettings: Equatable {
    var bindings: VimBindings

    init(bindings: VimBindings = .v1Default) {
        self.bindings = bindings
    }

    static let v1Default = VimSettings()
}
