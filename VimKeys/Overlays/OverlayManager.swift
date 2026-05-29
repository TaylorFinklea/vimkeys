import AppKit
import Foundation

/// V-M2 owns one overlay (help). V-M3 / V-M4 expand this to manage hint
/// and vomnibar windows alongside it. 0.7.1 adds the persistent mode
/// indicator pill.
@MainActor
final class OverlayManager {
    private var helpWindow: HelpOverlayWindow?
    private var modeIndicator: ModeIndicatorWindow?

    func showHelp(bindings: VimBindings) {
        if helpWindow == nil {
            helpWindow = HelpOverlayWindow()
        }
        helpWindow?.presentCentered(bindings: bindings)
    }

    func dismiss() {
        helpWindow?.orderOut(nil)
    }

    /// Pass `nil` (or empty string) to hide; any non-empty label shows
    /// the indicator. Idempotent — safe to call on every mode tick.
    func updateModeIndicator(text: String?) {
        if modeIndicator == nil {
            modeIndicator = ModeIndicatorWindow()
        }
        modeIndicator?.update(text: text)
    }
}
