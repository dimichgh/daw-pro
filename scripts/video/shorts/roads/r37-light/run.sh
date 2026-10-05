#!/bin/bash
# ROUND 37 — the whole still comparison, plus every cost measurement.
# Every render goes through the SAME mkscene.py; nothing is tuned per renderer.
set -u
cd "$(dirname "$0")"
BL=/Applications/Blender.app/Contents/MacOS/Blender
S=stills; M=measure; mkdir -p $S $M
run () { # run <tag> <sceneJson> <engine> <out> <sigmaMode> <samples> <volsamples>
  $BL -b --python mkscene.py -- "$2" "$3" "$4" "$5" "$6" "${7:-64}" 2>&1 \
    | rtk proxy grep -E "RENDERTIME|ALIGNMENT|CYCLES:|EEVEE:" | sed "s/^/[$1] /"
}
LOG=$M/render-log.txt; : > $LOG
exec > >(tee -a $LOG) 2>&1

echo "=== A. SAMPLE LADDERS on the LOW pose (the heaviest: most volume in frame)"
for n in 32 64 128 256 512; do
  for rep in 1 2; do
    SIGMA_HAZE=0.07 run "cyc-spp$n-r$rep" scene/P3-low-look-up.json CYCLES $M/lad/cyc-$n.png haze $n
  done
done
for v in 32 64 128 256; do
  for rep in 1 2; do
    SIGMA_HAZE=0.07 run "eev-vol$v-r$rep" scene/P3-low-look-up.json EEVEE $M/lad/eev-v$v.png haze 64 $v
  done
done
echo "=== A2. Cycles with the OIDN denoiser at 128"
for rep in 1 2; do
  DENOISE=1 SIGMA_HAZE=0.07 run "cyc-128-denoise-r$rep" scene/P3-low-look-up.json CYCLES $M/lad/cyc-128-den.png haze 128
done
echo "=== A3. Cycles on the CPU at 128 — the positive control that the GPU is engaged"
CYCLES_DEVICE=CPU SIGMA_HAZE=0.07 run "cyc-128-CPU" scene/P3-low-look-up.json CYCLES $M/lad/cyc-128-cpu.png haze 128
