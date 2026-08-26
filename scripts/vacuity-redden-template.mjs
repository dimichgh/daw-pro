// TEMPLATE — the redden half of a vacuity fix. Worked example: m23-ee-2b's three legs.
//
// Promoted from the session scratchpad at the ee-2b close so m23-ee-2c has something
// durable to copy. To reuse: replace the three `leg_*` functions with the legs you
// edited (transcribed VERBATIM from the gate — a paraphrase tests your paraphrase),
// give each its real field name and its MEASURED healthy shape, and update the
// POSITIVE CONTROL block with the corresponding PRE-FIX expressions.
//
// m23-ee-2b HALF ONE: does each new pin actually REDDEN on a degenerate response?
//
// The ee-2 item's own law: "A FIX IS NOT VERIFIED BY THE GATE GOING GREEN — green is
// what it did before." A green run proves the pin is not too TIGHT. It says nothing
// about whether the pin is load-bearing. Only forcing the collection empty does that.
//
// This is offline and pure: each leg's condition is transcribed VERBATIM from the
// edited gate, then evaluated against the four degenerate shapes plus the healthy
// shape MEASURED on the live run. No staging, no port, nothing to tear down.
//
// The four degenerate shapes are the ones a real failure produces, not inventions:
//   D1 {}                        command errored / never answered — no `result` at all
//   D2 {result:{}}               answered, but the field the leg reads is absent
//   D3 {result:{X:[]}}           field present and EMPTY — the original vacuity case
//   D4 {result:{X:null}}         field present and null — `?? []` silently rescues it
// D3 is the one the old code passed on. D1/D2/D4 are the ones `?? []` also masked.

const shapes = (field) => [
  ["D1 no result at all", {}],
  ["D2 result without the field", { result: {} }],
  ["D3 field present but EMPTY", { result: { [field]: [] } }],
  ["D4 field present but null", { result: { [field]: null } }],
];

// ── LEG 1: m17b-arrange-zoom.mjs:133 "still no zoom entries in undo" ──────────
// Absence assertion. The gate HAS performed an undoable edit by :124 (project.new
// then track.add), so the count pin is licensed AND presence is licensed — the
// filed item framed these as alternatives; reading the gate showed both apply.
const leg_m17b = (r) => {
  const undoLabels = r.result?.undo ?? [];
  return Array.isArray(r.result?.undo) && undoLabels.length >= 1
    && undoLabels.every((l) => !/zoom|ppb|row/i.test(l));
};

// ── LEG 2: m23a2-insert-slot-reserve.mjs:359 G3 ──────────────────────────────
// Pin on the SOURCE, not the slice: slice(0,3) of a short list is legal and short.
const leg_m23a2 = (floor) => {
  const floorFaders = floor.mixerFader ?? [];
  return floorFaders.length >= 3 && floorFaders.slice(0, 3).every((r) => r.height >= 100);
};

// ── LEG 3: m23k4a-midi-export.mjs:181 D8 ─────────────────────────────────────
const leg_m23k4a = (snap) => {
  const backTracks = snap.tracks ?? [];
  return Array.isArray(snap.tracks) && backTracks.length >= 2
    && backTracks.every((t) => t.name !== "Vox");
};

let bad = 0;
const run = (name, leg, field, healthy, healthyLabel, unwrap = (x) => x) => {
  console.log(`\n── ${name} ──`);
  for (const [label, shape] of shapes(field)) {
    const passes = leg(unwrap(shape));
    const ok = passes === false; // a degenerate response MUST redden
    if (!ok) bad++;
    console.log(`  ${ok ? "✓ REDDENS" : "✗ STILL PASSES (pin is decorative)"}  ${label}`);
  }
  const h = leg(healthy);
  if (h !== true) bad++;
  console.log(`  ${h ? "✓" : "✗"} healthy shape passes  ${healthyLabel}`);
};

// m17b reads `r.result.undo`; the healthy shape is the one the LIVE run measured.
run("m17b:133 still no zoom entries in undo", leg_m17b, "undo",
    { result: { undo: ["Add Track 'OrchA'"], redo: [] } },
    "measured live: {\"undo\":[\"Add Track 'OrchA'\"],\"redo\":[]}");

// m23a2/m23k4a read a bare object (already-unwrapped frames/snapshot), so the
// degenerate shapes are unwrapped one level to match how the gate holds them.
// MEASURED live this cycle, from G3's new detail argument: {"faders":5,"h":[107,107,107]}.
// ⚠️ Worth recording: the margin is 7 pt (107 against the 100 pt floor). That is the
// PRE-EXISTING assertion, untouched by this item — but it means G3 is a tight leg, and
// anything that costs the fader region ~8 pt at the 672 pt window floor reddens it.
run("m23a2:359 G3 reserved cluster intact", leg_m23a2, "mixerFader",
    { mixerFader: [{ height: 107 }, { height: 107 }, { height: 107 }, { height: 107 }, { height: 107 }] },
    "MEASURED: 5 faders, h=[107,107,107] vs the 100 pt floor",
    (s) => s.result ?? s);

// D8 prints its detail only on FAIL, so the healthy shape is attested by the leg
// PASSING live rather than by a printed value: `Array.isArray && length >= 2` held.
run("m23k4a:181 D8 audio track is not a MIDI part", leg_m23k4a, "tracks",
    { tracks: [{ name: "Lead" }, { name: "Pad" }] },
    "live PASS attests isArray && length >= 2 (C4 pins tracksExported === 2)",
    (s) => s.result ?? s);

// ── The control: the OLD code must FAIL this same test, or the test is blind ──
// If the pre-fix expression also reddened on D1-D4, there was never a defect and
// this whole item is theatre. Proving the old shape PASSES on empty is what makes
// the new shape's reddening meaningful.
console.log("\n── POSITIVE CONTROL: the PRE-FIX expressions on the same shapes ──");
const old_m17b   = (r) => (r.result?.undo ?? []).every((l) => !/zoom|ppb|row/i.test(l));
const old_m23a2  = (f) => (f.mixerFader ?? []).slice(0, 3).every((r) => r.height >= 100);
const old_m23k4a = (s) => (s.tracks ?? []).every((t) => t.name !== "Vox");
for (const [nm, fn, field, unwrap] of [
  ["m17b", old_m17b, "undo", (x) => x],
  ["m23a2", old_m23a2, "mixerFader", (s) => s.result ?? s],
  ["m23k4a", old_m23k4a, "tracks", (s) => s.result ?? s],
]) {
  const passed = shapes(field).filter(([, s]) => fn(unwrap(s)) === true);
  const blind = passed.length === 4;
  if (!blind) bad++;
  console.log(`  ${blind ? "✓" : "✗"} OLD ${nm}: passed ${passed.length}/4 degenerate shapes`
    + ` (${passed.map(([l]) => l.split(" ")[0]).join(",")}) — expected 4/4, i.e. fully vacuous`);
}

console.log(`\nREDDEN_2B ${bad === 0 ? "ALL LEGS LOAD-BEARING" : `${bad} PROBLEM(S)`}`);
process.exit(bad === 0 ? 0 : 1);
