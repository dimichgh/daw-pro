// m23-k4b GATE — a `.mid` reaches the app through the arrange drop, against a
// REAL app on staging (port 17695 only; 17600 is the user's LIVE app and is
// never touched. Staging is killed PIDFILE-EXACT).
//
// WHAT THIS PROVES AND WHAT IT DOES NOT
//   Proves: the HANDLER path, exactly as m23-f's gate does. `debug.arrangeDrop`
//   drives the SAME `AudioLaneDropCore` methods `AudioLaneDropDelegate` drives —
//   the seam cannot fake an OS event (`DropInfo` has no public initializer, and
//   the unbundled staging binary has no Accessibility grant: the m17-b −1712
//   measurement). Every assertion reads the app's own state afterwards
//   (`project.overview`, `edit.history`), never the seam's input.
//   Does NOT prove: that Finder's real drag reports `hasItemsConforming(to:
//   [.midi])` true for a `.mid`. That is OS behaviour, pinned as a unit fixture
//   in `MIDIDropRoutingTests.midConformsToAudio` instead
//   (`UTType(filenameExtension: "mid")` → `public.midi-audio`).
//
// THE HEADLINE MEASUREMENT (leg 4): how many undo steps a MIXED `.wav` + `.mid`
// drop costs. Not reasoned — read off `edit.history` and then spent, one
// `edit.undo` at a time, checking the project state after each.
//
//   M23K4B_PIDFILE=<scratch>/staging.pid node scripts/gates/m23k4b-midi-drop.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23k4b";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23K4B_OUT || "/tmp/m23k4b";
const PIDFILE = process.env.M23K4B_PIDFILE || "/tmp/m23k4b-staging.pid";
const BINARY = process.env.M23K4B_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23K4B_REPO || process.cwd();
const FIXTURES = `${OUT}/fixtures`;
fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Fixture arithmetic, computed before any assertion (the m23-c2 law) and then
// CHECKED against the app's own seam below — ppb 40, rowStep "large" →
// rowHeight 50, `.lanes` content so rulerInset 0:
//   lane 0 clip band = y in [0, 50) → probe y = 25
const PPB = 40;
const ROW_H = 50;
const Y_LANE0 = 25;
const SETTLE_MS = 350;
const X = (beat) => beat * PPB;

// ── fixtures ────────────────────────────────────────────────────────────────
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
fs.writeFileSync(`${FIXTURES}/tone2s.wav`, wav(88200));   // 2 s → 4 beats @120
// A REAL Standard MIDI File, not a hand-rolled one: the k1 byte fixture whose
// contents are Apple-confirmed (one format-1 MTrk on two channels → the mapper
// splits it into TWO instrument tracks, notes at beat 0).
fs.copyFileSync(`${REPO}/Tests/DAWCoreTests/Fixtures/SMF/hazard-type1-multichannel.mid`,
                `${FIXTURES}/song.mid`);
fs.writeFileSync(`${FIXTURES}/notes.txt`, "not a media file\n");

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
// previous run and refuses port 17600 in ONE place. Every M23K4B_* override is
// preserved — they let the gate be pointed at a bundle, which is deliberate.
buildOrAbort();
const { pid: stagingPid } = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY, pidfile: PIDFILE,
  outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${stagingPid} on :${PORT}`);
await sleep(4000);

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const near = (a, b, eps = 1e-6) => typeof a === "number" && Math.abs(a - b) < eps;

const drop = (p) => req("debug.arrangeDrop", p);
const overview = () => req("project.overview", {});
const history = () => req("edit.history", {});
const clipsOf = (ov, id) => ov.tracks.find((t) => t.id === id)?.clips ?? [];
const totalClips = (ov) => ov.tracks.reduce((n, t) => n + t.clips.length, 0);

try {
  // ── fixture ─────────────────────────────────────────────────────────────
  await req("project.new", { discardChanges: true });
  const a = await req("track.add", { kind: "audio", name: "DropAudio" });
  const audioId = (a.track ?? a).id;
  await req("debug.arrangeZoom", { reset: true });
  const zoom = await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await req("debug.panelDensity", { panel: "arrange", mode: "pro" });
  await req("transport.seek", { beats: 0 });
  await sleep(SETTLE_MS);

  const layout = await req("debug.panelLayout", {});
  check(`fixture: ppb is the ${PPB} the probe arithmetic assumes`,
        near(zoom.ppb, PPB), `ppb=${zoom.ppb}`);
  check(`fixture: rowHeight is the ${ROW_H} the lane-band arithmetic assumes`,
        near(layout.rowHeight, ROW_H), `rowHeight=${layout.rowHeight} (read, not assumed)`);

  // ── 1. CONTROL: an audio-only drag over the audio lane DOES highlight it ──
  // Without this leg, leg 2's "no highlight" could pass on a build that never
  // highlights anything.
  let e = await drop({ act: "enter", x: X(8), y: Y_LANE0, fileCount: 1 });
  check("1a control: an audio-only drag shows the drop line",
        e.hoverVisible === true, `hoverVisible=${e.hoverVisible} beat=${e.hoverBeat}`);
  check("1b control: …and HIGHLIGHTS the hovered audio lane",
        e.hoverTargetTrackId === audioId && e.hoverTargetLaneIndex === 0,
        `target=${e.hoverTargetTrackId} laneIndex=${e.hoverTargetLaneIndex}`);
  await drop({ act: "exit" });

  // ── 2. a MIDI-CARRYING drag: line yes, lane highlight NO ─────────────────
  // Same point, same file count — the ONLY difference is what the drag carries.
  e = await drop({ act: "enter", x: X(8), y: Y_LANE0, fileCount: 1, carriesMidi: true });
  check("2a midi hover: the drop LINE still shows (the landing beat is real)",
        e.hoverVisible === true && near(e.hoverBeat, 8),
        `hoverVisible=${e.hoverVisible} beat=${e.hoverBeat}`);
  check("2b midi hover: the audio lane is NOT highlighted (a .mid makes its own tracks)",
        e.hoverTargetLaneIndex === null,
        `laneIndex=${e.hoverTargetLaneIndex} (control leg 1b answered 0 at the same point)`);
  check("2c midi hover: the hovered TRACK is still reported (the line is not lost)",
        e.hoverTargetTrackId === audioId, `target=${e.hoverTargetTrackId}`);
  await drop({ act: "exit" });

  // ── 3. a MIDI-ONLY drop lands instrument tracks at the previewed beat ────
  const histBefore3 = (await history()).undo.length;
  e = await drop({ act: "drop", x: X(8), y: Y_LANE0, paths: [`${FIXTURES}/song.mid`] });
  await sleep(SETTLE_MS);
  const r3 = (e.results ?? [])[0] ?? {};
  check("3a midi drop: no error, and the per-file result reports the track count",
        !r3.error && r3.tracksCreated === 2,
        JSON.stringify(e.results));
  let ov = await overview();
  const inst3 = ov.tracks.filter((t) => t.kind === "instrument");
  check("3b midi drop: two instrument tracks appeared (the channel split)",
        inst3.length === 2, `instrument tracks=${inst3.length} of ${ov.tracks.length}`);
  check("3c midi drop: every imported clip starts at the beat the line was drawn at",
        inst3.length === 2 && inst3.every((t) => t.clips.length === 1 && near(t.clips[0].startBeat, 8)),
        `starts=${JSON.stringify(inst3.map((t) => t.clips.map((c) => c.startBeat)))} decidedBeat=${e.decidedBeat}`);
  check("3d midi drop: the hovered AUDIO lane got nothing",
        clipsOf(ov, audioId).length === 0, `clips on hovered lane=${clipsOf(ov, audioId).length}`);
  const hist3 = await history();
  // `edit.history.undo` is NEWEST-FIRST — `undo[0]` is what `edit.undo`
  // reverses next (`UndoHistory`'s stated contract, verified in the source
  // after this gate's first run sliced it the wrong way round).
  check("3e midi drop: costs exactly ONE undo step, labelled by the importer",
        hist3.undo.length === histBefore3 + 1 && hist3.undo[0] === "Import MIDI File",
        `depth ${histBefore3} → ${hist3.undo.length}; top=${JSON.stringify(hist3.undo.slice(0, 2))}`);

  // ── 4. THE MEASUREMENT: a MIXED .wav + .mid drop ────────────────────────
  await req("project.new", { discardChanges: true });
  const a2 = await req("track.add", { kind: "audio", name: "DropAudio" });
  const audioId2 = (a2.track ?? a2).id;
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await sleep(SETTLE_MS);
  const histBefore4 = (await history()).undo.length;
  const tracksBefore4 = (await overview()).tracks.length;

  e = await drop({
    act: "drop", x: X(8), y: Y_LANE0,
    paths: [`${FIXTURES}/tone2s.wav`, `${FIXTURES}/song.mid`, `${FIXTURES}/notes.txt`],
  });
  await sleep(SETTLE_MS);
  const results = e.results ?? [];
  check("4a mixed drop: the .wav imported, the .mid imported, the .txt was REFUSED",
        results.length === 3 && !results[0].error && !results[1].error
          && results[1].tracksCreated === 2 && (results[2].error ?? "").includes("supported"),
        JSON.stringify(results));

  ov = await overview();
  const audioTracks4 = ov.tracks.filter((t) => t.kind === "audio");
  const inst4 = ov.tracks.filter((t) => t.kind === "instrument");
  check("4b mixed drop: the .wav did NOT take the hovered lane — it made its own track",
        clipsOf(ov, audioId2).length === 0 && audioTracks4.length === 2,
        `hovered-lane clips=${clipsOf(ov, audioId2).length} audioTracks=${audioTracks4.length}`);
  const newAudio = audioTracks4.find((t) => t.id !== audioId2);
  check("4c mixed drop: BOTH halves land on the SAME beat (one resolved landing)",
        near(newAudio?.clips?.[0]?.startBeat, 8)
          && inst4.every((t) => t.clips.every((c) => near(c.startBeat, 8))),
        `wav=${newAudio?.clips?.[0]?.startBeat} midi=${JSON.stringify(inst4.map((t) => t.clips.map((c) => c.startBeat)))} decidedBeat=${e.decidedBeat}`);

  const hist4 = await history();
  // Newest-first, so the entries THIS drop added are the leading ones.
  const added = hist4.undo.slice(0, hist4.undo.length - histBefore4);
  console.log(`\n  [measured] mixed .wav + .mid drop cost ${added.length} undo step(s): `
    + `${JSON.stringify(added)}\n`);
  check("4d mixed drop: the undo cost is MEASURED off edit.history",
        added.length >= 1, `added=${JSON.stringify(added)}`);

  // Spend them one at a time, reading the project after each: the label stack
  // is a claim, the project state is the fact.
  const spent = [];
  for (let i = 0; i < added.length; i++) {
    const u = await req("edit.undo", {});
    await sleep(120);
    const after = await overview();
    spent.push({ undone: u.undone, tracks: after.tracks.length, clips: totalClips(after) });
  }
  console.log(`  [measured] undo ladder: ${JSON.stringify(spent)}`);
  const final = await overview();
  check(`4e mixed drop: ${added.length} undo(s) restore the pre-drop project exactly`,
        final.tracks.length === tracksBefore4 && totalClips(final) === 0,
        `tracks=${final.tracks.length} (pre-drop ${tracksBefore4}) clips=${totalClips(final)}`);
  check("4f mixed drop: ONE undo was NOT enough (so the count above is not vacuous)",
        added.length === 1
          ? spent[0].tracks === tracksBefore4
          : spent[0].tracks !== tracksBefore4 || spent[0].clips !== 0,
        `after first undo: tracks=${spent[0]?.tracks} clips=${spent[0]?.clips}`);

  const bad = checks.filter((c) => !c.ok);
  console.log(`\n${bad.length === 0 ? "GREEN" : "RED"} — ${checks.length - bad.length}/${checks.length}`);
  fs.writeFileSync(`${OUT}/checks.json`, JSON.stringify({ checks, mixedDropUndoSteps: added, spent }, null, 2));
  ws.close();
  clearTimeout(killer);
  // ⚠️ m23-ac-2a: this gate LEAKED — detached + unref, then exit with no
  // teardown. BOTH exit paths need it; the error path leaked too, and an
  // orphan left by a CRASHED gate is the one most likely to be adopted
  // unnoticed by whatever runs next.
  stopStaging(GATE, PIDFILE);
  process.exit(bad.length === 0 ? 0 : 1);
} catch (err) {
  console.error("GATE ERROR", err);
  try { ws.close(); } catch {}
  clearTimeout(killer);
  stopStaging(GATE, PIDFILE);
  process.exit(2);
}
