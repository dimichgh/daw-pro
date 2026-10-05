import fs from "node:fs";
import path from "node:path";
// The session builder. One socket, many commands, everything against STAGING.
//
// ⚠ PORT DISCIPLINE: this file must never talk to 17600. That is the user's
// live app and their real project; the MCP tools already point there, which is
// exactly why the film is driven from here instead.
import { connect, send, close } from "/Users/dsemenov/Views/daw-pro/claude-plugin/skills/ui-capture/scripts/dawctl.mjs";

const PORT = process.env.DAW_CONTROL_PORT || "17695";
if (PORT === "17600") { console.error("REFUSING: 17600 is the live app."); process.exit(1); }

// ⚠⚠ EVERY CAPTURE PATH MUST BE ABSOLUTE, AND THAT IS NOT A STYLE RULE.
// `debug.captureUI` takes a path over the WIRE and the APP resolves it against
// the APP's cwd -- which is the repo root, not the build script's directory.
// A relative path therefore writes somewhere else entirely while the command
// returns `ok` with a real PNG at a plausible name: the exact shape of a wrong
// answer that looks like a right one. MEASURED 2026-09-06: two captures from a
// film build landed in /Users/dsemenov/Views/daw-pro/shots/, a directory that
// did not previously exist, and the build reported success.
// Worse in `burst()`: `dir` is used BOTH for fs calls (script cwd) and for wire
// paths (app cwd), so the "clear stale frames first" step cleaned one directory
// while the app filled another.
export const abspath = (p) => path.resolve(p);
export const SHOTS = abspath(process.argv.includes("--shots-dir")
  ? process.argv[process.argv.indexOf("--shots-dir") + 1]
  : process.env.SESSION_SHOTS || "./shots");

export async function open() {
  await connect(`ws://127.0.0.1:${PORT}`);
  return true;
}
export async function cmd(method, params = {}) {
  const r = await send(method, params);
  if (r && r.ok === false) throw new Error(`${method}: ${r.error || JSON.stringify(r).slice(0, 200)}`);
  return r && r.result !== undefined ? r.result : r;
}
export async function shot(name) {
  await cmd("debug.captureUI", { path: `${SHOTS}/${name}.png` });
  return `${SHOTS}/${name}.png`;
}
export { close };

// ---- helpers the chapters all need -----------------------------------------

/** A note list for clip.addMIDI. Beats are CLIP-relative. */
export const n = (startBeat, pitch, lengthBeats, velocity = 100) =>
  ({ startBeat, pitch, lengthBeats, velocity });

/** Deterministic pseudo-random, so a re-run rebuilds the SAME track.
 *  ⚠ Math.random() would make every rebuild a different song, and then no
 *  measurement in the film could be reproduced by anyone, including me. */
export function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}

export async function addTrack(name, opts = {}) {
  const t = await cmd("track.add", { kind: "instrument", name });
  const id = t.id || (t.track && t.track.id);
  if (!id) throw new Error(`track.add returned no id for ${name}`);
  if (opts.instrument) await cmd("track.setInstrument", { trackId: id, ...opts.instrument });
  if (opts.volume !== undefined) await cmd("track.setVolume", { trackId: id, volume: opts.volume });
  if (opts.pan !== undefined) await cmd("track.setPan", { trackId: id, pan: opts.pan });
  return id;
}

export async function addClip(trackId, startBeat, lengthBeats, notes, name) {
  // ⚠ THE WIRE AND THE MCP TOOL DISAGREE, and the wire is what this file uses.
  // clip.addMIDI takes `atBeat`, not `startBeat`, and has no `returnNotes` --
  // that opt-out is the MCP layer's. Sending the MCP shape here is refused
  // outright, which is the good case; the bad case would be silent acceptance.
  const c = await cmd("clip.addMIDI", {
    trackId, atBeat: startBeat, lengthBeats, notes, ...(name ? { name } : {}),
  });
  return c.id || (c.clip && c.clip.id);
}

// ---------------------------------------------------------------- bursts
// A DEMO SEGMENT USED TO BE A FROZEN PICTURE while the sound played. This
// photographs the app WHILE THE TRANSPORT RUNS, so the playhead crosses the
// notes it is playing and the position readout counts up with it.
//
// ⚠ REAL TIME COMES FOR FREE. `debug.captureUI` costs ~285 ms per frame
// (measured; `scale` does not change it), so the transport advances ~285 ms
// between frames and a sequence played back at the MEASURED capture rate is
// the playback, correctly paced. meta.json records that rate rather than
// assuming one.
//
// ⚠ MASTER TO ZERO FIRST. This plays through whatever output device the
// machine has, and nobody asked for eight seconds of siren out of their
// speakers. The audio was already rendered offline; the burst only wants
// pictures.
export const burst = async (name, seconds, fromBeat = 0, opts = {}) => {
  const root = process.env.SESSION_BURSTS;
  if (!root) return;
  const dir = abspath(`${root}/${name}`);   // absolute: see the note on SHOTS
  fs.mkdirSync(dir, { recursive: true });
  // ⚠ CLEAR IT FIRST. A re-shoot writes f0001..fN and STOPS; the previous
  // take's frames past N survive, and `assemble.py` globs the directory -- so a
  // shorter re-shoot silently ends on frames from the run it was meant to
  // replace. Found by counting: a 18-frame re-shoot left 25 files behind.
  for (const f of fs.readdirSync(dir)) if (/^f\d+\.png$/.test(f)) fs.rmSync(`${dir}/${f}`);
  const ov = await cmd("project.overview", {});
  const clip = ov.tracks?.[0]?.clips?.[0]?.id;
  await cmd("mixer.setMasterVolume", { volume: 0 });
  // ⚠ A WHOLE ARRANGEMENT IS THE WRONG THING TO SHOW IN A PIANO ROLL. One
  // clip's roll, scrolled to bar 1 while the playhead is at bar 36, is an
  // empty grid -- measured by looking at the first take of this burst. For the
  // multi-track chapters show the ARRANGE view and let it follow the playhead.
  if (opts.arrange) {
    await cmd("debug.panelLayout", { editorMaximized: false, followPlayhead: true });
    await cmd("debug.followPlayhead", { enabled: true });
  } else {
    await cmd("debug.panelLayout", { editorMaximized: true });
  }
  // captureUI's OWN selectClip parameter opens the piano roll. There is no
  // debug.selectClip command -- calling that name is how the first cut of the
  // film shipped without a single shot of the note editor.
  if (clip && !opts.arrange) {
    await cmd("debug.captureUI", { path: `${dir}/_open.png`, selectClip: clip });
    // ⚠ AND THEN POINT IT AT THE NOTES. The roll opens anchored high in the
    // 128-row pitch stack, so a low clip -- a 49 Hz heartbeat at C1, an 808 at
    // F1 -- opens on an EMPTY GRID: the notes are real and are drawn in the
    // minimap and the velocity lane, just below the viewport. Row height is not
    // a workaround; MEASURED at the 10 pt floor the grid still bottomed out at
    // F2. `debug.panelLayout {pianoRollCenterPitch}` scrolls the pitch axis.
    //
    // It goes AFTER the open (the scroller has to exist for the request to land)
    // and after any row-height change (that re-pins the axis and would undo it).
    // The pitch is the clip's own MEDIAN, so it is right for every chapter and
    // no chapter is special-cased.
    const gn = await cmd("clip.getNotes", { clipId: clip });
    const ps = (gn.notes || []).map((x) => x.pitch).sort((a, b) => a - b);
    if (ps.length) await cmd("debug.panelLayout",
                             { pianoRollCenterPitch: ps[Math.floor(ps.length / 2)] });
  }
  await cmd("transport.seek", { beats: fromBeat });
  await cmd("transport.play", {});
  const t0 = Date.now();
  let i = 0;
  while ((Date.now() - t0) / 1000 < seconds) {
    i += 1;
    await cmd("debug.captureUI", { path: `${dir}/f${String(i).padStart(4, "0")}.png` });
  }
  await cmd("transport.stop", {});
  const fps = i / ((Date.now() - t0) / 1000);
  fs.writeFileSync(`${dir}/meta.json`,
                   JSON.stringify({ fps: +fps.toFixed(4), frames: i, seconds }, null, 1));
  console.log(`  burst ${name}: ${i} frames at ${fps.toFixed(2)} fps`);
};
