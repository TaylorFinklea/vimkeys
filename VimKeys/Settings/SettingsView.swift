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

            aboutView
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 380)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Bindings")
                .font(.title2.weight(.semibold))

            Text("Coming in v0.5")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("A read-only reference card for VimKeys' bindings will land alongside the link-hint and vomnibar features. Custom bindings are out of scope at v1.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var sitesPlaceholderView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sites")
                .font(.title2.weight(.semibold))

            Text("Coming in v0.5")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Per-domain disable rules let you silence VimKeys on sites that already have rich keyboard navigation (Gmail, Notion, etc.). Lands in V-M5.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }

    private var aboutView: some View {
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
