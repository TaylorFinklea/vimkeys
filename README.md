# VimKeys

VimKeys is a macOS menu-bar app that adds vim-style home-row navigation to
Safari. Active only when Safari is frontmost; gets out of the way
everywhere else. Inspired by Vimium (Chrome) and Vifari (Hammerspoon
Spoon).

## Status

`v0.6.0` — feature-complete for v1: scroll, find, history, reload,
insert-mode auto-detect, link hints, vomnibar (URL / tabs / bookmarks),
paste-and-go, copy-URL, per-site disable, Esc-Esc session suspend,
layout-aware keyboard resolution. Pending V-M6 release infrastructure
(Sparkle keypair, signed/notarized binaries on GitHub, Homebrew cask).

## Bindings

When Safari is frontmost. Outside Safari, every key passes through.

| Chord | Action |
|---|---|
| `j` / `k` / `h` / `l` | Scroll down / up / left / right (3 lines per press) |
| `d` / `u` | Half-page down / up (~15 lines) |
| `gg` / `G` | Top / bottom of page |
| `<count>` | Repeat next motion: `5j` scrolls down 5× (capped at 999) |
| `f` | Show hints, click on label match |
| `F` | Show hints, open match in new tab (Cmd+click) |
| `gi` | Focus first text input |
| `gs` | View source (Cmd+Option+U, requires Develop menu) |
| `/` / `n` / `N` | Find in page / next / previous |
| `H` / `L` | History back / forward |
| `r` / `R` | Reload / hard reload (Cmd+Option+R, requires Develop menu) |
| `o` / `O` | Vomnibar URL / open in new tab |
| `T` | Vomnibar tab switcher |
| `b` / `B` | Bookmark vomnibar / open in new tab (requires Full Disk Access) |
| `yy` / `yf` | Copy current URL / copy link URL via hints |
| `p` / `P` | Open clipboard URL in current / new tab |
| `Esc Esc` | Toggle session suspend on the current URL (cleared on navigation) |
| `i` / `Esc` | Insert mode / leave insert mode |
| `?` | Toggle help overlay |

Settings → Bindings exposes the hint alphabet (default
`sadfjkl;ehiwopvbnm`).
Settings → Sites manages per-host disable rules — VimKeys silently
passes every key through on hosts matching the list.

## Permissions

Three TCC scopes. All requested on first use.

- **Input Monitoring** — read keys globally while Safari is frontmost.
- **Accessibility** — post scroll events, classify focused-element type
  for insert-mode auto-detect, traverse Safari's AX tree for link hints.
- **Automation \u{2192} Safari** (Apple Events) — query URLs + tabs, set
  tab URLs, switch tabs. Used by `yy`, `o`, `O`, `T`, `p`, `P`, `yf`,
  and per-site disable URL polling.
- **Full Disk Access** (optional) — only needed for `b` / `B` bookmark
  vomnibar, which reads `~/Library/Safari/Bookmarks.plist`. macOS
  doesn't prompt automatically; add VimKeys at System Settings \u{2192}
  Privacy & Security \u{2192} Full Disk Access.

After granting, restart VimKeys via the menu-bar dropdown so the global
event tap picks up the new permission snapshot (the kernel binds it at
tap-creation time).

## Install

A signed/notarized release will land via Homebrew once V-M6 ships. For
now, build locally:

```bash
brew install xcodegen
git clone https://github.com/TaylorFinklea/vimkeys
cd vimkeys
xcodegen generate
xcodebuild build -scheme VimKeys -project VimKeys.xcodeproj \
  -configuration Release -destination 'platform=macOS'
ditto $(xcodebuild -scheme VimKeys -showBuildSettings -configuration Release \
  | awk '/ BUILT_PRODUCTS_DIR =/ {print $3}')/VimKeys.app /Applications/VimKeys.app
```

## Build + test

```bash
xcodegen generate
xcodebuild test -scheme VimKeys -project VimKeys.xcodeproj \
  -destination 'platform=macOS'
```

The Xcode project is generated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (Swift 6, macOS 14+).
Edit `project.yml` rather than the `.xcodeproj`.

Manual smoke-test checklists live under `docs/manual-tests/`, one per
milestone.

## Release pipeline

`scripts/package_release.sh` builds unsigned, signs with the local
Developer ID Application identity, notarises via `xcrun notarytool`,
staples the ticket, and emits `dist/VimKeys.zip` + `.sha256`.

`scripts/update_homebrew_tap.sh` writes a `vimkeys.rb` cask into
`../homebrew-tap/Casks/`.

CI under `.github/workflows/release.yml` runs both on tag push. Secrets
required:

- `APPLE_DEVID_CERT_P12_BASE64`, `APPLE_DEVID_CERT_PASSWORD`
- `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, `NOTARY_TEAM_ID`
- `SPARKLE_EDDSA_PRIVATE_KEY` (matching `SUPublicEDKey` in
  `VimKeys/Info.plist`)

## License

MIT — see `LICENSE`. Copyright Taylor Finklea 2026.
