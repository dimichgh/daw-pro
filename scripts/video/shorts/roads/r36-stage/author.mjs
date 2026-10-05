// ROUND 36 — the PLACEHOLDER material, written by hand.
//
// ⛔ THIS IS NOT AN ARRANGEMENT and must never be shown as one. It exists to
// exercise one mechanic each: a SUSTAINED voice whose beams stand through a
// chord, a BASS with genuinely long notes, a LEAD that hops along a rank, a
// STAB with very short notes, and the KIT's leap-out-of-a-hole. Every note here
// was typed, not generated.
//
// LAYOUT is the argument: `node author.mjs L1` or `L2`.
//   L1 "even ring"     — four stations, equal radius 3.2, 90 deg apart.
//   L2 "staggered ring"— same azimuths, radii 3.8/2.6/3.3/2.2 and plinths
//                        0/0.30/0.12/0.45, so no two stations share a radial
//                        line AND no two share a height. The occlusion sweep
//                        scores these against each other.
import fs from 'node:fs';

const LAYOUT = (process.argv[2] || 'L2').toUpperCase();
const BPM = 100, SPB = 60 / BPM, BAR = 4 * SPB;       // 0.6 s / beat, 2.4 s / bar
const T0 = 0.6;                                        // a beat of darkness first
const bar = n => T0 + n * BAR;
const beat = (n, b) => bar(n) + b * SPB;

// ---- the roads palette, rung 25/26. #FF707C #FFC370 #DBFF70 is the frozen fan;
// the stage adds nothing to it — the fifth colour is the kit's, which on the
// road was always the white-hot core.
const PAL = { sustained: '#FFC370', bass: '#FF707C', lead: '#DBFF70', stab: '#FFA0C8' };

const RING = LAYOUT === 'L1'
  ? [{ rad: 3.2, plinth: 0 }, { rad: 3.2, plinth: 0 }, { rad: 3.2, plinth: 0 }, { rad: 3.2, plinth: 0 }]
  : [{ rad: 3.8, plinth: 0.00 }, { rad: 2.6, plinth: 0.30 },
     { rad: 3.3, plinth: 0.12 }, { rad: 2.2, plinth: 0.45 }];

const instruments = [
  { name: 'Strings',  cls: 'sustained', az:  45, ...RING[0], color: PAL.sustained,
    rank: 4, rankSpread: 0.34, rodR: 0.044, hMin: 1.2, hMax: 3.0, riserR: 0.85, ringR: 0.30, pitchLo: 52, pitchHi: 79 },
  { name: 'Bass',     cls: 'bass',      az: 135, ...RING[1], color: PAL.bass,
    rank: 1, rodR: 0.070, hMin: 0.9, hMax: 2.2, riserR: 0.55, ringR: 0.34, pitchLo: 28, pitchHi: 48 },
  { name: 'Lead',     cls: 'lead',      az: 225, ...RING[2], color: PAL.lead,
    rank: 12, rankSpread: 0.19, rodR: 0.030, hMin: 1.0, hMax: 3.6, riserR: 1.25, ringR: 0.22, pitchLo: 60, pitchHi: 84 },
  { name: 'Stabs',    cls: 'stab',      az: 315, ...RING[3], color: PAL.stab,
    rank: 3, rankSpread: 0.28, rodR: 0.052, hMin: 0.9, hMax: 2.3, riserR: 0.65, ringR: 0.26, pitchLo: 48, pitchHi: 72 },
];

const notes = [];
const N = (i, t, dur, pitch, vel, slot) => notes.push({ i, t, dur, pitch, vel, slot });

// ── 0. STRINGS: sustained chords, one bar each, four beams standing together.
// i-vi-III-VII in A minor, so the beams change height between chords.
const CH = [[57, 60, 64, 69], [53, 57, 60, 65], [55, 60, 64, 67], [52, 55, 59, 64],
            [57, 60, 64, 69], [53, 57, 60, 65], [55, 59, 62, 67], [57, 61, 64, 69],
            [57, 60, 64, 69], [53, 57, 60, 65], [55, 60, 64, 67], [57, 60, 64, 72]];
CH.forEach((ch, b) => ch.forEach((p, k) =>
  N(0, bar(b), BAR * (b === 11 ? 1.6 : 0.94), p, 0.62 + 0.05 * k, k)));

// ── 1. BASS: deliberately LONG notes — two bars each for most of it, so the
// beam is standing while the camera goes a long way round. This is the case the
// road could never show (a rod had 1.05 s of a 2.17 s note).
[[0, 2, 33], [2, 2, 29], [4, 2, 31], [6, 2, 28],
 [8, 1, 33], [9, 1, 36], [10, 2, 31], [11.0, 1.6, 33]].forEach(([b, len, p]) =>
  N(1, bar(b), BAR * len * 0.97, p, 0.85, 0));

// ── 2. LEAD: eighth notes hopping along the rank, one slot per scale degree.
// A minor pentatonic-ish run so the hops are big enough to see.
const SCALE = [69, 72, 74, 76, 79, 81, 76, 74];
for (let b = 2; b < 12; b++) {
  if (b === 6 || b === 7) continue;                  // a hole, so the stage breathes
  for (let e = 0; e < 8; e++) {
    const p = SCALE[(b * 3 + e * 5) % SCALE.length] + (b > 8 ? 3 : 0);
    N(2, beat(b, e * 0.5), SPB * 0.42, p, 0.55 + 0.35 * (e % 2), (p - 60) % 12);
  }
}
// two LONG lead notes at the end so the same station shows both mechanics
N(2, bar(11), BAR * 0.8, 81, 0.95, 9);

// ── 3. STABS: very short, three beams at once, on the off-beats of bars 4-10.
for (let b = 4; b < 12; b += 2) {
  [1.5, 3.5].forEach(bt => [0, 1, 2].forEach(k =>
    N(3, beat(b, bt), SPB * 0.22, [55, 60, 64][k] + (b > 8 ? 2 : 0), 0.95, k)));
}

// ── KIT: kick on 1 & 3, snare on 2 & 4, hat on eighths. The centre of the rig.
const kit = {
  gravity: 9.0,
  lanes: [{ name: 'Kick',  pos: [0.0, -0.45], color: '#FFE9C8' },
          { name: 'Snare', pos: [-0.5, 0.35], color: '#FFD0A0' },
          { name: 'Hat',   pos: [0.55, 0.30], color: '#FFF4DC' }],
};
const drums = [];
for (let b = 0; b < 12; b++) {
  drums.push({ lane: 0, t: beat(b, 0), vel: 1.0 }, { lane: 0, t: beat(b, 2), vel: 0.85 });
  if (b > 0) drums.push({ lane: 1, t: beat(b, 1), vel: 0.9 }, { lane: 1, t: beat(b, 3), vel: 0.9 });
  if (b > 1) for (let e = 0; e < 8; e++) drums.push({ lane: 2, t: beat(b, e * 0.5), vel: e % 2 ? 0.45 : 0.7 });
}

// ---- the camera plan. ORBIT is the default; the clip also rides the elevation
// down to the LOW look-up and back to the HIGH look-down, because those are the
// two poses the user named and one clip that contains all three is worth more
// than three clips that each contain one.
const camera = {
  keys: [
    { t: 0.0,  az:  20, el: 24, r: 13.5, fov: 40, tgt: [0, 0.9, 0] },
    { t: 8.0,  az: 100, el: 28, r: 12.6, fov: 40, tgt: [0, 0.9, 0] },
    { t: 14.0, az: 160, el:  6, r:  9.6, fov: 44, tgt: [0, 1.1, 0] },  // LOW: towering
    { t: 21.0, az: 250, el: 11, r: 10.4, fov: 42, tgt: [0, 1.0, 0] },
    { t: 27.0, az: 330, el: 60, r: 15.5, fov: 38, tgt: [0, 0.3, 0] },  // HIGH: layout
    { t: 31.0, az: 380, el: 38, r: 13.0, fov: 39, tgt: [0, 0.8, 0] },
  ],
};

const P = {
  width: 1920, height: 1080, fps: 30, total: 30.0,
  title: 'DAW Pro — stage prototype',
  subtitle: `ROUND 36 · orbit rig · layout ${LAYOUT} · ${BPM} BPM · placeholder material`,
  badge: 'PLACEHOLDER MATERIAL — NOT AN ARRANGEMENT',
  layout: LAYOUT,
  look: {
    bg: 0x05050a, fog: 0.034, exposure: 0.88, fov: 40,
    floorR: 16, floorColor: 0x2a2723, floorRough: 0.96, ambient: 0.055,
    deckR: 5.4, deckAlpha: 0.10, deckColor: 0xffd9a8,
    bloomStrength: 1.05, bloomRadius: 0.62, bloomThreshold: 0.80,
    vignette: 1.0, gradeTint: 0.20, lightY: 0.42,
    holeColor: 0x0b0b0d, holeK: 3.0, holeDepth: 0.42,
    rise: 0.07, fall: 0.30, rodGain: 1.25, rodPower: 1.9,
    sheathK: 3.2, sheathAlpha: 0.13, capGlow: 0.26, riserColor: 0x1d1b19,
    lightDist: 9.5, decay: 1.6,
    drumCoreR: 0.075, drumHalo: 0.20, drumPower: 1.4, drumLeap: 0.72,
    drumFade: 0.34, drumRestK: 0.55, drumRestGlow: 0.22,
    ringPool: 48, ringTau: 2.0, ringGrow: 2.8, ringAlpha: 0.45,
    emberTau: 3.0, emberAlpha: 0.85,
  },
  instruments, notes, kit, drums, camera,
};

const out = process.argv[3] || `stage.${LAYOUT}.payload.json`;
fs.writeFileSync(out, JSON.stringify(P));
console.log(`${out}: layout ${LAYOUT}, ${instruments.length} stations, ` +
            `${notes.length} notes, ${drums.length} drum hits, ${P.total}s, ` +
            `note span ${Math.min(...notes.map(n => n.t)).toFixed(2)}..` +
            `${Math.max(...notes.map(n => n.t + n.dur)).toFixed(2)}s`);
