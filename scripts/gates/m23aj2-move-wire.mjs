// m23-aj-2 staging gate — clip.moveManyByTracks / clip.moveManyToTrack over
// the REAL control port. The WIRE half of m23-aj-1's cross-track group move
// (ProjectStore.moveClips(ids:byTracks:byBeats:) /
// moveClips(ids:toTrackId:byBeats:)).
//
// WHY THIS EXISTS AS A LIVE GATE, NOT ONLY SWIFT TESTS (the m23w precedent):
// Tests/DAWCoreTests/ClipCrossTrackMoveTests.swift proves the DOMAIN verb;
// Tests/DAWControlTests/ClipCrossTrackMoveCommandTests.swift proves the wire
// encoding in-process against a FakeMedia router. Neither proves the two
// commands are actually REACHABLE through the real router over a real socket
// with the real JSON encode/decode round trip — a registered-but-unroutable
// verb, or a response the wire encoder silently drops, is exactly what an
// in-process test cannot catch.
//
// FIXTURE, mirroring the DAWCore suite's own fixture EXACTLY so a wire leg
// and its domain counterpart reason about identical geometry:
//   [inst A, inst B, inst C, bus D, audio E]
// Every clip in this gate is MIDI (clip.addMIDI) — deliberately. Only the
// DESTINATION track's kind matters for every kind-refusal/clamp leg here, not
// the clip's own kind, so no audio-file fixture is needed anywhere in this
// gate (audio-clip-vs-track-kind correctness is DAWCore's job, proven by
// ClipCrossTrackMoveTests legs 6a/6b and 14).
//
// Staging 17695 ONLY. 17600 is the user's LIVE app and is never touched.
// Kill by EXACT pid from the pidfile — never pkill/pgrep. Lifecycle from
// `_staging.mjs` (m23-ac-1).
import { launchStaging, stopStaging, STAGING_PORT } from "./_staging.mjs";

const GATE = "m23aj2";
let ws, seq = 0, pass = 0, fail = 0;
const failures = [];

function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = `aj2-${++seq}`;
    const timer = setTimeout(() => rej(new Error(`timeout ${command}`)), timeoutMs);
    const onMsg = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id !== id) return;
      clearTimeout(timer); ws.removeEventListener("message", onMsg); res(m);
    };
    ws.addEventListener("message", onMsg);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
function ck(label, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS ${label}`); }
  else { fail++; failures.push(label); console.log(`FAIL ${label} :: ${detail}`); }
}
const histLen = async () => (await cmd("edit.history")).result?.undo?.length ?? -1;
const mk = async (trackId, name, atBeat, lengthBeats = 4) =>
  (await cmd("clip.addMIDI", { trackId, name, atBeat, lengthBeats })).result?.id;
const startBeatOf = (r, id) => (r.result?.clips ?? []).find((c) => c.id === id)?.startBeat;

async function buildFixture() {
  await cmd("project.new", { discardChanges: true });
  const a = (await cmd("track.add", { name: "A", kind: "instrument" })).result?.id;
  const b = (await cmd("track.add", { name: "B", kind: "instrument" })).result?.id;
  const c = (await cmd("track.add", { name: "C", kind: "instrument" })).result?.id;
  const d = (await cmd("track.add", { name: "D", kind: "bus" })).result?.id;
  const e = (await cmd("track.add", { name: "E", kind: "audio" })).result?.id;
  return { a, b, c, d, e };
}

try {
  const staging = await launchStaging({ gate: GATE });
  ws = staging.ws;
  console.log(`connected to staging on ${STAGING_PORT} (pid ${staging.pid})`);

  // =========================================================================
  // clip.moveManyByTracks
  // =========================================================================

  // ---- L1: happy path — a group spanning 2 tracks moves down 1 -------------
  {
    const t = await buildFixture();
    const x = await mk(t.a, "X", 0);
    const y = await mk(t.b, "Y", 4);
    const r = await cmd("clip.moveManyByTracks", { ids: [x, y], byTracks: 1 });
    ck("L1 ok", r.ok, JSON.stringify(r).slice(0, 240));
    const res = r.result ?? {};
    ck("L1 requestedTrackDelta == 1", res.requestedTrackDelta === 1, JSON.stringify(res.requestedTrackDelta));
    ck("L1 effectiveTrackDelta == 1", res.effectiveTrackDelta === 1, JSON.stringify(res.effectiveTrackDelta));
    ck("L1 clampedTracks == false", res.clampedTracks === false, JSON.stringify(res.clampedTracks));
    const landings = res.landings ?? [];
    ck("L1 two landings", landings.length === 2, JSON.stringify(landings));
    const toTracks = landings.map((l) => l.toTrackId).sort();
    ck("L1 landed on B and C", JSON.stringify(toTracks) === JSON.stringify([t.b, t.c].sort()),
       JSON.stringify(toTracks));
    ck("L1 offsets intact (0 and 4)", startBeatOf(r, x) === 0 && startBeatOf(r, y) === 4,
       JSON.stringify(res.clips));
  }

  // ---- L2: vertical clamp (TOP) — already at track 0, a runaway -5 clamps to 0
  {
    const t = await buildFixture();
    const m = await mk(t.a, "M", 0);
    const before = await histLen();
    const r = await cmd("clip.moveManyByTracks", { ids: [m], byTracks: -5 });
    ck("L2 ok", r.ok, JSON.stringify(r).slice(0, 200));
    const res = r.result ?? {};
    ck("L2 requestedTrackDelta == -5", res.requestedTrackDelta === -5, JSON.stringify(res.requestedTrackDelta));
    ck("L2 effectiveTrackDelta == 0", res.effectiveTrackDelta === 0, JSON.stringify(res.effectiveTrackDelta));
    ck("L2 clampedTracks == true", res.clampedTracks === true, JSON.stringify(res.clampedTracks));
    const l = (res.landings ?? [])[0] ?? {};
    ck("L2 landing from==to==A (no-op)", l.fromTrackId === t.a && l.toTrackId === t.a, JSON.stringify(l));
    ck("L2 no undo step pushed (whole-group clamp to 0 is a no-op)", (await histLen()) === before, `${before}`);
  }

  // ---- L3: beat-0 clamp — byBeats carrying the leftmost clip past 0 --------
  {
    const t = await buildFixture();
    const m = await mk(t.a, "M", 2);
    const r = await cmd("clip.moveManyByTracks", { ids: [m], byTracks: 0, byBeats: -8 });
    const res = r.result ?? {};
    ck("L3 requestedDeltaBeats == -8", res.requestedDeltaBeats === -8, JSON.stringify(res.requestedDeltaBeats));
    ck("L3 effectiveDeltaBeats == -2", res.effectiveDeltaBeats === -2, JSON.stringify(res.effectiveDeltaBeats));
    ck("L3 clamped == true", res.clamped === true, JSON.stringify(res.clamped));
    ck("L3 clip landed at beat 0", startBeatOf(r, m) === 0, JSON.stringify(res.clips));
  }

  // ---- L4: empty ids is a legal no-op, AND still carries both track-delta keys
  {
    const t = await buildFixture();
    const before = await histLen();
    const r = await cmd("clip.moveManyByTracks", { ids: [], byTracks: 1 });
    ck("L4 ok", r.ok, JSON.stringify(r).slice(0, 160));
    const res = r.result ?? {};
    ck("L4 landings empty", (res.landings ?? []).length === 0, JSON.stringify(res.landings));
    ck("L4 clips empty", (res.clips ?? []).length === 0, JSON.stringify(res.clips));
    ck("L4 requestedTrackDelta present (byTracks ALWAYS carries it)", res.requestedTrackDelta === 1,
       JSON.stringify(res.requestedTrackDelta));
    ck("L4 effectiveTrackDelta present (== 0, nothing to move)", res.effectiveTrackDelta === 0,
       JSON.stringify(res.effectiveTrackDelta));
    ck("L4 no undo step pushed", (await histLen()) === before, `${before}`);
  }

  // ---- L5: rejectUnknownKeys -------------------------------------------------
  {
    await buildFixture();
    const r = await cmd("clip.moveManyByTracks", { ids: [], byTracks: 0, bogus: 1 });
    ck("L5 unknown key refused", !!r.error, JSON.stringify(r).slice(0, 200));
    ck("L5 error names the bad key", /bogus/.test(r.error ?? ""), r.error ?? "");
    ck("L5 error names the verb", /clip\.moveManyByTracks/.test(r.error ?? ""), r.error ?? "");
  }

  // ---- L6: byTracks is REFUSED when non-integral, never truncated ----------
  {
    const t = await buildFixture();
    const m = await mk(t.a, "M", 0);
    const r = await cmd("clip.moveManyByTracks", { ids: [m], byTracks: 1.5 });
    ck("L6 non-integral byTracks refused", !!r.error, JSON.stringify(r).slice(0, 200));
    ck("L6 error names byTracks", /byTracks/.test(r.error ?? ""), r.error ?? "");
    ck("L6 error names 'whole number'", /whole number/.test(r.error ?? ""), r.error ?? "");
    const ov = await cmd("project.overview");
    const track0 = (ov.result?.tracks ?? []).find((tr) => tr.id === t.a);
    ck("L6 the clip did NOT move (not silently truncated to 1)",
       (track0?.clips ?? []).some((c) => c.id === m), JSON.stringify(track0));
  }

  // ---- L7: byTracks is required — omitting it is refused --------------------
  {
    await buildFixture();
    const r = await cmd("clip.moveManyByTracks", { ids: [] });
    ck("L7 missing byTracks refused", !!r.error, JSON.stringify(r).slice(0, 200));
    ck("L7 error names byTracks", /byTracks/.test(r.error ?? ""), r.error ?? "");
  }

  // ---- L8: kind refusal — a MIDI clip landing on the AUDIO track -----------
  {
    const t = await buildFixture();
    const m = await mk(t.c, "M", 0);   // C is index 2; +2 lands on E (audio, index 4)
    const r = await cmd("clip.moveManyByTracks", { ids: [m], byTracks: 2 });
    ck("L8 refused", !!r.error, JSON.stringify(r).slice(0, 200));
    ck("L8 error names MIDI clips", /cannot hold MIDI clips/.test(r.error ?? ""), r.error ?? "");
    const ov = await cmd("project.overview");
    const trackC = (ov.result?.tracks ?? []).find((tr) => tr.id === t.c);
    ck("L8 the WHOLE move refused — clip stayed on C", (trackC?.clips ?? []).some((c) => c.id === m),
       JSON.stringify(trackC));
  }

  // ---- L9: kind refusal — ANYTHING landing on a bus -------------------------
  {
    const t = await buildFixture();
    const m = await mk(t.c, "M", 0);   // C is index 2; +1 lands on D (bus, index 3)
    const r = await cmd("clip.moveManyByTracks", { ids: [m], byTracks: 1 });
    ck("L9 refused", !!r.error, JSON.stringify(r).slice(0, 200));
    ck("L9 error names 'cannot hold'", /cannot hold/.test(r.error ?? ""), r.error ?? "");
    const ov = await cmd("project.overview");
    const trackC = (ov.result?.tracks ?? []).find((tr) => tr.id === t.c);
    ck("L9 the WHOLE move refused — clip stayed on C", (trackC?.clips ?? []).some((c) => c.id === m),
       JSON.stringify(trackC));
  }

  // =========================================================================
  // clip.moveManyToTrack
  // =========================================================================

  // ---- L10: happy path — a 2-track group COLLAPSES onto one track ----------
  {
    const t = await buildFixture();
    const x = await mk(t.a, "X", 0);
    const y = await mk(t.b, "Y", 4);
    const r = await cmd("clip.moveManyToTrack", { ids: [x, y], toTrackId: t.c });
    ck("L10 ok", r.ok, JSON.stringify(r).slice(0, 200));
    const res = r.result ?? {};
    const landings = res.landings ?? [];
    ck("L10 both land on C", landings.every((l) => l.toTrackId === t.c), JSON.stringify(landings));
    ck("L10 offsets intact (0 and 4)", startBeatOf(r, x) === 0 && startBeatOf(r, y) === 4,
       JSON.stringify(res.clips));
  }

  // ---- L11: beat-0 clamp on the toTrack shape -------------------------------
  {
    const t = await buildFixture();
    const m = await mk(t.a, "M", 2);
    const r = await cmd("clip.moveManyToTrack", { ids: [m], toTrackId: t.a, byBeats: -8 });
    const res = r.result ?? {};
    ck("L11 effectiveDeltaBeats == -2", res.effectiveDeltaBeats === -2, JSON.stringify(res.effectiveDeltaBeats));
    ck("L11 clamped == true", res.clamped === true, JSON.stringify(res.clamped));
    ck("L11 clip landed at beat 0", startBeatOf(r, m) === 0, JSON.stringify(res.clips));
  }

  // ---- L12: empty ids with a VALID toTrackId is still a legal no-op --------
  {
    const t = await buildFixture();
    const before = await histLen();
    const r = await cmd("clip.moveManyToTrack", { ids: [], toTrackId: t.a });
    ck("L12 ok", r.ok, JSON.stringify(r).slice(0, 160));
    ck("L12 landings empty", (r.result?.landings ?? []).length === 0, JSON.stringify(r.result?.landings));
    ck("L12 no undo step pushed", (await histLen()) === before, `${before}`);
  }

  // ---- L13: an unknown toTrackId is refused EVEN WHEN ids is empty ---------
  {
    await buildFixture();
    const r = await cmd("clip.moveManyToTrack", { ids: [], toTrackId: "11111111-2222-3333-4444-555555555555" });
    ck("L13 refused", !!r.error, JSON.stringify(r).slice(0, 200));
    ck("L13 error names 'No track with id'", /No track with id/.test(r.error ?? ""), r.error ?? "");
  }

  // ---- L14: rejectUnknownKeys ------------------------------------------------
  {
    const t = await buildFixture();
    const r = await cmd("clip.moveManyToTrack", { ids: [], toTrackId: t.a, byTracks: 1 });
    ck("L14 unknown key refused", !!r.error, JSON.stringify(r).slice(0, 200));
    ck("L14 error names byTracks", /byTracks/.test(r.error ?? ""), r.error ?? "");
    ck("L14 error names the verb", /clip\.moveManyToTrack/.test(r.error ?? ""), r.error ?? "");
  }

  // ---- L15: kind refusal — a MIDI clip landing on the AUDIO track ----------
  {
    const t = await buildFixture();
    const m = await mk(t.c, "M", 0);
    const r = await cmd("clip.moveManyToTrack", { ids: [m], toTrackId: t.e });
    ck("L15 refused", !!r.error, JSON.stringify(r).slice(0, 200));
    ck("L15 error names MIDI clips", /cannot hold MIDI clips/.test(r.error ?? ""), r.error ?? "");
    const ov = await cmd("project.overview");
    const trackC = (ov.result?.tracks ?? []).find((tr) => tr.id === t.c);
    ck("L15 the WHOLE move refused — clip stayed on C", (trackC?.clips ?? []).some((c) => c.id === m),
       JSON.stringify(trackC));
  }

  // ---- L16: the MANUFACTURED-collision refusal, BYTE-EXACT message ---------
  // Two movers from DIFFERENT source tracks, same beats: a collision this
  // verb itself MANUFACTURES by collapsing them onto C. `CommandRouter` has
  // NO wire-side error mapping (the blanket `LocalizedError` arm), so this
  // pins that the wire message is IDENTICAL to `ProjectError.errorDescription`
  // — not merely that it contains the right words.
  {
    const t = await buildFixture();
    const x = await mk(t.a, "X", 0);
    const y = await mk(t.b, "Y", 0);
    const r = await cmd("clip.moveManyToTrack", { ids: [x, y], toTrackId: t.c });
    ck("L16 refused", !!r.error, JSON.stringify(r).slice(0, 200));
    const expected =
      `clips 'X' (${x}) and 'Y' (${y}) would overlap on the destination track — moving several ` +
      "tracks' clips onto one track needs them at different beats (move them one at a time, or " +
      "use clip.moveManyByTracks to keep them on separate tracks)";
    ck("L16 message is BYTE-EXACT (not merely 'contains')", r.error === expected,
       `got: ${JSON.stringify(r.error)}\nwant: ${JSON.stringify(expected)}`);
  }

  // ---- L17: .toTrack response OMITS requestedTrackDelta/effectiveTrackDelta
  // Contrast with L1/L4 above, which assert byTracks ALWAYS carries both keys
  // (even for a no-op) — the omission here is a deliberate asymmetry, not a
  // coincidental miss.
  {
    const t = await buildFixture();
    const m = await mk(t.a, "M", 0);
    const r = await cmd("clip.moveManyToTrack", { ids: [m], toTrackId: t.b });
    ck("L17 ok", r.ok, JSON.stringify(r).slice(0, 200));
    const res = r.result ?? {};
    ck("L17 requestedTrackDelta key is ABSENT (not null)", !("requestedTrackDelta" in res),
       JSON.stringify(Object.keys(res)));
    ck("L17 effectiveTrackDelta key is ABSENT (not null)", !("effectiveTrackDelta" in res),
       JSON.stringify(Object.keys(res)));
    ck("L17 the rest of the shape is still present", "clampedTracks" in res && "landings" in res,
       JSON.stringify(Object.keys(res)));
  }
} catch (err) {
  fail++; failures.push(`harness: ${err.message}`);
  console.log(`FAIL harness :: ${err.message}`);
} finally {
  try { ws?.close(); } catch { /* already gone */ }
  stopStaging(GATE);
}

console.log(`\nM23AJ2 ${pass}/${pass + fail}`);
if (failures.length) console.log("failed legs:\n  " + failures.join("\n  "));
process.exit(fail === 0 ? 0 : 1);
