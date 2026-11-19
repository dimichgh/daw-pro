// states.mjs — the film's project STATES, one folder each, and the note-editor
// helpers every phase shares. Library only.
//
// ⭐ EVERY STATE IS SAVED AS work/states/<state>/Voice Film 2026-10-11.dawproj —
// the SAME basename in a different folder. The app's title bar shows the
// project's file name, so a state saved as "cp2-sour.dawproj" put "cp2-sour"
// on screen in every exploratory still (out/shots/explore/). With one name,
// every frame reads "Voice Film 2026-10-11".
//
// ⛔ THE SUNG TAKE IS NEVER RE-MADE HERE. states/sung is a copy of the take
// sing.mjs produced (seed 2611). Every number the film speaks (cents, wobble,
// voice size) was measured on renders of THESE states; a re-sung take is a new
// performance and would silently invalidate all of them. Whether the same seed
// reproduces the same take is UNTESTED, so it is not relied on.
import { existsSync, mkdirSync, cpSync, writeFileSync } from "node:fs";
import { cmd, sleep, VOICE_HOME } from "./wire.mjs";

export const NAME = "Voice Film 2026-10-11.dawproj";
export const STATES = `${VOICE_HOME}/work/states`;
export const statePath = (s) => `${STATES}/${s}/${NAME}`;
export const VOCAL = "5495F530-8D76-4747-8E73-AB2A4CA7686E";   // the lead vocal clip (sing.mjs)

export function seedSung() {
  // The sung take + the mix decision (drums at 0.5), saved 2026-10-11 as
  // work/cp1-sung.dawproj. Copied once; never overwritten.
  if (existsSync(statePath("sung"))) return;
  mkdirSync(`${STATES}/sung`, { recursive: true });
  cpSync(`${VOICE_HOME}/work/cp1-sung.dawproj`, statePath("sung"), { recursive: true });
}

export async function openState(s) {
  if (!existsSync(statePath(s))) throw new Error(`no state ${s} at ${statePath(s)}`);
  await cmd("project.open", { path: statePath(s), discardChanges: true }, 120000);
  await cmd("ui.showMixer", { show: false });
}

export async function saveState(s) {
  mkdirSync(`${STATES}/${s}`, { recursive: true });
  const r = await cmd("project.save", { path: statePath(s) }, 120000);
  if (r.warnings?.length) console.warn(`save ${s}: ${JSON.stringify(r.warnings)}`);
  return r;
}

export const pe = (p = {}) => cmd("debug.pitchEditor", p, 30000);

export async function steps(list) {
  for (const s of list) await pe(s);
  return pe({});
}

// Open the note editor on the vocal, maximized, at a known row height, and
// wait until it has read the take ("Found 33 notes …").
export async function openEditor({ rowHeight = 14 } = {}) {
  await cmd("view.selectClip", { clipId: VOCAL });
  await cmd("view.openPitchEditor", { clipId: VOCAL });
  await cmd("view.panelLayout", { editorMaximized: true });
  await cmd("debug.panelLayout", { pitchEditorRowHeight: rowHeight });
  for (let i = 0; i < 60; i++) {
    const e = await pe({});
    if (e.chrome?.statusKey === "ready" && e.notesAsDrawn?.length) return e;
    await sleep(500);
  }
  throw new Error("the note editor never finished reading the take");
}

// A note's drawn rectangle, found by its TIME in the take (seconds from the
// clip's start) — never by id (ids are minted per analysis) and never by a
// guessed pixel.
//
// ⚠ A TAKE NOBODY HAS EDITED HAS NO STORED NOTE TABLE: the echo's `notes` is
// EMPTY while `notesAsDrawn` holds all 54 (MEASURED on the sung state). So a
// drawn note's time comes from its x when there is no record: content x 0 is
// the clip's first beat, `zoom.pixelsPerBeat` per beat, 0.6 s per beat at
// 100 BPM (checked: "door" drawn at x 157.9 = 2.96 s, its stored start).
export const TEMPO = 100;
export function noteAtTime(e, sec, { pitched = true } = {}) {
  const spb = 60 / TEMPO, ppb = e.zoom.pixelsPerBeat;
  const all = e.notesAsDrawn.map((d) => {
    const rec = (e.notes || []).find((n) => n.id === d.id) || {};
    return { ...rec, id: d.id, look: d.look, x: d.x, y: d.y, w: d.width, h: d.height,
             startSeconds: rec.startSeconds ?? (d.x / ppb) * spb,
             endSeconds: rec.endSeconds ?? ((d.x + d.width) / ppb) * spb,
             cx: d.x + d.width / 2, cy: d.y + d.height / 2 };
  });
  const hit = all.find((n) => sec >= n.startSeconds && sec < n.endSeconds
                              && (!pitched || n.look === "note"));
  if (!hit) throw new Error(`no ${pitched ? "pitched " : ""}note at ${sec}s`);
  return hit;
}

export const edits = () => cmd("clip.getPitchEdits", { clipId: VOCAL });

export function dump(name, obj) {
  writeFileSync(`${VOICE_HOME}/work/${name}.json`, JSON.stringify(obj, null, 2));
}
