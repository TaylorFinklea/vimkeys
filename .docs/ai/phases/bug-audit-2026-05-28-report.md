# Bug + Design Audit — 2026-05-28 (report)

Multi-agent audit of the whole app: 9 dimension reviewers → triage/dedupe →
3-lens adversarial verification (reachability / compensation / soundness;
finding kept only if ≥2 of 3 confirmed). **40 raw → 37 deduped → 27 confirmed,
10 rejected.** Then a 3-reviewer adversarial pass over the fix diff.

Result: **25/27 fixed** + tests; 1 documented-as-accepted; build clean,
**181/181 tests** (was 161). Committed in one sweep, not pushed.

## Fixed (by cluster)

### Cluster A — Esc / state machine (`VimStateMachine.swift`)
- **F33 (high)** Esc-Esc chord ran above the `.disabled` passthrough → 2nd Esc of a routine double-tap swallowed system-wide in any app. Chord now scoped to Safari-frontmost.
- **F10 (med)** First Esc that dismissed an overlay / left insert still armed the chord → reflexive 2nd Esc suspended the site. Chord now arms only on a plain no-op Esc.
- **F7 (low)** Pending count/g/y prefix survived a Cmd-chord and applied to the next motion. Now cleared (and the clear is reported as a mode change so the indicator refreshes — caught in review).
- Tests: 6 new in `VimStateMachineTests`.

### Cluster B — Caps Lock (`EventTapEngine.swift`, `VimStateMachine.swift`)
- **F6 (high)** Caps Lock uppercased dispatch chars → wrong/dead bindings. Engine resolves a Caps-Lock-free `commandCharacters` for normal-mode commands; hint/vomnibar text keeps the raw char. 2 new tests.

### Cluster C — Blocklist matching (`Persistence/SitesStore.swift`)
- **F11 (high)** IPv6-literal hosts (`[::1]:5174`) never matched. **F12 (med)** IDN hosts never matched (no punycode). **F13 (low)** trailing-dot FQDNs bypassed. Rewrote around a shared `parseAuthority` (+ `canonicalHost` punycode round-trip, bracket-aware IPv6 vs host:port). 6 new tests.

### Cluster D — Poll robustness + Automation UX (`AppModel.swift`, `SafariBridge.swift`, `PermissionController.swift`, `Settings/SettingsView.swift`)
- **F15 (high)** Background poll raised the Automation consent dialog. Poll now checks permission without prompting; grant via gesture or a new Settings button.
- **F20 (high)** Transient `currentURL()` nil re-enabled a disabled site. Poll skips nil (preserves state).
- **F21 (med)** Backgrounding nulled the URL, flapping disabled sites. `stopURLPoll` no longer pushes nil.
- **F17 (low)** `PermissionController.hasAppleEventsAccess` was a hardcoded `false` stub — wired to the real `AEDeterminePermissionToAutomateTarget` check; added the Settings → Permissions "Automation (Safari)" row.

### Cluster E — Concurrency / lifecycle
- **F2 (high)** `SafariObserver` AX callback deferred an unretained Bridge pointer → use-after-free. Now captures a strong ref before the Task.
- **F5 (high)** `SleepWakeHandler` was a value type; `didWake()`'s write-back clobbered the freshly-installed handler → recovery died after the first sleep/wake. Now a `final class`.
- **F1 (med)** Per-keystroke `Task { @MainActor }` callbacks had no creation-order guarantee. Replaced with a FIFO `hopToMain` (`DispatchQueue.main.async` + `assumeIsolated`).
- **F3 (med)** A stale prefix-timeout `perform` could wipe a freshly-typed prefix. Added a generation token.
- (Not unit-tested — threaded/lifecycle code; verified by reasoning + the swift-concurrency skill + the adversarial review.)

### Cluster F — Safari multi-app (`SafariBridge.swift`, `AppModel.swift`)
- **F34 (high)** Hardcoded `com.apple.Safari` while the engine also activates for Safari Technology Preview → wrong-app targeting. Now resolves the frontmost Safari-family bundle ID per call.
- **F30 (med)** Tab-group switch fails on non-English Safari (English menu titles). English limitation already documented; replaced the misleading "menu wasn't reachable" error with an honest message.

### Cluster G — Multi-screen coordinate math (`ScreenCoordinates.swift` [new], `Overlays/HintOverlayWindow.swift`, `LinkHintCoordinator.swift`, `AXLinkExtractor.swift`, `Overlays/HelpOverlayWindow.swift`)
- **F25/F26/F27 (high/high/med)** AX (top-left) vs Cocoa (bottom-left) coordinate spaces were mixed → hint badges mispositioned, wrong screen picked, visibility filter culled wrong targets on secondary displays. Centralized in a tested `ScreenCoordinates.flip`/`pointInPanel`.
- **F28 (low)** Badges were center-anchored at the target's top-left (half-badge offset) — now top-left-anchored via `.offset`.
- **F29 (low)** Help-overlay docstring overclaimed Safari-screen centering — corrected to match the actual `NSScreen.main` behavior.
- 6 new `ScreenCoordinatesTests`. **Needs on-hardware multi-monitor verification.**

### Cluster H — Polish / silent failures
- **F18 (med)** FDA probe read+parsed the whole `Bookmarks.plist` on the main thread. Added `SafariBookmarks.probeReadable` (mmap, no read/parse).
- **F22 (med)** Link-hint AX-trust-missing failed silently — added an `onError` breadcrumb.
- **F24 (low)** Empty tab read showed a silent empty switcher — added a breadcrumb.

## Accepted / not changed
- **F37 (low)** US-QWERTY fallback can mismap on non-QWERTY layouts during the ~100ms launch window or on UCKeyTranslate failure. Intentional graceful degradation, already documented in `KeyboardLayoutCache`. No fix.

## Rejected by verification (recorded for posterity)
These were dismissed by the ≥2/3 adversarial pass as not-real or not-actionable.
Two are genuine *design* observations (not bugs) worth keeping on the radar:
- **F35** Bindings data model (by-shape dicts + keycode-only Escape, not persisted/reverse-mappable) — **blocks the planned custom-remapping feature**; revisit when that feature is scoped.
- **F36** `AppModel` is a large coordinator (AE polling + clipboard + FDA + permissions + callback wiring) — refactor candidate, not a defect.
- Others (false alarms): F8, F9, F14, F16, F19, F23, F31, F32.

## Verification
`xcodegen generate && xcodebuild -scheme VimKeys -project VimKeys.xcodeproj -configuration Debug -destination 'platform=macOS' test` → 181/181.
