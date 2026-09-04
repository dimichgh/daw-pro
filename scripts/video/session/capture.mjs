// Photograph the session. Run AFTER track.mjs, against the saved project.
//
// ⚠ Every one of these verbs returns {"ok":true} whether or not the window
// shows what you meant. The only check that means anything is looking at the
// PNG, so this script prints a manifest and the pixels get reviewed by hand.
import { open, cmd, shot, close, SHOTS } from "./build.mjs";

const PROJ = "~/Music/DAW Pro Lessons/Session — Four Waveforms.dawproj";
const made = [];
const take = async (name, note) => { await shot(name); made.push([name, note]); console.log("  " + name); };

// ⚠ THE debug.* SURFACE VARIES BY BUILD. This one has captureUI and
// panelLayout but NOT selectClip -- and an unknown command is a hard error
// that killed the whole capture run twice. Every optional step is therefore
// wrapped: a missing verb costs one screenshot, not the session.
const step = async (label, fn) => {
  try { await fn(); }
  catch (e) { skipped.push(`${label}: ${String(e.message).split("—")[0].trim()}`); }
};
const skipped = [];

// Close everything that could photograph over the top. A modal you forgot is
// the single most common wrong screenshot on this surface.
const clearModals = async () => {
  for (const v of ["breathPad", "quantizePanel", "instrumentPicker", "effectPicker",
                   "effectEditor", "synthEditor", "samplerEditor", "voicePanel"]) {
    try { await cmd(`debug.${v}`, { close: true }); } catch { /* not open */ }
  }
};

await open();
await cmd("project.open", { path: PROJ });
await clearModals();

const ov = await cmd("project.overview", {});
const byName = Object.fromEntries(ov.tracks.map(t => [t.name, t]));
console.log("tracks:", ov.tracks.map(t => t.name).join(", "));

// 1. The arrangement, whole.
await cmd("debug.panelLayout", { editorMaximized: false });
await take("arrange-full", "all eight tracks, 64 bars");

// 2. The same view zoomed to the drop.
await cmd("transport.seek", { beats: 128 });
await take("arrange-drop", "playhead at the drop, bar 33");

// 3. The piano roll of the bass riff.
const bass = byName["Bass"];
if (bass && bass.clips.length) {
  await step("piano roll", async () => {
    await cmd("debug.selectClip", { clipId: bass.clips[0].id });
    await cmd("debug.panelLayout", { editorMaximized: true });
    await take("pianoroll-bass", "the bass riff, note by note");
    await cmd("debug.panelLayout", { editorMaximized: false });
  });
}

// 4. The synth editor: where saw|square|triangle|sine is chosen.
for (const [tname, label] of [["Kick", "kick-sine"], ["Bass", "bass-saw"], ["Hats", "hats-square"]]) {
  const t = byName[tname];
  if (!t) continue;
  await step(`synth ${label}`, async () => {
    await clearModals();
    await cmd("debug.synthEditor", { open: true, trackId: t.id });
    await take(`synth-${label}`, `${tname}: the four waveforms and the filter`);
  });
}
await clearModals();

// 5. The effect editors that the film actually talks about.
for (const [tname, idx, label] of [["808 sub", 0, "saturator"], ["Voice", 0, "voice-eq"],
                                   ["Stab", 0, "delay"]]) {
  const t = byName[tname];
  if (!t || !t.fx || !t.fx.length) continue;
  await step(`fx ${label}`, async () => {
    await clearModals();
    await cmd("debug.effectEditor", { open: true, trackId: t.id, effectId: t.fx[idx].id });
    await take(`fx-${label}`, `${tname}: ${t.fx[idx].kind}`);
  });
}
await clearModals();

// 6. The mixer.
await step("mixer", async () => {
  await cmd("debug.panelLayout", { view: "mix" });
  await take("mixer", "eight channels, one master");
  await cmd("debug.panelLayout", { view: "arrange" });
});

console.log("\nMANIFEST");
for (const [n, note] of made) console.log(`  ${n}.png — ${note}`);
console.log(`\n${made.length} shots in ${SHOTS}`);
if (skipped.length) {
  console.log("\nSKIPPED (verb missing on this build) — these are holes in the film,");
  console.log("not silent successes, which is why they are printed:");
  for (const s of skipped) console.log("  · " + s);
}
await close();
