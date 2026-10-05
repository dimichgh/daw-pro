#!/usr/bin/env bash
# m31-f — "does this instrument have more than one timbre?"
#
# WHY THIS EXISTS. A user listened to an M31 dogfood render and said the sax
# "sounded awful, like a toy instrument". No gate in this tree can hear, and
# three full cycles of green tests had said nothing. But the specific thing that
# makes a sampled instrument read as a toy IS measurable: on a real acoustic
# instrument, playing harder changes the SPECTRUM as well as the level — a
# saxophone leaned on throws far more upper-harmonic energy, and its spectral
# centroid roughly doubles from pp to ff. A single-sample instrument just gets
# louder. Loudness moves; timbre does not.
#
# So this probe takes a VELOCITY LADDER — the same pitch played at several
# velocities — and reports how far the CENTROID moved against how far the RMS
# moved. A large RMS spread with a flat centroid is the signature.
#
# WHAT IT CANNOT DO, stated plainly so nobody over-reads it: this measures
# LIVELINESS, not quality. It cannot tell you an instrument is out of tune, is
# the wrong articulation, or is simply ugly-but-dynamic. Taste is not on the
# wire. Deadness is.
#
# USAGE
#   scripts/probes/timbre-liveness.sh <ladder.wav> [noteStartSeconds...]
#
#   The WAV must contain N notes of the SAME pitch at ASCENDING velocities,
#   each 1 s long, starting on even seconds by default (0 2 4 6). Render one
#   with render_bounce over a clip built by the recipe in the header of
#   docs/dogfood/2026-08-24-session-2.md (m31-f).
#
# TWO TRAPS THIS SCRIPT EXISTS TO ENCODE, both of which cost real time:
#
#   1. `aspectralstats` writes to FRAME METADATA, not to the log. Without
#      `,ametadata=mode=print` every reading comes back EMPTY — and an empty
#      reading looks exactly like "this instrument produced no signal", which is
#      the opposite of the truth. (This tree's standing rule: never interpret the
#      emptiness of a command you have not positive-controlled.)
#   2. fish does NOT word-split `set -- $var`. This file is bash on purpose;
#      run it as a script, never by pasting its body into the shell.
#
# The script positive-controls ITSELF: it measures a synthesised 440 Hz and a
# 1760 Hz sine before touching your file, and ABORTS if the metric fails to tell
# them apart. A flat result is only evidence when the meter is known to move.

set -uo pipefail

WAV="${1:-}"
if [[ -z "$WAV" || ! -f "$WAV" ]]; then
  echo "usage: $0 <ladder.wav> [noteStartSeconds ...]" >&2
  exit 2
fi
shift || true
STARTS=("$@")
[[ ${#STARTS[@]} -eq 0 ]] && STARTS=(0 2 4 6)

FF="$(command -v ffmpeg || true)"
[[ -z "$FF" ]] && { echo "ffmpeg not found" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# mean spectral centroid over a window, in Hz. Empty -> "NA", never a silent 0.
centroid() { # $1=file $2=start $3=dur
  "$FF" -hide_banner -nostats -ss "$2" -t "$3" -i "$1" \
    -af "aspectralstats=measure=centroid,ametadata=mode=print" -f null - 2>&1 \
  | grep -oE '\.1\.centroid=[0-9.]+' | cut -d= -f2 \
  | awk '{s+=$1;n++} END{ if(n) printf "%.1f", s/n; else print "NA" }'
}

rms_db() { # $1=file $2=start $3=dur
  "$FF" -hide_banner -nostats -ss "$2" -t "$3" -i "$1" \
    -af "astats=metadata=1:reset=0" -f null - 2>&1 \
  | grep "RMS level dB:" | head -1 | sed 's/.*: //' \
  | awk '{ if($1=="") print "NA"; else printf "%.1f", $1 }'
}

# ---- SELF POSITIVE-CONTROL -------------------------------------------------
# A flat centroid across velocities is exactly the shape a BROKEN measurement
# produces. Prove the meter can move before believing that it did not.
"$FF" -hide_banner -loglevel error -y -f lavfi -i "sine=f=440:d=2"  -c:a pcm_f32le "$TMP/c440.wav"
"$FF" -hide_banner -loglevel error -y -f lavfi -i "sine=f=1760:d=2" -c:a pcm_f32le "$TMP/c1760.wav"
LO="$(centroid "$TMP/c440.wav" 0.3 1.0)"
HI="$(centroid "$TMP/c1760.wav" 0.3 1.0)"
if [[ "$LO" == "NA" || "$HI" == "NA" ]] || \
   ! awk -v a="$LO" -v b="$HI" 'BEGIN{exit !(b > a*2)}'; then
  echo "ABORT: the centroid meter failed its own positive control (440->$LO Hz, 1760->$HI Hz)." >&2
  echo "       A reading from a meter that cannot discriminate is not evidence." >&2
  exit 3
fi
printf 'positive control OK   440 Hz -> %s Hz   1760 Hz -> %s Hz\n\n' "$LO" "$HI"

# ---- THE LADDER ------------------------------------------------------------
printf '%-10s %-14s %-14s\n' "note" "RMS (dB)" "centroid (Hz)"
CMIN=""; CMAX=""; RMIN=""; RMAX=""
i=0
for s in "${STARTS[@]}"; do
  i=$((i+1))
  c="$(centroid "$WAV" "$(awk -v x="$s" 'BEGIN{printf "%.2f", x+0.30}')" 0.60)"
  r="$(rms_db  "$WAV" "$(awk -v x="$s" 'BEGIN{printf "%.2f", x+0.30}')" 0.60)"
  printf '%-10s %-14s %-14s\n' "#$i" "$r" "$c"
  [[ "$c" == "NA" || "$r" == "NA" ]] && continue
  if [[ -z "$CMIN" ]]; then CMIN=$c; CMAX=$c; RMIN=$r; RMAX=$r; fi
  awk -v a="$c" -v b="$CMIN" 'BEGIN{exit !(a<b)}' && CMIN=$c
  awk -v a="$c" -v b="$CMAX" 'BEGIN{exit !(a>b)}' && CMAX=$c
  awk -v a="$r" -v b="$RMIN" 'BEGIN{exit !(a<b)}' && RMIN=$r
  awk -v a="$r" -v b="$RMAX" 'BEGIN{exit !(a>b)}' && RMAX=$r
done

[[ -z "${CMIN:-}" ]] && { echo "no usable readings — check the note start times" >&2; exit 4; }

echo
awk -v cmin="$CMIN" -v cmax="$CMAX" -v rmin="$RMIN" -v rmax="$RMAX" '
BEGIN{
  rspread = rmax - rmin;
  cspread_pct = (cmin > 0) ? (cmax - cmin) / cmin * 100.0 : 0;
  printf "RMS spread       %.1f dB   (%.1f .. %.1f)\n", rspread, rmin, rmax;
  printf "centroid spread  %.2f %%    (%.1f .. %.1f Hz)\n", cspread_pct, cmin, cmax;
  printf "\n";
  if (rspread < 6) {
    print "INCONCLUSIVE: the velocities barely changed the level, so this ladder";
    print "does not test what it claims. Check the notes really differ in velocity.";
    exit 0;
  }
  if (cspread_pct < 5) {
    printf "VERDICT: STATIC. %.1f dB of level movement and only %.2f %% of timbre movement.\n", rspread, cspread_pct;
    print "This instrument has effectively ONE timbre; velocity is a volume knob.";
    print "It will read as lifeless on any exposed melodic part. Prefer a bank with";
    print "real velocity layers for leads and solos.";
  } else {
    printf "VERDICT: LIVE. %.2f %% centroid movement across %.1f dB of level.\n", cspread_pct, rspread;
    print "Velocity changes the tone, not just the volume.";
  }
  print "";
  print "NOTE: this measures LIVELINESS, not quality. It says nothing about tuning,";
  print "articulation, or whether the sound is pleasant. Those still need a human.";
  print "";
  print "READ THE TABLE, NOT JUST THE PERCENTAGE. The spread is min-to-max, which is a";
  print "CRUDE summary: a bank with discrete velocity layers steps between PLATEAUS";
  print "rather than sliding, and the steps need not be monotonic (a soft layer can be";
  print "brighter than the one above it). Two rows sharing a centroid means they share";
  print "a layer. Counting the distinct plateaus tells you the layer count; the";
  print "percentage only tells you the range is non-zero.";
}'
