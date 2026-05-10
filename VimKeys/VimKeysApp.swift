import Sparkle
import SwiftUI

@main
struct VimKeysApp: App {
    @StateObject private var model: AppModel
    private let updaterController: SPUStandardUpdaterController
    private let updaterObserver: SparkleUpdateObserver

    init() {
        // Construct in init() rather than as default values so Swift 6.x
        // doesn't crash in `silgen emitStoredPropertyInitialization` when
        // @StateObject's wrappedValue autoclosure tries to call the
        // @MainActor-isolated AppModel.init.
        let model = AppModel()
        let observer = SparkleUpdateObserver(model: model)
        _model = StateObject(wrappedValue: model)
        self.updaterObserver = observer
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: observer,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model, updater: updaterController.updater)
        } label: {
            MenuBarIconView(
                variant: model.menuBarVariant.variant,
                updateBadge: model.menuBarVariant.badge
            )
            .frame(width: 18, height: 18)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @StateObject private var checker: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _checker = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates\u{2026}") {
            updater.checkForUpdates()
        }
        .disabled(!checker.canCheckForUpdates)
    }
}

final class SparkleUpdateObserver: NSObject, SPUUpdaterDelegate {
    private let setAvailable: @MainActor (Bool) -> Void

    init(setAvailable: @escaping @MainActor (Bool) -> Void) {
        self.setAvailable = setAvailable
        super.init()
    }

    convenience init(model: AppModel) {
        self.init { available in
            model.setUpdateAvailable(available)
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in setAvailable(true) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in setAvailable(false) }
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        Task { @MainActor in setAvailable(false) }
    }

    #if DEBUG
    /// Test hooks. The Sparkle delegate methods each forward to one of these
    /// two paths; we expose them so unit tests don't have to construct an
    /// `SUAppcastItem` (whose public init in Sparkle 2.x requires a complex
    /// info-dictionary). Synchronous (no Task hop) so tests don't have to
    /// yield. Production code never calls these.
    @MainActor func applyTrueForTesting()  { setAvailable(true) }
    @MainActor func applyFalseForTesting() { setAvailable(false) }
    #endif
}
