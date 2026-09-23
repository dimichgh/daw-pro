#!/bin/bash
# A Short that LOOPS — built from the `*-loop-master.wav` cut by make-loop.py.
#
# ⛔⛔ NO OUTRO CARD ON A LOOPING SHORT, AND THAT IS THE WHOLE POINT.
# The house convention (make-viz.sh) concatenates `viz-outro-port.mp4` onto every
# Short. That card is 2.4 seconds of DIGITAL SILENCE — measured at -inf dBFS, not
# "quiet". A Short replays the instant it ends, so the shipped ones loop as
# [music] -> [2.4 s of nothing] -> [music], and no amount of musical care at the
# join survives that. The brand the card carried goes into the frame instead,
# where a looping viewer actually sees it rather than waiting out a tail.
#
# ⭐ AND THE TITLE LOSES "· long". The piece is named `Starlight · Ascent · long`
# because it IS the long-form cut; the Short inherited that verbatim and burned
# "· long … #Shorts" into the picture. Fixed on YouTube already; this fixes it in
# the pixels, which is the copy that cannot be edited after upload.
set -euo pipefail
D="${FEATURES_HOME:-$(cd "$(dirname "$0")" && pwd)}"
BPY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
PY=$D/viz/.venv/bin/python3
[ -x "$PY" ] || PY=python3
J() { python3 -c "import json,sys;print(json.load(open('$1'))['$2'])"; }

# ⭐ KIND selects WHICH one-minute cut to film, because there are now two
# kinds and they solve the replay join in opposite ways:
#   loop     — make-loop.py, 16 bars, harmony closes, tail wrapped across the
#              join so it repeats forever with no seam.
#   handover — make-handover-short.py, 16 bars centred on a MEASURED changeover,
#              which by definition does NOT end where it began, so instead of
#              wrapping it fades to digital silence at both ends.
# Both are card-less: the portrait outro is 2.4 s of -inf dBFS that a replaying
# Short plays straight through. The brand goes in-frame.
KIND="${KIND:-loop}"
PIECES="cosmic-ascent-5m cosmic-heartbeat-5m cosmic-aurora-5m cosmic-signal-5m cosmic-collapse-5m
        cosmic-forces cosmic-forces-apart cosmic-forces-crossing"
WANT=" $* "

for v in $PIECES; do
  if [ $# -gt 0 ] && [[ "$WANT" != *" $v "* ]]; then continue; fi
  B=$D/out/$v/build.json
  W=$D/out/$v/$v-$KIND-master.wav
  [ -f "$W" ] || { echo "SKIP $v — no $KIND master (run make-loop.py / make-handover-short.py, then master-loop.py)"; continue; }

  T=$(J "$B" title); S=$(J "$B" subtitle)
  T="${T% · long}"                       # see the header
  DUR=$($BPY -c "import soundfile as sf;i=sf.info('$W');print(f'{i.frames/i.samplerate:.4f}')")
  echo "=== $v — $T   (${DUR}s, $KIND) ==="

  $PY $D/viz/viz.py --input "$W" --output "$D/out/$v/video/_$v-$KIND.mp4" \
      --format short --start 0 --duration "$DUR" --title "$T" --subtitle "$S"

  # brand mark, drawn with Pillow because this ffmpeg has no drawtext (no
  # libfreetype) — checked, not assumed: `ffmpeg -filters | grep drawtext` is empty.
  BADGE=$D/out/$v/video/_badge.png
  $BPY - "$BADGE" <<'PYEOF'
import sys
from PIL import Image, ImageDraw, ImageFont
W, H = 1080, 1920
img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
def font(paths, size):
    for p in paths:
        try: return ImageFont.truetype(p, size)
        except Exception: pass
    return ImageFont.load_default()
f1 = font(["/System/Library/Fonts/Supplemental/Arial.ttf",
           "/System/Library/Fonts/Helvetica.ttc"], 30)
f2 = font(["/System/Library/Fonts/Supplemental/Arial.ttf",
           "/System/Library/Fonts/Helvetica.ttc"], 21)
# letterspaced wordmark, matching the outro card's treatment
def spaced(draw, y, text, f, fill, track):
    wds = [draw.textlength(c, font=f) + track for c in text]
    x = (W - (sum(wds) - track)) / 2
    for c, adv in zip(text, wds):
        draw.text((x, y), c, font=f, fill=fill); x += adv
spaced(d, 1760, "DAW PRO", f1, (233, 238, 245, 224), 7)
spaced(d, 1802, "© 2026", f2, (150, 162, 178, 176), 3)
img.save(sys.argv[1])
PYEOF

  ffmpeg -nostdin -v error -i "$D/out/$v/video/_$v-$KIND.mp4" -i "$BADGE" \
    -filter_complex "[0][1]overlay=0:0:format=auto" \
    -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 320k -movflags +faststart \
    -y "$D/out/$v/video/$v-${KIND}short.mp4"

  rm -f "$D/out/$v/video/_$v-$KIND.mp4" "$BADGE"
  echo "    -> out/$v/video/$v-${KIND}short.mp4"
done
