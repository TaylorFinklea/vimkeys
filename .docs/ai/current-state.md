# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main` — pushed through the 0.7.13 release tag; feature work after it is committed but **not pushed**.

## Last Session Summary

**Date**: 2026-05-29

- **Shipped 0.7.13** (the audit-fix release): bumped, notarized, stapled, GitHub release with `VimKeys.zip` + signed `appcast.xml`, Homebrew tap bumped + pushed. The in-app updater serves it (feed → version 25). Contains the 25 audit fixes (commit `dec6941`), including the multi-screen hint coordinate fix the user wants to test.
- **F36.1** — extracted `SafariURLPoller` from AppModel (timer + hasAccess gate + transient-nil skip + dedupe), now unit-tested via an injected fake bridge.
- **F35 (full)** — user-remappable key bindings:
  - F35.1: `VimBindings`/`VimCommand` Codable; `BindingsStore` (schema-versioned, mirrors SitesStore); `Chord` + reverse index + rebind/conflict/completeness helpers.
  - F35.2: help overlay renders from live bindings (`HelpReference` + per-command metadata) — no more drift.
  - F35.3: **Settings → Keys** tab with press-to-capture remapping (single + g/y-prefix chords; modifier chords + Esc fixed).
  - Hardening (from adversarial review): reserve `g`/`y` for single-char chords (they trigger prefix modes), keep an unbound command recoverable, single capture monitor.
- **F36.3** — extracted a shared, tested `QueryURL` resolver (de-dups clipboard paste-and-go + vomnibar URL/search logic).
- Commits since release: `b2f28bc` (poller), `7036e66` (bindings model), `cb51cbb` (help-from-bindings), `d08e7a2` (Keys UI), `0455228` (QueryURL), `e0f047b` (remap hardening).

## Build Status

- Tests: **208/208 passing** (`xcodegen generate` + `xcodebuild -scheme VimKeys -configuration Debug -destination 'platform=macOS' test`). Was 161 at the start of the audit.
- Build clean. Pre-existing debt: 2 `EventTapService` strict-concurrency warnings (predate this work).

## Blockers

- None. (The notary credential `vimkeys-notarytool` was re-stored by the user and works.)

## Open / next

- **Feature work (F35/F36) is committed on `main` but NOT pushed and NOT released** — it'll go into the next release (0.7.14) when the user decides. 0.7.13 shipped only the audit fixes.
- **Verify on hardware**: multi-screen hint positioning (0.7.13) and the new Keys remap UI (press-to-capture, conflict/reset) — both have logic tests but need an interactive pass.
- **Deferred (backlog, see roadmap.md):** F36.2 PermissionsModel extraction (high view-churn, low benefit); F36.4 callback-wiring cleanup (negligible after the poller extraction); F35 stretch: make modifier chords (Cmd+H/L, Cmd+Shift+J/K) and Esc remappable (needs a keycode-chord model, larger).
