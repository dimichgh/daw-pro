// m23-g1 GATE — arrange multi-select (shift/⌘ click) + group DELETE as ONE undo
// step, against a REAL app on staging (port 17695 ONLY; 17600 is the user's LIVE
// app and is never touched. Staging is killed PIDFILE-EXACT, never pkill/pgrep).
//
// WHAT THIS PROVES AND WHAT IT DOES NOT
//   Proves: the SELECTION MODEL and the ATOMICITY, end to end against the app's
//   own state. `debug.arrangeSelection {act:"click"}` runs the SAME
//   `AppModel.clickClip` the ClipBlock tap runs, with EXPLICIT modifiers; undo
//   depth is read from `edit.history` (labels, newest-first), never inferred;
//   clip existence is read from `project.overview`, never from the seam's echo.
//   Does NOT prove: that `NSEvent.modifierFlags` reports the chord correctly at
//   the instant a real SwiftUI tap ends (a synthesized tap carries no chord —
//   see `ArrangeClickModifiers.current`), nor, unless leg K1 reports
//   delivered:true, that macOS routes a real DELETE key press to the handler.
//   Leg K1 attempts the stronger proof and reports its outcome honestly either
//   way; leg K2 proves the GUARD regardless of delivery.
//
// FIXTURE ARITHMETIC, computed before any assertion was written (FIXTURE LAW —
// a fixture must be derived from values the gate controls, never discovered by
// trial and error):
//   window 1400x1000 logical, capture scale 2  -> 2800x2000 capture pixels
//   ppb 40 pt/beat, rowStep "large" -> rowHeight 50 pt, laneSpacing 6 pt
//   => lane pitch      = (50 + 6) * 2 = 112 px
//      lane band height=  50      * 2 = 100 px
//      clip width      = lengthBeats * ppb * 2 = 4 * 40 * 2 = 320 px
//   The lanes' content ORIGIN in window pixels is not a number this gate is
//   allowed to assume, so it is DERIVED from the capture by a column/row scan
//   and then CROSS-CHECKED against all three numbers above. If the layout ever
//   moves, the derivation fails loudly instead of silently cropping empty panel
//   (the m23-b false-negative class: crop to the surface before measuring).
//
// Setup: none — run it.
//
//   node scripts/gates/m23g1-arrange-multiselect.mjs
//
// (m23-ac-2a) This line used to read `swift build && node …`. It was deleted
// because a usage comment is not a build step, and the original m23-ac filing
// read exactly this comment — in this file and in m23g2/m23g3 — as evidence the
// gate built first, scoring three gates SAFE that were not. The build is now
// performed by `buildOrAbort()` below, where it cannot be misread.
//
// The pixel probe is compiled ON DEMAND into `.build/` (below). It used to be a
// hand-built `/tmp` binary named only in this comment, which meant a re-run on a
// machine whose /tmp had been swept died with a bare ENOENT inside the first
// measurement leg — a gate that cannot be re-run by the person verifying it is
// not a gate. Env overrides (M23G1_PROBE/OUT/PIDFILE/BINARY/REPO) still work.
import fs from "fs";
import path from "path";
import { execFileSync } from "child_process";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23g1";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23G1_OUT || "/tmp/m23g1";
const PIDFILE = process.env.M23G1_PIDFILE || "/tmp/m23g1-staging.pid";
const BINARY = process.env.M23G1_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23G1_REPO || process.cwd();
const PROBE = process.env.M23G1_PROBE || path.join(REPO, ".build", "m23g1-probe");
fs.mkdirSync(OUT, { recursive: true });

// Compile the pixel probe if it is missing or older than its source. Cheap
// (~2 s, -O, one file) and it makes the gate self-contained.
const PROBE_SRC = path.join(REPO, "scripts", "probes", "m23g1-clip-box-probe.swift");
const probeStale = !fs.existsSync(PROBE)
  || fs.statSync(PROBE).mtimeMs < fs.statSync(PROBE_SRC).mtimeMs;
if (probeStale) {
  console.log(`compiling pixel probe -> ${PROBE}`);
  execFileSync("swiftc", ["-O", "-o", PROBE, PROBE_SRC], { stdio: "inherit" });
}
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── the numbers the fixture is built from (everything else is derived) ──────
const SCALE = 2;
const PPB = 40;
const ROW_H = 50;
const LANE_SPACING = 6;
const CLIP_BEATS = 4;
const CLIP_START_BEAT = 2;
const WIN_W = 1400, WIN_H = 1000;
const LANE_PITCH_PX = (ROW_H + LANE_SPACING) * SCALE;   // 112
const LANE_BAND_PX = ROW_H * SCALE;                     // 100
const CLIP_W_PX = CLIP_BEATS * PPB * SCALE;             // 320
const SETTLE_MS = 350;
// Crop inset: keep every measurement strictly INSIDE the block so a neighbouring
// lane's glow can never leak into a box and manufacture a difference.
const INSET = 8;

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

// ── launch staging through the ONE home (m23-ac-2a) ─────────────────────────
// `buildOrAbort` is the half this gate never had: before this it ran whatever
// was compiled last. `startStaging` keeps the pidfile-exact teardown of a
// previous run and refuses port 17600 in ONE place. Every M23G1_* override is
// preserved — they let the gate be pointed at a bundle, which is deliberate.
buildOrAbort();
const { pid: stagingPid } = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY, pidfile: PIDFILE,
  outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${stagingPid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
// A MEASUREMENT, not an assertion. Kept OUT of `checks` on purpose: a
// `check(name, true, …)` can never fail, so counting one inflates the pass
// tally with a leg that proves nothing. These print and are summarised
// separately, and the headline count stays "assertions that could have failed".
const notes = [];
const note = (name, detail) => {
  notes.push({ name, detail });
  console.log(`  ..  ${name}\n        ${detail}`);
};
const near = (a, b, eps = 1e-6) => typeof a === "number" && Math.abs(a - b) < eps;

const sel = (p = {}) => req("debug.arrangeSelection", p);
const history = () => req("edit.history", {});
const overview = () => req("project.overview", {});
const totalClips = (ov) => ov.tracks.reduce((n, t) => n + t.clips.length, 0);
const clipsOf = (ov, trackId) => ov.tracks.find((t) => t.id === trackId)?.clips ?? [];

// ── pixel helpers ───────────────────────────────────────────────────────────
function profile(kind, png, x, w, y, h) {
  const raw = execFileSync(PROBE, [kind, png, String(x), String(w), String(y), String(h)]).toString();
  return raw.trim().split("\n").map((l) => l.split(" ").map(Number));
}
/** Contiguous runs whose value exceeds the profile's own median by `delta`. */
function runs(prof, delta, minLen) {
  const sorted = prof.map((p) => p[1]).slice().sort((a, b) => a - b);
  const median = sorted[Math.floor(sorted.length / 2)];
  const out = [];
  for (const [i, v] of prof) {
    if (v >= median + delta) {
      const last = out[out.length - 1];
      if (last && i === last[1] + 1) last[1] = i; else out.push([i, i]);
    }
  }
  return out.filter((r) => r[1] - r[0] + 1 >= minLen);
}
function boxes(png, specs) {
  const args = ["boxes", png, OUT, ...specs.map((s) => `${s.label}:${s.x},${s.y},${s.w},${s.h}`)];
  const raw = execFileSync(PROBE, args).toString().trim().split("\n");
  const out = {};
  for (const line of raw) {
    const [label, ...rest] = line.split(" ");
    const kv = Object.fromEntries(rest.map((t) => t.split("=")));
    out[label] = { dims: kv.dims, luma: Number(kv.luma), sha: kv.sha };
  }
  // HARD dimension assertion — a silently-failed crop is the known false-negative
  // mode on this project, and it must never be able to pass a leg.
  for (const s of specs) {
    const got = out[s.label]?.dims;
    if (got !== `${s.w}x${s.h}`) throw new Error(`crop ${s.label}: dims ${got} != ${s.w}x${s.h}`);
  }
  return out;
}

let LANE_TOP = null, LANE_X = null;   // derived below, then cross-checked
const boxFor = (lane) => ({
  x: LANE_X + INSET,
  y: LANE_TOP + lane * LANE_PITCH_PX + INSET,
  w: CLIP_W_PX - 2 * INSET,
  h: LANE_BAND_PX - 2 * INSET,
});

try {
  // ══ FIXTURE ══════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: WIN_W, height: WIN_H });
  const tracks = [];
  for (const n of ["G1a", "G1b", "G1c"]) {
    tracks.push((await req("track.add", { kind: "instrument", name: n })).id);
  }
  await req("debug.arrangeZoom", { reset: true });
  const zoom = await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  const layout = await req("debug.panelLayout", {});
  // Echo-and-CHECK, never assume a parameter landed (a debug command silently
  // ignores keys it does not own — the m23-c2 corollary).
  check(`F1 fixture: ppb is the ${PPB} the box arithmetic assumes`,
        near(zoom.ppb, PPB), `ppb=${zoom.ppb}`);
  check(`F2 fixture: rowHeight is the ${ROW_H} the lane-pitch arithmetic assumes`,
        near(layout.rowHeight, ROW_H), `rowHeight=${layout.rowHeight}`);

  const clips = [];
  for (const t of tracks) {
    clips.push((await req("clip.addMIDI", {
      trackId: t, atBeat: CLIP_START_BEAT, lengthBeats: CLIP_BEATS })).id);
  }
  await req("transport.seek", { beats: 0 });
  await sleep(SETTLE_MS);

  let ov = await overview();
  check("F3 fixture: three MIDI clips, one per track, identical geometry",
        totalClips(ov) === 3 && ov.tracks.every((t) => t.clips.length === 1
          && near(t.clips[0].startBeat, CLIP_START_BEAT) && near(t.clips[0].lengthBeats, CLIP_BEATS)),
        ov.tracks.map((t) => `${t.name}:${t.clips.map((c) => c.startBeat + "+" + c.lengthBeats)}`).join(" "));

  const base = await sel({});
  check("F4 fixture: nothing is selected before the first click (non-vacuity)",
        base.count === 0 && base.focusClipId === null && base.editorClipId === null,
        JSON.stringify(base));

  // ══ DERIVE the lane geometry from the capture, then CROSS-CHECK it ════════
  const capBase = await req("debug.captureUI", { path: `${OUT}/A0-none.png` });
  check("F5 capture: the frame is the size the pixel arithmetic assumes",
        capBase.width === WIN_W * SCALE && capBase.height === WIN_H * SCALE,
        `${capBase.width}x${capBase.height}`);

  // Rows: scan a column window that is inside the clip in x for ALL lanes. We do
  // not know the lanes' x yet, so scan the widest window that cannot contain the
  // sidebar: the right half of the window.
  const rowProf = profile("rows", `${OUT}/A0-none.png`, WIN_W, WIN_W, 0, WIN_H * SCALE);
  const laneRuns = runs(rowProf, 3, LANE_BAND_PX - 12).filter((r) => r[1] - r[0] + 1 <= LANE_BAND_PX + 12);
  check("F6 derive: exactly three lane bands are visible in the capture",
        laneRuns.length === 3, laneRuns.map((r) => `${r[0]}-${r[1]}`).join(",") || "none");
  if (laneRuns.length !== 3) throw new Error("lane derivation failed — refusing to measure blind");
  LANE_TOP = laneRuns[0][0];
  const pitch1 = laneRuns[1][0] - laneRuns[0][0];
  const pitch2 = laneRuns[2][0] - laneRuns[1][0];
  check(`F7 derive: lane pitch matches (rowHeight+laneSpacing)*scale = ${LANE_PITCH_PX}`,
        Math.abs(pitch1 - LANE_PITCH_PX) <= 2 && Math.abs(pitch2 - LANE_PITCH_PX) <= 2,
        `pitch=${pitch1},${pitch2} laneTop=${LANE_TOP}`);

  // Columns: inside lane 0's band, the only bright run to the right of the
  // sidebar is the clip block itself; its WIDTH is the cross-check.
  const colProf = profile("cols", `${OUT}/A0-none.png`, 0, WIN_W * SCALE, LANE_TOP + 20, LANE_BAND_PX - 40);
  const colRuns = runs(colProf, 4, 40);
  const clipRun = colRuns.find((r) => Math.abs((r[1] - r[0] + 1) - CLIP_W_PX) <= 8);
  check(`F8 derive: a clip-width run (${CLIP_W_PX} px = ${CLIP_BEATS} beats x ppb x scale) exists in lane 0`,
        !!clipRun, colRuns.map((r) => `${r[0]}-${r[1]}(${r[1] - r[0] + 1})`).join(" "));
  if (!clipRun) throw new Error("clip-x derivation failed — refusing to measure blind");
  LANE_X = clipRun[0];
  // The content origin implied by the clip's x must agree with the beat it was
  // placed at — an independent consistency check on the whole derivation.
  const impliedOriginX = LANE_X - CLIP_START_BEAT * PPB * SCALE;
  check("F9 derive: the derived x is consistent with the clip's startBeat",
        impliedOriginX > 0 && impliedOriginX < WIN_W * SCALE,
        `clipX=${LANE_X} impliedContentOriginX=${impliedOriginX}`);

  // ══ VISUAL: unselected clips read ALIKE (the control pair) ════════════════
  const specs = [0, 1, 2].map((i) => ({ label: `A0-lane${i}`, ...boxFor(i) }));
  const b0 = boxes(`${OUT}/A0-none.png`, specs);
  const l0 = [0, 1, 2].map((i) => b0[`A0-lane${i}`].luma);
  const spread0 = Math.max(...l0) - Math.min(...l0);
  check("V1 control: with nothing selected, the three clip boxes read ALIKE",
        spread0 < 3, `lumas=${l0.map((v) => v.toFixed(2)).join(",")} spread=${spread0.toFixed(2)}`);

  // ══ SELECTION MODEL ══════════════════════════════════════════════════════
  let s = await sel({ act: "click", clipId: clips[0] });
  check("S1 plain click selects exactly one clip and focuses it",
        s.intent === "replace" && s.count === 1 && s.focusClipId === clips[0]
          && s.selectedClipId === clips[0],
        JSON.stringify(s));
  // THE m23-e REGRESSION GUARD: a single click still opens the note editor.
  check("R1 m23-e guard: a single click OPENS the note editor on that clip",
        s.editorClipId === clips[0],
        `editorClipId=${s.editorClipId} expected ${clips[0]}`);

  s = await sel({ act: "click", clipId: clips[1], shift: true });
  check("S2 shift-click ADDS without moving the focus",
        s.intent === "toggle" && s.count === 2 && s.focusClipId === clips[0]
          && s.selectedIds.includes(clips[1]),
        JSON.stringify(s));
  check("R2 m23-e guard: building a group leaves the editor on the focus clip",
        s.editorClipId === clips[0], `editorClipId=${s.editorClipId}`);

  s = await sel({ act: "click", clipId: clips[2], command: true });
  check("S3 ⌘-click ADDS a third clip (mixed-track selection)",
        s.count === 3 && clips.every((c) => s.selectedIds.includes(c)),
        JSON.stringify(s.selectedIds));

  s = await sel({ act: "click", clipId: clips[2], shift: true });
  check("S4 shift-click REMOVES an already-selected clip (the other direction)",
        s.count === 2 && !s.selectedIds.includes(clips[2]) && s.focusClipId === clips[0],
        JSON.stringify(s));

  s = await sel({ act: "click", clipId: clips[2], command: true });
  check("S5 ⌘-click re-adds it (toggle is symmetric, not a one-way latch)",
        s.count === 3 && s.selectedIds.includes(clips[2]), JSON.stringify(s.selectedIds));

  s = await sel({ act: "click", clipId: clips[0], command: true });
  check("S6 ⌘-clicking the FOCUS out drops focus and KEEPS the other two",
        s.count === 2 && s.focusClipId === null && !s.selectedIds.includes(clips[0]),
        JSON.stringify(s));
  check("R3 m23-e guard: losing the focus CLOSES the editor (it never jumps)",
        s.editorClipId === null, `editorClipId=${s.editorClipId}`);

  // Mirror coherence: `selectedClipId` (what ~19 pre-g1 call sites read) must
  // equal `focusClipId` in EVERY state, including this focus-less one.
  check("S7 mirror: selectedClipId always equals focusClipId",
        s.selectedClipId === s.focusClipId, `${s.selectedClipId} vs ${s.focusClipId}`);

  s = await sel({ act: "click", clipId: clips[1] });
  check("S8 a plain click COLLAPSES a group back to one clip",
        s.count === 1 && s.selectedIds[0] === clips[1] && s.focusClipId === clips[1],
        JSON.stringify(s));

  // ══ VISUAL: selected ≠ unselected, and a NON-FOCUS member is visibly selected
  await sel({ act: "click", clipId: clips[0] });
  await sel({ act: "click", clipId: clips[1], shift: true });
  await sleep(SETTLE_MS);
  const capSel = await req("debug.captureUI", { path: `${OUT}/A1-sel01.png` });
  check("V2 capture: the selected frame is the same size as the control frame",
        capSel.width === capBase.width && capSel.height === capBase.height,
        `${capSel.width}x${capSel.height}`);
  const b1 = boxes(`${OUT}/A1-sel01.png`, [0, 1, 2].map((i) => ({ label: `A1-lane${i}`, ...boxFor(i) })));
  const l1 = [0, 1, 2].map((i) => b1[`A1-lane${i}`].luma);
  check("V3 the FOCUS clip is visibly brighter than an unselected one",
        l1[0] - l1[2] > 3, `focus=${l1[0].toFixed(2)} unselected=${l1[2].toFixed(2)} d=${(l1[0] - l1[2]).toFixed(2)}`);
  // THE multi-select claim: clip 1 is selected but NOT the focus, and must still
  // read as selected. Without this leg, "selected looks different" could be
  // satisfied by the focus styling alone and multi-select would be invisible.
  check("V4 a SELECTED-BUT-NOT-FOCUSED clip is visibly brighter than an unselected one",
        l1[1] - l1[2] > 3, `member=${l1[1].toFixed(2)} unselected=${l1[2].toFixed(2)} d=${(l1[1] - l1[2]).toFixed(2)}`);
  check("V5 the unselected clip did NOT change between the two frames",
        Math.abs(l1[2] - l0[2]) < 2, `before=${l0[2].toFixed(2)} after=${l1[2].toFixed(2)}`);

  // ══ ATOMICITY ════════════════════════════════════════════════════════════
  await sel({ act: "clear" });
  for (const [i, c] of clips.entries()) {
    await sel({ act: "click", clipId: c, ...(i === 0 ? {} : { shift: true }) });
  }
  s = await sel({});
  check("A1 a 3-clip MIXED-TRACK selection is standing before the delete",
        s.count === 3, JSON.stringify(s.selectedIds));

  // BASELINE FIRST: building the fixture journals, so the stack does not start
  // empty and "+1" must be measured, not assumed.
  const h0 = await history();
  const depth0 = h0.undo.length;
  const d = await sel({ act: "delete" });
  const h1 = await history();
  check("A2 the group delete removed clips (the action happened at all)",
        d.deleted === true && d.count === 0, JSON.stringify(d));
  check("A3 ATOMICITY: the undo stack grew by EXACTLY ONE",
        h1.undo.length === depth0 + 1,
        `${depth0} -> ${h1.undo.length} (a loop of clip.remove would be +3)`);
  check("A4 ATOMICITY: the new entry is the GROUP label",
        h1.undo[0] === "Delete 3 Clips",
        `undo[0]="${h1.undo[0]}" (a loop would read "Remove Clip '…'")`);
  ov = await overview();
  check("A5 all three clips are gone from the project",
        totalClips(ov) === 0, `clips=${totalClips(ov)}`);
  check("R4 m23-e guard: the editor closed with the clip it was open on",
        d.editorClipId === null, `editorClipId=${d.editorClipId}`);

  const u = await req("edit.undo", {});
  await sleep(SETTLE_MS);
  ov = await overview();
  const restored = tracks.map((t) => clipsOf(ov, t));
  check("A6 ATOMICITY: ONE undo restored ALL THREE clips",
        totalClips(ov) === 3 && restored.every((cs) => cs.length === 1),
        `label="${u.undoneLabel ?? u.label ?? ""}" perTrack=${restored.map((c) => c.length).join(",")}`);
  check("A7 the restored clips are at their original beats and lengths",
        restored.every((cs) => near(cs[0].startBeat, CLIP_START_BEAT) && near(cs[0].lengthBeats, CLIP_BEATS)),
        restored.map((c) => `${c[0].startBeat}+${c[0].lengthBeats}`).join(" "));
  const h2 = await history();
  check("A8 the undo stack is back to the baseline depth (one step, not three)",
        h2.undo.length === depth0, `${h1.undo.length} -> ${h2.undo.length}, baseline ${depth0}`);

  // NON-VACUITY of the instrument itself: an empty selection must journal NOTHING.
  // Without this, "+1" could not be distinguished from "the stack grows on its own".
  await sel({ act: "clear" });
  const dEmpty = await sel({ act: "delete" });
  const h3 = await history();
  check("A9 non-vacuity: deleting an EMPTY selection journals nothing",
        dEmpty.deleted === false && h3.undo.length === h2.undo.length,
        `deleted=${dEmpty.deleted} depth ${h2.undo.length} -> ${h3.undo.length}`);

  // The restored clips have NEW ids after an undo? (they must not — undo restores
  // the same identities, which is what makes a re-select possible.)
  const freshIDs = ov.tracks.flatMap((t) => t.clips.map((c) => c.id));
  check("A10 undo restored the SAME clip identities (not fresh copies)",
        clips.every((c) => freshIDs.includes(c)), JSON.stringify(freshIDs));
  const reopened = await sel({ act: "click", clipId: clips[0] });
  check("R5 m23-e guard: after the undo, a click re-opens the editor on the clip",
        reopened.editorClipId === clips[0], `editorClipId=${reopened.editorClipId}`);

  // ══ KEY PATH ═════════════════════════════════════════════════════════════
  // K1 — the STRONGER probe: a real DELETE key-down through NSApp.sendEvent, i.e.
  // the actual responder chain and SwiftUI's focus arbitration. Reported either
  // way; an unbundled staging binary whose window is not key may never route it,
  // and that is a fact about staging, not about the feature.
  await sel({ act: "clear" });
  for (const [i, c] of clips.entries()) {
    await sel({ act: "click", clipId: c, ...(i === 0 ? {} : { shift: true }) });
  }
  const hK = await history();
  const k1 = await sel({ act: "keyDelete" });
  const hK1 = await history();
  const keyDelivered = k1.delivered === true;
  note(`K1 PROBE: a real DELETE key event ${keyDelivered ? "REACHED" : "did NOT reach"} the handler`,
       `delivered=${k1.delivered} count=${k1.count} depth ${hK.undo.length} -> ${hK1.undo.length}`
       + (keyDelivered ? " — key DELIVERY is proven" : " — delivery NOT proven from staging; the handler path is proven by A2–A8"));
  if (keyDelivered) {
    check("K1b if the key was delivered, it deleted as ONE step",
          hK1.undo.length === hK.undo.length + 1 && hK1.undo[0] === "Delete 3 Clips",
          `undo[0]="${hK1.undo[0]}"`);
    await req("edit.undo", {});
    await sleep(SETTLE_MS);
  }

  // K2 — THE GUARD, proved independently of delivery: with a rename field
  // focused, the DELETE handler must refuse. A Backspace typed into a rename
  // that silently deleted the user's clips is the destructive failure this
  // placement exists to prevent.
  await sel({ act: "clear" });
  for (const [i, c] of clips.entries()) {
    await sel({ act: "click", clipId: c, ...(i === 0 ? {} : { shift: true }) });
  }
  const before2 = await sel({});
  await req("marker.add", { beat: 1, name: "RenameMe" });
  const markers = await req("marker.list", {});
  const markerId = (markers.markers ?? markers)[0]?.id;
  await req("debug.markerRename", { markerId });
  await sleep(600);
  // Baseline taken AFTER the marker exists: `marker.add` is itself an undoable
  // edit, and folding it into the baseline would make the guard leg read a +1
  // that has nothing to do with the key.
  const hG = await history();
  const guardState = await sel({});
  check("K2a the rename field really has focus (the leg is not vacuous)",
        guardState.textEditing === true,
        `textEditing=${guardState.textEditing} — if false, K2b proves nothing`);
  const k2 = await sel({ act: "keyHandler" });
  const hG2 = await history();
  ov = await overview();
  check("K2b GUARD: DELETE while renaming does NOT delete the selected clips",
        k2.deleted === false && totalClips(ov) === 3 && hG2.undo.length === hG.undo.length,
        `deleted=${k2.deleted} clips=${totalClips(ov)} depth ${hG.undo.length} -> ${hG2.undo.length}`);
  check("K2c the selection SURVIVES the refused key (nothing was silently dropped)",
        k2.count === before2.count, `${before2.count} -> ${k2.count}`);
  await req("debug.markerRename", { clear: true });
  await sleep(400);
  const cleared = await sel({});
  check("K2d with the field closed the guard releases (it is not a permanent latch)",
        cleared.textEditing === false, `textEditing=${cleared.textEditing}`);
  const k3 = await sel({ act: "keyHandler" });
  ov = await overview();
  check("K2e and the SAME handler then deletes, proving K2b measured the guard",
        k3.deleted === true && totalClips(ov) === 0, `deleted=${k3.deleted} clips=${totalClips(ov)}`);

  // ══ SCOPE ════════════════════════════════════════════════════════════════
  // W — DELETE must be INERT outside the arrange workspace. `ArrangeDeleteKey` is
  // mounted INSIDE the arrange workspace (which the Mix branch replaces, and which
  // is not an ancestor of the modal overlays), so the Mix and modal cases are
  // structurally unreachable rather than guarded. `handleArrangeDeleteKey` ALSO
  // re-checks the Mix half, which is the half this seam can observe — the modal
  // half depends on the real view hierarchy and is provable only through real key
  // delivery, which K1 shows staging cannot achieve. It is disclosed as NOT
  // PROVEN rather than asserted here.
  await req("edit.undo", {});                    // restore the three K2e deleted
  await sleep(SETTLE_MS);
  ov = await overview();
  await sel({ act: "clear" });
  for (const [i, c] of clips.entries()) {
    await sel({ act: "click", clipId: c, ...(i === 0 ? {} : { shift: true }) });
  }
  const w0 = await sel({});
  check("W0 the clips are back and re-selected (the W legs are not vacuous)",
        totalClips(ov) === 3 && w0.count === 3,
        `clips=${totalClips(ov)} selected=${w0.count}`);
  const mixOn = await req("ui.showMixer", { show: true });
  await sleep(SETTLE_MS);
  const hW = await history();
  const wMix = await sel({ act: "keyHandler" });
  const hW2 = await history();
  ov = await overview();
  check("W1 the seam really switched to Mix (the leg is not vacuous)",
        wMix.workspaceMode === "mix", `showMixer=${mixOn.mode} echo=${wMix.workspaceMode}`);
  check("W2 SCOPE: DELETE in the Mix console does NOT delete the arrange selection",
        wMix.deleted === false && totalClips(ov) === 3
          && hW2.undo.length === hW.undo.length,
        `deleted=${wMix.deleted} clips=${totalClips(ov)} depth ${hW.undo.length} -> ${hW2.undo.length}`);
  check("W3 the selection SURVIVES the refused key (nothing silently dropped)",
        wMix.count === 3, `count=${wMix.count}`);
  await req("ui.showMixer", { show: false });
  await sleep(SETTLE_MS);
  // The K2b/K2e idiom: the same handler must then FIRE, or W2 proved only that
  // something unrelated was broken.
  const wArr = await sel({ act: "keyHandler" });
  ov = await overview();
  check("W4 back in Arrange the SAME handler deletes, proving W2 measured the scope",
        wArr.workspaceMode === "arrange" && wArr.deleted === true && totalClips(ov) === 0,
        `mode=${wArr.workspaceMode} deleted=${wArr.deleted} clips=${totalClips(ov)}`);

  // M — the RETAINED-FOCUS modal case. Selecting clips asserts key focus on the
  // arrange workspace; opening an inline `.overlay` modal does not necessarily
  // move it, so a DELETE pressed with a panel open can reach the handler DIRECTLY
  // without ever propagating through the modal. Scoping the modifier cannot see
  // that path, so `isModalPresented` guards it — and these legs are the only
  // reason that guard is a fact rather than a hope.
  await req("edit.undo", {});                    // restore the three W4 deleted
  await sleep(SETTLE_MS);
  ov = await overview();
  await sel({ act: "clear" });
  for (const [i, c] of clips.entries()) {
    await sel({ act: "click", clipId: c, ...(i === 0 ? {} : { shift: true }) });
  }
  const m0 = await sel({});
  check("M0 the clips are back and re-selected (the M legs are not vacuous)",
        totalClips(ov) === 3 && m0.count === 3 && m0.modalPresented === false,
        `clips=${totalClips(ov)} selected=${m0.count} modal=${m0.modalPresented}`);
  await req("debug.quantizePanel", { clipId: clips[0] });
  await sleep(SETTLE_MS);
  const hM = await history();
  const mOpen = await sel({ act: "keyHandler" });
  const hM2 = await history();
  ov = await overview();
  check("M1 the quantize panel really is up (the leg is not vacuous)",
        mOpen.modalPresented === true, `modalPresented=${mOpen.modalPresented}`);
  check("M2 GUARD: DELETE with a modal open does NOT delete the clips behind it",
        mOpen.deleted === false && totalClips(ov) === 3
          && hM2.undo.length === hM.undo.length,
        `deleted=${mOpen.deleted} clips=${totalClips(ov)} depth ${hM.undo.length} -> ${hM2.undo.length}`);
  check("M3 the selection SURVIVES the refused key",
        mOpen.count === 3, `count=${mOpen.count}`);
  await req("debug.quantizePanel", { close: true });
  await sleep(SETTLE_MS);
  const mShut = await sel({});
  check("M4 closing the panel releases the guard (it is not a permanent latch)",
        mShut.modalPresented === false, `modalPresented=${mShut.modalPresented}`);
  const mAfter = await sel({ act: "keyHandler" });
  ov = await overview();
  check("M5 and the SAME handler then deletes, proving M2 measured the guard",
        mAfter.deleted === true && totalClips(ov) === 0,
        `deleted=${mAfter.deleted} clips=${totalClips(ov)}`);

  // P — MEASUREMENT of the piano roll's key focus after an arrange clip click.
  // Clicking a clip bumps `arrangeKeyFocusNonce`, which asserts focus on the
  // workspace scope; if that were to win over the roll's own focus, note DELETE
  // inside the roll could stop working. Note SELECTION is not drivable from any
  // seam here, so this records the fact and does not claim to prove the roll's
  // note-delete path — that still needs a human.
  await req("edit.undo", {});
  await sleep(SETTLE_MS);
  await sel({ act: "click", clipId: clips[0] });   // clips[0] is the MIDI clip
  await sleep(600);
  const pr = await sel({});
  note("P1 PROBE: piano-roll key focus after clicking a MIDI clip",
       `pianoRollEditorFocused=${pr.pianoRollEditorFocused} editorClipId=${pr.editorClipId}`
       + " — HISTORY-DEPENDENT (observed false from a clean sequence, true after a"
       + " modal round-trip), i.e. the clip-click focus nonce does NOT permanently"
       + " hold focus away from the roll. The roll's own note-DELETE path still"
       + " needs a human: note SELECTION is not drivable from any seam here.");
} catch (err) {
  check("FATAL", false, String(err && err.stack ? err.stack : err));
} finally {
  try { ws.close(); } catch {}
  stopStaging(GATE, PIDFILE);   // m23-ac-2a: same pidfile-exact kill, one home
  clearTimeout(killer);
  const bad = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - bad.length}/${checks.length} assertions passed`
              + `  (+ ${notes.length} informational probe${notes.length === 1 ? "" : "s"}, which cannot fail)`);
  for (const n of notes) console.log(`  probe: ${n.name} — ${n.detail}`);
  if (bad.length) {
    console.log("FAILED:");
    for (const b of bad) console.log(`  - ${b.name}: ${b.detail}`);
  }
  process.exit(bad.length ? 1 : 0);
}
