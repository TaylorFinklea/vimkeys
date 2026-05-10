# VimKeys

VimKeys is a macOS menu-bar app that adds vim-style home-row navigation to Safari. Active only when Safari is frontmost; gets out of the way everywhere else.

## Status

Pre-release (v0.1, V-M1). Scroll bindings only — link hints, vomnibar, sites list, and signed releases land in subsequent milestones.

## Defaults (V-M1)

When Safari is frontmost:

- `j` / `k` — scroll down / up (3 lines per press)
- `h` / `l` — scroll left / right
- `d` / `u` — half-page down / up
- `gg` / `G` — top / bottom of page
- A leading digit string (e.g. `5`, `12`) is a repeat count: `5j` scrolls down 5×.

When Safari is not frontmost, every key passes through untouched.

## Permissions

- **Input Monitoring** — required, lets VimKeys read keys globally.
- **Accessibility** — required, lets VimKeys post scroll events and synthesized keys.

Apple Events permission (used by V-M4 vomnibar / clipboard bindings) is not yet wired.

## Build locally

```bash
xcodegen generate
xcodebuild test -scheme VimKeys -project VimKeys.xcodeproj -destination 'platform=macOS'
xcodebuild build -scheme VimKeys -project VimKeys.xcodeproj -configuration Release -destination 'platform=macOS'
```

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) (Swift 6, macOS 14+). Edit `project.yml` rather than the `.xcodeproj` when changing targets, build settings, or sources.

Manual smoke-test checklist for V-M1: `docs/manual-tests/v0.1-smoke.md`.

## License

MIT — see `LICENSE`.
