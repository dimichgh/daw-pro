#!/bin/bash
# MOONLIGHT, end to end. Absolute paths throughout.
set -euo pipefail
D=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/02-moonlight
R=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads
PY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
export DAW_CONTROL_PORT=17695          # ⛔ NEVER 17600 — that is the user's live app
FMT=${FMT:-landscape}
# ⭐ PICTURE_ONLY=1 re-renders the FILM from the audio that is already on disk.
# The re-entry fix and the camera fit are picture-side changes; re-cutting a take
# through the DAW to change nothing about the music would be churn on staging,
# and would re-mint every track/clip id in build-facts.json for no reason.
# ⚠ It is only correct while song.py's NOTES are unchanged — the pin below is
# what makes that a check rather than a hope.
# ⛔⛔ THE APPROVED FILM IN THIS DIRECTORY IS BARS 1-8 (song.json: lengthBeats 32,
# notes 10/96/26, total 34.303 s) BUT song.py:38 DEFAULTS TO MOON_BARS=20. A
# plain, non-PICTURE_ONLY rebuild here would therefore SILENTLY REPLACE the film
# the user approved (md5 8574075dfd3d92ed39c396fcd57af261) WITH A DIFFERENT,
# LONGER FILM, through the DAW, overwriting music.wav and every id in
# build-facts.json on the way. It was a live foot-gun in the one directory that
# must not be corrupted, so the span is PINNED HERE rather than noted somewhere.
# ⚠ It is pinned, not hard-coded: set MOON_BARS yourself to build another span
# deliberately, and this line will not fight you — but you cannot get one by
# forgetting.
export MOON_BARS="${MOON_BARS:-8}"
echo "  [pin] MOON_BARS=$MOON_BARS — the approved film in this directory is bars 1-8"
if [ "${PICTURE_ONLY:-0}" != 1 ]; then
  $PY "$D/song.py"
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
  $PY "$D/song.py"
  $PY - "$D/song.json" "$D/out/build-facts.json" <<'PIN'
import json, sys
song = json.load(open(sys.argv[1])); facts = json.load(open(sys.argv[2]))
have = {t["name"]: t["notes"] for t in facts["tracks"]}
want = {t["name"]: len(t["notes"]) for t in song["tracks"] if t.get("road") or t.get("roadDrum")}
if have != want:
    sys.exit(f"PICTURE_ONLY refused: song.json {want} does not match the rendered audio {have} — "
             "the music changed, so re-run without PICTURE_ONLY")
print(f"  [pin] PICTURE_ONLY: song.json notes match the rendered audio {have}")
PIN
fi
node "$R/lib/prep.mjs" "$D/song.json" --format "$FMT" --out "$D/out/payload.json"
node "$R/lib/marks.mjs" "$D/out/payload.json"
# ⭐ THE GATES THAT CARRY THIS ROUND'S TWO FIXES, IN THE PIPELINE RATHER THAN RUN
# BY HAND. framing at ALLOW=0 is the acceptance test cameraFitExtra was SOLVED
# against — at the default 4 % tolerance it passed the broken framing too.
FRAMING_ALLOW=0 node "$R/lib/framing.mjs" "$D/out/payload.json"
node "$R/lib/reentry.mjs" "$D/out/payload.json"
node "$R/lib/entry.mjs"   "$D/out/payload.json"
node "$R/lib/seam.mjs"    "$D/out/payload.json"
SECS=$($PY -c "import json;print(json.load(open('$D/song.json'))['renderSeconds'])")
rm -rf "$D/out/frames"
node "$R/lib/shoot.mjs" "$D/out/payload.json" "$D/out/frames" "$SECS"
# ⭐ THE FRAME PIN, same contract as lib/r4.sh: a truncated picture must not ship
# green. Derived from renderSeconds x 30, never from what happens to be there.
WANT=$($PY -c "import sys;print(int(round(float(sys.argv[1])*30)))" "$SECS")
GOT=$(ls "$D/out/frames" | grep -c '^f[0-9]*\.png$')
if [ "$GOT" -lt "$WANT" ]; then echo "[FAIL] frames $GOT / $WANT expected" >&2; exit 2; fi
echo "  [pin] frames $GOT / $WANT expected (renderSeconds $SECS x 30)"
# ⭐ STILLS == SEQUENCE. r4.sh has always run this; build.sh had not, and the
# repeating paper tile is a NEW init-time path that no determinism check had seen.
$PY "$R/lib/framegate.py" "$D/out/frames" "$D/out/payload.json"
ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$D/out/frames/f%06d.png" \
  -vf setsar=1 -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 "$D/out/picture.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$D/out/picture.mp4" -i "$D/out/music.wav" \
  -c:v copy -af "aresample=48000,aformat=channel_layouts=stereo" -c:a aac -b:a 192k \
  -shortest "$D/out/moonlight.mp4"
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$D/out/moonlight.mp4")
$PY -c "
import sys; d=float(sys.argv[1]); w=float(sys.argv[2])
sys.exit(f'[FAIL] film {d}s is short of the {w}s asked for' if d < w - 0.5 else 0)" "$DUR" "$SECS"
echo "  [pin] film duration ${DUR}s / ${SECS}s asked for"
echo "-> $D/out/moonlight.mp4"
