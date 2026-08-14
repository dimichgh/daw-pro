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

# SwiftPM resource bundles (glass-d; generalised at m23-ap-2a-1, 2026-08-13).
#
# Every target that declares runtime-loaded resources gets its own .bundle beside
# the binary. They all ship in Contents/Resources — the standard app location,
# where the loaders look first (NOT the bundle root: a stray top-level item there
# would break the codesign seal).
#
# ⚠️⚠️ THIS USED TO COPY EXACTLY ONE, HARDCODED (`daw-pro_DAWApp.bundle`), AND
# THAT WAS A LATENT SHIPPING BUG THE MOMENT A SECOND TARGET GAINED RESOURCES.
# m23-ap-2a vendored the SwiftF0 weights into DAWEngine; they landed in
# `daw-pro_DAWEngine.bundle`, which this script then silently did not copy — so a
# packaged app could never find the pitch model. It failed as a clean
# `weightsMissing` rather than a crash only because `PitchTracker` deliberately
# avoids `Bundle.module` (whose generated accessor ends in `fatalError`). The
# whole test suite stayed green throughout, because tests resolve via the
# `.xctest`-sibling path and never exercise the packaged layout.
#
# USER RULING 2026-08-13, asked as "the pitch model won't reach the built app":
# *"Copy every resource bundle — fixes this and any future one."*
#
# ⚠️ "EVERY" IS FILTERED IN EXACTLY ONE WAY, AND IT IS NOT PEDANTRY: TEST BUNDLES
# MUST NEVER SHIP. A test build leaves `daw-pro_*Tests.bundle` beside the product
# ones (measured: `daw-pro_DAWCoreTests.bundle`, 92 KB), and a literal "copy
# every .bundle" would seal test fixtures into a signed, distributed app.
# `--show-bin-path -c release` does not normally surface them, which is exactly
# what makes this the kind of leak nobody notices until it has shipped.
shopt -s nullglob
copied_bundles=()
for rb in "$BIN_DIR"/*.bundle; do
    case "$(basename "$rb")" in
        *Tests.bundle|*Tests*.bundle)
            echo "  skipping test bundle: $(basename "$rb")"
            continue
            ;;
    esac
    cp -R "$rb" "$APP/Contents/Resources/"
    copied_bundles+=("$(basename "$rb")")
done
shopt -u nullglob

echo "  resource bundles copied: ${#copied_bundles[@]} — ${copied_bundles[*]:-none}"

# Two are REQUIRED, and each fails loudly here rather than quietly at runtime.
# DAWApp carries the onboarding hero art; DAWEngine carries the SwiftF0 weights.
# A missing one is a packaging failure, not a runtime condition.
for required in daw-pro_DAWApp.bundle daw-pro_DAWEngine.bundle; do
    if [[ ! -d "$APP/Contents/Resources/$required" ]]; then
        echo "error: required resource bundle '$required' did not reach the app" >&2
        echo "       (looked in $BIN_DIR — was the release build run?)" >&2
        exit 1
    fi
done

# Voice-conversion correctness patches + the facade hook (m10-p-6, 2026-08-13).
#
# These are OURS and tiny (~55 KB together). They are NOT optional: without them
# the RVC sidecar produces wrong audio (MLX's broken conv_transpose1d on long
# outputs, and the fork's flow noise_scale shipped at 0.0). The ~1.7 GB vendored
# runtime they patch canNOT ship in a signed bundle and installs separately into
# Application Support — which is exactly why these must be bundled: with the
# runtime living elsewhere, `rvcDir`'s sibling is NOT where our files are, so
# Configuration.resolveOwnedDir falls through to Contents/Resources for them.
#
# Like the weights above, this MUST run before `codesign`.
for owned in rvc-patches rvc-mitigation; do
    src="scripts/$owned"
    if [[ ! -d "$src" ]]; then
        echo "error: $src not found — the sidecar would produce WRONG AUDIO" >&2
        exit 1
    fi
    dest="$APP/Contents/Resources/$owned"
    mkdir -p "$dest"
    # No __pycache__: it would break the mitigation dir's one-file invariant and
    # is dead weight inside a read-only, signed bundle anyway.
    find "$src" -type f -name '*.py' -not -path '*__pycache__*' -exec cp {} "$dest/" \;
    find "$src" -type f \( -name '*.md' -o -name '*.patch' \) -exec cp {} "$dest/" \;
done

# ⚠️ scripts/rvc-mitigation/ goes on sys.path AHEAD of site-packages, so a second
# module there would shadow a same-named module for the whole interpreter. The
# invariant is asserted by gate_m23fo_mechanism.py at the source; assert it again
# on what actually LANDED, because a bundling bug is exactly how a copy diverges
# from its source.
hook_files=$(find "$APP/Contents/Resources/rvc-mitigation" -type f -name '*.py' | wc -l | tr -d ' ')
if [[ "$hook_files" != "1" ]]; then
    echo "error: rvc-mitigation must bundle EXACTLY ONE .py, found $hook_files" >&2
    exit 1
fi
echo "==> bundled voice-conversion patches + hook (one-file invariant holds)"

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

# --- Strip (m23-dp) ----------------------------------------------------------
# The linked binary carries ~20.6 MB of symbols — more than half the shipped
# bundle. `-S` drops the debug symbol table, `-x` drops local symbols; neither
# touches the external/dynamic symbols Swift reflection and SwiftUI need, which
# is why the aggressive forms (`-r`, `-u`, bare `strip`) are deliberately NOT
# used here.
#
# ⚠️ ORDERING IS LOAD-BEARING: this MUST run BEFORE `codesign` below. Stripping
# rewrites the Mach-O, so doing it after signing silently invalidates the seal
# and the app fails Gatekeeper with no error at bundle time.
#
# Set DAWPRO_NO_STRIP=1 to keep symbols when you need readable crash reports
# with function names instead of raw addresses.
if [[ "${DAWPRO_NO_STRIP:-0}" == "1" ]]; then
    echo "==> strip SKIPPED (DAWPRO_NO_STRIP=1) — symbols kept for crash reports"
else
    STRIP_TARGET="$APP/Contents/MacOS/$EXECUTABLE"
    BEFORE_BYTES=$(stat -f %z "$STRIP_TARGET")
    strip -S -x "$STRIP_TARGET"
    AFTER_BYTES=$(stat -f %z "$STRIP_TARGET")
    echo "==> strip -S -x: $((BEFORE_BYTES / 1048576)) MB -> $((AFTER_BYTES / 1048576)) MB" \
         "(saved $(( (BEFORE_BYTES - AFTER_BYTES) / 1048576 )) MB)"
fi

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
