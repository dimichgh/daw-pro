// m23af-panic — can the user get out of a stuck note?
//
// THE QUESTION. m23-af filed that there is no PANIC verb anywhere: the Stop
// button cannot clear a stuck note (`ProjectStore.stop()` early-returns unless
// the transport is playing or recording) and no control command existed either,
// so a note left sounding by a lost note-off was unclearable by the user AND by
// an agent. This gate drives the real app and asks whether `transport.panic`
// actually silences one.
//
// WHY A GATE AND NOT JUST `PanicCommandTests`. Those seven legs run against an
// engine SPY, so they pin the store/wire contract — panic works while stopped,
// panic does not stop the transport, the audition ledger is cleared before the
// flush — but a spy's `allNotesOff()` returns a stub. Nothing there proves the
// real engine reaches a renderer holding a stuck note. That is the half this
// gate owns, and the note is stuck through real CoreMIDI rather than through the
// audition path precisely because an audition note would be silenced by
// `stopAllAudition()` alone (see the probe's header).
//
// THE DISCRIMINATOR IS L2. Because no note-off is ever sent, `openLiveCount`
// stays > 0 and the m23-u/m23-ae tail re-arms forever — so on a build without a
// working panic the note is STILL SOUNDING when L2 samples, not decaying toward
// it. There is no window in which both builds look alike.
//
// Exit: 0 all checks pass, 1 a check failed, 2 could not set up.
import { spawn, spawnSync } from "child_process";
import {
  ROOT, sleep, launchStaging,
} from "./_staging.mjs";

const GATE = "m23af";
const PROBE = process.env.M23AF_PROBE || "/tmp/m23af-probe";
const PROBE_SRC = "scripts/probes/m23af-stuck-note-probe.swift";
const PITCH = 60;

let failed = 0;
const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok: !!ok });
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}: ${name}${detail ? ` — ${detail}` : ""}`);
}
// A PRECONDITION IS NOT A CHECK (m23-bl is open on giving this a home). If the
// note never sounded, every later leg is vacuous — "silent after panic" passes
// trivially against silence. So a failed precondition ABORTS with 2 rather than
// recording a FAIL that a summary line would average away into a near-pass.
function precondition(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "ABORT"}: ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) {
    console.log("ABORT: precondition failed — the discriminating legs would be vacuous");
    process.exit(2);
  }
}

// Rebuilt every run: a stale binary would play a sequence that no longer exists
// and the transcript would still look like a real measurement.
const probeBuild = spawnSync("swiftc", ["-O", "-o", PROBE, PROBE_SRC], {
  cwd: ROOT, encoding: "utf8",
});
if (probeBuild.status !== 0) {
  console.log("ABORT: probe compile failed — every leg would measure a stale probe");
  console.log((probeBuild.stderr || "").trim().split("\n").slice(-12).join("\n"));
  process.exit(2);
}
console.log(`# probe rebuilt: ${PROBE} <- ${PROBE_SRC}`);

const { ws, stop } = await launchStaging({ gate: GATE, skipBuild: false, settleMs: 1500 });

let nextID = 1;
const pending = new Map();
ws.onmessage = (ev) => {
  let msg;
  try { msg = JSON.parse(ev.data); } catch { return; }
  const r = pending.get(msg.id);
  if (r) { pending.delete(msg.id); r(msg); }
};
function send(command, params = {}) {
  const id = String(nextID++);
  return new Promise((res, rej) => {
    pending.set(id, res);
    ws.send(JSON.stringify({ id, command, params }));
    setTimeout(() => { if (pending.delete(id)) rej(new Error(`timeout: ${command}`)); }, 20000);
  });
}

const killer = setTimeout(() => {
  console.error("TIMEOUT");
  stop();
  process.exit(2);
}, 300_000);

let probe = null;
// TEARDOWN FOR THE PROBE, WHICH `armTeardown` DOES NOT COVER (m23-bd): that
// tears down STAGING, and the probe is a second child holding a VIRTUAL MIDI
// SOURCE the user's live app on 17600 can also see. `process.on("exit")` is the
// right hook and NOT `finally` — it runs on `process.exit()`, which is how both
// the catch path and the watchdog above leave.
process.on("exit", () => { try { probe?.kill("SIGKILL"); } catch { /* gone */ } });

try {
  await send("project.new", { discardChanges: true });
  const track = await send("track.add", { kind: "instrument", name: "m23af stuck" });
  const trackId = track?.result?.id ?? track?.result?.track?.id;
  if (!trackId) {
    console.log(`ABORT: no track id in ${JSON.stringify(track).slice(0, 300)}`);
    stop(); process.exit(2);
  }

  // sustain = 1.0 so an open voice reads FLAT AND LOUD rather than as the
  // ambiguous tail of a decaying patch (the m23-ad/m23-ae trap: a piano-like
  // envelope decays into the noise floor on its own and makes a broken build
  // look like a fixed one).
  await send("track.setInstrument", {
    trackId, kind: "polySynth", waveform: "saw",
    attack: 0.005, decay: 0.005, sustain: 1.0, release: 0.05, gain: 0.8,
  });
  await send("track.setArm", { trackId, armed: true });
  console.log(`# track ${trackId}: polySynth saw, sustain=1.0, ARMED`);

  await send("mixer.liveLoudness", { reset: true });
  const q = (r) => {
    const s = r?.result ?? {};
    return typeof s.momentaryLufs === "number" ? s.momentaryLufs : null;
  };

  // SAMPLE A WINDOW, NOT AN INSTANT (m23-ad). `momentaryLufs` is a 400 ms mean
  // omitted until the window has filled, so one sample can read null while a
  // note is audibly playing. MAX is also the stricter test for the silence leg:
  // any audible moment anywhere in the window fails it.
  async function maxOver(ms, label) {
    const t0 = Date.now();
    let best = null;
    const seen = [];
    while (Date.now() - t0 < ms) {
      const v = q(await send("mixer.liveLoudness", {}));
      seen.push(v);
      if (v !== null && (best === null || v > best)) best = v;
      await sleep(120);
    }
    console.log(`#   ${label}: max=${best} over ${seen.length} samples`);
    return best;
  }

  probe = spawn(PROBE, [String(PITCH)], { stdio: ["pipe", "pipe", "pipe"] });
  const probeLog = [];
  probe.stdout.on("data", (d) => probeLog.push(String(d)));
  probe.stderr.on("data", (d) => probeLog.push(String(d)));
  // ATTACHED AT SPAWN, AWAITED LATER (m23-ae): registering `on("exit")` after
  // the sampling loses the event when the probe dies early, and the gate then
  // hangs to its watchdog with the probe's stdout — the only diagnosis
  // available — still unprinted.
  let probeExit = null;
  const probeDone = new Promise((r) => probe.on("exit", (code, sig) => {
    probeExit = sig ? `signal ${sig}` : `code ${code}`;
    r();
  }));

  async function awaitProbeLine(needle, timeoutMs = 40_000) {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      if (probeLog.join("").includes(needle)) return true;
      if (probeExit) return false;
      await sleep(80);
    }
    return false;
  }

  // The app must SEE the source before the note is played, or "no audio" would
  // mean "never connected" rather than anything about panic.
  let visible = false;
  const seenT0 = Date.now();
  while (Date.now() - seenT0 < 25_000) {
    const inputs = await send("midi.listInputs", {});
    if (JSON.stringify(inputs?.result ?? {}).includes("m23af-probe")) { visible = true; break; }
    await sleep(400);
  }
  precondition("app can see the virtual source", visible,
               `after ${((Date.now() - seenT0) / 1000).toFixed(2)}s`);

  probe.stdin.write("go\n");
  precondition("probe reported the note-on", await awaitProbeLine("NOTEON"),
               probeExit ? `probe exited: ${probeExit}` : "");

  // P1 — the note is actually sounding. Without this every later leg is vacuous.
  const sounding = await maxOver(1600, "P1 while the note is stuck");
  precondition("the stuck note is SOUNDING before the panic", sounding !== null,
               `momentaryLufs=${sounding}`);

  // L1 — the verb answers, and reports what it flushed.
  const panicResp = await send("transport.panic", {});
  const flushed = panicResp?.result?.tracksFlushed;
  check("transport.panic succeeds", panicResp?.ok === true,
        JSON.stringify(panicResp?.error ?? panicResp?.result ?? {}).slice(0, 200));
  check("reports at least one renderer flushed", typeof flushed === "number" && flushed >= 1,
        `tracksFlushed=${flushed}`);

  // L2 — THE DISCRIMINATOR. The probe is still alive and still sending nothing,
  // so nothing but the panic can have silenced this.
  await sleep(900);
  const afterPanic = await maxOver(1600, "L2 after the panic");
  check("the stuck note is SILENCED by panic", afterPanic === null,
        `momentaryLufs=${afterPanic} (expected null)`);

  // L3 — panic left the transport alone. It was never started, so this also
  // pins that panic does not somehow start it.
  const overview = await send("project.overview", {});
  const playing = overview?.result?.transport?.isPlaying;
  check("panic did not disturb the transport", playing === false,
        `isPlaying=${playing}`);

  // L4 — the probe is STILL RUNNING, which is what makes L2 attributable. If it
  // had exited, the source would have vanished and that disappearance, not the
  // panic, could have been what silenced the voice.
  check("the virtual source outlived the measurement", probeExit === null,
        probeExit ? `probe exited: ${probeExit}` : "still holding the source open");

  // L5 — THE AUDITION PATH, AND THE HEARTBEAT HAZARD, ON THE REAL ENGINE.
  //
  // Everything above holds the note via THRU, which means the engine's
  // `auditionVoices` ledger is EMPTY throughout and `stopAllAudition()`'s
  // `removeAll()` is a no-op on every run — fixed and mutant alike. So none of
  // it exercises the ordering rationale this fix is built on: that
  // `AuditionController`'s 500 ms heartbeat would re-assert held pitches into a
  // ring the panic just emptied if the ledger were not cleared first.
  //
  // `note.audition` caps `durationMs` at 5000, so the whole leg must finish
  // inside that: hold, confirm sounding, panic, then sample for 1.8 s — past
  // THREE heartbeat intervals, which is the point. A 400 ms sample would go
  // quiet either way and prove nothing.
  // ⚠️ THE SETTLE BELOW IS LOAD-BEARING AND I LEFT IT OUT ON THE FIRST RUN.
  // `momentaryLufs` is a 400 ms MEAN, so the first samples after the panic
  // average over audio from BEFORE it. Sampling immediately, this leg read
  // -17.65 on a build whose panic demonstrably works (L2 above, same renderer,
  // same reset) and I nearly filed it as a product bug. L2 settles 900 ms for
  // exactly this reason; the window MAX makes it worse, not better, because one
  // straddling sample is enough. Same law as m23-ad, re-broken one leg later.
  //
  // The settle cannot hide a resurrection: the heartbeat re-asserts every
  // 500 ms, so a voice the panic failed to kill is still sounding at t+900 ms
  // and stays sounding for the whole window.
  //
  // TIMING BUDGET — `note.audition` caps `durationMs` at 5000 and the whole leg
  // must finish inside that, or the one-shot release would silence the note for
  // us and a broken build would read as fixed. Measured shape: ~1.1 s to P3,
  // panic, 0.9 s settle, ~1.6 s sampling ≈ 3.7 s, leaving ~1.3 s of margin.
  await send("note.audition", {
    trackId, pitches: [64], velocity: 100, durationMs: 5000,
  });
  const auditionSounding = await maxOver(900, "P3 auditioned note held");
  precondition("the AUDITIONED note is SOUNDING before the panic",
               auditionSounding !== null, `momentaryLufs=${auditionSounding}`);

  const panic2 = await send("transport.panic", {});
  check("transport.panic succeeds on the audition path", panic2?.ok === true,
        JSON.stringify(panic2?.error ?? panic2?.result ?? {}).slice(0, 200));

  await sleep(900);
  const afterAuditionPanic = await maxOver(1400, "L5 after the panic (2+ heartbeats)");
  check("the AUDITIONED note stays silenced across 2+ heartbeat intervals",
        afterAuditionPanic === null,
        `momentaryLufs=${afterAuditionPanic} (expected null — a non-null here is the `
        + `heartbeat resurrecting a flushed voice)`);

  console.log("\n--- probe stdout ---");
  console.log(probeLog.join("").trim());
  console.log("--- end probe stdout ---\n");

  clearTimeout(killer);
  try { probe.kill("SIGKILL"); } catch { /* gone */ }
  await Promise.race([probeDone, sleep(5_000)]);
  stop();

  console.log(`\n${results.filter((r) => r.ok).length}/${results.length} checks passed`);
  process.exit(failed ? 1 : 0);
} catch (err) {
  clearTimeout(killer);
  console.error(`ERROR: ${err?.message ?? err}`);
  try { probe?.kill("SIGKILL"); } catch { /* gone */ }
  stop();
  process.exit(2);
}
