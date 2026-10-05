// W7-NTU U1 GATE — THE HEADER GROUP "SOUND LIKE THE SINGER" (natural tuning X9,
// R16, R26) AND THE TOOL HELP AT THE 1208 pt FLOOR, LOOKED AT on a REAL app on
// staging (port 17695 ONLY; 17600 is the user's LIVE app and is never touched.
// Staging is stopped PIDFILE-EXACT through `_pitch-editor-look.mjs`'s
// `stopLook`, never pkill/pgrep — its window closes with it).
//
// ⭐ A SPY GATE WITH A SECOND INSTRUMENT. The pane says what it drew
// (`debug.pitchEditor`'s `singer` block: every row's face and words, and the
// two FRAMES the header's layout produced; `interaction.toolHelp` for the
// palette), and the STORE is read back over the wire independently
// (`clip.getPitchEdits`, `edit.history`, `edit.undo`) — never one instrument.
// The group's controls are pressed through the debug tier's `singer` act,
// which runs the group view's OWN callback (`PitchEditorView.runSinger`) —
// the path a click takes from the model to the app's funnel and the store.
//
// THE STATES, EACH CAPTURED ONCE AT 1600 AND ONCE AT 1208 pt (13 pictures, no
// two of one state — a repeated state would be a repeated picture)
//   ① a vocal tuned with this update: 100% voice size, consonants ON, Smooth lit
//     (at 1208 this is ④'s "updated" picture);
//   ② each Slides step pressed (Snappy / Quick / Slow captured, then Smooth
//     again, not re-captured), each ONE "Slide Smoothness" step, the store
//     holding the step's smoothness;
//   ③ a vocal tuned BEFORE the update (the project file's three natural-tuning
//     keys removed, then reopened — the on-disk shape of an old vocal): the
//     voice row DIM with its amber update line, no amount, Slides "Set by the
//     old tuning";
//   ④ the update line tapped: ONE "Update Tuning" step, all three set; Undo
//     brings the old vocal back; a press on the DIM slider is the SAME update;
// plus, at 1600 only: a voice-size drag mid-flight (the cyan thumb, nothing
// stored until release) and its ONE "Keep Voice Size" step; Consonants OFF;
// and at 1208 only: THE WOBBLE HELP beside its hover readout (C5a-F11's scene,
// now with "Hold ⌘ to draw instead."), which must show IN FULL on two lines.
//
// WHAT THIS PROVES (by echo + store, and by the captures a person looks at)
//   • the group is drawn BESIDE the chips at 1600 and at 1208 — measured from
//     the two frames the layout produced — and the chips keep 790 pt;
//   • each control is ONE undo step with its own name, and the store holds
//     what the row then draws;
//   • on an old vocal every press is THE update (never a voice-size write);
//   • THE USER'S FOCUS STAYS PUT: staging launches with
//     DAWPRO_STAGING_NO_ACTIVATE=1, every capture reports the app INACTIVE, and
//     the frontmost app (lsappinfo) is never the staging app — before the
//     launch, after it, after the last capture and after the stop.
//
// WHAT THIS DOES NOT PROVE
//   • a real pointer (m23-g1): the presses are the group's own callbacks;
//   • that the help is not truncated: the echo carries the STRING, never its
//     pixels — the Wobble capture is where a person sees it whole;
//   • sound: the track is muted.
//
// PRECONDITIONS
//   • AN UNLOCKED SCREEN — checked FIRST, before provenance, fixtures or a
//     launch: with the screen locked the frontmost app is `loginwindow` and a
//     capture proves nothing. EXIT 3, "PENDING". (The w7 runner checks the
//     same thing before it takes `staging.lock`.)
//   • PROVENANCE — `.build/debug/DAWApp` newer than every file under
//     `Sources/` and `Package.swift` (with a positive control on the same
//     `find`); else EXIT 2. Build under a heavy slot right before running it.
//
//   node scripts/gates/m23ap-ntu-header.mjs
//
// Env: M23AP_NTU_OUT (captures, fixture, the named project; default
//      /tmp/m23ap-ntu).
//
// EXIT: 0 green, 1 red, 2 proves nothing (a refused precondition), 3 pending
//       (the screen is locked; nothing was launched).
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { ROOT, DEFAULT_BINARY, STAGING_DEFAULTS_DOMAIN, verdict, sleep } from "./_staging.mjs";
import {
  synthesizeVocalFixture, launchLook, stopLook, makeCmd, waitPitchEditorReady,
  stagePitchEditorStep, captureLook,
} from "./_pitch-editor-look.mjs";

const GATE = "m23ap-ntu";
const OUT = process.env.M23AP_NTU_OUT || "/tmp/m23ap-ntu";
const STAGING_NAME = STAGING_DEFAULTS_DOMAIN;

/** The frontmost app's name AND pid, from lsappinfo. `name` null = lsappinfo
 * answered nothing parseable: a reading that proves nothing. */
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

// ═══════════════════════════════════════════════════════════════════════════
// PRECONDITION 1 — AN UNLOCKED SCREEN, BEFORE ANYTHING ELSE
// ═══════════════════════════════════════════════════════════════════════════
const front0 = frontmostApp();
console.log(`frontmost before anything: ${front0.name ?? `(unreadable: ${front0.raw})`} (pid ${front0.pid})`);
if (front0.name === "loginwindow") {
  console.log("PENDING — the screen is LOCKED (frontmost: loginwindow). Nothing was built, "
    + "launched or written; re-run on an unlocked screen.");
  process.exit(3);
}
if (front0.name === null) {
  console.log(`ABORT (proves nothing): lsappinfo did not name the frontmost app (${front0.raw})`);
  process.exit(2);
}
if (front0.name === STAGING_NAME) {
  console.log(`ABORT (proves nothing): a staging app (${STAGING_NAME}) is ALREADY frontmost — a previous `
    + "run left it; this run could not tell its own focus theft from that one's");
  process.exit(2);
}

mkdirSync(OUT, { recursive: true });
const EPS = 1e-9;
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
function refuseRun(reason) {
  console.log(`ABORT (proves nothing): ${reason}`);
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}
let stagingPid = null;
const stoleFocus = (f) => (stagingPid !== null && f.pid === stagingPid) || f.name === STAGING_NAME
  || (f.name === "Finder" && front0.name !== "Finder");

/** A capture's own numbers: its bytes' hash (two captures of different states
 * must differ, or one is STALE) and its luma range (`-hide_banner`, default
 * log level: `metadata=print` logs at INFO, which `-v error` would swallow). */
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
  return { exists: true, sha, ymin: num("YMIN"), ymax: num("YMAX"), ffmpegStatus: r.status };
}

// ═══════════════════════════════════════════════════════════════════════════
// PRECONDITION 2 — PROVENANCE
// ═══════════════════════════════════════════════════════════════════════════
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
// FIXTURE — three sung notes (the shared, proven recipe)
// ═══════════════════════════════════════════════════════════════════════════
const fixturePath = synthesizeVocalFixture(OUT, {
  notes: [{ hz: 220, seconds: 1.5 }, { hz: 247, seconds: 1.5 }, { hz: 196, seconds: 1.5 }],
});

const killer = setTimeout(() => {
  console.log("TIMEOUT — 10 minutes");
  try { stopLook(GATE); } catch { /* best effort */ }
  process.exit(2);
}, 600_000);

const session = await launchLook({ gate: GATE, settleMs: 1500, env: { DAWPRO_STAGING_NO_ACTIVATE: "1" } });
stagingPid = session.pid;
console.log(`staging pid ${session.pid} (skipBuild; DAWPRO_STAGING_NO_ACTIVATE=1); started ${new Date().toISOString()}`);
const cmd = makeCmd(session.ws);
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (!r || r.ok !== true) throw new Error(`${command} failed — ${JSON.stringify(r?.error ?? r)}`);
  return r.result;
}
const echo = () => must("debug.pitchEditor", {});
const stage = (act) => stagePitchEditorStep(cmd, act);
const history = async () => (await must("edit.history", {})).undo;
const fronts = [{ at: "before anything", name: front0.name, pid: front0.pid }];
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
  facts[key] = { ...captureFacts(shot.path), appActive: shot.appActive, width: shot.width, height: shot.height };
  return shot;
}

/** Poll the echo until `pred(echo)` holds; the last echo either way. */
async function waitEcho(pred, ms = 8000) {
  const deadline = Date.now() + ms;
  let e = await echo();
  while (!pred(e) && Date.now() < deadline) {
    await sleep(150);
    e = await echo();
  }
  return e;
}

/** The group as the header drew it, and where: `placement` is READ OFF the
 * two measured frames by the echo. */
function groupFacts(e) {
  const s = e.singer ?? {};
  return {
    drawn: s.drawn, placement: s.placement, frame: s.frame, presetsFrame: s.presetsFrame,
    voice: s.voice, consonants: s.consonants, slides: s.slides,
  };
}

try {
  {
    const f = noteFront("after the launch");
    check("FOCUS — the launch did not take the user's focus (lsappinfo)",
      f.name !== null && f.pid !== null && !stoleFocus(f),
      `frontmost ${front0.name} (pid ${front0.pid}) → ${f.name ?? f.raw} (pid ${f.pid}); staging pid ${session.pid}`);
  }

  // ── a NAMED project of this gate's own; the vocal tuned by a preset, muted
  await must("project.new", { discardChanges: true });
  const track = await must("track.add", { name: "NTU Header Vocal", kind: "audio" });
  const clip = await must("clip.addAudio", { trackId: track.id, path: fixturePath, atBeat: 0 });
  await must("clip.autoCorrectPitch", { clipId: clip.id });
  await must("track.setMute", { trackId: track.id, muted: true });
  const projectPath = join(OUT, "NTU Header.dawproj");
  await must("project.save", { path: projectPath });
  console.log(`project: ${projectPath} — clip ${clip.id.slice(0, 8)}`);
  const stored = () => must("clip.getPitchEdits", { clipId: clip.id });

  async function openEditor() {
    const opened = await must("view.openPitchEditor", { clipId: clip.id });
    if (opened.opened !== true) refuseRun(`view.openPitchEditor did not open: ${opened.reason}`);
    await waitPitchEditorReady(cmd, { timeoutMs: 30_000, intervalMs: 250 });
    await must("transport.stop", {});
    return waitEcho((e) => e.singer?.drawn === true && e.singer?.frame && e.singer?.presetsFrame);
  }
  async function width(w) {
    const frame = await must("debug.windowFrame", { width: w });
    await sleep(800);
    return frame;
  }

  /** The group's placement at this width, from the frames (never the rule). */
  function placementCheck(label, e, windowWidth) {
    const g = groupFacts(e);
    const f = g.frame ?? {};
    const p = g.presetsFrame ?? {};
    const inside = typeof f.x === "number" && f.x + f.width <= windowWidth - 12 + 0.5;
    check(`${label}: the group sits BESIDE the chips, 340 pt wide, inside the pane; the chips keep 790 pt`,
      g.drawn === true && g.placement === "beside" && Math.abs((f.width ?? 0) - 340) < 1
        && Math.abs((p.width ?? 0) - 790) < 1 && inside,
      `placement ${g.placement}; group ${JSON.stringify(f)}; chips ${JSON.stringify(p)}; window ${windowWidth}`);
    // The drawn form of "the header grows by the group, never by the chips":
    // the chips' column is no taller than the group beside it.
    check(`${label}: the chips' column is no taller than the group (the group sets the header's height)`,
      typeof p.height === "number" && typeof f.height === "number" && p.height <= f.height + 0.5,
      `chips ${p.height} pt, group ${f.height} pt`);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // ① A VOCAL TUNED WITH THIS UPDATE, at 1600
  // ═════════════════════════════════════════════════════════════════════════
  await width(1600);
  let e = await openEditor();
  {
    const s = await stored();
    const g = groupFacts(e);
    looks.new1600 = g;
    check("① new vocal: the store holds 100% / consonants ON / 3000 c/s and does not predate the update",
      s.formantCorrection === 1 && s.keepConsonantsUntuned === true
        && s.transitionSlopeCentsPerSecond === 3000 && s.predatesNaturalTuning === false,
      `store ${JSON.stringify({ f: s.formantCorrection, c: s.keepConsonantsUntuned, t: s.transitionSlopeCentsPerSecond, p: s.predatesNaturalTuning })}`);
    check("① new vocal: the rows DRAW it — \"100%\", ON, Smooth lit, the novice lines",
      g.voice?.readout === "100%" && g.voice?.needsUpdate === false && g.consonants?.on === true
        && g.consonants?.face === "ON" && g.slides?.selected === "smooth"
        && g.voice?.line === "Keeps the voice its own size when notes move."
        && g.consonants?.line === "S, T and breaths keep their own pitch."
        && g.slides?.line === "How gently a moved note slides into the next.",
      JSON.stringify({ voice: g.voice?.readout, line: g.voice?.line, cons: g.consonants?.face, slides: g.slides?.selected }));
    placementCheck("① at 1600", e, 1600);
    await shoot("new1600", "ntu-1-new-1600.png");
  }

  // ② EACH SLIDES STEP, pressed, at 1600
  const STEPS = { snappy: 20000, quick: 6000, slow: 1500, smooth: 3000 };
  async function pressSlides(step, tag) {
    const h0 = (await history()).length;
    await stage({ act: "singer", control: "slides", step });
    const now = await waitEcho((x) => x.singer?.slides?.selected === step);
    const s = await stored();
    const h = await history();
    check(`② ${tag} ${step}: ONE "Slide Smoothness" step, the store at ${STEPS[step]} c/s, the step lit`,
      h.length === h0 + 1 && h[0] === "Slide Smoothness" && s.transitionSlopeCentsPerSecond === STEPS[step]
        && now.singer?.slides?.selected === step && now.singer?.slides?.face === "step",
      `history +${h.length - h0} (${h[0]}); store ${s.transitionSlopeCentsPerSecond}; lit ${now.singer?.slides?.selected}`);
    return now;
  }
  // Smooth is ①'s own picture, so it is pressed (back to where it started)
  // but not captured again: two captures of one state would be one picture.
  for (const step of ["snappy", "quick", "slow", "smooth"]) {
    await pressSlides(step, "1600");
    if (step !== "smooth") await shoot(`slides-${step}-1600`, `ntu-2-slides-${step}-1600.png`);
  }

  // Keep voice size: a drag mid-flight (nothing stored), then ONE step.
  {
    const h0 = (await history()).length;
    for (const fraction of [0.9, 0.7, 0.5]) await stage({ act: "singer", control: "voiceTrack", fraction });
    const mid = await waitEcho((x) => x.singer?.voice?.dragging === true);
    const midStore = await stored();
    await shoot("voiceDrag1600", "ntu-3-voice-drag-1600.png");
    check("Keep voice size mid-drag: the row draws 50% (dragging), the store still 100%, no step yet",
      mid.singer?.voice?.readout === "50%" && mid.singer?.voice?.dragging === true
        && midStore.formantCorrection === 1 && (await history()).length === h0,
      `readout ${mid.singer?.voice?.readout}; store ${midStore.formantCorrection}`);
    await stage({ act: "singer", control: "voiceRelease" });
    const after = await waitEcho((x) => x.singer?.voice?.dragging === false && x.singer?.voice?.readout === "50%");
    const s = await stored();
    const h = await history();
    check("Keep voice size release: ONE \"Keep Voice Size\" step, the store at 0.5, the row reads it back",
      h.length === h0 + 1 && h[0] === "Keep Voice Size" && s.formantCorrection === 0.5
        && after.singer?.voice?.readout === "50%",
      `history +${h.length - h0} (${h[0]}); store ${s.formantCorrection}; readout ${after.singer?.voice?.readout}`);
  }
  // Consonants OFF (a choice), captured, then back ON.
  {
    const h0 = (await history()).length;
    await stage({ act: "singer", control: "consonants" });
    const off = await waitEcho((x) => x.singer?.consonants?.on === false);
    const s = await stored();
    check("Consonants: ONE \"Keep Consonants\" step, OFF by choice in the store, OFF on the capsule",
      (await history()).length === h0 + 1 && s.keepConsonantsUntuned === false && s.consonantsOffByChoice === true
        && off.singer?.consonants?.face === "OFF",
      `store ${JSON.stringify({ on: s.keepConsonantsUntuned, choice: s.consonantsOffByChoice })}; face ${off.singer?.consonants?.face}`);
    await shoot("consonantsOff1600", "ntu-4-consonants-off-1600.png");
    await stage({ act: "singer", control: "consonants" });
    await waitEcho((x) => x.singer?.consonants?.on === true);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // ③ A VOCAL TUNED BEFORE THE UPDATE — the on-disk shape of an old project
  // ═════════════════════════════════════════════════════════════════════════
  await must("project.save", { path: projectPath });
  {
    const file = join(projectPath, "project.json");
    const json = JSON.parse(readFileSync(file, "utf8"));
    let stripped = 0;
    for (const t of json.tracks ?? []) {
      for (const c of t.clips ?? []) {
        if (c.id !== clip.id && c.id?.toUpperCase?.() !== clip.id.toUpperCase()) continue;
        for (const key of ["formantCorrection", "keepsConsonantsUntuned", "transitionSlope"]) {
          if (c.pitchEdits && key in c.pitchEdits) { delete c.pitchEdits[key]; stripped += 1; }
        }
      }
    }
    if (stripped === 0) refuseRun("the saved project carried none of the three natural-tuning keys — "
      + "the legacy shape could not be made (the encoding changed?)");
    writeFileSync(file, JSON.stringify(json, null, 2));
    console.log(`legacy: stripped ${stripped} natural-tuning key(s) from ${file}`);
  }
  await must("project.open", { path: projectPath, discardChanges: true });
  await sleep(500);
  {
    // The FIXTURE must have made an old vocal: a preset set that bends pitch,
    // read back from the reopened project. If it did not, that is a fixture
    // fact ("nothing to predate"), not a row drawn wrong — refuse, never red.
    const r = await cmd("clip.getPitchEdits", { clipId: clip.id });
    if (!r || r.ok !== true) refuseRun(`the reopened project has no clip ${clip.id}: ${JSON.stringify(r?.error ?? r)}`);
    if (r.result.predatesNaturalTuning !== true) {
      refuseRun(`the reopened vocal does not predate natural tuning (predatesNaturalTuning `
        + `${r.result.predatesNaturalTuning}, isIdentity ${r.result.isIdentity}) — the fixture made no old vocal`);
    }
  }
  e = await openEditor();
  const legacyEcho = async (label, windowWidth) => {
    const s = await stored();
    const g = groupFacts(await echo());
    looks[`legacy${windowWidth}`] = g;
    check(`③ ${label}: the store predates the update (no voice size, slides 0, consonants off)`,
      s.predatesNaturalTuning === true && s.formantCorrection === null
        && s.transitionSlopeCentsPerSecond === 0 && s.keepConsonantsUntuned === false,
      `store ${JSON.stringify({ f: s.formantCorrection, t: s.transitionSlopeCentsPerSecond, c: s.keepConsonantsUntuned, p: s.predatesNaturalTuning })}`);
    check(`③ ${label}: the voice row is DIM with the update line, no amount; Slides says the old tuning set them`,
      g.voice?.needsUpdate === true && g.voice?.amount === null && g.voice?.readout === "—"
        && g.voice?.line === "Older tuning. Tap, or change a note, to update."
        && g.slides?.face === "oldTuning" && g.slides?.selected === null
        && g.slides?.line === "Set by the old tuning. Pick one to take over.",
      JSON.stringify({ voice: g.voice, slides: g.slides }));
    return g;
  };
  await legacyEcho("at 1600", 1600);
  placementCheck("③ at 1600", await echo(), 1600);
  await shoot("legacy1600", "ntu-5-legacy-1600.png");

  // ═════════════════════════════════════════════════════════════════════════
  // AT THE 1208 pt FLOOR
  // ═════════════════════════════════════════════════════════════════════════
  const floor = await width(1208);
  check("the window is at the 1208 pt floor", floor.width === 1208, `window ${floor.width} (floor ${floor.minWidth})`);
  await waitEcho((x) => Math.abs((x.singer?.frame?.x ?? 0) + (x.singer?.frame?.width ?? 0)) <= 1208);
  await legacyEcho("at 1208", 1208);
  placementCheck("③ at 1208", await echo(), 1208);
  await shoot("legacy1208", "ntu-6-legacy-1208.png");

  // ④ the update line, tapped
  {
    const h0 = (await history()).length;
    await stage({ act: "singer", control: "update" });
    const now = await waitEcho((x) => x.singer?.voice?.needsUpdate === false);
    const s = await stored();
    const h = await history();
    check("④ the update line tapped: ONE \"Update Tuning\" step; the store holds all three; the row un-dims",
      h.length === h0 + 1 && h[0] === "Update Tuning" && s.predatesNaturalTuning === false
        && s.formantCorrection === 1 && s.transitionSlopeCentsPerSecond === 3000 && s.keepConsonantsUntuned === true
        && now.singer?.voice?.readout === "100%" && now.singer?.slides?.selected === "smooth",
      `history +${h.length - h0} (${h[0]}); store ${JSON.stringify({ f: s.formantCorrection, t: s.transitionSlopeCentsPerSecond, c: s.keepConsonantsUntuned })}`);
    await shoot("updated1208", "ntu-7-updated-1208.png");
    await must("edit.undo", {});
    const back = await waitEcho((x) => x.singer?.voice?.needsUpdate === true);
    const sb = await stored();
    check("④ Undo brings the OLD vocal back exactly as it was drawn and stored",
      sb.predatesNaturalTuning === true && sb.formantCorrection === null && back.singer?.voice?.needsUpdate === true,
      `store predates ${sb.predatesNaturalTuning}, voice size ${sb.formantCorrection}`);
    // A press on the DIM slider is the same update — never its amount.
    const h1 = (await history()).length;
    await stage({ act: "singer", control: "voiceTrack", fraction: 0.2 });
    const pressed = await echo();
    await stage({ act: "singer", control: "voiceRelease" });
    await waitEcho((x) => x.singer?.voice?.needsUpdate === false);
    const sp = await stored();
    const hp = await history();
    check("④ a press on the dim slider is THE update: no draft drawn, voice size 100% (not 20%), one \"Update Tuning\"",
      pressed.singer?.voice?.dragging === false && pressed.singer?.voice?.amount === null
        && hp.length === h1 + 1 && hp[0] === "Update Tuning" && sp.formantCorrection === 1,
      `mid-press amount ${pressed.singer?.voice?.amount}; store ${sp.formantCorrection}; history ${hp[0]}`);
  }
  // ① and ② at the floor, on the updated vocal (① at 1208 IS ④'s
  // `updated1208` picture: the same state, so it is checked, not re-shot).
  placementCheck("① at 1208", await echo(), 1208);
  for (const step of ["snappy", "quick", "slow", "smooth"]) {
    await pressSlides(step, "1208");
    if (step !== "smooth") await shoot(`slides-${step}-1208`, `ntu-9-slides-${step}-1208.png`);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // THE WOBBLE HELP AT THE FLOOR, beside its hover readout (C5a-F11's scene)
  // ═════════════════════════════════════════════════════════════════════════
  {
    // The Wobble readout needs the render's analysis (the brush gate's
    // `waitForRenderBasis`): wait for the played line's `render` basis, and
    // say NOT RUN — loudly — rather than read a missing readout as a verdict.
    const deadline = Date.now() + 60_000;
    let basis = "";
    let rendering = true;
    while (Date.now() < deadline) {
      const c = (await must("project.snapshot", {})).tracks.flatMap((t) => t.clips ?? [])
        .find((x) => x.id === clip.id);
      rendering = c?.stretchRendering === true;
      basis = (await echo()).playedLine?.basis;
      if (!rendering && basis === "render") break;
      await sleep(300);
    }
    if (rendering || basis !== "render") {
      check("the Wobble help leg — NOT RUN: the render's analysis never arrived", false,
        `basis "${basis}", rendering ${rendering}`);
    }
    await stage({ act: "tool", tool: "wobble" });
    const now = await echo();
    // The LEFTMOST note (on screen at the clip's start, unscrolled), hovered
    // on its body near its left edge — the wobble gate's `bodyOf` — so the
    // dot at its top centre is not what the pointer is over.
    const note = [...(now.notesAsDrawn ?? [])].filter((n) => !n.cleared).sort((a, b) => a.x - b.x)[0];
    if (!note) throw new Error("no drawn note to hover");
    await stage({ act: "hover", x: note.x + Math.min(8, note.width / 2), y: note.y + note.height / 2 });
    const hovered = await waitEcho((x) => (x.wobble?.readout ?? "").length > 0, 4000);
    const help = hovered.interaction?.toolHelp ?? "";
    looks.wobbleHelp1208 = { help, readout: hovered.wobble?.readout };
    await shoot("wobbleHelp1208", "ntu-10-wobble-help-1208.png");
    check("the Wobble help at 1208, beside its readout: the palette holds the WHOLE help string "
      + "(the capture shows whether its two lines draw it whole)",
      help.includes("Hold ⌘ to draw instead.") && help.endsWith("Let go to hear it.")
        && (hovered.wobble?.readout ?? "").length > 0,
      `help "${help}"; readout "${hovered.wobble?.readout}"`);
    await stage({ act: "hoverEnd" });
  }

  {
    const f = noteFront("after the last capture");
    check("FOCUS — no capture took the user's focus (lsappinfo), and every capture reports the app INACTIVE",
      f.name !== null && !stoleFocus(f) && Object.values(facts).every((x) => x.appActive === false),
      `frontmost ${f.name} (pid ${f.pid}); appActive ${JSON.stringify(Object.fromEntries(Object.entries(facts).map(([k, v]) => [k, v.appActive])))}`);
  }
  {
    const shas = Object.entries(facts).map(([k, v]) => [k, v.sha]);
    const dup = shas.filter(([, a], i) => shas.findIndex(([, b]) => b === a) !== i);
    check("every capture exists, is not blank, and no two states share one picture (none is stale)",
      Object.values(facts).every((x) => x.exists && x.ymax !== null && x.ymin !== null && x.ymax - x.ymin > 40)
        && dup.length === 0,
      `${Object.keys(facts).length} captures; duplicates ${JSON.stringify(dup)}`);
  }
  writeFileSync(join(OUT, "ntu-looks.json"), JSON.stringify({ captures, facts, looks, fronts }, null, 2));
  console.log(`captures: ${Object.values(captures).join("  ")}`);
  console.log(`looks: ${join(OUT, "ntu-looks.json")}`);
} catch (err) {
  console.log(`ERROR: ${err?.stack ?? err}`);
  exitCode = 2;
} finally {
  clearTimeout(killer);
  try { session.ws.close(); } catch { /* ignore */ }
  stopLook(GATE);
  console.log("staging stopped (pidfile-exact); its window closed with it");
  const f = noteFront("after the stop");
  console.log(`frontmost after the stop: ${f.name ?? f.raw} (pid ${f.pid}); before: ${front0.name} (pid ${front0.pid})`);
}
{
  const LOG = join(process.env.HOME ?? "", "Library/Logs/DAWPro/main-actor-wedge.log");
  let text = null;
  try { text = readFileSync(LOG, "utf8"); } catch (err) { console.log(`wedge log: unreadable (${err.code}) — ${LOG}`); }
  if (text !== null) {
    const mine = text.split("\n").filter((l) => l.includes(` pid=${session.pid} `));
    console.log(`wedge log: ${mine.length} line(s) from staging pid ${session.pid}`
      + (mine.length ? `\n        ${mine.join("\n        ")}` : ""));
  }
}
if (exitCode !== null) process.exit(exitCode);
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
