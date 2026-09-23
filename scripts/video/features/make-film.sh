#!/usr/bin/env bash
# THE WHOLE FILM, IN ORDER, AS ONE COMMAND.
#
# ⛔⛔ WHY THIS FILE EXISTS. Three defects in the last cut were not bugs in any
# script — they were STEPS THAT DID NOT RUN:
#   · the intro/outro cards were never attached (optional flags, silent omission)
#   · the burst directories the manifest named were never recorded, and the
#     assembler fell through to stills without a word
#   · the branding of the visualisers happened once, by hand, in a shell that is
#     now closed — and stamped a narration disclaimer onto six silent videos
# A pipeline that lives in someone's shell history has no gates, because there
# is nothing to gate. This runs the steps in the only order that works, and
# stops at the first one that fails.
#
# ⚠ ONE WIRE SCRIPT AT A TIME. Every step below that touches port 17695 calls
# project.new; running two at once destroys the other's project mid-render.
# That is not hypothetical — it killed two builds in this session.
#
#   ./make-film.sh [--skip-build] [--skip-record] [--skip-viz]
set -euo pipefail
cd "$(dirname "$0")"
export DAW_CONTROL_PORT=17695 DAW_TIMEOUT_MS=900000

FILM="${FEATURES_HOME:-$(cd "$(dirname "$0")" && pwd)}"
SK=/Users/dsemenov/Views/daw-pro/claude-plugin/skills/demo-film
BPY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python   # system python3 has NO Pillow
step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }

# ── 1. the three arrangements, with the chosen lead ────────────────────────
if [[ " $* " != *" --skip-build "* ]]; then
  step "building the three variants (supersaw lead)"
  mkdir -p "$FILM/logs"
  for v in machine-room mountain-king fate; do
    # ⚠ `| tail -3` ATE THE ERROR. Under pipefail a failed build still aborted
    # the run, but the only thing on screen was the last three lines of a
    # successful-looking log — the actual refusal scrolled past unseen. The
    # full log goes to a file and the tail is shown ONLY on the way out.
    echo "  $v ..."
    node build.mjs "$v" > "$FILM/logs/$v.build.log" 2>&1 \
      || { echo "⛔ build of $v FAILED:"; tail -25 "$FILM/logs/$v.build.log"; exit 1; }
    tail -3 "$FILM/logs/$v.build.log"
  done
fi

# ── 1b. does the film still tell the truth about the render? ───────────────
# ⛔ THE NARRATION ASSERTS MEASURED NUMBERS OUT LOUD. Changing the lead moves
# them, and narrate.py re-uses any take it already has. This measures the fresh
# render, rewrites the sentence if the figures moved, and bins the stale take so
# step 4 is forced to speak the new one. It also re-asserts true peak and
# section structure — the supersaw stacks seven saws where there was one.
step "checking the spoken claims against the new render"
"$BPY" sync-claims.py "$FILM/out/machine-room/build.json" manifest.json "$FILM/vo"

# ── 2. one audio excerpt per stage ─────────────────────────────────────────
step "cutting one loop per stage"
bash cut-loops.sh

# ── 3. the recordings — one per stage, each its own burst directory ────────
if [[ " $* " != *" --skip-record "* ]]; then
  step "recording one distinct take per beat"
  bash record-all.sh
fi

# ── 4. narration ───────────────────────────────────────────────────────────
# ⚠ THE SERVER SHIPS IN THIS REPO. Do not conclude it is missing from a failed
# `which omlx` or a failed `import mlx_omni_server` — the package is `omlx`, and
# a wrong module name raises the IDENTICAL error as a missing one. That mistake
# shipped a film in the macOS `say` voice once already.
#
# ⛔⛔ narrate.py IS CONFIGURED BY ENVIRONMENT, NOT BY FLAGS. It has no argparse
# at all: it reads MANIFEST and OUT_DIR from os.environ and IGNORES argv
# entirely. This line used to pass `--manifest ... --out "$FILM/vo"`, which
# Python accepted in silence and then wrote narration to ./vo INSIDE THE REPO
# while the assembler two steps below read $FILM/vo and picked up the PREVIOUS
# cut's takes. Every meter would have passed; the film would have shipped the
# old words over the new pictures.
step "narration (cloned voice)"
eval "$("$SK/scripts/speech-server.sh" start)"
trap '"$SK/scripts/speech-server.sh" stop || true' EXIT
MANIFEST=manifest.json OUT_DIR="$FILM/vo" "$BPY" "$SK/scripts/narrate.py"

# ── 5. tie the picture to the words ────────────────────────────────────────
step "generating cutAt from the recorded narration"
node sync-cuts.mjs

# ── 6. the cards ───────────────────────────────────────────────────────────
# ⚠ The FILM is narrated, so its outro KEEPS the disclaimer. The visualisers
# are not, and make-viz.sh passes --no-disclaimer for them.
step "intro and outro cards"
mkdir -p "$FILM/out/brand"
"$BPY" "$SK/scripts/brand.py" intro --brand "$SK/brand.json" --theme features \
    --size 1920x1080 --seconds 3.5 --out "$FILM/out/brand/intro.mp4"
"$BPY" "$SK/scripts/brand.py" outro --brand "$SK/brand.json" --theme features \
    --size 1920x1080 --seconds 5 --out "$FILM/out/brand/outro.mp4"

# ── 7. assemble ────────────────────────────────────────────────────────────
# ⚠ --intro AND --outro ARE NOT OPTIONAL HERE even though argparse says they
# are. A film without them is unbranded and passes every other check.
step "assembling"
"$BPY" "$SK/scripts/assemble.py" \
    --manifest manifest.json --vo "$FILM/vo" --shots "$FILM/out" \
    --loops "$FILM/loops" --bursts "$FILM/bursts" --work "$FILM/work" \
    --intro "$FILM/out/brand/intro.mp4" --outro "$FILM/out/brand/outro.mp4" \
    --out "$FILM/out/demo-film.mp4"

# ── 8. the visualisers ─────────────────────────────────────────────────────
if [[ " $* " != *" --skip-viz "* ]]; then
  # ⛔ MASTER FIRST, AND IN THAT ORDER. make-viz.sh PREFERS <piece>-master.wav
  # when one exists. Re-render a cosmic version without re-mastering and the
  # visualiser silently picks up the PREVIOUS render's master — right filename,
  # wrong music, no error anywhere. The raw renders came in as low as
  # -29.1 LUFS; this levels every version to -18 and to each other, so that
  # when the user says one has more power they are hearing character and not
  # somebody's gain staging.
  step "mastering the cosmic renders to a common level"
  bash master-cosmic.sh

  step "visualisers (long + short, branded, no false disclaimer)"
  bash make-viz.sh
fi

step "done"
ls -la "$FILM/out/demo-film.mp4"
echo
echo "⚠ NOT FINISHED UNTIL SOMEONE LOOKS AT IT. Run the film-observer agent on"
echo "  the output before calling this shipped — a builder must not verify its"
echo "  own work, and every defect in the last two cuts was invisible to gates."
