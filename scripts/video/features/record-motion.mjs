#!/usr/bin/env node
// REAL MOTION — the playhead sweeping and the meters moving, at 30 fps.
//
// ⛔ WHY THIS EXISTS: the first cut of this film was 33 STILLS cut on a timer.
// The user's note was blunt — "you are just flipping screenshots which is not
// good" — and they were right. `debug.captureUI` runs at about 3.5 fps and
// CANNOT film movement; the 10-frame "motion burst" it produced was a 1 fps
// time-lapse, which is a slideshow with extra steps.
//
// `scripts/video/screenrec` (ScreenCaptureKit, built 2026-09-05) exists for
// exactly this and records a real 30 fps. captureUI stays the DEFAULT for
// stills; this is the documented EXCEPTION, for motion only.
//
// This script only drives the transport. The recording is started alongside it
// by record-all.sh, because the two have to overlap.
//
// ⛔⛔ SILENT WITHOUT MUTING THE MASTER — AND THE DIFFERENCE IS VISIBLE.
// This used to do `mixer.setMasterVolume {volume: 0}`, because playback goes
// through the real output device and the user is sitting at the machine. Track
// meters are pre-fader so they still moved — but the MASTER strip read
// "-inf dB" under audible music, in three separate places in the finished film.
// An observer caught it: a dead master fader is a bug report, not a demo.
//
// So instead the STAGING app is routed to BlackHole 2ch, a virtual device with
// no speaker behind it. The mix plays at FULL level into nowhere: every meter,
// the master fader included, reads normally, and the room stays quiet.
//
// ⚠ BY UID, NEVER BY NAME OR INDEX — BlackHole's numeric device id changes on
//   every coreaudiod restart. `uid` is also the only key the verb accepts; the
//   refusal for `deviceUID` names it explicitly.
// ⚠ THIS MOVES STAGING ONLY. `isDefault` stays on the user's own output, so the
//   SYSTEM default — and every other app — is untouched. Never change that.
// ⚠ transport.seek takes `beats`, NOT `beat`. Probed, not guessed.
import { open, close, cmd } from "./arrange.mjs";

const SILENT_UID = "BlackHole2ch_UID";

const view = process.argv[2] || "arrange";     // arrange | mix
const beats = Number(process.argv[3] || 44);
const hold = Number(process.argv[4] || 30);    // seconds to leave it playing
// A clip to open in the roll. Either an INDEX into the flattened clip list, or
// a NAME — any substring of "Track / Clip", case-insensitive. "-1" or absent
// means stay in the arrange view.
//
// ⛔ A NAME IS SAFER THAN AN INDEX AND THAT IS WHY IT IS HERE. An index is a
// guess about an ordering nobody asserts; reorder the tracks and the take
// silently films the wrong clip, which is exactly the class of defect this
// whole pass is chasing.
const clipArg = process.argv[5] ?? "-1";

await open();

// Route staging at the virtual device and PROVE it took. A setter's return is
// not proof: read the list back and check the flag. The field is `isSelected`
// — there is no `current` field, and looking for one reads as "nothing is
// selected" on a list where something plainly is.
await cmd("output.setDevice", { uid: SILENT_UID });
const { devices } = await cmd("output.listDevices", {});
const sel = devices.find((d) => d.isSelected);
if (!sel || sel.uid !== SILENT_UID) {
  console.error(`REFUSING TO PLAY: staging output is ${sel ? sel.name : "unset"}, not BlackHole.`);
  console.error("Playing now would come out of the user's speakers at full volume.");
  close();
  process.exit(2);
}
// Master stays at unity — that is the entire point of the device route.
await cmd("mixer.setMasterVolume", { volume: 1 });

await cmd("view.panelLayout", { workspace: view });

if (clipArg !== "-1" && clipArg !== "") {
  const ov = await cmd("project.overview", {});
  const clips = (ov.tracks || []).flatMap((t) =>
    (t.clips || []).map((c) => ({
      id: c.id, label: `${t.name} / ${c.name ?? ""}`,
      from: c.startBeat, to: c.startBeat + c.lengthBeats,
    })));
  const n = Number(clipArg);
  let pick, how;
  if (Number.isInteger(n)) {
    pick = clips[n]; how = "by index";
  } else {
    const named = clips.filter((c) => c.label.toLowerCase().includes(clipArg.toLowerCase()));
    // ⛔⛔ AMONG CLIPS OF THE RIGHT NAME, TAKE THE ONE THIS TAKE ACTUALLY SITS
    // IN. Probed on machine-room: the Drums track has SIX clips, one per section
    // (Intro 0–32, Build 32–64, Drop 64–128, Breakdown 128–160, ...). A plain
    // first-name-match opens the roll on Drums Intro no matter where the
    // transport is — so the viewer sees a piano roll whose notes are not the
    // notes being played, and three takes seeking to three different sections
    // all show the same picture.
    //
    // ⭐ AND IT MATCHES ON THE MIDPOINT OF THE TAKE, NOT THE SEEK. The seek sits
    // a couple of seconds EARLY on purpose (the recorder starts after the
    // transport), so at the seek beat the playhead is often still in the
    // PREVIOUS section: `honest` seeks to 124 and would open Drums Drop while
    // its audio is the breakdown that begins at 128. The clip a take spends
    // most of its time in is the honest answer.
    const mid = beats + (hold / 2) * (ov.transport.tempoBPM / 60);
    pick = named.find((c) => mid >= c.from && mid < c.to)
        || named.find((c) => beats >= c.from && beats < c.to);
    how = pick ? `covers beat ${mid.toFixed(0)} (take midpoint)`
               : "name match (NO clip covers this take)";
    if (!pick) pick = named[0];
  }
  // LOUD, NOT SILENT. This used to be `if (clips[i]) select(...)` — an
  // out-of-range index just did nothing and the take recorded the arrange view
  // instead of the roll, with no error anywhere.
  if (!pick) {
    console.error(`⛔ no clip matches ${JSON.stringify(clipArg)}. Available:`);
    clips.forEach((c, i) => console.error(`   [${i}] ${c.label}  beats ${c.from}–${c.to}`));
    close();
    process.exit(3);
  }
  console.error(`clip: ${pick.label} (${pick.from}–${pick.to}) — ${how}`);
  await cmd("view.selectClip", { clipId: pick.id });
}

// ⚠ SEEK AFTER THE SELECT, NOT BEFORE. Selecting a clip may move the playhead
// to it; doing the seek first would then be silently undone and the take would
// film the wrong bar while reporting the right one.
await cmd("transport.seek", { beats });
// ⚠ TIMESTAMPED so LEAD_IN in record-all.sh can be MEASURED rather than
// assumed. That constant shifts the seek to make the first recorded frame land
// on the start of the audio excerpt; it is currently a guess at how long the
// wire handshake takes. Compare this against the recorder's own start in
// rec.log after a run and correct it from the difference.
console.error(`play at ${new Date().toISOString()} (seek ${beats} beats)`);
await cmd("transport.play");

// ⛔⛔ PROVE THE PLAYHEAD IS MOVING BEFORE THE CAMERA COMMITS 22 SECONDS TO IT.
// `transport.play` returns success whether or not anything plays. Seek past the
// end of the content and the transport sits at a standstill; the screen recorder
// then captures a technically perfect video of a motionless app, and the only
// thing downstream that would notice is a human watching the finished film.
// (One take in this very table asked for beat 200 of a 160-beat piece.)
//
// So: read the position twice, 1.2 s apart, and require it to have ADVANCED.
// This is a measurement of the thing that matters, not a proxy for it — it
// catches a short piece, a dead engine and a failed seek with one check.
const pos = async () => (await cmd("project.overview", {})).transport;
const t0 = await pos();
await new Promise((r) => setTimeout(r, 1200));
const t1 = await pos();
if (!t1.isPlaying || t1.positionBeats <= t0.positionBeats) {
  console.error(`⛔ TRANSPORT IS NOT MOVING: beat ${t0.positionBeats.toFixed(2)} → ` +
                `${t1.positionBeats.toFixed(2)}, isPlaying=${t1.isPlaying}.`);
  console.error(`   Seek was ${beats} beats — most likely past the end of this piece.`);
  console.error("   Recording now would produce a still frame held for the whole take.");
  await cmd("transport.stop");
  close();
  process.exit(4);
}
console.error(`moving: beat ${t0.positionBeats.toFixed(1)} → ${t1.positionBeats.toFixed(1)}`);

await new Promise((r) => setTimeout(r, Math.max(0, hold - 1.2) * 1000));
await cmd("transport.stop");
close();
process.exit(0);
