import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            generalView
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            KeysView(model: model)
                .tabItem {
                    Label("Keys", systemImage: "keyboard")
                }

            sitesPlaceholderView
                .tabItem {
                    Label("Sites", systemImage: "globe")
                }

            permissionsView
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }

            aboutView
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 380)
    }

    private var permissionsView: some View {
        let inputGranted = model.permissionState != .denied
        let accessibilityGranted = model.accessibilityGranted
        let fullDiskGranted = model.fullDiskAccessGranted
        let automationGranted = model.automationAccessGranted

        return VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.weight(.semibold))

            Text("VimKeys needs Input Monitoring to read vim-style keys while Safari is frontmost. Accessibility is required to post scroll events, switch into insert mode on text inputs, and read link targets for hint mode. Automation and Full Disk Access are optional \u{2014} Automation lets VimKeys read Safari\u{2019}s URL (per-site disabling, yy, o/O, T) and Full Disk Access lets it read Safari\u{2019}s bookmarks directly.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                permissionRow(
                    title: "Input Monitoring",
                    granted: inputGranted,
                    action: { model.requestInputMonitoring() }
                )

                permissionRow(
                    title: "Accessibility",
                    granted: accessibilityGranted,
                    action: { model.requestAccessibility() }
                )

                permissionRow(
                    title: "Automation (Safari)",
                    granted: automationGranted,
                    optional: true,
                    detail: "Optional. Lets VimKeys read Safari\u{2019}s current URL (per-site disabling + Esc-Esc suspend), copy the page link (\u{0060}yy\u{0060}), open URLs (\u{0060}o\u{0060} / \u{0060}O\u{0060} / \u{0060}p\u{0060} / \u{0060}P\u{0060}), and switch tabs (\u{0060}T\u{0060}). Click to grant, or enable VimKeys under Safari in System Settings \u{2192} Privacy & Security \u{2192} Automation.",
                    buttonLabel: "Grant Automation Access\u{2026}",
                    action: { model.requestAutomationAccess() }
                )

                permissionRow(
                    title: "Full Disk Access",
                    granted: fullDiskGranted,
                    optional: true,
                    detail: "Optional. Lets the bookmarks vomnibar (\u{0060}b\u{0060} / \u{0060}B\u{0060}) read Safari\u{2019}s bookmarks live. Without it, export bookmarks from Safari manually. Relaunch VimKeys after granting.",
                    buttonLabel: "Open Full Disk Access\u{2026}",
                    action: { model.openFullDiskAccessSettings() }
                )
            }

            if !(inputGranted && accessibilityGranted) {
                Text("After granting access in System Settings, restart VimKeys so the global event tap picks up the new permissions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Restart VimKeys") {
                    model.relaunch()
                }
            }

            if let lastError = model.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        // Re-probe FDA each time the tab is shown so a grant made in
        // System Settings is reflected without waiting for a relaunch.
        .onAppear { model.refreshPermissionState() }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        optional: Bool = false,
        detail: String? = nil,
        buttonLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Label(
                    title,
                    systemImage: granted
                        ? "checkmark.circle.fill"
                        : (optional ? "minus.circle" : "exclamationmark.triangle.fill")
                )
                .foregroundStyle(granted ? .green : (optional ? .secondary : .orange))

                Spacer()

                if !granted {
                    Button(buttonLabel ?? "Enable \(title)") {
                        action()
                    }
                }
            }

            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generalView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("General")
                .font(.title2.weight(.semibold))

            Form {
                Section("Startup") {
                    Toggle(
                        "Start VimKeys at login",
                        isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )

                    Text("VimKeys will register itself as a login item via macOS Service Management. You can also remove it from System Settings \u{2192} General \u{2192} Login Items.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Mode default") {
                    Picker(
                        "When Safari is frontmost",
                        selection: Binding(
                            get: { model.settings.insertModeBehavior },
                            set: { model.setInsertModeBehavior($0) }
                        )
                    ) {
                        ForEach(InsertModeBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(model.settings.insertModeBehavior.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Updates") {
                    Text("Automatic updates are disabled in this pre-release build. Use the menu-bar Check for Updates\u{2026} button to check manually.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
    }

    private var sitesPlaceholderView: some View {
        SitesView(model: model)
    }

    private var aboutView: some View {
        aboutViewContent
    }

    private var aboutViewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "keyboard")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("VimKeys")
                        .font(.title.weight(.semibold))

                    Text("Vim-style home-row navigation in Safari.")
                        .foregroundStyle(.secondary)

                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                       let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                        Text("Version \(version) (\(build))")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Link("GitHub", destination: URL(string: "https://github.com/TaylorFinklea/vimkeys")!)
                Link("MIT License", destination: URL(string: "https://github.com/TaylorFinklea/vimkeys/blob/main/LICENSE")!)
            }
            .font(.footnote)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Acknowledgements")
                    .font(.footnote.weight(.semibold))
                Text("Inspired by Vimium (Chrome) and Vifari (Hammerspoon Spoon for Safari).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

/// Sites tab. Editable list of disabled hosts plus a one-click "disable
/// current site" button (uses `AppModel.disableCurrentHost()`, which
/// live-queries Safari's frontmost URL via Apple Events).
private struct SitesView: View {
    @ObservedObject var model: AppModel
    @State private var newEntry: String = ""
    @FocusState private var newEntryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sites")
                .font(.title2.weight(.semibold))

            Text("VimKeys passes every keystroke straight through to Safari on these sites. Enter a domain (\u{0060}gmail.com\u{0060} also covers \u{0060}mail.gmail.com\u{0060}) or a \u{0060}host:port\u{0060} (\u{0060}localhost:5174\u{0060}) to scope a single dev server. You can paste a full URL \u{2014} it\u{2019}s reduced to the host automatically. Case-insensitive; path is ignored.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                TextField("example.com", text: $newEntry)
                    .focused($newEntryFocused)
                    .onSubmit(addEntry)
                Button("Add") { addEntry() }
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Disable current site") {
                    model.disableCurrentHost()
                }
            }

            List {
                ForEach(Array(model.settings.disabledHosts.enumerated()), id: \.offset) { index, host in
                    HStack {
                        Text(host)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            model.removeDisabledHost(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 160)

            Spacer()
        }
    }

    private func addEntry() {
        let trimmed = newEntry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.addDisabledHost(trimmed)
        newEntry = ""
        newEntryFocused = true
    }
}
