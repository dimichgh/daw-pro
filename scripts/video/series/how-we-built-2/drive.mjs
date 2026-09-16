// The MOTION shot: film the app with screenrec while the transport actually
// runs, so the play segments are the playhead moving rather than a still.
// ⚠ STAGING ONLY (17695). ⚠ MASTER TO ZERO while filming — the audio for the
// film was rendered offline; nobody asked for the mix out of their speakers.
// ⛔ `--app DAWApp` only: 100+ windows are capturable and a wrong match is
// silent, which is why frame 1 of the result is looked at by hand.
import { open, cmd, close } from "../../session/build.mjs";
import { spawn } from "node:child_process";

const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-2";
const REC = "/Users/dsemenov/Views/daw-pro/scripts/video/screenrec/screenrec";
const SECONDS = Number(process.env.SECONDS || 16);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

await open();
await cmd("debug.clearModals", {}).catch(() => {});
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.30 });
await cmd("debug.followPlayhead", { enabled: true }).catch(() => {});
await cmd("transport.seek", { beats: 0 });
const master0 = (await cmd("project.overview", {})).master.volume;
await cmd("mixer.setMasterVolume", { volume: 0 });

const p = spawn(REC, ["--app", "DAWApp", "--scale", "2.0", "--fps", "30",
                      "--seconds", String(SECONDS),
                      "--out", `${HERE}/media/play-arrange.mp4`],
                { stdio: "inherit" });
await sleep(1500);
await cmd("transport.play", {});
await new Promise((r) => p.on("exit", r));
await cmd("transport.stop", {});
await cmd("transport.seek", { beats: 0 });
await cmd("mixer.setMasterVolume", { volume: master0 });
await cmd("debug.followPlayhead", { enabled: false }).catch(() => {});
console.log("recorded, master back to", master0);
await close();
