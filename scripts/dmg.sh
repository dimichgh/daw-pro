#!/bin/bash
# dmg.sh — package the ad-hoc-signed app bundle into a distributable disk
# image (M9 pkg-d). Runs bundle.sh first (idempotent), then builds a
# compressed UDZO image with the app and an /Applications symlink — the
# standard drag-to-install layout — and prints its SHA-256.
#
# Ad-hoc caveat (until pkg-b/c land real signing + notarization): on OTHER
# machines Gatekeeper quarantines the download; first launch needs
# right-click → Open, or `xattr -dr com.apple.quarantine "/Applications/DAW Pro.app"`.
# A copied/installed bundle also needs DAWPRO_ACESTEP_DIR set to reach the
# song-generation sidecar. Both documented in docs/PACKAGING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh

APP="dist/DAWPro.app"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/DAWPro-${SHORT_VERSION}.dmg"
STAGING="dist/dmg-root"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/DAWPro.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "DAW Pro" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "dmg: $DMG"
shasum -a 256 "$DMG"
