#!/bin/bash
# A LADDER: the same 13.8 s clip, rendered N times, varying ONE axis.
# Their pick IS the feedback, so every rung differs on one thing and is NAMED
# BY ITS REAL PARAMETER VALUES -- "A/B/C" would throw away the answer.
#
# ⭐ THIS NEVER TOUCHES THE DAW. out/music.wav is already rendered and
# gain-steered, so a look change costs frames + ffmpeg and nothing else.
# Staging 17695 is not contacted; 17600 is not contacted.
set -euo pipefail
D=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/00-sample
R=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads
PY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
LAD="$D/out/ladder"

SECS=$($PY -c "import json;print(json.load(open('$D/song.json'))['renderSeconds'])")
LEAD=$($PY -c "import json;print(json.load(open('$D/song.json'))['vizLagMs']/1000.0)")

name="$1"; look="$2"
V="$LAD/$name"
mkdir -p "$V"
echo "=== rung $name  $look"
node "$R/lib/look.mjs" "$D/out/payload.json" "$V/payload.json" "$look"
node "$R/lib/marks.mjs" "$V/payload.json"
rm -rf "$V/frames"
node "$R/lib/shoot.mjs" "$V/payload.json" "$V/frames" "$SECS"

ffmpeg -hide_banner -loglevel error -y -framerate 30 -i "$V/frames/f%06d.png" \
  -vf setsar=1 -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -r 30 "$V/picture.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$V/picture.mp4" -i "$D/out/music.wav" \
  -c:v copy -af "aresample=48000,aformat=channel_layouts=stereo" -c:a aac -b:a 192k \
  -shortest "$V/$name.mp4"

# the gate that outranks every look decision: the ball must LAND on the onset
$PY "$R/../tunes/lib/sync.py" "$V/$name.mp4" "$D/song.json" --road-only --lead "$LEAD"

# stills for judging, pulled from the FINISHED file (not from the frame dir)
mkdir -p "$V/check"
for t in 2.00 6.60 11.20 12.90; do
  ffmpeg -hide_banner -loglevel error -y -ss "$t" -i "$V/$name.mp4" -frames:v 1 "$V/check/f$t.png"
done
rm -rf "$V/frames" "$V/picture.mp4"
echo "rung $name done -> $V/$name.mp4"
