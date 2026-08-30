// m23-ct SMOKE — Musical Typing across the LIVE wire, on staging 17695.
//
// ⚠️ WHAT THIS CAN AND CANNOT SEE. It proves the seam is reachable and that the
// three instruments AGREE (the view's ledger, the store's held set, the sink's
// last request). It CANNOT see a keystroke or a pixel: `debug.musicalTyping`
// injects BELOW NSEvent for its {press}/{release} verbs only in the sense that it
// synthesizes an event and runs it through the SAME handler the monitor calls, so
// a broken monitor MASK would still pass here. That is what the m17-d space gate
// and the m23-cf delete gate cover, and they are run alongside this.
//
// Staging: DAW_CONTROL_PORT=17695. 17600 is the user's live app, never touched.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, verdict } from "./_staging.mjs";

const GATE = "m23ct-musical-typing-smoke";
buildOrAbort({ label: "building staging binary (m23-ct)…" });
startStaging({ gate: GATE });
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `mt${++n}`;
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
const ok = (c, label, detail = "") => {
  if (c) { pass++; console.log("PASS " + label); }
  else { fail++; console.log("FAIL " + label + (detail ? "  << " + detail : "")); }
};
const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
const body = r => (r.result ?? r.data ?? r);

try {
  await cmd("project.new", { name: "m23ct-smoke" });

  // An INSTRUMENT track, so the target can actually be `ready`.
  const t = body(await cmd("track.add", { name: "Keys", kind: "instrument" }));
  const trackID = (t.track ?? t)?.id;
  ok(!!trackID, "instrument track added", JSON.stringify(t).slice(0, 200));
  // ⚠️ THERE IS NO `track.select` ON THE WIRE. The active track is
  // `AppModel.explicitActiveTrackID`, written by a HEADER CLICK — so the seam a
  // gate uses is `debug.arrangeSelection {act:"clickTrack"}`, the same funnel the
  // mouse drives. (Measured here: without it, every note reports `no-track`.)
  const selected = body(await cmd("debug.arrangeSelection",
                                  { act: "clickTrack", trackId: trackID }));
  ok(!!selected, "track header clicked");

  // ── mode off by default, and a press while off does nothing ──────────────
  let s = body(await cmd("debug.musicalTyping", {}));
  ok(s.enabled === false, "mode is OFF by default", JSON.stringify(s).slice(0, 200));
  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  ok(s.decision === "pass-through:mode-off", "press while OFF passes through", s.decision);
  ok(same(s.sounding, []), "nothing sounds while OFF", JSON.stringify(s.sounding));

  // ── turn it on ───────────────────────────────────────────────────────────
  s = body(await cmd("debug.musicalTyping", { enable: true }));
  ok(s.enabled === true, "mode ON");
  ok(s.targetState === "ready", "target is ready on an instrument track", s.targetState);
  ok(s.baseOctave === 4 && s.velocity > 0, "defaults present",
     `octave=${s.baseOctave} vel=${s.velocity}`);

  // ── press A → middle C, and ALL THREE INSTRUMENTS AGREE ──────────────────
  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  ok(s.decision === "performed", "A performs", s.decision);
  ok(same(s.sounding, [60]), "view ledger holds 60", JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, [60]), "STORE holds 60", JSON.stringify(s.storeHeldPitches));
  ok(same(s.sinkRequestedPitches, [60]), "SINK asked for 60", JSON.stringify(s.sinkRequestedPitches));

  // ── a chord ──────────────────────────────────────────────────────────────
  await cmd("debug.musicalTyping", { press: "D" });
  s = body(await cmd("debug.musicalTyping", { press: "G" }));
  ok(same(s.sounding, [60, 64, 67]), "C major chord is polyphonic", JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, [60, 64, 67]), "store agrees on the chord",
     JSON.stringify(s.storeHeldPitches));

  // ── partial release leaves the rest ringing ──────────────────────────────
  s = body(await cmd("debug.musicalTyping", { release: "D" }));
  ok(same(s.sounding, [60, 67]), "releasing D leaves C and G", JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, [60, 67]), "store agrees after partial release",
     JSON.stringify(s.storeHeldPitches));

  // ── release all → silence everywhere ─────────────────────────────────────
  s = body(await cmd("debug.musicalTyping", { releaseAll: true }));
  ok(same(s.sounding, []), "releaseAll silences the view", JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, []), "releaseAll silences the STORE",
     JSON.stringify(s.storeHeldPitches));

  // ── the guards, live ─────────────────────────────────────────────────────
  s = body(await cmd("debug.musicalTyping", { press: "A", command: true }));
  ok(s.decision === "pass-through:chord", "⌘A is not a note", s.decision);
  ok(same(s.sounding, []), "⌘A sounded nothing", JSON.stringify(s.sounding));
  // ⚠️ THE LABEL HERE WAS MEASURED BEFORE IT WAS ASSERTED. The first run of this
  // smoke PRINTED it and got "performed" for a repeat that sounded nothing — the
  // seam was inferring the label from "did the monitor swallow it?", which cannot
  // separate a performed note from a swallowed repeat. The seam now carries the
  // predicate's real decision, and this pins it so the inference cannot come back.
  s = body(await cmd("debug.musicalTyping", { press: "A", repeat: true }));
  ok(s.decision === "swallowed-repeat", "a repeat reports as a repeat, not a note",
     s.decision);
  ok(same(s.sounding, []), "a key repeat re-struck nothing", JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, []), "a key repeat reached no store", JSON.stringify(s.storeHeldPitches));
  s = body(await cmd("debug.musicalTyping", { press: "A", noWindow: true }));
  ok(s.decision === "pass-through:secondary-window", "a secondary window passes through",
     s.decision);

  // ⛔ THE NON-NEGOTIABLE ONE: typing into a rename field inserts CHARACTERS.
  await cmd("marker.add", { beat: 16, name: "Chorus" });
  await cmd("debug.markerRename", {});   // the m17-d gate law: focus, then clear
  await sleep(300);
  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  ok(s.decision === "pass-through:text-editing",
     "⛔ a press into a focused rename field is NOT a note", s.decision);
  ok(same(s.sounding, []), "nothing sounded while text-editing", JSON.stringify(s.sounding));
  await cmd("debug.markerRename", { clear: true });
  await sleep(300);
  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  ok(s.decision === "performed", "and a note plays again once focus clears", s.decision);
  await cmd("debug.musicalTyping", { release: "A" });

  // ── octave / velocity ────────────────────────────────────────────────────
  s = body(await cmd("debug.musicalTyping", { press: "X" }));
  ok(s.baseOctave === 5, "X raises the octave", String(s.baseOctave));
  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  ok(same(s.sounding, [72]), "A now plays C5", JSON.stringify(s.sounding));
  await cmd("debug.musicalTyping", { release: "A" });
  await cmd("debug.musicalTyping", { press: "Z" });
  s = body(await cmd("debug.musicalTyping", { press: "C" }));
  ok(s.baseOctave === 4 && s.velocity < 100, "Z restores the octave, C softens",
     `octave=${s.baseOctave} vel=${s.velocity}`);

  // ── the ON-SCREEN keyboard, through the SAME shared entry point ───────────
  s = body(await cmd("debug.musicalTyping", { pointerPitch: 64 }));
  ok(same(s.sounding, [64]), "a mouse press sounds", JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, [64]), "the store heard the mouse",
     JSON.stringify(s.storeHeldPitches));
  s = body(await cmd("debug.musicalTyping", { pointerUp: true }));
  ok(same(s.sounding, []), "a mouse release silences", JSON.stringify(s.sounding));

  // ── ⭐ A REAL NSEvent THROUGH THE REAL MONITOR ────────────────────────────
  // ⛔ THE ONLY LEG THAT MEASURES THE JOIN. Every other check calls the
  // handlers directly, so a monitor installed with the WRONG MASK would pass
  // them all — and this item WIDENED that mask from [.keyDown] to
  // [.keyDown, .keyUp, .flagsChanged]. `post:true` hands the synthesized event
  // to AppKit, which must deliver it back through the local monitor for
  // anything to happen. A key-up in particular has never travelled that path
  // before this item existed. (m17-d's posted spaces are the precedent that
  // posting works at all on staging.)
  await cmd("debug.musicalTyping", { press: "A", post: true });
  await sleep(300);
  s = body(await cmd("debug.musicalTyping", {}));
  ok(same(s.sounding, [60]), "⭐ a POSTED key-down reached the live monitor",
     JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, [60]), "…and carried all the way to the store",
     JSON.stringify(s.storeHeldPitches));
  await cmd("debug.musicalTyping", { release: "A", post: true });
  await sleep(300);
  s = body(await cmd("debug.musicalTyping", {}));
  ok(same(s.sounding, []), "⭐ a POSTED key-UP reached the widened monitor mask",
     JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, []), "…and the store went silent",
     JSON.stringify(s.storeHeldPitches));

  // ═══════════════════════════════════════════════════════════════════════
  // ⭐⭐ THE JOIN: TYPING INTO A TAKE, READ BACK OUT OF THE CLIP
  //
  // `m23ct-typed-take.mjs` proves `note.play` records. It does NOT touch
  // `debug.musicalTyping`, so nothing else in this tree proves the path a HUMAN
  // takes — keystroke → monitor → predicate → controller → sink → store → take.
  // This is that path, and it reads the answer out of the CLIP rather than out
  // of any return value.
  // ═══════════════════════════════════════════════════════════════════════
  await cmd("debug.musicalTyping", { releaseAll: true });
  await cmd("debug.musicalTyping", { enable: false });
  await cmd("project.new", { discardChanges: true, name: "m23ct-smoke-take" });

  const armed = body(await cmd("track.add", { name: "Typed ARMED", kind: "instrument" }));
  const armedID = (armed.track ?? armed)?.id;
  const idle = body(await cmd("track.add", { name: "Typed IDLE", kind: "instrument" }));
  const idleID = (idle.track ?? idle)?.id;
  ok(!!armedID && !!idleID, "two instrument tracks for the two arms");

  async function notesOn(trackID) {
    const snap = body(await cmd("project.snapshot"));
    const track = (snap.tracks ?? []).find(t => t.id === trackID);
    const out = [];
    for (const clip of track?.clips ?? []) {
      const got = body(await cmd("clip.getNotes", { clipId: clip.id }));
      for (const n of got.notes ?? []) out.push(n.pitch);
    }
    return out.sort((a, b) => a - b);
  }

  // ── ARM 1: ARMED. Typing must SOUND and be KEPT. ──────────────────────────
  await cmd("track.setArm", { trackId: armedID, armed: true });
  await cmd("debug.arrangeSelection", { act: "clickTrack", trackId: armedID });
  await cmd("debug.musicalTyping", { enable: true });
  // ⚠️ EXPLICIT COUNT-IN 0, not inherited (m23-cy). The project default is now
  // ONE bar = 2.0 s at 120 BPM, four times the 500 ms wait below, so every
  // typed note would land pre-anchor and this smoke would report the typing
  // seam broken when it is not.
  await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
  await cmd("transport.record", {});
  // ⚠️ 500 ms BEFORE THE FIRST NOTE, AND IT IS NOT PADDING. A take's
  // PlaybackAnchor is scheduled slightly ahead of startTake and every
  // PRE-ANCHOR note-on is DISCARDED by design (the rule that makes count-in
  // work) — measured at up to ~300 ms by the engine lane. Without this wait the
  // first note vanishes and the gate fails for a reason that has nothing to do
  // with the seam. It is also the exact defect flagged for a human.
  await sleep(500);

  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  ok(s.targetState === "recording-armed", "⭐ the app predicts a captured take",
     s.targetState);
  ok(s.sinkIsRecording === true, "⭐⭐ the ENGINE confirms the take is keeping it",
     JSON.stringify(s.sinkIsRecording));
  ok(s.targetIsCapturing === true, "…and the honesty light is lit");
  ok(s.sinkCapturedEdges > 0, "the press contributed note edges to the take",
     JSON.stringify(s.sinkCapturedEdges));
  const edgesAfterPress = s.sinkCapturedEdges;
  // ⚠️ MEASURED CORRECTION. I first asserted `sinkCapturedEdges === 0` here and
  // it returned 1 — CORRECTLY. An auto-repeat is swallowed by the predicate and
  // NEVER REACHES THE SINK, so the field still holds the previous call's answer;
  // it is documented as "edges the LAST CALL put into the take", not "edges
  // since you last asked". The honest claim is that the sink was not called at
  // all, which is what these two assert. ⭐ The real heartbeat property — an
  // UNCHANGED set contributing zero edges — is proven two ways instead: in
  // `recordingIsCapturedNotRefused` (which pushes the same set twice through the
  // sink directly) and by the note COUNT read out of the clip below, which a
  // re-recording heartbeat would inflate.
  await sleep(600);
  s = body(await cmd("debug.musicalTyping", { press: "A", repeat: true }));
  ok(s.decision === "swallowed-repeat", "an auto-repeat is swallowed mid-take too",
     s.decision);
  ok(s.sinkCapturedEdges === edgesAfterPress,
     "a swallowed repeat reached the sink — it should not have",
     JSON.stringify([edgesAfterPress, s.sinkCapturedEdges]));
  await cmd("debug.musicalTyping", { release: "A" });
  await sleep(400);
  s = body(await cmd("debug.musicalTyping", { press: "D" }));   // E4 = 64
  await sleep(600);
  await cmd("debug.musicalTyping", { release: "D" });
  await sleep(300);
  await cmd("transport.stop", {});
  await sleep(600);

  const captured = await notesOn(armedID);
  ok(captured.includes(60) && captured.includes(64),
     "⭐⭐ WHAT WAS TYPED IS IN THE CLIP — the whole feature, end to end",
     JSON.stringify(captured));
  // ⭐⭐ AND EXACTLY TWO NOTES — THIS IS THE LIVE HEARTBEAT PROOF. The first note
  // was held across roughly 1.1 s, i.e. two 500 ms liveness re-assertions. An
  // edge-shaped crossing would have written a fresh note on each pass, so a
  // count of 2 is the set-shaped crossing working against a real capture
  // session; anything above 2 is the failure the seam's shape prevents.
  ok(captured.length === 2, "exactly two notes landed — no heartbeat duplicates",
     JSON.stringify(captured));

  // ── ARM 2: NOT ARMED. Must SOUND, must be FLAGGED, must keep NOTHING. ─────
  // The mandatory negative control: without it an always-recording result would
  // read as a pass, and the footgun the indicator exists to name would be
  // invisible to this gate.
  await cmd("debug.arrangeSelection", { act: "clickTrack", trackId: idleID });
  await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });  // m23-cy, see arm 1
  await cmd("transport.record", {});
  await sleep(500);
  s = body(await cmd("debug.musicalTyping", { press: "G" }));   // G4 = 67
  ok(s.targetState === "recording-unarmed",
     "⛔ the un-armed take is named, not silently normal", s.targetState);
  ok(same(s.sounding, [67]), "⛔ and it still SOUNDS — this is a status, not a refusal",
     JSON.stringify(s.sounding));
  ok(s.sinkIsRecording === false, "the engine says it is keeping nothing",
     JSON.stringify(s.sinkIsRecording));
  ok(s.targetIsCapturing === false, "the honesty light stays dark");
  await sleep(600);
  await cmd("debug.musicalTyping", { release: "G" });
  await cmd("transport.stop", {});
  await sleep(600);
  const lost = await notesOn(idleID);
  ok(lost.length === 0, "⛔ nothing was captured on the un-armed track",
     JSON.stringify(lost));

  // ── turning the mode OFF must strand nothing ─────────────────────────────
  await cmd("debug.musicalTyping", { press: "A" });
  await cmd("debug.musicalTyping", { press: "D" });
  s = body(await cmd("debug.musicalTyping", { enable: false }));
  ok(s.enabled === false, "mode OFF");
  ok(same(s.sounding, []), "⛔ toggling OFF mid-hold leaves NO stuck note",
     JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, []), "⛔ and the STORE is silent too",
     JSON.stringify(s.storeHeldPitches));

  console.log(`M23CT_MT_SMOKE pass=${pass} fail=${fail} total=${pass + fail}`);
} finally {
  try { ws.close(); } catch {}
  stopStaging(GATE);
}
verdict({ ran: pass + fail, failed: fail });
