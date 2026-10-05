// m23-ap I5 GATE — PLACE AND DRAG THE PLAYHEAD in the pitch (note) editor, and
// FOLLOW it during playback, against a REAL app on staging (port 17695 ONLY;
// 17600 is the user's LIVE app and is never touched. Staging is stopped
// PIDFILE-EXACT through `_pitch-editor-look.mjs`'s `stopLook`, never pkill/pgrep).
//
// ⭐ A SPY GATE, NOT A SOURCE-SHAPE GATE. The pane's seek is
// `{ beats in _ = try? store.seek(toBeats: beats) }` — a `try?` that would pass
// silently if the seek never happened. So every placement leg reads the
// TRANSPORT back over the wire (`project.snapshot` → `transport.positionBeats`,
// an instrument independent of anything the pane reports) and requires it to
// equal BOTH what the pane's model asked for (`debug.pitchEditor`'s
// `playhead.lastPlacementBeat`) AND the gate's OWN arithmetic from the echoed
// geometry — three instruments, never one.
//
// WHAT THIS PROVES
//   • the TIME RULER (`{act:"ruler", x}`, the ruler's own tick function):
//     click jumps, a scrub is one seek per tick, ⌥ bypasses the snap, the snap
//     lands on the SONG's 1/16 (I5-F1, 2026-09-25 — the clip starts at beat
//     3.1, OFF that grid and off a bar line, so the old clip-local snap lands
//     0.1 beat away and is caught), a tick past the clip clamps to its end,
//     and SNAP: OFF (Pro arrange + the app's clip snap off) places anywhere;
//   • I5-F1 — the ruler NUMBERS THE SONG'S BARS: its first bar label is the
//     song's "2" at 0.9 beat into the clip (clip-local numbering said "1" at
//     x 0), a click on the "5" tick puts the transport at "5.1", and wherever
//     the playhead is the ruler's last bar at or before it is the transport's
//     bar. The labels are the echo's (`playhead.ruler`, the band's own
//     function over the band's own inputs — a re-derivation, not pixels);
//     `transportReadout` is the string the transport bar draws. The capture
//     is what shows the band drew them;
//   • the SCROLLED ruler: with the view scrolled, a ruler-local x lands at x +
//     offset — the ONE place the offset is added. The UNSCROLLED leg is the
//     control that shows why the scrolled one discriminates (at offset 0 a
//     dropped offset is invisible);
//   • ⌘-CLICK on empty surface (staged press/release with command:true) seeks
//     once at the press point in CONTENT space — no offset added on that path —
//     and keeps the selection; a PLAIN click on empty seeks nothing;
//   • REFUSALS: a ruler tick mid-press, with a y, or with no x is an error;
//   • FOLLOW: with the ONE flag on and the transport playing, a live PINCH
//     stands follow down (no page turn, no suspension); once it ends, follow
//     turns the page; a simulated pointer scroll SUSPENDS it
//     (`debug.followPlayhead {simulateUserScroll, surface:"pitchEditor"}`), the
//     echo shows it, and `rearm` clears it. I5-F1-F: each of these waits on the
//     CONDITION that lets it discriminate (follow DUE, inside the clip, for a
//     stretch of transport), never on a sleep. It is red only when follow had
//     that chance and did the wrong thing, and INCONCLUSIVE (exit 2) when it
//     never got one, or when the window was not being drawn.
//
// WHAT THIS DOES NOT PROVE
//   • a REAL mouse on the ruler or a real ⌘ press (m23-g1: nothing in this tree
//     drives a real pointer), nor the ⌘-hover cursor and ghost line (a
//     `.flagsChanged` monitor no staged step can reach);
//   • motion: `view.capture` runs at ~3.5 fps and cannot film a page turn.
//
// PROVENANCE — as in `m23ap-i2-pitch-pinch.mjs`: the look harness launches
// with `skipBuild`, so this gate proves `.build/debug/DAWApp` is newer than
// every file under `Sources/` and `Package.swift` first (with a positive
// control on the same `find`), and refuses (exit 2) otherwise.
//
// AUDIO — the vocal's track is MUTED before anything plays: the follow legs
// run the real transport, and a gate has no business making sound.
//
//   node scripts/gates/m23ap-i5-playhead.mjs
//
// Env: M23AP_I5_OUT (captures, fixture, the named project; default
//      /tmp/m23ap-i5). M23AP_I5_EXPECT_PLANT=1 inverts nothing — it only labels
//      the run, so a planted build's log says what it is. M23AP_I5_BINARY=<abs>
//      runs a PLANTED scratch copy of the binary (with its bundles beside it)
//      instead of `.build/debug/DAWApp`, and skips provenance. It is refused
//      unless the run is labelled planted.
//
// EXIT: 0 green, 1 red, 2 proves nothing. That covers a refused precondition,
//      and FOLLOW legs that never got their chance or ran with the window not
//      drawn. A red outside the follow legs still exits 1.
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ROOT, DEFAULT_BINARY, verdict, sleep, panelDensityGuard } from "./_staging.mjs";
import {
  synthesizeVocalFixture, launchLook, stopLook, makeCmd, waitPitchEditorReady,
  stagePitchEditorStep, captureLook,
} from "./_pitch-editor-look.mjs";

const GATE = "m23ap-i5";
const OUT = process.env.M23AP_I5_OUT || "/tmp/m23ap-i5";
mkdirSync(OUT, { recursive: true });
if (process.env.M23AP_I5_EXPECT_PLANT === "1") console.log("RUN LABEL: a PLANTED build — red legs are the point");

const CLIP_START = 3.1;     // OFF the 1/16 grid AND a bar line on purpose (see the header)
const P0 = 64;              // the scale every placement leg runs at
const GRID = 0.25;          // a sixteenth note = a quarter beat (`PitchEditorModel.placementGrid`)
const EPS = 1e-6;

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
/** The FOLLOW legs' checks, kept apart: they are the ones a window that is
 * not drawn cannot vouch for (I5-F1-F), so their verdict can be withheld. */
const followCheckNames = new Set();
const fcheck = (name, ok, detail) => { followCheckNames.add(name); check(name, ok, detail); };
/** Why the FOLLOW legs proved nothing this run (empty = they did). */
const followInconclusive = [];
const r3 = (v) => (typeof v === "number" ? Math.round(v * 1000) / 1000 : v);
function refuseRun(reason) {
  console.log(`ABORT (proves nothing): ${reason}`);
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}

// ═══════════════════════════════════════════════════════════════════════════
// PROVENANCE
// ═══════════════════════════════════════════════════════════════════════════
// A PLANTED binary (M23AP_I5_BINARY, a scratch copy built with a defect in and
// the source restored at once) is older than the restored source by
// construction, so the check below cannot hold for it. It is skipped only
// when the run is LABELLED as planted.
const PLANT_BINARY = process.env.M23AP_I5_BINARY || null;
if (PLANT_BINARY && process.env.M23AP_I5_EXPECT_PLANT !== "1") {
  refuseRun("M23AP_I5_BINARY is for planted builds only — set M23AP_I5_EXPECT_PLANT=1 with it");
}
if (PLANT_BINARY) {
  console.log(`provenance: SKIPPED for the PLANTED binary ${PLANT_BINARY} — this run proves only that the plant goes red`);
} else {
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

// A 12-note sung fixture (~17 s = ~34 beats at 120): at 64 pt/beat the content
// (~2200 pt) is wider than the pane, so the scrolled legs have room.
const SCALE_HZ = [196, 220, 247, 262, 294, 330, 349, 392];
const LEGS = Array.from({ length: 12 }, (_, i) => ({ hz: SCALE_HZ[i % SCALE_HZ.length], seconds: 1.4 }));
const fixturePath = synthesizeVocalFixture(OUT, { notes: LEGS });
const silentPath = synthesizeVocalFixture(OUT, { silent: true });

const killer = setTimeout(() => {
  console.log("TIMEOUT — 10 minutes");
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}, 600_000);

const session = await launchLook({ gate: GATE, settleMs: 1500, ...(PLANT_BINARY ? { binary: PLANT_BINARY } : {}) });
console.log(`staging pid ${session.pid} (skipBuild — ${PLANT_BINARY ? "PLANTED binary" : "provenance proved above"}); `
  + `started ${new Date().toISOString()}`);
const cmd = makeCmd(session.ws);
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (!r || r.ok !== true) throw new Error(`${command} failed — ${JSON.stringify(r?.error ?? r)}`);
  return r.result;
}
const echo = () => must("debug.pitchEditor", {});
/** The transport's position, from the PROJECT — not from the pane's echo. */
async function transportBeats() {
  const snap = await must("project.snapshot", {});
  const beats = snap?.transport?.positionBeats;
  if (typeof beats !== "number") {
    throw new Error(`project.snapshot has no transport.positionBeats (transport keys: `
      + `${Object.keys(snap?.transport ?? {}).join(",")})`);
  }
  return beats;
}
const guard = panelDensityGuard(cmd);

let exitCode = null;
const captures = {};
try {
  // ── a NAMED project of this gate's own; the vocal at beat 3.1, muted
  await must("project.new", { discardChanges: true });
  const track = await must("track.add", { name: "I5 Vocal", kind: "audio" });
  const clip = await must("clip.addAudio", { trackId: track.id, path: fixturePath, atBeat: CLIP_START });
  await must("clip.autoCorrectPitch", { clipId: clip.id });
  await must("track.setMute", { trackId: track.id, muted: true });
  const projectPath = join(OUT, "2026-09-25 I5 Playhead Gate.dawproj");
  await must("project.save", { path: projectPath });
  const snap0 = await must("project.snapshot", {});
  const clip0 = snap0.tracks.flatMap((t) => t.clips ?? []).find((c) => c.id === clip.id);
  if (!clip0) refuseRun("the imported clip is not in the snapshot");
  if (Math.abs(clip0.startBeat - CLIP_START) > EPS) refuseRun(`clip landed at ${clip0.startBeat}, not ${CLIP_START}`);
  const LEN = clip0.lengthBeats;
  // I5-F1: the ruler legs count SONG bars in 4/4 from beat 0 — the gate's own
  // arithmetic (`songBar`) holds only for that meter, so say so if it changes.
  const ts = snap0.transport?.timeSignature;
  if (ts?.beatsPerBar !== 4) refuseRun(`the new project's meter is ${JSON.stringify(ts)}, not 4/4`);
  console.log(`project: ${projectPath} — clip ${clip.id.slice(0, 8)} at beat ${clip0.startBeat}, ${r3(LEN)} beats`);
  const opened = await must("view.openPitchEditor", { clipId: clip.id });
  if (opened.opened !== true) refuseRun(`view.openPitchEditor did not open: ${opened.reason}`);
  await waitPitchEditorReady(cmd, { timeoutMs: 30_000, intervalMs: 250 });
  // WAIT FOR THE TUNED CLIP'S RENDER TO LAND before any staged ruler tick —
  // these legs are about placement, not render timing, and the wait says so if
  // it never lands.
  // ⚠️ CORRECTED 2026-09-25: this wait was added believing a render landing
  // DROPPED staged ruler ticks (a probe lost 1 of 30 with the render in
  // flight). It did not fix the drop — the gate still lost its 5th scrub tick
  // with it. The measured cause was the staging tier skipping its SECOND CLOCK
  // for ruler ticks, which let the next tick be staged 7–11 ms after the last;
  // with the clock restored, 0 of 90 back-to-back ticks dropped (the comment
  // at `drawDeadline` in PitchEditorDebugStaging.swift), including while a
  // render was still in flight. The render was not the cause; the note stays
  // as a warning against reading one correlated probe as a mechanism.
  {
    const deadline = Date.now() + 45_000;
    let rendering = true;
    while (rendering && Date.now() < deadline) {
      const c = (await must("project.snapshot", {})).tracks.flatMap((t) => t.clips ?? [])
        .find((x) => x.id === clip.id);
      rendering = c?.stretchRendering === true;
      if (rendering) await sleep(250);
    }
    if (rendering) refuseRun("the tuned clip's render never landed within 45 s");
  }
  await must("transport.stop", {});
  await must("debug.panelLayout", { pitchEditorPPB: P0 });
  await sleep(300);

  /** The gate's OWN placement arithmetic, from the fixture's facts — never
   * the app's. Content x → PROJECT beat → the SONG's 1/16 (from beat 0)
   * unless unsnapped → clamped to the clip (I5-F1; I5 snapped clip-local). */
  const expectPlacement = (contentX, { snap = true, ppb = P0, start = CLIP_START, len = LEN } = {}) => {
    const project = start + contentX / ppb;
    const placed = snap ? Math.max(0, Math.round(project / GRID) * GRID) : project;
    return Math.min(Math.max(placed, start), start + len);
  };
  /** The song's 1-based bar number at a project beat, 4/4 from beat 0 (the
   * fixture's meter — asserted from the snapshot below). */
  const songBar = (beat) => Math.floor(beat / 4 + 1e-9) + 1;
  /** Scroll the pane (its own writer) and wait until two reads agree. */
  async function scrollTo(x) {
    await stagePitchEditorStep(cmd, { act: "scroll", x });
    let prev = await echo();
    for (let i = 0; i < 40; i++) {
      await sleep(50);
      const next = await echo();
      if (next.viewport.offsetX === prev.viewport.offsetX) return next;
      prev = next;
    }
    return prev;
  }
  /** One ruler tick, then the three instruments. */
  async function rulerLeg(name, rulerX, { option = false, snap = true, expectOffset } = {}) {
    const before = await echo();
    const offset = before.viewport.offsetX;
    if (expectOffset !== undefined && Math.abs(offset - expectOffset) > 0.5) {
      check(`${name}: precondition — the view sits at offset ${expectOffset}`, false, `offsetX ${offset}`);
      return null;
    }
    const stage = await stagePitchEditorStep(cmd, option ? { act: "ruler", x: rulerX, option: true }
                                                        : { act: "ruler", x: rulerX });
    const after = await echo();
    const wire = await transportBeats();
    const want = expectPlacement(rulerX + offset, { snap: snap && !option, ppb: before.zoom.pixelsPerBeat });
    const asked = after.playhead.lastPlacementBeat;
    check(`${name}: the transport (read back over the wire) is where the ruler placed it`,
      Math.abs(wire - want) < 1e-3 && Math.abs(asked - want) < EPS
        && after.playhead.placementCount === before.playhead.placementCount + 1,
      `ruler x ${rulerX} + offset ${r3(offset)} → want ${r3(want)}; model asked ${r3(asked)}; `
      + `transport ${r3(wire)}; placements ${before.playhead.placementCount}→${after.playhead.placementCount}; `
      + `stage ${stage.stage?.act}`);
    return { before, after, wire, want, offset };
  }

  // ═════════════════════════════════════════════════════════════════════════
  // THE RULER
  // ═════════════════════════════════════════════════════════════════════════
  await scrollTo(0);
  const R = 300.3;   // ruler-local x, nowhere near a grid midpoint at 64 pt/beat
  const unscrolled = await rulerLeg("UNSCROLLED ruler click (the control)", R, { expectOffset: 0 });
  captures.unscrolled = (await captureLook(cmd, join(OUT, "i5-1-ruler-unscrolled-ppb64.png"))).path;

  const O = 700;
  const scrolledEcho = await scrollTo(O);
  const scrolled = await rulerLeg("⭐ SCROLLED ruler click (offset added in ONE place)", R, { expectOffset: O });
  if (scrolled && unscrolled) {
    check("the scrolled leg DISCRIMINATES: a dropped offset would have landed the unscrolled beat",
      Math.abs(scrolled.want - unscrolled.want) > 1,
      `scrolled ${r3(scrolled.want)} vs unscrolled ${r3(unscrolled.want)} (offset ${r3(scrolledEcho.viewport.offsetX)})`);
  }
  const bypass = await rulerLeg("⌥ ruler click bypasses the snap (scrolled)", R, { option: true });
  if (bypass) {
    check("⌥ really landed OFF the grid (the snapped and the free placement differ)",
      Math.abs(bypass.want - expectPlacement(R + bypass.offset)) > EPS,
      `free ${r3(bypass.want)} vs snapped ${r3(expectPlacement(R + bypass.offset))}`);
  }
  // A scrub: several ticks, one seek each, the last one wins.
  {
    const xs = [100.2, 180.7, 260.1, 340.9, 420.4];
    const before = await echo();
    for (const x of xs) await stagePitchEditorStep(cmd, { act: "ruler", x });
    const after = await echo();
    const wire = await transportBeats();
    const want = expectPlacement(xs[xs.length - 1] + before.viewport.offsetX);
    check("a SCRUB is one seek per tick, and the transport ends on the last",
      after.playhead.placementCount === before.playhead.placementCount + xs.length
        && Math.abs(wire - want) < 1e-3,
      `placements +${after.playhead.placementCount - before.playhead.placementCount} `
      + `(want ${xs.length}); transport ${r3(wire)}, want ${r3(want)}`);
  }
  // Past the clip's end: clamps to it.
  {
    await stagePitchEditorStep(cmd, { act: "ruler", x: 99_999 });
    const wire = await transportBeats();
    check("a tick past the clip clamps to the clip's END",
      Math.abs(wire - (CLIP_START + LEN)) < 1e-3, `transport ${r3(wire)}, want ${r3(CLIP_START + LEN)}`);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // I5-F1 — THE RULER NUMBERS THE SONG'S BARS (the vocal starts at 3.1: inside
  // song bar 1, so the clip's first bar line is the song's bar 2, 0.9 beat in)
  // ═════════════════════════════════════════════════════════════════════════
  {
    const at = await scrollTo(0);
    const ppb = at.zoom.pixelsPerBeat;
    const ruler = at.playhead.ruler;
    const bars = (ruler?.labels ?? []).filter((l) => l.isBar);
    const first = bars[0];
    check("⭐ I5-F1 — the ruler's first bar label is the SONG's \"2\", 0.9 beat into the clip (clip-local numbering said \"1\" at x 0)",
      ruler?.numbering === "song" && first?.text === "2" && Math.abs(first.x - (4 - CLIP_START) * ppb) < 1e-6
        && !bars.some((l) => l.text === "1"),
      `numbering ${ruler?.numbering}; bar labels ${bars.slice(0, 5).map((l) => `${l.text}@${r3(l.x)}`).join(" ")} `
      + `(want 2@${r3((4 - CLIP_START) * ppb)})`);
    const five = bars.find((l) => l.text === "5");
    if (!five) {
      check("I5-F1 — the ruler labels song bar 5", false, `bar labels ${bars.map((l) => l.text).join(",")}`);
    } else {
      // A click ON the "5" tick (ruler-local = content x − offset 0).
      await stagePitchEditorStep(cmd, { act: "ruler", x: five.x - at.viewport.offsetX });
      const e = await echo();
      const wire = await transportBeats();
      check("⭐ I5-F1 — a click on the ruler's \"5\" puts the transport ON song bar 5: it reads \"5.1\"",
        Math.abs(wire - 16) < 1e-3 && e.playhead.transportReadout === "5.1",
        `tick "5" at x ${r3(five.x)} → transport ${r3(wire)}, readout "${e.playhead.transportReadout}"`);
    }
    // Between bar lines: the ruler's last bar at or before the playhead is
    // the transport's bar — three instruments (the echo's labels, the string
    // the transport bar draws, the gate's own 4/4 arithmetic).
    for (const target of [9.3, 22.85, 15.6]) {   // 15.6 last: the looked-at "4.4" case
      const rx = (target - CLIP_START) * ppb - at.viewport.offsetX;
      await stagePitchEditorStep(cmd, { act: "ruler", x: rx });
      const e = await echo();
      const wire = await transportBeats();
      const lastBar = (e.playhead.ruler?.labels ?? []).filter((l) => l.isBar && l.x <= e.playhead.x + 1e-6).pop();
      const readoutBar = String(e.playhead.transportReadout ?? "").split(".")[0];
      check(`I5-F1 — at song beat ~${target}, the ruler's bar under the playhead is the transport's bar`,
        lastBar?.text === readoutBar && readoutBar === String(songBar(wire)),
        `transport ${r3(wire)} reads "${e.playhead.transportReadout}"; ruler's last bar at or before x `
        + `${r3(e.playhead.x)} is "${lastBar?.text}" at ${r3(lastBar?.x)}; 4/4 arithmetic says bar ${songBar(wire)}`);
    }
    captures.songBars = (await captureLook(cmd, join(OUT, "i5-8-ruler-song-bars-ppb64.png"))).path;
  }

  // ═════════════════════════════════════════════════════════════════════════
  // ⌘-CLICK ON EMPTY SURFACE — content space, no offset on this path
  // ═════════════════════════════════════════════════════════════════════════
  const view = await scrollTo(O);
  const px = view.viewport.offsetX + 450.6;   // CONTENT x, inside the visible pane
  const clearOf = (e, y) => e.notesAsDrawn.every((n) =>
    px < n.x - 12 || px > n.x + n.width + 12 || y < n.y - 24 || y > n.y + n.height + 24);
  let py = null;
  for (let y = 6; y < view.viewport.contentH - 6; y += 6) { if (clearOf(view, y)) { py = y; break; } }
  if (py === null) refuseRun(`no empty surface point at content x ${r3(px)} for the ⌘-click legs`);
  await stagePitchEditorStep(cmd, { act: "selectAll" });
  {
    const before = await echo();
    await stagePitchEditorStep(cmd, { act: "press", x: px, y: py, command: true });
    const released = await stagePitchEditorStep(cmd, { act: "release", x: px, y: py, command: true });
    const after = await echo();
    const wire = await transportBeats();
    const want = expectPlacement(px);                    // content space: NO offset
    const withOffset = expectPlacement(px + before.viewport.offsetX);
    check("⭐ ⌘-click on empty surface seeks ONCE, at the click's CONTENT x (no offset on the grid path)",
      released.lastRelease?.click === "positionPlayhead"
        && after.playhead.placementCount === before.playhead.placementCount + 1
        && Math.abs(wire - want) < 1e-3 && Math.abs(after.playhead.lastPlacementBeat - want) < EPS,
      `click ${released.lastRelease?.action}/${released.lastRelease?.click}; want ${r3(want)} `
      + `(an offset added here would give ${r3(withOffset)}); model asked `
      + `${r3(after.playhead.lastPlacementBeat)}; transport ${r3(wire)}; placements `
      + `${before.playhead.placementCount}→${after.playhead.placementCount}`);
    check("⌘-click on empty KEEPS the selection (the click table sends it to the playhead, not to deselect)",
      before.selection.count > 0 && after.selection.count === before.selection.count,
      `selection ${before.selection.count} → ${after.selection.count}`);
    check("the playhead the echo draws is where the transport is (placed through the pane's geometry)",
      after.playhead.insideClip === true
        && Math.abs(after.playhead.x - (wire - CLIP_START) * after.zoom.pixelsPerBeat) < 0.01,
      `playhead.x ${r3(after.playhead.x)}, from the transport ${r3((wire - CLIP_START) * after.zoom.pixelsPerBeat)}; `
      + `screenX ${r3(after.playhead.screenX)}; insideClip ${after.playhead.insideClip}`);
  }
  {
    const before = await echo();
    const wireBefore = await transportBeats();
    await stagePitchEditorStep(cmd, { act: "press", x: px, y: py });
    const released = await stagePitchEditorStep(cmd, { act: "release", x: px, y: py });
    const after = await echo();
    const wire = await transportBeats();
    check("a PLAIN click on empty surface seeks nothing (and deselects, as before)",
      after.playhead.placementCount === before.playhead.placementCount
        && Math.abs(wire - wireBefore) < EPS && after.selection.count === 0,
      `click ${released.lastRelease?.click}; placements ${before.playhead.placementCount}→`
      + `${after.playhead.placementCount}; transport ${r3(wireBefore)}→${r3(wire)}; `
      + `selection ${before.selection.count}→${after.selection.count}`);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // SNAP: OFF — the app's snap IN FORCE reaches the pane (Pro arrange only:
  // Simple locks the arrange's grid, so its OFF is not in force there)
  // ═════════════════════════════════════════════════════════════════════════
  {
    await guard.set("arrange", "pro");
    const priorSnap = (await must("debug.arrangeDrag", {})).snap;
    const set = await must("debug.arrangeDrag", { snap: "off" });
    await sleep(300);
    const landed = set.effectiveSnap === "off";
    check("precondition: the app's snap IN FORCE is off (Pro arrange, SNAP: Off)",
      landed, `snap ${set.snap}, effectiveSnap ${set.effectiveSnap} (was ${priorSnap})`);
    if (landed) await rulerLeg("SNAP: OFF — a ruler click lands exactly where it points", R, { snap: false });
    await must("debug.arrangeDrag", { snap: priorSnap ?? "bar" });
    await guard.restore("snap-off leg done");
    await sleep(300);
    const back = await rulerLeg("…and SNAP back ON snaps again (the pane follows the chip both ways)", R);
    if (back) {
      const onSong = Math.abs((back.wire / GRID) - Math.round(back.wire / GRID)) < 1e-6;
      const onLocal = Math.abs(((back.wire - CLIP_START) / GRID) - Math.round((back.wire - CLIP_START) / GRID)) < 1e-6;
      const clamped = Math.abs(back.wire - CLIP_START) < EPS || Math.abs(back.wire - (CLIP_START + LEN)) < EPS;
      check("⭐ I5-F1 — the snapped-again placement is ON the SONG's 1/16 and OFF the clip-local one (the clip's 3.1 start makes them differ)",
        onSong && !onLocal && !clamped,
        `transport ${r3(back.wire)}: song grid ${onSong}, clip-local grid ${onLocal}, at a clamped edge ${clamped}`);
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // REFUSALS — an error, never a plausible no-op
  // ═════════════════════════════════════════════════════════════════════════
  {
    const withY = await cmd("debug.pitchEditor", { act: "ruler", x: 100, y: 5 });
    check("REFUSAL: a ruler tick with a y", withY.ok === false, `error ${JSON.stringify(withY.error)}`);
    const noX = await cmd("debug.pitchEditor", { act: "ruler" });
    check("REFUSAL: a ruler tick with no x", noX.ok === false, `error ${JSON.stringify(noX.error)}`);
    await stagePitchEditorStep(cmd, { act: "press", x: px, y: py });
    const midPress = await cmd("debug.pitchEditor", { act: "ruler", x: 100 });
    await stagePitchEditorStep(cmd, { act: "release", x: px, y: py });
    check("REFUSAL: a ruler tick while a press is in flight", midPress.ok === false,
      `error ${JSON.stringify(midPress.error)}`);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // FOLLOW — the ONE flag, this pane's runtime, and a pinch standing it down
  // ═════════════════════════════════════════════════════════════════════════
  // I5-F1-F (2026-09-26) — THESE LEGS WAIT ON CONDITIONS, NEVER ON WALL CLOCK.
  // They used to sleep 1200 ms, then give follow 3 s. A run on 2026-09-25
  // (22:45 local) failed two of them. The playhead echoed at screenX 1944 of
  // 1364 after the "1.2 s" wait: 4.85 s of transport had gone by. The shared
  // wedge log has a main actor stuck 4.7 s inside that leg's window
  // (RECOVERED 05:46:01Z; an untagged line, from a binary older than the pid
  // tag, so which process it was is inferred from the timing, not read).
  // The audio clock kept running, so by the time
  // pinchEnd was handled the playhead had LEFT THE CLIP, where follow correctly
  // does nothing (`followLineX` is nil). The clip is the song's last, so the
  // transport then stops at the song's end, and a stopped transport neither
  // pages nor suspends. The display was asleep for that whole
  // run (pmset: off 22:29:41–22:48:53). So each leg now:
  //   • waits for the state that makes it DISCRIMINATE: the playhead inside
  //     the clip and past the frame's edge (follow is DUE) for DUE_SPAN beats
  //     of transport, which is many ticks. It re-seeks into the clip when a
  //     stall has used up the runway;
  //   • goes RED only when follow HAD ITS CHANCE and did the wrong thing, and
  //     is INCONCLUSIVE (exit 2) when it never got one;
  //   • reads `occlusionVisible` at its start and end. A run whose window is
  //     not drawn cannot stand for the user's: the drawing that makes follow
  //     costly (and that WF's band freeze lived in) does not happen. Those
  //     legs still run and print, and then the run exits 2.
  {
    const MARGIN_PT = 32;        // `FollowPlayhead.edgeMargin` (min(32, W/4) — W is ~1364 here)
    const DUE_SPAN = 0.25;       // beats of transport while due = 125 ms at 120 bpm, many ticks
    const RESEEKS = 3;           // a stall may use up the runway this many times per leg
    const drawnReads = [];
    /** The app's own `NSWindow.occlusionState` (WF's `drawn()`). A read that
     * errors because the main actor is wedged is `undefined`, not "not drawn". */
    async function drawn(tag) {
      const r = await cmd("debug.windowFrame", {});
      const v = r?.ok ? r.result?.occlusionVisible : undefined;
      drawnReads.push({ tag, v });
      return v;
    }
    const inconclusive = (name, detail) => {
      followInconclusive.push(name);
      console.log(`  ??   ${name}\n        INCONCLUSIVE — ${detail}`);
    };
    await must("debug.panelLayout", { followPlayhead: true });
    const W = (await scrollTo(200)).viewport.viewportW;
    const at = await echo();
    const ppb = at.zoom.pixelsPerBeat;
    const offsetBefore = at.viewport.offsetX;
    const CLIP_END = CLIP_START + LEN;
    const margin = Math.min(MARGIN_PT, W / 4);
    const beatAtScreen = (sx, offset = offsetBefore) => CLIP_START + (offset + sx) / ppb;
    // PARK 8 pt inside the trailing margin (follow is due a 16th later);
    // DUE 8 pt past it (due at once): each leg re-seeks here.
    const parkBeat = beatAtScreen(W - margin - 8);
    const dueBeat = beatAtScreen(W - margin + 8);
    if (dueBeat >= CLIP_END - 4) refuseRun(`the follow due beat ${r3(dueBeat)} leaves < 4 beats of runway`);
    const isDue = (e) => e.playhead.insideClip === true && e.playhead.screenX > W - margin;
    // One poll: the pane's echo, THEN follow's counters. The counters only
    // grow, so a 0 read after the echo covers everything up to the echo.
    let t0 = Date.now();
    async function poll() {
      const t = Date.now();
      const e = await echo();
      const f = await must("debug.followPlayhead", {});
      return { e, f, rtt: Date.now() - t, ms: Date.now() - t0 };
    }
    const fmt = (p) => `+${p.ms} ms (rtt ${p.rtt}): beat ${r3(p.e.playhead.positionBeats)}, screenX `
      + `${r3(p.e.playhead.screenX)} of ${r3(W)}, inside ${p.e.playhead.insideClip}, offset `
      + `${r3(p.e.viewport.offsetX)}, scrolls ${p.f.pitchEditor.scrolls}, suspended `
      + `${p.f.pitchEditor.suspended}, pinch ${p.e.pinch.live}, playing ${p.f.isPlaying}`;
    const span = (a, b) => b.e.playhead.positionBeats - a.e.playhead.positionBeats;
    const stats = { polls: 0, maxRtt: 0, reseeks: 0 };
    const tally = (p) => { stats.polls++; stats.maxRtt = Math.max(stats.maxRtt, p.rtt); };
    const resetStats = () => { stats.polls = 0; stats.maxRtt = 0; stats.reseeks = 0; t0 = Date.now(); };
    const statLine = () => `${stats.polls} polls over ${Date.now() - t0} ms, max rtt ${stats.maxRtt} ms, `
      + `${stats.reseeks} re-seek(s)`;
    // A stall used up the runway. This project's only clip ENDS THE SONG, so
    // the transport does not just leave the clip, it STOPS at the song's end
    // (measured 2026-09-26: playing false at beat 36.955). Put it back where
    // follow is due and play again. Returns false once the leg's re-seeks
    // are spent.
    async function recover(p) {
      if (++stats.reseeks > RESEEKS) return false;
      await must("transport.seek", { beats: dueBeat });
      if (p.f.isPlaying !== true) await must("transport.play", {});
      return true;
    }

    // ── LEG 1: a LIVE pinch that changes no scale. Its anchor alone makes the
    // pinch own the scroll, so follow must stand down even while it is due.
    await must("transport.seek", { beats: parkBeat });
    await stagePitchEditorStep(cmd, { act: "pinch", x: offsetBefore + 300, y: py, magnification: 1 });
    await must("debug.followPlayhead", { resetCounters: true, rearm: true });
    const d1 = await drawn("pinch-start");
    resetStats();
    await must("transport.play", {});
    let held = null, fought = null, broke = null;
    {
      let from = null;
      for (const deadline = Date.now() + 20_000; Date.now() < deadline;) {
        await sleep(50);
        const p = await poll(); tally(p);
        if (p.f.pitchEditor.scrolls > 0 || p.f.pitchEditor.suspended
            || Math.abs(p.e.viewport.offsetX - offsetBefore) > 0.5) { fought = p; break; }
        if (p.e.pinch.live !== true) { broke = p; break; }
        if (p.e.playhead.insideClip !== true || p.f.isPlaying !== true) {
          if (!(await recover(p))) break;
          from = null;
          continue;
        }
        if (!isDue(p.e)) { from = null; continue; }
        if (from === null) from = p;
        else if (span(from, p) >= DUE_SPAN) { held = { from, to: p }; break; }
      }
    }
    const d1e = await drawn("pinch-end");
    const pinchName = "FOLLOW stands down while a pinch owns the scroll: no page turn, and no suspension blamed on it";
    if (fought) {
      fcheck(pinchName, false, `follow MOVED or suspended while the pinch was live — ${fmt(fought)}; ${statLine()}`);
    } else if (held) {
      fcheck(pinchName, true,
        `follow was DUE for ${r3(span(held.from, held.to))} beats of transport with the pinch live `
        + `(${fmt(held.from)} → ${fmt(held.to)}); ${statLine()}; drawn ${d1}→${d1e}`);
    } else {
      inconclusive(pinchName, `follow was never due for ${DUE_SPAN} beats with the pinch live `
        + `(${broke ? `precondition broke: ${fmt(broke)}` : "the runway ran out"}); ${statLine()}`);
    }

    // ── LEG 2: the pinch ends, so follow turns the page. Re-seek first: the
    // leg starts DUE with the clip's runway (~4.9 s), whatever leg 1 cost.
    await must("transport.seek", { beats: dueBeat });
    const d2 = await drawn("page-start");
    resetStats();
    await stagePitchEditorStep(cmd, { act: "pinchEnd" });
    let paged = null, missed = null;
    {
      let from = null;
      for (const deadline = Date.now() + 20_000; Date.now() < deadline;) {
        await sleep(50);
        const p = await poll(); tally(p);
        if (p.f.pitchEditor.scrolls > 0) { paged = p; break; }
        if (p.f.pitchEditor.suspended) { missed = { why: "follow SUSPENDED itself as the pinch ended", from: p, to: p }; break; }
        if (p.e.playhead.insideClip !== true || p.f.isPlaying !== true) {
          if (!(await recover(p))) break;
          from = null;
          continue;
        }
        if (p.e.pinch.live !== false || !isDue(p.e)) { from = null; continue; }
        if (from === null) from = p;
        else if (span(from, p) >= DUE_SPAN) { missed = { why: "follow was DUE with no pinch and did not scroll", from, to: p }; break; }
      }
    }
    // The counter can move before the scroller does: wait for the offset.
    let afterPage = await echo();
    for (let i = 0; paged && i < 40 && Math.abs(afterPage.viewport.offsetX - offsetBefore) <= 0.5; i++) {
      await sleep(50);
      afterPage = await echo();
    }
    const d2e = await drawn("page-end");
    const pageName = "…and once the pinch ends, follow TURNS THE PAGE (the control: it was the pinch holding it)";
    if (paged) {
      const inFrame = afterPage.playhead.insideClip !== true
        || (afterPage.playhead.screenX >= 0 && afterPage.playhead.screenX <= W);
      fcheck(pageName, afterPage.viewport.offsetX > offsetBefore + 0.5 && inFrame,
        `scrolls ${paged.f.pitchEditor.scrolls}; offset ${r3(offsetBefore)}→${r3(afterPage.viewport.offsetX)}; `
        + `playhead screenX ${r3(afterPage.playhead.screenX)} of ${r3(W)}; ${statLine()}; drawn ${d2}→${d2e}`);
    } else if (missed) {
      fcheck(pageName, false, `${missed.why}: ${fmt(missed.from)} → ${fmt(missed.to)}; ${statLine()}`);
    } else {
      inconclusive(pageName, `follow was never due for ${DUE_SPAN} beats once the pinch ended; ${statLine()}`);
    }
    captures.following = (await captureLook(cmd, join(OUT, "i5-3-following-after-page.png"))).path;

    // ── LEG 3: a simulated POINTER scroll SUSPENDS follow. Precondition:
    // follow is DRIVING (playing, inside, no pinch, not suspended) and the
    // playhead sits mid-frame with runway. From offset 0 the playhead is then
    // off-screen, so a follow that did NOT suspend drags the view back (its
    // scroll count moves): that is the RED this leg can see.
    {
      const cur = await echo();
      await must("transport.seek", { beats: beatAtScreen(W / 2, cur.viewport.offsetX) });
      // A stall in leg 2 can have run the transport to the song's end.
      if ((await must("debug.followPlayhead", {})).isPlaying !== true) await must("transport.play", {});
    }
    const d3 = await drawn("suspend-start");
    resetStats();
    const pre = await poll(); tally(pre);
    const scrollsPre = pre.f.pitchEditor.scrolls;
    const driving = pre.e.playhead.insideClip === true && pre.e.pinch.live === false
      && pre.f.isPlaying === true && pre.f.pitchEditor.suspended === false && !isDue(pre.e);
    let suspended = null, dragged = null, ignored = null;
    if (driving) {
      await must("debug.followPlayhead", { simulateUserScroll: 0, surface: "pitchEditor" });
      let from = null;
      for (const deadline = Date.now() + 20_000; Date.now() < deadline;) {
        await sleep(50);
        const p = await poll(); tally(p);
        if (p.f.pitchEditor.suspended) { suspended = p; break; }
        if (p.f.pitchEditor.scrolls > scrollsPre) { dragged = p; break; }
        if (p.e.playhead.insideClip !== true || p.f.isPlaying !== true || p.e.pinch.live !== false) break;
        // The scroll has ARRIVED (the reader says 0) with follow driving:
        // from here the detector has had the report, so time is on our side.
        if (p.e.viewport.offsetX > 0.5) { from = null; continue; }
        if (from === null) from = p;
        else if (span(from, p) >= DUE_SPAN) { ignored = { from, to: p }; break; }
      }
    }
    const suspendedEcho = await echo();
    const d3e = await drawn("suspend-end");
    const suspendName = "a manual scroll during playback SUSPENDS the pitch editor's follow, and the echo says so";
    if (!driving) {
      inconclusive(suspendName, `follow was not driving before the scroll: ${fmt(pre)}`);
    } else if (suspended) {
      fcheck(suspendName, suspendedEcho.playhead.follow.suspended === true
          && suspendedEcho.playhead.follow.enabled === true,
        `pitchEditor.suspended true at ${fmt(suspended)}; echo follow `
        + `${JSON.stringify(suspendedEcho.playhead.follow)}; ${statLine()}; drawn ${d3}→${d3e}`);
    } else if (dragged) {
      fcheck(suspendName, false, `follow DRAGGED THE VIEW BACK instead of suspending: ${fmt(dragged)}; ${statLine()}`);
    } else if (ignored) {
      fcheck(suspendName, false, `the scroll arrived with follow driving and nothing suspended: `
        + `${fmt(ignored.from)} → ${fmt(ignored.to)}; ${statLine()}`);
    } else {
      inconclusive(suspendName, `the scroll never arrived while follow was driving; ${statLine()}`);
    }
    // …and `rearm` (the chip, or the next play) clears it.
    await must("debug.followPlayhead", { rearm: true });
    const rearmed = await must("debug.followPlayhead", {});
    fcheck("rearm clears the suspension", rearmed.pitchEditor.suspended === false,
      `pitchEditor.suspended ${rearmed.pitchEditor.suspended}`);
    await must("transport.stop", {});
    await must("debug.panelLayout", { followPlayhead: false });
    // A leg's START read must be a definite true; its END read may be missing
    // (a wedge can block it — the wedge is then the evidence) but not false.
    const starts = drawnReads.filter((d) => d.tag.endsWith("-start"));
    const ends = drawnReads.filter((d) => d.tag.endsWith("-end"));
    const undrawn = starts.some((d) => d.v !== true) || ends.some((d) => d.v === false);
    console.log(`follow: occlusionVisible ${drawnReads.map((d) => `${d.tag} ${d.v}`).join(", ")}`);
    if (undrawn) {
      followInconclusive.push("window not drawn");
      console.log("  ??   the FOLLOW legs ran with the window NOT DRAWN (display asleep, screen locked, "
        + "minimized or covered) — they printed above, but they prove nothing about the user's app");
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // LOOK — the ruler zoomed in, and in the other pane states
  // ═════════════════════════════════════════════════════════════════════════
  await must("debug.panelLayout", { pitchEditorPPB: 160 });
  await sleep(300);
  await scrollTo(900);
  await stagePitchEditorStep(cmd, { act: "ruler", x: 520.3 });
  captures.zoomed = (await captureLook(cmd, join(OUT, "i5-2-ruler-zoomed-ppb160.png"))).path;
  const zoomedEcho = await echo();
  console.log(`look (zoomed): ppb ${zoomedEcho.zoom.pixelsPerBeat}, offset ${r3(zoomedEcho.viewport.offsetX)}, `
    + `playhead screenX ${r3(zoomedEcho.playhead.screenX)} (+52 pt sidebar in the capture)`);
  // The CONTROL for the fitting-content leg below: while the content is wider
  // than the pane, the ruler draws with exactly the offset the reader measured.
  check("content WIDER than the pane: the ruler draws with the measured offset (the control)",
    zoomedEcho.viewport.contentW > zoomedEcho.viewport.viewportW
      && Math.abs(zoomedEcho.playhead.rulerScrollX - zoomedEcho.viewport.offsetX) < 0.5,
    `contentW ${r3(zoomedEcho.viewport.contentW)} vs viewportW ${r3(zoomedEcho.viewport.viewportW)}; `
    + `rulerScrollX ${r3(zoomedEcho.playhead.rulerScrollX)}, offsetX ${r3(zoomedEcho.viewport.offsetX)}`);

  // ⭐ THE WHOLE CLIP FITS, AND THE READER MAY STILL SAY 900. The user's path:
  // from a scrolled, zoomed-in view, TIME − until the clip fits, then TIME −
  // once more. MEASURED 2026-09-25 (the first look at this capture): the
  // horizontal reader then reported the scroller's LAST REAL position (900) and
  // kept it, while the grid was drawn at 0. A ruler drawn with that reading
  // showed bar 8 over the clip's first bar, and a tick landed at the clip's
  // end. The ruler must use the offset the scroller can SHOW; when the content
  // fits, the only one is 0.
  //
  // ⚠️ I5-F1-F, MEASURED 2026-09-26: THE STALE READING IS A RACE, NOT A GIVEN.
  // Where it appears, it appears at the SECOND zoom (32 → 24: fitting to
  // fitting). The first zoom (160 → 32) read 0 in every sampled repetition.
  // This sequence went stale in 36 of 57 repetitions over 29 runs
  // (2026-09-25/26: this gate, its planted builds, and a copy that loops the
  // sequence), and a probe's near copy in 0 of 25. What decides it is NOT
  // known. It is not whether the window is drawn: it went stale with
  // `occlusionVisible` true and with it false, and stayed right both ways.
  // Nor is it which of the gate's earlier sections ran: with all of them and
  // with none, the loop's outcome differed from one run to the next.
  // So this used to be a PRECONDITION, and it failed a run on 2026-09-25
  // (22:49 local) for no fault of the product. Now it is an OBSERVATION:
  //   • stale: the legs below DISCRIMINATE, and a band or tick on the raw
  //     reading goes red;
  //   • not stale: the raw reading and the shown offset are the same number,
  //     so no defect of that kind can show. The legs still assert what the
  //     user sees (offset 0, the tick lands under the pointer), and the log
  //     says the run did not discriminate. That is not a failure. A planted
  //     run that did not discriminate proves nothing: run it again.
  const fitDrawn = await cmd("debug.windowFrame", {});
  await must("debug.panelLayout", { pitchEditorPPB: 32 });
  await sleep(300);
  await must("debug.panelLayout", { pitchEditorPPB: 24 });
  await sleep(300);
  await must("debug.panelLayout", { pitchEditorPPB: 32 });
  await sleep(600);
  const fits = await echo();
  const fitsW = fits.viewport.contentW, boxW = fits.viewport.viewportW;
  const fitDrawnEnd = await cmd("debug.windowFrame", {});
  const readerStale = fits.viewport.offsetX > 1;
  check("precondition: the clip FITS the pane at 32 pt/beat",
    fits.zoom.pixelsPerBeat === 32 && fitsW < boxW,
    `ppb ${fits.zoom.pixelsPerBeat}; contentW ${r3(fitsW)} < viewportW ${r3(boxW)}`);
  console.log(`fit: the reader says offsetX ${r3(fits.viewport.offsetX)} (${readerStale ? "STALE — this run discriminates" : "right"}); `
    + `occlusionVisible ${fitDrawn?.result?.occlusionVisible}→${fitDrawnEnd?.result?.occlusionVisible}`);
  // What this reads is `PitchEditorViewport.shownOffsetX` THROUGH THE ECHO — the
  // value handed to the ruler, not a measurement of what the band drew. The
  // band's input is pinned only by the site test (`scrollX: viewport.shownOffsetX`);
  // staging plant E (band + tick on the raw offset) left this check GREEN and
  // was caught by the tick check below.
  check("⭐ with the clip fitting, the offset handed to the ruler is 0 (the only one the scroller can show)",
    fits.playhead.rulerScrollX === 0,
    `rulerScrollX ${r3(fits.playhead.rulerScrollX)} (measured offsetX ${r3(fits.viewport.offsetX)})`);
  {
    const RX = 410.7;
    await stagePitchEditorStep(cmd, { act: "ruler", x: RX });
    const wire = await transportBeats();
    const want = expectPlacement(RX + 0, { ppb: 32 });   // the gate's own arithmetic, offset 0
    const stale = expectPlacement(RX + fits.viewport.offsetX, { ppb: 32 });
    check("⭐ …and a tick there lands on the beat under the pointer (read back over the wire)",
      Math.abs(wire - want) < 1e-3,
      `ruler x ${RX} at 32 pt/beat → want ${r3(want)}; transport ${r3(wire)} `
      + (readerStale ? `(the stale reading would have given ${r3(stale)})` : "(the reader was right: nothing to tell apart)"));
    if (readerStale) {
      check("the fitting leg DISCRIMINATES: the stale reading's beat differs from the right one",
        Math.abs(stale - want) > 1, `${r3(stale)} vs ${r3(want)}`);
    } else {
      console.log("  --   the fitting leg does NOT discriminate this run: the reader was right, so a band or tick "
        + "on the raw reading would land in the same place. Not a failure: see the header.");
    }
  }
  captures.default = (await captureLook(cmd, join(OUT, "i5-4-ruler-default-ppb32.png"))).path;
  const defaultEcho = await echo();
  console.log(`look (default, clip fits): ppb ${defaultEcho.zoom.pixelsPerBeat}, playhead screenX `
    + `${r3(defaultEcho.playhead.screenX)}, rulerScrollX ${r3(defaultEcho.playhead.rulerScrollX)}`);
  // ANALYSING — a fresh, never-tuned clip, captured before its detection lands.
  {
    const t2 = await must("track.add", { name: "I5 Analysing", kind: "audio" });
    const c2 = await must("clip.addAudio", { trackId: t2.id, path: fixturePath, atBeat: 1 });
    await must("track.setMute", { trackId: t2.id, muted: true });
    await must("view.openPitchEditor", { clipId: c2.id });
    const cap = await captureLook(cmd, join(OUT, "i5-5-state-analysing.png"));
    const e = await echo();
    captures.analysing = cap.path;
    console.log(`look (analysing attempt): statusKey at capture ≈ ${e.chrome.statusKey}`);
  }
  // NOTHING FOUND — a silent clip.
  {
    const t3 = await must("track.add", { name: "I5 Silence", kind: "audio" });
    const c3 = await must("clip.addAudio", { trackId: t3.id, path: silentPath, atBeat: 2 });
    const len3 = (await must("project.snapshot", {})).tracks.flatMap((t) => t.clips ?? [])
      .find((c) => c.id === c3.id)?.lengthBeats;
    if (typeof len3 !== "number") refuseRun("the silent clip is not in the snapshot");
    await must("view.openPitchEditor", { clipId: c3.id });
    let e = null;
    for (let i = 0; i < 40; i++) {
      await sleep(200);
      e = await echo();
      if (e.chrome.statusKey !== "analysing" && e.chrome.statusKey !== "idle" && e.chrome.statusKey !== "") break;
    }
    captures.noNotes = (await captureLook(cmd, join(OUT, "i5-6-state-no-notes.png"))).path;
    console.log(`look (silent clip): statusKey ${e?.chrome?.statusKey} — "${e?.chrome?.statusText}"`);
    // The ruler places the playhead in a state that draws no notes.
    const before = await echo();
    await scrollTo(0);
    await stagePitchEditorStep(cmd, { act: "ruler", x: 40.3 });
    const after = await echo();
    const wire = await transportBeats();
    // I5-F1: the song's grid — this clip starts ON it (beat 2), so the two
    // snaps agree here; the arithmetic is the song's all the same.
    const want = expectPlacement(40.3, { ppb: after.zoom.pixelsPerBeat, start: 2, len: len3 });
    check("the ruler places the playhead on a clip where NO notes were found (it shows in every state)",
      after.chrome.statusKey === "noNotes" && Math.abs(wire - want) < 1e-3
        && after.playhead.placementCount === before.playhead.placementCount + 1,
      `statusKey ${after.chrome.statusKey}; transport ${r3(wire)}, want ${r3(want)}`);
  }
  // A MISSING FILE — the refusal / engine-unavailable path, if the store takes it.
  {
    const gone = join(OUT, "vanishing-fixture.wav");
    spawnSync("cp", [fixturePath, gone]);
    const t4 = await must("track.add", { name: "I5 Missing", kind: "audio" });
    const c4 = await must("clip.addAudio", { trackId: t4.id, path: gone, atBeat: 3 });
    rmSync(gone, { force: true });
    await must("view.openPitchEditor", { clipId: c4.id });
    let e = null;
    for (let i = 0; i < 40; i++) {
      await sleep(200);
      e = await echo();
      if (!["analysing", "idle", ""].includes(e.chrome.statusKey)) break;
    }
    captures.missing = (await captureLook(cmd, join(OUT, "i5-7-state-missing-file.png"))).path;
    console.log(`look (missing file): statusKey ${e?.chrome?.statusKey} — "${e?.chrome?.statusText}"`);
  }
  writeFileSync(join(OUT, "i5-captures.json"), JSON.stringify(captures, null, 2));
  console.log(`captures: ${Object.values(captures).join("  ")}`);
} catch (err) {
  console.log(`ERROR: ${err?.stack ?? err}`);
  exitCode = 2;
} finally {
  clearTimeout(killer);
  try { await cmd("transport.stop", {}); } catch { /* best effort */ }
  try { await guard.restore("teardown", { timeoutMs: 3000 }); } catch { /* best effort */ }
  try { session.ws.close(); } catch { /* ignore */ }
  stopLook(GATE);
  console.log("staging stopped (pidfile-exact)");
}
// The shared wedge log (MainActorLiveness): every line this staging pid wrote.
// A stall of the main actor is the first suspect for any leg that timed out.
{
  const LOG = join(process.env.HOME ?? "", "Library/Logs/DAWPro/main-actor-wedge.log");
  let text = null;
  try { text = readFileSync(LOG, "utf8"); } catch (e) { console.log(`wedge log: unreadable (${e.code}) — ${LOG}`); }
  if (text !== null) {
    const lines = text.split("\n");
    const mine = lines.filter((l) => l.includes(` pid=${session.pid} `));
    const tagged = lines.filter((l) => / pid=\d+ /.test(l)).length;
    console.log(`wedge log: ${mine.length} line(s) from staging pid ${session.pid} (the log holds ${tagged} pid-tagged `
      + `line(s) in all — the tag is live)${mine.length ? `\n        ${mine.join("\n        ")}` : ""}`);
  }
}
if (exitCode !== null) process.exit(exitCode);
{
  const failed = checks.filter((c) => !c.ok);
  const failedElsewhere = failed.filter((c) => !followCheckNames.has(c.name));
  // A red OUTSIDE the follow legs is a verdict whatever the window did.
  if (followInconclusive.length > 0 && failedElsewhere.length === 0) {
    console.log(`checks: ${checks.length - failed.length}/${checks.length} ok`
      + (failed.length ? ` — FAILED (follow legs, not counted): ${failed.map((c) => c.name).join(" | ")}` : ""));
    console.log(`ABORT (proves nothing): the FOLLOW legs are INCONCLUSIVE (${followInconclusive.join("; ")}) — `
      + "re-run with the window drawn");
    process.exit(2);
  }
}
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
