#!/usr/bin/env node
// Render named mixes of the OPEN staging project through render.mixdown with
// excludeTrackIds (the project's own mute flags, dirty flag and undo stack are
// untouched — that is the whole point of the param, Commands.swift:7868).
//
//   node render.mjs <outName> <keep: comma list of track NAMES or "all"> [fromBeat] [seconds] [--project path]
//
// ⚠ DAW_TIMEOUT is per call here (wire.mjs): a mixdown of this 26 s song takes
// a few seconds, but a cold tuned clip renders its edits first.
import { mkdirSync } from "node:fs";
import { open, close, cmd, VOICE_HOME } from "./wire.mjs";

const args = process.argv.slice(2);
let project = null;
const pi = args.indexOf("--project");
if (pi >= 0) { project = args[pi + 1]; args.splice(pi, 2); }
const [name, keepRaw, fromRaw, secRaw] = args;
if (!name || !keepRaw) { console.error("usage: render.mjs <outName> <keep|all> [fromBeat] [seconds] [--project p]"); process.exit(2); }
const OUT = `${VOICE_HOME}/out/renders`;
mkdirSync(OUT, { recursive: true });

await open();
try {
  if (project) await cmd("project.open", { path: project, discardChanges: true });
  const ov = await cmd("project.overview", {});
  const keep = keepRaw === "all" ? null : keepRaw.split(",").map((s) => s.trim().toLowerCase());
  const matches = (t) => keep.some((k) => t.name.toLowerCase().startsWith(k));
  if (keep) {
    const unknown = keep.filter((k) => !ov.tracks.some((t) => t.name.toLowerCase().startsWith(k)));
    if (unknown.length) throw new Error(`no track named like ${JSON.stringify(unknown)}; tracks: ${ov.tracks.map((t) => t.name).join(" | ")}`);
  }
  const exclude = keep ? ov.tracks.filter((t) => !matches(t)).map((t) => t.id) : [];
  const params = { path: `${OUT}/${name}.wav`, ...(exclude.length ? { excludeTrackIds: exclude } : {}) };
  if (fromRaw !== undefined) params.fromBeat = Number(fromRaw);
  if (secRaw !== undefined) params.durationSeconds = Number(secRaw);
  const r = await cmd("render.mixdown", params, 600000);
  console.log(`${name}: ${r.path}  ${Number(r.durationSeconds).toFixed(2)} s  kept=[${ov.tracks.filter((t) => !exclude.includes(t.id)).map((t) => t.name).join(", ")}]`);
} catch (err) {
  // ⛔ WITHOUT THIS, AN ERROR EXITS 0: the finally below calls process.exit,
  // which ends the process before Node reports the rejection. MEASURED
  // 2026-10-11: tune.mjs died after one still and printed "exit 0".
  console.error("⛔", err?.stack || err);
  process.exitCode = 1;
} finally {
  close();
  process.exit(process.exitCode ?? 0);
}
