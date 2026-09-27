# Vendored third-party code

Header-only C++ vendored verbatim (headers + LICENSE files, nothing else) for
the offline time-stretch/pitch-shift facade (M5 ii-b), **EXCEPT THREE LOCAL
PATCHES** to `signalsmith-stretch.h` (below; 0002 and 0003 ship together or
not at all). Upstream repo layout is preserved so relative includes
(`include/` wrappers, `./platform/*`) resolve unchanged. Only the Accelerate platform backends are vendored — we always
compile with `SIGNALSMITH_USE_ACCELERATE`; the pffft/IPP backends are
preprocessor-dead on this build and were omitted.

| Library | Upstream | Commit | Fetched | License |
|---|---|---|---|---|
| signalsmith-stretch (v1.3.2) + local patches 0001-0003 | https://github.com/Signalsmith-Audio/signalsmith-stretch | `57b93f4e9206a089a45387eaa39bdc9f310d3308` | 2026-07-05 | MIT (`vendor/signalsmith-stretch/LICENSE.txt`) |
| signalsmith-linear | https://github.com/Signalsmith-Audio/linear | `7f53cdd1ccd52b409dacf2af24e7ff838c5580cd` | 2026-07-05 | MIT (`vendor/signalsmith-linear/LICENSE.txt`) |

## Local patches

### 0001 — fractional-bin `prevInput` read (`patches/0001-fractional-prevInput-rotation.patch`, 2026-09-25)

**What it fixes.** In the preliminary phase-vocoder prediction, an output bin
that reads a FRACTIONAL input bin interpolates `prediction.input` unrotated, but
interpolated `prevInput` after the `rot` pass had turned every bin by its OWN
centre advance (adjacent bins 2π·H/N apart: 84.375° at 48 kHz, 77.5° at
44.1 kHz). Mixing phasors from two frames gave a phase advance that is not the
fractional position's, so every non-integer spectral shift landed up to ~1.4 Hz
off. The patch brings the upper neighbour into the lower one's frame,
interpolates, and turns the result to the fractional position (the turn is the
`rot` pass's own `freqStep × defaultInterval()`, NOT the input hop).
`fracIndex == 0` runs the upstream expression verbatim.

**Measured effect** (architect harness + `TransposeFractionalReadTests`):
- +100 c on a 220 Hz sine rendered **+9.69 c sharp**; a −100 c move at 55 Hz
  landed at −58 c; a −25 c correction at −14.7 c. After 0001 alone: **≤ 0.42 c**
  for |shift| ≤ 3 st at 44.1/48/96 kHz, ratios 0.5–1.5, stereo,
  formant-preserve (≤ 0.01 c once 0002 is applied too).
- **0 st is byte-identical** (every bin reads an integer input bin), pinned by
  G1 against digests captured on the pristine header.
- Large shifts (≥ 5 st) were left with a second, independent residual that
  0001's old error had partly cancelled (mean |err| 6.45 → 1.62 c, 12 of 96
  cases worse by > 0.1 c). It was the peak position and the lobe map, fixed
  by 0002 below. (The "near-DC synthesis" half of that diagnosis was a
  mislabel: a constant-Hz error read in cents at a low output frequency.)
- Cost: ≈ +9 % on a transposing render (one `polar` per bin per channel per
  hop); 0 st unchanged. Offline only — never on the render thread.

**Re-apply:** `patch -p1 < patches/0001-fractional-prevInput-rotation.patch`
(if it no longer applies, re-derive it by hand from the patch's own
description; the block is the "Preliminary output prediction from
phase-vocoder" loop).

**The tripwire:** a re-vendor that drops this patch fails
`TransposeFractionalReadTests` G2 at ≈ **+9.69 c** (+100 c on 220 Hz at 48 kHz),
and G1's control stops differing from its pristine digest. That gate, not a
source marker, is what guards the patch.

### 0002 — peak position and flat main-lobe map (`patches/0002-peak-position-and-flat-lobe-map.patch`, 2026-09-25)

**What it fixes** (two halves; both are needed).
- *Peak position.* `findPeaks` placed each peak at the ENERGY CENTROID of its
  region's bins, biased toward bin centres by up to 0.076 bins (0.6 Hz at
  48 kHz). On a new spectrum the `rot` pass has already turned `prevInput` by
  each bin's centre advance, so `input·conj(prevInput)` at bin k has phase
  θ·(peak − k) for a steady partial. The patch reads the position from that
  phase around the region's max bin (3 bins, all channels summed), gated by
  coherence (|Σz| > 0.5·Σ|z|) and kept inside the region (±0.5 bin), else the
  centroid stands.
- *Flat lobe.* `updateOutputMap`'s smoothstep toward the NEXT peak (a window
  sidelobe ~53 bins away for a pure sine, or the next harmonic) bent the
  offset INSIDE each peak's own main lobe, so the lobe's bins advanced at
  different rates and pulled the partial (−12 c at −12 st). Each peak's offset
  is now held flat for 0.5·N/H bins either side (upstream's `smoothingBins/2`:
  97 % of the analysis window's first null at presetDefault, where the lobe is
  −40 dB; only 86 %/−21 dB at presetCheaper — re-derive before any preset
  change), capped at a quarter of BOTH the output and the INPUT gap between
  two peaks (the review's "V1" cap).

**Measured effect** (architect harness, product schedule, -O2):
- Steady partials: 12 c (±12 st) and 76 c (±24 st) on 0001 alone → ≤ 0.01 c,
  at 44.1/48/96 kHz, ratios 0.5–1.5, stereo, formant preserve and shift.
  ⚠ 2026-09-27: the 12/76 c figures come from this wider harness and did NOT
  reproduce in the plain-API repro filed upstream (#32). With 0001 alone that
  repro reads −1.65/+0.26 c at ±12 st and −2.64/−18.96 c at ±24 st on a sine
  (−50.06 c worst harmonic at −24 st); after all three patches, ≤ 0.011 c.
  12-harmonic tones to ±12 st and to +24 st: ≤ 0.001 c. Up-shifted bass
  5–13 c → ≤ 0.27 c.
- 0 st is byte-identical: `findPeaks`/`updateOutputMap` run only when
  frequencies are mapped.
- **Costs, accepted:** +7 % on a transposed render (offline only). At ≥ +9 st
  on low or dense material, inter-harmonic noise is redistributed toward the
  harmonics (energy conserved; 55 Hz +12 st mid-points −3.9 → −5.9 dB, and
  82/110 Hz +19 st −31 → −63 dB). A vibrato mean-pitch residual intrinsic to
  shifting a MOVING partial is no longer masked by 0001's opposite-signed
  errors: ≤ 1.2 c at 30 c depth, and up to 4.4 c at 60 c depth an octave
  down (0001 alone: −1.36 c there). The plain-API repro filed upstream (#32;
  5 Hz, 220 Hz, −12 st) reads 0.82 c, 3.53 c and −2.30 c: the same direction,
  different figures. A weaker partial within ~2 bins of a
  stronger one moves by the stronger one's Hz offset.
- **Known limit, not a regression:** dense spectra whose OUTPUT harmonics are
  closer than ~4.4 bins (≈ 34 Hz at 48 kHz) are unresolved in every variant:
  110 Hz taken down 24 st reads 11.9 c (122 c before).

**Coupled to 0003.** The phase-derived position is the advance over the
input interval divided by the H turn; without 0003 that interval is H±1 on
some near-unity hops and 17/104 measured near-unity rows regress (up to
1.13 c). The upstream repro (#32) did not re-run that count; its 6 transposed
H±1 rows land at exactly ±1.20 c without 0003, and within 0.0001 c with it.
Never ship one without the other.

**Re-apply** (after 0001):
`patch -p1 < patches/0002-peak-position-and-flat-lobe-map.patch`. If it no
longer applies, re-derive it by hand from the patch's description (the blocks
are `findPeaks` and the "Interpolate between points" loop of
`updateOutputMap`).

**The tripwires:** `TransposeFractionalReadTests` G3 (±5/±7/±12 st, < 0.05 c),
G12 (±19/±24 st), G13 (harmonic tones). Its flat-zone cap is bracketed from
both sides: G14 goes red if the up-shift flat zone is lost (low harmonic
tones, 3–17 c), G15 if the input-gap cap is lost (inter-harmonic noise
carved to −22.8 dB).

### 0003 — exact previous hop (`patches/0003-exact-previous-hop.patch`, 2026-09-25)

**What it fixes.** Upstream kept the previous block's spectrum when the input
interval was within ±1 sample of the synthesis hop H ("give or take 1
sample"), but the `rot` pass (and 0002's peak position) turn it by exactly H.
On an H±1 hop the output therefore advanced at ω(H±1)/H: ±1.20 c (48 kHz),
±1.31 c (44.1 kHz) per such hop, AT 0 st TOO. An input interval of H+1 reads
SHARP. (Corrected 2026-09-27: this line said ∓, against its own formula. Upstream
report #33 gives it in the library's in:out terms: 1441:1440 → +1.20 c.) The r
below is a stretch ratio, output/input, so r > 1 means H−1 hops and a FLAT reading. The patch re-analyses the
previous spectrum whenever the interval differs from H at all. The shipped
expression is
`blockProcess.reanalysePrev = didSeek || inputInterval != int(stft.defaultInterval());`
(upstream: `… || std::abs(inputInterval - int(stft.defaultInterval())) > 1;`).

**Measured effect:** 0 st through the product loop, r = 1.0005: −0.82 c
(48 kHz) / −0.87 c (44.1 kHz); a 64-beat clip dragged one 1/16
(r = 1.0009766) at 44.1 kHz: −0.93 c. After: 0.000 c. H±1 hops occur only at
ratios within ~2.6/H of 1 (measured maxima: 2.58/H in the 4096-frame
constant loop on 60 s files, 2.00/H in the per-hop curve loop); outside that
window, and at exactly 1, upstream already re-analysed every hop and the
bytes are unchanged. **0003 CHANGES 0-st BYTES inside that window**, which is
why the cache key widened (below). Cost: one extra analysis FFT per channel
on those hops only (+8.6 % at r = 1.0005, still below any ratio outside the
window).

**Upstream conflict.** Open upstream PR #25 inserts a line directly after
this statement and adds runtime `setInterval` with its own `prevInput`
re-rotation (semantically compatible: 0002 and 0003 read H per call). A
re-vendor that includes it re-applies this line by hand and re-runs the
whole gate plus the architect harness, not just the patch.

**Re-apply** (after 0001 and 0002):
`patch -p1 < patches/0003-exact-previous-hop.patch`.

**The tripwires:** `TransposeFractionalReadTests` G17 (0 st at r = 1.0005,
0.9995, 64.0625/64: < 0.05 c; 0001 alone −0.93…+0.86 c), G18 (the 0002/0003
coupling, transposed near-unity: < 0.05 c; 0002 alone up to 1.13 c), and G1+
(the near-unity 0-st digests captured on the 0001-only header must differ).

### Applying all three, and the gate

From `Sources/CSignalsmithStretch`, in order:

    patch -p1 < patches/0001-fractional-prevInput-rotation.patch
    patch -p1 < patches/0002-peak-position-and-flat-lobe-map.patch
    patch -p1 < patches/0003-exact-previous-hop.patch

Against upstream v1.3.2 (`57b93f4e…`) the result is byte-identical to the
shipped header: sha256 `80d11216b5d0d64dc7378fd589b13cb223341f678f272d3113e2e1a0624bf8af`
(0001 alone `2de8f20b…`, 0001+0002 `ed1356bc…`). Then run
`./scripts/test.sh --filter TransposeFractionalRead`. The gates, not source
markers, are what guard the patches.

**Upstream status.** v1.3.2 on `main` (as of `a670068`, 2026-09-25) has all
three defects; a vendor bump fixes none of them. FILED UPSTREAM on the
user's word (2026-09-27): #31 (0001, the fractional `prevInput` read), #32
(0002, peak position and the lobe map) and #33 (0003, the exact previous hop).
Each carries its fix and a single-file public-API repro.

**Cache:** all three patches are keyed by
`StretchRenderCache.transposeEngineVersion` (the `pv:` field), not by
`stretchEngineVersion`. `pv:` is appended to transposing renders, pitch-edited
renders, and — since 0003 — 0-st renders within ±5 % of ratio 1
(`StretchRenderCache.nearUnityRatioBand`: a sample-rate-free band covering
0003's ≤ 2.6/H window with ≥ 2× margin at every source rate ≥ 4 kHz). Every
other 0-st, edit-free render is byte-identical and keeps its key.

## To update

Clone both repos, re-copy the same file set, update the commit hashes above,
re-apply every local patch (above), and bump `stretchEngineVersion` in DAWEngine
so stale cache renders are invalidated (see docs/ARCHITECTURE.md, time-stretch
seam).
