// m23-r3 gate — per-insert spectrum, TURNED ON in the UI.
//
// The engine side landed across m23-r1 (the InsertSpectrumTap SPSC ring),
// r2a (wired into the effect chain) and r2b (an 11-leg coverage matrix). This
// gate covers the UI enablement ONLY: a TRACK EQ card now draws the same green
// spectrum fill the MASTER card has drawn since m22-b, fed by that insert's own
// armed tap.
//
// Staging: DAW_CONTROL_PORT=17695 .build/debug/DAWApp   (17600 is the user's
// LIVE app — never touched). Kill staging by EXACT PID from its pidfile.
// Output: captures land under /tmp/daw-gate-out/m23r3/ (created by the script).
//
// ⚠️ THE FIXTURE-LIVENESS LAW — the thing most likely to make this gate lie.
// Nearly every claim here is about a MEASUREMENT, and a dead fixture reads
// max=0.000 — which SATISFIES every "floor", "flat" and "no reading" leg. So
// the failure mode that matters is not a red run, it is a green one taken
// against silence. Two defences, both mandatory when adding a leg:
//   (a) the fixture is ~68 minutes long (FIXTURE_BEATS), an order of magnitude
//       past any plausible machine load — see the Setup block for why 128 beats
//       was a latent flake that reddened a different leg on each slow run;
//   (b) EVERY leg whose claim could be satisfied by silence asserts a REAL
//       reading first: L3b before L3f's zero, L4a0 before L4d's floor, L5a2
//       after the replay, L6a before the fader comparison, L7e's low-band
//       clause, L8c's magnitude. If you add a leg that expects nothing, add
//       the precondition that proves it expected something.
//
// WHAT EACH LEG IS FOR — read before editing one:
//
//   L1  A track EQ card draws a LIVE spectrum. Asserts the bands are actually
//       OFF THE FLOOR, never just that time passed: a freshly armed tap
//       honestly reads `.floor` until ~2048 frames (~43 ms @ 48 kHz) have
//       rendered, so a capture taken too early is pixel-identical to the
//       disarmed one and the whole gate would be decorative.
//   L2  The MASTER card is unchanged from m22-b — still the whole-mix reading,
//       still driven by `debug.vibeSeed`, and it takes NO insert tap
//       (`spectrumSource: "master"` is the proof: that branch never calls
//       `insertAnalysis`).
//   L3  THE DISCRIMINATION LEG. A floor silhouette and a MISSING layer render
//       identically, so pixels cannot tell them apart and neither can a
//       heights-are-zero assertion on its own. With the SAME seeded data
//       available, the layer present must MOVE the heights and the layer
//       absent must leave them flat. Ordered LIVE → DEAD → LIVE so the zero
//       sits between two proofs that this data draws. This is also arm/disarm
//       proven through the seam: dropping the plot (Simple→Pro) cancels the
//       layer's `.task(id:)`, which releases the tap.
//   L4  shown + FLOOR is a THIRD state, not the absent one: layer present,
//       armed, heights at floor. The card is proven READING first and is NOT
//       reopened, so the floor is a DECAY caused by the stop rather than a
//       fresh card's free zero. L3 is what makes this leg mean something.
//   L5  TARGET CHANGE — arm A, switch to B, switch back to A, five times with
//       no settle between. `.task(id:)`'s cancellation is NOT ordered before
//       the next task's start, so a release that fires unconditionally can
//       disarm a tap a newer task just took. The generation token in
//       AppModel.releaseInsertSpectrum is what stops that; this leg is what
//       proves the token load-bearing.
//   L8  THE SLOT HOLDS AT MOST ONE ARM — 11 distinct inserts on one track,
//       walked past the engine's cap of 8. A leaked arm is invisible under the
//       cap and fatal above it (arming REFUSES rather than evicts).
//   L7  TWO INSERTS ON ONE TRACK — the retarget where only effectID changes,
//       and the only one whose failure is silent rather than a floor. Proven
//       from the DATA (a low-pass on the second insert), not from motion.
//   L6  THE LABELLING LAW. A strip insert taps PRE-fader — measured at r2b as
//       0.0 dB of movement on a 1.0 → 0.5 track-fader move, against 6.0206 dB
//       for the same move on the MASTER fader. The track card's caption says
//       so; this leg proves the caption true at the UI seam (and self-checks
//       the fixture's stationarity first, so "unchanged" cannot pass by noise).
//
// Promoted from the session scratchpad at the m23-r3 close (2026-07-28).
import { mkdirSync } from "node:fs";

const OUT = "/tmp/daw-gate-out/m23r3";
mkdirSync(OUT, { recursive: true });

const sleep = ms => new Promise(r => setTimeout(r, ms));
async function connect() {
  for (let i = 0; i < 20; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket("ws://127.0.0.1:17695");
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(1000); }
  }
  throw new Error("could not connect to staging on 17695");
}
const ws = await connect();
let n = 0, pass = 0, fail = 0;
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const i = `r3_${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};

// ── Spectrum probe helpers ────────────────────────────────────────────────
// NONE of these drain the tap. `spectrumHeights` is the LAYER's own smoothed
// output — downstream of the one drain — so reading it proves the layer polled
// AND smoothed without becoming a second consumer of a ring that has room for
// exactly one (a second consumer would surface as a plausible STALE reading,
// never an error).
const BANDS = 24;
async function spectrum() {
  const r = await cmd("debug.effectEditor", {});
  if (!r.ok) throw new Error("debug.effectEditor failed: " + r.error);
  const s = r.result ?? {};
  const h = s.spectrumHeights ?? [];
  return {
    shown: s.spectrumShown, armed: s.spectrumArmed, source: s.spectrumSource,
    mode: s.editorMode, visible: s.visible, heights: h, help: s.curveHelp,
    max: h.length ? Math.max(...h) : -1,
    argmax: h.length ? h.indexOf(Math.max(...h)) : -1,
    live: h.filter(v => v > 0.02).length,
    brief() {
      return `shown=${s.spectrumShown} armed=${s.spectrumArmed} src=${s.spectrumSource} `
        + `mode=${s.editorMode} n=${h.length} max=${(h.length ? Math.max(...h) : -1).toFixed(3)} `
        + `live=${h.filter(v => v > 0.02).length}`;
    },
  };
}
// A distinctive seeded silhouette: everything at the display floor except ONE
// band, so "the layer moved" has a checkable SHAPE and not just a magnitude.
const SEED_PEAK_BAND = 5;
const seedBands = () =>
  Array.from({ length: BANDS }, (_, i) => (i === SEED_PEAK_BAND ? -8 : -70));

// ── Setup ─────────────────────────────────────────────────────────────────
// A SUSTAINED chord on the built-in polySynth: the spectrum has to be
// stationary or L6's "the fader did not move it" cannot be told from noise.
// Master volume 0 so the run is silent to whoever is at the machine — which
// costs the tap nothing, because a strip insert taps PRE-fader (that IS the
// law under test).
//
// ⚠️ FIXTURE LENGTH IS A CORRECTNESS PARAMETER, NOT A STYLE CHOICE. The first
// version used 128 beats = 64 s at the default 120 BPM, and NOTHING loops the
// transport or re-triggers the chord. The gate's own playing wall-clock is the
// same order of magnitude (L8 alone is 11 × 700 ms + settle ≈ 9 s, and every
// `cmd` round trip costs more on a loaded machine), so on a busy box the chord
// simply ENDED mid-run and every downstream leg read max=0.000. Observed three
// times by the coordinator: 61/62 (L8c), 52/62 (L5e and everything after),
// 62/62 — a cascade starting at a DIFFERENT leg each run, which is the
// signature of a wall-clock race and not a logic bug.
//
// 8192 beats ≈ 68 MINUTES at 120 BPM. That is not a tuned margin, it is an
// order of magnitude past any plausible load, which is the point: a gate that
// reddens on a slow machine trains everyone to ignore it.
const FIXTURE_BEATS = 8192;
let r = await cmd("project.new", { discardChanges: true });
ck("S1 project.new", r.ok, r.error);
r = await cmd("mixer.setMasterVolume", { volume: 0 });
ck("S2 master volume 0 (silent run; the strip tap is pre-fader)", r.ok, r.error);

async function makeVoice(name) {
  let x = await cmd("track.add", { kind: "instrument", name });
  const tid = (x.result?.track ?? x.result)?.id;
  await cmd("track.setInstrument", {
    trackId: tid, kind: "polySynth", waveform: "saw",
    attack: 0.01, decay: 0.05, sustain: 1.0, release: 0.1, gain: 0.8,
  });
  await cmd("clip.addMIDI", {
    trackId: tid, atBeat: 0, lengthBeats: FIXTURE_BEATS,
    notes: [40, 47, 52, 59, 64].map(p =>
      ({ pitch: p, startBeat: 0, lengthBeats: FIXTURE_BEATS, velocity: 110 })),
  });
  x = await cmd("fx.add", { trackId: tid, kind: "eq" });
  const eq = x.result?.effectId ?? x.result?.effect?.id;
  return { tid, eq };
}
const A = await makeVoice("SpectrumA");
const B = await makeVoice("SpectrumB");
ck("S3 two instrument tracks each with an EQ insert", !!A.tid && !!A.eq && !!B.tid && !!B.eq,
  JSON.stringify({ A, B }));
r = await cmd("fx.add", { trackId: "master", kind: "eq" });
const eqM = r.result?.effectId ?? r.result?.effect?.id;
ck("S4 master EQ insert", r.ok && !!eqM, r.error);
r = await cmd("debug.panelDensity", { panel: "effectEditor", mode: "simple" });
ck("S5 effect editor density = simple (the curve surface)", r.ok, r.error);
r = await cmd("transport.play");
ck("S6 transport rolling", r.ok, r.error);
await sleep(600);

// ── L1: a TRACK EQ card draws a LIVE spectrum ─────────────────────────────
r = await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
ck("L1a track EQ card open on the curve surface",
  r.ok && r.result?.visible === true && r.result?.editorMode === "curve",
  JSON.stringify(r.result)?.slice(0, 160));
await sleep(1200);
let s = await spectrum();
ck("L1b the spectrum layer is SHOWN on a track card (m22-b showed none)", s.shown === true, s.brief());
ck("L1c its tap is ARMED", s.armed === true, s.brief());
ck("L1d it reads THIS INSERT's tap, not the master mix", s.source === "insert", s.brief());
ck("L1e 24 bands", s.heights.length === BANDS, s.heights.length);
// The load-bearing assertion: OFF THE FLOOR. A tap armed < ~43 ms ago honestly
// reads floor, and a floor capture is indistinguishable from a disarmed one.
ck("L1f the bands are genuinely OFF THE FLOOR (real audio reached the tap)",
  s.max > 0.10 && s.live >= 6, s.brief());
// THE LABELLING LAW AT THE WIRE. `.help` is a tooltip — `debug.captureUI`
// cannot see it — so without this the cycle's headline decision would be pinned
// as a FUNCTION (unit tests) and unpinned as a WIRE. The probe resolves the
// caption through the SAME one-home call the card makes.
ck("L1g the track card's caption says PRE-FADER, not the master wording",
  typeof s.help === "string" && s.help.includes("BEFORE the fader")
  && s.help.includes("AFTER this EQ") && !s.help.includes("master-mix"),
  JSON.stringify(s.help));
const TRACK_HELP = s.help;
r = await cmd("debug.captureUI", { path: `${OUT}/L1-track-eq-live.png` });
ck("L1h captured the live track EQ card", r.ok, r.error);

// ── L2: the MASTER card is unchanged from m22-b ───────────────────────────
r = await cmd("debug.effectEditor", { trackId: "master", effectId: eqM, open: true });
ck("L2a master EQ card open", r.ok && r.result?.visible === true, r.error);
await sleep(900);
s = await spectrum();
ck("L2b the master card still draws its spectrum", s.shown === true, s.brief());
ck("L2c it still reads the WHOLE MIX, and takes no insert tap", s.source === "master", s.brief());
ck("L2d a master card is always measuring (masterAnalysis needs no arm)",
  s.armed === true, s.brief());
// m22-b's caption, byte-identical, and NOT the track one: two different
// measurements in identical green ink must never share words.
ck("L2d2 the master caption is m22-b's, unchanged and distinct from the track's",
  s.help === "The green fill is the live master-mix spectrum — context only; "
    + "its height is not the EQ's dB scale." && s.help !== TRACK_HELP,
  JSON.stringify(s.help));
r = await cmd("debug.vibeSeed", { bands: seedBands(), levelDB: -9 });
ck("L2e debug.vibeSeed still stages the MASTER card", r.ok, r.error);
await sleep(900);
s = await spectrum();
ck("L2f the master card prefers vibeSeed over the live poll", s.source === "masterSeed", s.brief());
ck("L2g and it draws the seeded silhouette", s.argmax === SEED_PEAK_BAND && s.max > 0.5,
  s.brief() + ` argmax=${s.argmax}`);
r = await cmd("debug.captureUI", { path: `${OUT}/L2-master-eq-seeded.png` });
ck("L2h captured the master card", r.ok, r.error);
await cmd("debug.vibeSeed", { clear: true });

// ── L3: DRAWN FLOOR vs MISSING LAYER (the discrimination leg) ─────────────
// Same data staged in both halves; the only difference is whether the layer
// exists. A heights-are-zero check alone would pass for the wrong reason.
//
// ORDER IS LOAD-BEARING: LIVE → DEAD → LIVE. The zero assertion runs BETWEEN
// two proofs that this exact seeded data draws, so it can only mean "the layer
// is gone". Written dead-first (as it was) the zero would also be satisfied by
// a fixture that had simply stopped producing — the same
// passing-on-silence trap this gate's own L7e fell into, one leg over.
r = await cmd("debug.insertSpectrumSeed", { bands: seedBands(), levelDB: -9 });
ck("L3a debug.insertSpectrumSeed stages the TRACK card (separate from vibeSeed)", r.ok, r.error);
await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
await sleep(1200);
s = await spectrum();
ck("L3b PRECONDITION — with the layer present this seed genuinely DRAWS "
  + "(without this the zero below is unearned)",
  s.shown === true && s.source === "insertSeed"
  && s.argmax === SEED_PEAK_BAND && s.max > 0.5, s.brief() + ` argmax=${s.argmax}`);
r = await cmd("debug.panelDensity", { panel: "effectEditor", mode: "pro" });
ck("L3c density → pro", r.ok, r.error);
// Re-open so the curve model (and its smoothed heights) is FRESH — otherwise
// "flat" could just be a leftover from a previous card.
await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
await sleep(1200);
s = await spectrum();
ck("L3d PRO renders the knob table, so there is no plot and no spectrum layer",
  s.mode === "knobs" && s.shown === false, s.brief());
ck("L3e no layer ⇒ the tap is RELEASED (the .task(id:) cancelled)",
  s.armed === false, s.brief());
ck("L3f no layer ⇒ the heights never advance, even with data that JUST drew",
  s.max === 0, s.brief());
ck("L3g no plot ⇒ no caption at all (the field mirrors the view's existence)",
  s.help === null || s.help === undefined, JSON.stringify(s.help));
r = await cmd("debug.captureUI", { path: `${OUT}/L3-track-eq-pro-no-layer.png` });
ck("L3h captured the absent-layer card", r.ok, r.error);
r = await cmd("debug.panelDensity", { panel: "effectEditor", mode: "simple" });
ck("L3i density → simple", r.ok, r.error);
await sleep(1200);
s = await spectrum();
ck("L3j the layer returns", s.mode === "curve" && s.shown === true, s.brief());
ck("L3k and re-ARMS the tap (same seam, opposite direction)", s.armed === true, s.brief());
ck("L3l it prefers insertSpectrumSeed over the live poll", s.source === "insertSeed", s.brief());
ck("L3m THE DISCRIMINATION: identical data, the present layer draws the seeded "
  + "SHAPE again — closing the live → dead → live sandwich",
  s.argmax === SEED_PEAK_BAND && s.max > 0.5, s.brief() + ` argmax=${s.argmax}`);
r = await cmd("debug.captureUI", { path: `${OUT}/L3-track-eq-seeded.png` });
ck("L3n captured the seeded track card", r.ok, r.error);
await cmd("debug.insertSpectrumSeed", { clear: true });

// ── L4: shown + FLOOR is a THIRD state ────────────────────────────────────
// PRECONDITION FIRST, for the same reason as L3: the card must be READING
// before the transport stops, or "draws the honest floor" is satisfied by a
// fixture that had already died and the leg proves nothing at all.
await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
await sleep(1500);
s = await spectrum();
ck("L4a0 PRECONDITION — the card is reading LIVE audio before the stop",
  s.source === "insert" && s.max > 0.10 && s.live >= 6, s.brief());
r = await cmd("transport.stop");
ck("L4a transport stopped", r.ok, r.error);
// The card is NOT reopened here on purpose: the heights must DECAY from the
// live reading L4a0 just proved down to the floor. A fresh card would start at
// zero and the floor claim would be free.
await sleep(2500);
s = await spectrum();
ck("L4b the layer is still SHOWN and still ARMED with no signal", s.shown === true && s.armed === true,
  s.brief());
ck("L4c it reads the live tap (unseeded)", s.source === "insert", s.brief());
ck("L4d and draws the honest FLOOR — nothing fabricated", s.max < 0.02, s.brief());
r = await cmd("debug.captureUI", { path: `${OUT}/L4-track-eq-floor.png` });
ck("L4e captured the floor state", r.ok, r.error);

// ── L5: TARGET CHANGE, A → B → A ──────────────────────────────────────────
// Seek to 0 BEFORE replaying: the fixture's notes start at beat 0 and run 128
// beats, and starting playback from inside a note never re-triggers it — which
// is exactly how L5/L6 first went green-at-floor, proving nothing.
await cmd("transport.seek", { beats: 0 });
r = await cmd("transport.play");
ck("L5a transport rolling again", r.ok, r.error);
await sleep(900);
s = await spectrum();
ck("L5a2 the fixture is audible again after the stop (never assert on silence)",
  s.max > 0.10, s.brief());
// One SLOW round first: each card must arm and read its own insert.
await cmd("debug.effectEditor", { trackId: B.tid, effectId: B.eq, open: true });
await sleep(1200);
s = await spectrum();
ck("L5b retargeting to B arms B and reads it live",
  s.armed === true && s.source === "insert" && s.max > 0.10, s.brief());
await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
await sleep(1200);
s = await spectrum();
ck("L5c retargeting back to A re-arms A and reads it live",
  s.armed === true && s.source === "insert" && s.max > 0.10, s.brief());
// Now the RACE: five A→B→A cycles with no settle between, so a cancelled
// task's release lands while a newer task already holds the slot.
for (let k = 0; k < 5; k++) {
  await cmd("debug.effectEditor", { trackId: B.tid, effectId: B.eq, open: true });
  await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
}
await sleep(1500);
s = await spectrum();
ck("L5d after 5 rapid A→B→A cycles the slot still holds A — a stale release "
  + "must not disarm a tap a newer task took", s.armed === true, s.brief());
ck("L5e and A is still measuring for real", s.max > 0.10 && s.live >= 6, s.brief());
// The mirror: end on B and check the same.
for (let k = 0; k < 5; k++) {
  await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
  await cmd("debug.effectEditor", { trackId: B.tid, effectId: B.eq, open: true });
}
await sleep(1500);
s = await spectrum();
ck("L5f the mirror cycle ends with B armed and measuring",
  s.armed === true && s.max > 0.10, s.brief());

// ── L6: THE PRE-FADER LABELLING LAW at the UI seam ────────────────────────
// The track card's caption promises "measured BEFORE the fader — so moving the
// track fader will not move it". This leg proves that promise where the USER
// meets it: the drawn heights.
//
// The fader is taken to ZERO, not to 0.25. That makes the two hypotheses
// unmissable rather than a matter of tolerance: a POST-fader tap at volume 0
// reads pure silence (every band at the floor), while a PRE-fader tap is
// untouched. And the "untouched" half is judged against the fixture's OWN
// measured drift, not a constant — the polysynth chord wobbles up to ~0.07 in
// the mid bands all by itself, which is what made a fixed 0.03 tolerance fail
// this leg for entirely the wrong reason on the first run.
await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
await cmd("track.setVolume", { trackId: A.tid, volume: 1.0 });
await sleep(2000);
const drift = (x, y) => Math.max(...x.map((v, i) => Math.abs(v - y[i])));
const base = [];
for (let k = 0; k < 3; k++) { base.push((await spectrum()).heights); await sleep(1200); }
const natural = Math.max(drift(base[0], base[1]), drift(base[1], base[2]),
  drift(base[0], base[2]));
// An empty sweep is a result, not a pass: two SILENCES also "agree".
ck("L6a there is a real reading to compare (never assert on two silences)",
  Math.max(...base[2]) > 0.10, `max=${Math.max(...base[2]).toFixed(3)}`);
console.log(`     (fixture's own drift across 3 samples at a fixed fader: ${natural.toFixed(4)})`);
r = await cmd("track.setVolume", { trackId: A.tid, volume: 0.0 });
ck("L6b track fader 1.0 → 0.0 (the track is now silent at the output)", r.ok, r.error);
await sleep(2500);
const H2 = (await spectrum()).heights;
// THE DECISIVE ONE: a post-fader tap would read the floor here.
ck("L6c a strip insert taps PRE-FADER: at fader 0 the insert is still reading",
  Math.max(...H2) > 0.10, `max=${Math.max(...H2).toFixed(3)}`);
ck("L6d and the fader moved it no more than the fixture moves itself — "
  + "which is what the card's caption promises",
  drift(base[2], H2) <= natural * 1.6 + 0.01,
  `faderDrift=${drift(base[2], H2).toFixed(4)} vs natural=${natural.toFixed(4)}`);
await cmd("track.setVolume", { trackId: A.tid, volume: 1.0 });

// ── L7: TWO INSERTS ON ONE TRACK — retarget by effectID ALONE ─────────────
// L5 always moved BOTH fields of EffectEditorTarget at once (A and B are
// different tracks). The configuration never exercised is the harder one: two
// EQs on the SAME strip, where only `effectID` changes. It is also the only
// one whose failure is SILENT — everywhere else a mis-keyed arm collapses to
// floor and the `max > 0.10` guards catch it, but a slot that compared only
// `trackID` would keep the FIRST insert's tap armed and reading while the card
// showed the second: a plausible WRONG curve, which is exactly the stale-read
// class the single-consumer invariant exists to prevent.
//
// So the two inserts are made to read DIFFERENTLY. The tap is post-insert
// ("the spectrum AFTER this EQ") and the chain runs eq → eq2, so a steep
// low-pass on eq2 strips the highs from eq2's tap while eq1's tap upstream
// still has them. Identity is then checkable from the DATA, not assumed from
// the fact that something moved.
r = await cmd("fx.add", { trackId: A.tid, kind: "eq" });
const A2 = r.result?.effectId ?? r.result?.effect?.id;
ck("L7a a SECOND EQ insert on the same track", r.ok && !!A2 && A2 !== A.eq, r.error);
await cmd("fx.setParam", { trackId: A.tid, effectId: A2, name: "lowPassFreq", value: 200 });
r = await cmd("fx.setParam", { trackId: A.tid, effectId: A2,
  name: "lowPassSlopeDbPerOct", value: 24 });
ck("L7b eq2 set to a steep 200 Hz low-pass (so the two taps cannot look alike)",
  r.ok, r.error);
// The arm was live on A.eq while fx.add rebuilt the chain — a free check that
// the arm survives a rebuild (r2a's claim), before anything is retargeted.
await sleep(1500);
s = await spectrum();
ck("L7c the FIRST insert's arm survived the chain rebuild and still reads live",
  s.armed === true && s.source === "insert" && s.max > 0.10, s.brief());
const H_EQ1 = s.heights;
// Retarget by effectID alone.
await cmd("debug.effectEditor", { trackId: A.tid, effectId: A2, open: true });
await sleep(1800);
s = await spectrum();
ck("L7d retargeting to the second insert on the SAME track arms and reads it",
  s.armed === true && s.source === "insert" && s.max > 0.10, s.brief());
const H_EQ2 = s.heights;
// THE IDENTITY PROOF: the top third of the band range, post-200 Hz-low-pass,
// must have collapsed. A trackID-only slot would still be reading eq1 here and
// would show the SAME highs — live, plausible, and wrong.
const hi = a => Math.max(...a.slice(16));
const lo = a => Math.max(...a.slice(0, 8));
// The LOW half must still be alive. Without that clause this check passes on
// SILENCE — a floor reading has "lost the highs" too, and mutation M11 (keying
// the .task on trackID alone) made it pass for exactly that wrong reason while
// the card sat at floor. An empty sweep is a result, not a pass.
ck("L7e it is reading THE SECOND insert, not still the first: the low-passed "
  + "tap kept its lows and lost the highs the upstream tap still shows",
  hi(H_EQ1) > 0.10 && lo(H_EQ2) > 0.10 && hi(H_EQ2) < hi(H_EQ1) * 0.5,
  `hi(eq1)=${hi(H_EQ1).toFixed(3)} lo(eq2)=${lo(H_EQ2).toFixed(3)} hi(eq2)=${hi(H_EQ2).toFixed(3)}`);
// And back — the same move in the other direction.
await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
await sleep(1800);
s = await spectrum();
ck("L7f retargeting BACK to the first insert re-arms it and the highs return",
  s.armed === true && s.max > 0.10 && hi(s.heights) > hi(H_EQ2) * 1.5,
  s.brief() + ` hi=${hi(s.heights).toFixed(3)}`);
// The race, within one track: five rapid eq1→eq2 cycles, ending on eq2.
for (let k = 0; k < 5; k++) {
  await cmd("debug.effectEditor", { trackId: A.tid, effectId: A.eq, open: true });
  await cmd("debug.effectEditor", { trackId: A.tid, effectId: A2, open: true });
}
await sleep(1800);
s = await spectrum();
ck("L7g after 5 rapid same-track cycles the slot holds eq2 — armed, live, "
  + "and reading the low-passed tap",
  s.armed === true && s.max > 0.10 && hi(s.heights) < hi(H_EQ1) * 0.5,
  s.brief() + ` hi=${hi(s.heights).toFixed(3)}`);

// ── L8: THE SLOT HOLDS AT MOST ONE ARM — walk PAST the engine cap ─────────
// The other half of the single-consumer invariant, and the half L7 alone
// cannot see. If a retarget arms the new insert without RELEASING the old, the
// arms accumulate silently: nothing is wrong on screen, because the card polls
// the insert it is showing. The engine's cap is 8 armed taps and it REFUSES
// rather than evicts — so the leak only becomes visible on the NINTH distinct
// insert, where arming fails and the card stops measuring for good.
//
// This leg was written because mutation M12 (a release that compares trackID
// only, so a same-track retarget leaks) left the whole gate GREEN: L7 walks
// just two inserts, and two is under the cap. A hole that mutation finds after
// the suite is green is the only kind worth this many lines.
const CAP = 8;
const chain = [B.eq];
for (let k = 0; k < CAP + 2; k++) {           // 11 distinct inserts > cap of 8
  const a = await cmd("fx.add", { trackId: B.tid, kind: "eq" });
  chain.push(a.result?.effectId ?? a.result?.effect?.id);
}
ck("L8a a chain of 11 distinct EQ inserts on one track (cap is 8)",
  chain.every(Boolean) && new Set(chain).size === chain.length, chain.length);
let firstDead = -1, deadBrief = "";
for (let i = 0; i < chain.length; i++) {
  await cmd("debug.effectEditor", { trackId: B.tid, effectId: chain[i], open: true });
  await sleep(700);
  const t = await spectrum();
  if (!(t.armed === true && t.source === "insert") && firstDead < 0) {
    firstDead = i; deadBrief = t.brief();
  }
}
ck("L8b opening all 11 in turn never exhausts the cap — one arm is held, "
  + "not accumulated (a leak would REFUSE from the 9th on)",
  firstDead < 0, `first dead insert index=${firstDead} ${deadBrief}`);
await sleep(1200);
s = await spectrum();
ck("L8c and the last one is genuinely measuring, not just nominally armed",
  s.armed === true && s.max > 0.10, s.brief());

await cmd("transport.stop");
await cmd("debug.effectEditor", { close: true });
console.log(`M23R3_GATE pass=${pass} fail=${fail}`);
ws.close();
process.exit(fail ? 1 : 0);
