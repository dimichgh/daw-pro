// ⚠ THE SHOT NAMED app-arrange WAS THE MIXER. debug.effectEditor switches the
// workspace to MIX and nothing switches it back, so the final capture — taken
// after ui.showMixer{show:false} had run once, at the TOP of shoot.mjs — was a
// picture of the mixer under the name "app-arrange". A valid PNG, a valid
// capture, the wrong screen. Caught by looking at it.
import { open, cmd, close } from "../../session/build.mjs";
const HERE = "/Users/dsemenov/Views/daw-pro/scripts/video/series/how-we-built-3";
await open();
await cmd("debug.effectEditor", { close: true }).catch(() => {});
await cmd("ui.showMixer", { show: false });
await cmd("debug.panelLayout", { editorMaximized: false, editorFraction: 0.30 });
await cmd("transport.seek", { beats: 0 });
await cmd("debug.captureUI", { path: `${HERE}/shots/app-arrange.png` });
console.log("reshot");
process.exit(0);
