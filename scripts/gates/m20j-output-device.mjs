// m20-j gate — output-device selection over the live control socket.
//
// WHY THIS EXISTS AS A LIVE GATE AND NOT ONLY AS SWIFT TESTS. The Swift side
// covers the wire in `CommandRouter` tests against a FakeEngine, and the
// hardware in real-CoreAudio engine tests — but never both end to end. A
// round-trip that goes through the real router, the real store and a real
// AUHAL is the only thing that proves the feature works as shipped, and the
// m20-j implementer said plainly that they had not run one.
//
// THE SAFETY CLAIM THIS GATE IS REALLY HERE TO DEFEND: pinning DAW Pro's
// output must NEVER move the macOS default output device. That is the entire
// reason this feature was built instead of the alternatives — the user chose
// it over "temporarily repoint your system default" precisely so their
// speakers keep working. So the default is read from CoreAudio (via the app's
// own live `isDefault`, which is re-read per call, not cached) BEFORE any pin,
// after a pin, and after the reset, and any movement fails the gate.
//
// Staging: DAW_CONTROL_PORT=17695. The user's live app on 17600 is never a
// target — `startStaging` asserts this.
import { sleep, buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "m20j-output-device";
buildOrAbort({ label: "building staging binary (m20j)…" });
startStaging({ gate: GATE });
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `od${++n}`;
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
let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};
const devicesOf = r => r.result?.devices ?? [];
const defaultUID = ds => (ds.find(d => d.isDefault) ?? {}).uid ?? null;
const selectedUIDs = ds => ds.filter(d => d.isSelected).map(d => d.uid);

// ---- L1: the list, and the shape every later leg reads -------------------
let r = await cmd("output.listDevices");
ck("L1 output.listDevices ok", r.ok, r.error);
const initial = devicesOf(r);
ck("L1 at least one output device", initial.length > 0, JSON.stringify(initial));
const FIELDS = ["uid", "name", "sampleRate", "channelCount", "isDefault", "isSelected"];
const missing = FIELDS.filter(f => !(f in (initial[0] ?? {})));
ck("L1 every documented field present", missing.length === 0, "missing: " + missing.join(","));

// THE BASELINE the safety claim is measured against.
const systemDefault = defaultUID(initial);
ck("L1 a system default exists", systemDefault !== null, JSON.stringify(initial));
ck("L1 fresh app follows the default (nothing pinned)",
   selectedUIDs(initial).length === 0, JSON.stringify(selectedUIDs(initial)));

// ---- L2: pin a NON-default device ---------------------------------------
// Prefer the loopback: pinning is app-local so any device is safe, but a
// silent one cannot startle the user if something later plays through it.
const candidates = initial.filter(d => !d.isDefault);
if (candidates.length === 0) {
  console.log("SKIP L2..L5 — single-output machine, no non-default device to pin");
  console.log(`ORCH_M20J pass=${pass} fail=${fail} (partial: one output device)`);
  ws.close(); stopStaging(GATE); process.exit(fail ? 1 : 0);
}
const target = candidates.find(d => d.uid === "BlackHole2ch_UID") ?? candidates[0];

r = await cmd("output.setDevice", { uid: target.uid });
ck("L2 output.setDevice ok", r.ok, r.error);
let after = devicesOf(r);
ck("L2 response reflects the pin without a second call",
   selectedUIDs(after).join() === target.uid, JSON.stringify(selectedUIDs(after)));
const pinned = after.find(d => d.uid === target.uid) ?? {};
ck("L2 pinned device is isSelected AND not isDefault — the two fields are independent",
   pinned.isSelected === true && pinned.isDefault === false, JSON.stringify(pinned));

// ⚠️ THE LOAD-BEARING ASSERTION. If this ever fails the feature is actively
// harmful: it means choosing an output inside DAW Pro moved the user's whole
// machine, silencing every other app.
ck("L2 SYSTEM DEFAULT UNMOVED by the pin",
   defaultUID(after) === systemDefault, `${systemDefault} -> ${defaultUID(after)}`);

// ---- L3: the pin is durable, not just echoed back ------------------------
await sleep(300);
r = await cmd("output.listDevices");
after = devicesOf(r);
ck("L3 a FRESH list still reports the pin (not just the setDevice echo)",
   selectedUIDs(after).join() === target.uid, JSON.stringify(selectedUIDs(after)));
ck("L3 SYSTEM DEFAULT still unmoved", defaultUID(after) === systemDefault,
   `${systemDefault} -> ${defaultUID(after)}`);

// ---- L4: teaching errors -------------------------------------------------
r = await cmd("output.setDevice", { uid: "no-such-device-uid" });
ck("L4 unknown uid is refused", r.ok === false || r.error != null, JSON.stringify(r));
ck("L4 the refusal teaches the WIRE verb (not the MCP tool name)",
   /output\.listDevices/.test(JSON.stringify(r.error ?? "")), JSON.stringify(r.error));
r = await cmd("output.listDevices");
ck("L4 a REFUSED pin left the previous selection intact",
   selectedUIDs(devicesOf(r)).join() === target.uid,
   JSON.stringify(selectedUIDs(devicesOf(r))));

r = await cmd("output.setDevice", { uid: target.uid, bogusKey: 1 });
ck("L4 unknown key rejected", r.ok === false || r.error != null, JSON.stringify(r));

// ---- L5: reset returns to following the default --------------------------
r = await cmd("output.setDevice", {});
ck("L5 omitted uid ok", r.ok, r.error);
after = devicesOf(r);
ck("L5 omitted uid clears the pin — following the default again",
   selectedUIDs(after).length === 0, JSON.stringify(selectedUIDs(after)));
ck("L5 SYSTEM DEFAULT unmoved across the whole suite",
   defaultUID(after) === systemDefault, `${systemDefault} -> ${defaultUID(after)}`);

console.log(`ORCH_M20J pass=${pass} fail=${fail}`);
ws.close();
stopStaging(GATE);
process.exit(fail ? 1 : 0);
