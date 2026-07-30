// m23ae-pedal-sustain — is a CC64-sustained note still sounding after 8 s?
//
// WHY A GATE AND NOT JUST THE UNIT TESTS. `LiveThruSustainTests` T8/T9/T10 drive
// the real `renderQuantum` against a real `PolySynthInstrument` and assert on
// AUDIO, and all three fail under a mutant — that coverage is genuine. But
// `thruRing` has exactly ONE producer in the whole tree: the CoreMIDI receive
// thread (`MIDIInputManager.swift:24`). No control command reaches it. So no
// unit test can answer the question a pianist would ask, which is not "is the
// tail re-armed" but "does the note still sound when I hold the pedal".
//
// This gate answers that one end to end, through real CoreMIDI:
//
//   virtual MIDI source -> CoreMIDI -> MIDIInputManager -> thruRing
//     -> InstrumentRenderer 6d re-arm -> polySynth -> master bus -> loudness
//
// THE INSTRUMENT IS CHOSEN TO MAKE THE BUG UNAMBIGUOUS. sustain = 1.0 holds the
// voice at full level for as long as it is open, so "still sounding at t=13" is
// a flat, loud reading rather than the ambiguous tail of a decaying patch. A
// piano-like envelope would have decayed into the noise floor on its own by the
// measurement window and made the two builds look identical — the same trap
// m23-ad's gate was built to avoid.
//
// Exit: 0 all checks pass, 1 a check failed, 2 could not set up.
import { spawn, spawnSync } from "child_process";
import {
  ROOT, sleep, launchStaging, stopStaging,
} from "./_staging.mjs";

const GATE = "m23ae";
const PROBE = process.env.M23AE_PROBE || "/tmp/m23ae-probe";
const PROBE_SRC = "scripts/probes/m23ae-pedal-sustain-probe.swift";
const PITCH = 60;

let failed = 0;
const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok: !!ok });
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}: ${name}${detail ? ` — ${detail}` : ""}`);
}

// Rebuilt every run: a stale binary would measure a sequence that no longer
// exists and the transcript would still look like a real measurement.
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
  const track = await send("track.add", { kind: "instrument", name: "m23ae pedal" });
  const trackId = track?.result?.id ?? track?.result?.track?.id;
  if (!trackId) {
    console.log(`ABORT: no track id in ${JSON.stringify(track).slice(0, 300)}`);
    stop(); process.exit(2);
  }

  await send("track.setInstrument", {
    trackId, kind: "polySynth", waveform: "saw",
    attack: 0.005, decay: 0.005, sustain: 1.0, release: 0.05, gain: 0.8,
  });
  await send("track.setArm", { trackId, armed: true });
  console.log(`# track ${trackId}: polySynth saw, sustain=1.0 release=0.05, ARMED`);

  await send("mixer.liveLoudness", { reset: true });
  const q = (r) => {
    const s = r?.result ?? {};
    return typeof s.momentaryLufs === "number" ? s.momentaryLufs : null;
  };

  // SAMPLE A WINDOW, NOT AN INSTANT (m23-ad). `momentaryLufs` is a 400 ms mean
  // and is OMITTED until the window has filled, so a single sample can read
  // `null` while a note is audibly playing. Taking the MAX is also the stricter
  // test for the silence legs: any audible moment anywhere fails them.
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

  // Probe timeline, from ITS go-ahead: t=0.5 CC64 down, t=0.7 ON, t=2.5 OFF
  // (key up), t=14.5 CC64 up, t=23.5 exit. stdin is a PIPE because the probe
  // blocks on a go-ahead line — see the handshake below.
  const probe = spawn(PROBE, [String(PITCH)], { stdio: ["pipe", "pipe", "pipe"] });
  // TEARDOWN FOR THE PROBE, WHICH `armTeardown` DOES NOT COVER (m23-ad/m23-bd):
  // it tears down STAGING, and the probe is a second child holding a VIRTUAL
  // MIDI SOURCE the user's live app on 17600 can see. `process.on("exit")` is
  // the right hook and NOT `finally` — it runs on `process.exit()`, which is how
  // both the catch path and the 300 s watchdog leave.
  process.on("exit", () => { try { probe.kill("SIGKILL"); } catch { /* gone */ } });
  const probeLog = [];
  probe.stdout.on("data", (d) => probeLog.push(String(d)));
  probe.stderr.on("data", (d) => probeLog.push(String(d)));
  // ATTACHED AT SPAWN, AWAITED LATER. Attaching `on("exit")` after the sampling
  // instead loses the event outright when the probe dies early — the listener
  // is registered on a process that already fired, and the gate then hangs to
  // its 300 s watchdog with the probe's stdout (the only diagnosis available)
  // still unprinted. Measured m23-ae: that is exactly how a probe that exited
  // at t≈16 presented, as a 300 s TIMEOUT with four null windows and no clue.
  let probeExit = null;
  const probeDone = new Promise((r) => probe.on("exit", (code, sig) => {
    probeExit = sig ? `signal ${sig}` : `code ${code}`;
    r();
  }));

  // ANCHOR EVERY WINDOW TO THE PROBE'S OWN STDOUT, NOT TO SLEEP ARITHMETIC.
  // The first draft of this gate used absolute sleeps from spawn and L2 failed
  // on a CORRECT build: the probe's clock starts after `MIDIClientCreate` +
  // `MIDISourceCreate`, so roughly a second of process launch and CoreMIDI
  // handshake sits between `spawn` and the probe's t=0 — and that offset is
  // machine-speed-dependent, which is a flake waiting to happen rather than a
  // constant to pad around. Anchoring makes every window relative to the event
  // it is actually about.
  async function awaitProbeLine(needle, timeoutMs = 40_000) {
    const t0 = Date.now();
    while (Date.now() - t0 < timeoutMs) {
      if (probeLog.join("").includes(needle)) return true;
      await sleep(60);
    }
    throw new Error(`probe never printed "${needle}" within ${timeoutMs} ms`);
  }

  // THE HANDSHAKE. The probe has created its virtual source and is blocked on
  // stdin. Do NOT let it play until the APP has actually connected that source:
  // the connect runs from a CoreMIDI notify block that hops to the main actor
  // (`MIDIInputManager.swift:191-196`), so it lands at a time no fixed sleep
  // can predict.
  //
  // `midi.listInputs` reads the manager's CACHED device list, which is exactly
  // what we want: that cache is refreshed by `setupChanged()`, so the probe
  // appearing in it IS evidence that the same pass connected the endpoint.
  // (It also forces the lazy client into existence if nothing else has.)
  //
  // ⚠️ EVERY `awaitProbeLine` BELOW DEPENDS ON THE PROBE'S `setvbuf` CALL.
  // Swift's `print` is block-buffered to a pipe, so without it the probe's
  // lines do not arrive until it EXITS. Measured m23-ae: that produced two
  // consecutive runs where all four windows read null and the gate looked like
  // it had caught a real defect — the windows had simply all opened after the
  // probe was gone. If this gate ever goes all-null again, check that first.
  await awaitProbeLine("waiting for the gate's go-ahead");
  let sawProbe = false;
  const seenAt = Date.now();
  while (Date.now() - seenAt < 25_000) {
    const inputs = (await send("midi.listInputs", {}))?.result?.inputs ?? [];
    if (inputs.some((d) => d.name === "m23ae-probe" && d.isOnline)) { sawProbe = true; break; }
    await sleep(250);
  }
  console.log(`# app sees the probe endpoint: ${sawProbe} `
            + `(after ${((Date.now() - seenAt) / 1000).toFixed(2)} s)`);
  if (!sawProbe) {
    // ABORT, not FAIL. Nothing below could distinguish "the pedal fix is broken"
    // from "the app never connected the source", and reporting the silence legs
    // as passes would be the worse outcome of the two.
    console.log("\nABORT: the app never enumerated the probe's virtual source.");
    console.log("Every leg below would be vacuous — silence proves nothing when");
    console.log("no MIDI could ever have arrived.");
    clearTimeout(killer); stop(); process.exit(2);
  }
  probe.stdin.write("go\n");

  // The note is sounding with the key still down.
  await awaitProbeLine("ON      (voice opens");
  await sleep(600);
  const withKey = await maxOver(900, "withKey (pedal down, key DOWN)");

  // KEY UP. Both builds still sound here — the pre-fix tail has its full 8 s
  // left to run — so this leg is a PRECONDITION, not a discriminator.
  const tOff = (await awaitProbeLine("OFF     (KEY UP"), Date.now());
  await sleep(500);
  const justAfterOff = await maxOver(900, "justAfterOff (key UP + ~0.5 s)");

  // THE DISCRIMINATING WINDOW, and the only leg that separates the builds.
  // `liveTailSeconds` is 8 s counted from the note-off, so a pre-m23-ae voice
  // is already gone at OFF+8. Opening at OFF+9.0 puts EVERY sample past it,
  // and the probe holds the pedal until OFF+12.0 so the window closes first.
  const untilPastTail = 9_000 - (Date.now() - tOff);
  if (untilPastTail > 0) await sleep(untilPastTail);
  const pastTail = await maxOver(1400, "pastTail (OFF+9.0, STRICTLY past liveTailSeconds)");

  // The pedal lifts and the deferred release finally lands. +2.5 s is not a
  // guess: measured m23-ae, momentary runs -17.84 → -19.20 → -21.02 → -39.46 →
  // nil across ~430 ms after CC64=0, so this window opens deep in the nil
  // region. Sampling any earlier catches the decay itself — which is exactly
  // how this leg first failed on a correct build.
  await awaitProbeLine("CC64 UP");
  await sleep(2500);
  const afterPedalUp = await maxOver(1800, "afterPedalUp (CC64=0 + 2.5 s)");

  // Bounded — a probe that never exits must not silently become a 300 s
  // watchdog kill, which reports identically to "the gate found nothing".
  await Promise.race([probeDone, sleep(15_000)]);
  console.log(probeLog.join("").trim().split("\n").map((l) => `  ${l}`).join("\n"));
  console.log(`# probe exit: ${probeExit ?? "STILL RUNNING (did not exit in 15 s)"}`);

  console.log(`# momentary LUFS: withKey=${withKey} justAfterOff=${justAfterOff} `
            + `pastTail=${pastTail} afterPedalUp=${afterPedalUp}`);

  const sounding = (v) => v !== null && v > -60;

  // PRECONDITIONS (the m23-bl shape, implemented locally rather than filed).
  // If the app never received the note, "pastTail is sounding" could never pass
  // and "afterPedalUp is silent" would pass for entirely the wrong reason.
  const gotIt = sounding(withKey);
  check("P1: the app RECEIVED the virtual-source note (precondition for everything below)",
        gotIt, `withKey=${withKey}`);
  if (!gotIt) {
    console.log("\nABORT: no audio while the key was down. The rest of this gate would be");
    console.log("vacuous — a silent 'afterPedalUp' proves nothing when nothing ever sounded.");
    clearTimeout(killer); stop(); process.exit(2);
  }
  check("P2: still sounding just after the KEY went up (pre-fix builds pass this too)",
        sounding(justAfterOff), `justAfterOff=${justAfterOff}`);

  // THE HEADLINE. Pre-m23-ae this read null/silent: `openLiveCount` was 0 (the
  // key is up), nothing re-armed the tail, and the sustaining voice was cut.
  check("L1: the PEDAL-SUSTAINED voice still sounds past liveTailSeconds (m23-ae)",
        sounding(pastTail),
        `pastTail=${pastTail} (pre-m23-ae the tail expired here and cut it)`);

  // Without this the fix is indistinguishable from "the node never sleeps once
  // a pedal event is seen" — which would be a stuck note, not a fix.
  check("L2: lifting the pedal DOES release it — the note is not stuck forever",
        !sounding(afterPedalUp), `afterPedalUp=${afterPedalUp}`);
} catch (e) {
  console.log(`FAIL: gate threw — ${e && e.message}`);
  failed++;
}

console.log(`\n${results.filter((r) => r.ok).length}/${results.length} checks passed`);
clearTimeout(killer);
stopStaging(GATE);
try { ws.close(); } catch { /* ignore */ }
process.exit(failed === 0 ? 0 : 1);
