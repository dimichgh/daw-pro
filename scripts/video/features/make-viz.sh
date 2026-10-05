#!/bin/bash
# Long + short visualiser for every piece, BRANDED.
# Titles/subtitles come from each build.json, so a piece cannot be captioned as
# another one.
#
# ⚠ THE SHORT WINDOW IS PER-PIECE AND IT MATTERS. A Short has to hook in the
# first second and end on a payoff, so the window is chosen to CONTAIN the
# climax rather than to start at a round number.
#
# ⛔ OUTRO, NO INTRO, ON SHORTS. House convention from scripts/video/shorts/: a
# Short cannot afford three seconds of card before the hook. Long visualisers
# get both cards, like lessons/ and series/.
#
# ⛔⛔ THE BRANDING IS IN THIS SCRIPT NOW, AND THAT IS THE FIX.
# viz.py does not attach cards at all — last time they were concatenated by an
# ad-hoc command typed once, which is exactly how six visualisers shipped an
# outro reading "Narration is a synthetic voice" over videos containing no
# speech whatsoever. A step that lives only in someone's shell history is a
# step that gets forgotten or done wrong. It lives here, and it passes
# --no-disclaimer, because NONE of these files is narrated.
set -euo pipefail
D="${FEATURES_HOME:-$(cd "$(dirname "$0")" && pwd)}"
SK=/Users/dsemenov/Views/daw-pro/claude-plugin/skills/demo-film
# ⚠ THE PLUGIN VENV — the system python3 has no Pillow, and that failure looks
# exactly like a missing package rather than a wrong interpreter.
BPY=/Users/dsemenov/Views/daw-pro/plugins/narrated-film/.venv/bin/python
[ -x "$BPY" ] || { echo "no plugin venv python at $BPY"; exit 1; }
PY=$D/viz/.venv/bin/python3
[ -x "$PY" ] || PY=python3
J() { python3 -c "import json,sys;print(json.load(open('$1'))['$2'])"; }

mkdir -p "$D/out/brand"

# --- the cards, built ONCE and reused -----------------------------------
# ⚠ --no-disclaimer on every one: these are instrumental pieces.
if [ ! -f "$D/out/brand/viz-outro-land.mp4" ]; then
  $BPY "$SK/scripts/brand.py" outro --brand "$SK/brand.json" --theme features \
      --size 1920x1080 --seconds 5 --out "$D/out/brand/viz-outro-land.mp4" --no-disclaimer
fi
if [ ! -f "$D/out/brand/viz-outro-port.mp4" ]; then
  $BPY "$SK/scripts/brand.py" outro --brand "$SK/brand.json" --theme features \
      --size 1080x1920 --seconds 2.4 --out "$D/out/brand/viz-outro-port.mp4" --no-disclaimer
fi
if [ ! -f "$D/out/brand/viz-intro-land.mp4" ]; then
  $BPY "$SK/scripts/brand.py" intro --brand "$SK/brand.json" --theme features \
      --size 1920x1080 --seconds 3 --out "$D/out/brand/viz-intro-land.mp4"
fi

# join <out.mp4> <part...> — re-encode rather than concat-copy, because the
# cards and the visualiser do not share an encoder configuration and a
# stream-copy concat of mismatched SPS/PPS plays as garbage in some players.
join() {
  local out="$1"; shift
  local lst; lst=$(mktemp /tmp/joinXXXX.txt)
  for p in "$@"; do echo "file '$p'" >> "$lst"; done
  ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$lst" \
    -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p \
    -c:a aac -b:a 192k -ac 2 -ar 48000 "$out"
  rm -f "$lst"
}

# piece:shortStart:shortDuration
#   the DJ variants   84 s  Build 2 into Drop 2 — the busiest 36 seconds
#   cosmic short      82 s  end of Theme through the peak of Wide
#   cosmic long      240 s  the ARRIVAL of the Rise, not its start
#
# ⚠ 240 IS MEASURED, NOT ROUND. The Rise runs bars 56-71 = 213-274 s, and the
# filter only reaches full open (resonance 0.0, the Butterworth the user called
# "power, like something is raising") at ~273 s. A window starting at 196 opens
# before the climb and ends at 232 — three quarters of the way up, cutting away
# the exact moment it is there to show. 240 + 36 ends at 276: on the payoff.
#
# ⭐ THE FIVE DEVELOPED PIECES (develop.mjs, 2026-09-21). Each window is computed
# from that piece's OWN form table so it ENDS on the arrival, and each tempo is
# different, so none of these numbers can be copied from a neighbour:
#   ascent    63 BPM, Ascent = bars 36-51 = 137-198 s -> 162 ends on 198
#   heartbeat 63 BPM, same form, and 162-198 is where the pulse DOUBLES
#   aurora    72 BPM, Corona = bars 40-55 = 133-187 s -> 151 ends on 187
#   signal    66 BPM, Ascent = bars 36-51 = 131-189 s -> 153 ends on 189
#   collapse  52 BPM — THE EXCEPTION, AND DELIBERATELY NOT A CLIMAX WINDOW.
#             This piece starts at full power and falls, so there is no arrival
#             to end on. 24-60 s spans the last third of Arrival into Cooling:
#             the Short opens bright and goes dark, which IS the piece.
# ⭐⭐ THE FIVE-MINUTE CUTS (develop.mjs `*5` forms, 2026-09-21). ⛔ THESE NUMBERS
# COULD NOT BE COPIED FROM THE 3½-MINUTE PIECE OF THE SAME NAME. Every one of
# these forms adds a second wave, so the climax moved from bar 36 to bar 60+ AND
# the bar it moved to is a different number of seconds away at each tempo:
# ⛔⛔ THESE WERE WRONG ONCE ALREADY AND THE REASON IS WORTH KEEPING: they were
# computed against the round-2 form tables, and round 3 lengthened three arrival
# sections (Summit 14->16, Aurora 18->24, Return 20->24). The windows still LANDED
# inside the arrival, so every video looked fine and nothing failed — which is
# exactly why nobody caught it. ⭐ A WINDOW THAT LANDS IS NOT A WINDOW THAT WAS
# COMPUTED: re-derive these from build.json whenever a form changes.
#   bar_seconds = 4 x 60 / tempo; start_bar = sum of the bars BEFORE the arrival.
#   ascent-5m    63 BPM (3.810 s/bar), Summit = bars 60-76 = 228.6-289.5 s
#                -> 253 ends on 289, the last bar of the only full-open section
#   heartbeat-5m 63 BPM, same form, and 253-289 is where the pulse DOUBLES
#                after a full minute with NO pulse at all (Drift)
#   aurora-5m    72 BPM (3.333 s/bar), Aurora = bars 60-84 = 200.0-280.0 s
#                -> 244 ends on 280, exactly the last bar (this one was already right)
#   signal-5m    66 BPM (3.636 s/bar), Return = bars 52-76 = 189.1-276.4 s
#                -> 240 ends on 276, the doubled pulse plus the top of the climb
# ⚠ THE SHORTS ALREADY ON THE CHANNEL WERE CUT AT THE OLD WINDOWS (ascent and
# heartbeat at 246, signal at 238). Re-running this script now produces a
# DIFFERENT 36 seconds for those three. That is not a defect to "fix" by
# re-uploading — it would leave duplicates on the channel, and the old windows
# land inside the same arrival section anyway (246-282 sits wholly within
# Summit's 228.6-289.5). The numbers above are right for the NEXT build.
#   collapse-5m  52 BPM — STILL AN EXCEPTION, BUT NOT THE SAME ONE. The 3½-minute
#                Collapse had no arrival to end on; the long one DOES — `Rekindle`
#                (bars 40-48 = 185-222 s) is the false recovery, the brightest
#                thing after the first minute. 186 ends on 222, the moment it
#                starts to go out again.
# ⭐ THE THREE ENERGIES (forces.mjs, 2026-09-22). All three are 63 BPM / 80 bars
# / 304.8 s, but the arrival section sits at a DIFFERENT bar in each because the
# whole point of the set is how long the handovers take — so one window does NOT
# serve all three. Arrival = `Consciousness`, the last and biggest of the three;
# derived from build.json, ending on its final bar per the rule above:
#   forces    Consciousness = bars 48-64 = 182.9-243.8 s -> 208 ends on 243.8
#   apart     Consciousness = bars 60-74 = 228.6-281.9 s -> 246 ends on 281.9
#   crossing  Consciousness = bars 54-66 = 205.7-251.4 s -> 215 ends on 251.4
PIECES="machine-room:84:36 mountain-king:84:36 fate:84:36
        cosmic-forces:208:36 cosmic-forces-apart:246:36
        cosmic-forces-crossing:215:36
        cosmic-a:82:36 cosmic-b:82:36 cosmic-c:82:36 cosmic-d:82:36
        cosmic-b-long:240:36 cosmic-d-long:240:36
        cosmic-ascent:162:36 cosmic-collapse:24:36 cosmic-heartbeat:162:36
        cosmic-aurora:151:36 cosmic-signal:153:36
        cosmic-ascent-5m:253:36 cosmic-collapse-5m:186:36
        cosmic-heartbeat-5m:253:36 cosmic-aurora-5m:244:36
        cosmic-signal-5m:240:36"

# ⚠ OPTIONAL PIECE FILTER: `bash make-viz.sh cosmic-a cosmic-b` rebuilds only
# those. Without it, changing one caption meant re-encoding all eighteen videos
# — or hand-editing this file, which is how a sed against the multi-line PIECES
# string left `cosmic-a:82:36: command not found` behind.
WANT=" $* "
for spec in $PIECES; do
  v="${spec%%:*}"; rest="${spec#*:}"; ss="${rest%%:*}"; dd="${rest#*:}"
  if [ $# -gt 0 ] && [[ "$WANT" != *" $v "* ]]; then continue; fi
  B=$D/out/$v/build.json
  [ -f "$B" ] || { echo "SKIP $v — no build.json"; continue; }
  T=$(J "$B" title); S=$(J "$B" subtitle); W=$(J "$B" wav)
  # ⭐ PREFER THE MASTERED FILE. The raw cosmic renders measured as low as
  # -29.1 LUFS; master-cosmic.sh levels them to -18 and to EACH OTHER.
  M="${W%.wav}-master.wav"
  [ -f "$M" ] && W="$M"
  [ -f "$W" ] || { echo "SKIP $v — no wav at $W"; continue; }
  mkdir -p "$D/out/$v/video"
  echo "=== $v — $T / $S   [$(basename "$W")] ==="

  $PY $D/viz/viz.py --input "$W" --output "$D/out/$v/video/_$v-long.mp4" \
      --format long --title "$T" --subtitle "$S"
  join "$D/out/$v/video/$v-long.mp4" \
       "$D/out/brand/viz-intro-land.mp4" \
       "$D/out/$v/video/_$v-long.mp4" \
       "$D/out/brand/viz-outro-land.mp4"

  $PY $D/viz/viz.py --input "$W" --output "$D/out/$v/video/_$v-short.mp4" \
      --format short --start "$ss" --duration "$dd" --title "$T" --subtitle "$S"
  join "$D/out/$v/video/$v-short.mp4" \
       "$D/out/$v/video/_$v-short.mp4" \
       "$D/out/brand/viz-outro-port.mp4"

  rm -f "$D/out/$v/video/_$v-long.mp4" "$D/out/$v/video/_$v-short.mp4"
done
