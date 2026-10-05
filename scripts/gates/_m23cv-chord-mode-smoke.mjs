// m23-cv SMOKE — ONE-FINGER CHORDS across the LIVE wire, on staging 17695.
//
// ⚠️ WHAT THIS CAN AND CANNOT SEE. It proves the chord path is reachable end to
// end and that the instruments AGREE (the view's ledger, the store's held set,
// the sink's last request, and — the leg that matters most — the CLIP that comes
// back out of a recorded take). It CANNOT see a keystroke or a pixel, and it
// CANNOT hear anything: every musical claim below is stated as pitch numbers and
// interval arithmetic. Whether a voicing sounds good is the user's judgement and
// is asserted nowhere.
//
// It is the m23-ct smoke's sibling and deliberately reuses its shape: same
// `debug.musicalTyping` seam, same `notesOn(track)` clip read-back, same
// `verdict()` exit.
//
// Staging: DAW_CONTROL_PORT=17695. 17600 is the user's live app, never touched.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, verdict } from "./_staging.mjs";

const GATE = "m23cv-chord-mode-smoke";
buildOrAbort({ label: "building staging binary (m23-cv)…" });
startStaging({ gate: GATE });
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `cv${++n}`;
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
const ok = (c, label, detail = "") => {
  if (c) { pass++; console.log("PASS " + label); }
  else { fail++; console.log("FAIL " + label + (detail ? "  << " + detail : "")); }
};
const same = (a, b) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
const body = r => (r.result ?? r.data ?? r);
const cell = (s, key) => (s.chordCells ?? []).find(c => c.key === key);

try {
  await cmd("project.new", { name: "m23cv-smoke" });
  const t = body(await cmd("track.add", { name: "Keys", kind: "instrument" }));
  const trackID = (t.track ?? t)?.id;
  ok(!!trackID, "instrument track added", JSON.stringify(t).slice(0, 200));
  // There is no `track.select` on the wire — the active track is written by a
  // HEADER CLICK, so the seam is `debug.arrangeSelection {act:"clickTrack"}`.
  await cmd("debug.arrangeSelection", { act: "clickTrack", trackId: trackID });
  await cmd("debug.musicalTyping", { enable: true });

  // ══ 1. ADDITIVE: note mode is untouched ═════════════════════════════════
  let s = body(await cmd("debug.musicalTyping", {}));
  ok(s.playMode === "notes", "chord mode is OFF by default", s.playMode);
  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  ok(same(s.sounding, [60]), "⭐ with chord mode OFF, A is still ONE note",
     JSON.stringify(s.sounding));
  await cmd("debug.musicalTyping", { release: "A" });

  // ══ 2. ONE KEY, ONE CHORD ═══════════════════════════════════════════════
  s = body(await cmd("debug.musicalTyping", { playMode: "chords" }));
  ok(s.playMode === "chords", "chord mode ON", s.playMode);
  ok(s.chordKey === 0 && s.chordMode === "major", "defaults to C major",
     `${s.chordKey} ${s.chordMode}`);
  ok(s.voicingPreset === "piano", "defaults to the piano preset", s.voicingPreset);

  // ⭐ THE USER'S OWN MOCK-UP, READ OFF THE LIVE APP: A S D F G H J are
  // C Dm Em F G Am Bdim / I ii iii IV V vi vii°.
  const home = ["A", "S", "D", "F", "G", "H", "J"].map(k => cell(s, k));
  ok(same(home.map(c => c?.chord), ["C", "Dm", "Em", "F", "G", "Am", "Bdim"]),
     "⭐ the home row is the diatonic seven, exactly as the mock-up says",
     JSON.stringify(home.map(c => c?.chord)));
  ok(same(home.map(c => c?.numeral), ["I", "ii", "iii", "IV", "V", "vi", "vii°"]),
     "⭐ …and the Roman numerals are on the keys",
     JSON.stringify(home.map(c => c?.numeral)));
  ok((s.chordCells ?? []).length === 17, "all 17 keys carry a chord",
     String((s.chordCells ?? []).length));

  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  ok(s.decision === "performed", "A performs in chord mode", s.decision);
  // C3 bass + a close root-position C major triad at middle C. Pitch numbers,
  // not an opinion: 48 = C3, 60/64/67 = C4/E4/G4.
  ok(same(s.sounding, [48, 60, 64, 67]),
     "⭐⭐ ONE KEY SOUNDED A WHOLE CHORD", JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, [48, 60, 64, 67]), "the STORE holds the same chord",
     JSON.stringify(s.storeHeldPitches));
  ok(same(s.sinkRequestedPitches, [48, 60, 64, 67]), "the SINK asked for the same chord",
     JSON.stringify(s.sinkRequestedPitches));
  ok(cell(s, "A")?.sounding === true, "…and the A cell lights on screen");

  // ══ 3. VOICE LEADING, LIVE ══════════════════════════════════════════════
  await cmd("debug.musicalTyping", { release: "A" });
  s = body(await cmd("debug.musicalTyping", { press: "G" }));   // V
  // From C4-E4-G4 to G: the common tone G is HELD and the other two move by 1
  // and 2 semitones. That is nearest-tone voice leading doing its job, and it is
  // checked as arithmetic rather than described.
  const gBody = (s.sounding ?? []).slice(1);
  ok(same(gBody, [59, 62, 67]),
     "⭐⭐ the V chord is VOICE-LED, not stacked from its root",
     JSON.stringify(s.sounding));
  const motion = [Math.abs(59 - 60), Math.abs(62 - 64), Math.abs(67 - 67)];
  ok(motion.reduce((a, b) => a + b, 0) === 3,
     "…total voice motion is 3 semitones across the change",
     JSON.stringify(motion));
  ok(same(s.sounding.slice(0, 1), [43]), "the bass moved to G2 under it",
     JSON.stringify(s.sounding));

  // ⛔ NEW CHORD REPLACES OLD — no pile-up against the 8-voice ceiling.
  ok(s.sounding.length === 4, "⛔ pressing a second chord key REPLACED the first",
     JSON.stringify(s.sounding));
  await cmd("debug.musicalTyping", { release: "G" });

  // ══ 4. THE PRESET OVERLAY — LIGHTS, NEVER GATES ═════════════════════════
  s = body(await cmd("debug.musicalTyping", { progression: "four-chords" }));
  ok(s.progression === "four-chords", "Four Chords is lit", String(s.progression));
  // ⚠️ `order` IS NO LONGER PAINTED — m34-i deleted the numeric badges after the
  // user reported them unreadable, and replaced them with the moving next-chord
  // BORDER (`_m34i-next-chord-border-smoke.mjs` owns that). It survives as SEAM
  // DATA: the step index, which is what the border's position is checked
  // against. These legs still pin the step ASSIGNMENT, which m34-i inherits.
  ok(cell(s, "A")?.order === 1 && cell(s, "G")?.order === 2
     && cell(s, "H")?.order === 3 && cell(s, "F")?.order === 4,
     "⭐ the lit keys step I=1 V=2 vi=3 IV=4, the mock-up's row exactly",
     JSON.stringify(["A", "G", "H", "F"].map(k => cell(s, k)?.order)));
  ok(cell(s, "S")?.order === null && cell(s, "D")?.order === null
     && cell(s, "J")?.order === null,
     "…and the other three degrees carry no step",
     JSON.stringify(["S", "D", "J"].map(k => cell(s, k)?.order)));
  // ⭐ EXACTLY FOUR STEPPED CELLS ON A FOUR-CHORD PRESET, ON THE LIVE APP. Found
  // by LOOKING at a screenshot: the first build numbered every cell sharing a
  // lit degree, so the colour keys and the +8va run gave ten badges and four
  // different cells all read `1`. No assertion in this tree can see a pixel, so
  // this one pins the COUNT the pixel problem reduces to. ⚠️ THE BADGE IS GONE
  // (m34-i) BUT THIS PIN IS NOT: the next-chord border inherits exactly the same
  // narrowing and would re-earn the same bug without it.
  const numbered = (s.chordCells ?? []).filter(c => c.order !== null);
  ok(numbered.length === 4,
     "⭐ exactly FOUR stepped cells for a four-chord preset",
     JSON.stringify(numbered.map(c => `${c.key}=${c.order}`)));
  const litCells = (s.chordCells ?? []).filter(c => c.lit);
  ok(litCells.length > 4,
     "…while LIT is wider than STEPPED — any lit key plays that chord",
     `${litCells.length} lit`);
  ok(cell(s, "W")?.lit === true && cell(s, "W")?.order === null,
     "a colour key of a lit degree is lit but carries no step",
     JSON.stringify(cell(s, "W")));

  // ⛔⛔ THE RULE THE USER'S CHOICE TURNS ON. A dim key must play exactly as
  // well as a lit one — "Follow the lights, or ignore them. Same keys either
  // way." This is the assertion the whole item would be wrong without.
  s = body(await cmd("debug.musicalTyping", { press: "S" }));   // ii — DIM
  ok(s.decision === "performed", "⛔⛔ a DIM key still performs", s.decision);
  ok((s.sounding ?? []).length === 4,
     "⛔⛔ a DIM key sounded a full chord — the preset lights, it never gates",
     JSON.stringify(s.sounding));
  ok((s.storeHeldPitches ?? []).length === 4, "…and it reached the store",
     JSON.stringify(s.storeHeldPitches));
  await cmd("debug.musicalTyping", { release: "S" });

  // A minor progression switches the SCALE and keeps the user's tonic.
  await cmd("debug.musicalTyping", { chordKey: 5 });            // F
  s = body(await cmd("debug.musicalTyping", { progression: "minor-rock" }));
  ok(s.chordKey === 5, "the tonic the user picked survived the preset", String(s.chordKey));
  ok(s.chordMode === "minor", "…and the scale followed the progression", s.chordMode);
  ok(cell(s, "A")?.chord === "Fm", "so A is now F minor", cell(s, "A")?.chord);
  await cmd("debug.musicalTyping", { progression: "" });
  s = body(await cmd("debug.musicalTyping", { chordKey: 0, chordMode: "major" }));
  ok(s.progression === null, "clearing the lights works", String(s.progression));

  // ══ 5. INSTRUMENT PRESETS ═══════════════════════════════════════════════
  s = body(await cmd("debug.musicalTyping", { voicingPreset: "bass" }));
  ok(s.voicingPreset === "bass", "the bass preset is selected", s.voicingPreset);
  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  ok((s.sounding ?? []).length === 1,
     "⭐ the BASS preset plays ONE note — the user's own question, answered",
     JSON.stringify(s.sounding));
  ok((s.sounding?.[0] ?? -1) % 12 === 0, "…and it is the root",
     JSON.stringify(s.sounding));
  await cmd("debug.musicalTyping", { release: "A" });
  s = body(await cmd("debug.musicalTyping", { voicingPreset: "pad" }));
  ok(cell(s, "A")?.chord === "Cmaj7", "the pad preset voices sevenths",
     cell(s, "A")?.chord);
  s = body(await cmd("debug.musicalTyping", { press: "A" }));
  const span = Math.max(...s.sounding) - Math.min(...s.sounding);
  ok(span >= 12, "…and it is SPREAD over more than an octave, not clustered",
     `span=${span} ${JSON.stringify(s.sounding)}`);
  await cmd("debug.musicalTyping", { release: "A" });
  await cmd("debug.musicalTyping", { voicingPreset: "piano" });

  // ⭐ THE COLOUR KEYS: the seven accidentals are not dead.
  s = body(await cmd("debug.musicalTyping", {}));
  ok(cell(s, "W")?.chord === "Cmaj7" && cell(s, "W")?.addsColour === true,
     "⭐ W colours the A key's chord into Cmaj7 instead of being a dead key",
     JSON.stringify(cell(s, "W")));

  // ══ 6. THE ON-SCREEN CHORD ROW, same funnel ═════════════════════════════
  s = body(await cmd("debug.musicalTyping", { chordCell: 0 }));
  ok(same(s.sounding, [48, 60, 64, 67]),
     "⭐ a MOUSE press on the chord row voiced it identically to the key",
     JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, s.sounding), "the store agrees with the mouse",
     JSON.stringify(s.storeHeldPitches));
  s = body(await cmd("debug.musicalTyping", { pointerUp: true }));
  ok(same(s.sounding, []), "a mouse release silences the chord",
     JSON.stringify(s.sounding));

  // ══ 7. ⛔⛔ GATE THE ONS, NEVER GATE THE OFFS ════════════════════════════
  await cmd("debug.musicalTyping", { press: "A" });
  s = body(await cmd("debug.musicalTyping", { playMode: "notes" }));
  ok(same(s.sounding, []),
     "⛔⛔ switching mode mid-chord strands NOTHING", JSON.stringify(s.sounding));
  ok(same(s.storeHeldPitches, []), "⛔⛔ …and the STORE is silent too",
     JSON.stringify(s.storeHeldPitches));
  await cmd("debug.musicalTyping", { playMode: "chords" });
  await cmd("debug.musicalTyping", { press: "A" });
  s = body(await cmd("debug.musicalTyping", { enable: false }));
  ok(same(s.sounding, []) && same(s.storeHeldPitches, []),
     "⛔⛔ turning the whole mode off mid-chord strands nothing either",
     JSON.stringify([s.sounding, s.storeHeldPitches]));

  // ══ 8. ⭐⭐ THE JOIN: A PLAYED CHORD, READ BACK OUT OF THE CLIP ══════════
  // The only leg that proves the thing the item promises. Everything above
  // reads a return value; this reads the RECORDING.
  await cmd("project.new", { discardChanges: true, name: "m23cv-smoke-take" });
  const rec = body(await cmd("track.add", { name: "Chords ARMED", kind: "instrument" }));
  const recID = (rec.track ?? rec)?.id;
  ok(!!recID, "a track to record onto");

  async function notesOn(id) {
    const snap = body(await cmd("project.snapshot"));
    const track = (snap.tracks ?? []).find(x => x.id === id);
    const out = [];
    for (const clip of track?.clips ?? []) {
      const got = body(await cmd("clip.getNotes", { clipId: clip.id }));
      for (const note of got.notes ?? []) out.push(note.pitch);
    }
    return out.sort((a, b) => a - b);
  }

  await cmd("track.setArm", { trackId: recID, armed: true });
  await cmd("debug.arrangeSelection", { act: "clickTrack", trackId: recID });
  await cmd("debug.musicalTyping", { enable: true });
  await cmd("debug.musicalTyping", { playMode: "chords" });
  await cmd("debug.musicalTyping", { progression: "four-chords" });
  // ⚠️ EXPLICIT COUNT-IN 0 (m23-cy): the project default is ONE bar = 2.0 s at
  // 120 BPM, far longer than the waits below, so every chord would land
  // pre-anchor and this gate would report the seam broken when it is not.
  await cmd("transport.setMetronome", { enabled: false, countInBars: 0 });
  await cmd("transport.record", {});
  // ⚠️ 500 ms BEFORE THE FIRST CHORD, AND IT IS NOT PADDING. A take's anchor is
  // scheduled slightly ahead of startTake and every PRE-ANCHOR note-on is
  // discarded by design — the same rule that makes count-in work.
  await sleep(500);

  s = body(await cmd("debug.musicalTyping", { press: "A" }));   // I  = C
  ok(s.targetState === "recording-armed", "the app predicts a captured take",
     s.targetState);
  ok(s.sinkIsRecording === true, "⭐ the ENGINE confirms the take is keeping it",
     JSON.stringify(s.sinkIsRecording));
  ok(s.sinkCapturedEdges >= 4,
     "⭐⭐ ONE KEY PRESS PUT A WHOLE CHORD'S EDGES INTO THE TAKE",
     JSON.stringify(s.sinkCapturedEdges));
  const chordOne = s.sounding.slice();
  await sleep(700);
  await cmd("debug.musicalTyping", { release: "A" });
  await sleep(300);
  s = body(await cmd("debug.musicalTyping", { press: "G" }));   // V  = G
  const chordTwo = s.sounding.slice();
  await sleep(700);
  await cmd("debug.musicalTyping", { release: "G" });
  await sleep(300);
  await cmd("transport.stop", {});
  await sleep(800);

  const recorded = await notesOn(recID);
  // ⭐ PRINTED UNCONDITIONALLY, PASS OR FAIL. Nobody here can hear the take, so
  // the pitch numbers ARE the evidence and they belong in the log rather than
  // only in a failure message. This is also the only place a human reading the
  // gate output can check the harmony by eye.
  console.log(`  chord 1 sounded ${JSON.stringify(chordOne)}`);
  console.log(`  chord 2 sounded ${JSON.stringify(chordTwo)}`);
  console.log(`  CLIP CONTAINS   ${JSON.stringify(recorded)}`);
  ok(recorded.length >= 6,
     "⭐⭐⭐ THE CLIP CARRIES A REAL CHORD PROGRESSION, PLAYED WITH TWO KEYSTROKES",
     `${recorded.length} notes: ${JSON.stringify(recorded)}`);
  const wanted = [...new Set([...chordOne, ...chordTwo])].sort((a, b) => a - b);
  const missing = wanted.filter(p => !recorded.includes(p));
  ok(missing.length === 0,
     "⭐⭐ every pitch that SOUNDED is in the clip — nothing was dropped",
     `missing ${JSON.stringify(missing)} of wanted ${JSON.stringify(wanted)}`);
  // ⚠️ AND NOT MORE THAN WAS PLAYED. A heartbeat that re-recorded the held set
  // would inflate this; the set-shaped seam is what prevents it.
  ok(recorded.length <= wanted.length + 2,
     "…and the take was not inflated by the liveness heartbeat",
     `${recorded.length} recorded vs ${wanted.length} played`);

  console.log(`M23CV_CHORD_SMOKE pass=${pass} fail=${fail} total=${pass + fail}`);
} finally {
  try { ws.close(); } catch {}
  stopStaging(GATE);
}
verdict({ ran: pass + fail, failed: fail });
