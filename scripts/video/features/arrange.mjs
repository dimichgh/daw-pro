#!/usr/bin/env node
// The arrangement engine for the demo film.
//
// THREE ARRANGEMENTS, ONE AXIS APART: they share this file's structure, tempo,
// track layout, drum patterns and effect chain, and differ ONLY in source
// material (original / Grieg / Beethoven). That is deliberate — the user's
// standing rule is to ship options that differ on ONE axis, because then their
// pick actually means something.
//
// ⚠ PORT DISCIPLINE: 17695 only. 17600 is the user's live app.
// ⚠ ONE WIRE SCRIPT AT A TIME: every run begins with project.new.

import { connect, send, close } from "/Users/dsemenov/Views/daw-pro/claude-plugin/skills/ui-capture/scripts/dawctl.mjs";

const PORT = process.env.DAW_CONTROL_PORT || "17695";
if (PORT === "17600") { console.error("REFUSING: 17600 is the user's live app."); process.exit(1); }

export async function open() { await connect(`ws://127.0.0.1:${PORT}`); }
export { close };

export async function cmd(method, params = {}) {
  const r = await send(method, params);
  return r && r.result !== undefined ? r.result : r;
}

// ---------------------------------------------------------------- drum voices
// MEASURED at Sources/DAWCore/DrumKit.swift:74-85, not assumed: this kit uses
// 36..43 (the MPC / Drum-Rack base) so it lands one-to-one on the 4x4 pad grid.
// General MIDI deliberately NOT followed — GM scatters these eight across 35-57,
// which would make the kit unplayable on a pad grid.
export const VOICE = {
  kick: 36, snare: 37, closedHat: 38, openHat: 39,
  clap: 40, tom: 41, rim: 42, cymbal: 43,
};

// ------------------------------------------------------------ the pattern DSL
// 16 characters = one bar of sixteenth notes.
//   X = accent   x = normal   o = ghost   - = rest
//
// ⚠ THE ACCENT NUMBERS ARE NOT ARBITRARY. The kit's `accentThreshold` defaults
// to 100, so a hit at 112 is ACCENTED by the instrument itself and one at 84 is
// not. Picking 112/84 means the pattern is hardware-correct without the pattern
// needing to know anything about the velocity curve.
export const VEL = { X: 112, x: 84, o: 52 };

export function pattern(voice, bars, str) {
  const notes = [];
  const perBar = 16;
  for (let bar = 0; bar < bars; bar++) {
    for (let i = 0; i < perBar; i++) {
      const c = str[i % str.length];
      if (c === "-" || c === undefined) continue;
      const vel = VEL[c];
      if (vel === undefined) throw new Error(`pattern char '${c}' is not one of X x o -`);
      notes.push({ startBeat: bar * 4 + i * 0.25, pitch: voice, lengthBeats: 0.25, velocity: vel });
    }
  }
  return notes;
}

/** Merge several voice patterns into one note list. */
export const layers = (...lists) => [].concat(...lists);

/** Repeat a note list every `cycleBeats` until `totalBeats`, shifting pitches by
 *  an optional per-cycle transposition list. */
export function repeat(notes, cycleBeats, totalBeats, transposeCycle = [0]) {
  const out = [];
  const cycles = Math.floor(totalBeats / cycleBeats);
  for (let c = 0; c < cycles; c++) {
    const shift = transposeCycle[c % transposeCycle.length];
    for (const nn of notes) {
      out.push({ ...nn, startBeat: nn.startBeat + c * cycleBeats, pitch: nn.pitch + shift });
    }
  }
  return out;
}

/** A chord: one note list from a list of pitches. */
export function chord(startBeat, pitches, lengthBeats, velocity = 72) {
  return pitches.map((p) => ({ startBeat, pitch: p, lengthBeats, velocity }));
}

// ------------------------------------------------------------------- wire ops
/** A BUS. ⚠ Needs its own helper: `addTrack` hardcodes kind:"instrument", so
 *  routing to a "bus" made that way is refused with "track … is not a bus —
 *  output and send destinations must be bus tracks". */
export async function addBus(name) {
  const t = await cmd("track.add", { kind: "bus", name });
  const id = t.id || (t.track && t.track.id);
  if (!id) throw new Error(`track.add bus returned no id for ${name}`);
  return id;
}

export async function addTrack(name, instrument = null, opts = {}) {
  const t = await cmd("track.add", { kind: "instrument", name });
  const id = t.id || (t.track && t.track.id);
  if (!id) throw new Error(`track.add returned no id for ${name}`);
  if (instrument) await cmd("track.setInstrument", { trackId: id, ...instrument });
  if (opts.volume !== undefined) await cmd("track.setVolume", { trackId: id, volume: opts.volume });
  if (opts.pan !== undefined) await cmd("track.setPan", { trackId: id, pan: opts.pan });
  // Omitting busId (or passing null) routes to master — so this is additive.
  if (opts.busId) await cmd("track.setOutput", { trackId: id, busId: opts.busId });
  return id;
}

/** An automation lane over one effect parameter, with its points written.
 *  ⚠ setPoints needs BOTH trackId and laneId; addLane returns {lane:{id}}. */
export async function automate(trackId, effectId, param, points) {
  const r = await cmd("automation.addLane", {
    trackId, target: { type: "effectParam", effectId, param },
  });
  const laneId = (r.lane && r.lane.id) || r.laneId || r.id;
  if (!laneId) throw new Error(`automation.addLane returned no lane id for ${param}`);
  await cmd("automation.setPoints", { trackId, laneId, points });
  return laneId;
}

export async function addClip(trackId, atBeat, lengthBeats, notes, name) {
  if (!notes.length) return null;   // an empty clip is a silent lie in the arrange view
  // ⚠ THE WIRE AND THE MCP TOOL DISAGREE: clip.addMIDI takes `atBeat`, not
  // `startBeat`. The MCP shape is refused outright here, which is the good case.
  const c = await cmd("clip.addMIDI", { trackId, atBeat, lengthBeats, notes, ...(name ? { name } : {}) });
  return c.id || (c.clip && c.clip.id);
}

export async function addFx(trackId, kind, params = {}) {
  const r = await cmd("fx.add", { trackId, kind });
  const effectId = r.effectId;
  if (!effectId) throw new Error(`fx.add ${kind} returned no effectId`);
  for (const [name, value] of Object.entries(params)) {
    await cmd("fx.setParam", { trackId, effectId, name, value });
  }
  return effectId;
}
