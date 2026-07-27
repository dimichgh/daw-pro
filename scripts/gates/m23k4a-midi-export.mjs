// m23-k4a implementer gate — Standard MIDI File EXPORT over the CONTROL WIRE,
// on staging port 17695 (G17). 17600 is the user's LIVE app and is never touched.
//
// Usage:  env DAW_CONTROL_PORT=17695 nohup .build/debug/DAWApp &
//         node scripts/gates/m23k4a-midi-export.mjs [outputDirectory]
//
// The unit suites gate every MAPPING verdict against hand-built project values;
// this gates the WIRE and the FILESYSTEM: that a real app process, driven only
// by JSON frames, writes a real `.mid` whose bytes come back through the shipped
// k3 importer with the same notes — including the two OFF-GRID beats that pin
// the rounding rule, which is the leg the roadmap's original gate could not see.
//
// It also leaves the exported file on disk so `scripts/validate-smf.swift` can
// hand it to Apple's `MusicSequenceFileLoad` (G8) — the third-party arbiter. A
// round trip through our own reader alone would pass a mirrored encoder/decoder
// bug with a green light.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const outDir = process.argv[2] ?? mkdtempSync(join(tmpdir(), "m23k4a-"));
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function connect() {
  for (let i = 0; i < 25; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket("ws://127.0.0.1:17695");
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(1000); }
  }
  throw new Error("no connect");
}
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `k4a${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};
// KEY-ORDER-INSENSITIVE deep compare. The control server encodes objects from
// Swift dictionaries, whose iteration order is NOT stable between two
// serialisations of the same value — `project.snapshot` called twice in a row
// with nothing in between already differs under a naive `JSON.stringify`. A
// gate that compared raw strings would report a difference that is not one.
const canon = v => Array.isArray(v) ? v.map(canon)
  : (v && typeof v === "object"
     ? Object.fromEntries(Object.keys(v).sort().map(k => [k, canon(v[k])]))
     : v);
const eq = (a, b) => JSON.stringify(canon(a)) === JSON.stringify(canon(b));
// The wire returns `error` as a bare string on this server, not {message}.
const msg = r => typeof r.error === "string" ? r.error : (r.error?.message ?? "");

// ---------------------------------------------------------------- fixture
let r = await cmd("project.new", { discardChanges: true });
ck("A0 project.new", r.ok, msg(r));

const lead = (await cmd("track.add", { name: "Lead", kind: "instrument" })).result?.id;
const bass = (await cmd("track.add", { name: "Bass", kind: "instrument" })).result?.id;
const vox = (await cmd("track.add", { name: "Vox", kind: "audio" })).result?.id;
ck("A1 three tracks (2 instrument + 1 audio)", !!lead && !!bass && !!vox);

const leadClip = (await cmd("clip.addMIDI",
  { trackId: lead, atBeat: 0, lengthBeats: 4 })).result?.id;
const bassClip = (await cmd("clip.addMIDI",
  { trackId: bass, atBeat: 0, lengthBeats: 4 })).result?.id;
ck("A2 two MIDI clips", !!leadClip && !!bassClip);

// The two OFF-GRID beats that discriminate `round` from floor/trunc/ceil at
// division 9600: 1.00006 * 9600 = 9600.576 (-> 9601) and 1.00001 * 9600 =
// 9600.096 (-> 9600). An on-grid fixture cannot see the rounding rule AT ALL.
r = await cmd("clip.setNotes", { clipId: leadClip, notes: [
  { pitch: 48, startBeat: 0, lengthBeats: 0.5, velocity: 100 },
  { pitch: 60, startBeat: 1.00006, lengthBeats: 0.5, velocity: 100 },
  { pitch: 62, startBeat: 1.00001, lengthBeats: 0.5, velocity: 100 },
  { pitch: 50, startBeat: 2, lengthBeats: 0.5, velocity: 100 },
]});
ck("A3 lead notes set (2 on-grid + 2 off-grid)", r.ok, msg(r));
r = await cmd("clip.setNotes", { clipId: bassClip, notes: [
  { pitch: 36, startBeat: 0, lengthBeats: 4, velocity: 90 },
]});
ck("A4 bass note set", r.ok, msg(r));

// A two-segment tempo map whose SECOND tempo does not round-trip exactly, so
// `maxTempoRoundTripErrorBPM` has something to say (61 BPM -> 983607 µs/qn).
r = await cmd("tempo.setMap", { segments: [
  { startBeat: 0, bpm: 120 }, { startBeat: 8, bpm: 61 },
]});
ck("A5 two-segment tempo map", r.ok, msg(r));

// ---------------------------------------------------------------- B: dry run
const path = join(outDir, "wire-export.mid");
r = await cmd("project.exportMIDI", { path, dryRun: true });
ck("B1 dryRun ok", r.ok, msg(r));
const dry = r.result?.report ?? {};
ck("B2 dryRun response shape {report, written:false}",
   r.result?.written === false && dry.written === false, JSON.stringify(r.result?.written));
ck("B3 dryRun still reports WHERE it would write", dry.path === path, dry.path);
ck("B4 dryRun sizes the file", typeof dry.byteCount === "number" && dry.byteCount > 0,
   dry.byteCount);
ck("B5 the audio track is SKIPPED with a reason, not an error",
   dry.tracks?.length === 3 && dry.tracks[2].exported === false
   && String(dry.tracks[2].skipReason ?? "").includes("audio track"),
   JSON.stringify(dry.tracks?.map(t => [t.name, t.exported, t.skipReason])));
// A skipped track carries NO channel: Swift's synthesized Codable omits a nil
// Optional entirely, so the key is ABSENT rather than JSON null.
ck("B6 the two instrument tracks got one channel each; the skipped one got none",
   dry.tracks?.[0].channel === 0 && dry.tracks?.[1].channel === 1
   && dry.tracks?.[2].channel == null,
   JSON.stringify(dry.tracks?.map(t => t.channel)));
ck("B7 default division is 9600, format 1",
   dry.ticksPerQuarterNote === 9600 && dry.format === 1,
   `${dry.ticksPerQuarterNote}/${dry.format}`);
ck("B8 the off-grid notes are counted as quantized and the loss is NAMED",
   dry.notesQuantized === 2 && dry.maxQuantizationErrorBeats > 0
   && dry.degradations.some(d => d.includes("nearest tick")),
   JSON.stringify([dry.notesQuantized, dry.maxQuantizationErrorBeats, dry.degradations]));
ck("B9 the inexact tempo rides the report",
   dry.maxTempoRoundTripErrorBPM > 0, dry.maxTempoRoundTripErrorBPM);

// ---------------------------------------------------------------- C: the write
r = await cmd("project.exportMIDI", { path });
ck("C1 export ok", r.ok, msg(r));
const full = r.result?.report ?? {};
ck("C2 written:true on both the envelope and the report",
   r.result?.written === true && full.written === true);
ck("C3 the dry run PREDICTED the real one exactly (modulo `written`)",
   eq({ ...dry, written: true }, full),
   JSON.stringify(Object.keys(full)
     .filter(k => !eq(full[k], k === "written" ? true : dry[k]))));
ck("C4 tracksExported/notesExported",
   full.tracksExported === 2 && full.notesExported === 5,
   `${full.tracksExported}/${full.notesExported}`);
ck("C5 tempo and meter landed on the conductor",
   full.tempoSegmentsWritten === 2 && full.meterChangesWritten === 1,
   `${full.tempoSegmentsWritten}/${full.meterChangesWritten}`);

// ---------------------------------------------------------------- D: re-import
r = await cmd("project.new", { discardChanges: true });
ck("D0 fresh project", r.ok, msg(r));
r = await cmd("project.importMIDI", { path, tempoPolicy: "adopt" });
ck("D1 re-import ok", r.ok, msg(r));
const back = r.result?.report ?? {};
ck("D2 every note came back", back.notesImported === 5, back.notesImported);
// The conductor is a part with no notes; k3 skips it and says so.
ck("D3 the parts ledger names the conductor and both tracks",
   back.parts?.length === 3, JSON.stringify(back.parts?.map(p => [p.name, p.imported])));

const snap = (await cmd("project.snapshot")).result ?? {};
const leadTrack = (snap.tracks ?? []).find(t => t.name === "Lead");
const notes = leadTrack?.clips?.[0]?.notes ?? [];
const beatOf = p => notes.find(x => x.pitch === p)?.startBeat;
// 9601/9600 and 9600/9600, written as the exact quotients rather than as
// decimal literals — the whole point of the leg is that a decimal literal
// re-opens the vacuity it exists to close.
ck("D4 the >=0.5-fraction off-grid beat came back as 9601/9600 (round, NOT floor/trunc)",
   beatOf(60) === 9601 / 9600, beatOf(60));
ck("D5 the small-fraction off-grid beat came back as 9600/9600 (round, NOT ceil)",
   beatOf(62) === 9600 / 9600, beatOf(62));
ck("D6 the on-grid notes are untouched", beatOf(48) === 0 && beatOf(50) === 2,
   `${beatOf(48)}/${beatOf(50)}`);
ck("D7 clip length survived (trailing silence is written into endTick)",
   leadTrack?.clips?.[0]?.lengthBeats === 4, leadTrack?.clips?.[0]?.lengthBeats);
ck("D8 the AUDIO track did not come back as a MIDI part",
   (snap.tracks ?? []).every(t => t.name !== "Vox"),
   JSON.stringify((snap.tracks ?? []).map(t => t.name)));

// ---------------------------------------------------------------- E: per-track
r = await cmd("project.new", { discardChanges: true });
const solo = (await cmd("track.add", { name: "Solo", kind: "instrument" })).result?.id;
const other = (await cmd("track.add", { name: "Other", kind: "instrument" })).result?.id;
await cmd("track.add", { name: "Tape", kind: "audio" });
const soloClip = (await cmd("clip.addMIDI",
  { trackId: solo, atBeat: 0, lengthBeats: 2 })).result?.id;
await cmd("clip.setNotes", { clipId: soloClip, notes: [
  { pitch: 72, startBeat: 0, lengthBeats: 1, velocity: 111 },
]});
const otherClip = (await cmd("clip.addMIDI",
  { trackId: other, atBeat: 0, lengthBeats: 2 })).result?.id;
await cmd("clip.setNotes", { clipId: otherClip, notes: [
  { pitch: 24, startBeat: 0, lengthBeats: 1, velocity: 40 },
]});

const soloPath = join(outDir, "wire-track.mid");
r = await cmd("track.exportMIDI", { trackId: solo, path: soloPath });
ck("E1 track.exportMIDI ok", r.ok, msg(r));
ck("E2 exactly one part in the ledger",
   r.result?.report?.tracks?.length === 1 && r.result?.report?.notesExported === 1,
   JSON.stringify(r.result?.report?.tracks?.map(t => t.name)));

r = await cmd("project.new", { discardChanges: true });
r = await cmd("project.importMIDI", { path: soloPath, tempoPolicy: "ignore" });
ck("E3 the single-track file re-imports as ONE track with the one note",
   r.ok && r.result?.report?.tracksCreated === 1
   && r.result?.report?.notesImported === 1, msg(r));

// ---------------------------------------------------------------- F: refusals
r = await cmd("project.exportMIDI", { ppq: 480, dryRun: true });
ck("F1 a typo'd `ppq` is REJECTED, never silently defaulted",
   !r.ok && msg(r).includes("ppq"), msg(r));
r = await cmd("project.exportMIDI", { tracks: [], dryRun: true });
ck("F2 the plural `tracks` guess is rejected too", !r.ok, msg(r));
r = await cmd("project.exportMIDI", { division: 0, dryRun: true });
ck("F3 division 0 refuses and names the range",
   !r.ok && msg(r).includes("32767"), msg(r));
r = await cmd("project.exportMIDI", { division: 32768, dryRun: true });
ck("F4 division 32768 refuses", !r.ok, msg(r));
r = await cmd("project.exportMIDI", { division: 32767, dryRun: true });
ck("F5 division 32767 is LEGAL (the edge, so the bound is not off by one)",
   r.ok && r.result?.report?.ticksPerQuarterNote === 32767, msg(r));
r = await cmd("project.exportMIDI", { format: 2, dryRun: true });
ck("F6 format 2 refuses and lists the legal values",
   !r.ok && msg(r).includes("format"), msg(r));
r = await cmd("project.exportMIDI", { path: "relative.mid", dryRun: true });
ck("F7 a relative path refuses", !r.ok && msg(r).includes("absolute"), msg(r));
// A fresh audio track: E3's `project.new` discarded the one section E made.
const tape = (await cmd("track.add", { name: "Tape2", kind: "audio" })).result?.id;
r = await cmd("track.exportMIDI", { trackId: tape, dryRun: true });
ck("F8 track.exportMIDI on an AUDIO track refuses and points at project.exportMIDI",
   !r.ok && msg(r).includes("project.exportMIDI"), msg(r));
r = await cmd("project.exportMIDI",
  { trackIds: ["11111111-2222-3333-4444-555555555555"], dryRun: true });
ck("F9 an unknown trackId refuses", !r.ok, msg(r));

// A project with NOTHING exportable refuses — but its DRY RUN succeeds, which
// is the conjunction that matters: the one call whose purpose is to find out
// must not refuse.
await cmd("project.new", { discardChanges: true });
await cmd("track.add", { name: "OnlyAudio", kind: "audio" });
r = await cmd("project.exportMIDI", { path: join(outDir, "nope.mid") });
ck("F10 a project with no instrument track refuses",
   !r.ok && msg(r).includes("nothing to export"), msg(r));
r = await cmd("project.exportMIDI", { path: join(outDir, "nope.mid"), dryRun: true });
ck("F11 …and the SAME project's dry run SUCCEEDS and reports what it found",
   r.ok && r.result?.report?.tracksExported === 0
   && String(r.result?.report?.tracks?.[0]?.skipReason ?? "").includes("audio"),
   msg(r) || JSON.stringify(r.result?.report?.tracks));

// ---------------------------------------------------------------- G: inert
// Export mutates NOTHING: no undo entry, and no change to the project.
await cmd("project.new", { discardChanges: true });
const g = (await cmd("track.add", { name: "G", kind: "instrument" })).result?.id;
const gClip = (await cmd("clip.addMIDI",
  { trackId: g, atBeat: 0, lengthBeats: 2 })).result?.id;
await cmd("clip.setNotes", { clipId: gClip, notes: [
  { pitch: 64, startBeat: 0, lengthBeats: 1, velocity: 100 },
]});
const historyBefore = (await cmd("edit.history")).result;
const snapBefore = (await cmd("project.snapshot")).result;
await cmd("project.exportMIDI", { path: join(outDir, "inert.mid") });
await cmd("track.exportMIDI", { trackId: g, path: join(outDir, "inert-track.mid") });
const historyAfter = (await cmd("edit.history")).result;
const snapAfter = (await cmd("project.snapshot")).result;
ck("G1 the undo history is IDENTICAL after two real exports",
   eq(historyBefore, historyAfter),
   JSON.stringify([historyBefore?.undo, historyAfter?.undo]));
ck("G2 the project snapshot is identical too", eq(snapBefore, snapAfter));

console.log(`\n${pass} pass / ${fail} fail`);
console.log(`exported files for the Apple-loader leg (G8) are in: ${outDir}`);
ws.close();
process.exit(fail === 0 ? 0 : 1);
