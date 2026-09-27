// W7-NTU U3 GATE — THE VOICE TOOL (natural tuning §1(f) items 2-3, R9, R11,
// R22, R26) AND THE PRESET CARD'S SETTINGS SENTENCE (W7-D2's item 3), LOOKED
// AT on a REAL app on staging (port 17695 ONLY; 17600 is the user's LIVE app
// and is never touched. Staging is stopped PIDFILE-EXACT through
// `_pitch-editor-look.mjs`'s `stopLook`, never pkill/pgrep — its window closes
// with it).
//
// ⭐ A SPY GATE WITH A SECOND INSTRUMENT. The pane says what it drew
// (`debug.pitchEditor`'s `voice` block: every mark's value, chip and place,
// the live draft, the palette's readout; `interaction.paletteLabels`,
// `toolHelp`, `refusalText`), and the STORE is read back over the wire
// independently (`clip.getPitchEdits`' per-note `formantOffsetSemitones`,
// `edit.history`) — never one instrument. Presses are STAGED through the
// pane's own gesture callbacks (`debug.pitchEditor` press → drag* → release),
// the path a pointer takes from the router to the model, the app's funnel and
// the store; the double-click is a release carrying `clicks: 2`.
//
// THE STATES, EACH CAPTURED ONCE, ALL AT THE 1208 pt FLOOR (the narrowest
// window: four palette slots, the help and a readout on one row)
//   v1 the Voice tool engaged, a note hovered: four slots (Move, Split,
//      Wobble, Voice), the whole Voice help, "Voice: as sung";
//   v2 a drag UP mid-flight: the live bar and chip "Brighter 2.0", the readout
//      "Voice: brighter 2.0", NOTHING stored and no undo step yet;
//   v3 after that release (ONE "Set Note Voice" step, the store at +2.0) and a
//      ⌥ drag DOWN on another note (48 pt with ⌥ = −1.0): two marks, "Brighter
//      2.0" and "Deeper 1.0";
//   v4 a double-click puts the first note back as sung: ONE step, the store
//      at 0, one mark left;
//   v5 a note shorter than 80 ms (a 70 ms split: the store's split floor is
//      60 ms), hovered: R11's line;
//   v6 the preset card when the ONLY change since the preset is a SETTING
//      (Slides → Quick): the note list says "any", and the card ends by saying
//      Slides changes to Smooth.
// plus, echo-and-store only (a context menu and a refusal line are not
// pictures a staged step can take): the note menu's "Voice: Deeper 2.0" and
// "Voice: As sung" (each ONE step), a press on a SOUND refused in words with
// nothing stored, and a preset erasing every note's Voice (the card's new
// "any note you made deeper or brighter" is a real loss).
//
// WHAT THIS PROVES (by echo + store, and by the captures a person looks at)
//   • the tool's bar and chip draw the value the store then holds, and only
//     the release writes it (one undo step per gesture, named "Set Note Voice");
//   • ⌥ divides the travel by 4; a double-click resets; a sound is refused;
//   • the palette holds four slots at 1208 with the whole help string;
//   • the preset card's words are true when only a setting changed;
//   • THE USER'S FOCUS STAYS PUT: staging launches with
//     DAWPRO_STAGING_NO_ACTIVATE=1, every capture reports the app INACTIVE, and
//     the frontmost app (lsappinfo) is never the staging app — before the
//     launch, after it, after the last capture and after the stop.
//
// WHAT THIS DOES NOT PROVE
//   • a real pointer (m23-g1): the presses are the pane's own callbacks, and
//     the live chord reader (`PitchEditorChord.current`, the click count
//     included) is one line no staged step runs;
//   • that the help is not truncated: the echo carries the STRING, never its
//     pixels — the v1 capture is where a person sees it whole;
//   • sound: the track is muted (the render's formant path is NT-E1's gate).
//
// PRECONDITIONS
//   • AN UNLOCKED SCREEN — checked FIRST, before provenance, fixtures or a
//     launch: with the screen locked the frontmost app is `loginwindow` and a
//     capture proves nothing. EXIT 3, "PENDING".
//   • PROVENANCE — `.build/debug/DAWApp` newer than every file under
//     `Sources/` and `Package.swift` (with a positive control on the same
//     `find`); else EXIT 2. Build under a heavy slot right before running it.
//
//   node scripts/gates/m23ap-ntu-voice.mjs
//
// Env: M23AP_NTU_VOICE_OUT (captures, fixture, the named project; default
//      /tmp/m23ap-ntu-voice).
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

const GATE = "m23ap-ntu-voice";
const OUT = process.env.M23AP_NTU_VOICE_OUT || "/tmp/m23ap-ntu-voice";
const STAGING_NAME = STAGING_DEFAULTS_DOMAIN;

// The words, verbatim from `PitchEditorFormantCopy` (pinned there by
// `PitchEditorVoiceToolTests.wordsByValue`): a changed word is a changed gate.
const WORDS = {
  labels: ["Move", "Split", "Wobble", "Voice"],
  help: "Drag a note up or down to make that part of the voice brighter or deeper, without changing "
    + "the note. Hold ⌥ for finer steps. Double-click a note to put it back as sung. Hold ⌘ to "
    + "draw instead. Let go to hear it.",
  asSung: "Voice: as sung",
  tooShort: "Too short to change the voice of this note alone",
  soundRefusal: "This is a breath or a consonant, so it has no voice to make deeper or brighter.",
  handEdits: "any note you moved or split by hand, any note you made deeper or brighter, "
    + "any wobble you changed and any pitch line you drew",
  slidesToSmooth: "“Slides” changes to Smooth.",
};

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
// FIXTURE — three sung notes after the helper's 0.12 s noise burst (a sound)
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

const near = (a, b) => typeof a === "number" && Math.abs(a - b) < EPS;
const centre = (n) => ({ x: n.x + n.width / 2, y: n.y + n.height / 2 });

try {
  {
    const f = noteFront("after the launch");
    check("FOCUS — the launch did not take the user's focus (lsappinfo)",
      f.name !== null && f.pid !== null && !stoleFocus(f),
      `frontmost ${front0.name} (pid ${front0.pid}) → ${f.name ?? f.raw} (pid ${f.pid}); staging pid ${session.pid}`);
  }

  // ── a NAMED project of this gate's own; the vocal tuned by a preset, muted
  await must("project.new", { discardChanges: true });
  const track = await must("track.add", { name: "NTU Voice Vocal", kind: "audio" });
  const clip = await must("clip.addAudio", { trackId: track.id, path: fixturePath, atBeat: 0 });
  await must("clip.autoCorrectPitch", { clipId: clip.id });
  await must("track.setMute", { trackId: track.id, muted: true });
  const projectPath = join(OUT, "NTU Voice.dawproj");
  await must("project.save", { path: projectPath });
  console.log(`project: ${projectPath} — clip ${clip.id.slice(0, 8)}`);

  /** The STORE's Voice per note id, over the wire (the second instrument). */
  async function storedVoices() {
    const s = await must("clip.getPitchEdits", { clipId: clip.id });
    return { set: s, byId: Object.fromEntries((s.segments ?? []).map((g) => [g.id, g.formantOffsetSemitones])) };
  }
  const tune = (params) => must("debug.tuneVocal", { clipId: clip.id, ...params });

  await must("debug.windowFrame", { width: 1208 });
  await sleep(800);
  {
    const opened = await must("view.openPitchEditor", { clipId: clip.id });
    if (opened.opened !== true) refuseRun(`view.openPitchEditor did not open: ${opened.reason}`);
    await waitPitchEditorReady(cmd, { timeoutMs: 30_000, intervalMs: 250 });
    await must("transport.stop", {});
  }
  let e = await waitEcho((x) => (x.notesAsDrawn ?? []).filter((n) => n.origin !== "unpitched").length >= 3);
  // The three SUNG notes, left to right (a sound is not a note here).
  const sung = () => [...(e.notesAsDrawn ?? [])].filter((n) => n.origin !== "unpitched" && !n.cleared)
    .sort((a, b) => a.x - b.x);
  if (sung().length < 3) refuseRun(`the preset drew ${sung().length} sung note(s), not 3 — a fixture fact`);
  const [n1, n2, n3] = sung();

  // ═════════════════════════════════════════════════════════════════════════
  // v1 — THE VOICE TOOL ENGAGED, A NOTE HOVERED
  // ═════════════════════════════════════════════════════════════════════════
  await stage({ act: "tool", tool: "voice" });
  await stage({ act: "hover", x: centre(n2).x, y: centre(n2).y });
  e = await waitEcho((x) => x.voice?.readout === WORDS.asSung);
  looks.v1 = { labels: e.interaction?.paletteLabels, help: e.interaction?.toolHelp, readout: e.voice?.readout };
  check("v1: four slots (Move, Split, Wobble, Voice), the Voice tool engaged, its WHOLE help, \"Voice: as sung\"",
    JSON.stringify(e.interaction?.paletteLabels) === JSON.stringify(WORDS.labels) && e.tool === "voice"
      && e.interaction?.toolHelp === WORDS.help && e.voice?.readout === WORDS.asSung
      && (e.voice?.marks ?? []).length === 0,
    JSON.stringify(looks.v1));
  await shoot("v1", "ntu-v1-tool-1208.png");

  // ═════════════════════════════════════════════════════════════════════════
  // v2 — A DRAG UP, MID-FLIGHT: drawn live, nothing stored
  // ═════════════════════════════════════════════════════════════════════════
  const h0 = (await history()).length;
  const p2 = centre(n2);
  await stage({ act: "press", x: p2.x, y: p2.y });
  await stage({ act: "drag", x: p2.x, y: p2.y - 12 });
  await stage({ act: "drag", x: p2.x, y: p2.y - 24 });
  e = await waitEcho((x) => x.voice?.draft?.dragging === true && near(x.voice?.draft?.semitones, 2));
  {
    const live = (e.voice?.marks ?? []).find((m) => m.segmentId === n2.id);
    const s = await storedVoices();
    looks.v2 = { draft: e.voice?.draft, live, readout: e.voice?.readout, stored: s.byId[n2.id] };
    check("v2: 24 pt up is +2.0, drawn LIVE (bar + chip \"Brighter 2.0\", readout \"Voice: brighter 2.0\"); "
      + "the store still 0 and no undo step yet",
      near(e.voice?.draft?.semitones, 2) && live?.live === true && live?.chip === "Brighter 2.0"
        && near(live?.offsetFraction, 2 / 6) && e.voice?.readout === "Voice: brighter 2.0"
        && s.byId[n2.id] === 0 && (await history()).length === h0,
      JSON.stringify(looks.v2));
  }
  await shoot("v2", "ntu-v2-drag-1208.png");

  // ═════════════════════════════════════════════════════════════════════════
  // v3 — THE RELEASE WRITES ONCE; a ⌥ drag DOWN on the third note
  // ═════════════════════════════════════════════════════════════════════════
  await stage({ act: "release", x: p2.x, y: p2.y - 24 });
  e = await waitEcho((x) => x.voice?.draft === null
    && (x.voice?.marks ?? []).some((m) => m.segmentId === n2.id && m.live === false));
  {
    const s = await storedVoices();
    const h = await history();
    check("v3: the release is ONE \"Set Note Voice\" step and the store holds +2.0 for that note alone",
      h.length === h0 + 1 && h[0] === "Set Note Voice" && s.byId[n2.id] === 2
        && s.byId[n1.id] === 0 && s.byId[n3.id] === 0,
      `history +${h.length - h0} (${h[0]}); store ${JSON.stringify([s.byId[n1.id], s.byId[n2.id], s.byId[n3.id]])}`);
  }
  const p3 = centre(n3);
  await stage({ act: "press", x: p3.x, y: p3.y });
  await stage({ act: "drag", x: p3.x, y: p3.y + 24, option: true });
  await stage({ act: "drag", x: p3.x, y: p3.y + 48, option: true });
  e = await waitEcho((x) => x.voice?.draft?.fine === true && near(x.voice?.draft?.semitones, -1));
  const fineDraft = e.voice?.draft;
  await stage({ act: "release", x: p3.x, y: p3.y + 48, option: true });
  e = await waitEcho((x) => x.voice?.draft === null && (x.voice?.marks ?? []).length === 2);
  {
    const s = await storedVoices();
    const h = await history();
    const chips = (e.voice?.marks ?? []).map((m) => m.chip).sort();
    looks.v3 = { fineDraft, marks: e.voice?.marks, stored: [s.byId[n2.id], s.byId[n3.id]] };
    check("v3: with ⌥ held, 48 pt down is −1.0 (a quarter of the travel); ONE more step; two marks drawn, "
      + "\"Brighter 2.0\" and \"Deeper 1.0\", as the store holds them",
      fineDraft?.fine === true && near(fineDraft?.semitones, -1) && h.length === h0 + 2 && h[0] === "Set Note Voice"
        && s.byId[n3.id] === -1 && s.byId[n2.id] === 2
        && JSON.stringify(chips) === JSON.stringify(["Brighter 2.0", "Deeper 1.0"]),
      JSON.stringify(looks.v3));
  }
  await shoot("v3", "ntu-v3-two-voices-1208.png");

  // ═════════════════════════════════════════════════════════════════════════
  // v4 — A DOUBLE-CLICK PUTS THE NOTE BACK AS SUNG
  // ═════════════════════════════════════════════════════════════════════════
  await stage({ act: "press", x: p2.x, y: p2.y });
  await stage({ act: "release", x: p2.x, y: p2.y, clicks: 2 });
  e = await waitEcho((x) => (x.voice?.marks ?? []).length === 1);
  {
    const s = await storedVoices();
    const h = await history();
    check("v4: a double-click (the release's clicks: 2) is ONE \"Set Note Voice\" step back to 0; one mark left",
      e.lastRelease?.action === "formantReset" && h.length === h0 + 3 && h[0] === "Set Note Voice"
        && s.byId[n2.id] === 0 && s.byId[n3.id] === -1 && (e.voice?.marks ?? [])[0]?.segmentId === n3.id,
      `lastRelease ${JSON.stringify(e.lastRelease)}; history +${h.length - h0}; store ${JSON.stringify([s.byId[n2.id], s.byId[n3.id]])}`);
  }
  await shoot("v4", "ntu-v4-reset-1208.png");

  // ═════════════════════════════════════════════════════════════════════════
  // THE NOTE MENU'S VOICE ROW (echo + store)
  // ═════════════════════════════════════════════════════════════════════════
  {
    const p1 = centre(n1);
    await stage({ act: "noteMenu", action: "voiceDeeper", x: p1.x, y: p1.y });
    await waitEcho((x) => (x.voice?.marks ?? []).some((m) => m.segmentId === n1.id));
    const s = await storedVoices();
    const h = await history();
    check("menu: \"Voice: Deeper 2.0\" on a note is ONE \"Set Note Voice\" step to −2.0",
      h.length === h0 + 4 && h[0] === "Set Note Voice" && s.byId[n1.id] === -2,
      `history +${h.length - h0} (${h[0]}); store ${s.byId[n1.id]}`);
    await stage({ act: "noteMenu", action: "voiceAsSung", x: p1.x, y: p1.y });
    await waitEcho((x) => !(x.voice?.marks ?? []).some((m) => m.segmentId === n1.id));
    const s2 = await storedVoices();
    const h2 = await history();
    check("menu: \"Voice: As sung\" is ONE more step back to 0",
      h2.length === h0 + 5 && h2[0] === "Set Note Voice" && s2.byId[n1.id] === 0,
      `history +${h2.length - h0} (${h2[0]}); store ${s2.byId[n1.id]}`);
  }

  // ═════════════════════════════════════════════════════════════════════════
  // A SOUND IS REFUSED IN WORDS (echo + store)
  // ═════════════════════════════════════════════════════════════════════════
  {
    const sound = [...(e.notesAsDrawn ?? [])].find((n) => n.origin === "unpitched");
    if (!sound) {
      check("sound: NOT RUN — the preset found no sound in the fixture's noise burst", false,
        `origins ${JSON.stringify((e.notesAsDrawn ?? []).map((n) => n.origin))}`);
    } else {
      const before = await storedVoices();
      const hb = (await history()).length;
      const ps = centre(sound);
      await stage({ act: "press", x: ps.x, y: ps.y });
      const refused = await waitEcho((x) => (x.interaction?.refusalText ?? "") !== "");
      if (refused.press?.inFlight === true) await stage({ act: "release", x: ps.x, y: ps.y });
      const after = await storedVoices();
      check("sound: a press on a sound is refused in words, drafts nothing and stores nothing",
        refused.interaction?.refusalText === WORDS.soundRefusal && refused.voice?.draft === null
          && JSON.stringify(after.byId) === JSON.stringify(before.byId) && (await history()).length === hb,
        `refusal "${refused.interaction?.refusalText}"; draft ${JSON.stringify(refused.voice?.draft)}`);
    }
  }

  // ═════════════════════════════════════════════════════════════════════════
  // v5 — A NOTE SHORTER THAN 80 ms, HOVERED (R11)
  // ═════════════════════════════════════════════════════════════════════════
  {
    const s = await storedVoices();
    const seg = (s.set.segments ?? []).find((g) => g.id === n1.id);
    if (!seg) throw new Error("the first note is not in the store");
    const known = new Set((s.set.segments ?? []).map((g) => g.id));
    await must("clip.splitNote", { clipId: clip.id, segmentId: n1.id, atSourceSeconds: seg.endSeconds - 0.07 });
    const split = await storedVoices();
    const piece = (split.set.segments ?? []).find((g) => !known.has(g.id));
    if (!piece) throw new Error("the split made no new note");
    if (!(piece.endSeconds - piece.startSeconds < 0.08)) {
      refuseRun(`the split's piece is ${piece.endSeconds - piece.startSeconds} s — not shorter than 80 ms`);
    }
    e = await waitEcho((x) => (x.notesAsDrawn ?? []).some((n) => n.id === piece.id));
    const short = (e.notesAsDrawn ?? []).find((n) => n.id === piece.id);
    if (!short) throw new Error("the 70 ms piece was not drawn");
    await stage({ act: "hover", x: short.x + short.width / 2, y: short.y + short.height / 2 });
    e = await waitEcho((x) => x.voice?.readout === WORDS.tooShort, 4000);
    looks.v5 = { short, readout: e.voice?.readout };
    check("v5: a 70 ms note (a split), hovered in the Voice tool, says R11's line",
      e.voice?.readout === WORDS.tooShort, JSON.stringify(looks.v5));
    await shoot("v5", "ntu-v5-too-short-1208.png");
    await stage({ act: "hoverEnd" });
  }

  // ═════════════════════════════════════════════════════════════════════════
  // v6 — THE PRESET CARD WHEN ONLY A SETTING CHANGED (W7-D2's item 3)
  // ═════════════════════════════════════════════════════════════════════════
  {
    // Hand edits (a Voice, a split) first: the card asks, and Replace erases
    // every Voice — the list's new item is a real loss.
    const asked = await tune({ preset: "natural" });
    check("card: hand edits (a Voice, a split) make the preset ASK, with the \"any\" list",
      asked.pending?.body?.includes(WORDS.handEdits) === true,
      `pending ${JSON.stringify(asked.pending?.body ?? null)}`);
    await tune({ answer: "replace" });
    const deadline = Date.now() + 20_000;
    let fresh = await tune({});
    while (fresh.clip?.handEditedSinceAutoCorrect !== false && Date.now() < deadline) {
      await sleep(250);
      fresh = await tune({});
    }
    const s = await storedVoices();
    const voices = (s.set.segments ?? []).map((g) => g.formantOffsetSemitones);
    check("card: \"Replace my edits\" applies the preset, and no note keeps a Voice",
      fresh.clip?.handEditedSinceAutoCorrect === false && voices.length > 0 && voices.every((v) => v === 0),
      `handEdited ${fresh.clip?.handEditedSinceAutoCorrect}; voices ${JSON.stringify(voices)}`);
    // Only a SETTING changes: Slides → Quick (one step), no note touched.
    await waitEcho((x) => x.singer?.drawn === true);
    await stage({ act: "singer", control: "slides", step: "quick" });
    await waitEcho((x) => x.singer?.slides?.selected === "quick");
    const card = await tune({ preset: "tight" });
    looks.v6 = { body: card.pending?.body, title: card.pending?.title };
    check("v6: a Slides pick alone makes the preset ASK; the card's list says \"any\", and it ends by saying "
      + "Slides changes to Smooth (a kept pick is not named: none was made)",
      card.pending?.title === "Replace your hand edits?" && card.pending?.body?.includes(WORDS.handEdits) === true
        && card.pending?.body?.endsWith(`any pitch line you drew. ${WORDS.slidesToSmooth}`) === true,
      JSON.stringify(looks.v6));
    await shoot("v6", "ntu-v6-card-settings-1208.png");
    await tune({ answer: "replace" });
    const deadline2 = Date.now() + 20_000;
    let after = await storedVoices();
    while (after.set.transitionSlopeCentsPerSecond !== 3000 && Date.now() < deadline2) {
      await sleep(250);
      after = await storedVoices();
    }
    check("v6: Replace lands Slides on Smooth (3000), as the card said",
      after.set.transitionSlopeCentsPerSecond === 3000,
      `store ${after.set.transitionSlopeCentsPerSecond}`);
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
  writeFileSync(join(OUT, "ntu-voice-looks.json"), JSON.stringify({ captures, facts, looks, fronts }, null, 2));
  console.log(`captures: ${Object.values(captures).join("  ")}`);
  console.log(`looks: ${join(OUT, "ntu-voice-looks.json")}`);
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
