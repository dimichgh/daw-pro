#!/bin/bash
# bundle.sh — assemble an ad-hoc-signed, LaunchServices-registered app bundle
# from the release build (M9 pkg-a). This ends the bare-SPM-executable era:
# after running it, `dist/DAWPro.app` is a real .app that Finder can launch and
# that answers the quit Apple event by name ("DAW Pro"), which is what makes the
# crash-b clean-exit / session.lock-removal path externally drivable.
#
# Idempotent: re-running replaces dist/DAWPro.app cleanly.
# `--output PATH` (m23-n3d) assembles somewhere else instead, so the packaging
# path can be exercised and `codesign -dv`-verified without disturbing the
# bundle the user actually launches. A relative PATH resolves against the repo
# root (this script cd's there); pass an absolute path for a scratch build.
# Ad-hoc signing only (identity "-"); Developer ID / notarization are
# credential-blocked and land in pkg-b/c. See docs/PACKAGING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

# --- Configuration -----------------------------------------------------------
SHORT_VERSION="0.1.0"          # CFBundleShortVersionString (marketing)
BUNDLE_VERSION="1"             # CFBundleVersion (build)
EXECUTABLE="DAWApp"           # kept identical to the SPM product for pgrep/
                              # process-name continuity with every gate script
DEFAULT_APP="dist/DAWPro.app"
APP="$DEFAULT_APP"
PLIST_TEMPLATE="scripts/Info.plist"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# --- Options -----------------------------------------------------------------
# --with-weights: seal the speech-model weights into the bundle (see below).
# DAWPRO_WHISPER_MODELS_DIR overrides where they are copied FROM, matching the
# same env knob the app itself honours.
WITH_WEIGHTS=0
WEIGHTS_SRC="${DAWPRO_WHISPER_MODELS_DIR:-$HOME/Library/Application Support/DAWPro/Models}"
REGISTER=auto                 # auto = register only the default location
while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-weights) WITH_WEIGHTS=1 ;;
        --output=*) APP="${1#--output=}" ;;
        --output|-o)
            # `shift` past the flag; a missing value must not silently swallow
            # the NEXT flag as a path (`--output --with-weights` would build a
            # bundle literally named "--with-weights").
            if [[ $# -lt 2 || "$2" == -* ]]; then
                echo "error: --output requires a path argument" >&2; exit 2
            fi
            APP="$2"; shift ;;
        --register) REGISTER=force ;;
        --help|-h)
            echo "usage: $0 [--output PATH] [--with-weights] [--register]"
            echo "  --output PATH   where to assemble the bundle"
            echo "                  (default: $DEFAULT_APP; must end in .app)"
            echo "  --with-weights  seal ~1.5 GB of speech weights into the .app"
            echo "                  (default: app loads them from Application Support)"
            echo "  --register      force LaunchServices registration even for a"
            echo "                  non-default --output (see the warning below)"
            echo
            echo "A non-default --output is NOT registered with LaunchServices by"
            echo "default: registering a scratch bundle makes it a second candidate"
            echo "for \`osascript -e 'quit app \"DAW Pro\"'\`, and the registration"
            echo "OUTLIVES the directory — deleting the scratch copy leaves a stale"
            echo "entry that can shadow $DEFAULT_APP."
            exit 0 ;;
        *) echo "error: unknown option '$1' (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# `rm -rf "$APP"` below is reachable with a caller-supplied path, so validate it
# before anything destructive runs. `set -u` catches an UNSET variable but not
# an empty or malformed one, and `rm -rf ""` / `rm -rf /` are not typos worth
# surviving. Requiring the .app suffix is cheap and makes a mistyped path fail
# here rather than delete a real directory.
if [[ -z "$APP" ]]; then
    echo "error: --output path is empty" >&2; exit 2
fi
if [[ "$APP" != *.app ]]; then
    echo "error: --output path must end in .app (got '$APP')" >&2; exit 2
fi

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

# SwiftPM resource bundle (glass-d): the DAWApp target declares runtime-loaded
# resources (the onboarding hero PNGs), which SwiftPM emits as a .bundle beside
# the binary. Ship it in Contents/Resources — the standard app location, where
# OnboardingHeroArt.load looks first (NOT the bundle root: a stray top-level
# item there would break the codesign seal).
RESOURCE_BUNDLE="$BIN_DIR/daw-pro_DAWApp.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
else
    echo "error: SwiftPM resource bundle not found at $RESOURCE_BUNDLE" >&2
    exit 1
fi

# Speech-model weights (m23-n1, 2026-07-27) — OPT-IN, off by default.
#
# The default ships a SMALL app and the weights are installed separately into
#   ~/Library/Application Support/DAWPro/Models/
# which the resolver consults FIRST (WhisperModelCatalog.searchRootCandidates).
# `--with-weights` instead seals a copy into Contents/Resources/Models for a
# self-contained, offline-capable .app — the right choice behind a restrictive
# proxy, at the cost of a ~1.5 GB bundle that must be re-shipped and
# re-notarized in full on every update.
#
# This MUST run before `codesign` below: resources land first, then the seal is
# applied over them. Adding anything after signing invalidates the signature.
if [[ "$WITH_WEIGHTS" == "1" ]]; then
    if [[ ! -d "$WEIGHTS_SRC" ]]; then
        echo "error: --with-weights given but no weights at $WEIGHTS_SRC" >&2
        echo "       install them there first, or set DAWPRO_WHISPER_MODELS_DIR." >&2
        exit 1
    fi
    echo "==> --with-weights: copying $(du -sh "$WEIGHTS_SRC" | cut -f1) into the bundle"
    cp -R "$WEIGHTS_SRC" "$APP/Contents/Resources/Models"
else
    echo "==> weights NOT bundled (default); app resolves them from Application Support"
fi

echo "==> plutil -lint"
plutil -lint "$APP/Contents/Info.plist"

# --- Sign --------------------------------------------------------------------
# Ad-hoc (identity "-"): runs on this machine and any machine after a
# right-click > Open (Gatekeeper prompt once). Notarization lifts that later.
echo "==> codesign --force --sign - (ad-hoc)"
codesign --force --sign - "$APP"

# --- Register with LaunchServices -------------------------------------------
# Makes `osascript -e 'quit app "DAW Pro"'` resolve the bundle by name.
#
# Deliberately SKIPPED for a non-default --output. Registration is global and
# persistent: a registered scratch bundle becomes a second candidate for that
# same quit-by-name lookup, and the entry OUTLIVES the directory — deleting the
# scratch copy leaves a stale record that can shadow the real
# dist/DAWPro.app, which is exactly the path the crash-b clean-exit gate
# depends on. A throwaway bundle built to verify the seal has no business
# touching a machine-wide registry. `--register` forces it back on.
if [[ "$APP" != "$DEFAULT_APP" && "$REGISTER" != "force" ]]; then
    echo "==> lsregister SKIPPED (non-default --output; pass --register to force)"
elif [[ -x "$LSREGISTER" ]]; then
    echo "==> lsregister -f"
    "$LSREGISTER" -f "$APP"
else
    echo "warning: lsregister not found at $LSREGISTER; skipping LS registration" >&2
fi

echo "==> done"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'
echo "    bundle: $APP"
