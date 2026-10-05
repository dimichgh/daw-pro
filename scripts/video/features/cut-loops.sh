#!/usr/bin/env bash
# ONE AUDIO EXCERPT PER STAGE, EACH FROM A DIFFERENT PART OF THE MUSIC.
#
# ⛔⛔ WHY: an observer found the film's play beats were duplicates. Three
# stages named `mr-intro.wav` and two named `mr-build2.wav`, and `play_audio()`
# always takes the FIRST `playMax` seconds of whatever it is given — so those
# stages played byte-identical audio under captions describing different things.
# Nothing in the pipeline compared one stage's audio to another's, so identical
# was the default rather than an accident.
#
# The fix is upstream of the assembler: every stage gets its OWN file, cut from
# its OWN place in the arrangement. Then no offset logic can collapse them.
#
# ⚠ 128 BPM throughout, so beat b starts at b * 60 / 128 = b * 0.46875 s.
#   bar 8 = beat 32 = 15 s   | bar 32 = beat 128 = 60 s
#   bar 16 = beat 64 = 30 s  | bar 40 = beat 160 = 75 s
#   bar 24 = beat 96 = 45 s  | bar 48 = beat 192 = 90 s
set -euo pipefail
F="${FEATURES_HOME:-$(cd "$(dirname "$0")" && pwd)}"
OUT=$F/loops
mkdir -p "$OUT"

# ⭐⭐ EVERY CUT IS RECORDED IN cuts.json, AND THAT IS WHAT KEEPS THE PICTURE
# HONEST. record-all.sh derives each take's seek position FROM these offsets, so
# the app on screen is playing the same bar the viewer is hearing. Before this,
# the two tables drifted independently: `the-drop` played audio from 0:45 while
# the footage showed the transport at 0:24, and `whats-new` was 43 seconds out.
# Nothing detects that but a musician watching the finished film.
: > "$OUT/cuts.tsv"

cut() {   # cut <src.wav> <start> <len> <dest> <stage>
  local src="$1" start="$2" len="$3" dest="$4" stage="${5:-}"
  [ -f "$src" ] || { echo "MISSING SOURCE: $src" >&2; exit 1; }
  ffmpeg -hide_banner -loglevel error -y -ss "$start" -t "$len" -i "$src" \
    -af "afade=t=in:st=0:d=0.05,afade=t=out:st=$(echo "$len - 0.4" | bc):d=0.4" \
    -c:a pcm_s16le "$OUT/$dest"
  [ -n "$stage" ] && printf "%s\t%s\t%s\n" "$stage" "$dest" "$start" >> "$OUT/cuts.tsv"
}

MR=$F/out/machine-room/machine-room.wav
MK=$F/out/mountain-king/mountain-king.wav
FA=$F/out/fate/fate.wav

# stage          source  from  len  file                  what the listener hears
cut "$MR" 30 14 mr-open.wav      open         # Drop        — the full thing, first time
cut "$MR" 90 14 mr-whatsnew.wav  whats-new    # Drop 2      — the biggest section
# ⛔ 4 s, NOT 0 s, AND THE REASON IS THE CAMERA. A take seeks to
# (cutStart - LEAD_IN) so the first recorded frame lands on the excerpt's first
# sample. At cutStart 0 that clamps to beat 0 — there is nothing before the
# start of the song to seek to — so the picture ran 1.67 s AHEAD of the audio
# here while every other stage sat within 0.19 s. (Measured by an independent
# observer, cross-correlating film audio against the render and reading the
# on-screen transport clock.) Starting the excerpt 4 s in gives the seek room.
cut "$MR"  4 14 mr-drums.wav     drum-machine # Intro       — kick and hats, exposed
cut "$MR" 75 14 mr-effects.wav   effects      # Build 2     — sixteenth hats, tom fill
cut "$MR" 15 14 mr-buildone.wav  build-one    # Build       — the clap arrives
cut "$MR" 45 14 mr-thedrop.wav   the-drop     # Drop, later — lead well established
cut "$MR" 60 14 mr-honest.wav    honest       # Breakdown   — no kick at all
cut "$MK" 30 14 mk-variants.wav  variants     # Grieg, at the drop
cut "$FA" 90 14 fate-close.wav   close        # Beethoven, at the second drop

echo "--- every excerpt must be a DIFFERENT file; identical md5s mean the cuts collapsed ---"
md5 -q "$OUT"/mr-*.wav "$OUT"/mk-*.wav "$OUT"/fate-*.wav | sort | uniq -c | sort -rn | head -3
echo "(a count above 1 is a failure: two stages would play the same audio again)"
