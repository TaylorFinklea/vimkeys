#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAP_REPO="${TAP_REPO:-${ROOT_DIR}/../homebrew-tap}"
PLIST_PATH="${ROOT_DIR}/VimKeys/Info.plist"
ZIP_PATH="${ZIP_PATH:-${ROOT_DIR}/dist/VimKeys.zip}"
SHA_PATH="${ROOT_DIR}/dist/VimKeys.sha256"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_PATH}")"
SHA256="${SHA256:-}"

if [[ -z "${SHA256}" ]]; then
  if [[ -f "${SHA_PATH}" ]]; then
    SHA256="$(cat "${SHA_PATH}")"
  elif [[ -f "${ZIP_PATH}" ]]; then
    SHA256="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
  else
    echo "No release zip or checksum found. Run ./scripts/package_release.sh first." >&2
    exit 1
  fi
fi

mkdir -p "${TAP_REPO}/Casks"

cat > "${TAP_REPO}/Casks/vimkeys.rb" <<EOF
cask "vimkeys" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/TaylorFinklea/vimkeys/releases/download/v#{version}/VimKeys.zip"
  name "VimKeys"
  desc "Vim-style home-row navigation for Safari, scoped to a menu-bar app"
  homepage "https://github.com/TaylorFinklea/vimkeys"

  depends_on macos: ">= :sonoma"

  app "VimKeys.app"

  zap trash: [
    "~/Library/Preferences/io.taylorfinklea.vimkeys.plist",
  ]
end
EOF

echo "Updated ${TAP_REPO}/Casks/vimkeys.rb"
