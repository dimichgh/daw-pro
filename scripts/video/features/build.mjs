#!/usr/bin/env node
// Build ONE arrangement, end to end, on staging — and photograph every step,
// because the film has to SHOW the work happening in the DAW, not assert it.
//
//   node build.mjs <variant> [--no-shots] [--no-render]
//
// ⚠ 17695 only. ⚠ One wire script at a time (this calls project.new).
//
// ⛔⛔ WHY THE SHOT CODE BELOW IS SO DEFENSIVE — IT SHIPPED A WRONG PICTURE.
// The first version captured after each fx.add and called the results
// "09-fx-drums", "10-fx-bass", "12-fx-lead-djfilter". Those three files were
// BYTE-IDENTICAL: adding an effect changes nothing in the arrange view, so all
// three showed the same unchanged screen under three different labels. Worse,
// the mixer shot was taken after `view.panelLayout({panel:"mixer"})` wrapped in
// `.catch(() => {})` — the verb takes `workspace`, not `panel`, so the call was
// REFUSED and the catch ate the refusal. A PNG was written, at a plausible name,
// showing the wrong panel. That is the 2>/dev/null trap in JavaScript clothing:
// never silence the error from the call whose success you intend to interpret.
// So now: effect cards are OPENED before they are photographed, the panel verb
// is NOT wrapped in a catch, and identical consecutive shots are a hard failure.

import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import { open, close, cmd, addTrack, addBus, addClip, addFx, automate } from "./arrange.mjs";
import { BARS, TEMPO, SECTIONS, drumsFor, bassLine, padLine, motif, VARIANTS } from "./material.mjs";
// ⚠ FROM leads.mjs, NOT lead-options.mjs. The latter is a SCRIPT with top-level
// wire calls and renders; importing it would run all three comparison builds as
// an import side effect. See the header of leads.mjs.
import { LEADS } from "./leads.mjs";

const DIR = process.env.FEATURES_HOME
  || new URL(".", import.meta.url).pathname.replace(/\/$/, "");
const OUT = `${DIR}/out`;
const WANT = process.argv[2] || "machine-room";
const SHOTS = !process.argv.includes("--no-shots");
const RENDER = !process.argv.includes("--no-render");
// ⛔⛔ THE captureUI MOTION BURST IS OFF BY DEFAULT NOW — IT IS SUPERSEDED.
// It produced ten stills at roughly 1 fps and called them motion, which is the
// slideshow the user rejected ("you are just flipping screenshots"). Real 30 fps
// footage comes from record-all.sh via ScreenCaptureKit instead.
// It also muted the master to keep playback silent, which put "-inf dB" on the
// master strip in every frame it produced. Opt back in with --motion only if
// the recorder is unavailable; nothing in the film uses these frames.
const MOTION = SHOTS && process.argv.includes("--motion");

const V = VARIANTS[WANT];
if (!V) { console.error(`unknown variant '${WANT}' — have: ${Object.keys(VARIANTS).join(", ")}`); process.exit(1); }

const shotDir = `${OUT}/${V.id}/shots`;
// ⚠ WIPE FIRST. Without this the directory accumulated shots from three
// different builds under overlapping numbers (13-mixer from one run sitting
// beside 13-filter-sweep from another), so the film would have cut together
// frames from arrangements that no longer existed.
//
// ⛔⛔ BUT ONLY WHEN THIS RUN IS ACTUALLY TAKING SHOTS. This wipe used to be
// unconditional, and `record-all.sh` rebuilds every project with `--no-shots`
// before filming it — so the rebuild DELETED the 23 stills the real build had
// just written and replaced them with nothing. assemble.py then found no
// stills for any stage, skipped all ten, and exited "nothing to assemble"
// after a forty-minute pipeline run. A destructive step has to be owned by the
// mode that rebuilds what it destroys.
if (SHOTS) {
  fs.rmSync(shotDir, { recursive: true, force: true });
}
fs.mkdirSync(shotDir, { recursive: true });

let shotN = 0;
const manifest = [];
// ⚠ ABSOLUTE PATHS ONLY. debug.captureUI resolves the path against the APP's
// cwd, not this script's, so a relative path writes somewhere else entirely
// while returning ok with a real PNG at a plausible name.
const settle = (ms) => new Promise((r) => setTimeout(r, ms));

async function shot(label, { expectSameAsPrev = false, settleMs = 500 } = {}) {
  if (!SHOTS) return null;
  const name = `${String(++shotN).padStart(2, "0")}-${label}`;
  const p = path.resolve(`${shotDir}/${name}.png`);
  // ⚠⚠ SETTLE BEFORE CAPTURING — THIS IS A RACE, NOT A FORMALITY.
  // A wire command returns as soon as the model is mutated; the view repaints
  // afterwards. Capturing immediately photographs the PREVIOUS frame. Measured:
  // two consecutive runs of this identical script flagged DIFFERENT shots as
  // duplicates (run 1: mixer; run 2: markers, drum-pattern, drum-notes) — which
  // is the signature of a race rather than a logic error. Left alone this ships
  // a correct caption over a stale picture, intermittently, which is the worst
  // kind of wrong because it passes most of the time.
  await settle(settleMs);
  await cmd("debug.captureUI", { path: p });
  const md5 = crypto.createHash("md5").update(fs.readFileSync(p)).digest("hex");
  const prev = manifest[manifest.length - 1];
  const dup = prev && prev.md5 === md5;
  manifest.push({ n: shotN, name, path: p, md5, expectSameAsPrev, duplicateOfPrev: !!dup });
  console.log(`   shot ${name}${dup ? (expectSameAsPrev ? "  (identical — expected)" : "  ⚠ IDENTICAL TO PREVIOUS") : ""}`);
  return p;
}

const step = (s) => console.log(`\n▸ ${s}`);

await open();

// ---------------------------------------------------------------- 1. the form
step("empty project, tempo, and the sections marked out");
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: TEMPO });
// ⚠ Effects only RENDER at Pro density — at Simple there is no inserts section,
// no "+" menu and no editor card at all, so every effect shot would be a blank.
for (const panel of ["arrange", "mixer", "pianoRoll", "effectEditor", "transport"]) {
  await cmd("debug.panelDensity", { panel, mode: "pro" });
}
// ⛔⛔ SET THE WORKSPACE EXPLICITLY, AND ONLY LOOKING AT THE PICTURE FOUND THIS.
// The app was sitting in the MIX workspace, so every shot captioned as an
// arrange view was actually the mixer — which is precisely why "add six clips"
// produced a byte-identical screen: clips do not appear in a mixer. The
// duplicate detector flagged it, but the detector could only say "identical";
// it took opening the PNG to see the ARRANGE/MIX toggle set to MIX.
await cmd("view.panelLayout", { workspace: "arrange" });
await shot("empty");
for (const s of SECTIONS) await cmd("marker.add", { beat: s.bar * 4, name: s.name });
await shot("markers");

// ⚠ THE SWEEP NEEDS A BUS, AND THE WIRE SAID SO OUT LOUD.
// Putting the djFilter on the master and asking for an effectParam automation
// lane there was refused: "master automation supports the volume target only in
// v1 — pan, sendLevel, and effectParam lanes live on tracks". So the four
// instruments feed a Mix Bus, the sweep lives on the bus, and the master keeps
// only the limiter. That is the more honest mixing architecture anyway.
const mixBus = await addBus("Mix Bus");

// ------------------------------------------------------------- 2. the drums
step(`drum machine — our own ${V.kit} kit, every sound synthesised`);
const drums = await addTrack("Drums", { kind: "drumSynth" }, { volume: 0.9, busId: mixBus });
await shot("drum-track");
// ⚠ drumKit does NOT imply kind (unlike audioUnit/soundBank). Sending the kit
// alone is a SILENT INAUDIBLE SUCCESS — kind went in with track.setInstrument
// above, and the preset is loaded through its own verb.
await cmd("instrument.loadDrumPreset", { trackId: drums, name: V.kit });
// ⛔ EXPECTED TO LOOK IDENTICAL, AND THAT IS THE POINT, NOT A BUG:
// the drum machine has NO editor card. Loading a whole new kit changes the
// sound completely and the screen not at all. The film says so out loud rather
// than pretending a picture changed.
await shot(`kit-${V.kit}`, { expectSameAsPrev: true });

const drumClips = [];
for (const s of SECTIONS) {
  const id = await addClip(drums, s.bar * 4, s.bars * 4, drumsFor(s.name, s.bars), `Drums ${s.name}`);
  if (id) drumClips.push(id);
}
await shot("drum-pattern");

// The notes themselves — a drumSynth track opens in the PIANO ROLL (it is not
// a GM percussion bank, so it does not get the step grid).
//
// ⛔ NO view.openEditor HERE, AND THE APP IS THE ONE THAT SAID SO. Asking for
// the instrument editor on this track is refused outright:
//   "track "Drums" plays the drum machine, which has no editor card yet — its
//    75 parameters are on the wire. Read them with instrument.describeDrumKit…"
// That refusal is the single most honest thing in this build, and the film
// quotes it rather than staging a panel that does not exist.
if (drumClips.length) {
  await cmd("view.selectClip", { clipId: drumClips[2] || drumClips[0] });
  await shot("drum-notes-in-roll");
}

// ------------------------------------------------------- 3. bass, pad, lead
step("bass, chords and the hook");
await cmd("view.panelLayout", { workspace: "arrange" });
const bass = await addTrack("Bass", {
  kind: "polySynth",
  waveform: "saw", cutoffHz: 900, resonance: 0.18,
  attack: 0.004, decay: 0.12, sustain: 0.55, release: 0.09, gain: 0.85,
}, { volume: 0.85, busId: mixBus });
for (const s of SECTIONS) {
  if (s.name === "Breakdown" || s.name === "Intro") continue;   // bass is the payoff, not the wallpaper
  await addClip(bass, s.bar * 4, s.bars * 4, bassLine(V.bassRoots, s.bars), `Bass ${s.name}`);
}
await shot("bass");

const pad = await addTrack("Pad", {
  kind: "polySynth",
  waveform: "saw", cutoffHz: 2600, resonance: 0.22,
  attack: 0.42, decay: 0.5, sustain: 0.8, release: 0.9, gain: 0.55,
}, { volume: 0.62, pan: -0.15, busId: mixBus });
for (const s of SECTIONS) {
  if (s.name === "Intro") continue;
  await addClip(pad, s.bar * 4, s.bars * 4, padLine(V.pads, s.bars), `Pad ${s.name}`);
}
await shot("pad");

// ⭐ THE LEAD IS THE SUPERSAW, AND THE USER CHOSE IT BY EAR.
// ⛔ IT USED TO BE `waveform: "square"` WITH EIGHT PARAMETERS SET, and their
// verdict on that film was "the synth used for lead track is cheap, like toy".
// They were right, and the cause was not taste: `unisonVoices` DEFAULTS TO 1,
// so the lead was a single clean oscillator — no detune, no sub, no drift, no
// drive, no per-note jitter. That is the definition of a toy synth sound, and
// no amount of effects downstream fixes a one-oscillator source.
//
// Three candidates one axis apart went out (lead-options.mjs); they picked A.
// It is IMPORTED rather than copied so the film's lead cannot drift from the
// patch they actually heard.
const lead = await addTrack("Lead", LEADS.supersaw,
  { volume: 0.72, pan: 0.18, busId: mixBus });
const leadClips = [];
for (const s of SECTIONS) {
  if (!["Drop", "Breakdown", "Drop 2"].includes(s.name)) continue;
  const id = await addClip(lead, s.bar * 4, s.bars * 4, motif(V.lead, V.leadBars, s.bars), `Lead ${s.name}`);
  if (id) leadClips.push(id);
}
await shot("lead");
if (leadClips.length) {
  await cmd("view.selectClip", { clipId: leadClips[0] });
  await shot("lead-notes-in-roll");
}
// ⛔ THE POLY SYNTH CARD USED TO BE OPENED HERE AND IT POISONED EVERY LATER SHOT.
// There is NO close verb on the wire — `view.openEditor` takes only trackId and
// effectId, and `view.closeEditor` does not exist — so a card, once open, is on
// screen for the rest of the build. An INSTRUMENT card is its own layer that
// effect cards do not replace, so opening this one at bar zero left "Poly Synth
// on Lead" sitting under the DJ Filter card in the shot captioned `mixer`, which
// showed two stacked cards and almost no mixer. It is now opened LAST.

// ------------------------------------------------------------- 4. the effects
// ⚠ TWO PASSES, AND THE ORDER IS THE WHOLE POINT.
// Pass A adds every effect with NO card open, so the mixer and the automation
// lane can be photographed showing themselves rather than showing a card. Pass B
// then opens each card in turn. This split exists because cards CANNOT BE CLOSED
// (see above): every clean shot has to be taken before the first one opens.
//
// ⚠ AND EACH CARD IS STILL OPENED BEFORE IT IS PHOTOGRAPHED. Without
// view.openEditor the mixer does not change when an effect is added, and three
// "new effect" shots came out byte-identical.
step("the new effects — this is the part that is new");
const fx = {};
const cards = [];                    // [trackId, effectId, label] photographed in pass B
function later(trackId, effectId, label) { cards.push([trackId, effectId, label]); return effectId; }
async function fxShot(trackId, kind, params, label) {
  return later(trackId, await addFx(trackId, kind, params), label);
}

fx.transientShaper = await fxShot(drums, "transientShaper",
  { attackDb: 4.5, sustainDb: -2, attackMs: 3 }, "fx-transientShaper");
fx.clipper = await fxShot(drums, "clipper",
  { driveDb: 4, ceilingDb: -0.8, mode: 1 }, "fx-clipper");
// ⛔⛔ bandNMode IS THE BAND'S ON SWITCH AND IT DEFAULTS TO OFF. The first
// version of this call set freq/threshold/range/ratio on both bands and never
// set the mode — so every knob here was on a band that was not running, and the
// app's own note is explicit that mode 0 "is a TRUE no-op, the band's filter is
// not even run". The effect card photographed fine, the render measured fine,
// and the Dynamic EQ was a bit-exact bypass. Mode 1 = ABOVE: the band reacts
// when the level INSIDE THE BAND rises past the threshold, and a NEGATIVE
// rangeDb then turns it DOWN when it gets loud — the classic move for a bass
// that blooms at 90 Hz and boxes up at 320. Proven by a band-level delta in
// prove-deq.mjs, not by the card looking right.
// MEASURED, in prove-deq.mjs / tune-deq.mjs, on the same 8 bars of this bass:
//   band OFF (defaults) ....... 90 Hz band RMS -32.21 dB
//   knobs set, mode NOT set ... -32.21 dB and BYTE-IDENTICAL to OFF
//   mode 1, threshold -22 ..... -32.30 dB  (0.09 dB — decorative, not an effect)
//   mode 1, threshold -42 ..... -34.50 dB  (2.29 dB of real gain reduction)
// Threshold -50 buys only 0.08 dB more, so -42 is the knee: the band engages on
// essentially every note. The first two lines are the whole lesson — a shipped
// effect can be configured, photographed, and rendered while doing NOTHING.
fx.dynamicEQ = await fxShot(bass, "dynamicEQ", {
  band1Mode: 1, band1Freq: 90, band1Q: 2, band1ThresholdDb: -42,
  band1RangeDb: -9, band1Ratio: 4, band1AttackMs: 8, band1ReleaseMs: 120,
  band2Mode: 1, band2Freq: 320, band2ThresholdDb: -40, band2RangeDb: -6, band2Ratio: 3,
}, "fx-dynamicEQ");
fx.saturator = await fxShot(bass, "saturator", { driveDb: 9, mix: 0.75 }, "fx-saturator");
fx.phaser = await fxShot(pad, "phaser",
  { rateHz: 0.22, stages: 8, depthOctaves: 3.2, mix: 0.55 }, "fx-phaser");
fx.hallReverb = await fxShot(pad, "hallReverb",
  { mix: 0.42, decaySeconds: 3.4, sizeMeters: 26, preDelayMs: 32 }, "fx-hallReverb");
fx.djFilter = await fxShot(lead, "djFilter", { position: 0, resonance: 0.42 }, "fx-djFilter");
fx.tapeDelay = await fxShot(lead, "tapeDelay",
  { timeMs: 234, feedback: 0.42, mix: 0.3, wowDepthMs: 2.2 }, "fx-tapeDelay");

// ------------------------------------------ THE DJ GESTURE, ON THE MIX BUS
// ⛔ A MEASURED FIX, NOT A FLOURISH. With drums+bass+pad+lead and a master
// limiter, the first mix measured per-section RMS of -14.3 (intro) against
// -14.2 (drop): the track never built. A listener would hear eight bars of kick
// and the full drop at the SAME size. Sweeping one filter across the whole mix
// is how a DJ makes a build audible, and it shows up in the numbers as well as
// the ears — a low-pass takes the treble out, so the intro measures quieter AND
// darker. After this change: drop +6.5 dB louder, +33 dB brighter than intro.
fx.busFilter = later(mixBus, await addFx(mixBus, "djFilter", { position: -0.55, resonance: 0.3 }),
                     "bus-filter-card");
// position 0 is a BIT-EXACT BYPASS — the drop is the filter getting out of the
// way entirely, which is why a drop sounds like the lid coming off.
const SWEEP = [
  { beat: 0,   value: -0.55 },  // Intro: muffled, underwater
  { beat: 28,  value: -0.50 },
  { beat: 32,  value: -0.42 },  // Build: opening
  { beat: 60,  value: -0.12 },
  { beat: 64,  value: 0.0 },    // DROP: wide open, bypass
  { beat: 126, value: 0.0 },
  { beat: 128, value: -0.40 },  // Breakdown: lid back on
  { beat: 156, value: -0.34 },
  { beat: 160, value: -0.30 },  // Build 2
  { beat: 188, value: 0.18 },   // ...and THIN just before the drop: bass leaves
  { beat: 191, value: 0.30 },   // the tension note
  { beat: 192, value: 0.0 },    // DROP 2: everything returns at once
  { beat: 256, value: 0.0 },
];
fx.sweepLane = await automate(mixBus, fx.busFilter, "position", SWEEP);

// ⛔⛔ THE SHOT BELOW USED TO SHOW NO AUTOMATION LANE AT ALL.
// An observer checked the picture against the words and found the film saying
// "an automation lane opens it over sixty four bars" over an arrange view with
// the lane COLLAPSED — the one frame that has to prove the claim, disproving it.
// Creating a lane does not reveal it: the track header's disclosure triangle
// starts closed, and `view.panelLayout` only chooses a workspace.
//
// `ui.showAutomation {trackId}` expands the track and selects its first lane.
// ⚠ NOT WRAPPED IN A CATCH, and the return is CHECKED — it reports
// selectedLaneId, so a null there means the lane is still not on screen and the
// shot would be another confident picture of nothing.
//
// ⚠⚠ GUARDED BY `SHOTS`, AND THAT GUARD IS NOT COSMETIC. This expands the Mix
// Bus automation lane and LEAVES IT EXPANDED. record-all.sh builds each project
// with --no-shots and then FILMS it, so an unguarded call here would put an
// open automation lane in the arrange view of every take — clutter on `open`,
// `drum-machine` and `build-one`, and the user asked specifically to keep the
// focus on the track that is playing.
if (SHOTS) {
  const shown = await cmd("ui.showAutomation", { trackId: mixBus });
  if (!shown.selectedLaneId) {
    console.error("⛔ ui.showAutomation returned no selectedLaneId — the sweep lane " +
                  "is NOT visible, and this shot would show an empty track again.");
    close();
    process.exit(1);
  }
  await shot("filter-sweep-automation");
}

// ⛔ THE MASTER LIMITER IS A MEASURED FIX TOO.
// The first render measured -13.9 LUFS integrated — a healthy-looking number —
// while TRUE PEAK sat at +1.6 dBFS: clipping. A loudness meter does not look
// up. Note `truePeak` defaults to 0 (OFF): a limiter with it off passes
// inter-sample peaks straight through.
fx.masterLimiter = later("master", await addFx("master", "limiter",
  { ceilingDb: -1.0, truePeak: 1, releaseMs: 80 }), "master-limiter-card");

// ⚠ NOT WRAPPED IN A CATCH. This verb takes `workspace`, not `panel`; when the
// wrong key was silenced by .catch(() => {}) the "mixer" shot was the arrange
// view under a mixer label.
//
// THE CLEAN MIXER SHOT — eleven inserts across six strips and no card in front
// of them. It has to happen HERE, after every fx.add and before the first
// openEditor, because nothing on the wire can dismiss a card once it is up.
await cmd("view.panelLayout", { workspace: "mix" });
await shot("mixer");

// ---------------------------------------------------- 4b. the cards, in turn
// Each effect card REPLACES the previous one, so from here every shot carries
// exactly one card. The poly synth goes last of all: an instrument card is a
// separate layer that effect cards do not replace, so it would sit under every
// shot that followed it.
// ⛔ GUARDED BY `SHOTS`. A card exists here ONLY to be photographed, and it
// CANNOT BE CLOSED afterwards (no close verb on the wire). So under
// --no-shots — which is how the project is rebuilt before a SCREEN RECORDING —
// opening them leaves modal cards parked over the arrangement for the whole
// take. That is exactly what happened: the first motion recording caught the
// Poly Synth and Limiter cards sitting on top of the playing track.
if (SHOTS) {
  step("the effect cards");
  for (const [trackId, effectId, label] of cards) {
    await cmd("view.openEditor", { trackId, effectId });
    await shot(label);
  }

  // ⛔⛔ THE SAME CARD AGAIN, WIDE OPEN — because the film SAYS "wide open".
  // The bus filter is authored at position -0.55 so its card photographs
  // CLOSED, and an observer found that closed card sitting under the sentence
  // "Wide open, the filter is a perfect bypass. It does nothing at all." The
  // words were true of the render and false of the picture beside them.
  // Automation drives this parameter during playback, so the static value left
  // here does not change a note of the render — only what the card shows.
  // ⚠ THE KEY IS `name`, NOT `param` (Commands.swift:2782). `mod.addRoute` in
  // cosmic.mjs uses `param` for the same idea — two verbs, two spellings.
  await cmd("fx.setParam", { trackId: mixBus, effectId: fx.busFilter,
                             name: "position", value: 0 });
  await cmd("view.openEditor", { trackId: mixBus, effectId: fx.busFilter });
  await shot("bus-filter-open");
  await cmd("fx.setParam", { trackId: mixBus, effectId: fx.busFilter,
                             name: "position", value: -0.55 });
}
// ⚠ THE POLY SYNTH CARD IS DELIBERATELY NOT OPENED HERE — it is the LAST shot
// of the whole build (after the motion burst), because an instrument card is a
// layer effect cards do not replace and it would sit under every frame after it.

// ------------------------------------------------------------------ 5. render
const wav = path.resolve(`${OUT}/${V.id}/${V.id}.wav`);
if (RENDER) {
  step("render");
  const seconds = (BARS * 4 / TEMPO) * 60;
  await cmd("render.mixdown", { path: wav, durationSeconds: Math.ceil(seconds) + 2 });
  console.log(`   wrote ${wav}`);
}

// ------------------------------------------------------------ 5b. MOTION
// ⭐ THE ONLY SHOTS IN THIS BUILD WHERE SOMETHING IS ACTUALLY MOVING.
// Every other frame is a still, and a film made entirely of stills is a slide
// deck. This runs the transport across the last bars of Build 1 and into the
// Drop with the bus DJ Filter card open, so the POSITION knob is caught tracking
// its own automation lane as the filter opens. That is "an AI agent moved a
// control" shown rather than asserted.
//
// ⚠ SILENT ON PURPOSE. transport.play goes through the REAL audio device on this
// machine. Master volume is taken to 0 for the burst and restored after — track
// meters are pre-fader, so they still animate. It runs AFTER the render so it
// cannot touch the rendered file.
// ⚠ transport.seek takes `beats`, NOT `beat`. Probed, not guessed.
if (MOTION) {
  step("motion burst — the filter opening into the drop");
  await cmd("mixer.setMasterVolume", { volume: 0 });
  await cmd("view.panelLayout", { workspace: "mix" });
  await cmd("view.openEditor", { trackId: mixBus, effectId: fx.busFilter });
  await cmd("transport.seek", { beats: 48 });
  await cmd("transport.play");
  // 10 frames across ~4.5 s of music: beats 48->64, the filter climbing from
  // -0.42 to 0.0. If the transport is not actually running these come out
  // identical and the shot self-check fails the build, which is the point.
  for (let i = 0; i < 10; i++) await shot(`motion-${String(i).padStart(2, "0")}`, { settleMs: 450 });
  await cmd("transport.stop");
  await cmd("mixer.setMasterVolume", { volume: 1 });
}

// ⛔ MEASURED GAP, AND THE FILM MUST NOT CLAIM OTHERWISE.
// I expected the burst to catch the POSITION knob tracking its automation lane
// as the filter opened. It does not: across all ten frames the DJ Filter card
// reads -0.55, its authored value, while the transport clock runs and the
// meters move. Automation demonstrably drives the RENDER (the drop measures
// +33 dB brighter than the intro), but it does not drive the effect card's
// readout during live playback. So what these frames honestly show is metering
// and the playhead — not a knob turning itself.

// The poly synth DOES have an editor card — worth showing precisely because the
// drum machine's absence is the contrast the film is built on. LAST, so that the
// instrument layer cannot sit under anything.
if (SHOTS) {
  await cmd("view.panelLayout", { workspace: "mix" });
  await cmd("view.openEditor", { trackId: lead });
  await shot("polysynth-card");
}
// Leave the app on the ARRANGE view, with no card open, so whatever runs next
// — a screen recording especially — starts on the track rather than on a panel.
await cmd("view.panelLayout", { workspace: "arrange" });

// ------------------------------------------------- 6. the shot self-check
// A labelled shot that is identical to the one before it is a picture of
// nothing happening, shipped under a caption that says something happened.
const surprises = manifest.filter((m) => m.duplicateOfPrev && !m.expectSameAsPrev);
fs.writeFileSync(`${OUT}/${V.id}/build.json`, JSON.stringify({
  variant: V.id, title: V.title, subtitle: V.subtitle, kit: V.kit, blurb: V.blurb,
  source: V.source || null, tempo: TEMPO, bars: BARS, sections: SECTIONS,
  tracks: { drums, bass, pad, lead, mixBus }, fx, wav,
  shots: manifest, duplicateShots: surprises.map((s) => s.name),
  at: new Date().toISOString(),
}, null, 2));

console.log(`\n${V.title}: ${shotN} shots, ${RENDER ? "rendered" : "no render"}`);
if (surprises.length) {
  console.error(`⚠ ${surprises.length} shot(s) identical to the previous one and NOT expected to be:`);
  for (const s of surprises) console.error(`   ${s.name}`);
  close();
  process.exit(1);
}
console.log("✅ every shot differs from the one before it (or is marked as expected-identical)");
close();
process.exit(0);
