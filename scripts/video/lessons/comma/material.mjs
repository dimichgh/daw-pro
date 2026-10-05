// The tuning material, defined ONCE so every stage of the chain agrees.
//
// ⭐ NOTHING HERE IS A ROUNDED CONSTANT. Every cent value is derived from the
// ratio it comes from, in full double precision, and written to
// material.json for measure.py and spec.py to read. The film's headline number
// — the Pythagorean comma — is computed as 1200*log2((3/2)^12 / 2^7), never
// typed as 23.46.
//
// ⚠ THE APP DOES THE RETUNING, NOT THIS FILE. Each sampler zone gets
// `tuneCents`; the engine varispeeds the 440.000 Hz source. Measured on the
// staging app: tuneCents 23.46 renders 446.003 Hz against a prediction of
// 446.003 — cent-exact, which is what makes it legitimate to say the film's
// numbers were measured off DAW Pro renders.
import fs from "node:fs";

export const CENT = (r) => 1200 * Math.log2(r);
export const A4 = 440.0;

export const FIFTH_PURE = CENT(3 / 2);              // 701.955000865...
export const FIFTH_ET = 700.0;
export const THIRD_PURE = CENT(5 / 4);              // 386.313713865...
export const THIRD_ET = 400.0;
export const COMMA_RATIO = Math.pow(3 / 2, 12) / Math.pow(2, 7); // 531441/524288
export const COMMA = CENT(COMMA_RATIO);             // 23.4600103...
export const ET_NARROWING = FIFTH_PURE - FIFTH_ET;  // 1.955000865...

// The walk: twelve pure fifths from A4, each folded back into the A4 octave.
// Thirteen points, the last of which SHOULD be A4 again and is not.
export const WALK = Array.from({ length: 13 }, (_, k) => {
  const raw = k * FIFTH_PURE;
  return { step: k, rawCents: raw, cents: raw % 1200, octaves: Math.floor(raw / 1200) };
});

// One sampler zone per walk step, on MIDI pitches 60..72. rootPitch === the
// zone's own pitch so the keymap's varispeed factor is exactly 1 and the ONLY
// thing moving the pitch is tuneCents — otherwise the two mechanisms would
// compose and no measured Hz could be attributed to either.
export const WALK_BASE_PITCH = 60;
export const walkZones = (path) => WALK.map((w, k) => ({
  path, rootPitch: WALK_BASE_PITCH + k,
  minPitch: WALK_BASE_PITCH + k, maxPitch: WALK_BASE_PITCH + k,
  tuneCents: w.cents,
}));

// Predicted beat rates. A beat between two partials is |f1 - f2|.
export const hz = (cents) => A4 * Math.pow(2, cents / 1200);
export const predict = {
  // fundamentals, 440 against the comma-sharp A
  unison: Math.abs(hz(COMMA) - A4),
  // fifth: 3*f_root against 2*f_fifth (both land near 1320 Hz)
  fifthPure: Math.abs(3 * A4 - 2 * hz(FIFTH_PURE)),
  fifthET: Math.abs(3 * A4 - 2 * hz(FIFTH_ET)),
  // major third: 5*f_root against 4*f_third (both land near 2200 Hz)
  thirdPure: Math.abs(5 * A4 - 4 * hz(THIRD_PURE)),
  thirdET: Math.abs(5 * A4 - 4 * hz(THIRD_ET)),
};

export const partial = { fifth: 3 * A4, third: 5 * A4 };

if (import.meta.url === `file://${process.argv[1]}`) {
  const out = {
    a4: A4, fifthPure: FIFTH_PURE, fifthET: FIFTH_ET, thirdPure: THIRD_PURE,
    thirdET: THIRD_ET, commaRatio: COMMA_RATIO, comma: COMMA,
    etNarrowing: ET_NARROWING, walk: WALK, walkBasePitch: WALK_BASE_PITCH,
    predict, partial,
    hz: { a: A4, commaA: hz(COMMA), fifthPure: hz(FIFTH_PURE),
          fifthET: hz(FIFTH_ET), thirdPure: hz(THIRD_PURE), thirdET: hz(THIRD_ET) },
    ratioNum: 531441, ratioDen: 524288,
  };
  fs.writeFileSync(new URL("./material.json", import.meta.url), JSON.stringify(out, null, 1));
  console.log(JSON.stringify(out.predict, null, 1));
  console.log("comma", COMMA, "ratio", COMMA_RATIO, 531441 / 524288);
  console.log("walk last", WALK[12].cents);
}
