// Re-shoot the saturator panel showing the 32 dB the narration names.
// Built FRESH rather than by reopening the session project: project.open wedged
// the app twice at this size, and the shot is of the EFFECT UI, which does not
// care where the track came from.
import { open, cmd, shot, close, SHOTS } from "./build.mjs";
await open();
await cmd("project.new", { discardChanges: true });
const t = await cmd("track.add", { kind: "instrument", name: "808 sub" });
const id = t.id || t.track?.id;
const fx = await cmd("fx.add", { trackId: id, kind: "saturator", params: { driveDb: 32 } });
const eid = fx.effectId || fx.id;
// ⚠ A SETTER'S RETURN IS NOT PROOF IT TOOK.
await cmd("fx.setParam", { trackId: id, effectId: eid, name: "driveDb", value: 32 });
const ov = await cmd("project.overview", {});
console.log("READ BACK:", JSON.stringify(ov.tracks.find(x => x.id === id)).slice(0, 400));
await cmd("debug.effectEditor", { open: true, trackId: id, effectId: eid });
await shot("fx-saturator-32");
console.log("shot ->", `${SHOTS}/fx-saturator-32.png`);
await close();
