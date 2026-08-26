// m17-b orchestrator gate — arrange zoom (direct non-ladder ppb sets, clamp 9999->200, playhead anchor <2px,
// off-screen center-beat anchor, layout==mirror lockstep incl. 8-set burst, min-zoom offset floor, rowStep,
// snapshot/undo-clean, relaunch persistence). SETTLE LAW: layout hOffset lands NEXT main-actor turn — settle
// ~250 ms before asserting; the analytic mirror is exact immediately. KNOWN SCRIPT ARTIFACT (baseline
// 20/20, MEASURED 2026-08-10): no known script artifact remains. The far-clip scenery leg used to send
// `startBeat`, which `clip.addMIDI` REJECTS (it takes `atBeat`), so that leg was red for the gate's
// whole life and was documented as 'fails harmlessly' rather than fixed (m23-bn). Fixed 2026-08-10 and
// VERIFIED by a real run: `ORCH_ZOOM_GATE2 pass=20 fail=0`, exit 0.
// m23-ee-2b FIXED the second long-standing artifact: the fixture track was named "ZoomOrch", which the undo
// leg's own /zoom|ppb|row/i regex matched, so that leg was red for the gate's whole life over a TRACK NAME
// while the app was correct. Renamed to "OrchA". The regex was always testing the right property; the
// fixture collided with it. LAW: a gate's fixture names must not be able to satisfy its own assertions.
// Staging: DAW_CONTROL_PORT=17695. Promoted from session scratchpad 2026-07-16 (m17-g).
// m17-b orch gate v2 — fixed verbs, explicit reset baseline, settle-then-read (layout applies on a fresh main-actor turn).
// m23-ac-3a: was "class 3" — it never launched anything and drove whatever was
// on 17695. It now builds and launches its own instance. GATE is "m17b-orch" so
// that `startStaging` creates the SAME `/tmp/daw-gate-out/m17b-orch` this gate
// already writes its captures into; the old "mkdir -p before running" note is
// obsolete because the harness makes the directory.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, verdict } from "./_staging.mjs";

const GATE = "m17b-orch";
const SCRATCH = `/tmp/daw-gate-out/${GATE}`;

buildOrAbort({ label: "building staging binary (m17b)…" });
startStaging({ gate: GATE });
const ws = await connect();
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

// m23-bg: pin the capture window and CONFIRM it stuck before anything else
// runs. A pin's own echo is not proof it took — until m23-dw fixed it,
// `debug.windowFrame {width:1440,height:640}` used to return 640 exactly, then
// the window silently drifted to 672 within ~100ms and held there (WindowFloor
// is applied to the content area below the titlebar while this command sets a
// contentRect INCLUDING it, +32 exactly). m23-dw fixed the drift itself: that
// same request now lands on 672 immediately and stays (`WindowFloor.
// minWindowContentHeight`) — but this gate pins {1400,1000} anyway, which
// held perfectly even before the fix, and keeps the re-read-confirm pattern
// as a general defense, not one specific to the old bug. So this settles,
// then re-reads with a BARE (mutation-free — DAWProApp.swift:3617 only
// mutates when width/height are present) call and asserts the re-read
// matches the request. Unpinned, this gate would inherit whatever size the
// LAST gate run on this machine left in the shared DAWApp autosave domain.
{
  let wf = null;
  for (let i = 0; i < 20 && !(wf && typeof wf.width === "number"); i++) {
    wf = (await cmd("debug.windowFrame", {})).result;
    if (!(wf && typeof wf.width === "number")) await sleep(250);
  }
  ck(`${GATE} m23-bg window exists pre-pin`, wf && typeof wf.width === "number", JSON.stringify(wf));
  await cmd("debug.windowFrame", { width: 1400, height: 1000 });
  await sleep(300);
  wf = (await cmd("debug.windowFrame", {})).result;
  console.log(`${GATE} m23-bg pin: requested 1400x1000, confirmed ${wf?.width}x${wf?.height}`);
  ck(`${GATE} m23-bg pin took (re-read matches request)`, wf?.width === 1400 && wf?.height === 1000, JSON.stringify(wf));
}

let r = await cmd("project.new");
ck("project.new ok", r.ok, r.error);
// m23-ee-2b: name must NOT contain zoom/ppb/row — the undo leg at :133 greps its
// own journal for those words, and "ZoomOrch" made that leg fail on itself.
r = await cmd("track.add", { kind: "instrument", name: "OrchA" });
const tid = (r.result?.track ?? r.result)?.id;
ck("instrument track ok", r.ok && !!tid, r.error);
r = await cmd("clip.addMIDI", { trackId: tid, atBeat: 48, lengthBeats: 8, name: "FarClip" });
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
// m23-ee-2b: `?? []` + `[].every(f) === true` made this ABSENCE assertion pass
// whenever `edit.history` carried no `undo` field at all. Pinned on the response
// (the reply must carry the list it is read for) and on the journal being
// non-empty — `project.new` + `track.add` above are undoable, so an empty journal
// means the read failed, not that zooming behaved.
// ⚠️ AND IT HAD NO DETAIL ARGUMENT: this leg was RED in the tree with no way to
// see WHY. A failing assertion that prints nothing is its own defect.
const undoLabels = r.result?.undo ?? [];
ck("still no zoom entries in undo",
   Array.isArray(r.result?.undo) && undoLabels.length >= 1
     && undoLabels.every(l => !/zoom|ppb|row/i.test(l)),
   JSON.stringify({ undo: undoLabels, redo: r.result?.redo ?? null }));
r = await cmd("project.snapshot");
ck("no zoom keys in snapshot", !JSON.stringify(r.result).match(/arrangePPB|pixelsPerBeat|rowStep/), "");
r = await cmd("project.new");
ck("normalized non-dirty for kill", r.ok, r.error);

console.log(`ORCH_ZOOM_GATE2 pass=${pass} fail=${fail}`);
ws.close();
stopStaging(GATE);
verdict({ ran: pass + fail, failed: fail });
