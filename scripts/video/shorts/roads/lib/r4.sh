#!/bin/bash
# Render ONE FORMAT of the sample into out/r4/<name>/, optionally with a look
# override. Landscape and the Short come out of the SAME scene, the same song
# data and the same physics -- only `width`/`height` and the camera keyframes
# differ, both of which live in song.json's `formats` block.
#
# ⭐ THIS NEVER TOUCHES THE DAW. out/music.wav is already rendered and
# gain-steered, so a format or a look change costs frames + ffmpeg and nothing
# else. Staging 17695 is not contacted; 17600 is not contacted.
# ⛔ It also never writes to out/ladder/r3-geometry — that file is under
# independent review and is left exactly as it is.
set -euo pipefail
D=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/00-sample
R=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads
PY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python

fmt="$1"; name="${2:-$1}"
# ⚠ NOT `look="${3:-{}}"` -- bash reads that default as `{` and appends a stray
# `}`, so every rung got `{"arcDecay":0.8}}` and died in JSON.parse. It killed a
# six-rung ladder silently because the loop piped through grep.
look="${3-}"; [ -z "$look" ] && look='{}'
SECS=$($PY -c "import json;print(json.load(open('$D/song.json'))['renderSeconds'])")
LEAD=$($PY -c "import json;print(json.load(open('$D/song.json'))['vizLagMs']/1000.0)")
OUT="${OUT:-r4}"
V="$D/out/$OUT/$name"; mkdir -p "$V"
echo "=== $OUT $name  format=$fmt  look=$look"

node "$R/lib/prep.mjs" "$D/song.json" --format "$fmt" --out "$V/base.json"
node "$R/lib/look.mjs" "$V/base.json" "$V/payload.json" "$look"

# ⛔⛔⛔ TWO BUGS LIVED IN THIS SECTION AND THEY WERE THE SAME BUG.
#
# (1) COVERAGE. It used to set SHEETGATES=0 for any take whose look JSON did
#     not contain the literal string "default", which silently skipped marks,
#     paperpix, roadpix AND entry for BOTH reverse cuts. "approach-cool passes"
#     therefore meant framegate + perfcam only; the other four verdicts did not
#     exist for it and nothing said so. The justification -- that those gates
#     are take-independent because perfcam proves the STATE is -- was the
#     round-5b hole restated: perfcam proves the state is shared, not that the
#     take renders it correctly, and the take is exactly what those gates would
#     have been looking at.
#
# (2) THE ORPHAN. `set -e` aborted at the first red gate, which skipped the
#     check stills, the sync run AND the cleanup -- leaving 817 MB of frames in
#     out/r8/approach and no check/ directory, which is how the missing
#     coverage was noticed at all.
#
# Both are fixed the same way: run EVERY gate, keep EVERY exit code, ALWAYS
# write the stills and ALWAYS delete the frames, and exit the worst code at the
# very end. A gate is now free to go red without destroying the run's evidence.
set +e
WORST=0
g() { # g <label> <cmd...>
  local lbl="$1"; shift
  "$@"; local rc=$?
  echo "  [gate] $lbl -> exit $rc"
  # 1 = a real failure and outranks 2 = a broken probe, which outranks 0
  if [ "$rc" = 1 ]; then WORST=1; elif [ "$rc" = 2 ] && [ "$WORST" = 0 ]; then WORST=2; fi
}

g marks    node "$R/lib/marks.mjs"    "$V/payload.json"
g paperpix node "$R/lib/paperpix.mjs" "$V/payload.json" "$V/paperpix"
g roadpix  node "$R/lib/roadpix.mjs"  "$V/payload.json" "$V/roadpix"
g entry    node "$R/lib/entry.mjs"    "$V/payload.json"
g perfcam  node "$R/lib/perfcam.mjs"  "$V/payload.json"
g framing  node "$R/lib/framing.mjs"  "$V/payload.json"
# ⭐ (L) label orientation, asserted rather than eyeballed (round 17)
g labels   node "$R/lib/labels.mjs"   "$V/payload.json"
# ⭐ (G) the world-space ribbon guard + the approach-tail assertion (round 12)
g ribbon   node "$R/lib/ribbon.mjs"   "$V/payload.json"
# ⭐ (R) a voice returning after a rest must FLY IN, not switch on (round 13).
# ⚠ It reports BROKEN on a payload with no rest long enough to darken a voice —
# the tuning sample is exactly that, which is why the defect shipped.
g reentry  node "$R/lib/reentry.mjs"  "$V/payload.json"
# ⭐ (S) THE TILE BOUNDARY. Reports BROKEN (exit 2) rather than a hollow pass on a
# payload short enough not to wrap — which the tuning sample is, deliberately.
g seam     node "$R/lib/seam.mjs"     "$V/payload.json"

# ⛔⛔ THESE THREE USED TO RUN UNCHECKED UNDER `set +e`, AND A TRUNCATED FILM
# COULD SHIP GREEN. shoot.mjs and both ffmpegs had no status test: a
# part-rendered frames dir encodes a short picture, `-shortest` truncates the
# mux to match it, and WORST stayed 0. Nothing in the suite pinned frame count
# or duration -- framegate.py's `len(files) < 30` was the only guard in the
# whole run, and 31 of 414 frames passes it.
# ⭐ THE PIN IS DERIVED, NOT TYPED: the frame count is `renderSeconds * 30`,
# the same number shoot.mjs is given, so it cannot drift from what was asked
# for. A short render is a BROKEN run (exit 2), not a failed assertion.
rm -rf "$V/frames"
node "$R/lib/shoot.mjs" "$V/payload.json" "$V/frames" "$SECS"
SHOOT_RC=$?
WANT=$($PY -c "import math,sys; print(int(round(float(sys.argv[1])*30)))" "$SECS")
GOT=$(ls "$V/frames" 2>/dev/null | grep -c '^f[0-9]*\.png$')
if [ "$SHOOT_RC" != 0 ] || [ "$GOT" -lt "$WANT" ]; then
  echo "  [BROKEN] shoot.mjs exit $SHOOT_RC and wrote $GOT of $WANT frames — the render"
  echo "  [BROKEN] is INCOMPLETE. Nothing below has measured this film."
  WORST=2; [ "$SHOOT_RC" != 0 ] && WORST=1
  echo "  === $name worst gate exit: $WORST"; exit $WORST
fi
echo "  [pin] frames $GOT / $WANT expected (renderSeconds $SECS x 30)"

ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$V/frames/f%06d.png" \
  -vf setsar=1 -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 "$V/picture.mp4"
ENC1=$?
ffmpeg -hide_banner -loglevel error -y -i "$V/picture.mp4" -i "$D/out/music.wav" \
  -c:v copy -af "aresample=48000,aformat=channel_layouts=stereo" -c:a aac -b:a 192k \
  -shortest "$V/$name.mp4"
ENC2=$?
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$V/$name.mp4" 2>/dev/null)
SHORT=$($PY -c "import sys; d=float(sys.argv[1] or 0); w=float(sys.argv[2]); print(1 if d < w-0.5 else 0)" "$DUR" "$SECS")
if [ "$ENC1" != 0 ] || [ "$ENC2" != 0 ] || [ "$SHORT" = 1 ]; then
  echo "  [BROKEN] encode exits $ENC1/$ENC2 and the muxed film is ${DUR}s against ${SECS}s asked for."
  echo "  [BROKEN] -shortest will silently truncate to a partial picture; NOT a measured failure."
  WORST=2
  echo "  === $name worst gate exit: $WORST"; exit $WORST
fi
echo "  [pin] film duration ${DUR}s / ${SECS}s asked for"

g framegate  $PY "$R/lib/framegate.py" "$V/frames" "$V/payload.json"
g afterglow  node "$R/lib/afterglow.mjs" "$V/payload.json"
# ⚠ RENAMED. This line used to be labelled "the ball must LAND on the onset",
# which it has never been able to check: sync.py decodes the AUDIO ONLY and
# never opens a frame. All four cuts share a byte-identical audio track, so it
# prints an identical verdict for every one of them. Nothing in this suite
# measures whether the FLASH is on the beat; saying so is better than a label
# that implies it does.
g "sync (AUDIO ONLY - onsets vs the score; says nothing about the picture)" \
  $PY "$R/../tunes/lib/sync.py" "$V/$name.mp4" "$D/song.json" --roads --lead "$LEAD"

# ALWAYS -- these used to sit after a `set -e` gate and never ran on a red run
mkdir -p "$V/check"
for t in 0.00 2.00 6.60 11.20 12.90; do
  ffmpeg -hide_banner -loglevel error -y -ss "$t" -i "$V/$name.mp4" -frames:v 1 "$V/check/f$t.png"
done
rm -rf "$V/frames" "$V/_stills" "$V/picture.mp4"
echo "  === $name worst gate exit: $WORST"
echo "r4 $name done -> $V/$name.mp4"
exit $WORST
