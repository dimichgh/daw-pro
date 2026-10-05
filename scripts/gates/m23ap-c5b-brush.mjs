// m23-ap C5b-4b GATE (C5b-G) — THE FREEHAND BRUSH, LOOKED AT on a REAL app on
// staging (port 17695 ONLY; 17600 is the user's LIVE app and is never touched.
// Staging is stopped PIDFILE-EXACT through `_pitch-editor-look.mjs`'s
// `stopLook`, never pkill/pgrep). Design: timing-and-freehand §5.5–§5.6, the
// C5b-4 increment's looked-at gate ("a peak pulled up, with the line and the
// help visible").
//
// ⭐ A SPY GATE WITH A SECOND INSTRUMENT. The pane says what it drew
// (`debug.pitchEditor`'s `brush` block: the band, the stroke, the draft the
// release would store, the readout; `interaction.toolHelp` for the palette's
// words), and the STORE is read back over the wire independently
// (`clip.getPitchEdits`, `edit.history`, `edit.undo`) — never one instrument.
//
// WHAT THIS PROVES
//   • ⌘ held over a sung note shows the brush band (2 × 12 pt, full height) and
//     the brush's help; without ⌘ the same hover shows none (the control);
//   • a ⌘-drag that pulls a peak up draws a live draft and commits NOTHING
//     while the button is down;
//   • the release is ONE "Draw Pitch" undo step, and what the store holds is
//     EXACTLY the draft the pane drew at the last tick (every note, every
//     sample), the readout's number included; Undo restores the table;
//   • a stroke across two notes is still ONE undo step;
//   • Escape mid-stroke drops it: nothing committed;
//   • on a breath or consonant (when the fixture's table has one) the band is
//     refused in words and the press draws nothing;
//   • THE USER'S FOCUS STAYS PUT: staging launches with
//     DAWPRO_STAGING_NO_ACTIVATE=1, every capture reports the app INACTIVE, and
//     the frontmost app (lsappinfo) is never the staging app — before the
//     launch, after it, after the last capture and after the stop.
//
// WHAT THIS DOES NOT PROVE
//   • a real pointer (m23-g1): the steps go through the pane's own gesture
//     functions (`debug.pitchEditor {act:…}`), not the event system; ⌘ is the
//     staged `keys` step and the steps' `command: true`;
//   • sound: the tracks are muted, and a gate has no business making sound;
//   • motion: `view.capture` is ~3.5 fps and cannot film a stroke.
//
// PRECONDITION — AN UNLOCKED SCREEN. With the screen locked the frontmost app
// is `loginwindow` and a capture proves nothing; the gate refuses (exit 2)
// before it launches anything.
//
// PROVENANCE — as in `m23ap-c5a4b-wobble.mjs`: the look harness launches with
// `skipBuild`, so this gate first proves `.build/debug/DAWApp` is newer than
// every file under `Sources/` and `Package.swift` (with a positive control on
// the same `find`), and refuses (exit 2) otherwise. Build under a heavy slot
// right before running it.
//
//   node scripts/gates/m23ap-c5b-brush.mjs
//
// Env: M23AP_C5B_OUT (captures, fixtures, the named project; default
//      /tmp/m23ap-c5b).
//
// EXIT: 0 green, 1 red, 2 proves nothing (a refused precondition).
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { ROOT, DEFAULT_BINARY, STAGING_DEFAULTS_DOMAIN, verdict, sleep } from "./_staging.mjs";
import {
  synthesizeVocalFixture, launchLook, stopLook, makeCmd, waitPitchEditorReady,
  stagePitchEditorStep, captureLook,
} from "./_pitch-editor-look.mjs";

const GATE = "m23ap-c5b";
const OUT = process.env.M23AP_C5B_OUT || "/tmp/m23ap-c5b";
mkdirSync(OUT, { recursive: true });

const PPB = 64;               // C5a-4b's zoom: a 1.5 s note is ~190 pt wide
const EPS = 1e-9;
// The process name the staging child runs as (`_staging.mjs`'s alias), which
// is what lsappinfo reports if it ever becomes frontmost.
const STAGING_NAME = STAGING_DEFAULTS_DOMAIN;
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const r3 = (v) => (typeof v === "number" ? Math.round(v * 1000) / 1000 : v);
/** Key-order-free rendering (C5a-4b's comparator, same reason: the wire's
 * objects come from a Swift dictionary whose key order varies call to call). */
const canon = (v) => JSON.stringify(v, (_, x) => (x && typeof x === "object" && !Array.isArray(x)
  ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]])) : x));
function refuseRun(reason) {
  console.log(`ABORT (proves nothing): ${reason}`);
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}

/** The frontmost app's name AND pid, from lsappinfo (the w7 focus law's
 * instrument). `name` is null when lsappinfo answered nothing parseable — a
 * reading that proves nothing, never "nobody is frontmost". The PID is what
 * the focus checks compare: no run has yet shown what name lsappinfo gives the
 * staging child (an unbundled binary reached through `_staging.mjs`'s alias),
 * so a name-only check could pass vacuously. */
function frontmostApp() {
  const front = spawnSync("lsappinfo", ["front"], { encoding: "utf8" });
  const asn = (front.stdout ?? "").trim();
  if (!asn) return { name: null, pid: null, raw: `lsappinfo front: ${(front.stderr ?? "").trim() || "no output"}` };
  const info = spawnSync("lsappinfo", ["info", "-only", "pid,name", asn], { encoding: "utf8" });
  const raw = (info.stdout ?? "").trim();
  const m = /"LSDisplayName"="([^"]*)"/.exec(raw);
  const p = /"pid"=(\d+)/.exec(raw);
  return { name: m ? m[1] : null, pid: p ? Number(p[1]) : null, raw };
}

/** A capture's own numbers: its bytes' hash (two captures of different states
 * must differ, or one of them is STALE) and its luma range through ffmpeg's
 * `signalstats` (a blank capture has almost none). `-hide_banner` and the
 * default log level: `metadata=print` logs at INFO, which `-v error` would
 * swallow into a clean, wrong "unmeasured". */
function captureFacts(path) {
  if (!existsSync(path)) return { exists: false };
  const sha = createHash("sha256").update(readFileSync(path)).digest("hex").slice(0, 16);
  const r = spawnSync("ffmpeg", ["-hide_banner", "-i", path, "-vf", "signalstats,metadata=print",
    "-f", "null", "-"], { encoding: "utf8" });
  const text = `${r.stderr ?? ""}${r.stdout ?? ""}`;
  const num = (k) => {
    const m = new RegExp(`lavfi\\.signalstats\\.${k}=([0-9.]+)`).exec(text);
    return m ? Number(m[1]) : null;
  };
  return { exists: true, sha, ymin: num("YMIN"), ymax: num("YMAX"), yavg: num("YAVG"), ffmpegStatus: r.status };
}

// ═══════════════════════════════════════════════════════════════════════════
// PRECONDITIONS: an unlocked screen, then provenance
// ═══════════════════════════════════════════════════════════════════════════
const front0 = frontmostApp();
console.log(`frontmost before the launch: ${front0.name ?? `(unreadable: ${front0.raw})`}`);
if (front0.name === null) refuseRun(`lsappinfo did not name the frontmost app (${front0.raw})`);
if (front0.name === "loginwindow") {
  refuseRun("the screen is LOCKED (frontmost: loginwindow) — pending an unlocked screen");
}
if (front0.name === STAGING_NAME) {
  refuseRun(`a staging app (${STAGING_NAME}) is ALREADY frontmost — a previous run left it; `
    + "this run could not tell its own focus theft from that one's");
}
// Set right after the launch: the one pid that must never be frontmost.
let stagingPid = null;
/** Did this reading find the user's focus taken — by the staging child (by
 * PID; by the alias NAME too, for a leftover from another run), or by a Finder
 * window that was not frontmost before the launch? */
const stoleFocus = (f) => (stagingPid !== null && f.pid === stagingPid) || f.name === STAGING_NAME
  || (f.name === "Finder" && front0.name !== "Finder");
{
  const binary = join(ROOT, DEFAULT_BINARY);
  const find = (args) => spawnSync("find", args, { cwd: ROOT, encoding: "utf8" });
  const newer = find(["Sources", "Package.swift", "-newer", binary, "-type", "f"]);
  const older = find(["Sources", "-type", "f", "!", "-newer", binary]);
  if (newer.status !== 0 || older.status !== 0) refuseRun(`find failed: ${newer.stderr || older.stderr}`);
  const newerFiles = newer.stdout.split("\n").filter(Boolean);
  const olderCount = older.stdout.split("\n").filter(Boolean).length;
  if (olderCount === 0) refuseRun("provenance control: `! -newer` matched no file — the find shape is broken");
  if (newerFiles.length > 0) {
    refuseRun(`${newerFiles.length} source file(s) are NEWER than ${DEFAULT_BINARY} `
      + `(${newerFiles.slice(0, 4).join(", ")}) — rebuild under a heavy slot and re-run`);
  }
  console.log(`provenance: ${DEFAULT_BINARY} is newer than all ${olderCount} files under Sources/ and Package.swift`);
}

// ═══════════════════════════════════════════════════════════════════════════
// FIXTURES
// ═══════════════════════════════════════════════════════════════════════════
// The main vocal: three sung notes (the shared, proven recipe).
const LEGS = [
  { hz: 220, seconds: 1.5 },   // the peak pulled up
  { hz: 247, seconds: 1.5 },   // the second note of a two-note stroke
  { hz: 196, seconds: 1.5 },   // the Escape leg
];
const fixturePath = synthesizeVocalFixture(OUT, { notes: LEGS });

/** A second vocal with a CONSONANT the finder can see: the finder measures
 * the clip's own noise floor from at least 1 s of unvoiced frames that carry a
 * level (`PitchUnpitchedFinder.minimumQuietSeconds`; digital silence carries
 * none), and keeps a stretch 9 dB over it (`defaultMarginDb`) that lasts at
 * least 60 ms. So: a quiet noise bed (≈ −50 dBFS) around the notes, and a loud
 * 150 ms noise burst in the gap between them. Built with the shared recipe's
 * voice (three partials, 5.5 Hz vibrato, click-free fades). If the finder
 * still finds no sound here, the sound leg says NOT RUN — loudly. */
function synthesizeSoundFixture(outDir) {
  const path = join(outDir, "vocal-with-consonant.wav");
  const parts = [
    { kind: "bed", seconds: 0.7 }, { kind: "note", hz: 220, seconds: 1.2 },
    { kind: "bed", seconds: 0.3 }, { kind: "burst", seconds: 0.15 }, { kind: "bed", seconds: 0.3 },
    { kind: "note", hz: 247, seconds: 1.2 }, { kind: "bed", seconds: 0.6 },
  ];
  const args = ["-hide_banner", "-y"];
  const filters = [];
  const labels = [];
  let input = 0;
  parts.forEach((p, i) => {
    const label = `p${i}`;
    if (p.kind === "bed" || p.kind === "burst") {
      const src = p.kind === "bed"
        ? `anoisesrc=color=pink:duration=${p.seconds}:amplitude=0.003:seed=${7 + i}`
        : `anoisesrc=color=white:duration=${p.seconds}:amplitude=0.3:seed=${11 + i}`;
      args.push("-f", "lavfi", "-i", src);
      filters.push(`[${input}]aformat=channel_layouts=mono[${label}]`);
      input += 1;
    } else {
      const outFade = Math.max(p.seconds - 0.06, 0.01).toFixed(3);
      args.push(
        "-f", "lavfi", "-i", `sine=frequency=${p.hz}:duration=${p.seconds}`,
        "-f", "lavfi", "-i", `sine=frequency=${p.hz * 2}:duration=${p.seconds}`,
        "-f", "lavfi", "-i", `sine=frequency=${p.hz * 3}:duration=${p.seconds}`,
      );
      filters.push(`[${input}][${input + 1}][${input + 2}]amix=inputs=3:weights='1.0 0.45 0.22':normalize=0,`
        + `vibrato=f=5.5:d=0.4,volume=0.35,`
        + `afade=t=in:st=0:d=0.04,afade=t=out:st=${outFade}:d=0.06,aformat=channel_layouts=mono[${label}]`);
      input += 3;
    }
    labels.push(`[${label}]`);
  });
  filters.push(`${labels.join("")}concat=n=${labels.length}:v=0:a=1[out]`);
  args.push("-filter_complex", filters.join(";"), "-map", "[out]", "-ac", "1", "-ar", "48000",
    "-c:a", "pcm_s16le", path);
  const r = spawnSync("ffmpeg", args, { encoding: "utf8" });
  if (r.status !== 0 || !existsSync(path)) {
    throw new Error(`synthesizeSoundFixture: ffmpeg failed (exit ${r.status})\n${r.stderr ?? ""}`);
  }
  return path;
}
const soundFixturePath = synthesizeSoundFixture(OUT);

const killer = setTimeout(() => {
  console.log("TIMEOUT — 10 minutes");
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}, 600_000);

// ⭐ THE FOCUS LAW: the launch skips `activate(ignoringOtherApps:)` (DAWProApp's
// onAppear, opt-in) so the user's frontmost app stays frontmost.
const session = await launchLook({ gate: GATE, settleMs: 1500, env: { DAWPRO_STAGING_NO_ACTIVATE: "1" } });
console.log(`staging pid ${session.pid} (skipBuild — provenance proved above; DAWPRO_STAGING_NO_ACTIVATE=1); `
  + `started ${new Date().toISOString()}`);
const cmd = makeCmd(session.ws);
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (!r || r.ok !== true) throw new Error(`${command} failed — ${JSON.stringify(r?.error ?? r)}`);
  return r.result;
}
const echo = () => must("debug.pitchEditor", {});
const stage = (act) => stagePitchEditorStep(cmd, act);
stagingPid = session.pid;
const fronts = [{ at: "before the launch", name: front0.name, pid: front0.pid }];
const noteFront = (at) => {
  const f = frontmostApp();
  fronts.push({ at, name: f.name ?? `(unreadable: ${f.raw})`, pid: f.pid });
  return f;
};

let exitCode = null;
const captures = {};
const facts = {};
const looks = {};
async function shoot(key, file) {
  const shot = await captureLook(cmd, join(OUT, file));
  captures[key] = shot.path;
  facts[key] = { ...captureFacts(shot.path), appActive: shot.appActive, method: shot.method,
    width: shot.width, height: shot.height };
  return shot;
}

/** Wait until `clipId`'s render has landed and the pane draws the RENDER's
 * line (the brush is refused on an estimate, §5.5). `refuse: false` answers
 * false on a timeout instead of ending the run. */
async function waitForRenderBasis(clipId, { refuse = true } = {}) {
  const deadline = Date.now() + 60_000;
  let basis = "";
  let rendering = true;
  while (Date.now() < deadline) {
    const c = (await must("project.snapshot", {})).tracks.flatMap((t) => t.clips ?? [])
      .find((x) => x.id === clipId);
    rendering = c?.stretchRendering === true;
    basis = (await echo()).playedLine?.basis;
    if (!rendering && basis === "render") return true;
    await sleep(300);
  }
  const why = `the played line never reached the render's basis (basis "${basis}", rendering ${rendering})`;
  if (refuse) refuseRun(why);
  console.log(`  (${why})`);
  return false;
}

/** Wait until the pane shows `clipId` — the echo names it AND every drawn rect
 * is one of ITS notes (a switch rebuilds the pane, and until the new one
 * reports, the rects are the old clip's). The echo, or null on a timeout. */
async function waitForPaneOn(clipId) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const e = await echo();
    const ids = new Set((e.notes ?? []).map((n) => n.id));
    if (e.clipId === clipId && e.chrome?.statusKey === "ready" && e.notesAsDrawn.length > 0
        && e.notesAsDrawn.every((r) => ids.has(r.id))) return e;
    await sleep(250);
  }
  return null;
}

try {
  {
    const f = noteFront("after the launch");
    check("FOCUS — the launch did not take the user's focus (lsappinfo)",
      f.name !== null && f.pid !== null && !stoleFocus(f),
      `frontmost ${front0.name} (pid ${front0.pid}) → ${f.name ?? f.raw} (pid ${f.pid}); staging pid ${session.pid}`);
  }

  // ── a NAMED project of this gate's own; two vocals, both muted
  await must("project.new", { discardChanges: true });
  const track = await must("track.add", { name: "C5b Brush Vocal", kind: "audio" });
  const clip = await must("clip.addAudio", { trackId: track.id, path: fixturePath, atBeat: 0 });
  await must("clip.autoCorrectPitch", { clipId: clip.id });
  await must("track.setMute", { trackId: track.id, muted: true });
  const soundTrack = await must("track.add", { name: "C5b Consonant Vocal", kind: "audio" });
  const soundClip = await must("clip.addAudio", { trackId: soundTrack.id, path: soundFixturePath, atBeat: 0 });
  await must("clip.autoCorrectPitch", { clipId: soundClip.id });
  await must("track.setMute", { trackId: soundTrack.id, muted: true });
  const projectPath = join(OUT, "C5b Brush.dawproj");
  await must("project.save", { path: projectPath });
  console.log(`project: ${projectPath} — clip ${clip.id.slice(0, 8)}, consonant clip ${soundClip.id.slice(0, 8)}`);
  const opened = await must("view.openPitchEditor", { clipId: clip.id });
  if (opened.opened !== true) refuseRun(`view.openPitchEditor did not open: ${opened.reason}`);
  await waitPitchEditorReady(cmd, { timeoutMs: 30_000, intervalMs: 250 });
  await must("transport.stop", {});
  await must("debug.panelLayout", { pitchEditorPPB: PPB });
  await waitForRenderBasis(clip.id);
  await sleep(300);

  // ── which drawn note is which leg: the longest stored note near each leg's pitch
  const midiOf = (hz) => 69 + 12 * Math.log2(hz / 440);
  const pickFrom = (e, hz) => {
    const near = e.notes.filter((n) => n.origin !== "unpitched" && Math.abs(n.sungMidi - midiOf(hz)) < 1);
    near.sort((a, b) => (b.endSeconds - b.startSeconds) - (a.endSeconds - a.startSeconds));
    const n = near[0];
    const rect = n && e.notesAsDrawn.find((r) => r.id === n.id);
    if (!rect) refuseRun(`no drawn note near ${hz} Hz (notes: ${e.notes.map((x) => r3(x.detectedHz)).join(", ")})`);
    return { id: n.id, hz: n.detectedHz, rect };
  };
  const e0 = await echo();
  const A = pickFrom(e0, 220);
  const B = pickFrom(e0, 247);
  const C = pickFrom(e0, 196);
  const rowH = e0.pitchWindow?.rowHeight;
  if (!(typeof rowH === "number" && rowH > 0)) refuseRun(`the pane reported no row height (${JSON.stringify(e0.pitchWindow)})`);
  console.log(`notes: 220→${A.id.slice(0, 8)} 247→${B.id.slice(0, 8)} 196→${C.id.slice(0, 8)} `
    + `(of ${e0.notes.length} stored, ${e0.notesAsDrawn.length} drawn); one semitone = ${r3(rowH)} pt`);
  const centreY = (n) => n.rect.y + n.rect.height / 2;
  const at = (n, fraction) => ({ x: n.rect.x + n.rect.width * fraction, y: centreY(n) });
  /** Scroll so the span [x0, x1] and the note sit in view (content space is
   * unchanged by a scroll; the capture needs it on screen). */
  async function showSpan(n, x0) {
    const e = await echo();
    const wantX = Math.max(0, x0 - 120);
    const wantY = Math.max(0, centreY(n) - e.viewport.viewportH / 2);
    if (Math.abs(e.viewport.offsetX - wantX) > 1 || Math.abs(e.viewport.offsetY - wantY) > 1) {
      await stage({ act: "scroll", x: wantX, y: wantY });
    }
    await sleep(250);
  }
  const storedTable = async (id = clip.id) => (await must("clip.getPitchEdits", { clipId: id })).segments;
  const byId = (segments, id) => segments.find((s) => s.id === id);
  const history = async () => (await must("edit.history", {})).undo;
  const shapeEquals = (stored, drafted) => !!stored && Math.abs(stored.startSeconds - drafted.startSeconds) < EPS
    && Math.abs(stored.stepSeconds - drafted.stepSeconds) < EPS
    && stored.cents.length === drafted.cents.length
    && stored.cents.every((c, i) => Math.abs(c - drafted.cents[i]) < EPS);
  const perNoteLine = (e, id) => (e.playedLine?.perNote ?? []).find((p) => p.id === id);

  // ═════════════════════════════════════════════════════════════════════════
  // 1 — THE BAND: ⌘ over a sung note (and no ⌘ as the control)
  // ═════════════════════════════════════════════════════════════════════════
  const p0 = at(A, 0.35);
  await showSpan(A, p0.x);
  await stage({ act: "tool", tool: "pointer" });
  await stage({ act: "keys", command: false });
  await stage({ act: "hover", ...p0 });
  const plain = await echo();
  check("CONTROL — without ⌘, a hovered sung note shows NO band and the Move tool's own help",
    plain.brush.commandHeld === false && plain.brush.band === null && !/redraw/i.test(plain.interaction.toolHelp),
    `band ${JSON.stringify(plain.brush.band)}; help "${plain.interaction.toolHelp}"`);
  await stage({ act: "keys", command: true });
  await stage({ act: "hover", ...p0 });
  const banded = await echo();
  const band = banded.brush.band;
  check("⭐ with ⌘ held over a sung note: the band, 24 pt wide and centred on the pointer, live (not refused)",
    banded.brush.commandHeld === true && band !== null && band.stroking === false && band.refused === false
      && Math.abs(band.width - 24) < 0.5 && Math.abs(band.centreX - p0.x) < 0.5,
    `band ${JSON.stringify(band)}`);
  check("with ⌘ held the palette draws the BRUSH's help",
    /redraw/i.test(banded.interaction.toolHelp) && banded.interaction.toolHelp !== plain.interaction.toolHelp,
    `help "${banded.interaction.toolHelp}"`);
  await shoot("band", "c5b-1-band-hover.png");
  looks.band = { band, help: banded.interaction.toolHelp };

  // ═════════════════════════════════════════════════════════════════════════
  // 2 — A PEAK PULLED UP, MID-STROKE: a draft, and NOTHING committed
  // ═════════════════════════════════════════════════════════════════════════
  const h0 = await history();
  const t0 = await storedTable();
  const lineBefore = perNoteLine(await echo(), A.id);
  const pressed = await stage({ act: "press", ...p0, command: true });
  // Past the 4 pt slop, then up one semitone and back down: a raised peak.
  const path = [
    [6, 0], [12, -0.35 * rowH], [18, -0.75 * rowH], [24, -1.0 * rowH],
    [30, -0.75 * rowH], [36, -0.35 * rowH], [42, 0],
  ].map(([dx, dy]) => ({ x: p0.x + dx, y: p0.y + dy }));
  for (const p of path) await stage({ act: "drag", ...p, command: true });
  const mid = await echo();
  await shoot("midStroke", "c5b-2-mid-stroke-peak.png");
  const drafted = mid.brush.draft;
  looks.midStroke = { readout: mid.brush.readout, maxExcursionCents: mid.brush.maxExcursionCents,
    help: mid.interaction.toolHelp, dragReadout: mid.interaction.dragReadout,
    draftNotes: drafted.map((d) => d.segmentId.slice(0, 8)) };
  check("the ⌘-press on a note is the BRUSH on that note",
    pressed.press.kind === "brush" && pressed.press.noteId === A.id,
    `press ${pressed.press.kind} on ${pressed.press.noteId?.slice(0, 8)}`);
  check("⭐ mid-stroke: the stroke is live on A, the band follows it, and the pane holds a draft for A",
    mid.brush.stroking === true && mid.brush.pressedNoteId === A.id && mid.brush.band?.stroking === true
      && drafted.some((d) => d.segmentId === A.id),
    `stroking ${mid.brush.stroking}; band ${JSON.stringify(mid.brush.band)}; draft notes `
    + `${JSON.stringify(looks.midStroke.draftNotes)}`);
  check("the palette shows the stroke's readout (SF Mono slot) and the brush's help while drawing",
    /^Drawing · moves the line by up to \d+ cents$/.test(mid.brush.readout)
      && mid.interaction.dragReadout === mid.brush.readout && /redraw/i.test(mid.interaction.toolHelp),
    `readout "${mid.brush.readout}"; palette readout "${mid.interaction.dragReadout}"; help "${mid.interaction.toolHelp}"`);
  const h0mid = await history();
  check("NOTHING is committed while the button is down",
    h0mid.length === h0.length && canon(await storedTable()) === canon(t0), `history ${h0.length}→${h0mid.length}`);

  // ═════════════════════════════════════════════════════════════════════════
  // 3 — THE RELEASE: ONE "Draw Pitch" step; the store holds EXACTLY the draft
  // ═════════════════════════════════════════════════════════════════════════
  const last = path[path.length - 1];
  const rel = await stage({ act: "release", ...last, command: true });
  const h1 = await history();
  const t1 = await storedTable();
  check("⭐ the release commits ONCE: one undo entry, \"Draw Pitch\"",
    rel.lastRelease?.action === "endBrush" && rel.lastRelease?.noteId === A.id
      && h1.length === h0.length + 1 && h1[0] === "Draw Pitch",
    `release ${rel.lastRelease?.action}; history ${h0.length}→${h1.length}; newest "${h1[0]}"`);
  const everyDraftStored = drafted.length > 0
    && drafted.every((d) => shapeEquals(byId(t1, d.segmentId)?.shape, d));
  check("⭐ THE DRAFT IS THE STORED SET: every note the pane drafted at the last tick is stored sample for sample "
    + "(read back over the wire)", everyDraftStored,
    drafted.map((d) => {
      const s = byId(t1, d.segmentId)?.shape;
      return `${d.segmentId.slice(0, 8)}: draft ${d.cents.length} @ ${r3(d.startSeconds)} vs stored `
        + `${s?.cents?.length} @ ${r3(s?.startSeconds)}`;
    }).join("; "));
  const untouched = t0.filter((s) => !drafted.some((d) => d.segmentId === s.id));
  check("notes the stroke did not draft keep their drawing",
    untouched.every((s) => canon(s.shape) === canon(byId(t1, s.id)?.shape)),
    `${untouched.length} other note(s) compared`);
  check("POSITIVE CONTROL for the table comparator: the stroke's table compares DIFFERENT",
    canon(t1) !== canon(t0), "canon(after release) vs canon(before)");
  const storedA = byId(t1, A.id)?.shape?.cents ?? [];
  const largest = storedA.reduce((m, c) => Math.max(m, Math.abs(c)), 0);
  const priorA = byId(t0, A.id)?.shape?.cents ?? [];
  check("the readout's number is the store's: A had no drawing, so its largest stored sample IS the stroke's "
    + "largest change (and the SF Mono line rounds it to 5 cents)",
    priorA.length === 0 && Math.abs(largest - mid.brush.maxExcursionCents) <= 0.1 + EPS
      && mid.brush.readout === `Drawing · moves the line by up to ${Math.round(Math.round(mid.brush.maxExcursionCents / 5) * 5)} cents`,
    `stored max |cents| ${r3(largest)} vs maxExcursionCents ${r3(mid.brush.maxExcursionCents)}; readout "${mid.brush.readout}"`);
  // The pane resyncs from the store and redraws the line; an edit re-renders
  // the clip, so wait for the RENDER's line again before reading it.
  await sleep(400);
  await waitForRenderBasis(clip.id);
  const after = await echo();
  const lineAfter = perNoteLine(after, A.id);
  check("⭐ the peak is IN THE LINE the pane draws after the release: A's highest point rose",
    typeof lineBefore?.maxMidi === "number" && typeof lineAfter?.maxMidi === "number"
      && lineAfter.maxMidi > lineBefore.maxMidi + 0.2,
    `A's line max ${r3(lineBefore?.maxMidi)} → ${r3(lineAfter?.maxMidi)} midi `
    + `(pulled to ~${r3((lineBefore?.medianMidi ?? NaN) + 1)})`);
  check("after the release the stroke and its draft are gone (the line is the STORE's now)",
    after.brush.stroking === false && after.brush.draft.length === 0,
    `stroking ${after.brush.stroking}; draft ${after.brush.draft.length}`);
  await stage({ act: "keys", command: false });
  await stage({ act: "hover", ...p0 });
  await shoot("afterRelease", "c5b-3-after-release.png");
  looks.afterRelease = { lineBefore, lineAfter, history: h1.slice(0, 2) };

  // ═════════════════════════════════════════════════════════════════════════
  // 4 — UNDO RESTORES THE TABLE EXACTLY
  // ═════════════════════════════════════════════════════════════════════════
  await must("edit.undo", {});
  await sleep(400);
  await waitForRenderBasis(clip.id);   // the next stroke is refused on an estimate
  const t2 = await storedTable();
  check("Undo restores the table EXACTLY (every note, every field)", canon(t2) === canon(t0),
    `A's samples after undo ${byId(t2, A.id)?.shape?.cents?.length}; table ${canon(t2) === canon(t0) ? "identical" : "DIFFERENT"}`);
  await stage({ act: "hover", ...p0 });
  await shoot("afterUndo", "c5b-4-after-undo.png");
  const undone = perNoteLine(await echo(), A.id);
  looks.afterUndo = { line: undone };
  check("after Undo the pane's line over A is the line from before the stroke",
    typeof undone?.maxMidi === "number" && Math.abs(undone.maxMidi - lineBefore.maxMidi) < 1e-6,
    `A's line max ${r3(lineBefore?.maxMidi)} → (stroke) ${r3(lineAfter?.maxMidi)} → (undo) ${r3(undone?.maxMidi)}`);
  await sleep(900);   // past the journal's 800 ms fold, so the next stroke is its own step

  // ═════════════════════════════════════════════════════════════════════════
  // 5 — ONE STROKE ACROSS TWO NOTES IS STILL ONE UNDO STEP
  // ═════════════════════════════════════════════════════════════════════════
  {
    const start = at(A, 0.9);
    const endB = at(B, 0.15);
    await showSpan(A, start.x);
    const hA = await history();
    const tA = await storedTable();
    await stage({ act: "keys", command: true });
    await stage({ act: "press", ...start, command: true });
    const steps = 8;
    for (let i = 1; i <= steps; i++) {
      const f = i / steps;
      await stage({ act: "drag", x: start.x + (endB.x - start.x) * f,
        y: start.y + (endB.y - start.y) * f - 0.5 * rowH, command: true });
    }
    const across = await echo();
    const draftIds = across.brush.draft.map((d) => d.segmentId);
    const relAB = await stage({ act: "release", x: endB.x, y: endB.y - 0.5 * rowH, command: true });
    const hB = await history();
    const tB = await storedTable();
    check("⭐ a stroke across TWO notes drafts both and is ONE undo step, every drafted note stored as drafted",
      draftIds.includes(A.id) && draftIds.includes(B.id) && relAB.lastRelease?.action === "endBrush"
        && hB.length === hA.length + 1 && hB[0] === "Draw Pitch"
        && across.brush.draft.every((d) => shapeEquals(byId(tB, d.segmentId)?.shape, d)),
      `draft notes ${JSON.stringify(draftIds.map((id) => id.slice(0, 8)))}; history ${hA.length}→${hB.length} `
      + `("${hB[0]}")`);
    await must("edit.undo", {});
    await sleep(400);
    await waitForRenderBasis(clip.id);
    check("one Undo takes the whole two-note stroke back", canon(await storedTable()) === canon(tA), "table compared whole");
    await stage({ act: "keys", command: false });
  }
  await sleep(900);

  // ═════════════════════════════════════════════════════════════════════════
  // 6 — ESCAPE MID-STROKE: NOTHING COMMITTED
  // ═════════════════════════════════════════════════════════════════════════
  {
    const s = at(C, 0.4);
    await showSpan(C, s.x);
    const hC = await history();
    const tC = await storedTable();
    await stage({ act: "keys", command: true });
    await stage({ act: "press", ...s, command: true });
    for (const [dx, dy] of [[6, 0], [14, -0.6 * rowH], [22, -0.9 * rowH]]) {
      await stage({ act: "drag", x: s.x + dx, y: s.y + dy, command: true });
    }
    const live = await echo();
    await stage({ act: "escape" });
    await sleep(150);
    const dropped = await echo();
    const releaseAfter = dropped.press?.inFlight === true
      ? await stage({ act: "release", x: s.x + 22, y: s.y - 0.9 * rowH, command: true }) : null;
    const hD = await history();
    check("⭐ Escape mid-stroke drops it: the draft goes, the rest of the gesture does nothing, nothing is committed",
      live.brush.stroking === true && live.brush.draft.length > 0
        && dropped.brush.stroking === false && dropped.brush.draft.length === 0
        && hD.length === hC.length && canon(await storedTable()) === canon(tC),
      `before Escape: stroking ${live.brush.stroking}, draft ${live.brush.draft.length}; after: stroking `
      + `${dropped.brush.stroking}, draft ${dropped.brush.draft.length}; release `
      + `${releaseAfter?.lastRelease?.action ?? "(press already over)"}; history ${hC.length}→${hD.length}`);
    await stage({ act: "keys", command: false });
  }

  // ═════════════════════════════════════════════════════════════════════════
  // 7 — A BREATH OR CONSONANT IS REFUSED IN WORDS (second vocal)
  // ═════════════════════════════════════════════════════════════════════════
  {
    const openedSound = await must("view.openPitchEditor", { clipId: soundClip.id });
    if (openedSound.opened !== true) throw new Error(`view.openPitchEditor (consonant clip): ${openedSound.reason}`);
    const shown = await waitForPaneOn(soundClip.id);
    const rendered = shown ? await waitForRenderBasis(soundClip.id, { refuse: false }) : false;
    await sleep(300);
    const es = await echo();
    const soundNote = shown && rendered ? es.notes.find((n) => n.origin === "unpitched") : null;
    const soundRect = soundNote && es.notesAsDrawn.find((r) => r.id === soundNote.id);
    if (!soundRect) {
      const why = !shown ? "the pane never showed the consonant vocal"
        : !rendered ? "the consonant vocal's line never reached the render's basis"
          : `the consonant vocal's table holds no drawn sound (${es.notes.length} stored: `
            + `${es.notes.map((n) => n.origin).join(", ")})`;
      console.log(`  NOT RUN — the sound leg: ${why}. The refusal is covered in-process by `
        + "`aStrokeOnASoundIsRefused` (PitchEditorModelTests); this leg PROVES NOTHING on this run.");
      looks.sound = { notRun: true, why, origins: es.notes.map((n) => n.origin) };
    } else {
      const S = { id: soundNote.id, rect: soundRect };
      const sp = { x: S.rect.x + S.rect.width / 2, y: centreY(S) };
      await showSpan(S, sp.x);
      const hS = await history();
      const tS = await storedTable(soundClip.id);
      await stage({ act: "keys", command: true });
      await stage({ act: "hover", ...sp });
      const over = await echo();
      check("⭐ with ⌘ over a SOUND the band is REFUSED and says why, in the palette too",
        over.brush.band?.refused === true && typeof over.brush.band?.refusal === "string"
          && over.interaction.toolHelp === over.brush.band.refusal,
        `band ${JSON.stringify(over.brush.band)}; help "${over.interaction.toolHelp}"`);
      await shoot("soundRefused", "c5b-5-sound-refused-band.png");
      await stage({ act: "press", ...sp, command: true });
      for (const [dx, dy] of [[6, 0], [12, -0.5 * rowH]]) {
        await stage({ act: "drag", x: sp.x + dx, y: sp.y + dy, command: true });
      }
      const refused = await echo();
      const relS = await stage({ act: "release", x: sp.x + 12, y: sp.y - 0.5 * rowH, command: true });
      const hS2 = await history();
      check("a stroke begun on the sound draws nothing: the refusal line says why, no draft, no commit",
        refused.brush.stroking === false && refused.interaction.refusalText === over.brush.band.refusal
          && relS.lastRelease?.action === "nothing" && hS2.length === hS.length
          && canon(await storedTable(soundClip.id)) === canon(tS),
        `stroking ${refused.brush.stroking}; refusal "${refused.interaction.refusalText}"; release `
        + `${relS.lastRelease?.action}; history ${hS.length}→${hS2.length}`);
      looks.sound = { refusal: over.brush.band?.refusal, help: over.interaction.toolHelp };
      await stage({ act: "keys", command: false });
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // THE CAPTURES THEMSELVES: none blank, none stale, none taken ACTIVE
  // ═════════════════════════════════════════════════════════════════════════
  for (const [key, f] of Object.entries(facts)) {
    const measured = typeof f.ymin === "number" && typeof f.ymax === "number";
    check(`capture ${key}: exists, NOT BLANK (luma range measured), taken with the app INACTIVE`,
      f.exists === true && measured && f.ymax - f.ymin >= 32 && f.appActive === false,
      `${captures[key]} — ${f.width}×${f.height} ${f.method}; luma ${f.ymin}–${f.ymax} (avg ${f.yavg}); `
      + `appActive ${f.appActive}; sha ${f.sha}`);
  }
  const order = ["band", "midStroke", "afterRelease", "afterUndo"];
  for (let i = 1; i < order.length; i++) {
    const a = facts[order[i - 1]];
    const b = facts[order[i]];
    check(`capture ${order[i]} is NOT a stale copy of ${order[i - 1]} (the states differ, so must the bytes)`,
      !!a?.sha && !!b?.sha && a.sha !== b.sha, `${a?.sha} vs ${b?.sha}`);
  }
  {
    const f = noteFront("after the last capture");
    check("FOCUS — after every step and capture the user's frontmost app is still not staging (lsappinfo)",
      f.name !== null && f.pid !== null && !stoleFocus(f), `frontmost ${front0.name} (pid ${front0.pid}) → ${f.name ?? f.raw} (pid ${f.pid}); staging pid ${session.pid}`);
  }
  writeFileSync(join(OUT, "c5b-looks.json"), JSON.stringify({ captures, facts, looks, fronts }, null, 2));
  console.log(`captures: ${Object.values(captures).join("  ")}`);
  console.log(`looks: ${join(OUT, "c5b-looks.json")}`);
} catch (err) {
  console.log(`ERROR: ${err?.stack ?? err}`);
  exitCode = 2;
} finally {
  clearTimeout(killer);
  try { session.ws.close(); } catch { /* ignore */ }
  stopLook(GATE);
  console.log("staging stopped (pidfile-exact)");
}
{
  // The window went with the process: the pid must be gone (signal 0 probes
  // it). `stopLook` sends SIGTERM and returns at once, so poll (≤ 5 s); the
  // event loop running between polls is also what reaps the child.
  let alive = true;
  for (let i = 0; i < 50 && alive; i++) {
    await sleep(100);
    try { process.kill(session.pid, 0); } catch { alive = false; }
  }
  check("NO WINDOW LEFT — the staging process (and so its window) is gone after the stop",
    alive === false, `pid ${session.pid} ${alive ? "STILL ALIVE" : "gone"}`);
  const f = noteFront("after the stop");
  check("FOCUS — after the stop the frontmost app is not staging and not a stray Finder window (lsappinfo)",
    f.name !== null && f.pid !== null && !stoleFocus(f), `frontmost ${front0.name} (pid ${front0.pid}) → ${f.name ?? f.raw} (pid ${f.pid}); staging pid ${session.pid}`);
  console.log(`frontmost: ${fronts.map((x) => `${x.at}: ${x.name} (pid ${x.pid})`).join(" · ")}`);
}
{
  const LOG = join(process.env.HOME ?? "", "Library/Logs/DAWPro/main-actor-wedge.log");
  let text = null;
  try { text = readFileSync(LOG, "utf8"); } catch (e) { console.log(`wedge log: unreadable (${e.code}) — ${LOG}`); }
  if (text !== null) {
    const mine = text.split("\n").filter((l) => l.includes(` pid=${session.pid} `));
    console.log(`wedge log: ${mine.length} line(s) from staging pid ${session.pid}`
      + (mine.length ? `\n        ${mine.join("\n        ")}` : ""));
  }
}
if (exitCode !== null) process.exit(exitCode);
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
