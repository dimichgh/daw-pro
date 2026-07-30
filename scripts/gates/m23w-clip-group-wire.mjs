// m23-w staging gate — clip.removeMany / clip.moveMany over the REAL control port.
//
// This is the "real exercise" half of the cycle: the Swift tests drive the router
// in-process, which cannot catch a verb that is registered but unreachable, a
// response the encoder drops, or a param the wire rejects before the store sees it.
//
// ⚠️ BUILD FIRST, then launch OUR OWN binary. A gate that drives whatever instance
// is already on the port has unknown provenance and its green is undetectable
// noise — that is the m23-ac class, and 24 gates in this tree still have it
// (re-measured at m23-ac; the "33" this comment used to claim was derived by a
// token search that miscounted in both directions).
// This one builds and launches, so what it tests is what the tree says.
//
// Staging 17695 ONLY. 17600 is the user's LIVE app and is never touched.
// Kill by EXACT pid from the pidfile — never pkill/pgrep.
// The build/launch/pidfile-kill lifecycle lives in ONE place (m23-ac-1) —
// `_staging.mjs`. It used to be copy-pasted into every gate that had it at all.
import { launchStaging, stopStaging, STAGING_PORT } from "./_staging.mjs";

const GATE = "m23w";
let ws, seq = 0, pass = 0, fail = 0;
const failures = [];
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = `w-${++seq}`;
    const timer = setTimeout(() => rej(new Error(`timeout ${command}`)), timeoutMs);
    const onMsg = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id !== id) return;
      clearTimeout(timer); ws.removeEventListener("message", onMsg); res(m);
    };
    ws.addEventListener("message", onMsg);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
function ck(label, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS ${label}`); }
  else { fail++; failures.push(label); console.log(`FAIL ${label} :: ${detail}`); }
}
const histLen = async () => (await cmd("edit.history")).result?.undo?.length ?? -1;

try {
  const staging = await launchStaging({ gate: GATE });
  ws = staging.ws;
  console.log(`connected to staging on ${STAGING_PORT} (pid ${staging.pid})`);

  // ---- W1: the verbs are actually REACHABLE on the wire ---------------------
  // A registered-but-unroutable verb is exactly what in-process tests miss.
  await cmd("project.new", { discardChanges: true });
  const t1 = (await cmd("track.add", { name: "W-A", kind: "instrument" })).result?.id;
  const t2 = (await cmd("track.add", { name: "W-B", kind: "instrument" })).result?.id;
  ck("W1 two instrument tracks created", !!t1 && !!t2, `${t1} ${t2}`);

  const mk = async (track, atBeat) =>
    (await cmd("clip.addMIDI", { trackId: track, atBeat, lengthBeats: 2 })).result?.id;

  // ---- W2: removeMany, 3 clips across 2 tracks = exactly ONE undo step ------
  const a = await mk(t1, 0), b = await mk(t1, 4), c = await mk(t2, 0);
  const beforeRemove = await histLen();
  const rm = await cmd("clip.removeMany", { ids: [a, b, c] });
  const afterRemove = await histLen();
  ck("W2 removeMany returned 3 clips", (rm.result?.length ?? rm.result?.clips?.length) === 3,
     JSON.stringify(rm).slice(0, 240));
  ck("W2 removeMany across 2 tracks = ONE undo step", afterRemove - beforeRemove === 1,
     `${beforeRemove} -> ${afterRemove}`);

  // ---- W3: all-or-nothing on an unknown id — NO partial mutation ------------
  await cmd("project.new", { discardChanges: true });
  const t3 = (await cmd("track.add", { name: "W-C", kind: "instrument" })).result?.id;
  const d = await mk(t3, 0), e = await mk(t3, 4);
  const histBefore = await histLen();
  const bogus = "11111111-2222-3333-4444-555555555555";
  const bad = await cmd("clip.removeMany", { ids: [d, bogus, e] });
  const overview = await cmd("project.overview");
  const clipCount = (overview.result?.tracks ?? [])
    .reduce((n, t) => n + (t.clips?.length ?? 0), 0);
  ck("W3 unknown id is refused", !!bad.error, JSON.stringify(bad).slice(0, 200));
  ck("W3 NO partial mutation — both clips survive", clipCount === 2, `clips=${clipCount}`);
  ck("W3 no undo step was pushed", (await histLen()) === histBefore, `hist ${histBefore}`);

  // ---- W4: moveMany surfaces the CLAMP, not a bare ok ----------------------
  // A group move can deliver LESS than asked; an agent that cannot see that
  // compounds the error on its next call. This is the roadmap's named case.
  await cmd("project.new", { discardChanges: true });
  const t4 = (await cmd("track.add", { name: "W-D", kind: "instrument" })).result?.id;
  const m1 = await mk(t4, 2), m2 = await mk(t4, 8), m3 = await mk(t4, 14);
  const mv = await cmd("clip.moveMany", { ids: [m1, m2, m3], byBeats: -8 });
  const r = mv.result ?? {};
  ck("W4 effectiveDeltaBeats == -2 (whole-group floor clamp)", r.effectiveDeltaBeats === -2,
     JSON.stringify(r).slice(0, 260));
  ck("W4 clamped == true is REPORTED", r.clamped === true, JSON.stringify(r).slice(0, 200));
  ck("W4 requestedDeltaBeats == -8 is preserved", r.requestedDeltaBeats === -8, `${r.requestedDeltaBeats}`);
  ck("W4 trimmedClipIDs present", Array.isArray(r.trimmedClipIDs), typeof r.trimmedClipIDs);
  ck("W4 removedClipIDs present", Array.isArray(r.removedClipIDs), typeof r.removedClipIDs);
  const starts = (r.clips ?? []).map((c) => c.startBeat).sort((x, y) => x - y);
  ck("W4 all three spacings intact (0,6,12)",
     JSON.stringify(starts) === JSON.stringify([0, 6, 12]), JSON.stringify(starts));

  // ---- W5: the clamp BOUNDARY the roadmap's case only samples the inside of -
  // Leftmost already at beat 0 with a negative delta => effective == 0: unchanged
  // clips, clamped TRUE, and NO edit performed.
  const histB4 = await histLen();
  const mv0 = await cmd("clip.moveMany", { ids: [m1, m2, m3], byBeats: -4 });
  const r0 = mv0.result ?? {};
  ck("W5 boundary: effectiveDeltaBeats == 0", r0.effectiveDeltaBeats === 0, JSON.stringify(r0).slice(0, 200));
  ck("W5 boundary: clamped == true", r0.clamped === true, `${r0.clamped}`);
  ck("W5 boundary: NO undo step pushed", (await histLen()) === histB4, `hist ${histB4}`);

  // ---- W6: empty ids mirrors the store — self-describing no-op, no undo step -
  const histE = await histLen();
  const emptyRm = await cmd("clip.removeMany", { ids: [] });
  const emptyMv = await cmd("clip.moveMany", { ids: [], byBeats: 4 });
  ck("W6 empty removeMany is not an error", !emptyRm.error, JSON.stringify(emptyRm).slice(0, 160));
  ck("W6 empty moveMany is not an error", !emptyMv.error, JSON.stringify(emptyMv).slice(0, 160));
  ck("W6 empty ids push NO phantom undo step", (await histLen()) === histE, `hist ${histE}`);

  // ---- W7: unknown key rejected AT THE WIRE --------------------------------
  const junk1 = await cmd("clip.removeMany", { ids: [], nope: 1 });
  const junk2 = await cmd("clip.moveMany", { ids: [], byBeats: 0, nope: 1 });
  ck("W7 removeMany rejects an unknown key", !!junk1.error, JSON.stringify(junk1).slice(0, 160));
  ck("W7 moveMany rejects an unknown key", !!junk2.error, JSON.stringify(junk2).slice(0, 160));

  // ---- W8: the group edit is ONE undo step that fully REVERSES -------------
  // "One step" is only worth having if undoing it restores everything.
  await cmd("project.new", { discardChanges: true });
  const t5 = (await cmd("track.add", { name: "W-E", kind: "instrument" })).result?.id;
  const u1 = await mk(t5, 0), u2 = await mk(t5, 4), u3 = await mk(t5, 8);
  await cmd("clip.removeMany", { ids: [u1, u2, u3] });
  const gone = await cmd("project.overview");
  const goneCount = (gone.result?.tracks ?? []).reduce((n, t) => n + (t.clips?.length ?? 0), 0);
  await cmd("edit.undo");
  const back = await cmd("project.overview");
  const backCount = (back.result?.tracks ?? []).reduce((n, t) => n + (t.clips?.length ?? 0), 0);
  ck("W8 removeMany emptied the track", goneCount === 0, `clips=${goneCount}`);
  ck("W8 ONE undo restores all three", backCount === 3, `clips=${backCount}`);

  // ---- W9: trimmedClipIDs/removedClipIDs carry VALUES, not just a shape ----
  // W4 only asserted these are arrays — and a handler that hardcoded `[]` would
  // pass that, because every fixture above moves onto EMPTY space. Drive a mover
  // ONTO a resident so the field has something real to carry. This is the field
  // the store computes correctly and only the wire encoding can silently drop.
  await cmd("project.new", { discardChanges: true });
  const t6 = (await cmd("track.add", { name: "W-F", kind: "instrument" })).result?.id;
  const mover = await mk(t6, 8);          // 2 beats long, lands exactly on…
  const resident = await mk(t6, 4);       // …this one when nudged -4.
  const onto = await cmd("clip.moveMany", { ids: [mover], byBeats: -4 });
  const rr = onto.result ?? {};
  const swallowed = [...(rr.removedClipIDs ?? []), ...(rr.trimmedClipIDs ?? [])];
  ck("W9 the covered resident is REPORTED by id, not silently dropped",
     swallowed.includes(resident), JSON.stringify(rr).slice(0, 300));
} catch (err) {
  fail++; failures.push(`harness: ${err.message}`);
  console.log(`FAIL harness :: ${err.message}`);
} finally {
  try { ws?.close(); } catch { /* already gone */ }
  stopStaging(GATE);
}

console.log(`\nM23W ${pass}/${pass + fail}`);
if (failures.length) console.log("failed legs:\n  " + failures.join("\n  "));
process.exit(fail === 0 ? 0 : 1);
