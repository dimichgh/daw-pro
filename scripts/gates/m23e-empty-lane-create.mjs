// m23-e GATE — empty-lane double-click creates a MIDI clip and opens the note
// editor on it, against a REAL app on staging (port 17695 only; 17600 is the
// user's LIVE app and is never touched. Staging is killed PIDFILE-EXACT).
//
// WHAT THIS PROVES AND WHAT IT DOES NOT
//   Proves: the HANDLER path. `debug.arrangePointer {act:"doubleClick"}` stages a
//   synthetic event through the SAME `handleDoubleClick` a real double-click
//   runs, and every assertion below reads the app's own state afterwards —
//   `project.overview` (the store's clips) and the seam echo's `editorClipId`
//   (the SAME `openEditorClip` the ContentView editor branch gates on, so a
//   non-null value means the roll is on screen for that clip).
//   Does NOT prove: SwiftUI's gesture ARBITRATION — that a real two-click
//   sequence on a surface whose single tap already seeks actually reaches
//   `handleDoubleClick`. Nothing headless can reach that (the m17-b measurement:
//   no Accessibility grant on the unbundled staging binary). The design is built
//   to be correct either way — the clip start and the seek both come from
//   `pointerBeat(forX:)` — but "the real click works" is a claim only a human
//   can close.
//
// FIXTURE ARITHMETIC, computed before any assertion was written (the m23-c2 law:
// assert the fixture, but COMPUTE it first or you re-derive it by trial):
//   ppb = 80, rowStep = large -> rowHeight 50, laneSpacing 6, `.lanes` content
//   so rulerInset = 0. Neither track has takes or automation expanded, so
//   extraHeight = 0 for both:
//     lane 0 (instrument) clip band = y in [0, 50)     -> probe y = 25
//     row gap                        = y in [50, 56)   -> probe y = 53
//     lane 1 (audio)      clip band = y in [56, 106)   -> probe y = 81
//     below the stack                = y > 106         -> probe y = 400
//   x = beat * 80. Every probe beat is an exact BAR (4/4) so the default bar
//   SNAP is a no-op and the asserted startBeat is unambiguous; the one leg that
//   deliberately tests the snap probes at beat 7.6 and expects 8.
//   The playhead stays at beat 0 throughout EXCEPT where a leg moves it on
//   purpose: the create must not inherit the pointer classifier's
//   playhead-grab precedence, and the only way to show that is to seek the
//   playhead ONTO the probe x and create there anyway.
//
//   M23E_PIDFILE=<scratch>/staging.pid node scripts/gates/m23e-empty-lane-create.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23e";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23E_OUT || "/tmp/m23e";
const PIDFILE = process.env.M23E_PIDFILE || "/tmp/m23e-staging.pid";
const BINARY = process.env.M23E_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23E_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const PPB = 80;
const ROW_H = 50;             // rowStep "large"
const LANE_SPACING = 6;
const Y_INST = 25;            // lane 0 clip band
const Y_GAP = ROW_H + 3;      // 53 — the 6 pt gap between rows
const Y_AUDIO = ROW_H + LANE_SPACING + ROW_H / 2;   // 81 — lane 1 clip band
const Y_BELOW = 400;
const SETTLE_MS = 350;        // the m17-b main-actor settle law (~250 ms floor)
const X = (beat) => beat * PPB;

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("x")); });
      let nextId = 1; const pending = new Map();
      ws.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
        if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        else e.resolve(m.result ?? m);
      };
      const req = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

// ── launch staging through the ONE home (m23-ac-2a) ───────────────────────
// `buildOrAbort` is the half this gate never had: before this it ran whatever
// was compiled last. `startStaging` keeps the pidfile-exact teardown of a
// previous run and refuses port 17600 in ONE place. Every M23E_* override is
// preserved — they let the gate be pointed at a bundle, which is deliberate.
buildOrAbort();
const { pid: stagingPid } = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY, pidfile: PIDFILE,
  outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${stagingPid} on :${PORT}`);
await sleep(3500);

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const near = (a, b, eps = 1e-6) => typeof a === "number" && Math.abs(a - b) < eps;

// Every assertion below reads the CAUSING call — the `act` response itself, not
// a follow-up. That was impossible before the m23-e seam fix: the response used
// to be built before SwiftUI's update landed, so the call that caused a change
// answered with the PREVIOUS call's state. A caller reading the causing response
// could therefore pass on a stale id from an earlier action, which is precisely
// the false pass this seam exists to prevent. `act` now waits (bounded) for the
// lanes to run the event before answering, so reading the causing call is both
// legal and the STRONGER assertion — a follow-up read cannot tell "this call did
// it" from "some earlier call did it".
async function dblClick(x, y) {
  const t0 = Date.now();
  const causing = await req("debug.arrangePointer", { act: "doubleClick", x, y });
  causing.__ms = Date.now() - t0;
  return causing;
}
async function hover(x, y) {
  return await req("debug.arrangePointer", { act: "hover", x, y });
}
async function pointer() { return await req("debug.arrangePointer", {}); }
const overview = async () => await req("project.overview", {});
const clipsOf = (ov, trackId) => (ov.tracks.find((t) => t.id === trackId)?.clips) ?? [];
const totalClips = (ov) => ov.tracks.reduce((n, t) => n + t.clips.length, 0);

try {
  // ── fixture ───────────────────────────────────────────────────────────
  await req("project.new", { discardChanges: true });
  const inst = await req("track.add", { kind: "instrument", name: "NoteTrk" });
  const instId = (inst.track ?? inst).id;
  const audio = await req("track.add", { kind: "audio", name: "AudioTrk" });
  const audioId = (audio.track ?? audio).id;
  await req("debug.arrangeZoom", { reset: true });
  const zoom = await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  // SIMPLE density for legs 1-8: this is the beginner's path, and the density is
  // set explicitly rather than inherited so a persisted preference from an
  // earlier run cannot decide what this gate measures.
  await req("debug.panelDensity", { panel: "arrange", mode: "simple" });
  await sleep(SETTLE_MS);

  // PRECONDITIONS — without these the whole gate can pass vacuously.
  check("fixture: two tracks, zero clips (the create has somewhere to go)",
        (await overview()).tracks.length === 2 && totalClips(await overview()) === 0,
        `tracks=${(await overview()).tracks.length} clips=${totalClips(await overview())}`);
  check(`fixture: ppb is the ${PPB} the probe arithmetic assumes`,
        near(zoom.ppb, PPB), `ppb=${zoom.ppb}`);
  const layout = await req("debug.panelLayout", {});
  check(`fixture: rowHeight is the ${ROW_H} the lane-band arithmetic assumes`,
        near(layout.rowHeight, ROW_H), `rowHeight=${layout.rowHeight}`);
  const pre = await pointer();
  check("fixture: no editor open before the double-click",
        pre.editorClipId === null && pre.createdClipId === null,
        `editorClipId=${pre.editorClipId} createdClipId=${pre.createdClipId}`);

  // ── 1. instrument lane: create at the double-clicked beat ─────────────
  // Probe beat 12 (bar 4 of 4/4) -> x = 960. Expect start 12, length 4 (one bar,
  // nothing to the right to clamp against).
  let e = await dblClick(X(12), Y_INST);
  const created = e.createdClipId;
  check("create: a clip was created", typeof created === "string" && created.length > 0,
        `createdClipId=${created}`);
  let ov = await overview();
  let clips = clipsOf(ov, instId);
  const c1 = clips.find((c) => c.id === created);
  check("create: it is on the INSTRUMENT lane and is the only clip in the project",
        !!c1 && totalClips(ov) === 1, `instClips=${clips.length} total=${totalClips(ov)}`);
  check("create: startBeat is the DOUBLE-CLICKED beat, not 0",
        near(c1?.startBeat, 12), `startBeat=${c1?.startBeat} expected=12 (x=${X(12)} / ppb ${PPB})`);
  check("create: length is one BAR of the meter (4/4 -> 4), not a hardcoded default",
        near(c1?.lengthBeats, 4), `lengthBeats=${c1?.lengthBeats}`);
  check("create: it is an EMPTY MIDI clip (a writable grid, not a seeded one)",
        c1?.kind === "midi" && c1?.noteCount === 0,
        `kind=${c1?.kind} noteCount=${c1?.noteCount}`);
  check("create: the EDITOR opened on THAT clip (not merely 'an editor is open')",
        e.editorClipId === created && e.selectedClipId === created,
        `editorClipId=${e.editorClipId} selectedClipId=${e.selectedClipId} created=${created}`);
  check("create: no refusal was raised", e.refusal === null, `refusal=${JSON.stringify(e.refusal)}`);

  // ── 2. the beat tracks the LIVE zoom, not a constant ──────────────────
  const zoom2 = await req("debug.arrangeZoom", { ppb: 40 });
  await sleep(SETTLE_MS);
  e = await dblClick(20 * 40, Y_INST);       // beat 20 at ppb 40
  const created2 = e.createdClipId;
  ov = await overview();
  const c2 = clipsOf(ov, instId).find((c) => c.id === created2);
  check(`zoom: at ppb ${zoom2.ppb} an x of 800 is beat 20, and the clip lands there`,
        near(c2?.startBeat, 20), `startBeat=${c2?.startBeat} expected=20 ppb=${zoom2.ppb}`);
  check("zoom: the editor followed to the new clip", e.editorClipId === created2,
        `editorClipId=${e.editorClipId} created=${created2}`);
  await req("debug.arrangeZoom", { ppb: PPB });
  await sleep(SETTLE_MS);

  // ── 3. UNDO removes the clip in ONE step and the track survives ───────
  const beforeUndo = await overview();
  await req("edit.undo", {});
  await sleep(SETTLE_MS);
  ov = await overview();
  check("undo: ONE step removed the clip it created",
        totalClips(ov) === totalClips(beforeUndo) - 1
        && !clipsOf(ov, instId).some((c) => c.id === created2),
        `clips ${totalClips(beforeUndo)} -> ${totalClips(ov)}`);
  check("undo: the TRACK survived (only the clip was undone)",
        ov.tracks.length === 2 && ov.tracks.some((t) => t.id === instId),
        `tracks=${ov.tracks.length}`);
  e = await pointer();
  check("undo: the editor closed with the clip it was open on (no stale id)",
        e.editorClipId === null, `editorClipId=${e.editorClipId} selectedClipId=${e.selectedClipId}`);

  // ── 4. AUDIO lane refuses HONESTLY and creates nothing ────────────────
  const beforeRefusal = await overview();
  e = await dblClick(X(12), Y_AUDIO);
  ov = await overview();
  check("refusal: the store's message surfaced VERBATIM",
        typeof e.refusal === "string"
        && e.refusal.includes("cannot hold MIDI clips")
        && e.refusal.includes("only instrument tracks accept MIDI clips"),
        `refusal=${JSON.stringify(e.refusal)}`);
  check("refusal: it is anchored on the AUDIO lane that refused",
        e.refusalTrackId === audioId, `refusalTrackId=${e.refusalTrackId} audio=${audioId}`);
  check("refusal: NOTHING was created", e.createdClipId === null
        && totalClips(ov) === totalClips(beforeRefusal) && clipsOf(ov, audioId).length === 0,
        `createdClipId=${e.createdClipId} total ${totalClips(beforeRefusal)} -> ${totalClips(ov)}`);
  check("refusal: no editor was opened", e.editorClipId === null,
        `editorClipId=${e.editorClipId}`);
  // The same refusal the WIRE returns for the same call — proving the UI copy is
  // not a second, drifting string.
  let wireRefusal = null;
  try { await req("clip.addMIDI", { trackId: audioId, atBeat: 12, lengthBeats: 4 }); }
  catch (err) { wireRefusal = String(err.message); }
  check("refusal: identical to what `clip.addMIDI` returns over the wire",
        wireRefusal !== null && wireRefusal.includes(e.refusal),
        `wire=${wireRefusal}`);

  // ── 5. the create does NOT inherit the playhead-grab precedence ───────
  // Empty lane space within 4 pt of the playhead classifies `.playheadGrab`. A
  // real double-click whose first tap also seeks moves the playhead ONTO the
  // pointer — so the create must work at exactly the playhead's x, or it would
  // die in the field while passing every staged test.
  await req("transport.seek", { beats: 4 });
  await sleep(SETTLE_MS);
  const z = await hover(X(4), Y_INST);
  check("playhead: the probe x really IS classified playhead-grab (fixture check — "
        + "without this the next leg proves nothing)",
        z.zone === "playhead-grab", `zone=${z.zone} playheadBeat=${z.playheadBeat}`);
  const beforePH = await overview();
  e = await dblClick(X(4), Y_INST);
  ov = await overview();
  const cPH = clipsOf(ov, instId).find((c) => c.id === e.createdClipId);
  check("playhead: a clip is STILL created on the playhead's own x",
        !!cPH && near(cPH.startBeat, 4) && totalClips(ov) === totalClips(beforePH) + 1,
        `createdClipId=${e.createdClipId} startBeat=${cPH?.startBeat}`);
  await req("edit.undo", {});
  await sleep(SETTLE_MS);
  await req("transport.seek", { beats: 0 });
  await sleep(SETTLE_MS);

  // ── 6. the bar is CLAMPED to the gap before the next clip ─────────────
  // Resident at [6, 10). Double-click at beat 4 -> room = 6 - 4 = 2, so the
  // one-bar default (4) clamps to 2. Unclamped it would reach beat 8 and the
  // store's overlap resolution would TRIM the resident's notes away.
  await req("project.new", { discardChanges: true });
  const t2 = await req("track.add", { kind: "instrument", name: "ClampTrk" });
  const t2Id = (t2.track ?? t2).id;
  await req("clip.addMIDI", { trackId: t2Id, atBeat: 6, lengthBeats: 4, name: "Resident",
                              notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 96 }] });
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await sleep(SETTLE_MS);
  e = await dblClick(X(4), Y_INST);
  ov = await overview();
  const clamped = clipsOf(ov, t2Id).find((c) => c.id === e.createdClipId);
  const resident = clipsOf(ov, t2Id).find((c) => c.name === "Resident");
  check("clamp: the new clip stops where the next clip starts (length 2, not 4)",
        near(clamped?.startBeat, 4) && near(clamped?.lengthBeats, 2),
        `start=${clamped?.startBeat} length=${clamped?.lengthBeats}`);
  check("clamp: the resident was NOT trimmed and kept its note",
        near(resident?.startBeat, 6) && near(resident?.lengthBeats, 4) && resident?.noteCount === 1,
        `resident start=${resident?.startBeat} length=${resident?.lengthBeats} notes=${resident?.noteCount}`);

  // ── 7. a snap that lands INSIDE a resident creates nothing ────────────
  // Probe beat 7.6 -> bar snap -> 8, which is inside [6, 10). No room: nothing.
  const beforeInside = await overview();
  e = await dblClick(7.6 * PPB, Y_INST);
  ov = await overview();
  check("no-room: a snapped start inside a resident creates nothing",
        e.createdClipId === null && totalClips(ov) === totalClips(beforeInside),
        `createdClipId=${e.createdClipId} total ${totalClips(beforeInside)} -> ${totalClips(ov)}`);

  // ── 8. non-lane bands create nothing ──────────────────────────────────
  for (const [label, y] of [["row gap", Y_GAP], ["below the lane stack", Y_BELOW]]) {
    const before = await overview();
    e = await dblClick(X(20), y);
    ov = await overview();
    check(`geometry: a double-click in the ${label} (y=${y}) creates nothing`,
          e.createdClipId === null && totalClips(ov) === totalClips(before),
          `createdClipId=${e.createdClipId} total ${totalClips(before)} -> ${totalClips(ov)}`);
  }

  // ── 9. the SPLIT path over a clip still works (m17-c regression) ──────
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await sleep(SETTLE_MS);
  const beforeSplit = await overview();
  e = await dblClick(X(8), Y_INST);          // inside the resident [6, 10)
  ov = await overview();
  check("split: double-clicking a CLIP still splits it (Pro), and creates nothing new",
        totalClips(ov) === totalClips(beforeSplit) + 1 && e.createdClipId === null,
        `total ${totalClips(beforeSplit)} -> ${totalClips(ov)} createdClipId=${e.createdClipId}`);

  // ── 10. the create also works in PRO (legs 1-8 ran in Simple) ─────────
  // Both densities matter for different reasons: Simple is the beginner's path
  // the item exists for, Pro is where the split shares the same gesture.
  await req("project.new", { discardChanges: true });
  const t3 = await req("track.add", { kind: "instrument", name: "ProTrk" });
  const t3Id = (t3.track ?? t3).id;
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await sleep(SETTLE_MS);
  e = await dblClick(X(16), Y_INST);
  ov = await overview();
  const cPro = clipsOf(ov, t3Id).find((c) => c.id === e.createdClipId);
  check("pro: a fresh instrument track reaches a writable grid in PRO density too",
        !!cPro && near(cPro.startBeat, 16) && e.editorClipId === e.createdClipId,
        `start=${cPro?.startBeat} editorClipId=${e.editorClipId} created=${e.createdClipId}`);

  // ── 11. meter-aware length: a 7/8 section yields a 7-beat clip ────────
  await req("tempo.setMap", {
    segments: [{ startBeat: 0, bpm: 120 }],
    meterChanges: [{ startBeat: 0, beatsPerBar: 7, beatUnit: 8 }],
  });
  await sleep(SETTLE_MS);
  e = await dblClick(X(28), Y_INST);          // 28 = bar 4 in 7/8
  ov = await overview();
  const c78 = clipsOf(ov, t3Id).find((c) => c.id === e.createdClipId);
  check("meter: in 7/8 the created clip is 7 beats, not 4",
        near(c78?.lengthBeats, 7) && near(c78?.startBeat, 28),
        `start=${c78?.startBeat} length=${c78?.lengthBeats}`);

  // ── 12. the echo reports the call that CAUSED it (seam lag fix) ───────
  // Before the fix these two disagreed by exactly one call: the causing
  // `doubleClick` answered null/null/null and the NEXT call carried the result.
  await req("project.new", { discardChanges: true });
  const t4 = await req("track.add", { kind: "instrument", name: "LagTrk" });
  const t4Id = (t4.track ?? t4).id;
  const t4a = await req("track.add", { kind: "audio", name: "LagAudio" });
  const t4aId = (t4a.track ?? t4a).id;
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await sleep(SETTLE_MS);
  const causing = await dblClick(X(12), Y_INST);
  await sleep(SETTLE_MS);
  const followUp = await pointer();
  check("lag: the CAUSING doubleClick response already carries the created clip",
        typeof causing.createdClipId === "string" && causing.editorClipId === causing.createdClipId,
        `causing createdClipId=${causing.createdClipId} editorClipId=${causing.editorClipId} (${causing.__ms} ms)`);
  check("lag: causing and follow-up now AGREE (no one-call lag)",
        causing.createdClipId === followUp.createdClipId
        && causing.editorClipId === followUp.editorClipId
        && causing.selectedClipId === followUp.selectedClipId,
        `causing=${causing.createdClipId} followUp=${followUp.createdClipId}`);
  // The refusal is the leg that could pass on a STALE id: a clip exists now, so
  // a lagging echo would answer this audio-lane call with the id just created.
  const causingRefusal = await dblClick(X(12), Y_AUDIO);
  check("lag: the CAUSING refusal response carries the refusal, and createdClipId "
        + "is null rather than the clip created two calls earlier",
        typeof causingRefusal.refusal === "string"
        && causingRefusal.refusal.includes("cannot hold MIDI clips")
        && causingRefusal.createdClipId === null
        && causingRefusal.refusalTrackId === t4aId,
        `refusal=${JSON.stringify(causingRefusal.refusal)?.slice(0, 40)}… createdClipId=`
        + `${causingRefusal.createdClipId} refusalTrackId=${causingRefusal.refusalTrackId}`);
  // `editorClipId` deliberately still names the clip open from the earlier
  // create: refusing a create on an audio lane must NOT close an editor you
  // already had open. `createdClipId` — cleared before every staged
  // double-click, set only by the view's own create callback — is the field
  // that answers "did THIS call create something", which is why the assertion
  // above is on that one.
  check("refusal does not close an editor that was already open",
        causingRefusal.editorClipId === causing.createdClipId,
        `editorClipId=${causingRefusal.editorClipId} stillOpen=${causing.createdClipId}`);

  // ── 13. zone and create resolve the SAME point to the SAME lane ───────
  // The open question: do `pointerZone` and the create path use different y
  // conventions? They do NOT — both consume the SAME `pointerLanes` array
  // (TimelineLanesView.swift:1125 and :1221), whose bands are
  // [laneTop(i), laneTop(i)+rowHeight) with laneTop starting at rulerInset.
  // Proven here from outside: at a fixed x well away from the playhead, hover's
  // zone and the create agree at every y INSIDE a clip band.
  await req("project.new", { discardChanges: true });
  const t5 = await req("track.add", { kind: "instrument", name: "SweepTrk" });
  const t5Id = (t5.track ?? t5).id;
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await req("transport.seek", { beats: 0 });
  await sleep(SETTLE_MS);
  const SWEEP_X = X(20);                 // 40 beats from the playhead: never grab
  const inBand = [0, 1, ROW_H / 2, ROW_H - 1];
  const outOfBand = [ROW_H, ROW_H + 3, ROW_H + LANE_SPACING - 1, 400];
  let sweepOK = true, sweepDetail = [];
  for (const y of inBand) {
    const h = await hover(SWEEP_X, y);
    const before = totalClips(await overview());
    const d = await dblClick(SWEEP_X, y);
    const after = totalClips(await overview());
    const madeOne = after === before + 1 && typeof d.createdClipId === "string";
    sweepDetail.push(`y=${y} zone=${h.zone} created=${madeOne}`);
    if (!(h.zone === "empty" && madeOne)) sweepOK = false;
    if (madeOne) await req("edit.undo", {});
    await sleep(120);
  }
  check("convention: INSIDE the clip band, hover's zone and the create agree at every y",
        sweepOK, sweepDetail.join(" | "));
  let outOK = true, outDetail = [];
  for (const y of outOfBand) {
    const h = await hover(SWEEP_X, y);
    const before = totalClips(await overview());
    const d = await dblClick(SWEEP_X, y);
    const after = totalClips(await overview());
    outDetail.push(`y=${y} zone=${h.zone} created=${d.createdClipId !== null}`);
    if (!(d.createdClipId === null && after === before)) outOK = false;
  }
  // The asymmetry outside a band is DELIBERATE, not a divergence: the row gap
  // and the free space below the lanes belong to no track, so they stay
  // ghost-able and seekable (zone "empty") while the create — which must name a
  // track — correctly declines. Documented here so a future gate does not read
  // it as a bug.
  check("convention: OUTSIDE any clip band the create declines, though the seek "
        + "surface deliberately stays wider (zone stays \"empty\")",
        outOK, outDetail.join(" | "));

  // The specific coordinates that produced the confusing reading: lane 1's
  // middle on a two-track fixture. With the lag fixed, the causing call reports
  // this point's OWN zone.
  await req("project.new", { discardChanges: true });
  await req("track.add", { kind: "instrument", name: "A" });
  await req("track.add", { kind: "audio", name: "B" });
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await sleep(SETTLE_MS);
  const h81 = await hover(X(12), Y_AUDIO);
  check(`convention: y=${Y_AUDIO} on an EMPTY audio lane reports zone "empty" (a `
        + `"clip" reading there was the one-call lag, not a lane mismatch)`,
        h81.zone === "empty", `zone=${h81.zone}`);

  // ── normalize ─────────────────────────────────────────────────────────
  await req("debug.arrangePointer", { act: "clear" });
  await req("debug.panelDensity", { panel: "arrange", mode: "simple" });
  await req("debug.arrangeZoom", { reset: true });
  await req("project.new", { discardChanges: true });
} catch (err) {
  check("gate ran to completion", false, String(err && err.stack ? err.stack : err));
}

const pass = checks.filter((c) => c.ok).length;
console.log(`\nM23E ${pass}/${checks.length}`);
fs.writeFileSync(`${OUT}/results.json`, JSON.stringify(checks, null, 2));
try { ws.close(); } catch {}
stopStaging(GATE, PIDFILE);   // m23-ac-2a: same pidfile-exact kill, one home
clearTimeout(killer);
process.exit(pass === checks.length ? 0 : 1);
