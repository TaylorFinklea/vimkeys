# V-M6 release setup

**Current state (post v0.6.0):**

- GitHub repo: `github.com/TaylorFinklea/vimkeys` — exists, main pushed.
- Homebrew tap: `github.com/TaylorFinklea/homebrew-tap/Casks/vimkeys.rb` — exists.
- Sparkle EdDSA keypair: **shared with LayerKeys** (same public key
  `l2ghc9Y6kQcCddTEo6oRIJ2KL3rrE1ji/Xz+i9bme70=`, same private key
  in the login keychain). Updates to either app are signed by the same
  keypair.
- First release: v0.6.0, signed + notarised + stapled, published via
  the manual local path (`scripts/package_release.sh` →
  `gh release create`).

Everything below describes the remaining setup needed to make
**tag-triggered CI releases** work. Until those secrets land, you can
keep cutting releases manually via the steps in the "Manual release"
section at the bottom.

## 1. GitHub repo

Already created. If you ever rebuild from scratch:

```bash
gh repo create TaylorFinklea/vimkeys --public --source=. --remote=origin
git push -u origin main
```

The Homebrew tap (`TaylorFinklea/homebrew-tap`) is also already set up;
the cask emitter writes into `../homebrew-tap/Casks/vimkeys.rb`.

## 2. Sparkle EdDSA keypair (already wired)

VimKeys reuses LayerKeys' keypair so the private key already lives in
your login keychain. No new generation needed. If you ever want a
separate keypair, run Sparkle's `generate_keys` (ships at
`~/Library/Developer/Xcode/DerivedData/VimKeys-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`)
and update both `VimKeys/Info.plist` and `project.yml` with the new
`SUPublicEDKey`.

To extract the private key for the GitHub Actions secret:

```bash
security find-generic-password \
  -s "https://sparkle-project.org/keys/" \
  -a "ed25519" \
  -w
```

That's the value of `SPARKLE_EDDSA_PRIVATE_KEY`.

## 3. Apple Developer certs

You already have a `Developer ID Application: Taylor Finklea (K7CBQW6MPG)`
cert in your login keychain. Export it for CI as a password-protected
`.p12`:

```bash
security export -k login.keychain -t certs -f pkcs12 \
  -o /tmp/devid.p12 \
  -P "YOUR_P12_PASSWORD" \
  "Developer ID Application: Taylor Finklea (K7CBQW6MPG)"
base64 -i /tmp/devid.p12 -o /tmp/devid.p12.b64
cat /tmp/devid.p12.b64  # value for APPLE_DEVID_CERT_P12_BASE64
```

## 4. Notarization credentials

Create an app-specific password at https://appleid.apple.com → Sign-in
and Security → App-Specific Passwords. Name it `vimkeys-notarytool`.
Save the password.

Store it for local builds:

```bash
xcrun notarytool store-credentials vimkeys-notarytool \
  --apple-id "your-apple-id@example.com" \
  --team-id "K7CBQW6MPG" \
  --password "the-app-specific-password"
```

## 5. GitHub secrets

In the vimkeys repo → Settings → Secrets and variables → Actions, add:

| Secret | Value |
|---|---|
| `APPLE_DEVID_CERT_P12_BASE64` | output of `base64 -i /tmp/devid.p12` |
| `APPLE_DEVID_CERT_PASSWORD` | the `-P` password from step 3 |
| `NOTARY_APPLE_ID` | your Apple ID email |
| `NOTARY_PASSWORD` | the app-specific password from step 4 |
| `NOTARY_TEAM_ID` | `K7CBQW6MPG` |
| `SPARKLE_EDDSA_PRIVATE_KEY` | the private key from step 2 |

## 6. Cut a release via CI (after secrets are set)

```bash
git tag v0.7.0
git push origin v0.7.0
```

`.github/workflows/release.yml` builds, signs, notarises, signs the
Sparkle appcast, and publishes a GitHub release with `VimKeys.zip` +
`appcast.xml` attached.

## 7. Publish the Homebrew cask (only re-run for new versions)

```bash
./scripts/update_homebrew_tap.sh
cd ../homebrew-tap
git add Casks/vimkeys.rb
git commit -m "Update vimkeys to <version>"
git push
```

Users install via:

```bash
brew tap TaylorFinklea/tap
brew install --cask vimkeys
```

## Manual release (works today, no CI secrets needed)

Until the CI secrets are set, this is the canonical path for cutting a
release:

```bash
NOTARY_KEYCHAIN_PROFILE=layerkeys-notarytool ./scripts/package_release.sh
SPARKLE_BIN=~/Library/Developer/Xcode/DerivedData/VimKeys-*/SourcePackages/artifacts/sparkle/Sparkle/bin
"$SPARKLE_BIN"/generate_appcast \
  --download-url-prefix "https://github.com/TaylorFinklea/vimkeys/releases/download/v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' VimKeys/Info.plist)/" \
  -o dist/appcast.xml \
  dist/
gh release create "v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' VimKeys/Info.plist)" \
  dist/VimKeys.zip dist/appcast.xml --generate-notes
./scripts/update_homebrew_tap.sh
cd ../homebrew-tap
git add Casks/vimkeys.rb
git commit -m "Update vimkeys to $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ../vimkeys/VimKeys/Info.plist)"
git push
```

## Subsequent releases

Bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`
and `CFBundleShortVersionString` + `CFBundleVersion` in `VimKeys/Info.plist`.
Regenerate the Xcode project, commit, then either tag-push (CI) or run
the manual flow above.

## Local dry run

Test the signing path without notarising:

```bash
SKIP_NOTARIZE=1 ./scripts/package_release.sh
```

Test the unsigned path (for emergency builds):

```bash
SKIP_CODESIGN=1 ./scripts/package_release.sh
```
