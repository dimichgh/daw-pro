#!/usr/bin/env node
// panels — open DAW Pro's panels, drive their controls, and photograph them.
//
// Every recipe here is MEASURED against the running app, and several encode a
// trap that produced a wrong screenshot first. See SKILL.md for the full list;
// the ones that bite hardest are marked ⚠ inline.
//
//   node panels.mjs list
//   node panels.mjs shoot <outdir> [name ...]        # default: every panel
//   node panels.mjs ids                              # tracks / clips / inserts
//
// As a library:  import { shoot, pair, clearModals, collectIds } from "./panels.mjs";

import { connect, send, trySend, close } from "./dawctl.mjs";
import path from "node:path";

// ---------------------------------------------------------------- id helpers

/** tracks, their first clip, and every insert, keyed by readable name. */
export async function collectIds() {
  const ov = await send("project.overview", {});
  const ids = { _tracks: [], _overview: ov };
  for (const t of ov.tracks) {
    ids[t.name] = t.id;
    ids._tracks.push(t.name);
    if (t.clips?.length) ids[`clip:${t.name}`] = t.clips[0].id;
    for (const e of t.fx || []) ids[`fx:${t.name}:${e.name}`] = e.id;
  }
  // ⚠ project.overview omits the MASTER chain entirely. debug.insertLabels is
  // the only readable source for master insert ids — and its ledger ACCUMULATES
  // across rebuilds, so stale ids from deleted effects are still listed. The
  // effect editor rejects a stale id, which is how you tell them apart.
  const rows = await trySend("debug.insertLabels", {});
  for (const r of rows?.rows || []) {
    if (r.chain === "master") ids[`fx:master:${r.kind}`] = r.effectId;   // last wins
  }
  return ids;
}

/** Verify a master insert id is live; stale ledger ids are REJECTED. */
export async function masterInsert(kind, ids) {
  const id = ids[`fx:master:${kind}`];
  if (!id) return null;
  const r = await send("debug.effectEditor", { open: true, trackId: "master", effectId: id })
    .catch(() => null);
  await trySend("debug.effectEditor", { close: true });
  return r ? id : null;
}

// ------------------------------------------------------------------ plumbing

export async function clearModals() {
  // ⚠ A modal left open photographs OVER whatever you meant to shoot, and the
  // capture succeeds, so nothing tells you. Always clear before a shot.
  for (const c of ["debug.breathPad", "debug.quantizePanel", "debug.instrumentPicker",
                   "debug.effectPicker", "debug.effectEditor", "debug.synthEditor",
                   "debug.samplerEditor", "debug.voicePanel"]) {
    await trySend(c, { close: true });
  }
  await trySend("debug.musicalTyping", { enable: false });
  const g = await trySend("debug.pianoRollMarquee", {});
  if (g?.gestureInFlight) await trySend("debug.pianoRollMarquee", { act: "end", x: 0, y: 0 });
}

export async function capture(file, extra = {}) {
  return send("debug.captureUI", { path: file, scale: 2, ...extra });
}

// ------------------------------------------------------------ panel registry
//
// Each entry opens ONE panel and leaves it on screen. `ids` is collectIds()'s
// result; `o` is the caller's option bag (trackName, clipName, …).

export const PANELS = {
  "arrange": async () => {
    await send("ui.showMixer", { show: false });
    await send("debug.panelLayout", { editorMaximized: false, editorFraction: 0.30 });
  },

  "mixer": async () => {
    await send("ui.showMixer", { show: true });
    await trySend("debug.panelDensity", { panel: "mixer", mode: "pro" });
    await send("debug.panelLayout", { mixerInsertsCollapsed: false });
  },

  // ⚠ THE PIANO ROLL'S TWO FRAMING TRAPS.
  //  1. The roll shows a fixed pitch band. A part whose notes sit below it
  //     photographs as an EMPTY GRID and the capture still reports success.
  //     Check the clip's pitch range first (clip.getNotes) — roughly 48..79 is
  //     safe at the default row height.
  //  2. The roll does NOT scroll horizontally to the playhead. Seeking to the
  //     notes is not enough; the zoom has to bring them inside the ~1660pt
  //     grid. At ppb 12, beat 56 lands at x=672. At ppb 38 it is off-screen.
  "editor-notes": async (ids, o = {}) => {
    await send("ui.showMixer", { show: false });
    await send("debug.stepSequencer", { mode: "notes" });
    await send("debug.panelLayout", {
      editorFraction: 0.55, pianoRollMinimap: true,
      pianoRollRowHeight: o.rowHeight ?? 11, pianoRollPPB: o.ppb ?? 12,
    });
    if (o.clipId) await capture(o.scratch || "/tmp/_panels-scratch.png", { selectClip: o.clipId });
  },

  "editor-steps": async (ids, o = {}) => {
    await send("ui.showMixer", { show: false });
    if (o.clipId) await capture(o.scratch || "/tmp/_panels-scratch.png", { selectClip: o.clipId });
    await send("debug.stepSequencer", { mode: "steps" });
  },

  "editor-maximized": async () => {
    await send("debug.panelLayout", { editorMaximized: true, pianoRollMinimap: true });
  },

  "quantize": async (ids, o = {}) =>
    // ⚠ `open` is documented but NEVER read — any call that is not
    // {close:true} opens this panel.
    send("debug.quantizePanel", {
      clipId: o.clipId, mode: "pro",
      ...(o.grid ? { grid: o.grid } : {}),
      ...(o.swing != null ? { swing: o.swing } : {}),
      ...(o.strength != null ? { strength: o.strength } : {}),
    }),

  // ⚠ `pattern` SETS THE DOT'S ANGLE BY ITSELF. Passing angleDegrees after it
  // overwrites the pattern, and every shape then photographs identically —
  // a failure only a byte-size comparison catches.
  "breath": async (ids, o = {}) =>
    send("debug.breathPad", { clipId: o.clipId, ...(o.pattern ? { pattern: o.pattern } : {}) }),

  // ⚠ debug.musicalTyping RETURNS EARLY on the first key it recognises, so
  // {enable:true, playMode:"chords"} silently applies only `enable`. One verb
  // per call.
  "keys": async () => {
    await send("debug.musicalTyping", { enable: true });
    await send("debug.musicalTyping", { playMode: "notes" });
  },
  "chords": async (ids, o = {}) => {
    await send("debug.musicalTyping", { enable: true });
    await send("debug.musicalTyping", { playMode: "chords" });
    if (o.progression) await send("debug.musicalTyping", { progression: o.progression });
    if (o.voicing) await send("debug.musicalTyping", { voicingPreset: o.voicing });
  },

  // ⚠ instrumentPicker and effectPicker CREATE A TRACK if none is eligible.
  // Always pass a trackId on a real project.
  "instrument-picker": async (ids, o = {}) =>
    send("debug.instrumentPicker", { trackId: o.trackId, mode: "pro",
      ...(o.bank ? { bank: o.bank } : {}), ...(o.search ? { search: o.search } : {}) }),
  "effect-picker": async (ids, o = {}) =>
    send("debug.effectPicker", { trackId: o.trackId }),

  "insert": async (ids, o = {}) =>
    send("debug.effectEditor", { open: true, trackId: o.trackId, effectId: o.effectId }),
  "synth": async (ids, o = {}) =>
    send("debug.synthEditor", { open: true, trackId: o.trackId }),
  "sampler": async (ids, o = {}) =>
    send("debug.samplerEditor", { open: true, trackId: o.trackId }),
  "voice": async () => send("debug.voicePanel", { open: true }),
};

/** Open one panel and photograph it. */
export async function shoot(outdir, name, ids, opts = {}) {
  const fn = PANELS[name];
  if (!fn) throw new Error(`unknown panel '${name}' — try: ${Object.keys(PANELS).join(", ")}`);
  await clearModals();
  await fn(ids, opts);
  const file = path.join(outdir, `${opts.as || name}.png`);
  const r = await capture(file);
  return { name, file, width: r.width, height: r.height };
}

// ------------------------------------------------------- before / after pairs

/**
 * Photograph a control at `before` values and again at `after`, then RESTORE
 * whatever the project actually held and PROVE the restore by re-reading.
 *
 * This writes to the user's live project. Restoration is not optional, and a
 * setter's return is not proof it took — hence the verify pass.
 *
 * `driver` is "insert" (debug.effectEditor) or "synth" (debug.synthEditor).
 */
export async function pair(outdir, id, { driver = "insert", trackId, effectId, before }) {
  const cmd = driver === "synth" ? "debug.synthEditor" : "debug.effectEditor";
  const openArgs = driver === "synth" ? { open: true, trackId } : { open: true, trackId, effectId };

  const opened = await send(cmd, openArgs);
  const tuned = { ...opened.values };
  const wave = opened.waveform;
  await capture(path.join(outdir, `${id}-after.png`));

  for (const [k, v] of Object.entries(before)) await send(cmd, { param: k, value: v });
  await capture(path.join(outdir, `${id}-before.png`));

  for (const [k, v] of Object.entries(tuned)) await send(cmd, { param: k, value: v });
  if (driver === "synth" && wave) await send(cmd, { waveform: wave });

  const back = await send(cmd, openArgs);
  const drift = Object.entries(tuned)
    .filter(([k, v]) => Math.abs((back.values?.[k] ?? NaN) - v) > 1e-9)
    .map(([k, v]) => ({ param: k, wanted: v, got: back.values?.[k] }));
  await trySend(cmd, { close: true });

  return { id, tuned, restored: drift.length === 0, drift };
}

// ------------------------------------------------------------------------ CLI

if (import.meta.url === `file://${process.argv[1]}`) {
  const [verb, outdir, ...rest] = process.argv.slice(2);
  await connect();
  try {
    if (verb === "list") {
      console.log(Object.keys(PANELS).join("\n"));
    } else if (verb === "ids") {
      const ids = await collectIds();
      for (const k of Object.keys(ids).filter((k) => !k.startsWith("_")).sort()) {
        console.log(`${k}\t${ids[k]}`);
      }
    } else if (verb === "shoot") {
      if (!outdir) throw new Error("usage: panels.mjs shoot <outdir> [name ...]");
      const ids = await collectIds();
      // ⚠ SAFETY: instrument-picker / effect-picker CREATE A TRACK when they
      // get no usable trackId, and `insert` needs a real effect. Fill sensible
      // targets from the live project, and skip a panel we cannot target
      // rather than letting it invent one.
      const ov = ids._overview;
      const instr = ov.tracks.find((t) => t.kind === "instrument");
      const withFx = ov.tracks.find((t) => (t.fx || []).length);
      const withClip = ov.tracks.find((t) => (t.clips || []).length);
      const defaults = {
        trackId: instr?.id,
        clipId: withClip?.clips[0].id,
        effectId: withFx?.fx[0].id,
      };
      const needsTrack = new Set(["instrument-picker", "effect-picker", "synth", "sampler"]);
      const needsInsert = new Set(["insert"]);
      const names = rest.length ? rest : Object.keys(PANELS);
      for (const n of names) {
        try {
          if (needsTrack.has(n) && !defaults.trackId) throw new Error("no instrument track to target");
          if (needsInsert.has(n) && !defaults.effectId) throw new Error("no insert to open");
          const opts = { ...defaults };
          if (needsInsert.has(n)) opts.trackId = withFx.id;
          const r = await shoot(outdir, n, ids, opts);
          console.log(`  ${r.name.padEnd(20)} ${r.width}x${r.height}  ${r.file}`);
        } catch (e) { console.log(`  ${n.padEnd(20)} SKIPPED — ${e.message}`); }
      }
      await clearModals();
    } else {
      console.error("usage: panels.mjs list | ids | shoot <outdir> [name ...]");
      process.exitCode = 2;
    }
  } catch (e) {
    console.error(String(e.message || e));
    process.exitCode = 1;
  }
  close();
  // ⚠ Node keeps the process alive until the socket finishes closing, so a
  // bare close() leaves the CLI hanging AFTER all its work is done — and any
  // piped output never flushes, which reads as "it produced nothing".
  process.exit(process.exitCode ?? 0);
}
