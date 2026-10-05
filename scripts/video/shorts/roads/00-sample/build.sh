#!/bin/bash
# THE TUNING SAMPLE, end to end. Absolute paths throughout: a relative path sent
# over the wire is resolved by the APP, not by this script, and comes back `ok`.
set -euo pipefail
D=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/00-sample
R=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads
PY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
export DAW_CONTROL_PORT=17695          # ⛔ NEVER 17600 — that is the user's live app

$PY "$D/song.py"                                   # -> song.json
node "$R/../tunes/lib/build.mjs" "$D/song.json" "$D/out"        # staging: tracks + music.wav
node "$R/../tunes/lib/gain.mjs"  "$D/song.json" "$D/out" -14    # steer the master gain
node "$R/lib/prep.mjs" "$D/song.json"                           # -> out/payload.json
node "$R/lib/marks.mjs" "$D/out/payload.json"   # payload-level mapping check
node "$R/lib/paperpix.mjs" "$D/out/payload.json" "$D/out/paperpix"   # ⛔ ink under the ball
node "$R/lib/roadpix.mjs"  "$D/out/payload.json" "$D/out/roadpix"    # ⛔ trail + road identity

# Both of these MUST come from song.json, never from a literal: a hardcoded lead
# that happens to equal vizLagMs makes the sync gate pass by coincidence, and it
# keeps passing after you change the lag. Measured trap, not a hypothetical.
SECS=$($PY -c "import json;print(json.load(open('$D/song.json'))['renderSeconds'])")
LEAD=$($PY -c "import json;print(json.load(open('$D/song.json'))['vizLagMs']/1000.0)")
echo "build.sh: renderSeconds=$SECS  lead=$LEAD  (both read from song.json)"
rm -rf "$D/out/frames"
node "$R/lib/shoot.mjs" "$D/out/payload.json" "$D/out/frames" "$SECS"   # three.js, 414 PNGs at 13.8 s

ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$D/out/frames/f%06d.png" \
  -vf setsar=1 -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 "$D/out/picture.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$D/out/picture.mp4" -i "$D/out/music.wav" \
  -c:v copy -af "aresample=48000,aformat=channel_layouts=stereo" -c:a aac -b:a 192k \
  -shortest "$D/out/sample-nometer.mp4"
$PY /Users/dsemenov/Views/daw-pro/scripts/video/meter.py \
  "$D/out/sample-nometer.mp4" "$D/out/sample.mp4" --work "$D/out/seg" --corner br --start 0 --short

# gates
$PY /Users/dsemenov/Views/daw-pro/plugins/narrated-film/scripts/verify.py \
  --film "$D/out/sample.mp4" --manifest "$D/out/manifest.json"
$PY "$R/../tunes/lib/sync.py" "$D/out/sample.mp4" "$D/song.json" --roads --lead "$LEAD"
# ⭐ the control that makes the line above mean something: another song's score
$PY "$R/../tunes/lib/sync.py" "$D/out/sample.mp4" "$R/01-lantern/song.json" --roads || true
