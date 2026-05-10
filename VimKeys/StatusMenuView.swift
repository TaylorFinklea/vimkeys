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

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    model.permissionState.title,
                    systemImage: model.permissionState.isGranted
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(model.permissionState.isGranted ? .green : .orange)

                Text(model.permissionState.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !model.permissionState.isGranted {
                    Button("Enable Keyboard Permissions") {
                        model.requestPermission()
                    }
                }
            }

            if let lastError = model.lastError {
                Divider()
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Divider()

            Button("Settings\u{2026}") {
                openSettings()
            }

            Button("Refresh Permissions") {
                model.refreshPermissionState()
                model.restartEventTap()
            }

            CheckForUpdatesView(updater: updater)

            Button("Quit VimKeys") {
                model.quit()
            }
        }
        .padding()
        .frame(width: 320)
    }
}
