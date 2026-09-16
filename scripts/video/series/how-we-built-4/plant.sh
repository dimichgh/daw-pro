#!/bin/bash
# THE CENTREPIECE EXPERIMENT — falsify the PDC pin by planting a fault in
# SHIPPING SOURCE and watching four tests redden at exactly their own plugin's
# latency. Then restore, and PROVE the restore.
#
# ⛔ THE TRAP IS NOT OPTIONAL. A script that dies after the sed leaves a planted
# fault in Sources/. `trap ... EXIT` fires on error, on ^C, and on success.
set -u
R=/Users/dsemenov/Views/daw-pro
HERE=$R/scripts/video/series/how-we-built-4
FILE=$R/Sources/DAWEngine/PlaybackGraph.swift
BAK=$HERE/logs/PlaybackGraph.swift.orig
LINE=1393
ORIG='                chainLatencyActive: chainState.latencySamples,'
PLANT='                chainLatencyActive: 0,  // PLANTED-DEFECT-HWB4'

cp "$FILE" "$BAK"
trap 'cp "$BAK" "$FILE"; echo "TRAP: restored $FILE"' EXIT

step () { echo; echo "════════ $1"; }

step "0. the line we are about to break, as it ships"
sed -n "${LINE}p" "$FILE"

step "1. BASELINE — the pin, unmodified, must be GREEN"
( cd $R && ./scripts/test.sh --filter PDCHostedAURender ) > $HERE/logs/plant-00-green.log 2>&1
echo "exit $?"; tail -4 $HERE/logs/plant-00-green.log

step "2. PLANT — chainLatencyActive: chainState.latencySamples  ->  0"
python3 - "$FILE" "$LINE" "$PLANT" <<'PY'
import sys
p, n, new = sys.argv[1], int(sys.argv[2]), sys.argv[3]
L = open(p).read().split("\n")
assert L[n-1].strip() == "chainLatencyActive: chainState.latencySamples,", repr(L[n-1])
L[n-1] = new
open(p, "w").write("\n".join(L))
print("planted at line", n)
PY
sed -n "${LINE}p" "$FILE"

step "3. THE RED RUN — the same four tests, on a program with one number wrong"
( cd $R && ./scripts/test.sh --filter PDCHostedAURender ) > $HERE/logs/plant-01-red.log 2>&1
echo "exit $?"; grep -c '✘' $HERE/logs/plant-01-red.log; tail -6 $HERE/logs/plant-01-red.log

step "4. RESTORE (the trap will also do this; doing it explicitly so the proof runs after)"
cp "$BAK" "$FILE"

step "5. PROOF OF RESTORE — four independent checks, not one return code"
cmp "$BAK" "$FILE"; echo "cmp exit $? (0 = byte-identical to the backup)"
echo -n "planted marker still in file (want 0): "; grep -c 'PLANTED-DEFECT-HWB4' "$FILE"
echo -n "original line back in file (want 1): ";   grep -c 'chainLatencyActive: chainState.latencySamples,' "$FILE"
echo -n "git sees the file as modified (want nothing): "
( cd $R && git status --porcelain -- Sources/DAWEngine/PlaybackGraph.swift ); echo "[end]"

step "6. THE GREEN RUN AGAIN — the same tests, on the restored program"
( cd $R && ./scripts/test.sh --filter PDCHostedAURender ) > $HERE/logs/plant-02-green.log 2>&1
echo "exit $?"; tail -4 $HERE/logs/plant-02-green.log
