#!/bin/bash
# THE VERTICAL SHORT — bars 1-9, portrait, on the `short-right1` camera.
#
# ⛔⛔ `D` IS THIS DIRECTORY AND NOTHING ELSE. The last file copied from a sibling
# still pointed at 02-moonlight and would have overwritten an approved film. If
# you copy this one, the FIRST edit is D.
#
# ⭐ IT SHARES 03's song.py, ly2notes.py AND source/ RATHER THAN COPYING THEM.
# A second copy of the parser is a second thing to keep in sync and the first
# thing to rot; the span, the output directory and the id are ENVIRONMENT.
#
# ⭐ WHY BARS 1-9 — a Short is not the first N seconds of the long film, and this
# span was chosen for the same reason the long one was, from the melody's rests:
#  · it OPENS at bar 1, so the twenty seconds of accompaniment alone are there to
#    set up the entry rather than being cut off mid-texture;
#  · the melody's FIRST ENTRY at t=20.375 is the most recognisable moment in the
#    movement, and it lands at the two-thirds point of a 40 s Short;
#  · it ENDS at bar 10's line (t=38.589), which sits INSIDE the melody's 6.43 s
#    rest (35.375 -> 41.803) — the same phrase-gap rule every camera transition
#    in the long film obeys. The passage closes on a breath, not a cut.
# It is therefore self-contained: setup, arrival, and a rest to end on.
set -euo pipefail
D=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/04-moonlight-short
S=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/03-moonlight-long
R=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads
PY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
export DAW_CONTROL_PORT=17695          # ⛔ NEVER 17600 — that is the user's live app
export DAW_TIMEOUT_MS=${DAW_TIMEOUT_MS:-900000}
export MOON_BARS=9 MOON_OUTDIR="$D" MOON_ID=moonlight-short
# ⛔ THE DOLLY IS RE-SOLVED FOR THIS SPAN AND THIS FRAME. Inheriting the long
# cut's cameraFitExtra 2.20 put the portrait camera at back 10.75 / h 4.25 against
# the approved short-right1's 4.35 / 1.72 — the same "grey wedge" failure as the
# long film, in portrait, and the first render of this Short shipped it: the
# action occupied roughly the bottom sixth of a 1080x1920 frame. Read off the
# frame at t=20.6, not off a gate: framing passed at 2.20 too, because "in frame"
# and "worth looking at" are different questions.
# Laddered against framing.mjs at FRAMING_ALLOW=0 on THIS payload:
#   0.80 -> 134 offenders   1.00 -> 67   1.20 -> 27   1.40 -> 0   1.50 -> 0
# The threshold is between 1.20 and 1.40; 1.50 keeps the same ~+0.10 margin the
# long cut keeps over its own. back 6.84 / h 2.71 at 1.40.
export MOON_FIT_EXTRA=${MOON_FIT_EXTRA:-1.50}
mkdir -p "$D/out"
FMT=short

if [ "${PICTURE_ONLY:-0}" != 1 ]; then
  $PY "$S/song.py"
  node "$R/../tunes/lib/build.mjs" "$D/song.json" "$D/out"
  node "$R/../tunes/lib/gain.mjs"  "$D/song.json" "$D/out" -14
else
  # ⛔⛔ PICTURE_ONLY USED TO SKIP song.py ENTIRELY, AND THAT SHIPPED A STALE
  # song.json. Measured, on this very Short: a re-derived end-card caption and a
  # re-laddered cameraFitExtra were both edited, the build was re-run with
  # PICTURE_ONLY=1, it printed every pin green — and the film still carried the
  # OLD caption ("bars 1-42" on a nine-bar cut) and the OLD dolly. The note-count
  # pin cannot see it: a caption and a camera change no note counts.
  # ⭐ PICTURE_ONLY MEANS "DO NOT TOUCH THE DAW", NOT "DO NOT RE-DERIVE THE SONG".
  # So song.py runs, and the pin below then compares the FRESH song.json against
  # the audio that is already on disk — which is a strictly stronger check than
  # before, because it now also catches a picture-only edit that accidentally
  # moved a note.
  $PY "$S/song.py"
  $PY - "$D/song.json" "$D/out/build-facts.json" <<'PIN'
import json, sys
song = json.load(open(sys.argv[1])); facts = json.load(open(sys.argv[2]))
have = {t["name"]: t["notes"] for t in facts["tracks"]}
want = {t["name"]: len(t["notes"]) for t in song["tracks"] if t.get("road") or t.get("roadDrum")}
if have != want:
    sys.exit(f"PICTURE_ONLY refused: song.json {want} does not match the rendered audio {have}")
print(f"  [pin] PICTURE_ONLY: song.json notes match the rendered audio {have}")
PIN
fi
node "$R/lib/prep.mjs" "$D/song.json" --format "$FMT" --out "$D/out/payload.json"
SECS=$($PY -c "import json;print(json.load(open('$D/song.json'))['renderSeconds'])")
PSECS=$($PY -c "import json;print(json.load(open('$D/song.json'))['pictureSeconds'])")
node "$R/lib/marks.mjs" "$D/out/payload.json"
FRAMING_ALLOW=0 FRAMING_SECONDS="$PSECS" node "$R/lib/framing.mjs" "$D/out/payload.json"
node "$R/lib/reentry.mjs" "$D/out/payload.json" || [ $? = 2 ]
node "$R/lib/labels.mjs"  "$D/out/payload.json"
node "$R/lib/entry.mjs"   "$D/out/payload.json"
node "$R/lib/seam.mjs"    "$D/out/payload.json" || [ $? = 2 ]
node "$R/lib/ribbon.mjs"  "$D/out/payload.json"
rm -rf "$D/out/frames"
node "$R/lib/shoot.mjs" "$D/out/payload.json" "$D/out/frames" "$PSECS"
WANT=$($PY -c "import sys;print(int(round(float(sys.argv[1])*30)))" "$PSECS")
GOT=$(ls "$D/out/frames" | grep -c '^f[0-9]*\.png$')
if [ "$GOT" -lt "$WANT" ]; then echo "[FAIL] frames $GOT / $WANT expected" >&2; exit 2; fi
echo "  [pin] frames $GOT / $WANT expected (pictureSeconds $PSECS x 30)"
$PY "$R/lib/framegate.py" "$D/out/frames" "$D/out/payload.json"
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$D/out/frames/f%06d.png" \
  -vf setsar=1 -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 "$D/out/picture.mp4"
# ⚠ apad THEN -shortest, so the end card is not cut off with the audio. See 03's build.sh.
ffmpeg -hide_banner -loglevel error -y -i "$D/out/picture.mp4" -i "$D/out/music.wav" \
  -c:v copy -af "aresample=48000,aformat=channel_layouts=stereo,apad" -c:a aac -b:a 192k \
  -shortest "$D/out/moonlight-short.mp4"
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$D/out/moonlight-short.mp4")
$PY -c "
import sys; d=float(sys.argv[1]); w=float(sys.argv[2])
sys.exit(f'[FAIL] film {d}s is short of the {w}s asked for' if d < w - 0.5 else 0)" "$DUR" "$PSECS"
echo "  [pin] film duration ${DUR}s / ${PSECS}s asked for (music ${SECS}s + end card)"
# ⭐ A/V DRIFT. Every other gate here measures the PICTURE; this one decodes the
# film's own AUDIO and scores its onsets against the score. It is the only check
# whose failure mode GROWS WITH LENGTH, and it was missing from all three film
# builds while r4.sh ran it on a 14-second sample. Measured on the finished mux:
# long 94.1% matched / 2.4 ms drift, short 96.4% / 4.4 ms. Its own wrong-phase
# and random controls must fire or it reports BROKEN (exit 2).
# ⚠ THE LEAD IS DERIVED, NOT TYPED. `vizLagMs` is a standing open question in
# NOTES.md; a literal 0.0175 here would silently diverge from song.json the day
# it changes, and the gate would then measure the wrong thing while staying green.
LEAD=$($PY -c "import json,sys;print(json.load(open(sys.argv[1]))['vizLagMs']/1000.0)" "$D/song.json")
$PY "$R/../tunes/lib/sync.py" "$D/out/moonlight-short.mp4" "$D/song.json" --roads --lead "$LEAD"
echo "-> $D/out/moonlight-short.mp4"
