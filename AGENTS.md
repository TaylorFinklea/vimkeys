# Repository Agent Instructions

Project-specific guidance for any AI coding agent (Claude Code, Codex, Copilot, Opencode, etc.) working in this repository. Shared agent behavior lives in `~/AGENTS.md`.

## Build, test, and release commands

```bash
# Regenerate the .xcodeproj from project.yml after changing it
xcodegen generate

# Run the XCTest suite
xcodebuild test -scheme VimKeys -project VimKeys.xcodeproj -destination 'platform=macOS'

# Run a single test
xcodebuild test -scheme VimKeys -project VimKeys.xcodeproj -destination 'platform=macOS' \
  -only-testing:VimKeysTests/VimStateMachineTests/testDecideJScrollsDown

# Release build
xcodebuild build -scheme VimKeys -project VimKeys.xcodeproj -configuration Release -destination 'platform=macOS'
```

Release packaging (`scripts/package_release.sh`, Homebrew tap update, `release.yml`) lands in V-M6 and is intentionally absent at V-M1.

## Architecture

VimKeys is a `LSUIElement` SwiftUI menu-bar app that installs a `CGEventTap` to give Safari vim-style home-row navigation. There is no kernel extension or external daemon — all interception happens in-process via Quartz Event Services. The tap only acts when Safari (or Safari Technology Preview) is frontmost; otherwise every key passes through untouched.

Control flow, in layers:

1. **UI (`VimKeysApp`, `StatusMenuView`, `SettingsView`)** — `MenuBarExtra` renders the current `VimMode` (Off / Normal) and a permission warning. `Settings` scene hosts General + (placeholder) Bindings + Sites + About tabs.
2. **`AppModel` (`@MainActor`)** — owns the current `VimMode`, permission state, `EventTapService`, `SafariObserver`, and `LaunchAtLoginController`. `SafariObserver` callbacks flow into `AppModel.safariFrontmostChanged(_:)` which forwards to `EventTapService.updateSafariFrontmost(_:)`.
3. **`EventTapService` + private `EventTapEngine`** — `EventTapEngine` spins up a dedicated `Thread` (`VimKeys.EventTap`) with its own `CFRunLoop` that owns the `CGEvent.tapCreate` handle. The tap callback must not block the main thread; tearing down requires `perform(on: thread)` to stop the run loop cleanly. `onModeChange` / `onTapError` hop back to `@MainActor` via `Task`.
4. **`VimStateMachine`** — pure value type (no Quartz types beyond `CGEventFlags` / `CGKeyCode` / `CGEventType`) that maps `(eventType, keyCode, characters, flags, timestamp) -> VimDecision`. All mode transitions and prefix logic (digit counts, `g`-prefix for `gg`) live here so they are trivially unit-testable without simulating CGEvents. `VimKeysTests` exercises this directly.
5. **`KeyCatalog`** — the enum-based source of truth for `VimCommand` (the full v1 binding set, forward-compat) and the default `VimBindings` table that maps `(characters, requiresShift)` chords to commands.
6. **`PermissionController`** — wraps `CGPreflightListenEventAccess` (Input Monitoring), `CGPreflightPostEventAccess` (Accessibility for posting events), `AXIsProcessTrustedWithOptions` (Accessibility for AX-tree reads, used in V-M2+), and a stub for Apple Events (used in V-M4+).
7. **`SafariObserver`** — `@MainActor` wrapper around `NSWorkspace.didActivateApplicationNotification`. Bundle IDs `com.apple.Safari` and `com.apple.SafariTechnologyPreview` count as Safari; anything else makes the engine `.disabled`. AX observers (focus changed, URL changed) arrive in V-M2.

### Event-tap invariants to preserve

- **Pass-through default.** When the state machine is `.disabled` (Safari not frontmost), the tap returns the original event unchanged for every keystroke. No mode-change callback should fire, no logging, no state mutation.
- **Character resolution.** Vim bindings are character-based (`f`, `g`, `?`, `/`), not keycode-based. The engine resolves once per event via `NSEvent(cgEvent:)?.charactersIgnoringModifiers` so non-US layouts work correctly. Pass both keyCode and characters into `decide(...)`.
- **Modifier policy.** Cmd / Option / Control modifiers on a vim key cause `.passThrough`. Shift is allowed (it distinguishes `g` vs `G`).
- **Scroll sign convention.** `CGEvent.scrollWheelEvent2Source(...)`'s `wheel1` argument is positive-up, negative-down. `j` (down) emits a negative wheel1; `k` (up) emits positive.
- **`.scrollToEdge` posts Cmd+Up / Cmd+Down.** Safari binds those to "Scroll to top" / "Scroll to bottom" natively. The engine synthesizes the keypair (keyDown + keyUp) with `.maskCommand` set on the source event.
- **Mode transition callbacks.** Only notify `onModeChange` when `VimStateMachine` reports an actual change — spurious callbacks will flicker the menu bar.
- **Prefix timeout.** `g` prefix and pending counts time out after 1500 ms via a `DispatchSourceTimer`. The engine must cancel and reschedule the timer on every prefix-changing decide.

### Persistence and migration

V-M1 has no persistent settings beyond Sparkle's defaults and `LaunchAtLoginController`. The `SettingsStore` and `SitesStore` arrive in V-M5; both will be UserDefaults-backed. There are no migrations to preserve at V-M1.

## Release workflow

V-M6 lands `scripts/package_release.sh`, `scripts/update_homebrew_tap.sh`, `.github/workflows/release.yml`, a real Sparkle EdDSA keypair, and the Homebrew cask. Until then, `SUPublicEDKey` in `project.yml` / `Info.plist` is intentionally empty and `SUEnableAutomaticChecks` is false; the "Check for Updates…" menu item exists but won't successfully verify until V-M6 sets the real key.

CI (`.github/workflows/ci.yml`) runs the XCTest suite on `macos-latest` for every push to `main` and every PR. The workflow is provisioned but won't actually execute until the GitHub repo is created in V-M6.

## Testing notes

- Tests target `VimStateMachine` and `KeyCatalog` directly — add new coverage at these seams rather than trying to drive `CGEventTap` from tests.
- `VimStateMachine` is a pure value type. Construct one with `VimStateMachine(settings: .v1Default)` and call `decide(...)` with synthetic parameters — no CGEvent needed. See `LayerKeysTests/LayerKeysTests.swift:390-402` (in the sibling LayerKeys repo) for the canonical pattern.
- Use `XCTest`, not Swift Testing — match LayerKeys for consistency. Test class naming: `VimStateMachineTests`, `KeyCatalogTests`. Test method naming: `testDecide*` for state-machine assertions.

## Milestone scope

V-M1 ships scroll/edge bindings only. Bindings, modes, and overlays for later milestones are defined in the source for forward-compat (`VimMode.insert`, `.hint`, `.vomnibar`, etc.) but **must not be reachable** from `decide(...)` until their owning milestone lands. Adding behavior earlier than its milestone is scope creep.
