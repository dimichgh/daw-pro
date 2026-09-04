// The session builder. One socket, many commands, everything against STAGING.
//
// ⚠ PORT DISCIPLINE: this file must never talk to 17600. That is the user's
// live app and their real project; the MCP tools already point there, which is
// exactly why the film is driven from here instead.
import { connect, send, close } from "/Users/dsemenov/Views/daw-pro/claude-plugin/skills/ui-capture/scripts/dawctl.mjs";

const PORT = process.env.DAW_CONTROL_PORT || "17695";
if (PORT === "17600") { console.error("REFUSING: 17600 is the live app."); process.exit(1); }

export const SHOTS = process.argv.includes("--shots-dir")
  ? process.argv[process.argv.indexOf("--shots-dir") + 1]
  : process.env.SESSION_SHOTS || "./shots";

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
