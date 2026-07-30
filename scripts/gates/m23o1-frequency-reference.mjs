// m23-o1 gate — the instrument frequency reference, LIVE on the control wire.
//
// Staging: DAW_CONTROL_PORT=17695 .build/debug/DAWApp   (17600 is the user's
// LIVE app — NEVER touched). Kill staging by EXACT PID from its pidfile.
//
// This is design §8.2's S1–S8. It is NOT a wire round-trip with extra steps:
// S3–S6 take the high-pass corner THE SHIPPED TABLE RECOMMENDS, apply it
// through `fx.setParam`, and measure what it did through `fx.spectrum`. The
// gate therefore fails if the shipped DATA is wrong, not merely if the
// plumbing is.
//
// ⚠️ FIXTURE-LIVENESS LAW (m23-r3 paid for this). Nearly every leg here is a
// claim about a MEASUREMENT, and a DEAD fixture reads floor — which SATISFIES
// any "the low band dropped" leg. A green run taken against silence is the
// failure mode that matters, not a red one. Two defences, both mandatory:
//   (a) the clip is FIXTURE_BEATS long — orders of magnitude past any
//       plausible machine stall, so the notes cannot end mid-run;
//   (b) S2 runs BEFORE any filter leg and asserts the fixture is genuinely
//       SOUNDING (band 0 and band 8 both off the floor). Every later delta is
//       measured against a baseline S2 has already proven alive.
//
// THE FIXTURE, and why these two notes:
//   `MasterMixAnalyzer` is 24 log bands from 40 Hz to 16 kHz, ratio 1.297577.
//   MIDI 30 = 46.25 Hz  -> band 0.56  (solidly INSIDE band 0)
//   MIDI 65 = 349.23 Hz -> band 8.32  (solidly INSIDE band 8)
//   MIDI 32 (51.91 Hz) was REJECTED: it lands at band 1.00, exactly on the
//   0/1 edge, where a rounding difference silently moves the reading a band.
//   Bands 2…6 (67…248 Hz) sit BETWEEN the two tones and carry no fundamental,
//   which is what makes the sine-purity clause meaningful.
//
// A NOTE ON WHAT S4 IS FOR. S3 asserts the row's own corner barely moves the
// instrument. A `fx.setParam` that silently did NOTHING would also satisfy
// that. S4 applies a DELIBERATELY WRONG corner through the SAME comparison
// code path and demands a BIG delta. S3 without S4 is decorative.
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";

const PORT = 17695;                 // staging. NEVER 17600.
const OUT = "/tmp/daw-gate-out/m23o1";
const PIDFILE = `${OUT}/staging.pid`;
const FIXTURE_BEATS = 4096;         // ~68 min at 60 bpm — cannot end mid-run
const LOW_NOTE = 30;                // 46.25 Hz -> band 0
const HIGH_NOTE = 65;               // 349.23 Hz -> band 8
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

mkdirSync(OUT, { recursive: true });

// ---------------------------------------------------------------- staging up
let child = null;
function startStaging() {
  child = spawn(".build/debug/DAWApp", [], {
    cwd: "/Users/dsemenov/Views/daw-pro",
    env: { ...process.env, DAW_CONTROL_PORT: String(PORT) },
    stdio: ["ignore", "pipe", "pipe"],
    detached: false,
  });
  writeFileSync(PIDFILE, String(child.pid));
  const log = [];
  child.stdout.on("data", (d) => log.push(d.toString()));
  child.stderr.on("data", (d) => log.push(d.toString()));
  process.on("exit", () => writeFileSync(`${OUT}/staging.log`, log.join("")));
}

// Kill by the EXACT pid we recorded. NEVER pkill/pgrep — a pattern kill here
// could take down the user's live app on 17600.
function stopStaging() {
  if (!existsSync(PIDFILE)) return;
  const pid = Number(readFileSync(PIDFILE, "utf8").trim());
  if (Number.isInteger(pid) && pid > 0) {
    try { process.kill(pid, "SIGTERM"); } catch { /* already gone */ }
  }
  rmSync(PIDFILE, { force: true });
}

async function connect() {
  for (let i = 0; i < 40; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket(`ws://127.0.0.1:${PORT}`);
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(1000); }
  }
  throw new Error(`could not connect to staging on ${PORT}`);
}

// ------------------------------------------------------------------ harness
let ws, seq = 0, pass = 0, fail = 0;
const failures = [];
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = `o1-${++seq}`;
    const timer = setTimeout(() => rej(new Error(`timeout ${command}`)), timeoutMs);
    const onMsg = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id !== id) return;
      clearTimeout(timer); ws.removeEventListener("message", onMsg); res(m);
    };
    ws.addEventListener("message", onMsg);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
function ck(label, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS ${label}`); }
  else { fail++; failures.push(label); console.log(`FAIL ${label} ${detail}`); }
}
const fin = (a) => Array.isArray(a) && a.length === 24 && a.every(Number.isFinite);

async function spectrum(trackId, effectId) {
  const r = await cmd("fx.spectrum", { trackId, effectId, arm: true });
  return r.result ?? null;
}

// MEASURED, FIRST RUN: every reading taken after the one-shot baseline sat
// ~10 dB below it UNIFORMLY — band 8 "moved" 10.06 dB under a 30 Hz high-pass
// that cannot physically touch a 349 Hz tone. That is level drift in the
// fixture, not filtering, and a single global baseline silently attributes all
// of it to whatever leg runs next. S3/S5/S6 all failed on that artefact.
//
// So every filter claim is measured as an A/B PAIR, adjacent in time, toggling
// ONLY `highPassEnabled`: any slow drift is common to both halves and cancels
// in the difference. Returns null if either half failed to measure — a
// measurement helper must never fail open into a zero-filled array.
async function measurePaired(trackId, effectId) {
  await cmd("fx.setParam", { trackId, effectId, name: "highPassEnabled", value: 0 });
  await sleep(500);
  const off = await measure(trackId, effectId);
  await cmd("fx.setParam", { trackId, effectId, name: "highPassEnabled", value: 1 });
  await sleep(500);
  const on = await measure(trackId, effectId);
  if (!off || !on) return null;
  return { off, on, cut: off.map((v, i) => v - on[i]) };   // cut > 0 == attenuated
}
// Average several reads — one quantum is noisy and a single sample can make a
// threshold leg flap. This is a MEASUREMENT helper, so it must never fail open:
// it returns null rather than a zero-filled array if any read is malformed.
async function measure(trackId, effectId, reads = 6) {
  const acc = new Array(24).fill(0);
  let got = 0;
  for (let i = 0; i < reads; i++) {
    const s = await spectrum(trackId, effectId);
    if (!s || !fin(s.bands)) return null;
    for (let b = 0; b < 24; b++) acc[b] += s.bands[b];
    got++;
    await sleep(120);
  }
  if (got !== reads) return null;
  return acc.map((v) => v / reads);
}

// ---------------------------------------------------------------------- run
startStaging();
ws = await connect();

try {
  // ------------------------------------------------------------ arrange
  await cmd("project.new", { discardChanges: true });
  await cmd("transport.setTempo", { bpm: 60 });

  const t = await cmd("track.add", { kind: "instrument", name: "o1 fixture" });
  const trackId = t.result?.id;
  ck("setup: instrument track", !!trackId, JSON.stringify(t.result ?? t.error));

  const si = await cmd("track.setInstrument", {
    trackId, kind: "polySynth", waveform: "sine",
    attack: 0.01, sustain: 1.0, release: 0.1, gain: 0.8,
  });
  ck("setup: sine polySynth", si.error == null, JSON.stringify(si.error ?? "").slice(0, 200));

  const clip = await cmd("clip.addMIDI", { trackId, atBeat: 0, lengthBeats: FIXTURE_BEATS });
  const clipId = clip.result?.id;
  ck("setup: long MIDI clip", !!clipId, JSON.stringify(clip.result ?? clip.error));

  const notes = await cmd("clip.setNotes", {
    clipId,
    notes: [
      { pitch: LOW_NOTE, startBeat: 0, lengthBeats: FIXTURE_BEATS, velocity: 100 },
      { pitch: HIGH_NOTE, startBeat: 0, lengthBeats: FIXTURE_BEATS, velocity: 100 },
    ],
  });
  ck("setup: two sustained tones (band 0 + band 8)", notes.error == null,
     JSON.stringify(notes.error ?? "").slice(0, 200));

  const fx = await cmd("fx.add", { trackId, kind: "eq" });
  const effectId = fx.result?.effectId;
  ck("setup: EQ insert", !!effectId, JSON.stringify(fx.result ?? fx.error));

  await cmd("transport.play", {});
  await sleep(1500);   // let the graph render past the tap's fill time

  // ------------------------------------------------------- S1: on the wire
  const s1 = await cmd("frequency.reference", { family: "electricBass" });
  const ref = s1.result?.reference;
  ck("S1 resolution == family", s1.result?.resolution === "family",
     `got ${s1.result?.resolution} ${JSON.stringify(s1.error ?? "").slice(0, 160)}`);
  ck("S1 fundamental.kind == pitched", ref?.fundamental?.kind === "pitched",
     `got ${JSON.stringify(ref?.fundamental)?.slice(0, 120)}`);
  ck("S1 recommendedHighPass.kind == corner", ref?.recommendedHighPass?.kind === "corner",
     `got ${JSON.stringify(ref?.recommendedHighPass)?.slice(0, 160)}`);

  // The index must ride on EVERY response — that is the whole shape decision.
  const indexFamilies = s1.result?.families;
  ck("S1 families index present on a RESOLVED response",
     Array.isArray(indexFamilies) && indexFamilies.length > 0,
     `len ${indexFamilies?.length}`);

  // DISCRIMINATOR: a collapsed table (every family returning one row) passes
  // every single-sided leg above. Two different families must DIFFER.
  const s1b = await cmd("frequency.reference", { family: "maleVocal" });
  ck("S1b two families return DIFFERENT rows (a collapsed table dies here)",
     JSON.stringify(s1b.result?.reference?.fundamental)
       !== JSON.stringify(ref?.fundamental),
     `bass=${JSON.stringify(ref?.fundamental)} vocal=${JSON.stringify(s1b.result?.reference?.fundamental)}`);

  const hp = ref?.recommendedHighPass?.hz;
  const slope = ref?.recommendedHighPass?.slopeDbPerOct;
  ck("S1c the corner carries usable numbers",
     Number.isFinite(hp) && (slope === 12 || slope === 24), `hz=${hp} slope=${slope}`);

  // ------------------------------------ S2: ANTI-VACUITY — fixture is ALIVE
  const base = await measure(trackId, effectId);
  ck("S2 baseline measured (helper did not fail open)", base != null);
  if (base) {
    ck("S2 band 0 is OFF THE FLOOR", base[0] > -60, `band0=${base[0].toFixed(2)}`);
    ck("S2 band 8 is OFF THE FLOOR", base[8] > -60, `band8=${base[8].toFixed(2)}`);
    // MEASURED, FIRST RUN: band 0 and band 1 read IDENTICALLY (-26.88 both),
    // and band 2 sat only 5.1 dB down. That is NOT distortion — it is spectral
    // leakage, because at the low end the analyzer's BANDS ARE NARROWER THAN
    // ITS FFT BIN: band 0 spans just 11.9 Hz (40→51.9). Bands 0/1/2 cannot be
    // resolved independently and the 46 Hz tone smears across all three.
    // The synth's sine is genuinely clean — its 2nd harmonic lands in band 3
    // at −51 dB, 24 dB below the fundamental.
    // So purity is asserted over bands 3…7, which lie BETWEEN the two tones
    // and outside the leakage skirt. Excluding band 2 is a measured fact about
    // the instrument, not a threshold loosened to get a pass.
    // BAND 3 IS EXCLUDED, and not to buy a pass. Run 2 flaked here with band 3
    // at −51.00 against a −50.38 bar — a 0.62 dB margin, i.e. a coin flip.
    // The cause is arithmetic, not noise: the low tone's 2nd harmonic is
    // 2 × 46.25 = 92.50 Hz, which lands at band 3.22. Band 3 CARRIES A
    // HARMONIC and was never "empty region between the tones".
    // Bands 4…7 (113…248 Hz) hold no harmonic of either tone and measure
    // −56.7 dB worst case: ~26 dB below the 349 Hz tone and ~30 dB below the
    // 46 Hz one, so the 20 dB bar keeps a real margin instead of a 0.6 dB one.
    const mid = Math.max(base[4], base[5], base[6], base[7]);
    ck("S2 sine purity: bands 4…7 at least 20 dB below both tones",
       mid < Math.min(base[0], base[8]) - 20,
       `mid=${mid.toFixed(2)} b0=${base[0].toFixed(2)} b8=${base[8].toFixed(2)}`);
    // The leakage itself, pinned: if a future analyzer change made band 0
    // independently resolvable, this leg tells us the fixture reasoning above
    // needs revisiting rather than letting it rot as a stale comment.
    ck("S2c band 0 and band 1 track each other (the low-end FFT-bin fact)",
       Math.abs(base[0] - base[1]) < 1.0,
       `b0=${base[0].toFixed(2)} b1=${base[1].toFixed(2)}`);
  }
  const tap = await spectrum(trackId, effectId);
  ck("S2b tapPoint == postInsertPreFader", tap?.tapPoint === "postInsertPreFader",
     `got ${tap?.tapPoint}`);

  // -------------------------- S3: the ROW'S OWN corner does not eat the bass
  await cmd("fx.setParam", { trackId, effectId, name: "highPassFreq", value: hp });
  await cmd("fx.setParam", { trackId, effectId, name: "highPassSlopeDbPerOct", value: slope });
  const p3 = await measurePaired(trackId, effectId);
  ck("S3 measured with the row's corner (A/B paired)", p3 != null);
  if (p3) {
    // A RED S3 IS A DATA VERDICT ABOUT THE SHIPPED TABLE — never loosen this
    // threshold to make it pass. It means the recommended corner eats the
    // instrument it is supposed to protect.
    ck("S3 the row's own corner costs band 0 <= 6 dB",
       Math.abs(p3.cut[0]) <= 6, `cut band0=${p3.cut[0].toFixed(2)}`);
    ck("S3 and leaves band 8 alone (<= 2 dB)",
       Math.abs(p3.cut[8]) <= 2, `cut band8=${p3.cut[8].toFixed(2)}`);
  }

  // ------------------- S4: ANTI-VACUITY for S3 — a no-op setParam dies here
  await cmd("fx.setParam", { trackId, effectId, name: "highPassFreq", value: 100 });
  await cmd("fx.setParam", { trackId, effectId, name: "highPassSlopeDbPerOct", value: 24 });
  const p4 = await measurePaired(trackId, effectId);
  ck("S4 measured with a deliberately wrong corner", p4 != null);
  if (p4) {
    ck("S4 a WRONG corner (100 Hz/24) DOES cut band 0 > 6 dB — proves S3 could fail",
       p4.cut[0] > 6, `cut band0=${p4.cut[0].toFixed(2)}`);
  }

  // --------------------------- S5: the cut is real, selective, and biggest low
  await cmd("fx.setParam", { trackId, effectId, name: "highPassFreq", value: 200 });
  const p5 = await measurePaired(trackId, effectId);
  ck("S5 measured at 200 Hz", p5 != null);
  if (p5) {
    ck("S5 band 0 attenuated >= 15 dB", p5.cut[0] >= 15, `cut band0=${p5.cut[0].toFixed(2)}`);
    // THE LEG THAT SEPARATES "cut the low end" FROM "turned it all down".
    ck("S5 band 8 barely moves (<= 2 dB)",
       Math.abs(p5.cut[8]) <= 2, `cut band8=${p5.cut[8].toFixed(2)}`);
    ck("S5 band 0 has the LARGEST attenuation (ties allowed)",
       p5.cut[0] >= Math.max(...p5.cut) - 1e-9,
       `cut0=${p5.cut[0].toFixed(2)} max=${Math.max(...p5.cut).toFixed(2)}`);
  }

  // ------------------------------------------------- S6: the filter reverses
  // Drift-immune restatement: re-apply the ROW's corner and demand the SAME
  // cut S3 measured. A latching filter keeps S5's 200 Hz behaviour and this
  // leg reddens. Comparing to a stale global baseline is what broke run 1.
  await cmd("fx.setParam", { trackId, effectId, name: "highPassFreq", value: hp });
  await cmd("fx.setParam", { trackId, effectId, name: "highPassSlopeDbPerOct", value: slope });
  const p6 = await measurePaired(trackId, effectId);
  ck("S6 measured after restore", p6 != null);
  if (p3 && p6) {
    ck("S6 re-applying the row's corner reproduces S3's cut within 2 dB (no latching)",
       Math.abs(p6.cut[0] - p3.cut[0]) <= 2,
       `S6 cut0=${p6.cut[0].toFixed(2)} vs S3 cut0=${p3.cut[0].toFixed(2)}`);
  }

  // ------------------------------------------- S7: the HONEST failure, live
  const at = await cmd("track.add", { kind: "audio", name: "o1 audio" });
  const audioId = at.result?.id;
  const s7 = await cmd("frequency.reference", { trackId: audioId });
  ck("S7 resolution == unresolved", s7.result?.resolution === "unresolved",
     `got ${s7.result?.resolution}`);
  ck("S7 carries a non-empty reason", !!s7.result?.reason, `got ${s7.result?.reason}`);
  ck("S7 carries a non-empty explanation", !!s7.result?.explanation);
  ck("S7 carries a non-empty remedy — the failure teaches the way out",
     !!s7.result?.remedy, `got ${JSON.stringify(s7.result?.remedy)?.slice(0, 140)}`);
  // Never a hardcoded count: Step 2 legitimately deleted 7 families, so the
  // index size is DATA. What must hold is that it is the SAME index.
  // Compare CANONICALLY. Run 2 failed this leg with both indexes 13 long, the
  // same ids in the same ORDER, and every entry equal — the only difference was
  // JSON KEY ORDER inside each object ({family,notes,displayName} on the
  // resolved path vs {displayName,family,notes} on the unresolved one). JSON
  // objects are unordered by spec, so a raw stringify compare was asserting
  // something neither the protocol nor any client guarantees. What this leg is
  // actually for is that the unresolved branch ships the SAME INDEX, not that
  // two code paths happen to serialise their keys alike.
  const canon = (v) => JSON.stringify(v, (_k, val) =>
    (val && typeof val === "object" && !Array.isArray(val))
      ? Object.fromEntries(Object.keys(val).sort().map((k) => [k, val[k]]))
      : val);
  const s7fam = canon(s7.result?.families);
  const idxfam = canon(indexFamilies);
  if (s7fam !== idxfam) {
    // Run 1 failed here with BOTH lengths 13 — so the difference is content or
    // order, not size. Dump it rather than guessing.
    writeFileSync(`${OUT}/families-diff.json`, JSON.stringify(
      { fromS1: indexFamilies, fromS7: s7.result?.families }, null, 2));
  }
  ck("S7 families present on the UNRESOLVED branch and IDENTICAL to S1's index",
     s7fam === idxfam,
     `len ${s7.result?.families?.length} vs ${indexFamilies?.length} — see families-diff.json`);

  // ------------------------------------------------------ S8: drum kit, live
  const dt = await cmd("track.add", { kind: "instrument", name: "o1 drums" });
  const drumId = dt.result?.id;
  const sb = await cmd("track.setInstrument", {
    trackId: drumId, kind: "soundBank",
    // MEASURED run 1: `track.setInstrument` refused with "'source' is required
    // (\"gm\" or an absolute .sf2/.dls path)" — the S8 group's 5 failures were
    // ALL this one missing key, not a product fault.
    soundBank: { source: "gm", bankMSB: 120, program: 0 },
  });
  const s8 = await cmd("frequency.reference", { trackId: drumId });
  ck("S8 resolution == drumKit", s8.result?.resolution === "drumKit",
     `got ${s8.result?.resolution} setInstrument=${JSON.stringify(sb.error ?? "ok").slice(0, 160)}`);
  ck("S8 coveredNotes == 17", s8.result?.coveredNotes?.length === 17,
     `got ${s8.result?.coveredNotes?.length}`);

  const s8b = await cmd("frequency.reference", { trackId: drumId, note: 38 });
  ck("S8b note 38 resolves to snare", s8b.result?.reference?.family === "snare",
     `got ${s8b.result?.reference?.family}`);

  const s8c = await cmd("frequency.reference", { trackId: drumId, note: 54 });
  ck("S8c uncovered note 54 gives a REASON, not a bare error",
     s8c.result?.reason === "percussionNoteNotCoveredInV1",
     `got reason=${s8c.result?.reason} error=${JSON.stringify(s8c.error ?? "").slice(0, 140)}`);
  ck("S8d coveredNotes STILL present on the uncovered-note branch",
     s8c.result?.coveredNotes?.length === 17, `got ${s8c.result?.coveredNotes?.length}`);

  // ------------------------------------------- wire hygiene (design §6 rules)
  const zero = await cmd("frequency.reference", {});
  ck("W1 zero params is LEGAL and returns the index", zero.result?.resolution === "index",
     `got ${zero.result?.resolution} ${JSON.stringify(zero.error ?? "").slice(0, 140)}`);

  const both = await cmd("frequency.reference", { family: "piano", trackId: audioId });
  ck("W2 family WINS over trackId", both.result?.reference?.family === "piano",
     `got ${both.result?.reference?.family}`);
  ck("W2b and says so: resolvedFrom == argument", both.result?.resolvedFrom === "argument",
     `got ${both.result?.resolvedFrom}`);

  const bogus = await cmd("frequency.reference", { family: "kazoo" });
  ck("W3 unknown family is an ERROR, never a nil-ish success",
     bogus.error != null && bogus.result == null,
     JSON.stringify(bogus.result ?? "").slice(0, 140));
  ck("W3b and the error names the valid ids",
     bogus.error != null && /electricBass|maleVocal|kick/.test(JSON.stringify(bogus.error)),
     JSON.stringify(bogus.error ?? "").slice(0, 200));

  const badKey = await cmd("frequency.reference", { nope: 1 });
  ck("W4 unknown key refused, and the message names it",
     badKey.error != null && /nope/.test(JSON.stringify(badKey.error)),
     JSON.stringify(badKey.error ?? "").slice(0, 160));

  await cmd("transport.stop", {});
  writeFileSync(`${OUT}/bands.json`, JSON.stringify({ base, hp, slope }, null, 2));
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging();
}

console.log(`\nM23O1_GATE pass=${pass} fail=${fail}`);
if (failures.length) console.log("FAILED LEGS:\n  " + failures.join("\n  "));
process.exit(fail ? 1 : 0);
