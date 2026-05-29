# Decisions

> Architecture decision records. Append-only — one entry per decision.

## [2026-05-28] Automation permission obtained by gesture, never by the background poll

**Context**: The URL poll (per-site ignorelist + Esc-Esc) sends an Apple Event to Safari. The first AE send raises the macOS "control Safari" consent dialog. An earlier change had un-gated the poll, so the prompt could pop from a 1.5s background timer at launch while the user was mid-task (F15).
**Decision**: The poll checks permission with `AEDeterminePermissionToAutomateTarget(promptIfNeeded:false)` (via `SafariBridge.hasAccess`) and skips the AE when not granted — it never prompts. The grant is obtained only by an explicit user gesture: a "Grant Automation Access" button in Settings → Permissions, or the first AE-using keypress (`o`/`O`/`T`/`yy`/`p`/`P`). The dead `PermissionController.hasAppleEventsAccess` stub was wired to the real check (F17).
**Alternatives considered**: (a) prompt once at launch — still surprises the user; (b) revert to gating the poll on `hasAccess` at start only — resurrects the original chicken-and-egg where the ignorelist stayed dead until an AE key was pressed.
**Rationale**: A background timer must never raise modal consent. Per-tick `promptIfNeeded:false` is side-effect-free and auto-recovers the moment the user grants via a gesture.

## [2026-05-28] Esc-Esc chord scoped to Safari-frontmost + plain-Esc only

**Context**: The session-wide CGEventTap ran the Esc-Esc suspend chord before the "Safari not frontmost" passthrough, so a routine double-Esc in any other app had its 2nd Esc swallowed (F33); and an Esc that dismissed an overlay still armed the chord, so a reflexive 2nd Esc suspended the site (F10).
**Decision**: Run the chord only when Safari is frontmost (never in `.disabled`), and arm it only when the first Esc was a plain no-op pass-through (not when it dismissed an overlay / left insert / cancelled a prefix). In `.insertFirst` mode, where every Esc toggles insert↔normal, the chord therefore never arms — Esc-Esc suspend lives in autoDetect/manual normal mode and as the un-suspend gesture in `.disabledBySite`.
**Rationale**: A global tap must not eat Escape in unrelated apps; hijacking a reflexive second Esc into a suspend is surprising. Trade-off (no Esc-Esc suspend in insertFirst) is acceptable — that mode uses Esc as its own toggle.

## [2026-05-28] Caps Lock ignored for navigation commands only

**Context**: `event.flags` (incl. Caps Lock's `.maskAlphaShift`) was passed verbatim into UCKeyTranslate, uppercasing dispatch chars and misfiring the case-sensitive binding table (`g`→`G`, etc.) (F6).
**Decision**: The engine resolves a separate Caps-Lock-free `commandCharacters` for normal-mode dispatch; hint/vomnibar text entry keeps the raw character (Caps Lock respected). Hint matching is already case-insensitive, so hints are unaffected either way.
**Alternatives considered**: strip Caps Lock everywhere (would lose uppercase in the vomnibar). **Rationale**: matches the user's explicit choice — commands are case-as-shift, free text honors Caps Lock.

## [2026-05-28] SafariBridge targets the frontmost Safari-family app

**Context**: `SafariObserver` activates VimKeys for both Safari and Safari Technology Preview, but `SafariBridge` hardcoded `com.apple.Safari`, so in Tech Preview the URL poll/copy/open/tab-switch hit the wrong app (F34).
**Decision**: `SafariBridge.activeBundleID` resolves the frontmost app when it's in `SafariObserver.safariBundleIDs`, else falls back to vanilla Safari. All scripting + the permission check route through it.
**Known limitation**: `requestAutomationAccess()` runs while the Settings window (not Safari) is frontmost, so it targets the vanilla-Safari fallback — a Tech-Preview-only user would be linked to the wrong app's Automation toggle. Documented, low impact.

## [2026-05-28] AX↔Cocoa coordinate conversion centralized in `ScreenCoordinates`

**Context**: AX frames (top-left origin, Y down) were compared against / positioned within `NSScreen.frame` (bottom-left origin, Y up). They coincide only on the primary display, so hint overlays, screen selection, and the visibility filter all broke on secondary monitors (F25/26/27).
**Decision**: A pure, unit-tested `ScreenCoordinates.flip` (involution pivoting on primary-display height) + `pointInPanel`. Hint badges now position via `.offset` from the panel's AX origin (also fixes the half-badge center-anchor offset, F28).
**Rationale**: One tested conversion instead of ad-hoc mixing. The math is unit-tested; the AX/AppKit integration needs on-hardware multi-monitor verification.

## [2026-05-29] Key remapping scoped to character bindings; modifier chords + Esc stay fixed

**Context**: Shipping user-remappable bindings (F35). The bindings table (`VimBindings`) only holds the character-based normal-mode chords (single + g/y prefix). The modifier chords (Cmd+H/L, Cmd+Shift+J/K) and Esc/Esc-Esc are resolved by keycode in `VimStateMachine.decide(...)`, outside the table.
**Decision**: v1 remaps only the character bindings. Modifier chords + Esc are shown as fixed. Persistence via `BindingsStore` (schema-versioned JSON, mirrors `SitesStore`); the help overlay + a new Settings → Keys tab both render from the live reverse index so they can't drift.
**Guardrails (from adversarial review)**: reject `g`/`y` and digits for single-char chords (the state machine resolves them before the single-char table, so such a binding would be silently dead); block conflicts and keep every command reachable (rebinding falls back to the default shape so an unbound command stays recoverable in the UI).
**Alternatives considered**: a full keycode+modifier chord model that would also make the modifier chords remappable — deferred as a larger model change. **Rationale**: the character bindings are what users actually want to remap; the keycode chords are few and have sensible defaults.

## [2026-05-29] AppModel decomposition done incrementally, not big-bang

**Context**: F36 flagged AppModel as a ~700-line god object.
**Decision**: Extract one focused, testable collaborator at a time with the suite green between. Done: `SafariURLPoller` (F36.1 — the recently-buggy poll seam, now unit-tested) and `QueryURL` (F36.3 — de-dups clipboard + vomnibar URL/search resolution).
**Deferred**: `PermissionsModel` (F36.2) — extracting the four permission flags would churn every view that reads `model.permissionState`/etc. for no user benefit and real regression risk; `wiring cleanup` (F36.4) — negligible value now that the poller extraction reduced the engine callbacks to one-liners.
**Rationale**: The poll seam was worth isolating (it caused real field bugs and is now tested); the rest is cosmetic. A big-bang AppModel rewrite trades real regression risk for no user-visible gain.
