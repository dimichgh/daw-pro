#!/usr/bin/env bash
# ONE DISTINCT TAKE PER PLAY BEAT.
# (The count is whatever the TAKES table holds — a number written into a comment
# rots the moment a beat is added, and this one already had.)
#
# ⛔⛔ WHY: an independent observer found the film's eight burst beats were built
# from only TWO clips — the same 28 s of footage shown eight times. Two moments
# 187 s apart showed the same app clock (0:23.255 and 0:23.426). Cause, in
# assemble.py: `burst()` returns a cached clip per NAME and `play_audio()` always
# takes the first `playMax` seconds of the loop. Nothing compares one beat to
# another, so identical beats are the default, not an accident.
#
# The fix is upstream: give every beat its OWN recording, from a different
# position, view or piece — then the duplication cannot happen.
#
# ⛔ AND THE MASTER MUST NOT BE MUTED. The previous takes set master volume to 0
# so playback stayed silent for the user; the mixer then showed MASTER at -inf dB
# with a red clip on the bus and every channel metering — a dead master under
# audible music, visible in three places in the film. Instead the STAGING app's
# output is routed to BlackHole 2ch, so it plays at full level into a virtual
# device nobody hears.
# ⚠ Resolve BlackHole BY UID: its device id changes on every coreaudiod restart.
#
# ⚠ THE TAKES ARE WRITTEN STRAIGHT INTO bursts/<stage>/clip.mp4, NOT into a
# flat out/rec/. assemble.py looks for a burst at `<bursts>/<name>/` and a
# recording sitting anywhere else is SILENTLY IGNORED — the stage falls back to
# stills with no error, which is precisely how the frozen beats shipped.
set -euo pipefail
cd "$(dirname "$0")"
export DAW_CONTROL_PORT=17695 DAW_TIMEOUT_MS=900000
REC=../screenrec/screenrec

# ⛔⛔ HOLD THE DISPLAY AWAKE FOR THE WHOLE RUN. ScreenCaptureKit returns ZERO
# frames while the display is asleep — and it does so quietly: screenrec still
# reports the window it found, still writes an mp4, and the file is simply
# empty. On an unattended machine the display sleeps partway through a long
# session and every take after that point is a valid-looking file of nothing.
# `-d` keeps the display on, `-i` blocks idle sleep, `-u` declares user
# activity (which also WAKES a display that has already slept), and `-w $$`
# ties its lifetime to this script's, so nothing is left holding the machine
# awake if the run dies.
caffeinate -d -i -u -w $$ &
sleep 1
FILM="${FEATURES_HOME:-$(cd "$(dirname "$0")" && pwd)}"
BURSTS=$FILM/bursts
mkdir -p "$BURSTS"

# stage|project|view|seekBeats|clip (-1 = arrange view; otherwise an index or a
#                                     NAME substring matched against "Track / Clip")
#
# ⛔ THE PROJECT COLUMN MUST MATCH THE AUDIO THE STAGE PLAYS. `close` used to
# build `cosmic` while the stage plays fate-close.wav — the Beethoven variant,
# drums and all. The film would have shown tracks named Strings/Halo/Voice
# under a kick drum: picture contradicting narration, which is the single
# defect class the observer keeps finding.
#
# ⛔ AND THE BEAT MUST BE INSIDE THE PIECE. `close` also asked for beat 200 of a
# 160-beat render, where the transport simply stops. record-motion.mjs now
# measures that the playhead advances and refuses the take if it does not.
#
# ⭐⭐ `auto` MEANS "WHEREVER THE AUDIO FOR THIS STAGE WAS CUT FROM" — read out
# of loops/cuts.tsv, which cut-loops.sh writes. The film plays a 14 s excerpt
# under each beat; if the footage is from a different part of the arrangement,
# the transport on screen disagrees with the music in the viewer's ears. Both
# tables used to be maintained by hand and had drifted badly: `the-drop` played
# audio from 0:45 over a picture at 0:24, `whats-new` was 43 seconds out.
# Deriving it means they cannot come apart again.
# A number instead of `auto` is an explicit override — `kits` needs one because
# its audio is a rendered kit comparison, not a cut of the arrangement.
TAKES=(
  "open|machine-room|arrange|auto|-1"
  "whats-new|machine-room|mix|auto|-1"
  "drum-machine|machine-room|arrange|auto|Drums"
  # ⛔ `kits` HAS NO TAKE, DELIBERATELY. Its audio is three isolated kick hits
  # with digital silence between them — a rendered A/B demo, not a performance.
  # Footage of the full five-track arrangement rolling underneath is a different
  # performance entirely, and an observer caught exactly that. A still claims
  # nothing; motion here would claim something false.
  "effects|machine-room|mix|auto|-1"
  "build-one|machine-room|arrange|auto|-1"
  "the-drop|machine-room|arrange|auto|-1"
  "honest|machine-room|arrange|auto|Drums"
  "variants|mountain-king|arrange|auto|-1"
  "close|fate|arrange|auto|-1"
)

# The recorder starts this many seconds after the transport does, so seeking
# this much EARLIER puts the first recorded frame at the moment the excerpt
# begins.
#
# ⭐⭐ 1.825 IS THE MEASURED HANDSHAKE — and getting here took one wrong turn
# worth recording, because the shape of the mistake is general.
#
# First attempt set this to 1.92, reasoning: "an observer measured the nine play
# beats at mean -0.05, so the handshake is ~1.95, trim to 1.92." The form is
# right and the number was wrong, because THOSE RESIDUALS WERE TAKEN BEFORE THE
# ROUNDING FIX AND STILL CONTAINED ITS BIAS. `%.0f` had rounded eight stages UP
# (+0.125 s) and drum-machine DOWN (-0.125 s), so the -0.05 was really
# (H - 2.0 + 0.125), giving H = 1.825, not 1.95. Setting 1.92 therefore left
# every stage at 1.825 - 1.92 = -0.095, and the next pass measured exactly that
# mean. The correction to one defect was calibrated on data the defect had
# skewed.
#
# ⛔ A CONSTANT DERIVED FROM MEASUREMENTS TAKEN BEFORE A FIX INHERITS THE BIAS
# THAT FIX REMOVES. Re-derive it after, or subtract the bias explicitly.
#
# H measured 1.825 in BOTH runs (pass-2 net of the rounding bias: 1.707-1.872,
# mean 1.825; this run: 1.685-1.884, mean 1.8246). At 1.825 the nine residuals
# fall in -0.140..+0.059, mean ~0.000, none outside the +/-0.19 s bar.
LEAD_IN=1.825

# ⚠ `view` IS ONLY "arrange" OR "mix" — the wire rejects anything else
# (Commands.swift:8259). The piano roll is not a workspace; it opens when a clip
# is SELECTED, which is what the clip column does. Checked here so a typo costs
# a second rather than nine takes.
for spec in "${TAKES[@]}"; do
  IFS='|' read -r _ _ view _ _ <<< "$spec"
  case "$view" in arrange|mix) ;; *) echo "⛔ bad view '$view' in: $spec"; exit 1 ;; esac
done

# ⛔⛔ THE TABLE AND THE MANIFEST MUST NAME THE SAME SET.
# assemble.py looks for a burst at <bursts>/<stage["burst"]>/ and, finding
# nothing, falls through to a frozen still WITHOUT SAYING SO. That is how `kits`
# held one picture for 18 seconds and `honest` for 23 in the last cut. A take
# recorded under a name no stage claims is equally invisible — wasted minutes
# and a stage still frozen. Neither direction is allowed to pass quietly.
python3 - "$(printf '%s\n' "${TAKES[@]}" | cut -d'|' -f1)" <<'PYEOF'
import json, sys
takes = set(sys.argv[1].split())
man = json.load(open("manifest.json"))
want = {s["burst"] for s in man["stages"] if s.get("burst")}
# ⭐ A stage may opt OUT of motion by declaring `"stillsOnly": true` — but it
# has to SAY SO. Otherwise a stage that simply lost its recording is
# indistinguishable from one that was never meant to have one, which is how two
# stages shipped holding a single frame for eighteen and twenty-three seconds.
noburst = [s["id"] for s in man["stages"]
           if not s.get("burst") and not s.get("stillsOnly")]
if noburst:
    print(f"⛔ stages with NO burst and no `stillsOnly` flag: {noburst}")
if want - takes:
    print(f"⛔ manifest wants bursts nothing records: {sorted(want - takes)}")
if takes - want:
    print(f"⛔ takes no stage uses (recorded for nothing): {sorted(takes - want)}")
sys.exit(1 if (noburst or want ^ takes) else 0)
PYEOF
echo "✓ takes table and manifest name the same ${#TAKES[@]} beats"

# resolve_beats <stage> <project> — turn `auto` into a beat, from cuts.tsv.
# ⛔ FAILS LOUDLY rather than defaulting to 0: a take silently filmed from the
# top of the arrangement while its audio comes from the drop is exactly the
# picture/sound mismatch this is here to prevent.
CUTS=$FILM/loops/cuts.tsv
resolve_beats() {
  local stage="$1" proj="$2"
  [ -f "$CUTS" ] || { echo "⛔ no $CUTS — run cut-loops.sh first" >&2; exit 1; }
  python3 - "$stage" "$proj" "$CUTS" "$FILM/out/$proj/build.json" "$LEAD_IN" <<'PYEOF'
import json, sys
stage, proj, cuts, bj, lead = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5])
row = next((l.split("\t") for l in open(cuts).read().splitlines()
            if l.split("\t")[0] == stage), None)
if row is None:
    sys.exit(f"⛔ stage {stage!r} has no cut in {cuts} — give it an explicit beat "
             f"in the TAKES table instead of `auto`")
start = float(row[2])
try:
    tempo = json.load(open(bj))["tempo"]      # beats per minute, from the build itself
except FileNotFoundError:
    sys.exit(f"⛔ no {bj} — build {proj} before recording it")
beats = max(0.0, (start - lead) * tempo / 60.0)
# ⛔ FRACTIONAL, NOT ROUNDED. `%.0f` here silently threw away up to half a beat
# — 0.23 s at 128 BPM — of alignment, for nothing. `drum-machine` wanted beat
# 4.27 and got 4, which put its picture 0.125 s behind before anything else went
# wrong, and it was the one stage an observer measured outside the ±0.19 s band.
# positionBeats is a Double on the wire; there was never a reason to round.
print(f"{beats:.3f}")
PYEOF
}

# ⚠ OPTIONAL STAGE FILTER: `bash record-all.sh drum-machine` re-records only
# that take. Re-recording all ten because one cut point moved costs five minutes
# and re-rolls nine takes that were already correct.
ONLY=" $* "

CURRENT=""
for spec in "${TAKES[@]}"; do
  IFS='|' read -r stage proj view beats clip <<< "$spec"
  if [ $# -gt 0 ] && [[ "$ONLY" != *" $stage "* ]]; then continue; fi
  if [ "$beats" = "auto" ]; then
    beats=$(resolve_beats "$stage" "$proj") || exit 1
  fi
  if [ "$proj" != "$CURRENT" ]; then
    echo "--- building $proj ---"
    # ⚠ LOGGED, NOT DISCARDED. This was `>/dev/null 2>&1`: under `set -e` a
    # failed build aborted the run having printed nothing at all about why.
    mkdir -p "$BURSTS"
    if [ "$proj" = "cosmic" ]; then node cosmic.mjs > "$BURSTS/$proj.build.log" 2>&1
    else node build.mjs "$proj" --no-shots --no-render --no-motion > "$BURSTS/$proj.build.log" 2>&1; fi \
      || { echo "⛔ build of $proj FAILED:"; tail -20 "$BURSTS/$proj.build.log"; exit 1; }
    CURRENT="$proj"
  fi
  echo "recording $stage  ($proj / $view / beat $beats)"
  mkdir -p "$BURSTS/$stage"
  # ⚠ NOT SILENCED. A transport driver that dies leaves a static screen, and a
  # static screen records perfectly happily as a valid mp4 of nothing.
  node record-motion.mjs "$view" "$beats" 26 "$clip" > "$BURSTS/$stage/drive.log" 2>&1 &
  DRIVER=$!
  sleep 2
  # ⚠ LOGGED, NOT PIPED TO tail. Under pipefail a recorder failure aborts the
  # run with its diagnosis already discarded — the third instance of this exact
  # shape in this pipeline.
  $REC --app "DAWProStaging" --out "$BURSTS/$stage/clip.mp4" --seconds 22 --fps 30 \
    > "$BURSTS/$stage/rec.log" 2>&1 \
    || { echo "⛔ screen recorder FAILED for $stage:"; cat "$BURSTS/$stage/rec.log"; exit 1; }
  tail -1 "$BURSTS/$stage/rec.log"
  wait $DRIVER || { echo "⛔ transport driver FAILED for $stage:"; cat "$BURSTS/$stage/drive.log"; exit 1; }
done

echo "--- all ${#TAKES[@]} takes recorded ---"
echo "=== every take must be a DIFFERENT file ==="
md5 -q "$BURSTS"/*/clip.mp4 | sort | uniq -c | sort -rn | head -3
echo "(a count above 1 means two stages would show identical footage)"

echo "=== and every take must MOVE — frame-pair difference, with a static control ==="
# ⛔⛔ THIS REPLACES `freezedetect`, WHICH COULD NOT DO THE JOB HERE AND SAID SO
# ONLY IF YOU CALIBRATED IT. A DAW window is ~95% unchanging chrome, so the
# MEAN frame-to-frame difference is always tiny and freezedetect fired on every
# take at -60/-50 dB — including `whats-new`, whose meters are visibly dancing.
# Swept -60 dB through -30 dB: there is NO threshold at which real takes report
# clean and a deliberately-frozen clip reports frozen. It was pure noise, and a
# gate that cries wolf on every run is worse than no gate, because it teaches
# you to scroll past it.
#
# What discriminates: the PEAK pixel change between two frames 16 s apart.
# Measured — real takes 181-255, a frozen clip 3. A 60x separation, so the
# threshold is not delicately placed.
MOVED_MIN=40
ymax() {   # ymax <file> <t1> <t2>
  ffmpeg -hide_banner -loglevel error -y -ss "$2" -i "$1" -ss "$3" -i "$1" -frames:v 1 \
    -filter_complex "[0:v][1:v]blend=all_mode=difference,format=gray,signalstats,metadata=print:key=lavfi.signalstats.YMAX:file=-" \
    -f null - 2>/dev/null | grep -o "YMAX=[0-9.]*" | head -1 | cut -d= -f2
}
bad=0
for d in "$BURSTS"/*/; do
  s=$(basename "$d")
  [ -f "$d/clip.mp4" ] || continue
  y=$(ymax "$d/clip.mp4" 2 18); y=${y:-0}
  if [ "${y%.*}" -ge "$MOVED_MIN" ]; then printf "  %-14s moves (peak change %s)\n" "$s" "$y"
  else printf "  %-14s ⛔ STATIC (peak change %s < %s)\n" "$s" "$y" "$MOVED_MIN"; bad=$((bad+1)); fi
done
# ⭐ POSITIVE CONTROL: prove the probe can still fire, on a clip that IS frozen.
ffmpeg -hide_banner -loglevel error -y -i "$BURSTS/open/clip.mp4" -vf "select=eq(n\,0)" -frames:v 1 /tmp/_f.png
ffmpeg -hide_banner -loglevel error -y -loop 1 -i /tmp/_f.png -t 6 -r 30 -pix_fmt yuv420p /tmp/_frozen.mp4
c=$(ymax /tmp/_frozen.mp4 1 5); c=${c:-0}
printf "  %-14s peak change %s — MUST be < %s, or the probe above proves nothing\n" \
       "CONTROL frozen" "$c" "$MOVED_MIN"
[ "${c%.*}" -lt "$MOVED_MIN" ] || { echo "⛔ the control did not read as static — probe is not discriminating"; exit 1; }
[ "$bad" -eq 0 ] || { echo "⛔ $bad take(s) are static"; exit 1; }
