# V-M6 release setup

Everything in this document is a one-time user action. After completing
it, every `git tag v0.x.y && git push --tags` triggers a signed,
notarised, Sparkle-signed GitHub release.

## 1. GitHub repo

```bash
gh repo create TaylorFinklea/vimkeys --public --source=. --remote=origin
git push -u origin main
```

Mirror the side repo for the Homebrew cask:

```bash
gh repo create TaylorFinklea/homebrew-tap --public
# Clone it as a sibling directory; the release script writes
# ../homebrew-tap/Casks/vimkeys.rb relative to vimkeys/.
git clone https://github.com/TaylorFinklea/homebrew-tap ../homebrew-tap
```

## 2. Generate the Sparkle EdDSA keypair

Sparkle's `generate_keys` lives inside the Sparkle SPM checkout under
`~/Library/Developer/Xcode/DerivedData/.../SourcePackages/checkouts/Sparkle/bin/generate_keys`,
or — more reliably — download the matching Sparkle release tarball:

```bash
SPARKLE_VERSION=2.9.1
curl -fsSL \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
  | tar -xJ -C /tmp
/tmp/bin/generate_keys
```

This stores the private key in your login keychain under the label
`https://sparkle-project.org/keys/`. The public key prints to stdout.

Copy the public key into `VimKeys/Info.plist` AND `project.yml`:

```xml
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_KEY_BASE64_HERE</string>
```

Flip `SUEnableAutomaticChecks` to `true` in both files. Commit.

Export the **private** key for CI:

```bash
security find-generic-password \
  -s "https://sparkle-project.org/keys/" \
  -a "ed25519" \
  -w
```

Copy the printed key — that's the value of the `SPARKLE_EDDSA_PRIVATE_KEY`
secret below.

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

## 6. Cut the first release

```bash
git tag v0.5.0
git push origin v0.5.0
```

GitHub Actions runs `.github/workflows/release.yml`. On success the
release page at `https://github.com/TaylorFinklea/vimkeys/releases/tag/v0.5.0`
contains `VimKeys.zip` (signed, notarised, stapled) and `appcast.xml`
(Sparkle update feed).

## 7. Publish the Homebrew cask

```bash
./scripts/package_release.sh        # only if you didn't already run CI
./scripts/update_homebrew_tap.sh
cd ../homebrew-tap
git add Casks/vimkeys.rb
git commit -m "Update vimkeys to 0.5.0"
git push
```

Users then install via:

```bash
brew tap TaylorFinklea/tap
brew install --cask vimkeys
```

## Subsequent releases

Bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`
(and matching keys in `VimKeys/Info.plist`). Regenerate the Xcode
project, commit, tag, push tag, and re-run the homebrew tap update
script after CI publishes the release.

## Local dry run

Test the signing path without notarising:

```bash
SKIP_NOTARIZE=1 ./scripts/package_release.sh
```

Test the unsigned path (for emergency builds):

```bash
SKIP_CODESIGN=1 ./scripts/package_release.sh
```
