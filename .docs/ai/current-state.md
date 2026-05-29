# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-28

- Ran a multi-agent bug + design audit of the whole app (9 dimensions → triage → 3-lens adversarial verification). 40 raw → 37 deduped → **27 confirmed** findings (10 rejected as false alarms).
- Fixed 25 of 27 in 8 clusters (A–H), each with regression tests where unit-testable. Adversarially reviewed the diff (3 reviewers); fixed the one regression they found (stale mode-indicator on prefix-clear). All committed in one sweep.
- Net: +~700 LOC, 161 → **181 tests, all passing**. Build clean (only the 2 pre-existing `EventTapService` Sendable warnings remain).
- Headline fixes: Esc-Esc no longer swallows the 2nd Esc system-wide (F33); Caps Lock no longer breaks navigation (F6); sleep/wake recovery no longer dies after the first cycle (F5); AX-focus use-after-free closed (F2); blocklist now handles IPv6/IDN/trailing-dot (F11/12/13); the URL poll no longer pops the Automation prompt from a background timer and no longer flaps disabled sites on transient nils / backgrounding (F15/F20/F21); Automation permission row added to Settings + the dead `hasAppleEventsAccess` stub wired (F17); SafariBridge now targets the frontmost Safari-family app (F34); multi-screen hint coordinate math fixed (F25/26/27/28/29).

## Build Status

- Tests: **181/181 passing** (`xcodegen generate` + `xcodebuild -scheme VimKeys -configuration Debug -destination 'platform=macOS' test`).
- Build: clean. Pre-existing debt: 2 `EventTapService` strict-concurrency warnings (non-Sendable `self` captured in `.main` NSWorkspace observer blocks) — predate this work, out of scope.

## Blockers

- **0.7.12 release still blocked** on the vanished `vimkeys-notarytool` keychain credential (unrelated to this work). Re-store with `xcrun notarytool store-credentials vimkeys-notarytool --apple-id "taylor.finklea@icloud.com" --team-id K7CBQW6MPG` before publishing.

## Open / deferred

- **F37** (US-QWERTY fallback can mismap on non-QWERTY layouts during the ~100ms launch window / on UCKeyTranslate failure): accepted, already documented in `KeyboardLayoutCache`. No code change.
- **Multi-screen fixes (F25/26/27/28/29)** need on-hardware verification on a real multi-monitor (esp. vertically-stacked) setup — the coordinate math is unit-tested (`ScreenCoordinatesTests`) but the AX/AppKit integration can't be unit-tested.
- Two findings rejected by verification as not-real: covered in the phases report.
- Changes are committed but **not pushed** (per repo convention — review then push).
