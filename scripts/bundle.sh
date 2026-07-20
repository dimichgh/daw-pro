#!/bin/bash
# bundle.sh — assemble an ad-hoc-signed, LaunchServices-registered app bundle
# from the release build (M9 pkg-a). This ends the bare-SPM-executable era:
# after running it, `dist/DAWPro.app` is a real .app that Finder can launch and
# that answers the quit Apple event by name ("DAW Pro"), which is what makes the
# crash-b clean-exit / session.lock-removal path externally drivable.
#
# Idempotent: re-running replaces dist/DAWPro.app cleanly.
# Ad-hoc signing only (identity "-"); Developer ID / notarization are
# credential-blocked and land in pkg-b/c. See docs/PACKAGING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

# --- Configuration -----------------------------------------------------------
SHORT_VERSION="0.1.0"          # CFBundleShortVersionString (marketing)
BUNDLE_VERSION="1"             # CFBundleVersion (build)
EXECUTABLE="DAWApp"           # kept identical to the SPM product for pgrep/
                              # process-name continuity with every gate script
APP="dist/DAWPro.app"
PLIST_TEMPLATE="scripts/Info.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# --- Build -------------------------------------------------------------------
echo "==> swift build -c release"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/$EXECUTABLE"
if [[ ! -x "$BIN" ]]; then
    echo "error: release binary not found at $BIN" >&2
    exit 1
fi

# --- Assemble bundle ---------------------------------------------------------
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

# Info.plist from template with version substitution (single source of truth
# for the version lives in the constants above).
sed -e "s/__SHORT_VERSION__/$SHORT_VERSION/g" \
    -e "s/__BUNDLE_VERSION__/$BUNDLE_VERSION/g" \
    "$PLIST_TEMPLATE" > "$APP/Contents/Info.plist"

# Classic APPL type/creator marker — harmless, keeps older Finder codepaths happy.
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon (glass-b, 2026-07-19): the .icns is a COMMITTED artifact built from
# the GPT-Image master (Sources/DAWApp/Resources/AppIcon-master-1024.png) via
# iconutil; CFBundleIconFile=AppIcon in the plist template points at it.
cp "Sources/DAWApp/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> plutil -lint"
plutil -lint "$APP/Contents/Info.plist"

# --- Sign --------------------------------------------------------------------
# Ad-hoc (identity "-"): runs on this machine and any machine after a
# right-click > Open (Gatekeeper prompt once). Notarization lifts that later.
echo "==> codesign --force --sign - (ad-hoc)"
codesign --force --sign - "$APP"

# --- Register with LaunchServices -------------------------------------------
# Makes `osascript -e 'quit app "DAW Pro"'` resolve the bundle by name.
echo "==> lsregister -f"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP"
else
    echo "warning: lsregister not found at $LSREGISTER; skipping LS registration" >&2
fi

echo "==> done"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'
echo "    bundle: $APP"
