// m17-d orchestrator gate — space-bar transport (play from seeked beat, double-toggle, modifier/repeat/noWindow
// pass-throughs, posted spaces type into a focused rename field with transport untouched, record-stop leg).
// GATE LAW: clear text focus via debug.markerRename{clear:true} (or, failing
// that, project.new), never staged clicks — debug.arrangePointer runs
// SwiftUI's gesture handlers directly and never produces an NSEvent, so it
// never touches AppKit's responder chain and cannot resign a field editor by
// construction (DAWProApp.swift ~633-637, "not injectable on the unbundled
// staging binary"). markerRename{clear:true} nils stagedMarkerRenameID, which
// flips the marker flag's `isRenaming` off and removes the TextField (and its
// @FocusState binding) from the view hierarchy entirely — SwiftUI resigns the
// field editor as part of that removal, same as project.new's full view-tree
// replacement does (project.new also works, just needlessly discards the
// project). MEASURED readback via debug.keySpace, live 2026-08-05: while the
// field is up, firstResponder:"text-editing" / responderClass:
// "_SystemTextFieldFieldEditor"; after markerRename{clear:true} + settle,
// firstResponder:"none" / responderClass:"AppKitWindow" — the window itself,
// not a SwiftUI-internal flag, so this is a real AppKit-level resignation
// (m23-ba). Staging: DAW_CONTROL_PORT=17695. Promoted from session scratchpad
// 2026-07-16 (m17-g).
// m17-d orchestrator gate — DISJOINT: seeked play at beat 32, rapid double-toggle,
// option/shift chords, repeat flag, rename-field two-space typing, record-stop leg.
// m23-ac-3a: was "class 3" — it never launched anything and drove whatever was
// on 17695. It now builds and launches its own instance.
import { sleep, buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "m17d-key-space";
buildOrAbort({ label: "building staging binary (m17d)…" });
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

// clear focus the GATE LAW way: debug.markerRename{clear:true} nils the
// staged rename id, which removes the TextField (and its @FocusState binding)
// from the view entirely — never a staged pointer act (those don't resign
// the field editor; see the header note). Note this bypasses onCommitRename/
// onCancelRename (real Escape/Return paths), so the "  " draft typed above is
// discarded rather than committed/trimmed — harmless here since no later leg
// depends on the marker's name.
//
// ⭐ m23-ba-1 MEASURED that "discarded" claim rather than reasoning it (a
// SwiftUI teardown could plausibly have delivered the focus-loss .onChange,
// which COMMITS): it holds. Pinned by m23ba1-marker-rename-modes.mjs leg C, so
// if a future SwiftUI ever changes it, a gate turns red instead of this comment
// quietly becoming wrong. ⚠️ AND IF YOU NEED THE USER'S OWN FINISHING GESTURES,
// {clear:true} IS NOT THEM — use debug.markerRename {commit:true} (Return /
// click away; click-away COMMITS) or {cancel:true} (Escape).
r = await cmd("debug.markerRename", { clear: true });
ck("markerRename clear ok", r.ok, r.error ?? "");
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
stopStaging(GATE);
process.exit(fail ? 1 : 0);
