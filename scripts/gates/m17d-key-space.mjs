// m17-d orchestrator gate — space-bar transport (play from seeked beat, double-toggle, modifier/repeat/noWindow
// pass-throughs, posted spaces type into a focused rename field with transport untouched, record-stop leg).
// GATE LAW: clear text focus via project.new, never staged clicks (staged pointer acts don't resign the field
// editor). Staging: DAW_CONTROL_PORT=17695. Promoted from session scratchpad 2026-07-16 (m17-g).
// m17-d orchestrator gate — DISJOINT: seeked play at beat 32, rapid double-toggle,
// option/shift chords, repeat flag, rename-field two-space typing, record-stop leg.
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
  throw new Error("no connect");
}
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
const state = async () => { await sleep(300); return (await cmd("debug.keySpace", {})).result ?? {}; };

let r = await cmd("project.new");
ck("project.new", r.ok, r.error);
let s = await state();
ck("monitor installed, responder none, not playing", s.monitorInstalled === true && s.firstResponder === "none" && s.isPlaying === false, JSON.stringify(s));

// seeked play from beat 32
await cmd("transport.seek", { beats: 32 });
r = await cmd("debug.keySpace", { press: true });
s = await state();
ck("space -> playing from beat 32", s.isPlaying === true && s.positionBeats >= 32 && s.positionBeats < 34, JSON.stringify(s));
await sleep(400);
r = await cmd("debug.keySpace", { press: true });
s = await state();
ck("space again -> stopped", s.isPlaying === false, JSON.stringify(s));

// rapid double-toggle: play then stop back-to-back
await cmd("debug.keySpace", { press: true });
await cmd("debug.keySpace", { press: true });
s = await state();
ck("rapid double-toggle nets to stopped", s.isPlaying === false, JSON.stringify(s));

// chords pass through: option, shift, control (agent live-tested command)
for (const mod of ["option", "shift", "control"]) {
  r = await cmd("debug.keySpace", { press: true, [mod]: true });
  s = await state();
  if (s.isPlaying !== false) { await cmd("transport.stop"); }
  ck(`${mod}+space passes through (no transport)`, s.isPlaying === false, JSON.stringify(s));
}

// repeat flag ignored
r = await cmd("debug.keySpace", { press: true, repeat: true });
s = await state();
ck("key-repeat space ignored", s.isPlaying === false, JSON.stringify(s));

// noWindow -> secondary -> passthrough
r = await cmd("debug.keySpace", { press: true, noWindow: true });
s = await state();
ck("secondary/no-window space passes through", s.isPlaying === false, JSON.stringify(s));

// rename-field honesty: marker + rename focus + TWO posted spaces
r = await cmd("marker.add", { beat: 16, name: "Chorus" });
ck("marker added", r.ok, r.error);
r = await cmd("debug.markerRename", {});
ck("markerRename focus seam ok", r.ok, r.error ?? "");
s = await state();
ck("responder is text-editing", s.firstResponder === "text-editing", JSON.stringify(s));
await cmd("debug.keySpace", { press: true, post: true });
await sleep(250);
await cmd("debug.keySpace", { press: true, post: true });
s = await state();
ck("transport untouched while typing", s.isPlaying === false, JSON.stringify(s));
ck("field text actually gained spaces", typeof s.fieldText === "string" && / /.test(s.fieldText) && s.fieldText !== "Chorus",
  JSON.stringify(s.fieldText));

// clear focus (escape-equivalent: re-read after clicking off via arrangePointer clear + click empty)
await cmd("debug.arrangePointer", { act: "click", x: 0, y: 25 });
await sleep(300);
s = await state();
ck("focus cleared back to none", s.firstResponder === "none", JSON.stringify(s));

// record leg: arm a track, record, space stops
r = await cmd("track.add", { kind: "instrument", name: "RecTrk" });
const tid = (r.result?.track ?? r.result)?.id;
r = await cmd("track.setArm", { trackId: tid, armed: true });
ck("armed", r.ok, r.error);
r = await cmd("transport.record", {});
ck("recording started", r.ok, r.error);
await sleep(600);
s = await state();
ck("state shows recording", s.isRecording === true, JSON.stringify(s));
await cmd("debug.keySpace", { press: true });
s = await state();
ck("space stopped the recording", s.isRecording === false && s.isPlaying === false, JSON.stringify(s));

r = await cmd("project.new");
ck("normalized", r.ok, r.error);
console.log(`ORCH_SPACE_GATE pass=${pass} fail=${fail}`);
ws.close();
process.exit(fail ? 1 : 0);
