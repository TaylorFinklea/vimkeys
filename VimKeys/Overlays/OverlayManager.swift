import AppKit
import Foundation

/// V-M2 owns one overlay (help). V-M3 / V-M4 expand this to manage hint
/// and vomnibar windows alongside it.
@MainActor
final class OverlayManager {
    private var helpWindow: HelpOverlayWindow?

    func showHelp() {
        if helpWindow == nil {
            helpWindow = HelpOverlayWindow()
        }
        helpWindow?.presentCentered()
    }

    func dismiss() {
        helpWindow?.orderOut(nil)
    }
}
