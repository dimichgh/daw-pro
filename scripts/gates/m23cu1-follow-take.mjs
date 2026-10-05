// m23-cu-1 gate — DOES THE VIEW FOLLOW THE PLAYHEAD WHILE YOU RECORD?
//
// Reported: *"it would be good to ... autoposition on the area where the notes
// are placed and progress as user keeps playing."*
//
// ⭐⭐ **THE MECHANISM WAS ALREADY COMPLETE.** `ProjectStore.record()` sets
// `isPlaying` as well as `isRecording`, `followArrangeTick` runs off
// `transport.positionBeats` at ~30 Hz, and `FollowPlayheadModel`'s guard passes
// during a take. Measured on staging BEFORE any code changed: with the
// preference ON a 6 s take moved the arrange from offset 0 to 934.5 (1 page
// scroll); with it OFF, zero scrolls. The only thing between the user and the
// behaviour they asked for was `PanelLayoutModel.defaultFollowPlayhead == false`.
//
// The fix is an OR, not a default flip and not a save/restore override:
// `arrangeFollowEnabled = panelLayout.followPlayhead || transport.isRecording`,
// read at BOTH arrange call sites. Flipping the default would start every
// existing session scrolling — the surprise m23-c2 made this opt-in to avoid.
// Writing the preference for the take's duration would mutate a user setting
// nobody touched and strand it if the app died mid-take.
//
// ── THE ARMS ────────────────────────────────────────────────────────────────
//  1  preference OFF + PLAYBACK  → 0 scrolls        (the opt-in still holds)
//  2  preference OFF + a TAKE    → scrolls > 0      ⭐ the sub-item
//  3  the preference is STILL OFF afterwards        ⛔ no silent write
//  4  preference OFF + PLAYBACK again → 0 scrolls   (the take did not leak)
//  5  a manual scroll mid-take SUSPENDS follow      (one scroll policy, reused)
//  6  preference ON  + a TAKE    → scrolls > 0      (the pre-existing path is intact)
//
// ⭐⭐ **ARM 1 IS ARM 2'S NEGATIVE CONTROL AND ARM 2 IS ARM 1'S POSITIVE ONE.**
// A `scrolls > 0` reading means nothing unless this fixture can also produce a
// zero; a `scrolls === 0` reading means nothing unless it can produce a
// non-zero. Both directions are exercised on the SAME project and geometry, so
// the difference between them is the recording flag and nothing else.
//
// ⚠️ Geometry is asserted before anything is concluded from a scroll count: a
// content width that does not exceed the viewport makes `pageOffset` return nil
// forever, and every `scrolls === 0` in this file would pass for a reason that
// has nothing to do with follow.
//
// ⚠️ COUNT-IN IS PINNED TO 0 HERE, deliberately (the m23-cy interaction): with
// the new project default of one bar the playhead sits FROZEN at the record
// position for 2.0 s, so a take's first 2 s produce no position changes and
// therefore no follow ticks — correct behaviour (there is nothing to follow
// yet), but it would eat this gate's sample window and make a slow machine look
// like a broken feature. Count-in has its own gate.
//
// ⚠️ Sticky UserDefaults slots (`followPlayhead`, arrange `ppb`) are READ FIRST
// and RESTORED at the end — the m23-ei / m23-du(b) law. A restore to a value
// this gate itself wrote is not a restore.
//
// Staging: DAW_CONTROL_PORT=17695, pidfile-exact teardown. NEVER 17600.
import { sleep, buildOrAbort, startStaging, stopStaging, connect, verdict } from "./_staging.mjs";

const GATE = "m23cu1-follow-take";
buildOrAbort({ label: "building staging binary (m23cu1)…" });
startStaging({ gate: GATE });
const ws = await connect();

let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `cu${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 30000);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t);
      ws.removeEventListener("message", h);
      res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
const req = async (c, p) => {
  const m = await cmd(c, p);
  if (!m.ok) console.log(`  ⚠️ ${c} -> ${JSON.stringify(m.error)}`);
  return m.result ?? {};
};

let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + JSON.stringify(extra) : "")); }
};

// ⚠️ Priors BEFORE the fixture writes them.
const priorLayout = await req("debug.panelLayout", {});
const priorZoom = await req("debug.arrangeZoom", {});
console.log(`prior sticky slots: followPlayhead=${priorLayout.followPlayhead} arrangePPB=${priorZoom.ppb}`);

const PPB = 100, CLIP_BEATS = 128, ROLL_MS = 6000;
// Where arm 5 drags the arrange to. Inside the scroller's ceiling
// (contentWidth 13600 − viewportWidth 1090 = 12510) so the value is not
// clamped on the way in, and far from any offset follow would choose.
const DRAG_TO = 11000;

/** A wide arrange with one long clip and one armed instrument track. */
async function buildFixture(followPreference) {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const tr = await req("track.add", { name: "m23cu1 Follow", kind: "instrument" });
  const trackId = tr.id ?? tr.track?.id;
  const notes = [];
  for (let b = 0; b < CLIP_BEATS; b += 4) {
    notes.push({ pitch: 60, startBeat: b, lengthBeats: 0.9, velocity: 100 });
  }
  await req("clip.addMIDI", { trackId, atBeat: 0, lengthBeats: CLIP_BEATS, notes });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.panelLayout", { followPlayhead: followPreference });
  await req("track.setArm", { trackId, armed: true });
  await req("transport.setMetronome", { enabled: false, countInBars: 0 });  // see header
  return trackId;
}

/** Rolls the transport for ROLL_MS and returns the follow runtime at the end. */
async function roll(kind) {
  await req("transport.seek", { beats: 0 });
  await req("debug.followPlayhead", { rearm: true, resetCounters: true });
  const before = await req("debug.followPlayhead", {});
  await req(kind === "record" ? "transport.record" : "transport.play", {});
  await sleep(ROLL_MS);
  const during = await req("debug.followPlayhead", {});
  await req("transport.stop", {});
  await sleep(800);
  console.log(`  [measured] ${kind}: enabled=${during.enabled} effective=${during.enabledEffective} ` +
    `autoByTake=${during.autoEngagedByTake} isRecording=${during.isRecording} ` +
    `scrolls=${during.arrange.scrolls} offset=${during.arrange.offset} ` +
    `suspended=${during.arrange.suspended}`);
  return { before, during };
}

// ── GEOMETRY FIRST — without this every zero below is meaningless ───────────
console.log("\n=== FIXTURE + GEOMETRY ===");
await buildFixture(false);
const geo = await req("debug.followPlayhead", {});
console.log(`  arrange viewport=${geo.arrange.viewportWidth} content=${geo.arrange.contentWidth}`);
ck("⭐ the arrange has somewhere to scroll (content ≫ viewport) — else every scroll count is vacuous",
   geo.arrange.contentWidth > geo.arrange.viewportWidth * 3,
   { content: geo.arrange.contentWidth, viewport: geo.arrange.viewportWidth });
ck("the persisted preference starts OFF for arms 1-5", geo.enabled === false, geo.enabled);

// ── ARM 1: preference OFF + PLAYBACK → no scrolling ─────────────────────────
console.log("\n=== ARM 1: preference OFF + PLAYBACK (the opt-in still holds) ===");
const a1 = await roll("play");
ck("1: plain playback with follow off does NOT scroll", a1.during.arrange.scrolls === 0, a1.during.arrange);
ck("1: and the effective flag is off during playback",
   a1.during.enabledEffective === false, a1.during.enabledEffective);

// ── ARM 2: preference OFF + a TAKE → it follows ─────────────────────────────
console.log("\n=== ARM 2: preference OFF + a TAKE (the sub-item) ===");
const a2 = await roll("record");
ck("⭐⭐ 2: a TAKE follows the playhead even with the preference off",
   a2.during.arrange.scrolls > 0, a2.during.arrange);
ck("⭐ 2: and the view actually MOVED — a scroll count without an offset change would be a lie",
   a2.during.arrange.offset > 0, a2.during.arrange.offset);
ck("2: the app reports the follow as auto-engaged by the take, not as a preference",
   a2.during.autoEngagedByTake === true && a2.during.enabled === false,
   { autoByTake: a2.during.autoEngagedByTake, enabled: a2.during.enabled });

// ── ARM 3: THE PREFERENCE WAS NOT WRITTEN ───────────────────────────────────
console.log("\n=== ARM 3: the take must not have written the preference ===");
const layoutAfter = await req("debug.panelLayout", {});
ck("⛔ 3: the persisted followPlayhead is STILL false — a take never writes a user preference",
   layoutAfter.followPlayhead === false, layoutAfter.followPlayhead);

// ── ARM 4: NO LEAK — playback after a take is back to not following ─────────
console.log("\n=== ARM 4: playback AFTER the take does not keep following ===");
const a4 = await roll("play");
ck("4: the auto-engage did not leak into ordinary playback",
   a4.during.arrange.scrolls === 0, a4.during.arrange);

// ── ARM 5: THE EXISTING MANUAL-SCROLL POLICY STILL OWNS THE SCROLL ──────────
console.log("\n=== ARM 5: a manual scroll mid-take suspends follow (one policy, reused) ===");
await req("transport.seek", { beats: 0 });
await req("debug.followPlayhead", { rearm: true, resetCounters: true });
await req("transport.record", {});
await sleep(2500);
const beforeDrag = await req("debug.followPlayhead", {});
// A simulated POINTER scroll — the same seam a real drag reaches the detector on.
await req("debug.followPlayhead", { simulateUserScroll: DRAG_TO, surface: "arrange" });
await sleep(1500);
const afterDrag = await req("debug.followPlayhead", {});
await req("transport.stop", {});
await sleep(800);
console.log(`  [measured] before drag scrolls=${beforeDrag.arrange.scrolls} suspended=${beforeDrag.arrange.suspended}; ` +
  `after drag scrolls=${afterDrag.arrange.scrolls} suspended=${afterDrag.arrange.suspended}`);
ck("5a: follow WAS driving the take before the drag (positive control for 5b)",
   beforeDrag.arrange.scrolls > 0, beforeDrag.arrange);
ck("⭐ 5b: a manual scroll during the take SUSPENDS follow — the existing policy, not a second one",
   afterDrag.arrange.suspended === true, afterDrag.arrange);
// ⭐ THE STRONG FORM: assert where the VIEW IS, not how many scrolls were
// counted. A suspended follow leaves the user's scroll position alone; an
// unsuspended one yanks the viewport back toward the playhead within one ~30 Hz
// tick. Comparing offsets is a fact about the surface; comparing counters over a
// 1.5 s window is an assumption about when the next page boundary falls.
ck("⭐ 5c: the view STAYS where the user dragged it — follow does not yank it back",
   Math.abs(afterDrag.arrange.offset - DRAG_TO) < 1,
   { draggedTo: DRAG_TO, offsetNow: afterDrag.arrange.offset });
// The stand-down must not outlive the take: the next transport start re-arms.
await req("transport.seek", { beats: 0 });
await req("transport.record", {});
await sleep(600);
const rearmed = await req("debug.followPlayhead", {});
await req("transport.stop", {});
await sleep(800);
ck("⭐ 5d: the NEXT take re-arms follow — a mid-take stand-down never outlives its take",
   rearmed.arrange.suspended === false, rearmed.arrange);

// ── ARM 6: THE PRE-EXISTING PREFERENCE PATH IS UNTOUCHED ────────────────────
console.log("\n=== ARM 6: preference ON + a take still follows (m23-c2 path intact) ===");
await buildFixture(true);
const a6 = await roll("record");
ck("6: with the preference ON a take follows exactly as before",
   a6.during.arrange.scrolls > 0, a6.during.arrange);
ck("6: and it is NOT reported as auto-engaged — the preference is the reason",
   a6.during.autoEngagedByTake === false && a6.during.enabled === true,
   { autoByTake: a6.during.autoEngagedByTake, enabled: a6.during.enabled });

// ── RESTORE the sticky slots ────────────────────────────────────────────────
await req("debug.panelLayout", { followPlayhead: priorLayout.followPlayhead });
await req("debug.arrangeZoom", { ppb: priorZoom.ppb });
const restored = await req("debug.panelLayout", {});
const restoredZoom = await req("debug.arrangeZoom", {});
console.log(`\nrestored sticky slots: followPlayhead=${restored.followPlayhead} arrangePPB=${restoredZoom.ppb}`);
ck("sticky followPlayhead restored to the value found on arrival",
   restored.followPlayhead === priorLayout.followPlayhead,
   { prior: priorLayout.followPlayhead, now: restored.followPlayhead });
ck("sticky arrange ppb restored to the value found on arrival",
   restoredZoom.ppb === priorZoom.ppb, { prior: priorZoom.ppb, now: restoredZoom.ppb });

console.log(
  `\n[measured] m23-cu-1: playback/off=${a1.during.arrange.scrolls} scrolls, ` +
  `TAKE/off=${a2.during.arrange.scrolls} scrolls (offset ${a2.during.arrange.offset}), ` +
  `playback-after/off=${a4.during.arrange.scrolls}, TAKE/on=${a6.during.arrange.scrolls}.`
);

stopStaging(GATE);
verdict({ ran: pass + fail, failed: fail });
