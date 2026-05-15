import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            generalView
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            bindingsPlaceholderView
                .tabItem {
                    Label("Bindings", systemImage: "keyboard")
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

        return VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2.weight(.semibold))

            Text("VimKeys needs Input Monitoring to read vim-style keys while Safari is frontmost. Accessibility is required to post scroll events, switch into insert mode on text inputs, and read link targets for hint mode (V-M3).")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
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
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Label(
                title,
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(granted ? .green : .orange)

            Spacer()

            if !granted {
                Button("Enable \(title)") {
                    action()
                }
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

                Section("Insert mode") {
                    Picker(
                        "Switch into insert mode",
                        selection: Binding(
                            get: { model.settings.insertModeBehavior },
                            set: { model.setInsertModeBehavior($0) }
                        )
                    ) {
                        ForEach(InsertModeBehavior.allCases) { behavior in
                            Text(behavior.title).tag(behavior)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Auto-detect uses Accessibility to flip into insert mode whenever Safari focuses a text input, and back to normal mode when focus leaves. Manual mode ignores focus changes \u{2014} press i to enter insert mode and Esc to leave it.")
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

    private var bindingsPlaceholderView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bindings")
                .font(.title2.weight(.semibold))

            Form {
                Section("Link hints") {
                    TextField(
                        "Hint alphabet",
                        text: Binding(
                            get: { model.settings.hintAlphabet },
                            set: { model.setHintAlphabet($0) }
                        )
                    )

                    Text("Characters used to label clickable elements in hint mode (\u{0060}f\u{0060} / \u{0060}F\u{0060}). Vimium's default home-row alphabet is \u{0060}sadfjkl;ehiwopvbnm\u{0060}. Stick to lowercase letters; the matcher is case-insensitive.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Reset to default") {
                        model.setHintAlphabet(LinkHintEngine.defaultAlphabet)
                    }
                }

                Section("Reference") {
                    bindingRow("j / k / h / l", "Scroll down / up / left / right")
                    bindingRow("d / u", "Half-page down / up")
                    bindingRow("gg / G", "Top / bottom of page")
                    bindingRow("f / F", "Click hint / open in new tab")
                    bindingRow("gi", "Focus first text input")
                    bindingRow("gs", "View source (Cmd+Opt+U)")
                    bindingRow("/ n N", "Find / next / previous")
                    bindingRow("H L", "History back / forward")
                    bindingRow("r R", "Reload / hard reload")
                    bindingRow("i Esc", "Insert mode / leave insert mode")
                    bindingRow("?", "Toggle help overlay")
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
    }

    @ViewBuilder
    private func bindingRow(_ chord: String, _ command: String) -> some View {
        HStack(spacing: 12) {
            Text(chord)
                .font(.system(.body, design: .monospaced))
                .frame(width: 110, alignment: .leading)
            Text(command)
                .foregroundStyle(.secondary)
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
/// current site" button (uses `AppModel.disableCurrentHost()` which reads
/// the polled Safari URL).
private struct SitesView: View {
    @ObservedObject var model: AppModel
    @State private var newEntry: String = ""
    @FocusState private var newEntryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sites")
                .font(.title2.weight(.semibold))

            Text("VimKeys passes every keystroke straight through to Safari when the page's host matches one of these entries. Suffix-matched, case-insensitive (\u{0060}gmail.com\u{0060} also covers \u{0060}mail.gmail.com\u{0060}).")
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
