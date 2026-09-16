// Stills for Part 3. ⚠ STAGING ONLY (17695).
// ⚠ THE COMPRESSOR IS ADDED AND REMOVED. The project on staging has no
// effects and must not gain one: fx.add -> two shots -> fx.remove, and the
// insert chain is RE-READ afterwards to prove it went back to empty. A
// setter's return is not proof.
import { open, cmd, shot, close } from "../../session/build.mjs";
import { readFileSync } from "node:fs";

const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-3";
await open();
const T = JSON.parse(readFileSync(`${HERE}/ids.json`, "utf8")).ids;
const layout = (o) => cmd("debug.panelLayout", o);
const cap = (name, extra = {}) =>
  cmd("debug.captureUI", { path: `${HERE}/shots/${name}.png`, ...extra });

await cmd("debug.effectEditor", { close: true }).catch(() => {});
await cmd("ui.showMixer", { show: false });
await layout({ editorMaximized: false, editorFraction: 0.30, followPlayhead: false });
await cmd("transport.seek", { beats: 0 });
await shot("app-arrange");

// The notes, as notes. Drums sits at kit pitches; the Bass and Lead are in the
// roll's own visible band, so aim at the Lead and centre it.
await layout({ pianoRollPPB: 26, pianoRollRowHeight: 13, pianoRollMinimap: true,
               editorFraction: 0.62 });
await cap("app-roll", { selectClip: T["Bass:clip"] });
await layout({ pianoRollCenterPitch: 50 });
await cap("app-roll", { selectClip: T["Bass:clip"] });

// The compressor, at the two release settings the film names.
const before = await cmd("fx.list", { trackId: T["Drums"] }).catch(() => null);
const fx = await cmd("fx.add", { trackId: T["Drums"], kind: "compressor",
                                 params: { thresholdDb: -18, ratio: 4, attackMs: 10,
                                           releaseMs: 30, kneeDb: 6 } });
const effectId = fx.effectId || fx.id;
console.log("added compressor", effectId, "prior chain:", JSON.stringify(before));
await cmd("debug.effectEditor", { open: true, trackId: T["Drums"], effectId });
await cap("comp-release-30");
await cmd("fx.setParam", { trackId: T["Drums"], effectId, name: "releaseMs", value: 800 });
await cap("comp-release-800");
await cmd("debug.effectEditor", { close: true }).catch(() => {});
await cmd("fx.remove", { trackId: T["Drums"], effectId });

// ⚠ RE-READ. The restore is proved here, not by fx.remove returning.
const after = await cmd("project.overview", {});
const drums = after.tracks.find((t) => t.id === T["Drums"]);
console.log("Drums fx after removal:", JSON.stringify(drums.fx));
if (drums.fx.length !== 0) throw new Error("COMPRESSOR NOT REMOVED");

await layout({ editorMaximized: false, editorFraction: 0.30, pianoRollPPB: 32,
               pianoRollRowHeight: 14 });
await cmd("debug.effectEditor", { close: true }).catch(() => {});
await cmd("transport.seek", { beats: 0 });
await shot("app-arrange");
console.log("shots done");
await close();
