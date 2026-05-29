# Roadmap

> Durable goals + active items. Check off as completed; see current-state.md
> for the latest session breadcrumb and decisions.md for the why.

## Now

- [ ] Release 0.7.14 with the F35/F36 work (key remapping + AppModel cleanups) once verified — currently committed on `main`, not pushed/released. 0.7.13 shipped only the audit fixes.
- [ ] On-hardware verification (needs interactive/multi-monitor):
  - [ ] Multi-screen hint positioning (0.7.13 fix) — `f`/`F` on a secondary, especially vertically-stacked, display.
  - [ ] Keys remap UI — press-to-capture, conflict warnings, reset, persistence across relaunch.

## Backlog

### F36.2 — Extract PermissionsModel from AppModel
- **Scope**: Move `permissionState`, `accessibilityGranted`, `fullDiskAccessGranted`, `automationAccessGranted`, `refreshPermissionState`, the `requestX`/`openXSettings` actions, and `probeFullDiskAccess` into a focused `@MainActor ObservableObject`.
- **Files**: `VimKeys/AppModel.swift`, `VimKeys/Settings/SettingsView.swift`, `VimKeys/StatusMenuView.swift` (call sites read `model.permissionState` etc.).
- **Acceptance**: views read `model.permissions.X` (or AppModel re-exposes); no behavior change; suite green.
- **Verify**: `xcodegen generate && xcodebuild -scheme VimKeys -configuration Debug -destination 'platform=macOS' test`.
- **Tier hint**: Sonnet — mechanical multi-file, but touches several view call sites. Deferred: high churn, no user benefit, real regression risk. Only do it if AppModel growth becomes a real maintenance problem.

### F36.4 — Callback-wiring cleanup
- **Scope**: Move the `service.onX = { hopToMain { ... } }` closure bodies in AppModel.init into named methods so the wiring block reads as a table.
- **Files**: `VimKeys/AppModel.swift`.
- **Tier hint**: Haiku. Low value after the SafariURLPoller extraction already shrank these to one-liners; do opportunistically.

### F35 stretch — Remap modifier chords + Esc
- **Scope**: Extend the bindings model to cover keycode+modifier chords (Cmd+H/L, Cmd+Shift+J/K) and Esc/Esc-Esc, currently fixed in `VimStateMachine.decide(...)`.
- **Tier hint**: needs Opus to scope — a new chord model + state-machine refactor; bigger than the v1 character-binding remap.

### Pre-existing tech debt
- [ ] `EventTapService` strict-concurrency warnings (2): non-Sendable `self` captured in the `.main` NSWorkspace sleep/wake observer blocks. Predates the audit; needs an isolation decision for `EventTapService`.
