import Sparkle
import SwiftUI

struct StatusMenuView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VimKeys")
                    .font(.headline)
                Text("\u{2014} \(model.mode.menuTitle)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if !model.allPermissionsGranted {
                permissionsSection

                Divider()
            }

            if let lastError = model.lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)

                Divider()
            }

            Button("Settings\u{2026}") {
                // LSUIElement: true makes VimKeys a background process,
                // which means SwiftUI's openSettings() creates the window
                // but doesn't bring our process to the front. Activate
                // explicitly so the Settings window comes forward.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }

            Button("Open Bookmarks Folder") {
                model.openBookmarksFolder()
            }

            CheckForUpdatesView(updater: updater)

            Button("Quit VimKeys") {
                model.quit()
            }
        }
        .padding()
        .frame(width: 320)
    }

    /// Per-permission status + enable buttons. macOS treats Input
    /// Monitoring and Accessibility as separate TCC permissions with
    /// separate prompts; surfacing them as one combined "Keyboard
    /// Permissions" row obscured which one needed attention. Also
    /// shows a Restart button whenever something is missing — the
    /// kernel-cached event tap won't pick up newly-granted permissions
    /// without a fresh process.
    @ViewBuilder
    private var permissionsSection: some View {
        let inputGranted = model.permissionState != .denied
        let accessibilityGranted = model.accessibilityGranted
        let allGranted = inputGranted && accessibilityGranted

        VStack(alignment: .leading, spacing: 10) {
            permissionRow(
                title: "Input Monitoring",
                granted: inputGranted,
                deniedDetail: "Listen for vim-style keys while Safari is frontmost.",
                action: { model.requestInputMonitoring() }
            )

            permissionRow(
                title: "Accessibility",
                granted: accessibilityGranted,
                deniedDetail: "Post scroll events, switch into insert mode on text inputs, and read link targets for hint mode.",
                action: { model.requestAccessibility() }
            )

            if !allGranted {
                Text("After granting access, restart VimKeys so the global event tap picks up the new permissions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Restart VimKeys") {
                    model.relaunch()
                }
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        deniedDetail: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                title,
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(granted ? .green : .orange)

            if !granted {
                Text(deniedDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Enable \(title)") {
                    action()
                }
            }
        }
    }
}
