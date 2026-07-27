// m23-f GATE — arrange audio drop: an honest drop indicator + snap/magnet
// landing, against a REAL app on staging (port 17695 only; 17600 is the user's
// LIVE app and is never touched. Staging is killed PIDFILE-EXACT).
//
// WHAT THIS PROVES AND WHAT IT DOES NOT
//   Proves: the HANDLER path. `debug.arrangeDrop` drives the SAME
//   `AudioLaneDropCore` methods `AudioLaneDropDelegate` drives — the seam does
//   not fake an OS event, because it cannot (`DropInfo` has no public
//   initializer, and the unbundled staging binary has no Accessibility grant:
//   the m17-b −1712 measurement). Every assertion reads the app's own state
//   afterwards: `project.overview` for the landed clip and the seam echo's
//   `hoverVisible` for whether a drop line is standing.
//   Does NOT prove: that macOS delivers the drag callbacks in the orders staged
//   here. Leg 2's post-drop `update` in particular is an ordering this gate
//   INJECTS; AppKit does not send `draggingUpdated:` after
//   `performDragOperation:`. It proves the handler is robust to it, not that it
//   happens. Leg 3 injects no ordering at all — it simply stops sending drag
//   events, which is what an abandoned/cancelled drag looks like from inside the
//   app; pre-fix, nothing outside `dropExited`/`performDrop` could ever clear the
//   hover, so it stood indefinitely. (The same stranding was also observed
//   surviving app deactivation during the m23-f investigation — that evidence is
//   in the session repro logs, not in this gate.)
//
// THE PRE-FIX ARTIFACT, MEASURED (so these legs are calibrated against a real
// defect and not against themselves):
//   A cyan 2 pt line at the drop x, y = 390..613 px = 224 px = 112 pt = the
//   lanes' full `contentHeight` for 2 tracks — against `rowHeight` 100 px, which
//   is what a degenerate one-lane artifact would have measured. That is
//   `TimelineLanesView.dropAffordance`, stranded. Captures live in the m23-f
//   session scratchpad; the identity question the roadmap posed is answered by
//   that number.
//
// FIXTURE ARITHMETIC, computed before any assertion was written (the m23-c2
// law): ppb 40, rowStep "large" -> rowHeight 50, laneSpacing 6, `.lanes` content
// so rulerInset = 0, no takes/automation expanded:
//   lane 0 (audio)      clip band = y in [0, 50)    -> probe y = 25
//   lane 1 (instrument) clip band = y in [56, 106)  -> probe y = 81
// x = beat * 40, and the viewport is ~1141 pt wide, so every probe beat below is
// under 28 to stay ON SCREEN (pass 1 of the investigation lost two captures to
// off-screen probes).
// The magnet radius is 10 pt = 0.25 beat at ppb 40; every "inside"/"outside"
// probe is derived from that, never guessed.
//
//   M23F_PIDFILE=<scratch>/staging.pid M23F_FIXTURES=<dir> node scripts/gates/m23f-arrange-drop.mjs
import fs from "fs";
import { spawn } from "child_process";

const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23F_OUT || "/tmp/m23f";
const PIDFILE = process.env.M23F_PIDFILE || "/tmp/m23f-staging.pid";
const BINARY = process.env.M23F_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23F_REPO || process.cwd();
const FIXTURES = process.env.M23F_FIXTURES || `${OUT}/fixtures`;
fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const PPB = 40;
const ROW_H = 50;
const LANE_SPACING = 6;
const Y_AUDIO = 25;
const Y_INST = ROW_H + LANE_SPACING + ROW_H / 2;   // 81
const SETTLE_MS = 350;
const MAGNET_BEATS = 10 / PPB;                      // 0.25
const X = (beat) => beat * PPB;

// ── fixtures: real WAV files (a drop needs files that AVAudioFile can read) ──
function wav(frames, sampleRate = 44100) {
  const dataBytes = frames * 2;
  const buf = Buffer.alloc(44 + dataBytes);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + dataBytes, 4); buf.write("WAVE", 8);
  buf.write("fmt ", 12); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22); buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * 2, 28); buf.writeUInt16LE(2, 32); buf.writeUInt16LE(16, 34);
  buf.write("data", 36); buf.writeUInt32LE(dataBytes, 40);
  for (let i = 0; i < frames; i++) {
    buf.writeInt16LE(Math.round(12000 * Math.sin((2 * Math.PI * 220 * i) / sampleRate)), 44 + i * 2);
  }
  return buf;
}
fs.mkdirSync(FIXTURES, { recursive: true });
fs.writeFileSync(`${FIXTURES}/tone2s.wav`, wav(88200));   // 2 s -> 4 beats @120
fs.writeFileSync(`${FIXTURES}/tone1s.wav`, wav(44100));   // 1 s -> 2 beats @120
fs.writeFileSync(`${FIXTURES}/empty.wav`, wav(0));        // VALID header, 0 frames
fs.writeFileSync(`${FIXTURES}/notaudio.txt`, "not audio\n");

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

// ── launch staging (pidfile-exact teardown of any previous run) ─────────────
if (fs.existsSync(PIDFILE)) {
  const oldPid = Number(fs.readFileSync(PIDFILE, "utf8").trim());
  if (Number.isFinite(oldPid) && oldPid > 1) {
    try { process.kill(oldPid); } catch {}      // pidfile-EXACT; never pkill/pgrep
    await sleep(1500);
  }
}
const log = fs.openSync(`${OUT}/staging.log`, "a");
const child = spawn(BINARY, [], {
  cwd: REPO, detached: true, stdio: ["ignore", log, log],
  env: { ...process.env, DAW_CONTROL_PORT: PORT },
});
child.unref();
fs.writeFileSync(PIDFILE, String(child.pid));
console.log(`staging pid ${child.pid} on :${PORT}`);
await sleep(4000);

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const near = (a, b, eps = 1e-6) => typeof a === "number" && Math.abs(a - b) < eps;

const drop = (p) => req("debug.arrangeDrop", p);
const pointer = (p) => req("debug.arrangePointer", p);
const overview = () => req("project.overview", {});
const clipsOf = (ov, id) => ov.tracks.find((t) => t.id === id)?.clips ?? [];
const totalClips = (ov) => ov.tracks.reduce((n, t) => n + t.clips.length, 0);

try {
  // ── fixture ─────────────────────────────────────────────────────────────
  await req("project.new", { discardChanges: true });
  const a = await req("track.add", { kind: "audio", name: "DropAudio" });
  const audioId = (a.track ?? a).id;
  const i = await req("track.add", { kind: "instrument", name: "DropInst" });
  const instId = (i.track ?? i).id;
  await req("debug.arrangeZoom", { reset: true });
  const zoom = await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await req("transport.seek", { beats: 0 });
  await sleep(SETTLE_MS);

  const layout = await req("debug.panelLayout", {});
  check(`fixture: ppb is the ${PPB} the probe arithmetic assumes`, near(zoom.ppb, PPB), `ppb=${zoom.ppb}`);
  check(`fixture: rowHeight is the ${ROW_H} the lane-band arithmetic assumes`,
        near(layout.rowHeight, ROW_H), `rowHeight=${layout.rowHeight}`);
  check("fixture: two tracks, zero clips", (await overview()).tracks.length === 2 && totalClips(await overview()) === 0,
        `tracks=${(await overview()).tracks.length}`);

  // ── 1. a drop line shows WHILE a drag is in flight (the control) ────────
  // Without this leg every "no line" assertion below could pass vacuously on a
  // feature that never draws a line at all.
  let e = await drop({ act: "enter", x: X(4), y: Y_AUDIO, fileCount: 1 });
  check("1a in-flight: entering the lanes shows a drop line",
        e.hoverVisible === true, `hoverVisible=${e.hoverVisible} beat=${e.hoverBeat}`);
  e = await drop({ act: "update", x: X(8), y: Y_AUDIO, fileCount: 1 });
  check("1b in-flight: the line TRACKS the pointer (echo is not stale)",
        e.hoverVisible === true && near(e.hoverBeat, 8),
        `hoverBeat=${e.hoverBeat} expected 8 — a one-call lag would answer 4`);
  check("1c in-flight: the hovered AUDIO lane is the routing target",
        e.hoverTargetTrackId === audioId && e.hoverTargetLaneIndex === 0,
        `target=${e.hoverTargetTrackId} laneIndex=${e.hoverTargetLaneIndex}`);

  // ── 2. the drop clears the line, and a POST-DROP update cannot re-arm it ─
  e = await drop({ act: "drop", x: X(8), y: Y_AUDIO, paths: [`${FIXTURES}/tone2s.wav`] });
  check("2a drop: the line is gone on the CAUSING call",
        e.hoverVisible === false, `hoverVisible=${e.hoverVisible}`);
  check("2b drop: the file landed at the previewed beat",
        Array.isArray(e.results) && e.results.length === 1 && !e.results[0].error,
        JSON.stringify(e.results));
  let ov = await overview();
  let clip = clipsOf(ov, audioId)[0];
  check("2c drop: the clip's startBeat IS the beat the line was drawn at",
        near(clip?.startBeat, 8) && near(e.decidedBeat, 8),
        `startBeat=${clip?.startBeat} decidedBeat=${e.decidedBeat}`);
  // THE report-(2) regression leg. Pre-fix this returned hoverVisible true and
  // left a full-contentHeight glowing line standing over a landed clip.
  e = await drop({ act: "update", x: X(8), y: Y_AUDIO, fileCount: 1 });
  check("2d drop: a post-drop UPDATE cannot re-arm the line",
        e.hoverVisible === false,
        `hoverVisible=${e.hoverVisible} — pre-fix this was true (measured 224 px = contentHeight)`);

  // ── 3. a STRANDED line is dismissed by an ordinary pointer event ────────
  // The stranding here is not injected: the hover is armed by a drag that then
  // never terminates, which is exactly what a cancelled/abandoned drag leaves.
  await drop({ act: "exit" });
  await drop({ act: "enter", x: X(16), y: Y_INST, fileCount: 1 });
  e = await drop({ act: "update", x: X(16), y: Y_INST, fileCount: 1 });
  check("3a stranded: an unterminated drag leaves the line standing",
        e.hoverVisible === true, `hoverVisible=${e.hoverVisible}`);
  // The user's next mouse move over the timeline. Nothing about this event
  // belongs to the drop system — it is the ordinary hover handler.
  await pointer({ act: "hover", x: X(20), y: Y_INST });
  e = await drop({});
  check("3b stranded: the next ordinary POINTER event removes it",
        e.hoverVisible === false && e.pressedMouseButtons === 0,
        `hoverVisible=${e.hoverVisible} pressedMouseButtons=${e.pressedMouseButtons}`
          + " — this is what makes the artifact removable");

  // 3c: the dismissal's SAFETY guard is a pure predicate, asserted in
  // `ArrangeDropSnapTests.pointerDismissRule` — it cannot be asserted here,
  // because a gate has no way to hold a mouse button down. Recorded so the
  // absence is deliberate rather than an oversight: this leg proves the clear
  // FIRES, the unit test proves it does not fire mid-drag.

  // ── 4. snap: the drop-position table across snap settings ──────────────
  // Each row records the PREVIEWED beat, the source rule, and the LANDED
  // startBeat, so preview/landing agreement is asserted per row rather than
  // assumed. Raw beat 9.4 is deliberately off every grid.
  const table = [];
  for (const [snap, expectBeat, expectSource] of [
    ["off", 9.4, "raw"],
    ["bar", 8, "grid"],
    ["beat", 9, "grid"],
    ["sixteenth", 9.375, "grid"],
  ]) {
    await req("project.new", { discardChanges: true });
    const t = await req("track.add", { kind: "audio", name: "SnapLane" });
    const tid = (t.track ?? t).id;
    await req("debug.arrangeZoom", { reset: true });
    await req("debug.arrangeZoom", { ppb: PPB });
    await req("debug.arrangeZoom", { rowStep: "large" });
    await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
    await drop({ snap });
    await sleep(SETTLE_MS);
    const hov = await drop({ act: "enter", x: X(9.4), y: Y_AUDIO, fileCount: 1 });
    const dropped = await drop({ act: "drop", x: X(9.4), y: Y_AUDIO, paths: [`${FIXTURES}/tone1s.wav`] });
    const landed = clipsOf(await overview(), tid)[0];
    table.push({ snap, preview: hov.hoverBeat, source: hov.hoverSnapSource,
                 landed: landed?.startBeat, decided: dropped.decidedBeat });
    check(`4 snap ${snap}: preview ${expectBeat} (${expectSource}) == landed`,
          near(hov.hoverBeat, expectBeat) && hov.hoverSnapSource === expectSource
            && near(landed?.startBeat, expectBeat),
          `preview=${hov.hoverBeat} source=${hov.hoverSnapSource} landed=${landed?.startBeat}`);
  }
  console.log("\n  DROP-POSITION TABLE (raw beat 9.4, ppb 40)");
  console.log("  snap        preview   source     landed");
  for (const r of table) {
    console.log(`  ${r.snap.padEnd(11)} ${String(r.preview).padEnd(9)} ${String(r.source).padEnd(10)} ${r.landed}`);
  }

  // ── 5. magnet: clip edges + bar 1, and the exclusion boundary ───────────
  await req("project.new", { discardChanges: true });
  const m = await req("track.add", { kind: "audio", name: "MagnetLane" });
  const magId = (m.track ?? m).id;
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await drop({ snap: "bar" });
  // A resident clip whose edges are deliberately OFF the bar grid: 5.3 -> 7.3.
  await req("clip.addAudio", { trackId: magId, path: `${FIXTURES}/tone1s.wav`, atBeat: 5.3 });
  await sleep(SETTLE_MS);
  ov = await overview();
  const resident = clipsOf(ov, magId)[0];
  const edge = resident.startBeat + resident.lengthBeats;
  check("5a magnet fixture: the resident clip's END edge is OFF the bar grid",
        near(resident.startBeat, 5.3) && Math.abs(edge - Math.round(edge / 4) * 4) > MAGNET_BEATS,
        `start=${resident.startBeat} end=${edge}`);

  // Inside the radius: the magnet must beat the bar grid (which would say 8).
  e = await drop({ act: "enter", x: X(edge + MAGNET_BEATS / 2), y: Y_AUDIO, fileCount: 1 });
  check("5b magnet: a clip edge INSIDE the radius takes the drop from the grid",
        near(e.hoverBeat, edge) && e.hoverSnapSource === "magnetClipEdge",
        `hoverBeat=${e.hoverBeat} source=${e.hoverSnapSource} edge=${edge} (grid would be 8)`);

  // Outside the radius: the grid must win. This is the direction that proves
  // the radius is real rather than the magnet swallowing the whole lane.
  e = await drop({ act: "update", x: X(edge + MAGNET_BEATS * 2), y: Y_AUDIO, fileCount: 1 });
  check("5c magnet: OUTSIDE the radius the grid is back in charge",
        e.hoverSnapSource === "grid" && near(e.hoverBeat, 8),
        `hoverBeat=${e.hoverBeat} source=${e.hoverSnapSource}`);

  // Bar 1 under a FINE grid — the case a nearest-wins rule could never reach.
  await drop({ snap: "sixteenth" });
  await sleep(SETTLE_MS);
  e = await drop({ act: "update", x: X(0.05), y: Y_AUDIO, fileCount: 1 });
  check("5d magnet: bar 1 wins under a 1/16 grid",
        near(e.hoverBeat, 0) && e.hoverSnapSource === "magnetBarOne",
        `hoverBeat=${e.hoverBeat} source=${e.hoverSnapSource} (grid would be 0.0625)`);

  // Snap OFF must not magnetise — the user turned snapping off on purpose.
  await drop({ snap: "off" });
  await sleep(SETTLE_MS);
  e = await drop({ act: "update", x: X(edge + MAGNET_BEATS / 2), y: Y_AUDIO, fileCount: 1 });
  check("5e magnet: snap OFF never magnetises",
        e.hoverSnapSource === "raw" && near(e.hoverBeat, edge + MAGNET_BEATS / 2),
        `hoverBeat=${e.hoverBeat} source=${e.hoverSnapSource}`);

  // And the magnetised landing must SURVIVE into the store (the one-home point:
  // a second snap downstream would pull this to the bar grid).
  await drop({ snap: "bar" });
  await sleep(SETTLE_MS);
  await drop({ act: "exit" });
  await drop({ act: "enter", x: X(edge + MAGNET_BEATS / 2), y: Y_AUDIO, fileCount: 1 });
  e = await drop({ act: "drop", x: X(edge + MAGNET_BEATS / 2), y: Y_AUDIO,
                   paths: [`${FIXTURES}/tone1s.wav`] });
  const magnetLanded = clipsOf(await overview(), magId).find((c) => near(c.startBeat, edge));
  check("5f magnet: the magnetised beat is what the CLIP lands on, not a re-snapped one",
        !!magnetLanded && e.decidedSnapSource === "magnetClipEdge",
        `landedStarts=${JSON.stringify(clipsOf(await overview(), magId).map((c) => c.startBeat))} expected ${edge}`);

  // ── 6. the zero-length clip artifact ───────────────────────────────────
  await req("project.new", { discardChanges: true });
  const z = await req("track.add", { kind: "audio", name: "ZeroLane" });
  const zeroId = (z.track ?? z).id;
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await sleep(SETTLE_MS);
  await drop({ act: "enter", x: X(4), y: Y_AUDIO, fileCount: 1 });
  e = await drop({ act: "drop", x: X(4), y: Y_AUDIO, paths: [`${FIXTURES}/empty.wav`] });
  const zeroClip = clipsOf(await overview(), zeroId)[0];
  check("6 zero-frame file: no ZERO-LENGTH clip is placed",
        !!zeroClip && zeroClip.lengthBeats > 0,
        `lengthBeats=${zeroClip?.lengthBeats} — pre-fix this was exactly 0 (measured live)`);

  // ── 7. a non-audio drop still creates nothing and reports why ──────────
  await drop({ act: "exit" });
  await drop({ act: "enter", x: X(12), y: Y_AUDIO, fileCount: 1 });
  e = await drop({ act: "drop", x: X(12), y: Y_AUDIO, paths: [`${FIXTURES}/notaudio.txt`] });
  check("7 non-audio: rejected with a readable reason, no clip, no stranded line",
        e.hoverVisible === false && e.results?.[0]?.error?.includes(".txt")
          && clipsOf(await overview(), zeroId).length === 1,
        `error=${e.results?.[0]?.error} hoverVisible=${e.hoverVisible}`);

  await drop({ act: "exit" });
  await req("project.new", { discardChanges: true });
} catch (err) {
  check("gate ran to completion", false, err.message);
} finally {
  clearTimeout(killer);
  const pass = checks.filter((c) => c.ok).length;
  console.log(`\nORCH_M23F pass=${pass} fail=${checks.length - pass} of ${checks.length}`);
  ws.close();
  await sleep(200);
  process.exit(checks.every((c) => c.ok) ? 0 : 1);
}
