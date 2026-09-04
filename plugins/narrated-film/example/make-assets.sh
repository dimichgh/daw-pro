#!/usr/bin/env bash
# Generate the example's stills and audio so no binaries live in the repo.
# Deliberately avoids drawtext: it needs libfreetype, which many ffmpeg builds
# (including Homebrew's default on this machine) do not ship.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

slate() {  # slate <file> <bg> <bar-colour>
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=$2:s=1280x720:d=1" \
    -f lavfi -i "color=c=$3:s=880x8:d=1" \
    -filter_complex "[0:v][1:v]overlay=(W-w)/2:(H-h)/2" -frames:v 1 "$1"
}
slate slate-1.png 0x101820 0x4FD1E0
slate slate-2.png 0x141B26 0xC8D2E0

ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=220:duration=6" \
  -af "volume=0.35,afade=t=in:d=0.2,afade=t=out:st=5:d=1" -ac 2 tone.wav

echo "wrote slate-1.png slate-2.png tone.wav"
