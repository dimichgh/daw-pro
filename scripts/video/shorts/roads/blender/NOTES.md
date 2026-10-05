# Blender look probe — "note road" visualiser

A **look probe**, not a pipeline. One self-contained script builds the whole scene
procedurally from a note list defined at the top of the file, bakes every animated
value to keyframes, and renders. Nothing here is meant to be a port target as-is.

Everything lives under `scripts/video/shorts/roads/blender/`. Nothing outside that
directory was read or written.

## Run it

```
BL=/Applications/Blender.app/Contents/MacOS/Blender
D=/Users/dsemenov/Views/daw-pro/scripts/video/shorts/roads/blender

# fast look iteration (sub-second frames)
$BL -b -noaudio -P $D/probe.py -- --engine EEVEE  --frames 13,27,38 --out $D/out/x --resx 960 --resy 540

# final look
$BL -b -noaudio -P $D/probe.py -- --engine CYCLES --frames 13,27,38 --out $D/out/x --samples 128
$BL -b -noaudio -P $D/probe.py -- --engine CYCLES --anim --out $D/out/clip --samples 128
```

Args: `--engine EEVEE|CYCLES --frames a,b,c --anim --out DIR --tag NAME
--resx --resy --samples --disk-rough --decay`.

## The score (procedural, in `probe.py`)

24 fps, 8.0 s, 192 frames. Road scrolls at `V = 2.0` units/s; a note at time `t`
sits at `y = V*t`, so a playhead at `y = V*t` meets it exactly on the beat.

- 4 pitch lanes at x = −2, −1, 0, +1; percussion lane at x = +2.
- 5 chords at t = 1.00 / 2.40 / 3.80 / 5.20 / 6.60 s, with 3, 3, 3, 3 and **4**
  simultaneous voices — 16 note disks total. Lanes with no note in a chord still
  have their playhead travelling, which is what makes the multi-voice case read.
- 6 percussion hits at t = 0.70 / 1.80 / 3.10 / 4.40 / 5.70 / 7.00 s.

No audio. Rendered silent, as asked.

## What is built, and how

| Element | How |
|---|---|
| Road | a **slab** (0.20 thick), not a plane — a plane cannot have holes with walls |
| Track lines | 6 thin boxes + Bevel modifier (0.008 / 3 segments, harden normals) |
| Note disks | cylinder r=0.30 d=0.07 + Bevel (0.018 / 4 segments) — real chamfer |
| Disk material | Principled, base colour 0.012 (near-black), **metallic 1.0**, roughness 0.30 |
| Heat | `Attribute(OBJECT, "heat")` → Blackbody 950–6800 K into Emission Colour; `62·heat^2.6` into Emission Strength |
| Playhead | flat emissive disk r=0.19, hovering 0.36 above the road, `visible_shadow=False` |
| Comet | a static teardrop mesh parented to the head: **full head width at the head, monotonic taper to a mathematical point** over 1.6 units |
| Comet shader | `Mix(Transparent, Emission, fac = along^3.2)` — the transparent leg is what stops the tail ending in a black stub |
| Perc holes | 6 cylinders **boolean DIFFERENCE (EXACT)** through the slab, Bevel applied after so the rims chamfer |
| Perc disk | emissive disk keyframed on Z, starting inside the hole at −0.30, apex +1.00, back down over 0.62 s |
| Road material | two Noise textures — one at scale 300/detail 12 into Bump (fibre grain), one at 55 into a 0.68–0.95 Roughness band, a third into a subtle colour break-up |
| World | Texture Coordinate → Z → 3-stop ColorRamp: dark below (so holes read as openings), soft studio band above. Metal has something to reflect. |
| Lights | key area 7×3 at 520 W above/ahead, rim area 6×1.4 at 260 W from the right |

Camera, key light, rim light, all four playheads **and all four comet tails** are
parented to one `rig` empty, which is the only object carrying position keyframes; the disks carry `["heat"]` keys and the perc
disks carry Z keys. Every value is baked on **every** frame — no handlers run during
render, and no interpolation curve is ever sampled between keys.

## Four things you will SEE that are choices, not accidents

1. **The percussion disks glow inside their holes the whole time** (emission 40, parked
   at z = −0.30). That warm interior is *why* the holes read as real openings rather
   than painted circles — but it means an un-hit hole is lit and a hole whose disk has
   just leapt out goes dark inside. If dark idle holes are wanted, key the perc
   material's emission to zero while parked.
2. **The playhead hovers 0.36 above the road — it never actually lands on the note.**
   It started on the road, which is where "lands on each note" points, and it
   completely occluded the strike: the frame meant to show a white-hot chord showed
   three playheads. Hovering is the probe's answer, not the only one — a ring playhead,
   a translucent one, or one that lands and dims are all unexplored. **This is an open
   design question for the port, not a settled detail.**
3. **The percussion disk's apex (1.00 above the road, from `1.30*(4u(1−u))^0.7`) puts
   it visually beside its hole rather than obviously out of it** at this camera angle.
   Lowering that `1.30` keeps the disk visually tied to the hole it came from. Left
   as-is deliberately — iteration speed.
4. **The visible backdrop is black.** The world's bright studio band sits *above* the
   camera frustum on purpose; you see it only in the chamfers and in what the metal
   reflects. The gradient is working — it is what stops the metal being dead — it is
   just not meant to be in shot.

## Render settings

- Blender 5.2.1 LTS, `-b -noaudio -P`. EEVEE engine id is `BLENDER_EEVEE`.
- Cycles: `compute_device_type='METAL'`, GPU device `Apple M5 Max (GPU - 40 cores)`
  confirmed **`use=True` and printed on every run** (`[cycles-device]` line).
  `device='GPU'`, 128 samples, adaptive sampling, OIDN denoising on,
  `sample_clamp_indirect=10`, max bounces 8, transparent bounces 12.
- View transform **AgX** (it is what makes high emission go white-hot instead of
  clipping to flat yellow).
- 1920×1080, PNG.

## Measured per-frame times (2nd and 3rd render in the same process, never the 1st)

The Metal kernel cache was already warm on this machine, so even the first frame of
a session came in at 1.6–5.6 s — the ~106 s cold-compile did not recur. Timings are
from the script's own `perf_counter` around each `render()`.

| engine | resolution | samples | 1st render | **2nd render** | **3rd render** |
|---|---|---|---|---|---|
| EEVEE | 960×540 | 64 TAA | 1.81 s (first ever) | **0.41 s** | **0.43 s** |
| EEVEE | 960×540 | 64 TAA | 0.54 s | **0.43 s** | **0.40 s** |
| Cycles GPU | 960×540 | 96 | 2.62 s | **2.25 s** | **1.67 s** |
| Cycles GPU | 1280×720 | 128 | 2.64 s | **2.45 s** | **2.44 s** |
| Cycles GPU | 1920×1080 | 128 | 5.05 s | **5.01 s** | **4.89 s** |

The 8 s / 192-frame 1080p Cycles clip measured **1054.7 s wall = 5.49 s/frame**, one
scene build, one `render(animation=True)`.

## Deliverables

All under `scripts/video/shorts/roads/blender/`:

| file | what |
|---|---|
| `probe.py` | the whole probe — scene, score, materials, animation, render |
| `out/note-road-probe.mp4` | **the clip.** 1920×1080, 24 fps, 8.000 s, 192 frames, h264 yuv420p, 4.55 MB, **no audio stream** |
| `out/clip/frames/f0001..f0192.png` | the source PNG sequence |
| `out/stills/01-rest-black-bevelled-disks.png` | black bevelled disks at rest, chamfer highlight, holes as openings |
| `out/stills/02-strike-white-hot.png` | a 3-voice chord at full heat, light pooling on the road |
| `out/stills/03-cooling-pale-yellow.png` | heat 0.426 |
| `out/stills/04-cooling-orange.png` | heat 0.159 |
| `out/stills/05-cooling-deep-red.png` | heat 0.025 |
| `out/stills/06-comet-tails-no-strike.png` | four playheads + comets, nothing struck |
| `out/stills/detail-comet-tail-tip.png` | close crop of the tail: full disk width at the head, fading to nothing |
| `out/stills/07-drum-hole-disk-leaping-out.png` | percussion disk at apex, warm bounce on the hole walls |
| `out/stills/08-four-voice-chord.png` | the 4-voice chord — four playheads, four strikes |
| `out/variants/rough-{0.10,0.30,0.60}_f0027.png` | **the choice axis** (below) |
| `out/variants/00-crop-strip-0.10-0.30-0.60.png` | the three cropped to the same disk, side by side |

## The one axis to choose on: disk metal roughness

Same frame (27, a 3-voice strike), same everything, only `--disk-rough` changed.
This is the axis I judged most genuinely open — the brief said "metallic,
low-to-moderate roughness", which is a range, not a value, and the whole
black-disk-that-glows idea lives or dies on how the chamfer catches light.

- **0.10** — piano-black, mirror chamfer. A single hard specular line on the bevel.
- **0.30** — the value used in the clip and stills.
- **0.60** — matte/graphite. The chamfer highlight is broad and soft; the disk face
  picks up more ambient and sits lighter against the road.

No favourite is stated on purpose. Measured mean luminance over the same crop:
100.26 / 100.48 / 100.89 (0–255) — nearly identical globally, which is why the
**crop strip**, not the full frames, is the thing to look at.

Decay speed (`--decay`, currently 0.85 s) is the other open axis and was not
varied; say the word and it is three more stills or three more clips.

## Verification actually performed

- **Every image in this report was opened and looked at**, not just path-checked.
  Two real defects were found only by looking: (a) `primitive_cube_add(size=1)` has
  half-extent 0.5, so the road was half the intended size and started at y=1.5 with
  the playheads floating off its near end; (b) the playhead disk was sitting directly
  on top of the note disk and hiding the strike entirely — the frame that was supposed
  to show a white-hot note showed three playheads.
- **"Reaches exactly black" was tested by sampling pixels, with a control.**
  At frame 47 (heat exactly 0.0), a 7×7 pixel patch at the centre of each cooled disk,
  located with `world_to_camera_view` rather than by eye:

  | | R | G | B |
  |---|---|---|---|
  | cooled disk, emission live | 0.125490 | 0.131653 | 0.141096 |
  | **same pixels, emission link severed from the shader** | 0.125730 | 0.131653 | 0.141337 |

  Max delta **2.4e-4**, in both directions — denoiser noise. There is no glow floor.
  The residual 0.13 is specular reflection of the world on black metal, and it is
  **blue-leaning (B > G > R)**; an ember residue would be red-leaning. Positive
  control on the same probe: the same disk at heat 0.159 reads
  `0.862 / 0.603 / 0.443` — warm and obvious, so the probe can see emission.
- **Duplicate-content check** on the still batch and on the variant batch:
  `md5 -q *.png | sort | uniq -d` returned 0 lines both times.
- **The clip really moves.** Frames decoded from the finished mp4, downscaled to
  160×90 grey, mean absolute consecutive-frame delta = **2.459** (min 0.573, max
  6.112); zero frames below 0.5. **Negative control**: a deliberately static video
  built by looping one of these same stills scores **0.0023** on the identical
  measurement — a thousandfold separation. (Frame hashing was NOT used; h264 noise
  makes every extracted frame a distinct md5 even for a still image.)
- **The clip is silent as required** — `ffprobe` reports one stream, `codec_type=video`.
- A 4×4 contact sheet of every 12th frame was built and looked at: strikes, the full
  cooling ramp, comets, and the percussion jump are all present in the moving file.

## Footprint

`out/clip/frames/` is 192 PNGs = **356 MB measured** (`du -sh`); the whole `blender/` directory is 386 MB of untracked files inside the
git working tree, and `out/` is not gitignored under this subtree. The mp4 is the
deliverable; the frames are kept only so the clip can be re-encoded without a
16-minute re-render. Delete them freely.

## What I could not do / open ends

- **The road still reads a little like brushed aluminium at grazing incidence.** The
  fibre-grain bump catches the raking key light. Tuning `n1` scale/`bump` strength and
  the roughness band is the knob; it is the least-settled material here.
- **The comet taper fights perspective.** The tail trails *toward* the camera, so the
  narrow end is the near end and perspective magnifies it. It still comes to a true
  point (verified in an orthogonal top-down render), but the on-screen read is more
  "wedge" than "comet". A stronger taper power, a longer tail, or a camera that leads
  rather than follows would all help; not explored.
- **No motion blur, no depth of field, no bloom.** EEVEE in 5.2 has no `use_bloom`
  attribute; the glow you see in Cycles is real light transport, not a post effect.
- **No audio, by instruction.** No DAW involvement at all.
- **EEVEE renders the emission flat** — no pooling on the road. Every image delivered
  is Cycles for that reason. EEVEE was used only for geometry/lighting iteration.
