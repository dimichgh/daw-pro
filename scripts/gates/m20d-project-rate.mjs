// m20-d gate — the live graph runs at the PROJECT rate, not the device rate.
//
// WHAT THIS PROVES AND WHY IT NEEDED TO BE LIVE. m19-k Phase 2 pins the live
// graph to `AudioEngine.projectSampleRate` (48 kHz) and lets the graph's last
// edge into `outputNode` become the ONE conversion edge. Every Swift-side
// test of that runs against a graph whose rate was handed to it — which is
// exactly the thing under test, so it cannot fail for the reason that
// matters. The only way to know the SHIPPING app stopped following the device
// is to put a real device at a different rate underneath a real engine and
// read what the render callbacks actually stamp.
//
// ⚠️ THE FALSIFIABILITY IS MEASURED, NOT ARGUED. This gate was written and run
// against the UNMODIFIED (pre-m20-d) tree first, with BlackHole staged at
// 44100 Hz and pinned as the app's output:
//
//     reading                            sampleRate   quantumFrames
//     after the pin, no rebuild            48000          558
//     after a teardown-class rebuild       44100          512
//
// The SECOND reading is the one that discriminates — `rebuildEngine` is where
// the old code re-read the device — and it is why leg L3 forces a rebuild
// instead of trusting the post-pin state. (The first reading is kept as L2
// because it is still an invariant worth pinning, but on its own it would
// have passed before m20-d existed and would have proved nothing.)
// `quantumFrames` is the mechanical corroborator: 512 was the device-native
// pull (graph rate == device rate, no converter) and 558 ≈ 512 × 48000/44100
// the output-edge converter engaged. L4c asserts that RATIO against this run's
// own native pull rather than against 512 — hard-coding one machine's IO
// buffer would pass on any larger buffer for a reason unrelated to the flip.
//
// ⚠️ ANTI-VACUITY: every rate assertion below is paired with a check that the
// DEVICE really is at 44100 at that moment. If the staging write silently
// fails, the graph reads 48000 for the boring reason and a gate that only
// looked at the graph would report a confident pass. It fails instead.
//
// AUDIBLE? NO. The app's output is pinned to BlackHole (a silent virtual
// device) before any transport starts, and the pin is app-local — the macOS
// default output is read before, during and after, and never moves. Safe to
// run unattended.
//
// THE ONE THING THIS WRITES: BlackHole's nominal sample rate. It is restored
// to 48000 in a `finally` with the read-back verified, because an uncaught
// throw stranding that setting is exactly what `m20b/bhrate`'s own header was
// written to complain about.
//
// HOW TO RUN — there is a BUILD STEP, and on a fresh checkout it is not
// optional. `m20d-bhrate` is gitignored build output, so this gate aborts
// (exit 2) before staging anything until you compile it:
//
//     swiftc -O scripts/gates/m20d-bhrate.swift -o scripts/gates/m20d-bhrate
//     node scripts/gates/m20d-project-rate.mjs
//
// The abort prints that same swiftc line, but only AFTER you have already run
// the gate — hence saying it here, where it is visible first.
//
// Staging: DAW_CONTROL_PORT=17695. The user's live app on 17600 is never a
// target — `startStaging` asserts this.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, ROOT } from "./_staging.mjs";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";

const GATE = "m20d-project-rate";
const UID = "BlackHole2ch_UID";
const PROJECT_RATE = 48000;
const STAGED_DEVICE_RATE = 44100;
const RESTORE_RATE = 48000;

// The device-rate tool. Its SOURCE is committed (`m20d-bhrate.swift`) so this
// gate is reproducible; the compiled binary is a build artifact and is not.
// It can only ever resolve BlackHole — the UID is a compile-time constant with
// no argument that overrides it, so it cannot reach the user's real devices.
const BHRATE = path.join(ROOT, "scripts", "gates", "m20d-bhrate");

let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};

if (!existsSync(BHRATE)) {
  console.log(`ABORT — device-rate helper missing: ${BHRATE}`);
  console.log("       build it:  swiftc -O scripts/gates/m20d-bhrate.swift -o scripts/gates/m20d-bhrate");
  process.exit(2);
}
const rate = (...args) => execFileSync(BHRATE, args, { encoding: "utf8" }).trim();
const readBackOf = s => { const m = /read-back=([0-9.]+)/.exec(s); return m ? Number(m[1]) : NaN; };

console.log("device rate before staging:", rate());
const staged = rate(String(STAGED_DEVICE_RATE));
console.log(`staged -> ${staged}`);
ck("L0 loopback staged at 44100 (the whole gate is vacuous otherwise)",
   readBackOf(staged) === STAGED_DEVICE_RATE, staged);

buildOrAbort({ label: "building staging binary (m20d)…" });
startStaging({ gate: GATE });

let ws;
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `pr${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}

const devicesOf = r => r.result?.devices ?? [];
const defaultUID = ds => (ds.find(d => d.isDefault) ?? {}).uid ?? null;

/// One measurement: close the old telemetry window, render for real, read the
/// window we just made. `engine.performanceStats.sampleRate` is stamped per
/// render callback by the instrumented Tier-1 blocks with the GRAPH rate — it
/// is 0 when nothing rendered, so `callbackCount` is checked by every caller.
/// A 0 must never be read as "not the device rate".
async function measure(label) {
  await cmd("engine.performanceStats", { reset: true });
  await cmd("transport.seek", { beats: 0 });
  await cmd("transport.play");
  await sleep(1200);
  const r = await cmd("engine.performanceStats");
  await cmd("transport.stop");
  const s = r.result ?? {};
  console.log(`  [${label}] sampleRate=${s.sampleRate} quantum=${s.quantumFrames} callbacks=${s.callbackCount} frames=${s.renderedFrames}`);
  return s;
}

/// What the APP reports for the pinned device right now — the anti-vacuity
/// half of every rate assertion.
async function pinnedDeviceRate() {
  const r = await cmd("output.listDevices");
  return (devicesOf(r).find(d => d.uid === UID) ?? {}).sampleRate ?? null;
}

let systemDefault = null;
try {
  ws = await connect();

  // ---- L1: pin the loopback BEFORE any transport starts ------------------
  let r = await cmd("output.listDevices");
  const initial = devicesOf(r);
  systemDefault = defaultUID(initial);
  ck("L1 a system default exists (the baseline the safety leg is measured against)",
     systemDefault !== null, JSON.stringify(initial));
  ck("L1 the loopback is present and the app reads it at 44100",
     (initial.find(d => d.uid === UID) ?? {}).sampleRate === STAGED_DEVICE_RATE,
     JSON.stringify(initial.find(d => d.uid === UID)));

  r = await cmd("output.setDevice", { uid: UID });
  ck("L1 output pinned to the loopback (nothing below may reach the speakers)",
     r.ok && (devicesOf(r).find(d => d.uid === UID) ?? {}).isSelected === true, r.error);

  // Something that renders through an instrument source node, so the Tier-1
  // blocks have a reason to stamp a rate at all.
  r = await cmd("track.add", { kind: "instrument", name: "RateInvariance" });
  const tid = (r.result?.track ?? r.result)?.id;
  ck("L1 instrument track added", r.ok && !!tid, r.error);
  // `atBeat`, NOT `startBeat` — `clip.addMIDI` rejects unknown keys, so the
  // wrong name is a refusal, not a default (Commands.swift:1945-1946).
  r = await cmd("clip.addMIDI", {
    trackId: tid, atBeat: 0, lengthBeats: 8, name: "Hold",
    notes: [{ pitch: 69, startBeat: 0, lengthBeats: 8, velocity: 90 }],
  });
  ck("L1 MIDI clip added with a held note (the source node has real work to do)",
     r.ok && !!(r.result?.clip ?? r.result)?.id, r.error);

  // ---- L2: the post-pin state -------------------------------------------
  // NOT the discriminating leg (it read 48000 before m20-d too, because the
  // graph had been built from the then-default) — pinned as an invariant.
  let s = await measure("L2 pinned, no rebuild");
  ck("L2 render callbacks actually happened (a 0 reading is not evidence)",
     (s.callbackCount ?? 0) > 0 && (s.renderedFrames ?? 0) > 0, JSON.stringify(s));
  ck("L2 graph runs at the project rate", s.sampleRate === PROJECT_RATE, s.sampleRate);
  ck("L2 the device is still at 44100 under it (anti-vacuity)",
     await pinnedDeviceRate() === STAGED_DEVICE_RATE);

  // ---- L3: THE DISCRIMINATING LEG ---------------------------------------
  // A teardown-class change replaces the engine and rebuilds the graph. That
  // is where the pre-m20-d code re-read the device and came back 44100/512.
  r = await cmd("track.add", { kind: "audio", name: "Scratch" });
  const scratch = (r.result?.track ?? r.result)?.id;
  r = await cmd("track.remove", { trackId: scratch });
  ck("L3 teardown-class change accepted (forces the engine rebuild)", r.ok, r.error);
  await sleep(400);

  s = await measure("L3 after rebuild");
  ck("L3 render callbacks actually happened (a 0 reading is not evidence)",
     (s.callbackCount ?? 0) > 0 && (s.renderedFrames ?? 0) > 0, JSON.stringify(s));
  ck("L3 ⚠️ THE FLIP: a REBUILT graph still runs at 48000 (read 44100 pre-m20-d)",
     s.sampleRate === PROJECT_RATE, s.sampleRate);
  ck("L3 the device is still at 44100 under it (anti-vacuity)",
     await pinnedDeviceRate() === STAGED_DEVICE_RATE);
  ck("L3 audio flowed THROUGH the output edge (frames rendered, not a stalled graph)",
     (s.renderedFrames ?? 0) > 10_000, s.renderedFrames);
  // Recorded here, ASSERTED in L4 — the pull size only means something next to
  // the same device's native pull, which L4a is what produces. A bare
  // `quantumFrames > 512` would have hard-coded one machine's IO buffer and
  // passed on any larger one for the wrong reason.
  const convertedQuantum = s.quantumFrames;

  // ---- L4: device-rate invariance across a live flip ---------------------
  // The point of the whole design: chain latencies, PDC and automation math
  // stop moving when the hardware moves. Flip the loopback under a running
  // pin and the graph rate must not budge.
  console.log("flip -> 48000:", rate("48000"));
  await sleep(800);
  s = await measure("L4a device at 48000");
  ck("L4a graph unchanged at 48000 while the device sits at 48000",
     s.sampleRate === PROJECT_RATE && (s.callbackCount ?? 0) > 0, JSON.stringify(s));
  // Device rate == graph rate here, so no converter: this IS the device's
  // native pull size, whatever this machine's IO buffer happens to be.
  const nativeQuantum = s.quantumFrames;

  console.log("flip -> 44100:", rate("44100"));
  await sleep(800);
  ck("L4b the device really moved back to 44100 (anti-vacuity)",
     await pinnedDeviceRate() === STAGED_DEVICE_RATE);
  s = await measure("L4b device back at 44100");
  ck("L4b render callbacks survived the flip", (s.callbackCount ?? 0) > 0, JSON.stringify(s));
  ck("L4b ⚠️ graph rate did NOT follow the device back down (read 44100 pre-m20-d)",
     s.sampleRate === PROJECT_RATE, s.sampleRate);

  // ---- L4c: the converter, proven by arithmetic and not by a constant -----
  // A 48 kHz graph feeding a 44.1 kHz device must be pulled for MORE frames
  // per device callback, by exactly the rate ratio. Comparing against this
  // run's own native pull needs no knowledge of the machine's buffer size.
  //
  // ⚠️ L4c CORROBORATES THE MECHANISM; IT DOES NOT DISCRIMINATE. Measured
  // under the `graphRate: nil` mutant: the graph followed the device, so the
  // converter simply engaged in the other direction (native 470 = 512 ×
  // 44100/48000 with the device at 48 k, converted 512) and BOTH L4c checks
  // still passed while L2/L3/L4a/L4b failed. Read it as "a converter is on
  // this edge and the arithmetic is sane", never as evidence of WHICH rate the
  // graph chose — that is L2/L3/L4a/L4b's job, and only theirs.
  const expected = nativeQuantum * (PROJECT_RATE / STAGED_DEVICE_RATE);
  const ratioOK = q => Number.isFinite(q) && Math.abs(q - expected) <= 2;
  console.log(`  quantum: native=${nativeQuantum} converted=${s.quantumFrames} (L3 read ${convertedQuantum}) expected≈${expected.toFixed(1)}`);
  ck("L4c the output-edge converter is engaged — pull size scales by 48000/44100",
     ratioOK(s.quantumFrames), `${s.quantumFrames} vs ≈${expected.toFixed(1)}`);
  // ⚠️ Both converted readings are checked against the RATIO, not against each
  // other. An earlier version of this leg asserted `L3 === L4b` — "same
  // condition, same pull size" — and it FAILED 558 vs 557 on the first real
  // run. That was the gate being wrong about resamplers, not the app: the
  // ratio is 557.3, so the pull alternates between 557 and 558 to hold the
  // average. An equality here would have been a permanent coin-flip flake.
  ck("L4c the L3 reading scales by the same ratio (the converter was already engaged there)",
     ratioOK(convertedQuantum), `${convertedQuantum} vs ≈${expected.toFixed(1)}`);

  // ---- L5: the m20-j safety property still holds -------------------------
  r = await cmd("output.listDevices");
  ck("L5 SYSTEM DEFAULT UNMOVED across the whole gate",
     defaultUID(devicesOf(r)) === systemDefault,
     `${systemDefault} -> ${defaultUID(devicesOf(r))}`);

  r = await cmd("output.setDevice", {});
  ck("L5 pin released", r.ok && devicesOf(r).every(d => !d.isSelected), r.error);
} catch (e) {
  fail++;
  console.log("FAIL gate threw :: " + (e?.stack ?? e?.message ?? e));
} finally {
  try { ws?.close(); } catch {}
  try { stopStaging(GATE); } catch (e) { console.log("stopStaging: " + e?.message); }
  // The ONE written setting, restored unconditionally and VERIFIED by
  // read-back — a restore whose status code was never checked is how m20-b
  // stranded this device the first time.
  const restored = rate(String(RESTORE_RATE));
  console.log("device rate restored ->", restored);
  ck("L6 loopback nominal rate restored to 48000 (read-back verified)",
     readBackOf(restored) === RESTORE_RATE, restored);
}

console.log(`ORCH_M20D pass=${pass} fail=${fail}`);
process.exit(fail ? 1 : 0);
