// m17-c orchestrator gate — arrange pointer zones at ppb 80 / L rows (tolerance edges, ghost bar-snap,
// empty-click seek, click-over-clip refusal, staged split + undo/redo, teaching errors). POINTER SETTLE LAW:
// act responses echo the PREVIOUS view-reported state — act, settle ~300 ms, then a BARE debug.arrangePointer {}
// read. Staging: DAW_CONTROL_PORT=17695. Promoted from session scratchpad 2026-07-16 (m17-g).
// m17-c zone legs re-run with hover -> settle -> BARE READ (view-reported state law).
const sleep = ms => new Promise(r => setTimeout(r, ms));
const ws = await new Promise((res, rej) => {
  const w = new WebSocket("ws://127.0.0.1:17695");
  w.addEventListener("open", () => res(w));
  w.addEventListener("error", () => rej(new Error("refused")));
});
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `oz${++n}`;
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
const hoverRead = async (x, y) => {
  await cmd("debug.arrangePointer", { act: "hover", x, y });
  await sleep(300);
  return (await cmd("debug.arrangePointer", {})).result ?? {};
};
let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};

let r = await cmd("project.new");
ck("project.new", r.ok, r.error);
r = await cmd("track.add", { kind: "instrument", name: "ZonesTrk" });
const tid = (r.result?.track ?? r.result)?.id;
r = await cmd("clip.addMIDI", { trackId: tid, atBeat: 8, lengthBeats: 8, name: "ZoneClip", notes: [
  { pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 96 }
]});
ck("fixture clip", r.ok, r.error);
await cmd("debug.arrangeZoom", { reset: true });
await cmd("debug.arrangeZoom", { ppb: 80 });
await cmd("debug.arrangeZoom", { rowStep: "large" });
await cmd("transport.seek", { beats: 24 });
await sleep(300);

let e = await hoverRead(22 * 80, 25);
ck("settled: hover empty at beat 22 -> zone empty", e.zone === "empty", JSON.stringify(e));
ck("settled: ghost snapped to bar (20|24)", e.ghostBeat === 20 || e.ghostBeat === 24, JSON.stringify(e));

e = await hoverRead(24 * 80, 25);
ck("settled: hover on playhead -> playhead-grab", e.zone === "playhead-grab", JSON.stringify(e));

e = await hoverRead(10 * 80, 25);
ck("settled: hover over clip -> clip zone, no ghost", e.zone === "clip" && e.ghostBeat == null, JSON.stringify(e));

// playhead-grab edge: 3px inside vs 12px outside the grab tolerance at ppb 80
e = await hoverRead(24 * 80 + 3, 25);
ck("settled: +3px still grab", e.zone === "playhead-grab", JSON.stringify(e));
e = await hoverRead(24 * 80 + 12, 25);
ck("settled: +12px not grab", e.zone !== "playhead-grab", JSON.stringify(e));

await cmd("debug.arrangePointer", { act: "clear" });
r = await cmd("project.new");
ck("normalized", r.ok, r.error);
console.log(`ORCH_ZONES pass=${pass} fail=${fail}`);
ws.close();
process.exit(fail ? 1 : 0);
