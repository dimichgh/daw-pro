// m17-b orchestrator gate — arrange zoom (direct non-ladder ppb sets, clamp 9999->200, playhead anchor <2px,
// off-screen center-beat anchor, layout==mirror lockstep incl. 8-set burst, min-zoom offset floor, rowStep,
// snapshot/undo-clean, relaunch persistence). SETTLE LAW: layout hOffset lands NEXT main-actor turn — settle
// ~250 ms before asserting; the analytic mirror is exact immediately. KNOWN SCRIPT ARTIFACTS (accepted
// baseline 16/18): clip.addMIDI uses atBeat (the far-clip scenery leg sends startBeat and fails harmlessly);
// the undo-regex leg matches this script's own "ZoomOrch" track name — verify via a direct edit.history read.
// Staging: DAW_CONTROL_PORT=17695. Promoted from session scratchpad 2026-07-16 (m17-g).
// m17-b orch gate v2 — fixed verbs, explicit reset baseline, settle-then-read (layout applies on a fresh main-actor turn).
// NOTE: capture/output paths point at /tmp/daw-gate-out — `mkdir -p /tmp/daw-gate-out` before running.
const SCRATCH = "/tmp/daw-gate-out/m17b-orch";
const sleep = ms => new Promise(r => setTimeout(r, ms));

const ws = await new Promise((res, rej) => {
  const w = new WebSocket("ws://127.0.0.1:17695");
  w.addEventListener("open", () => res(w));
  w.addEventListener("error", () => rej(new Error("refused")));
});
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `oz2_${++n}`;
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
const settledState = async () => { await sleep(250); return (await cmd("debug.arrangeZoom", {})).result; };
let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};

let r = await cmd("project.new");
ck("project.new ok", r.ok, r.error);
r = await cmd("track.add", { kind: "instrument", name: "ZoomOrch" });
const tid = (r.result?.track ?? r.result)?.id;
ck("instrument track ok", r.ok && !!tid, r.error);
r = await cmd("clip.addMIDI", { trackId: tid, startBeat: 48, lengthBeats: 8, name: "FarClip" });
ck("far MIDI clip at beat 48", r.ok, r.error);

await cmd("debug.arrangeZoom", { reset: true });
let s = await settledState();
ck("reset baseline 16/medium, layout==mirror", s.ppb === 16 && s.rowStep === "medium" && Math.abs(s.hOffset - s.hOffsetMirror) < 1.0, JSON.stringify(s));

// visible-playhead anchor at a DIRECT non-ladder ppb
r = await cmd("transport.seek", { beats: 50 });
ck("seek 50 ok", r.ok, r.error);
s = await settledState();
const xPre = s.playheadScreenX;
ck("playhead visible pre-zoom", xPre >= 0 && xPre <= s.viewportWidth, JSON.stringify(s));
await cmd("debug.arrangeZoom", { ppb: 56 });
s = await settledState();
ck("direct 56: playhead anchor held (<2px)", Math.abs(s.playheadScreenX - xPre) < 2, `pre=${xPre} post=${s.playheadScreenX}`);
ck("direct 56: layout settled == mirror", Math.abs(s.hOffset - s.hOffsetMirror) < 1.0, JSON.stringify(s));
r = await cmd("debug.captureUI", { path: `${SCRATCH}/orch-zoom56-settled.png` });
ck("capture at settled 56", r.ok, r.error);

// off-screen playhead -> viewport-center anchor, settled
await cmd("debug.arrangeZoom", { reset: true });
await cmd("transport.seek", { beats: 400 });
s = await settledState();
const centerPre = (s.hOffset + s.viewportWidth / 2) / s.ppb;
ck("playhead off-screen", s.playheadScreenX > s.viewportWidth, JSON.stringify(s));
await cmd("debug.arrangeZoom", { step: "in" });
s = await settledState();
const centerPost = (s.hOffset + s.viewportWidth / 2) / s.ppb;
ck("off-screen zoom keeps center beat (settled, ±0.5)", Math.abs(centerPre - centerPost) < 0.5, `pre=${centerPre} post=${centerPost}`);
ck("off-screen zoom: layout == mirror settled", Math.abs(s.hOffset - s.hOffsetMirror) < 1.0, JSON.stringify(s));

// zoom out to min from a scrolled position: offsets stay non-negative and lockstep
await cmd("debug.arrangeZoom", { ppb: 4 });
s = await settledState();
ck("min zoom from scrolled: offset >= 0 and lockstep", s.ppb === 4 && s.hOffset >= 0 && Math.abs(s.hOffset - s.hOffsetMirror) < 1.0, JSON.stringify(s));

// rapid burst: 8 sets back-to-back then settle — no divergence
for (const p of [10, 80, 33, 120, 7, 64, 45, 100]) await cmd("debug.arrangeZoom", { ppb: p });
s = await settledState();
ck("burst of 8 direct sets settles lockstep at 100", s.ppb === 100 && Math.abs(s.hOffset - s.hOffsetMirror) < 1.0, JSON.stringify(s));

// stage persistence values for the relaunch check
await cmd("debug.arrangeZoom", { ppb: 40 });
await cmd("debug.arrangeZoom", { rowStep: "small" });
s = await settledState();
ck("staged 40/small for relaunch", s.ppb === 40 && s.rowStep === "small" && s.rowHeight === 24, JSON.stringify(s));

r = await cmd("edit.history");
ck("still no zoom entries in undo", (r.result?.undo ?? []).every(l => !/zoom|ppb|row/i.test(l)));
r = await cmd("project.snapshot");
ck("no zoom keys in snapshot", !JSON.stringify(r.result).match(/arrangePPB|pixelsPerBeat|rowStep/), "");
r = await cmd("project.new");
ck("normalized non-dirty for kill", r.ok, r.error);

console.log(`ORCH_ZOOM_GATE2 pass=${pass} fail=${fail}`);
ws.close();
process.exit(fail ? 1 : 0);
