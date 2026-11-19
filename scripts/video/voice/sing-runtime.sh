#!/bin/bash
# Build the PRIVATE singing-engine runtime that staging points at.
#
# ⛔ WHY NOT THE USER'S INSTALL DIRECTLY: the runtime folder holds the sidecar's
# pidfile (`<runtime>/run/sing.pid`). Pointing staging at the user's real
# `~/Library/Application Support/DAWPro/SingingEngine` would share that pidfile
# with the user's live app — two apps each believing they own one engine.
#
# So this is the orch-smoke recipe (W8, 2026-10-07): the heavy, read-only parts
# are SYMLINKED (venv, upstream, weights, nltk_data — nothing here writes to
# them), the built-in voice is COPIED (the facade realpaths a voice and correctly
# refuses one that resolves outside its own root), and install.json is COPIED
# (the app's "installed?" check is that file plus a lockSha256 match).
# Staging gets DAWPRO_SING_RUNTIME_DIR=<this folder> and SING_API_URL on 18004.
set -euo pipefail
VOICE_HOME="${VOICE_HOME:-$(cd "$(dirname "$0")" && pwd)}"
INST="$HOME/Library/Application Support/DAWPro/SingingEngine"
RT="$VOICE_HOME/work/sing-runtime"
SING=/Users/dsemenov/Views/daw-pro/scripts/sing
pin() { grep "^$1=" "$SING/pins.env" | head -n 1 | cut -d= -f2- | tr -d '"'; }

[ -f "$INST/install.json" ] || { echo "⛔ no installed engine at $INST"; exit 1; }
mkdir -p "$RT/voices/builtin-1"
for part in venv upstream weights nltk_data; do
  [ -e "$RT/$part" ] || ln -s "$INST/$part" "$RT/$part"
done
/bin/cp -p "$INST/voices/builtin-1/prompt.wav" "$INST/voices/builtin-1/prompt.json" "$RT/voices/builtin-1/"
/bin/cp -p "$INST/install.json" "$RT/install.json"

W="$(shasum -a 256 "$RT/voices/builtin-1/prompt.wav" | cut -d ' ' -f 1)"
M="$(shasum -a 256 "$RT/voices/builtin-1/prompt.json" | cut -d ' ' -f 1)"
[[ "$W" == "$(pin BUILTIN_WAV_SHA256)" && "$M" == "$(pin BUILTIN_META_SHA256)" ]] \
  || { echo "⛔ built-in voice sha mismatch ($W / $M)"; exit 1; }
L="$(shasum -a 256 "$SING/requirements.lock" | cut -d ' ' -f 1)"
I="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["lockSha256"])' "$RT/install.json")"
[[ "$L" == "$I" ]] || { echo "⛔ install.json lockSha256 $I != shipped lock $L (the app would say needsUpdate)"; exit 1; }

# A 3-second probe before any 20-second model load: the venv, through the
# symlink, imports torch and sees MPS (the orch-smoke probe, verbatim).
PROBE="$(/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 MPLCONFIGDIR="$RT/cache/mpl-probe" \
  "$RT/venv/bin/python" -c 'import sys, torch; print(sys.prefix, torch.__version__, torch.backends.mps.is_available())' 2>&1)"
echo "venv probe: $PROBE"
[[ "$PROBE" == "$RT/venv 2.11.0 True" ]] || { echo "⛔ venv probe failed"; exit 1; }
echo "✓ private runtime ready: $RT (builtin-1 sha ok, lock sha ok)"
