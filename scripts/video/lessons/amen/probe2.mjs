// POSITIVE CONTROL for probe.mjs, which reported kick(36) and hat(42) at
// exactly -120.00 dB for all eight velocities while snare(38) and ride(51)
// gave a clean ladder. A uniform floor across every unit is the signature of a
// probe that never measured, not of four silent drums -- so render the same
// hits for real and look at the audio.
import { open, cmd, addTrack, addClip, n, close } from "../../session/build.mjs";

const GUGS = "/Users/dsemenov/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2";
const KIT = { kind: "soundBank", soundBank: { source: GUGS, program: 0, bankMSB: 120 } };
const AUD = new URL("./audio/", import.meta.url).pathname;

await open();
await cmd("project.new", { discardChanges: true });
await cmd("transport.setTempo", { bpm: 120 });
const t = await addTrack("Kit", { instrument: KIT });
// one hit per beat: 36 kick, 38 snare, 42 closed hat, 46 open hat, 51 ride, 49 crash
const P = [36, 38, 42, 46, 51, 49];
await addClip(t, 0, P.length + 2, P.map((p, i) => n(i, p, 0.5, 110)), "ladder");
await cmd("render.mixdown", { path: `${AUD}hitprobe.wav`, durationSeconds: (P.length + 2) * 0.5 });
console.log("wrote hitprobe.wav; pitches", P.join(","), "at 120bpm, one per beat (0.5 s)");
close(); process.exit(0);
