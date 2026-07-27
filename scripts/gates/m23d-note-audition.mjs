// m23-d GATE (C18) — note audition END-TO-END, against a REAL app on staging.
//
// This gate asserts AUDIO, never an ok response. `note.audition` returning
// {ok:true, audible:true} proves the store accepted the request and the engine
// said a renderer took it; it does NOT prove a sample ever left the master bus.
// So every leg here reads `mixer.masterAnalysis` — the post-master-fader tap —
// and compares levels against a measured silence baseline from the SAME session.
//
// FIXTURE ARITHMETIC, computed before the sampling loop was written (the m23-c2
// law: assert the fixture, but COMPUTE it first or you re-derive it by trial):
//   sampling window = SAMPLES(10) * POLL_MS(100) = 1000 ms of wall clock, plus
//   ~10 round trips of a few ms each. The audition must OUTLIVE that window or
//   the gate passes on scheduling luck, so DURATION_MS = 3000 — 3x the window,
//   and >= 2 s of slack even if every request took 100 ms. The controller
//   heartbeats every 500 ms while holding, so the renderer's 3 s liveness
//   watchdog cannot cut the voice early; the release is the release task at
//   t=3000, which the gate then WAITS OUT and re-measures, so a stuck note
//   fails here too.
//
// Two things that will otherwise burn a staging run:
//   * GM sound bank ONLY. A third-party AUv2 wedges the main actor for minutes
//     (docs: the AU-hosting wedge).
//   * The hosted instrument prepares ASYNCHRONOUSLY, so the FIRST audition after
//     track.setInstrument can legitimately answer audible:false /
//     reason:"instrumentNotReady". The gate POLLS for readiness and reports how
//     long it took — that measurement is the answer to design §16 open question 1
//     (does prepare() from setAuditionPitches make the first note on a cold app
//     audible, or does the started engine need a quantum or two?).
//
// Staging port 17695 only — 17600 is the user's LIVE app and is never touched.
// Staging is killed PIDFILE-EXACT; never pkill, never pgrep.
//
//   M23D_PIDFILE=<scratch>/staging.pid node scripts/gates/m23d-note-audition.mjs
import fs from "fs";
import { spawn } from "child_process";

const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23D_OUT || "/tmp/m23d";
const PIDFILE = process.env.M23D_PIDFILE || "/tmp/m23d-staging.pid";
const BINARY = process.env.M23D_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23D_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── fixture constants (see the arithmetic above) ──────────────────────────
const DURATION_MS = 3000;
const POLL_MS = 100;
const SAMPLES = 10;
const SAMPLING_WINDOW_MS = SAMPLES * POLL_MS;
const CHORD = [60, 64, 67];
const VELOCITY = 110;
// GM program 16 = Drawbar Organ: instant attack, FLAT sustain, fast release.
// The patch is part of the fixture arithmetic, not decoration. The first run of
// this gate used program 0 (Acoustic Grand Piano) and both release legs failed
// on the patch rather than on the code — a piano's envelope is still decaying
// 4 s after note-on, so "the bus fell back to the floor" and "the scheduled
// notes are still sounding 14 s into a 32-beat hold" are both unmeasurable with
// it. A sustaining patch makes note-ON and note-OFF the ONLY things that move
// the level, which is exactly what this gate is trying to read.
const PROGRAM = 16;

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("x")); });
      let nextId = 1; const pending = new Map();
      ws.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
        if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        else e.resolve(m.result ?? m);
      };
      const req = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

// ── launch staging (pidfile-exact teardown of any previous run) ───────────
if (fs.existsSync(PIDFILE)) {
  const oldPid = Number(fs.readFileSync(PIDFILE, "utf8").trim());
  if (Number.isFinite(oldPid) && oldPid > 1) {
    try { process.kill(oldPid); } catch {}      // pidfile-EXACT; never pkill/pgrep
    await sleep(1500);
  }
}
const log = fs.openSync(`${OUT}/staging.log`, "a");
const child = spawn(BINARY, [], {
  cwd: REPO, detached: true, stdio: ["ignore", log, log],
  env: { ...process.env, DAW_CONTROL_PORT: PORT },
});
child.unref();
fs.writeFileSync(PIDFILE, String(child.pid));
console.log(`staging pid ${child.pid} on :${PORT}`);
await sleep(3500);

let { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};

// transport.play/stop/seek answer bare ok with no result body, so transport
// state is read from project.overview — the app's own numbers, not the echo of
// the request that set them.
const transport = async () => (await req("project.overview", {})).transport;
// Master tap readers. peakDB is the fast responder; levelDB is short-term RMS.
const level = async () => {
  const a = await req("mixer.masterAnalysis", {});
  return { peak: a.peakDB, rms: a.levelDB };
};
async function sampleWindow(label, samples = SAMPLES) {
  const peaks = [], rmss = [];
  for (let i = 0; i < samples; i++) {
    const l = await level();
    peaks.push(l.peak); rmss.push(l.rms);
    await sleep(POLL_MS);
  }
  const maxPeak = Math.max(...peaks), maxRms = Math.max(...rmss);
  console.log(`   [${label}] peakDB max ${maxPeak.toFixed(2)} of ${peaks.map(p => p.toFixed(1)).join(",")}`);
  return { peaks, rmss, maxPeak, maxRms };
}

// A TIME-STAMPED series, which the two assertions below need and a bare max
// cannot give: "flat across the hold" and "how many onsets" are both questions
// about SHAPE OVER TIME, and the first version of this gate asked neither.
async function sampleSeries(label, windowMs) {
  const t0 = Date.now();
  const series = [];
  while (Date.now() - t0 < windowMs) {
    const l = await level();
    series.push({ t: Date.now() - t0, peak: l.peak, rms: l.rms });
    await sleep(POLL_MS);
  }
  console.log(`   [${label}] ${series.length} samples over ${Date.now() - t0} ms`);
  console.log(`        ${series.map(s => `${(s.t / 1000).toFixed(2)}:${s.peak.toFixed(1)}`).join(" ")}`);
  return series;
}

// An ONSET is an attack transient: a sharp RISE to a musical level. Adjacent
// rises inside ONSET_COALESCE_MS are one attack (an attack sampled mid-rise
// must not read as two), so the detector cannot manufacture the very thing it
// is counting.
const ONSET_RISE_DB = 3;
const ONSET_COALESCE_MS = 300;
function onsets(series, floorDB) {
  const found = [];
  for (let i = 1; i < series.length; i++) {
    if (series[i].peak <= series[i - 1].peak + ONSET_RISE_DB) continue;
    if (series[i].peak < floorDB + 20) continue;          // noise, not a note
    if (found.length && series[i].t - found[found.length - 1] < ONSET_COALESCE_MS) continue;
    found.push(series[i].t);
  }
  return found;
}

// ── fixture: a clean project with ONE GM instrument track ─────────────────
console.log("\n── FIXTURE");
await req("project.new", { discardChanges: true });
const track = (await req("track.add", { kind: "instrument", name: "Audition" })).id;
await req("track.setInstrument", { trackId: track, soundBank: { source: "gm", program: PROGRAM } });
console.log(`  track ${track} · GM program ${PROGRAM} (sustaining)`);

// §16 Q1 — how long until the FIRST audition on a cold app is audible?
console.log("\n── §16 Q1: readiness of the FIRST audition after setInstrument");
let readyAfterMs = null, firstAnswer = null;
for (let i = 0; i < 60; i++) {
  const r = await req("note.audition", { trackId: track, pitches: [60], velocity: 1, durationMs: 10 });
  if (firstAnswer === null) firstAnswer = JSON.stringify(r);
  if (r.audible === true) { readyAfterMs = i * 250; break; }
  await sleep(250);
}
console.log(`  first answer: ${firstAnswer}`);
console.log(`  audible after ~${readyAfterMs} ms of polling`);
check("C18 the instrument becomes auditionable at all (readiness is reachable)",
      readyAfterMs !== null, `audible after ~${readyAfterMs} ms; first answer ${firstAnswer}`);
await sleep(400);   // let the 10 ms probe note release before baselining

// ═══ LEG A — transport STOPPED ════════════════════════════════════════════
// The roadmap's gate is "audible one-shot with transport stopped". The whole
// point of the feature is that it works when nothing is playing, which is
// exactly when the master tap is otherwise at its floor — so this leg has the
// cleanest possible signal-to-baseline.
console.log("\n── LEG A: transport STOPPED");
await req("transport.stop", {});
const stopped = await transport();
check("LA (setup) the transport really is stopped", stopped.isPlaying === false,
      `isPlaying ${stopped.isPlaying} at beat ${stopped.positionBeats}`);
const silentA = await sampleWindow("A/silence", 6);

const auditionA = await req("note.audition", {
  trackId: track, pitches: CHORD, velocity: VELOCITY, durationMs: DURATION_MS });
console.log(`  note.audition → ${JSON.stringify(auditionA)}`);
check("LA the wire verb reports it sounded (necessary, NOT sufficient — audio is below)",
      auditionA.audible === true && auditionA.durationMs === DURATION_MS, JSON.stringify(auditionA));

// ONE dense series across the hold AND past the release, because the two
// assertions this gate was missing are both about shape over time.
const seriesA = await sampleSeries("A/hold→release", DURATION_MS + 2000);
const holdA = seriesA.filter(s => s.t < DURATION_MS - POLL_MS);
const soundingA = { maxPeak: Math.max(...holdA.map(s => s.peak)) };

// The fixture assertion the arithmetic exists to make: the audition OUTLIVED
// the sampling window. Without this, a pass could be scheduling luck.
check("LA (fixture) the audition outlives the sampling window",
      DURATION_MS > SAMPLING_WINDOW_MS * 2,
      `durationMs ${DURATION_MS} vs window ${SAMPLING_WINDOW_MS} ms (${SAMPLES}x${POLL_MS})`);
check("LA (fixture) the silence baseline really is silent — a floor is required for a rise to mean anything",
      silentA.maxPeak < -60, `silence peakDB max ${silentA.maxPeak.toFixed(2)}`);
check("LA (fixture) the hold was sampled densely enough to have a shape at all",
      holdA.length >= 8, `${holdA.length} samples inside the ${DURATION_MS} ms hold`);
check("LA AUDIO: the master bus carries the audition with the transport STOPPED",
      soundingA.maxPeak > silentA.maxPeak + 30,
      `sounding peakDB max ${soundingA.maxPeak.toFixed(2)} vs silence ${silentA.maxPeak.toFixed(2)} ` +
      `(+${(soundingA.maxPeak - silentA.maxPeak).toFixed(2)} dB)`);
check("LA AUDIO: the level is a real musical level, not a denormal tail",
      soundingA.maxPeak > -40, `peakDB max ${soundingA.maxPeak.toFixed(2)}`);

// ══ THE TWO ASSERTIONS WHOSE ABSENCE HID A BROKEN FEATURE ═════════════════
// This gate passed 20/20 while the audition sounded for exactly ONE render
// quantum and then went silent, because every check above is satisfied by a
// blip: it rises off the floor, it reaches a musical level, and it is followed
// by a collapse that is still falling. A note that never held does ALL of that.
// What a blip cannot do is stay FLAT for three seconds, and what a working
// audition cannot do is speak TWICE.
const middleA = seriesA.filter(s => s.t >= DURATION_MS * 0.25 && s.t <= DURATION_MS * 0.75);
const midLo = Math.min(...middleA.map(s => s.peak));
const midHi = Math.max(...middleA.map(s => s.peak));
const FLAT_TOLERANCE_DB = 6;
check("LA AUDIO: the audition SUSTAINS — the level is FLAT across the middle of the hold",
      middleA.length >= 4 && midHi - midLo < FLAT_TOLERANCE_DB,
      `${middleA.length} samples in [${(DURATION_MS * 0.25) | 0},${(DURATION_MS * 0.75) | 0}] ms: ` +
      `min ${midLo.toFixed(2)} max ${midHi.toFixed(2)} → spread ${(midHi - midLo).toFixed(2)} dB ` +
      `(tolerance ${FLAT_TOLERANCE_DB}); a one-quantum blip decays tens of dB across this window`);

// Onsets are scanned from the SILENCE FLOOR forward, so the note's own attack
// is onset #1 and the scan cannot miss it by starting mid-note.
const scanA = [{ t: -POLL_MS, peak: silentA.peaks[silentA.peaks.length - 1] }, ...seriesA];
const onsetsA = onsets(scanA, silentA.maxPeak);
check("LA AUDIO: EXACTLY ONE onset per audition — the release must not make the note speak again",
      onsetsA.length === 1,
      `${onsetsA.length} onset(s) at t = ${onsetsA.map(t => `${t} ms`).join(", ") || "none"} ` +
      `over a ${DURATION_MS} ms hold; a second onset near t=${DURATION_MS} is the note sounding ` +
      `when it was told to STOP`);

// The release. C11/C12's stuck-note claim, measured on the audio itself.
//
// A single absolute threshold cannot answer this, and pretending otherwise is
// how a gate ends up tuned to whatever number it happened to see: a note-OFF on
// a sampled instrument is followed by a RELEASE TAIL (voice release + the
// sampler's own reverb), so the bus does not snap to the floor the instant the
// voice is released. What actually distinguishes the two cases is the SHAPE:
//   * released  → a large collapse from the sounding level, and STILL FALLING.
//   * stuck     → level pinned near the sounding level, and FLAT.
// So this samples twice, seconds apart, and asserts both the collapse and the
// continued decay. That reading holds for any patch and any reverb length.
// NOTE: this pair is NECESSARY BUT NOT SUFFICIENT on its own — it is exactly
// what a never-held note also satisfies. It only means "released" beside the
// flat-hold assertion above.
const afterA = { maxPeak: Math.max(...seriesA.filter(s => s.t > DURATION_MS + 1000).map(s => s.peak)) };
await sleep(3000);
const afterA2 = await sampleWindow("A/released+3s", 6);
// The threshold here is DERIVED from the flatness tolerance above, not chosen:
// a STUCK note is by definition still inside the sustain band, so "released"
// means the level left that band by several times its width. 3x is unambiguous
// and involves no knowledge of the patch's release length.
//
// This assertion previously demanded a 40 dB collapse — and that number was
// itself an artifact of the bug. With the audition sounding for one quantum,
// the level measured a second after "release" had already been decaying for
// four seconds, so 40 dB was easy. Now that the note actually HOLDS for the
// full 3 s, one second past the note-off is only 23 dB down: a real release
// tail. The old threshold could only be met by a feature that was broken.
check("LA AUDIO: the one-shot RELEASES — the bus leaves the sustain band decisively",
      afterA.maxPeak < soundingA.maxPeak - 3 * FLAT_TOLERANCE_DB,
      `released ${afterA.maxPeak.toFixed(2)} vs sounding ${soundingA.maxPeak.toFixed(2)} ` +
      `(${(afterA.maxPeak - soundingA.maxPeak).toFixed(2)} dB, required < ` +
      `${(-3 * FLAT_TOLERANCE_DB).toFixed(0)} dB = 3x the ${FLAT_TOLERANCE_DB} dB sustain band)`);
check("LA AUDIO: what is left is a DECAYING TAIL, not a stuck note (a held voice would sit flat)",
      afterA2.maxPeak < afterA.maxPeak - 6 || afterA2.maxPeak < silentA.maxPeak + 6,
      `${afterA.maxPeak.toFixed(2)} → ${afterA2.maxPeak.toFixed(2)} dB three seconds later ` +
      `(floor ${silentA.maxPeak.toFixed(2)}); the sounding level was ${soundingA.maxPeak.toFixed(2)}`);

// ═══ LEG B — DURING PLAYBACK, without disturbing scheduled notes ═══════════
// The roadmap's second half. Scheduled material rolls; the audition is added on
// top. Two claims: the audition ADDS audible level, and the scheduled notes are
// STILL sounding while it does (the merge did not eat them).
console.log("\n── LEG B: DURING PLAYBACK");
// A held scheduled chord, low in the register so it is distinct from the
// audition's C major triad, and long enough to cover both sampling windows.
await req("clip.addMIDI", {
  trackId: track, atBeat: 0, lengthBeats: 32,
  notes: [
    { pitch: 36, startBeat: 0, lengthBeats: 32, velocity: 100 },
    { pitch: 43, startBeat: 0, lengthBeats: 32, velocity: 100 },
  ],
});
await req("transport.seek", { beats: 0 });
await req("transport.play", {});
const playing = await transport();
check("LB (setup) the transport really is rolling", playing.isPlaying === true,
      `isPlaying ${playing.isPlaying} at beat ${playing.positionBeats}`);
await sleep(600);   // let the scheduled notes speak before baselining
const scheduledOnly = await sampleWindow("B/scheduled-only");
check("LB (fixture) the scheduled material is actually SOUNDING — otherwise this leg tests nothing",
      scheduledOnly.maxPeak > -40, `scheduled-only peakDB max ${scheduledOnly.maxPeak.toFixed(2)}`);

const posBefore = (await transport()).positionBeats;
const auditionB = await req("note.audition", {
  trackId: track, pitches: CHORD, velocity: VELOCITY, durationMs: DURATION_MS });
console.log(`  note.audition → ${JSON.stringify(auditionB)}`);
check("LB the wire verb reports it sounded while rolling",
      auditionB.audible === true, JSON.stringify(auditionB));
const bothSounding = await sampleWindow("B/scheduled+audition");
const posAfter = (await transport()).positionBeats;

check("LB AUDIO: the audition ADDS level on top of the running mix",
      bothSounding.maxPeak > scheduledOnly.maxPeak + 1.5,
      `both ${bothSounding.maxPeak.toFixed(2)} vs scheduled-only ${scheduledOnly.maxPeak.toFixed(2)} ` +
      `(+${(bothSounding.maxPeak - scheduledOnly.maxPeak).toFixed(2)} dB)`);
check("LB AUDIO: the SCHEDULED notes are still sounding throughout — the audition did not cut them",
      Math.min(...bothSounding.peaks) > -40,
      `min peakDB during the audition ${Math.min(...bothSounding.peaks).toFixed(2)}`);
check("LB the transport kept advancing across the audition (playback was not disturbed)",
      posAfter > posBefore, `beat ${posBefore} → ${posAfter}`);

// Release under playback, then confirm the scheduled material is untouched by
// the audition's exit — the §5.3 claim that an audition release cuts ONLY
// audition voices and never calls instrument.reset() or requestFlush(). A reset
// would take the held bass notes with it, so the bus would collapse to the
// floor; the assertion is that it comes back to the SCHEDULED-ONLY level, which
// is both halves of the claim in one number.
await sleep(DURATION_MS + 1200);
const afterB = await sampleWindow("B/after-release");
check("LB AUDIO: after the audition releases the SCHEDULED notes still play (no instrument reset, no flush)",
      Math.abs(afterB.maxPeak - scheduledOnly.maxPeak) < 6,
      `after-release peakDB max ${afterB.maxPeak.toFixed(2)} vs scheduled-only ` +
      `${scheduledOnly.maxPeak.toFixed(2)} (delta ${(afterB.maxPeak - scheduledOnly.maxPeak).toFixed(2)} dB); ` +
      `an instrument reset would have collapsed it to the ${silentA.maxPeak.toFixed(2)} floor`);
await req("transport.stop", {});

// ═══ LEG C — the defeat switch is a VIEW preference; the wire ignores it ═══
console.log("\n── LEG C: the defeat switch does not gag the wire");
const off = await req("debug.panelLayout", { auditionEnabled: false });
check("LC the switch round-trips over the debug tier", off.auditionEnabled === false, JSON.stringify(off));
const withSwitchOff = await req("note.audition", {
  trackId: track, pitches: [72], velocity: VELOCITY, durationMs: 800 });
check("LC note.audition deliberately IGNORES the view switch (an agent is not a mouse)",
      withSwitchOff.audible === true, JSON.stringify(withSwitchOff));
const gaggedSound = await sampleWindow("C/switch-off", 6);
check("LC AUDIO: it really sounded with the switch off",
      gaggedSound.maxPeak > silentA.maxPeak + 30,
      `peakDB max ${gaggedSound.maxPeak.toFixed(2)} vs silence ${silentA.maxPeak.toFixed(2)}`);
// Restore the SHIPPED default — this store writes through to UserDefaults.standard,
// which staging shares with the user's own app.
const restored = await req("debug.panelLayout", { auditionEnabled: true });
check("LC the shipped default (ON) is restored before the gate exits",
      restored.auditionEnabled === true, JSON.stringify(restored));

console.log("\n=== GATE ===");
let failed = 0;
for (const c of checks) {
  if (!c.ok) failed++;
  console.log(`${c.ok ? "PASS" : "FAIL"}  ${c.name}\n        ${c.detail}`);
}
fs.writeFileSync(`${OUT}/gate.json`, JSON.stringify({ readyAfterMs, checks }, null, 2));
console.log(`\n${checks.length - failed}/${checks.length} checks passed`);
clearTimeout(killer); ws.close(); process.exit(failed === 0 ? 0 : 1);
