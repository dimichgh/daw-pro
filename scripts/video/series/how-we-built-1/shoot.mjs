// Stills + playing bursts for "How We Built a DAW — Part 1".
// ⚠ STAGING ONLY (17695); build.mjs refuses 17600.
import { open, cmd, shot, close, burst } from "../../session/build.mjs";

const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-1";
await open();

const ids = JSON.parse((await import("node:fs")).readFileSync(`${HERE}/ids.json`, "utf8"));
const T = ids.ids;

const layout = (o) => cmd("debug.panelLayout", o);
const mixer = (show) => cmd("ui.showMixer", { show });

// ── 1. the arrangement: what a DAW looks like ──────────────────────────────
await cmd("debug.clearModals", {}).catch(() => {});
await mixer(false);
await layout({ editorMaximized: false, editorFraction: 0.30, followPlayhead: false });
await cmd("transport.seek", { beats: 0 });
await shot("app-arrange");

// ── 2. one clip's notes: what a clip is made of ────────────────────────────
await layout({ pianoRollPPB: 26, pianoRollRowHeight: 13, pianoRollMinimap: true,
               editorFraction: 0.62 });
await cmd("debug.captureUI", { path: `${HERE}/shots/app-roll-lead.png`,
                               selectClip: T["Lead:clip"] });
await layout({ pianoRollCenterPitch: 68 });
await cmd("debug.captureUI", { path: `${HERE}/shots/app-roll-lead.png`,
                               selectClip: T["Lead:clip"] });

// the drum grid, as steps
await cmd("debug.captureUI", { path: `${HERE}/shots/app-roll-drums.png`,
                               selectClip: T["Drums:clip"] });
await layout({ pianoRollCenterPitch: 41 });
await cmd("debug.stepSequencer", { mode: "steps" }).catch((e) => console.log("  step seq:", e.message));
await cmd("debug.captureUI", { path: `${HERE}/shots/app-roll-drums.png`,
                               selectClip: T["Drums:clip"] });
await cmd("debug.stepSequencer", { mode: "notes" }).catch(() => {});

// ── 3. the mixer: what "mixing" means ──────────────────────────────────────
await layout({ editorFraction: 0.30 });
await mixer(true);
await shot("app-mixer");

// ── 4. an effect: what a plug-in looks like ────────────────────────────────
const fx = await cmd("fx.add", { trackId: T["Drums"], kind: "compressor" });
const fxId = fx.effectId || fx.id;
await cmd("debug.effectEditor", { open: true, trackId: T["Drums"], effectId: fxId });
await shot("app-fx");
await cmd("debug.effectEditor", { close: true }).catch(() => {});
await cmd("fx.remove", { trackId: T["Drums"], effectId: fxId });
await mixer(false);
await cmd("debug.clearModals", {}).catch(() => {});

// ── 5. bursts: the transport actually running ──────────────────────────────
process.env.SESSION_BURSTS = `${HERE}/bursts`;
await layout({ editorFraction: 0.30 });
await burst("play-arrange", 9.0, 0, { arrange: true });
await layout({ pianoRollPPB: 26, pianoRollRowHeight: 13, editorFraction: 0.62 });
await burst("play-roll", 7.0, 0, {});

await cmd("mixer.setMasterVolume", { volume: 0.41 });
await layout({ editorMaximized: false, editorFraction: 0.30, followPlayhead: false });
await cmd("transport.seek", { beats: 0 });
await shot("app-arrange");
console.log("shots done");
await close();
