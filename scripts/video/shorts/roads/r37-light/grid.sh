#!/bin/bash
set -u; cd "$(dirname "$0")"
BL=/Applications/Blender.app/Contents/MacOS/Blender
export SIGMA_HAZE=0.07
g () { $BL -b --python mkscene.py -- "$@" 2>&1 | rtk proxy grep -E "RENDERTIME|ALIGNMENT"; }
for p in P1-mid-orbit P2-high-look-down P3-low-look-up P4-low-az315-occl; do
  for rep in 1 2; do
    DENOISE=1 g scene/$p.json CYCLES stills/$p--cycles.png haze 128
  done
  for rep in 1 2; do
    g scene/$p.json EEVEE stills/$p--eevee.png haze 64 128
  done
done
echo "=== the physically-right rod: the EMISSIVE CYLINDER IS the lamp"
LAMP=mesh DENOISE=1 g scene/P3-low-look-up.json CYCLES stills/P3-low-look-up--cycles-MESHLAMP.png haze 128
LAMP=mesh          g scene/P3-low-look-up.json EEVEE  stills/P3-low-look-up--eevee-MESHLAMP.png  haze 64 128
echo "=== the haze density DERIVED from three.js's FogExp2 (0.0156), for the record"
DENOISE=1 g scene/P3-low-look-up.json CYCLES measure/P3--cycles-SIGMA-MATCHED.png matched 128
          g scene/P3-low-look-up.json EEVEE  measure/P3--eevee-SIGMA-MATCHED.png  matched 64 128
