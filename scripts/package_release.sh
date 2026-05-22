#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
DERIVED_DATA_PATH="${ROOT_DIR}/build/release-derived-data"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/VimKeys.app"
ZIP_PATH="${DIST_DIR}/VimKeys.zip"
SHA_PATH="${DIST_DIR}/VimKeys.sha256"
PLIST_PATH="${ROOT_DIR}/VimKeys/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_PATH}")"

# `xcrun notarytool store-credentials` profile name; override with
# NOTARY_KEYCHAIN_PROFILE if you used a different label locally.
: "${NOTARY_KEYCHAIN_PROFILE:=vimkeys-notarytool}"

# Escape hatches for development builds:
#   SKIP_CODESIGN=1     — produce an unsigned build (Gatekeeper will quarantine)
#   SKIP_NOTARIZE=1     — sign locally but don't submit to Apple's notary service
SKIP_CODESIGN="${SKIP_CODESIGN:-}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-}"

mkdir -p "${DIST_DIR}"
rm -rf "${DERIVED_DATA_PATH}" "${ZIP_PATH}" "${SHA_PATH}"

# Regenerate the Xcode project from project.yml so package_release stays in
# lockstep with the canonical config (matters when CI checks out a tag
# without committed .xcodeproj diffs).
( cd "${ROOT_DIR}" && xcodegen generate )

# Always build unsigned; we sign + notarize explicitly afterward so the same
# script works locally (cert in login keychain) and in CI (cert imported into
# a temp keychain by the release workflow).
BUILD_ARGS=(
  -scheme VimKeys
  -project "${ROOT_DIR}/VimKeys.xcodeproj"
  -configuration Release
  -destination "platform=macOS"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
)

xcodebuild "${BUILD_ARGS[@]}"

if [[ -z "${SKIP_CODESIGN}" ]]; then
  # Resolve the Developer ID Application identity. DEVELOPER_ID can be set
  # explicitly to the full cert subject; otherwise we discover the single
  # matching identity in the keychain.
  if [[ -z "${DEVELOPER_ID:-}" ]]; then
    matches=$(security find-identity -p codesigning -v 2>/dev/null \
              | awk -F'"' '/Developer ID Application/ {print $2}' \
              | sort -u)
    match_count=$(printf '%s\n' "${matches}" | grep -c . || true)
    if [[ "${match_count}" -eq 1 ]]; then
      DEVELOPER_ID="${matches}"
    elif [[ "${match_count}" -gt 1 ]]; then
      echo "ERROR: multiple Developer ID Application identities found:" >&2
      printf '  %s\n' "${matches}" >&2
      echo "Set DEVELOPER_ID explicitly to disambiguate." >&2
      exit 1
    else
      echo "ERROR: no Developer ID Application identity in keychain." >&2
      echo "Install one or re-run with SKIP_CODESIGN=1 for an unsigned build." >&2
      exit 1
    fi
  fi

  echo "Signing ${APP_PATH}"
  echo "  identity: ${DEVELOPER_ID}"

  # First pass: deep-sign everything (catches Sparkle's nested XPC
  # services and framework binaries). The outer app bundle is re-signed
  # last so its signature wraps the already-signed nested components.
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "${DEVELOPER_ID}" \
    --deep \
    "${APP_PATH}"

  # Re-sign the outer app bundle last. VimKeys is non-sandboxed and
  # claims no entitlements (TCC — Input Monitoring, Accessibility, Apple
  # Events, Full Disk Access — is granted at runtime, not via claims),
  # so no entitlements file is passed.
  echo "Re-signing main app bundle"
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "${DEVELOPER_ID}" \
    "${APP_PATH}"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
fi

ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

if [[ -z "${SKIP_CODESIGN}" && -z "${SKIP_NOTARIZE}" ]]; then
  if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
    echo "Submitting ${ZIP_PATH} to Apple notary (Apple ID + app-specific password)"
    xcrun notarytool submit "${ZIP_PATH}" \
      --apple-id "${NOTARY_APPLE_ID}" \
      --password "${NOTARY_PASSWORD}" \
      --team-id "${NOTARY_TEAM_ID}" \
      --wait
  else
    echo "Submitting ${ZIP_PATH} to Apple notary (keychain profile=${NOTARY_KEYCHAIN_PROFILE})"
    xcrun notarytool submit "${ZIP_PATH}" \
      --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
      --wait
  fi

  echo "Stapling notarization ticket onto ${APP_PATH}"
  xcrun stapler staple "${APP_PATH}"

  # Re-zip so the distributed archive carries the stapled ticket.
  rm -f "${ZIP_PATH}"
  ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

  # Sanity-check the final artifact: the ticket must validate and Gatekeeper
  # must accept it.
  xcrun stapler validate "${APP_PATH}"
  spctl --assess --type execute --verbose=2 "${APP_PATH}"
fi

shasum -a 256 "${ZIP_PATH}" | awk '{print $1}' > "${SHA_PATH}"

echo "Built VimKeys ${VERSION}"
echo "Zip: ${ZIP_PATH}"
echo "SHA256: $(cat "${SHA_PATH}")"
