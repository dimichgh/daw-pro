// m23ad-thru-retrigger — does a live-THRU retrigger leave a stuck voice?
//
// WHY A GATE AND NOT JUST A UNIT TEST. `LiveThruRenderTests` drives the real
// `renderQuantum` and proves the emitted event stream (on, off, on) — that is
// genuine coverage, and a mutant that removes the defensive close fails it.
// But `thruRing` has exactly ONE producer in the whole tree: the CoreMIDI
// receive thread (`MIDIInputManager.swift:24`). No control command reaches it.
// So the unit tests can never answer the question a user would ask, which is
// not "what events are emitted" but "does the note stop when I let go".
//
// This gate answers that one, end to end, through real CoreMIDI:
//
//   virtual MIDI source -> CoreMIDI -> MIDIInputManager -> thruRing
//     -> InstrumentRenderer 6b drain -> polySynth -> master bus -> loudness
//
// `MIDIInputManager.setupChanged()` connects EVERY online source, so the probe
// needs no device-selection step — creating the source is the whole handshake.
//
// THE INSTRUMENT IS CHOSEN TO MAKE THE BUG LOUD. A polySynth with
// sustain = 1.0 and a short release holds a note at full level for as long as
// the voice is open. Pre-m23-ad the retrigger orphaned voice #1 — no off could
// ever pair with it — so after the single note-off the track kept sounding
// FOREVER. A decaying patch (piano, plucks) would have hidden that behind its
// own envelope, which is exactly the trap this gate is built to avoid.
//
// Exit: 0 all checks pass, 1 a check failed, 2 could not set up.
import { spawn } from "child_process";
import { spawnSync } from "child_process";
import fs from "fs";
import {
  ROOT, STAGING_PORT, sleep, launchStaging, stopStaging,
} from "./_staging.mjs";

const GATE = "m23ad";
const PROBE = process.env.M23AD_PROBE || "/tmp/m23ad-probe";
const PROBE_SRC = "scripts/probes/m23ad-thru-retrigger-probe.swift";
const PITCH = 60;

let failed = 0;
const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok: !!ok });
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}: ${name}${detail ? ` — ${detail}` : ""}`);
}

// The probe is rebuilt every run for the same reason m23c2 rebuilds its own:
// a stale binary would measure a version of the sequence that no longer exists,
// and the transcript would look like a real measurement.
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

try {
  await send("project.new", { discardChanges: true });
  const track = await send("track.add", { kind: "instrument", name: "m23ad thru" });
  const trackId = track?.result?.id ?? track?.result?.track?.id;
  if (!trackId) {
    console.log(`ABORT: no track id in ${JSON.stringify(track).slice(0, 300)}`);
    stop(); process.exit(2);
  }

  // sustain 1.0 = the voice holds at full level while open. release short, so a
  // CORRECTLY closed voice is silent well inside the measurement window and the
  // gate cannot pass by merely waiting out a long tail.
  await send("track.setInstrument", {
    trackId, kind: "polySynth", waveform: "saw",
    attack: 0.005, decay: 0.005, sustain: 1.0, release: 0.05, gain: 0.8,
  });
  await send("track.setArm", { trackId, armed: true });
  console.log(`# track ${trackId}: polySynth saw, sustain=1.0 release=0.05, ARMED`);

  // Reset the running loudness measurement so nothing before this point counts.
  await send("mixer.liveLoudness", { reset: true });

  const before = await send("mixer.liveLoudness", {});
  const q = (r) => {
    const s = r?.result ?? {};
    return typeof s.momentaryLufs === "number" ? s.momentaryLufs : null;
  };

  // SAMPLE A WINDOW, NOT AN INSTANT. One reading is a coin flip against a
  // 400 ms momentary window: measured m23-ad, a single sample 300 ms after a
  // clearly-audible note-on came back null purely because the window had not
  // filled. Taking the MAX over a window is also the stricter test for the
  // silence legs — ANY audible moment in the window fails them.
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

  // Probe timeline: t≈2.0 ON#1, t≈3.5 ON#2, t≈5.0 OFF, t≈11 exit.
  const probe = spawn(PROBE, [String(PITCH), "1500"], { stdio: ["ignore", "pipe", "pipe"] });
  // TEARDOWN FOR THE PROBE, WHICH `armTeardown` DOES NOT COVER — it tears down
  // STAGING, and the probe is a second child holding a VIRTUAL MIDI SOURCE the
  // user's live app on 17600 can see. Without this, a throw after the spawn or
  // the 300 s watchdog would leave it running: the exact m23-bd shape (a
  // watchdog that exits without tearing down its children), one scale smaller.
  //
  // `process.on("exit")` is the right hook and NOT `finally`: it runs on
  // `process.exit()`, which is how both the catch path and the watchdog leave.
  // Signals are covered too — armTeardown (already installed by launchStaging
  // above) converts SIGINT/SIGTERM/SIGHUP into `process.exit`, which then runs
  // this. Synchronous by necessity; `kill` is.
  process.on("exit", () => { try { probe.kill("SIGKILL"); } catch { /* gone */ } });
  const probeLog = [];
  probe.stdout.on("data", (d) => probeLog.push(String(d)));
  probe.stderr.on("data", (d) => probeLog.push(String(d)));

  await sleep(2500);
  const heldOne = await maxOver(900, "held1 (voice #1 alone)");
  await sleep(700);
  const heldTwo = await maxOver(900, "held2 (after the RETRIGGER)");
  await sleep(1200);
  const afterOff = await maxOver(1200, "afterOff (~1.2 s past the single OFF)");
  const settled = await maxOver(1500, "settled (~3 s past the OFF)");

  await new Promise((r) => probe.on("exit", r));
  console.log(probeLog.join("").trim().split("\n").map((l) => `  ${l}`).join("\n"));

  console.log(`# momentary LUFS: reset=${q(before)} held1=${heldOne} `
            + `held2=${heldTwo} afterOff=${afterOff} settled=${settled}`);

  // A LOUDNESS FLOOR, NOT A THRESHOLD DANCE. nil means "not enough audio yet"
  // (the field is OMITTED below ~-200 dB float noise), so an idle engine reads
  // null — that is the silence signal, and a real note reads far above -60.
  const sounding = (v) => v !== null && v > -60;

  // PRECONDITION. If the app never received the note, every later leg is
  // vacuous — a silent "afterOff" would then be a PASS for the wrong reason.
  // This is the m23-bl shape, so it is stated as the gate's own gate.
  const gotIt = sounding(heldOne);
  check("P1: the app RECEIVED the virtual-source note (precondition for everything below)",
        gotIt, `held1=${heldOne}`);
  if (!gotIt) {
    console.log("\nABORT: no audio after ON#1. The rest of this gate would be vacuous —");
    console.log("a silent 'afterOff' proves nothing when the note never arrived.");
    console.log("Check: is a MIDI input device selected? did setupChanged() run?");
    clearTimeout(killer); stop(); process.exit(2);
  }

  check("L1: the RETRIGGER still sounds (a voice is replaced, not silenced)",
        sounding(heldTwo), `held2=${heldTwo}`);

  // ⚠️ THERE IS NO "DID IT STACK?" CHECK HERE, AND THAT IS A MEASURED
  // DECISION, NOT AN OVERSIGHT (m23-ad). The obvious extra leg is "held2 is
  // within N dB of held1, therefore one voice, therefore no stack". It was
  // written, run against the mutant, and DELETED: two saw voices on the same
  // pitch measured only +0.69 dB over one — not the ≈ +5 dB the phase-naive
  // prediction assumed — so any band loose enough not to be flaky also PASSES
  // while the bug is happening. A check that green-lights the exact defect it
  // names is worse than no check: it launders the failure.
  //
  // Why so small: the two voices start ~1.5 s apart, so a saw and its copy
  // land at an arbitrary phase offset, and momentary LUFS is a 400 ms mean.
  // Partial cancellation eats most of the theoretical +6 dB.
  //
  // BE PRECISE ABOUT WHAT FAILED, or the next reader draws the wrong lesson:
  // the delta is NOT noise. It reproduced with a consistent sign and size —
  // 0.00 dB fixed, +0.69 dB mutant. What it cannot support is an ABSOLUTE
  // BAND, because no threshold separates +0.69 from 0.00 without being tighter
  // than the measurement is stable. If a future cycle wants a stacking check,
  // the viable form is a two-condition COMPARISON against a known-bad build,
  // not a band. L2/L3 below are the discriminators — verified: mutant 3/5
  // rc=1, fixed 4/4 rc=0.
  const delta = heldOne !== null && heldTwo !== null ? heldTwo - heldOne : null;
  console.log(`#   (observation only, NOT asserted) held2-held1 = `
            + `${delta === null ? "null" : delta.toFixed(2)} dB`);
  check("L2: ONE note-off silences the track — no orphaned voice survives (m23-ad)",
        !sounding(afterOff), `afterOff=${afterOff} (pre-m23-ad this stayed loud forever)`);
  check("L3: still silent 2.7 s later — it was a real close, not a slow release",
        !sounding(settled), `settled=${settled}`);
} catch (e) {
  console.log(`FAIL: gate threw — ${e && e.message}`);
  failed++;
}

console.log(`\n${results.filter((r) => r.ok).length}/${results.length} checks passed`);
clearTimeout(killer);
stopStaging(GATE);
try { ws.close(); } catch { /* ignore */ }
process.exit(failed === 0 ? 0 : 1);
