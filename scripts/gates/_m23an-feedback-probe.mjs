// _m23an — MEASUREMENT INSTRUMENT, not a gate. `_`-prefixed so the corpus
// classifier skips it (a synthetic probe counted as coverage is worse than no
// probe at all).
//
// PURPOSE: establish, on a LIVE staging binary and BEFORE any code changes,
// what a track-header click on a zero-clip track actually does — because the
// last two cycles (m23-al, m23-am) both found the filed cause FALSE, and the
// m23-an filing makes two claims worth testing rather than trusting:
//
//   (i)  "the `.noClips` branch changes nothing and draws nothing, so the click
//        reads as if it did not register"  -> is the click really inert?
//   (ii) `.noClips` is the case that has no feedback  -> is it the ONLY one?
//
// The DISCRIMINATOR legs (D1/D2/D6) are what decide the predicate's shape:
// "nothing visible happened" is a DIFFERENT question from "which branch fired",
// and it may be broader (a plain click on an empty track is not `.noClips`) or
// narrower (a plain click that closes the piano roll is very visible indeed).
//
// Every verdict is THREE-WAY where its negative branch is reachable by an error
// (m23-am's law): succeeded / failed-for-the-expected-reason / INSTRUMENT FAULT.
//
// Usage:  node scripts/gates/_m23an-feedback-probe.mjs
import {
  ROOT as REPO, STAGING_PORT as PORT, DEFAULT_BINARY as BINARY,
  sleep, buildOrAbort, startStaging, stopStaging, pidfilePath, connect,
} from "./_staging.mjs";

const GATE = "_m23an-feedback-probe";
const PIDFILE = pidfilePath(GATE);

buildOrAbort({ root: REPO });

const staging = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY,
  detached: true, pidfile: PIDFILE,
});
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4500);

// `_staging.connect` returns the RAW socket; the request/response wrapper is
// each gate's own (the m23-am shape, copied verbatim so a probe and a gate
// cannot disagree about what a reply is).
const ws = await connect({ port: PORT });
let nextId = 1;
const pending = new Map();
ws.onmessage = (ev) => {
  let m; try { m = JSON.parse(ev.data); } catch { return; }
  const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
  if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
  else e.resolve(m.result ?? m);
};
const req = (command, params = {}) => new Promise((resolve, reject) => {
  const id = String(nextId++);
  pending.set(id, { resolve, reject, command });
  ws.send(JSON.stringify({ id, command, params }));
  setTimeout(() => {
    if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
  }, 25000);
});
const teardown = () => { try { stopStaging(GATE, PIDFILE); } catch {} };
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => { console.error(`${ev}:`, e && e.message); teardown(); process.exit(2); });
}

const say = (s) => console.log(s);
const sel = (p) => req("debug.arrangeSelection", p);
const short = (s) => (typeof s === "string" ? s.slice(0, 8) : String(s));

/** Selection STATE, normalised so two reads can be compared as strings. */
function snap(s) {
  // FIELD NAMES ARE THE SEAM'S, verified against the printed key list below —
  // a probe that guesses `selectedClipIds` reads `undefined`, reports n=0 for
  // every leg, and looks exactly like a measurement that found no change. That
  // is what the D5 control leg exists to catch, and it caught it.
  if (!Array.isArray(s.selectedIds)) throw new Error("seam has no selectedIds array");
  const ids = s.selectedIds.slice().sort();
  return {
    n: ids.length,
    ids: ids.map(short).join(","),
    focus: short(s.focusClipId ?? null),
    open: short(s.editorClipId ?? null),
    nonce: s.keyFocusNonce,
    surface: s.activeEditorSurface,
    renderSeq: s.renderSeq,
  };
}
const same = (a, b) => a.n === b.n && a.ids === b.ids && a.focus === b.focus && a.open === b.open;

try {
  // ══ FIXTURE ════════════════════════════════════════════════════════════════
  // Track A: 3 MIDI clips.  Track B: ZERO clips (an instrument track, created
  // and left alone).  Both are instrument tracks, so the ONLY difference
  // between them is the clip count — the variable under test.
  await req("project.new", { discardChanges: true });
  const tA = (await req("track.add", { name: "HAS CLIPS", kind: "instrument" })).id;
  const tB = (await req("track.add", { name: "EMPTY", kind: "instrument" })).id;
  for (let i = 0; i < 3; i++) {
    await req("clip.addMIDI", { trackId: tA, atBeat: i * 4, lengthBeats: 4 });
  }
  const ov = await req("project.overview", {});
  const counts = (ov.tracks ?? []).map((t) => (t.clips ?? []).length);
  say(`fixture: tracks=${counts.length} clipCounts=${JSON.stringify(counts)}`);
  if (counts[0] !== 3 || counts[1] !== 0) {
    say("*** INSTRUMENT FAULT: fixture is not 3-clips / 0-clips. Nothing below is readable.");
    throw new Error("fixture");
  }

  // Print the seam's FULL shape once — a probe that guesses field names and
  // reads `undefined` reports exactly like one that measured an absence.
  const shape = await sel({});
  say(`\nseam keys: ${Object.keys(shape).sort().join(" ")}`);

  // ══ D5 CONTROL — a header click on a track WITH clips is LOUD ══════════════
  await sel({ act: "clear" }).catch(() => {});
  const b5 = snap(await sel({}));
  const a5 = snap(await sel({ act: "clickTrack", trackId: tA, shift: true }));
  say(`\nD5 CONTROL  ⇧ on a 3-clip header`);
  say(`    before n=${b5.n} [${b5.ids}]   after n=${a5.n} [${a5.ids}]`);
  say(`    -> ${a5.n === 3 && !same(b5, a5)
        ? "VISIBLE (selection grew) — the instrument CAN see a change"
        : "*** INSTRUMENT FAULT: the control leg saw no change, so a null result below means nothing"}`);

  // ══ D3 — the FILED premise: ⇧ on a zero-clip header ════════════════════════
  const b3 = snap(await sel({}));
  const r3 = await sel({ act: "clickTrack", trackId: tB, shift: true });
  const a3 = snap(r3);
  say(`\nD3 FILED    ⇧ on a 0-clip header`);
  say(`    effect=${JSON.stringify(r3.effect ?? r3.trackClickEffect)} intent=${JSON.stringify(r3.intent)}`);
  say(`    before n=${b3.n} [${b3.ids}] focus=${b3.focus}   after n=${a3.n} [${a3.ids}] focus=${a3.focus}`);
  say(`    -> selection ${same(b3, a3) ? "UNCHANGED — nothing to draw" : "CHANGED (!!) — the filing is wrong"}`);

  // ══ D4 — but the click is NOT inert: it moves focus and retargets ⌘+ ═══════
  say(`\nD4 INVISIBLE CONSEQUENCE  (the same ⇧ click as D3)`);
  say(`    keyFocusNonce ${b3.nonce} -> ${a3.nonce}  ${a3.nonce > b3.nonce ? "BUMPED" : "not bumped"}`);
  say(`    activeEditorSurface ${b3.surface} -> ${a3.surface}`);
  // Hand the surface to the roll first, so the flip back is a real transition.
  // `engage pianoRoll` REFUSES unless a MIDI clip is open (the router would
  // resolve straight back to "arrange"), so the roll is opened first by
  // clicking a clip — which is also how a user reaches this state.
  const midi = (await req("project.overview", {})).tracks[0].clips;
  await sel({ act: "click", clipId: midi[0].id });
  await sel({ act: "engage", surface: "pianoRoll" });
  const bE = snap(await sel({}));
  const aE = snap(await sel({ act: "clickTrack", trackId: tB, shift: true }));
  say(`    after engaging the ROLL: surface ${bE.surface} -> ${aE.surface} on a ⇧ click on the EMPTY header`);
  say(`    -> ${aE.surface === "arrange" && bE.surface !== "arrange"
        ? "THE CLICK HAS A REAL CONSEQUENCE: it TOOK the zoom surface for the arrange, invisibly"
        : "no surface transition (surface was already arrange, or the click does not engage)"}`);

  // ══ D1 DISCRIMINATOR — plain click on a 0-clip header WITH an editor open ══
  // If this closes the piano roll it is a LARGE visible change, and the plain
  // branch is NOT uniformly silent. This single leg decides whether the
  // predicate is one branch or two.
  await sel({ act: "clear" }).catch(() => {});
  const clips = (await req("project.overview", {})).tracks[0].clips;
  await sel({ act: "click", clipId: clips[0].id });   // adopts a focus -> opens the roll
  const b1 = snap(await sel({}));
  const a1 = snap(await sel({ act: "clickTrack", trackId: tB }));  // PLAIN
  say(`\nD1 DISCRIMINATOR  PLAIN click on a 0-clip header while a clip is FOCUSED`);
  say(`    before n=${b1.n} focus=${b1.focus} open=${b1.open}`);
  say(`    after  n=${a1.n} focus=${a1.focus} open=${a1.open}`);
  say(`    -> ${!same(b1, a1)
        ? "VISIBLE: the plain branch CLEARED the selection/focus — this case is NOT silent"
        : "silent (!!) — then the predicate is broader than expected"}`);

  // ══ D2 — plain click on a 0-clip header with an ALREADY EMPTY selection ════
  await sel({ act: "clear" }).catch(() => {});
  const b2 = snap(await sel({}));
  const r2 = await sel({ act: "clickTrack", trackId: tB });         // PLAIN
  const a2 = snap(r2);
  say(`\nD2 WIDENING   PLAIN click on a 0-clip header with the selection ALREADY EMPTY`);
  say(`    effect=${JSON.stringify(r2.effect ?? r2.trackClickEffect)}`);
  say(`    before n=${b2.n} focus=${b2.focus} open=${b2.open}   after n=${a2.n} focus=${a2.focus} open=${a2.open}`);
  say(`    -> ${same(b2, a2)
        ? "EQUALLY SILENT, and its effect is NOT \"no-clips\" — the filing names one branch, the defect spans two"
        : "changed — the filing's scope is right"}`);

  // ══ D6 — the leg that shows "nothing changed" alone is TOO BROAD ═══════════
  await sel({ act: "clear" }).catch(() => {});
  await sel({ act: "clickTrack", trackId: tA });                     // select A's clips
  const b6 = snap(await sel({}));
  const a6 = snap(await sel({ act: "clickTrack", trackId: tA }));    // click A AGAIN
  say(`\nD6 TOO-BROAD  PLAIN click REPEATED on the SAME 3-clip header`);
  say(`    before n=${b6.n} [${b6.ids}]   after n=${a6.n} [${a6.ids}]`);
  say(`    -> ${same(b6, a6)
        ? "NOTHING CHANGED — so a bare \"did the selection change\" predicate would fire an\n"
          + "       acknowledgement HERE, where 3 blocks are visibly selected and the state MATCHES\n"
          + "       the intent. The predicate needs a SECOND term: the track has no clips."
        : "changed — a bare unchanged-predicate would be safe after all"}`);

  say("\n── probe complete ──");
} finally {
  teardown();
}
