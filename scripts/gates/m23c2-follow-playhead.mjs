// m23-c2 GATE — follow the playhead (arrange lanes + piano-roll bands).
//
// Everything here is measured under REAL PLAYBACK, never seeks. A seek forces a
// state invalidation, so a seek-driven gate cannot tell a live surface from a
// frozen one (the m23-c1 law); the transport is started and the surfaces are
// sampled while it rolls.
//
// Every measurement is a CROP of the surface under test, with its real pixel
// dimensions asserted before its numbers are trusted — whole-window hashing has
// produced false negatives on the piano roll twice, because the arrange playhead
// moves regardless of what the roll does.
//
// The playhead itself is the probe: DAWTheme.playback (0x3EE6FF) is the only
// strongly cyan thing in the windows below (the roll's grid window is a
// note-free pitch band, the arrange's is a ruler strip clear of the clip), so
// "is the playhead in frame" is a pixel fact, not an inference from the app's
// own numbers. Those numbers are read too, and the two are cross-checked.
//
// >>> THIS GATE NOW BUILDS AND LAUNCHES ITS OWN APP (m23-ac-3e-3) <<<
//
// It was the corpus's LAST class 2 — it launched a binary but never built one,
// so every run measured whatever `.build/debug/DAWApp` happened to contain. It
// was also a HYBRID: it connected FIRST and only spawned at Leg 6, because that
// leg deliberately kills and respawns staging to prove the follow preference
// survives a real process restart. That relaunch is the POINT of Leg 6 and is
// preserved exactly; only the lifecycle around it moved to the harness.
//
// TWO PROVENANCE GAPS WERE CLOSED, NOT ONE — the same pair m23c1 had (m23-ac-3b-3):
//   1. the APP was never built, and
//   2. the cyan-column PROBE was compiled by hand "once" and then trusted
//      forever. `/tmp/m23c2-probe` on this machine was dated Jul 26 and would
//      have been used silently. It is now rebuilt every run, like the app, for
//      the same reason: a stale probe measures the previous build's pixels.
//      (Swift binaries are NOT byte-reproducible — compare FUNCTION, not bytes.)
//
// >>> THE ENV OVERRIDES THAT COULD BREAK TEARDOWN ARE GONE <<<
// `M23C2_PIDFILE`, `M23C2_BINARY` and `M23C2_REPO` were deleted. The pidfile in
// particular is the single file the whole teardown chain depends on: startStaging
// writes pid A to it, Leg 6 kills A and writes its replacement B to it, and
// stopStaging/armTeardown re-read it to kill B. A stale `M23C2_PIDFILE` export
// would have broken link 2 silently and left B alive on 17695 — the same shape as
// the `PORT` hazard swept at m23-bi. Binary and repo root now have ONE home in
// the harness rather than a second spelling here.
//
// Staging port 17695 only — 17600 is the user's live app (assertStagingPort).
// Usage: node scripts/gates/m23c2-follow-playhead.mjs
// Exit codes: 0 = all checks pass; 1 = a check failed; 2 = the 900 s watchdog.
import fs from "fs";
import { execFileSync, spawn, spawnSync } from "child_process";
import {
  ROOT, STAGING_PORT, DEFAULT_BINARY, PROFILE_ROOT_ENV,
  buildOrAbort, startStaging, stopStaging, pidfilePath, releaseSessionLock,
  stagingProfileRoot, stagingSessionLockPath, panelDensityGuard, verdict,
  stagingBinaryAlias,
} from "./_staging.mjs";

const GATE = "m23c2";                     // names the pidfile + staging out dir
const PORT = STAGING_PORT;
const OUT = process.env.M23C2_OUT || "/tmp/m23c2";
const PROBE = process.env.M23C2_PROBE || "/tmp/m23c2-probe";
// ONE home for each of these — the harness owns them; this file no longer
// carries a second spelling that could drift from it.
const PIDFILE = pidfilePath(GATE);
const BINARY = DEFAULT_BINARY;
const REPO = ROOT;
fs.mkdirSync(OUT, { recursive: true });
let guard = null;   // m23-ej-2: `let` — assigned after connect, read by the killer below
const killer = setTimeout(async () => {
  console.error("TIMEOUT");
  await guard?.restore("timeout");
  process.exit(2);
}, 900_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── crop windows, in CAPTURE pixels (window 1400x1000 logical @2x = 2800x2000)
// Chosen from a real capture (see the recon in the item record), not guessed.
// A-RULER  : arrange ruler strip, clear of the clip row and of the lanes' own
//            leading-edge highlight → the playhead is the ONLY cyan in it.
// A-LANE   : the arrange clip row, from x=800 so the clip's cyan label is out —
//            an independent read of the same playhead, which is what proves the
//            ruler and the lanes scroll in lockstep.
// R-GRID   : a note-free pitch band of the roll's grid (all fixture notes are C4)
//            → again, only the playhead.
// R-NOTES  : the C4 row — note bodies, for the roll's own scroll ground truth.
// R-VEL    : the velocity lane, same x window as the grid ones, so the two bands'
//            reported runs are DIRECTLY comparable (the m23-c1 idiom).
// R-GUTTER : the keyboard gutter. It scrolls VERTICALLY with the grid and never
//            horizontally, so its bytes are the non-followed axis's witness.
// R-CTRL   : the controller strip's value canvas (chip row excluded). This band
//            carries NO playhead (m23-c1), so the playhead cannot be its probe —
//            the fixture's CC lane alternates 8/119 every 4 beats and each point
//            draws one full-height RISER, which after the median subtraction is
//            the only thing in the column profile (a flat hold-segment is ~3 px
//            of ink down an 80 px column and reads as background).
// ⚠️ m23-bk: RGRID.y and RNOTES.y below are PLACEHOLDERS, overwritten by the
// CALIBRATION block right after the fixture opens. They used to be hardcoded
// and were PROVEN mis-aimed: notes render in `DAWTheme.playback` — the SAME
// cyan the playhead probe hunts for (`PianoRollView.noteColor`) — so
// RGRID.y=1350 landed ON the pitch-60 note row (rasterized 1375..1443,
// measured) instead of a note-free one, and RNOTES.y=1275 was ~100px off
// that same row. Both are now MEASURED every run: `debug.explainFrames`
// gives `pianoRollGrid`'s rasterized top (the m23-ag idiom — see
// `m23c1-offclip-cue.mjs:237-273`, the working reference), then a
// row-height scan inside that panel (rowHeight is PINNED to 34 by
// buildFixture, so its capture-space size is a known constant, not a guess)
// finds which row actually carries note ink and picks a nearby row that
// carries none. RVEL/RCTRL were measured to already sit correctly inside
// their panels and are left as hardcoded constants, verified (not derived)
// at calibration time — see the CALIBRATION checks below.
const W = {
  ARULER:  { x: 620, y: 280,  w: 2150, h: 80,  thr: 20 },
  ALANE:   { x: 800, y: 380,  w: 1970, h: 100, thr: 8 },
  RGRID:   { x: 140, y: undefined, w: 2635, h: 150, thr: 20 },
  RNOTES:  { x: 140, y: undefined, w: 2635, h: 34,  thr: 20 },
  RVEL:    { x: 140, y: 1570, w: 2635, h: 100, thr: 20 },
  RGUTTER: { x: 30,  y: 840,  w: 95,   h: 680, thr: 20 },
  RCTRL:   { x: 140, y: 1745, w: 2635, h: 80,  thr: 20 },
};
// ── m23-gu: two sub-windows OF THE RGUTTER CROP, in CROP-LOCAL pixels ──────
// These index into `crop-<tag>-<i>-rgutter.png` — the file the identity leg
// hashes — NOT into the 2800x2000 capture. That is deliberate and is the whole
// mechanism of the item; the reasoning is at the INK PIN block in Leg 1.
// INK   = the editor header's cyan `pianokeys` glyph  (capture-absolute 40,971)
// BLANK = flat background, same size                   (capture-absolute 40,860)
//
// ⚠️ `RGUTTER_INK.y` WAS 110 AND IS NOW 131 — ORCHESTRATOR CORRECTION AT THE
// m23-gu CLOSE, 2026-08-11. 110 PASSED, AND PASSED BY ONE PIXEL. A fine sweep
// of this exact window down this exact crop puts the HOT BAND (peak >= thr 20,
// i.e. hotColumns >= 1) at dy 110..152, with dy=109 reading peak 19.95 — under
// the threshold by 0.05. So the shipped window sat ON the cliff edge: it read
// 24.34, only 4.34 clear of thr, and a ONE-PIXEL upward slip of the content
// would have reddened it. dy=131 is the band's centre: peak 56.89 (2.8x thr),
// 16 hot columns, margin 22 px up and 25 px down.
//   MEASURED, my own probe, same crop:  dy 100/104 -> 0.00 | 106 -> 6.79 |
//   108 -> 15.56 | 109 -> 19.95 (0 hot) | 110 -> 24.34 (13 hot) | 115 -> 46.28 |
//   120..145 -> ~55-57 (plateau) | 150 -> 32.75 | 152 -> 29.33 | 156 -> 19.77
//   (0 hot) | 160 -> 10.22 | 200 -> 0.00.
// ⭐ THE LESSON IS m23-gs's, ON A NEW SURFACE: a green leg one pixel from red is
// measuring the renderer, not the app. A pin's THRESHOLD MARGIN is part of the
// pin, and "it passed" never establishes it — only a sweep does.
const RGUTTER_INK   = { x: 10, y: 131, w: 45, h: 40, thr: 20 };
const RGUTTER_BLANK = { x: 10, y: 20,  w: 45, h: 40, thr: 20 };
// Content-space origins of the two scrollers in CAPTURE pixels, and the 2x scale.
// Used only to cross-check the pixel reading against the app's own numbers.
const ARRANGE_X0 = 597, ROLL_X0 = 133, SCALE = 2;

function probe(png, tag, win) {
  const out = `${OUT}/crop-${tag}.png`;
  const raw = execFileSync(PROBE, [png, out, String(win.x), String(win.y),
                                   String(win.w), String(win.h), String(win.thr)]).toString();
  const kv = Object.fromEntries(raw.trim().split("\n").map((l) => l.split("=")));
  const expect = `${win.w}x${win.h}`;
  // HARD dimension assertion: a silently-failed crop is the known false-negative mode.
  if (kv.dims !== expect) throw new Error(`crop ${tag}: dims ${kv.dims} != ${expect}`);
  kv.runList = kv.runs === "-" ? [] : kv.runs.split(",").map((r) => r.split("-").map(Number));
  kv.path = out;
  return kv;
}
// The playhead's x in a window that contains nothing else cyan.
const lineX = (m) => m.runList.length ? (m.runList[0][0] + m.runList[0][1]) / 2 : null;
// Does ANY run in this window cover x? (the velocity lane also carries stems, and
// a stem may merge with the playhead when the transport crosses a note.)
const covers = (m, x, tol = 3) =>
  x != null && m.runList.some(([s, e]) => x >= s - tol && x <= e + tol);

// ── m23-gt: RNOTES's run list is `note starts ∪ {playhead}` — FILTER BY WIDTH ──
//
// m23-bk correctly re-aimed RNOTES onto the pitch-60 note row. That row also
// carries the PLAYHEAD, which spans every pitch row and is drawn in the SAME
// `DAWTheme.playback` cyan as the notes (`PianoRollView.noteColor`), so whenever
// the playhead is inside this x-window it contributes one extra "start" that is
// not a note. Both consumers below are MEMBERSHIP predicates
// (`risers.every(c => starts.some(s => |c - s| <= 3))`), so a superset cannot
// redden them — but it makes them STRICTLY EASIER to satisfy: a riser landing on
// the playhead would pass without sitting on any note. This is a rigour fix, not
// a live red.
//
// WHY WIDTH AND NOT THE ALTERNATIVES. Two other discriminators were measured
// against real artefacts and REJECTED:
//
//   (a) "drop runs touching a crop edge" — MEASURABLY WRONG, it turns this leg
//       FALSELY RED. In the paged capture the run `2663-2774` touches the RIGHT
//       edge and IS a real note (beat 24) truncated by the window; the CC riser
//       measured at 2661.5 depends on its start at 2663. Dropping edge-touching
//       runs deletes a note start a real riser needs.
//   (b) "off-lattice ⇒ playhead" — the 800px (4 beats × 100 ppb × 2×) lattice
//       MOVES run-to-run because `rollOffset` varies; only the playhead sits
//       still. A lattice test is a second model to keep in sync with the app's,
//       for no gain over a property that is directly visible in the pixels.
//
// THE TWO BOUNDS, MEASURED BY ME (18 crops: the 16 sampled `*-rnotes` of one
// full run plus the two Leg-5 captures), NOT estimated:
//   • playhead runs — span 2 EVERY time it appears separately, 11/11 occurrences
//     (`514-516`, `318-320`, `1069-1071`, `1820-1822`, `322-324`, `1103-1105`,
//     `1850-1852`, `339-341`, `1120-1122`, `1901-1903`, and 8 more at span 2 on
//     the note-free RGRID band).
//   • real note runs — span 177 unclipped (`lengthBeats 0.9` × 100 ppb × 2×);
//     span 170 when truncated by the LEFT crop edge (`140-310` at offset 0);
//     span 115 and span 111 when truncated by the RIGHT edge (`2519-2634`,
//     `2523-2634`). **111 is the narrowest real note ever measured here.**
//
// So the constant must satisfy `2 < PLAYHEAD_MAX_SPAN <= 110`, and it is set to
// 8: four times the widest playhead ever measured, and ~14× below the narrowest
// real note ever measured. Margin on both sides is more than an order of
// magnitude, which is why a round number is honest here.
//
// ⚠️ WHY 8 AND NOT A SHARED CONSTANT WITH THE RGRID LEG BELOW. The L1 calibration
// leg (`rGrid's matched run is a thin ~2px stroke`) tests the SAME quantity
// (`runList[0][1] - runList[0][0]`) with the SAME literal 8 — deliberately, and
// deliberately NOT through this constant. That leg is the WITNESS that the
// playhead is thin; this filter is the CONSUMER of that fact. If the two shared
// one mutable constant, raising this threshold would silently WEAKEN the witness
// and the guarantee would evaporate without a single red. Kept apart, the
// invariant is checkable by reading: as long as `PLAYHEAD_MAX_SPAN >= 8`, the
// witness's own bound proves every playhead it certifies is dropped here.
//
// ⚠️ THE RESIDUAL, STATED RATHER THAN HIDDEN: a note truncated to a span of 8 or
// less would ALSO be dropped, shrinking `starts` and making the membership
// predicate strictly HARDER — the opposite failure, and the quieter one. It is
// reachable only if a note start lands within ~9 px of the right crop edge (a
// ~9/800 = ~1% slice of the offset phase; the observed phase parks the rightmost
// start near 2663, ~111 px clear). It is NOT prevented here — it is made LOUD by
// the anti-vacuity legs in Leg 5, which assert the filtered starts still
// outnumber the risers they have to explain, and by every detail string below
// carrying the RAW runs next to the filtered ones.
//
// ⚠️ AND WHY THE RAW RUNS ARE IN THE DETAIL STRINGS: RNOTES and RCTRL run at the
// same `thr: 20` but over 34px and 80px bands, and their ink margins are NOT
// comparable — MEASURED by sweeping the threshold on one paged capture, the note
// BODIES survive thr=30 and are gone by thr=40 (~1.5–2× headroom), while the CC
// risers survive thr=100 and are gone by thr=120 (~5×). So a note can in
// ⚠️ CORRECTED 2026-08-11 (m23-gy) — "gone by thr=40" IS WRONG, and this comment
// is where the roadmap item inherited it from. Re-measured across 19 captures of
// a full run rather than one paged capture, the sweep the m23-gy legs now PRINT
// on every run is: thr 20/25/30/33/35 → 19/19, thr 38 → 7/19, thr 40 → 7/19,
// thr 50 and above → 0/19. So note bodies still survive at 40 and collapse is
// complete only by 50 — the headroom is ~2.5×, not ~1.5–2×, and the 38–50 band
// is UNSTABLE (7/19 is neither survival nor collapse) rather than a clean edge.
// The qualitative point below is unaffected and is why this was worth measuring:
// RCTRL's margin is still far larger than RNOTES's, so the trap is real.
// ⭐ The numbers above are no longer a remembered one-off — the GY legs re-derive
// them every run, so this comment cannot rot again without a red beside it.
// principle be lost to THRESHOLD while its riser is still detected, which would
// redden the anti-vacuity leg and look exactly like an over-matching filter.
// Raw-vs-filtered in the detail separates the two instantly: a threshold loss is
// missing from the RAW list too, a filter drop is present in RAW and absent from
// the filtered starts.
const PLAYHEAD_MAX_SPAN = 8;
const runSpan = ([a, b]) => b - a;
const noteRuns = (m) => m.runList.filter((r) => runSpan(r) > PLAYHEAD_MAX_SPAN);
const thinRuns = (m) => m.runList.filter((r) => runSpan(r) <= PLAYHEAD_MAX_SPAN);
const noteStarts = (m) => noteRuns(m).map(([a]) => a);
const runText = (rs) => (rs.length ? rs.map(([a, b]) => `${a}-${b}(w${b - a + 1})`).join(",") : "-");

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("x")); });
      let nextId = 1; const pending = new Map();
      ws.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
        if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        else e.resolve(m.result ?? m);
      };
      const req = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

// ── lifecycle ─────────────────────────────────────────────────────────────
// Build the app, then rebuild the probe, then launch — in that order, so a
// compile failure on either side costs nothing and leaves nothing running.
buildOrAbort({ label: "building staging binary (m23c2)…" });

// Rebuild the cyan-column probe every run, for the same reason the app is built
// every run: a stale probe measures the previous build's idea of the pixels.
// This is m23c1's pattern and the SAME probe source — the two gates share it.
// Swift binaries are NOT byte-reproducible, so this is compared by FUNCTION
// (the dims assertion in probe()), never by bytes.
const probeSrc = "scripts/probes/m23c1-cyan-column-probe.swift";
const probeBuild = spawnSync("swiftc", ["-O", "-o", PROBE, probeSrc], {
  cwd: REPO, encoding: "utf8",
});
if (probeBuild.status !== 0) {
  console.log("ABORT: probe compile failed — every pixel leg would measure a stale probe");
  console.log((probeBuild.stderr || "").trim().split("\n").slice(-12).join("\n"));
  process.exit(2);
}
console.log(`# probe rebuilt: ${PROBE} <- ${probeSrc}`);

// startStaging clears a stale pidfile before launching and arms the teardown
// (m23-bd), which re-READS the pidfile on exit — that is what makes Leg 6's
// kill-and-respawn safe, provided Leg 6 writes its new pid to the same file.
const staged = startStaging({ gate: GATE });
const firstPid = staged.pid;
// The harness owns the pidfile path; assert our copy agrees rather than trusting
// two spellings to stay equal. Link 1 of the three-link teardown chain.
if (staged.pidfile !== PIDFILE) {
  console.log(`ABORT: pidfile disagreement — harness ${staged.pidfile} vs gate ${PIDFILE}`);
  process.exit(2);
}
console.log(`# staging pid ${firstPid} (pidfile ${PIDFILE})`);

let { ws, req } = await connect();
// m23-ej-2: NOT `panelDensityGuard(req)` — `req` is a reassigned `let` (rebound
// at Leg 6's relaunch below, same hazard `restoreZoomSlots` already documents),
// so the guard must read it through a wrapper that resolves `req` at CALL time,
// not the function value `req` happened to hold when this line ran. A guard
// bound to the pre-relaunch closure would try to restore over the OLD (by then
// closed) socket and silently never reach the relaunched process B.
guard = panelDensityGuard((command, params) => req(command, params));
const checks = [];
// m23-bl: THIRD check outcome — UNKNOWN — for a check whose CONCLUSION is
// invalidated by a precondition that already failed (Leg 6's relaunch race;
// see the comment block above Leg 6 for which four checks this applies to
// and why). Declared via an optional 4th `opts` arg so the other 61 call
// sites are untouched:
//   - `{ id: "<string>" }`   names this check so a later one can depend on it.
//   - `{ requires: "<id>" }` makes this check UNKNOWN — not PASS, not FAIL —
//                            unless the named check ran AND passed. `ok` is
//                            still evaluated by the caller (JS evaluates call
//                            arguments eagerly) but is NEVER read into the
//                            outcome once the dependency is not a PASS: that
//                            is the entire point — this check's own boolean
//                            cannot be trusted once its precondition is gone.
// `requires:` naming an id that is never registered ANYWHERE in this run is a
// typo, not "no dependency" — `validateRequiresOrThrow()` below THROWS for
// that case (not a console warning), checked once every check has run.
const checkById = new Map();          // id -> check record, for `requires` lookups
const pendingRequires = [];           // { requires, record } — validated once, at the end
const check = (name, ok, detail, opts = {}) => {
  const { id, requires } = opts;
  const record = { name, ok, detail, outcome: undefined, id, requires };
  if (requires !== undefined) {
    // `requires` accepts a STRING or an ARRAY of ids (m23-bl sweep). A claim can
    // rest on more than one precondition — L6's survival leg needs BOTH "the old
    // process is gone" AND "follow was ON before the relaunch", and marking only
    // one of them would leave the other's failure still able to certify a
    // conclusion it cannot support. ALL named preconditions must have PASSED.
    const ids = Array.isArray(requires) ? requires : [requires];
    const deps = ids.map((r) => ({ r, dep: checkById.get(r) }));
    const bad = deps.filter(({ dep }) => !dep || dep.outcome !== "PASS");
    record.outcome = bad.length === 0 ? (ok ? "PASS" : "FAIL") : "UNKNOWN";
    if (record.outcome === "UNKNOWN") {
      const why = bad
        .map(({ r, dep }) => dep
          ? `precondition "${r}" ${dep.outcome} (${dep.detail})`
          : `precondition "${r}" has not run/registered yet`)
        .join("; AND ");
      record.detail = `UNKNOWN — invalidated by ${why}; this check's own condition ` +
        `was NOT evaluated into a verdict. Original claim: ${detail}`;
    }
    for (const r of ids) pendingRequires.push({ requires: r, record });
  } else {
    record.outcome = ok ? "PASS" : "FAIL";
  }
  checks.push(record);
  if (id !== undefined) checkById.set(id, record);
  if (record.outcome === "FAIL") console.log(`   !! ${name} — ${record.detail}`);
};
// Validates every `requires:` used anywhere in this run names a check id that
// was actually registered — called once, after the last check runs (see the
// call site at the end of Leg 6). A typo here must be loud: silently reading
// as "no dependency" would let this whole mechanism degrade back into the
// exact bug it exists to fix.
function validateRequiresOrThrow() {
  for (const { requires, record } of pendingRequires) {
    if (!checkById.has(requires)) {
      throw new Error(
        `check("${record.name}", ..., { requires: "${requires}" }): "${requires}" does not ` +
        `name any registered check id anywhere in this run — a typo'd dependency silently ` +
        `degrading to "no dependency" is the exact bug class this mechanism exists to fix.`
      );
    }
  }
}

// ── fixture ───────────────────────────────────────────────────────────────
const PPB = 100, CLIP_BEATS = 128, CLIP2_AT = 200;
async function buildFixture() {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  await guard.set("pianoRoll", "pro");
  const tr = await req("track.add", { name: "Follow Probe", kind: "instrument" });
  const trackId = tr.id ?? tr.track?.id;
  // Notes on every 4th beat at ONE pitch: leaves note-free pitch bands where the
  // playhead is the only cyan, and sparse note x's the two bands can be compared on.
  const notes = [];
  for (let b = 0; b < CLIP_BEATS; b += 4) {
    notes.push({ pitch: 60, startBeat: b, lengthBeats: 0.9, velocity: 100 });
  }
  const c1 = await req("clip.addMIDI", { trackId, atBeat: 0, lengthBeats: CLIP_BEATS, notes });
  // A SECOND long clip far down the timeline: the off-clip arm needs an edited clip
  // that is (a) scrollable and (b) not where the transport is.
  const c2 = await req("clip.addMIDI", { trackId, atBeat: CLIP2_AT, lengthBeats: CLIP_BEATS, notes });
  // A real CONTROLLER LANE on clip 1 — without it the CTRL band draws nothing and
  // its follow is unobservable. Points share the notes' beats so the two bands'
  // ink is DIRECTLY comparable; alternating values make each point a riser.
  const ccPoints = [];
  for (let b = 0; b < CLIP_BEATS; b += 4) ccPoints.push({ beat: b, value: (b / 4) % 2 === 0 ? 8 : 119 });
  await req("clip.setControllerLane", { clipId: c1.id ?? c1.clip?.id, type: "cc", controller: 1, points: ccPoints });
  await req("debug.arrangeZoom", { ppb: PPB });
  // rowHeight is PINNED, not inherited: every ALANE crop y below was measured at
  // 34 (the shipped default), and the lane rows are what put the lane band there.
  // Inheriting it from UserDefaults would silently slide the window off the lane
  // while the dimension assertion still passed — the m23-b "the variable never
  // reached the surface" failure, in reverse.
  await req("debug.panelLayout", { pianoRollPPB: PPB, rowHeight: 34 });
  return { trackId, clipId: c1.id ?? c1.clip?.id, clip2Id: c2.id ?? c2.clip?.id };
}
// ── m23-ei: this gate is the pianoRollPPB leaker ──────────────────────────────
// `buildFixture` pins BOTH zoom slots to PPB (100) and the gate restored NEITHER:
// `debug.arrangeZoom {ppb}` and `debug.panelLayout {pianoRollPPB, rowHeight}` are
// sticky UserDefaults in the shared `DAWApp` domain, so every run left the corpus
// at 100 against app defaults of 32 (roll) and 16 (arrange). Measured ambient was
// exactly 100, which is this constant, not a zoom ladder — the item was filed as
// "zoom-accumulated" and that was wrong.
//
// ⚠️ The pins THEMSELVES are correct and must stay: every ALANE crop y below was
// measured at these values, and inheriting them would slide the window off the
// lane while the dimension assertion still passed. The defect is the missing
// RESTORE, exactly as m23-du(b) found for m22g.
//
// ⚠️ Read the priors BEFORE `buildFixture()` writes them — after is too late, and
// a restore to a value the gate itself set is not a restore.
const priorRollLayout = await req("debug.panelLayout", {});
const priorArrange = await req("debug.arrangeZoom", {});
console.log(`prior zoom slots: pianoRollPPB=${priorRollLayout.pianoRollPPB} `
  + `rowHeight=${priorRollLayout.rowHeight} arrangePPB=${priorArrange.ppb} `
  + `arrangeRowStep=${priorArrange.rowStep}`);

let zoomRestored = false;
async function restoreZoomSlots(reason) {
  if (zoomRestored) return;            // idempotent: normal path AND handlers call it
  zoomRestored = true;
  try {
    // `req` is a reassigned `let` (rebound at the relaunch below), so this always
    // speaks to the CURRENT staging process — including the relaunched one.
    await req("debug.panelLayout", {
      pianoRollPPB: priorRollLayout.pianoRollPPB, rowHeight: priorRollLayout.rowHeight,
    });
    await req("debug.arrangeZoom", { ppb: priorArrange.ppb, rowStep: priorArrange.rowStep });
    const back = await req("debug.panelLayout", {});
    const backA = await req("debug.arrangeZoom", {});
    console.log(`  zoom slots restored (${reason}): pianoRollPPB=${back.pianoRollPPB} `
      + `rowHeight=${back.rowHeight} arrangePPB=${backA.ppb}`);
  } catch (e) {
    // Loud: a failed restore is what poisons the NEXT gate, and it must not hide.
    console.error(`  ⚠️ ZOOM SLOT RESTORE FAILED (${reason}) — LEAKED: ${e?.message ?? e}`);
  }
}
for (const sig of ["unhandledRejection", "uncaughtException"]) {
  process.on(sig, async (err) => {
    console.error(`\n${sig.toUpperCase()} — restoring zoom slots + panel density before exit:`, err);
    await restoreZoomSlots(sig);
    await guard?.restore(sig);
    stopStaging(GATE);
    process.exit(3);
  });
}

const { clipId, clip2Id } = await buildFixture();
console.log(`fixture: clip1 @0 len ${CLIP_BEATS}, clip2 @${CLIP2_AT} len ${CLIP_BEATS}, ${PPB} pt/beat`);

// Open the editor once; later captures keep it open without re-selecting (a
// re-select would be an edit-state change in the middle of a measurement).
await req("debug.captureUI", { path: `${OUT}/open-editor.png`, selectClip: clipId });

// ── m23-bk CALIBRATION — derive RGRID/RNOTES.y, verify RVEL/RCTRL ──────────
// Parked at a known state (stopped, seek 0, both scrollers at 0) so the note
// x's are the fixture's predictable beat*ppb positions, then measured with
// the SAME `debug.explainFrames` idiom m23c1 uses (its header, lines 237-273,
// is the copied reference) — NOT re-derived by guessing new pixel constants.
await req("transport.stop", {});
await req("transport.seek", { beats: 0 });
await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "pianoRoll" });
await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "arrange" });
await sleep(500);
const calPng = `${OUT}/calibration.png`;
const calCap = await req("debug.captureUI", { path: calPng });
if (calCap.width !== 2800 || calCap.height !== 2000) {
  throw new Error(`calibration capture size ${calCap.width}x${calCap.height}`);
}
// explainFrames is INERT unless explain mode is ON, and a valid id then comes
// back undefined — indistinguishable from a wrong id — so the frames are
// asserted present below rather than trusted blindly. Off again immediately:
// explain mode paints a violet overlay that must not leak into any capture
// used for a real measurement.
await req("debug.explainMode", { on: true });
await sleep(300);
const ef = await req("debug.explainFrames", { ids: ["pianoRollGrid", "pianoRollVelocity", "pianoRollControllers"] });
await req("debug.explainMode", { on: false });
await sleep(300);
const gridFrame = ef.frames?.pianoRollGrid?.[0];
const velFrame = ef.frames?.pianoRollVelocity?.[0];
const ctrlFrame = ef.frames?.pianoRollControllers?.[0];
if (!gridFrame || !velFrame || !ctrlFrame || !ef.captureOrigin || !ef.captureSize) {
  throw new Error(`calibration: missing measured frames — ${JSON.stringify(ef).slice(0, 400)}`);
}
// The m23-ag idiom: explainRoot-space point -> capture pixel via captureOrigin
// plus the ratio of a REAL capture's pixel height to the reported captureSize
// (points) — never a guessed/hardcoded backing scale.
const calScale = calCap.height / ef.captureSize.height;
const toCaptureBox = (f) => ({
  x: Math.round((f.x + ef.captureOrigin.x) * calScale),
  y: Math.round((f.y + ef.captureOrigin.y) * calScale),
  w: Math.round(f.width * calScale),
  h: Math.round(f.height * calScale),
});
const gridBox = toCaptureBox(gridFrame);
const velBox = toCaptureBox(velFrame);
const ctrlBox = toCaptureBox(ctrlFrame);
console.log(`calibration: scale=${calScale} captureOrigin=${JSON.stringify(ef.captureOrigin)}`);
console.log(`calibration: pianoRollGrid capture box ${JSON.stringify(gridBox)}`);
console.log(`calibration: pianoRollVelocity capture box ${JSON.stringify(velBox)}`);
console.log(`calibration: pianoRollControllers capture box ${JSON.stringify(ctrlBox)}`);

// Row scan: rowHeight is PINNED to 34pt by buildFixture, so its capture-space
// size is a known constant. Scan every row-height slice of the grid panel and
// find which one carries note ink (the fixture's single pitch, 60/C4) — that
// is the row RNOTES must read, and every other row is a valid RGRID home.
const rowHCap = 34 * calScale;
const rows = [];
for (let ry = gridBox.y, ri = 0; ry + rowHCap <= gridBox.y + gridBox.h; ry += rowHCap, ri++) {
  const r = probe(calPng, `cal-row-${ri}`, { x: 140, y: Math.round(ry), w: 2635, h: Math.round(rowHCap), thr: 20 });
  rows.push({ i: ri, y: Math.round(ry), peak: Number(r.peak) });
}
const sortedByPeak = rows.slice().sort((a, b) => b.peak - a.peak);
const hotRow = sortedByPeak[0];
const secondHotRow = sortedByPeak[1];
console.log(`calibration: row scan (${rows.length} rows) — hottest row ${hotRow.i} `
  + `y=${hotRow.y} peak=${hotRow.peak.toFixed(2)}; next-hottest peak=${secondHotRow?.peak.toFixed(2) ?? "n/a"}`);
check("CALIBRATION: exactly one grid row is hot (the note row is unambiguous)",
      hotRow.peak >= 20 && (!secondHotRow || secondHotRow.peak < 20),
      `hot=${hotRow.peak.toFixed(2)} nextHot=${secondHotRow?.peak.toFixed(2) ?? "n/a"}`);

// RNOTES: centered on the hot (note) row.
//
// ⚠️ m23-bk: because RNOTES now sits ON the pitch-60 row instead of ~100px
// above it, its runList is note starts UNION the playhead — the playhead
// spans every pitch row, including this one, so whenever it crosses this
// x-window it adds one more "start" that is not on the note lattice.
// MEASURED (a Leg 5 paged capture, roll offset 1133): starts
// 267,654,1067,1867,2667 — four are exactly the beat-12/16/20/24 note
// lattice (spacing 800px = 4 beats * 100ppb * 2x); 654 has no lattice fit
// and lands exactly where `ROLL_X0 + (beat*PPB - offset)*SCALE` puts the
// playhead at the beat the transport had reached (~13.9). Every CURRENT
// consumer of RNOTES only tests riser ⊆ starts membership
// (`risers.some(s => Math.abs(c - s) <= 3)`), which tolerates the extra
// entry — but a FUTURE leg asserting `starts.length` exactly, or matching
// bidirectionally, would need to filter the playhead out first.
//
// ✅ m23-gt: THAT FILTER NOW EXISTS — `noteStarts()` (see its block above),
// which drops runs of span <= PLAYHEAD_MAX_SPAN before `starts` is derived.
// Both Leg 5 consumers go through it, and it carries its own two-sided
// positive control at the end of Leg 5. ⚠️ The `probe(... W.RNOTES)` at the
// SAMPLED-RUN call site below is deliberately left RAW: nothing reads
// `sample.rNotes` today, and a filter applied where no leg consumes it would
// be an untested code path pretending to be a guarantee.
W.RNOTES.y = Math.round(hotRow.y + (rowHCap - W.RNOTES.h) / 2);
// RGRID: a note-free band. Anchored at the grid panel's top unless that would
// overlap the hot row or run past the panel's bottom — checked, not assumed —
// in which case it falls back to just below the hot row.
const overlaps = (aY, aH, bY, bH) => aY < bY + bH && bY < aY + aH;
let candidateGridY = gridBox.y;
if (overlaps(candidateGridY, W.RGRID.h, hotRow.y, rowHCap) || candidateGridY + W.RGRID.h > gridBox.y + gridBox.h) {
  candidateGridY = Math.round(hotRow.y + rowHCap + 6);
}
W.RGRID.y = candidateGridY;
check("CALIBRATION: the derived RGRID band fits inside the grid panel and does not overlap the note row",
      W.RGRID.y >= gridBox.y && (W.RGRID.y + W.RGRID.h) <= (gridBox.y + gridBox.h)
        && !overlaps(W.RGRID.y, W.RGRID.h, hotRow.y, rowHCap),
      `RGRID y=${W.RGRID.y} h=${W.RGRID.h}, grid box ${JSON.stringify(gridBox)}, hot row y=${hotRow.y} h=${rowHCap}`);
console.log(`calibration: derived W.RNOTES.y=${W.RNOTES.y}  W.RGRID.y=${W.RGRID.y}`);

// RVEL / RCTRL: NOT re-derived — measured to already sit inside their panels
// (the m23-bk item's own correction), so only VERIFIED here. A future layout
// drift that moves either panel now fails this loudly instead of silently
// re-detaching them the way RGRID/RNOTES had.
check("CALIBRATION: W.RVEL sits inside the measured pianoRollVelocity panel",
      W.RVEL.y >= velBox.y && (W.RVEL.y + W.RVEL.h) <= (velBox.y + velBox.h),
      `RVEL=${JSON.stringify(W.RVEL)} velBox=${JSON.stringify(velBox)}`);
check("CALIBRATION: W.RCTRL sits inside the measured pianoRollControllers panel",
      W.RCTRL.y >= ctrlBox.y && (W.RCTRL.y + W.RCTRL.h) <= (ctrlBox.y + ctrlBox.h),
      `RCTRL=${JSON.stringify(W.RCTRL)} ctrlBox=${JSON.stringify(ctrlBox)}`);

// SETTLE the lanes' laid-out content width before any counter is trusted. The
// lanes learn a newly added clip's extent on their next layout pass, which lands
// a beat after the command returns — and a content-width change that arrives
// mid-leg would be attributed to follow, which is exactly the thing the
// contentWidthChanges counter exists to detect.
let settled = 0;
for (let i = 0; i < 20; i++) {
  await sleep(600);
  const w = (await req("debug.followPlayhead", {})).arrange.contentWidth;
  if (w === settled && w > 0) break;
  settled = w;
}
const geo = await req("debug.followPlayhead", {});
console.log(`arrange viewport=${geo.arrange.viewportWidth} content=${geo.arrange.contentWidth} | ` +
            `roll viewport=${geo.pianoRoll.viewportWidth} content=${geo.pianoRoll.contentWidth}\n`);
check("both surfaces have several viewports of content to follow across",
      geo.arrange.contentWidth > geo.arrange.viewportWidth * 3 &&
      geo.pianoRoll.contentWidth > geo.pianoRoll.viewportWidth * 3,
      `arrange ${geo.arrange.contentWidth}/${geo.arrange.viewportWidth}, roll ${geo.pianoRoll.contentWidth}/${geo.pianoRoll.viewportWidth}`);

// ── a sampled run of REAL playback ────────────────────────────────────────
async function playAndSample(tag, { enabled, seconds = 15, everyMs = 1200 }) {
  await req("transport.stop", {});
  await req("debug.panelLayout", { followPlayhead: enabled });
  // Park BOTH scrollers at zero so the two legs start from the same place.
  // Switching follow off does not (and must not) scroll anything back, so
  // without this the OFF leg would begin wherever the ON leg left the view.
  // Issued while stopped, so it can never register as a manual scroll.
  await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "arrange" });
  await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "pianoRoll" });
  await req("transport.seek", { beats: 0 });
  await sleep(700);
  await req("debug.followPlayhead", { rearm: true, resetCounters: true });
  await sleep(200);
  const samples = [];
  const t0 = Date.now();
  await req("transport.play", {});
  // Let the playhead clear the leading edge before the first frame: the crop
  // windows start a few px inside the content origin, and a capture taken in the
  // first instants of playback catches it still under that edge.
  await sleep(900);
  let i = 0;
  while (Date.now() - t0 < seconds * 1000) {
    const png = `${OUT}/${tag}-${String(i).padStart(2, "0")}.png`;
    const cap = await req("debug.captureUI", { path: png });
    if (cap.width !== 2800 || cap.height !== 2000) throw new Error(`capture size ${cap.width}x${cap.height}`);
    const f = await req("debug.followPlayhead", {});
    const z = await req("debug.arrangeZoom", {});
    samples.push({
      i, png,
      follow: f, zoom: z,
      aRuler: probe(png, `${tag}-${i}-aruler`, W.ARULER),
      aLane: probe(png, `${tag}-${i}-alane`, W.ALANE),
      rGrid: probe(png, `${tag}-${i}-rgrid`, W.RGRID),
      rVel: probe(png, `${tag}-${i}-rvel`, W.RVEL),
      rNotes: probe(png, `${tag}-${i}-rnotes`, W.RNOTES),
      rGutter: probe(png, `${tag}-${i}-rgutter`, W.RGUTTER),
    });
    i++;
    await sleep(everyMs);
  }
  await req("transport.stop", {});
  const end = await req("debug.followPlayhead", {});
  return { samples, end };
}

function report(tag, run) {
  console.log(`\n── ${tag} — ${run.samples.length} samples of real playback`);
  for (const s of run.samples) {
    console.log(`  ${String(s.i).padStart(2)}  beat ${s.zoom.playheadBeat.toFixed(2).padStart(6)}  ` +
                `arrOff ${String(s.follow.arrange.offset).padStart(6)}  rollOff ${String(s.follow.pianoRoll.offset).padStart(6)}  ` +
                `ruler=${s.aRuler.runs.padEnd(12)} grid=${s.rGrid.runs.padEnd(12)} vel=${s.rVel.runs}`);
  }
  const e = run.end;
  console.log(`  END arrange scrolls=${e.arrange.scrolls} reports=${e.arrange.offsetReports} widthChanges=${e.arrange.contentWidthChanges} suspended=${e.arrange.suspended}`);
  console.log(`  END roll    scrolls=${e.pianoRoll.scrolls} reports=${e.pianoRoll.offsetReports} widthChanges=${e.pianoRoll.contentWidthChanges} suspended=${e.pianoRoll.suspended}`);
}

// ═══ LEG 1 — follow ON: both surfaces keep the playhead in frame ═══════════
const on = await playAndSample("on", { enabled: true });
report("FOLLOW ON", on);
{
  const s = on.samples;
  // m23-bj: EVERY leg below is an `s.every(…)`, and `[].every(fn)` is `true`.
  // `samples` is filled by a WALL-CLOCK race (`while (Date.now() - t0 < 15000)`,
  // one 2800x2000 capture + 6 crops per turn, and t0 is stamped before both
  // `transport.play` and a 900 ms settle), so a loaded machine can shorten it
  // without any signal — the count was only ever `console.log`ged in `report()`.
  // A short run must REDDEN here, not pass vacuously. L1 was already defended
  // by accident (the distinct-offsets leg fails on a short set); this makes it
  // explicit and is the only thing standing between L2 and a vacuous green.
  check("L1 samples: the run produced enough frames to mean anything",
        s.length >= 5, `${s.length} samples`);
  check("L1 arrange: the playhead is in frame in EVERY sample (ruler crop)",
        s.every((x) => lineX(x.aRuler) != null),
        s.map((x) => (lineX(x.aRuler) ?? "GONE")).join(" "));
  // The lane row carries note ink as well as the playhead (and a note ending at
  // the playhead fuses with it into one run), so this asks the same question the
  // velocity lane is asked: does this band show the playhead AT the x the other
  // band puts it at.
  check("L1 arrange: the lane row shows the playhead at the SAME x as the ruler (they scroll in lockstep)",
        s.every((x) => covers(x.aLane, lineX(x.aRuler))),
        s.map((x) => `${lineX(x.aRuler)}∈[${x.aLane.runs}]`).join(" "));
  // ── m23-gs: THE FLOOR WAS `>= 3`. IT IS NOW `>= 2` — AND THE REASON THE ITEM
  //    GAVE FOR LOWERING IT WAS FALSE, SO THE REAL ONE IS RECORDED HERE. ──
  //
  // WHAT WAS DERIVED: `>= 3` needs TWO scrolls inside the sampled window. A page
  // buys ~1131 pt on the roll, so the second scroll needs the playhead past
  // ~beat 24.2 = 12.1 s of playback — inside a 15 s wall-clock window that also
  // absorbs process launch and a 900 ms settle. ~2 s of slack. MEASURED over
  // three runs 2026-08-11: arrange AND roll both produced exactly 3 distinct
  // offsets, i.e. BOTH SURFACES SAT EXACTLY ON THE FLOOR.
  //
  // ⚠️ WHAT `>= 2` IS *NOT*: it is not "decoupled from everything tunable". The
  // FIRST scroll fires when the playhead passes `viewport - edgeMargin` (~1290 pt
  // on the roll = ~beat 12.9 = ~6.45 s), so this still depends on `viewport` and
  // `edgeMargin` — it is decoupled from `leadFraction` only, and buys ~8.5 s of
  // slack instead of ~2 s. Claiming more would replace one false statement with
  // another.
  //
  // ⚠️⚠️ m23-gs's OWN JUSTIFICATION WAS FALSE AND MUST NOT BE RE-INHERITED. It
  // said this leg is "STILL THE ONLY LEG ASSERTING THAT THE SURFACE MOVED AT
  // ALL". It is not: the PAGE-policy legs below pin `scrolls >= 1` — which
  // m23-ea added IN THE SAME CYCLE THAT FILED m23-gs.
  //
  // ⭐ SO WHY KEEP THIS LEG AT ALL? The two are non-redundant in ONE direction.
  // `scrolls` is cumulative and read at `end` — AFTER the sample loop and after
  // `transport.stop` — so a scroll landing between the last sample and that read
  // increments `scrolls` and produces NO distinct offset. This leg is therefore
  // the only one asserting the surface moved DURING THE WINDOW THE PIXELS WERE
  // SAMPLED FROM, which is the window every other L1 leg reasons about. That
  // asymmetry, not the magnitude, is its content.
  //
  // ⚠️ CONSEQUENCE — IT MAKES A SIBLING LOAD-BEARING: at `>= 3` this leg also
  // failed on a short sample set, which is the "defended by accident" m23-bj
  // names above. At `>= 2` a 2-sample run can satisfy it, so that accidental
  // defence is now GONE and `s.length >= 5` is the SOLE short-run guard.
  check("L1 arrange: the surface actually SCROLLED WITHIN THE SAMPLED WINDOW (>= 2 distinct offsets)",
        new Set(s.map((x) => x.follow.arrange.offset)).size >= 2,
        [...new Set(s.map((x) => x.follow.arrange.offset))].join(","));
  // ── m23-gv: THE "DISTINCT OFFSETS" LEG ABOVE IS ORDER-BLIND. THIS ONE IS
  //    ORDER-ONLY. NEITHER IMPLIES THE OTHER. ──
  //
  // `new Set(...).size >= 2` sees `{0, 928, 1860.5}` and `{1860.5, 928, 0}` as
  // the SAME set — it counts how many distinct values appeared, never in what
  // order they appeared in. No leg in this file asserts the per-sample offset
  // SEQUENCE is ordered. The closest existing check to "direction" is Leg 3's
  // `b.arrange.offset > arrOff` (line ~932) — but that is a single two-point
  // comparison, ARRANGE-ONLY, nested inside the manual-scroll-suspension test;
  // it says nothing about L1's own sampled window and nothing about the roll at
  // all. A regression that scrolled BACKWARD on either surface during L1's own
  // forward-playback run — a sign flip in `landing`, a page picked in the wrong
  // direction, an off-by-one that occasionally re-derives a smaller offset —
  // would clear every leg above, including the order-blind distinct-offsets
  // one. This leg reads the RAW per-sample sequence, in capture order, and
  // asserts it never goes down.
  //
  // ⚠️⚠️ THE VACUITY TRAP — WHY THIS WAS NOT SHIPPED INSIDE m23-gs. Non-decreasing
  // is TRIVIALLY TRUE when nothing moved: a surface parked at 0 for the whole
  // run satisfies `0 <= 0 <= 0 <= …` without ever having followed anything.
  // Alone, this is exactly the green-on-nothing shape this file has spent six
  // cycles removing (the m23-bj / m23-fl class documented above). It is
  // meaningful ONLY paired with the `>= 2` distinct-offsets leg directly above —
  // that is the leg that proves the surface actually moved. A future edit that
  // weakens or deletes that pin silently guts this one; the two must be read
  // together, not apart, and this comment is the record of why.
  //
  // ⚠️ THE SCOPE LIMIT — DO NOT LIFT THIS TO A SURFACE THAT CAN SEEK OR LOOP.
  // Non-decreasing is the right invariant ONLY because L1 plays forward from
  // beat 0 with no seeks. Follow's own `landing` computation is explicitly
  // SYMMETRIC (`Sources/DAWAppKit/FollowPlayhead.swift:89-98`: "a loop wrap or a
  // rewind pages BACK by the same rule, so follow never leaves the playhead
  // behind the viewport") — a rewind or a loop wrap legitimately scrolls BACK,
  // and this assertion would redden a CORRECT rewind. The rewind/backward-follow
  // block right after LEG 1 closes exercises exactly that symmetric case, on
  // purpose, OUTSIDE this leg's scope — never merge the two.
  check("L1 arrange: the sampled offsets never go BACKWARD during forward playback (non-decreasing sequence — order-only, see m23-gv above; meaningless without the distinct-offsets pin directly above it)",
        s.every((x, idx) => idx === 0 || x.follow.arrange.offset >= s[idx - 1].follow.arrange.offset),
        s.map((x) => x.follow.arrange.offset).join(" "));
  check("L1 roll: the playhead is in frame in EVERY sample (note-free grid crop)",
        s.every((x) => lineX(x.rGrid) != null),
        s.map((x) => (lineX(x.rGrid) ?? "GONE")).join(" "));
  // m23-bk MANDATORY POSITIVE CONTROL on the derived RGRID window itself. A
  // mis-aimed crop that lands on static note ink still "finds a run" — that
  // was exactly how the old RGRID passed for the wrong reason. Measured
  // signature of the two cases: the real playhead's x is DISTINCT on every
  // sample and its matched run is a ~2px stroke (arrange ruler: 931 1802 2531
  // 1414 2156 1020 1758 2509, runs like 922-924); note ink's x is CONSTANT
  // between scrolls and its run is ~168px wide (measured: 224 224 224 347.5
  // 347.5 347.5 477.5 477.5, runs like 140-308).
  check("L1 roll CALIBRATION: rGrid's x changes on EVERY sample (not just at scroll boundaries — proves it is the playhead, not static note ink)",
        s.every((x, idx) => idx === 0 || lineX(x.rGrid) !== lineX(s[idx - 1].rGrid)),
        s.map((x) => lineX(x.rGrid)).join(" "));
  check("L1 roll CALIBRATION: rGrid's matched run is a thin ~2px stroke (the playhead), not a wide band of note ink",
        s.every((x) => x.rGrid.runList.length === 1 && (x.rGrid.runList[0][1] - x.rGrid.runList[0][0]) <= 8),
        s.map((x) => x.rGrid.runs).join(" | "));
  check("L1 roll: the VELOCITY lane shows the playhead at the SAME x as the grid (m23-c1 two-bands law)",
        s.every((x) => covers(x.rVel, lineX(x.rGrid))),
        s.map((x) => `${lineX(x.rGrid)}∈[${x.rVel.runs}]`).join(" "));
  // Same change as the arrange leg above — see the m23-gs block.
  check("L1 roll: the surface actually SCROLLED WITHIN THE SAMPLED WINDOW (>= 2 distinct offsets)",
        new Set(s.map((x) => x.follow.pianoRoll.offset)).size >= 2,
        [...new Set(s.map((x) => x.follow.pianoRoll.offset))].join(","));
  // Same reasoning as the arrange leg above (m23-gv) — order-only, non-
  // redundant with the order-blind distinct-offsets leg, paired with the
  // roll's own `>= 2` distinct-offsets pin directly above it (without which it
  // is vacuous on a parked-at-0 run), and scoped to forward-only playback only
  // — see the full comment on the arrange leg for why. Not restated here.
  check("L1 roll: the sampled offsets never go BACKWARD during forward playback (non-decreasing sequence — order-only, see m23-gv above; meaningless without the distinct-offsets pin directly above it)",
        s.every((x, idx) => idx === 0 || x.follow.pianoRoll.offset >= s[idx - 1].follow.pianoRoll.offset),
        s.map((x) => x.follow.pianoRoll.offset).join(" "));
  check("L1 roll: the NON-FOLLOWED (vertical) axis holds — the keyboard gutter is byte-identical throughout",
        new Set(s.map((x) => x.rGutter.sha)).size === 1,
        [...new Set(s.map((x) => x.rGutter.sha))].join(","));
  // ── m23-gu: THE INK PIN — the leg above must not be able to pass on a BLANK
  //    window, which was the one thing it could not fail on. ──
  //
  // THE DEFECT, restated so it cannot be re-lost: `size === 1` over the sampled
  // gutter shas is a NEGATIVE property. A crop aimed at flat background is
  // byte-identical across every sample and would pass MORE reliably than a
  // correctly aimed one, which at least risks a stray pixel. Nothing anywhere
  // asserted the crop CONTAINED anything, so the green was fully compatible
  // with measuring nothing. (Latent, never live — the window is aimed correctly
  // today, which is what the numbers below establish rather than assume.)
  //
  // ⚠️ THE FILED SCOPE'S FIRST METHOD IS NOT AVAILABLE — MEASURED, NOT ARGUED.
  // It asked for "non-empty runs" on the W.RGUTTER window itself. That window
  // cannot produce one: the probe scores a per-column cyan MEAN down the WHOLE
  // crop, so a ~40 px glyph inside a 680 px column is divided away. MEASURED on
  // a real sampled capture: `95x680 thr20 -> baseline=-0.48 peak=5.48
  // hotColumns=0 runs=-`. And the keys themselves are invisible to this metric
  // BY CONSTRUCTION — they are neutral white/black and the score is
  // (g+b)/2 - r (keys region at thr 8: `peak=0.63 runs=-`). So the pin has to
  // be a TIGHT window on the one cyan thing in that column.
  //
  // ⚠️ WHAT THIS PIN WITNESSES, STATED EXACTLY, BECAUSE THE NAME COULD IMPLY
  // MORE. The cyan is the editor header's `pianokeys` glyph
  // (`PianoRollView.swift:887`, drawn in `noteColor`), which sits ABOVE the
  // vertical scroller and is FIXED CHROME. This leg therefore proves the hashed
  // crop IS NOT BLANK and IS ALIGNED where it was calibrated. It does NOT prove
  // the piano KEYS are in frame — no cyan metric can see them. (The 680 px
  // window spans the header strip AND the keyboard below it; "gutter" in the
  // leg name above is shorthand for the whole non-followed left column.)
  //
  // ⭐ THE CALIBRATION-VS-SAMPLED CHAIN IS CLOSED BY CONSTRUCTION, AND THAT IS
  // THE POINT OF THE ITEM. An ink pin taken at calibration time would prove
  // nothing about these samples: `calibration.png` is a DIFFERENT capture, so
  // "the calibration crop had ink" + "the sampled crops match each other" never
  // meet. Instead the pin is probed OUT OF THE SAMPLED CROP FILES themselves —
  // `x.rGutter.path`, the very PNG whose sha the leg above compares — at
  // CROP-LOCAL offsets. The bytes measured for ink ARE the bytes hashed;
  // containment is definitional, not inferred. VERIFIED: probing the full
  // capture at absolute (40,950) and the crop file at crop-local (10,110)
  // return the SAME sha (442dddac7955), the same peak (24.12) and the same four
  // runs, differing only by the +30 x origin — the crop file carries the
  // capture's pixels faithfully.
  //
  // THE FLOOR IS `>= 1 RUN`, AND IT IS A PROPERTY, NOT A MARGIN. At thr=20 a
  // non-empty run list is EXACTLY `peak >= 20`, and peak is a column MEAN over
  // 40 rows after the median (background) column is subtracted — ~800 summed
  // cyan units in one column. A stray anti-aliased pixel cannot reach that;
  // only real strokes can. Asserting the observed FOUR runs instead would be
  // asserting the glyph's shape, which is not what m23-gu is about — so 4 is
  // REPORTED in the detail (a stroke merge stays visible in the log) and 1 is
  // asserted.
  //
  // MEASURED — all 8 sampled crops of one run, byte-identical to each other:
  //   ink   @crop-local 10,131 -> peak 56.89  hot 16  runs 21-25,30-32,37-39,43-47
  //   blank @crop-local 10,20  -> peak  0.00  hot  0  runs -
  // A vertical sweep of the SAME window over the SAME crop quantifies the
  // mis-aim it catches: the hot band is dy 110..152, so at dy=131 a slip of
  // 22 px up or 25 px down reddens this leg.
  //
  // ⚠️⚠️ THAT SWEEP ORIGINALLY READ "hot only across dy 110..140 … a crop that
  // slipped ~50 px either way reddens this leg", AND THE WINDOW SHIPPED AT
  // dy=110. Both halves were wrong in the same direction: the band's TOP edge is
  // dy=110 itself (dy=109 reads peak 19.95 against thr 20), so the margin upward
  // was ONE PIXEL, not fifty. Caught at the m23-gu close by re-running the sweep
  // rather than re-reading the sentence. See the constant's block above.
  // ⭐ A SWEEP THAT REPORTS A RANGE MUST SAY WHERE THE CHOSEN POINT SITS INSIDE
  // IT — "hot across 110..140" and "we picked 110" are individually true and
  // jointly a one-pixel margin.
  //
  // THE CONTROL IS THE SECOND HALF OF THE SAME PREDICATE, DELIBERATELY. A
  // separate green "the blank window is empty" leg would ITSELF be a leg that
  // passes on nothing — precisely the class being closed here. Both sides in
  // one check: same probe, same crop file, same predicate, one window that must
  // be hot and one that must be cold.
  //
  // ⚠️ NON-VACUITY IS INHERITED, NOT OWNED: this is an `s.every(...)`, so an
  // empty sample set would pass it. `L1 samples: s.length >= 5` above is the
  // guard, and it is now load-bearing for a FOURTH leg — see the m23-gs block,
  // which flagged it as the sole remaining short-run defence.
  const gInk = s.map((x) => probe(x.rGutter.path, `inkpin-on-${x.i}`, RGUTTER_INK));
  const gBlank = probe(s[0].rGutter.path, "inkpin-on-blank", RGUTTER_BLANK);
  console.log(`  ink pin (crop-local, on the hashed crops): ` +
              gInk.map((k) => `${k.runList.length}r/p${k.peak}`).join(" ") +
              ` | blank ${gBlank.runList.length}r/p${gBlank.peak}`);
  check("L1 roll INK PIN (two-sided): the HASHED gutter crop CONTAINS INK (the header's cyan pianokeys glyph), and the SAME probe on a blank slice of the SAME crop finds none — so the byte-identity leg above cannot be green on a blank window",
        gInk.length >= 1 && gInk.every((k) => k.runList.length >= 1) && gBlank.runList.length === 0,
        `ink @crop-local ${RGUTTER_INK.x},${RGUTTER_INK.y} over ${gInk.length} sampled crops: ` +
        gInk.map((k) => `${k.runList.length}runs/peak${k.peak}`).join(" ") +
        ` [sample 0 runs ${gInk[0]?.runs ?? "n/a"}] || blank @${RGUTTER_BLANK.x},${RGUTTER_BLANK.y}: ` +
        `${gBlank.runList.length}runs/peak${gBlank.peak} runs=${gBlank.runs}`);
  // PAGE, not per-tick: ~15 s at 120 bpm is 30 beats = 3000 pt, under 3 arrange
  // viewports and under 3 roll viewports. A continuous policy would have issued
  // hundreds (measured: 262 over 8 bars — see FollowPlayhead's doc table).
  //
  // ── m23-ea: THE CEILING IS THE CLAIM. THE FLOOR IS ONLY AN ANTI-VACUITY PIN. ──
  //
  // These two legs used to read `>= 2 && <= 12`. The ceiling is the real
  // assertion — it is what separates PAGE policy from the per-tick regression.
  // The `2` was a DERIVED quantity: an arithmetic consequence of travel ×
  // viewportWidth × `FollowPlayhead.leadFraction`, none of which this gate is
  // about. It asserted a *consequence* of three tunables instead of the property
  // it means, so a legitimate change to any of them reddens it against correct
  // code.
  //
  // HOW TIGHT, MEASURED 2026-08-11 (not estimated — read off two identical runs):
  // a page buys `viewport - edgeMargin - leadFraction*viewport` of travel, which
  // is ~927 pt on the arrange (viewport 1090) and ~1131 pt on the roll (1322);
  // the observed offset deltas were 932.5 and 1133, so that model is confirmed.
  // At 100 pt/beat the roll's SECOND scroll therefore needs the playhead past
  // ~beat 24.2 = 12.1 s of playback — inside a 15 s wall-clock window that also
  // absorbs process launch and a 900 ms settle (see the m23-bj note above: t0 is
  // stamped BEFORE both). That is ~2 s of slack. Both runs measured arrange=3,
  // roll=2: THE ROLL SAT EXACTLY ON THE OLD FLOOR, one slow launch from a red
  // that would have meant nothing about follow. (It cannot reach 3 either — the
  // third page needs ~beat 35.6, past the end of the window.)
  //
  // NOTHING IS LOST BY DROPPING IT, for two independent reasons:
  //   1. The property the floor smuggled in — THE PLAYHEAD NEVER LEFT THE
  //      VIEWPORT — is asserted directly and pixel-wise by the two "the playhead
  //      is in frame in EVERY sample" legs above. ⚠️ UPDATE (m23-bk, fixed): the
  //      ROLL leg used to be green-but-UNSOUND — W.RGRID was mis-aimed onto the
  //      pitch-60 note row, so `lineX` read note ink, not the playhead, and the
  //      roll rested on reason 2 alone. RGRID.y is now derived at runtime (see
  //      the CALIBRATION block above) and the two "L1 roll CALIBRATION" legs
  //      prove it reads the playhead (x distinct every sample, ~2px run), so
  //      the roll leg is sound and reason 1 applies to it too.
  //   2. The floor was already IMPLIED by the "several distinct offsets" leg
  //      above. `scrollCount` increments only when `FollowPlayhead.landing`
  //      returns a real move — a clamped no-op returns nil and is never counted
  //      — and the only non-follow offset sources are the `simulateUserScroll`
  //      seam (unused in L1) and content reflow (L1 asserts widthChanges === 0).
  //      So N distinct sampled offsets ⟹ at least N-1 scrolls, and that leg
  //      pins N >= 2 (m23-gs lowered it from 3; N >= 2 still implies at least
  //      one scroll, which is exactly what the PAGE-policy floor below claims).
  //
  // ⚠️ DO NOT read reason 2 as "the strong floor survives somewhere decoupled".
  // The distinct-offsets leg carried the SAME leadFraction coupling and the same
  // ~2 s of slack — that coupling WAS m23-gs and is now FIXED (that leg is
  // `>= 2`; see the m23-gs block above), so neither leg carries a derived floor
  // any more.
  //
  // `>= 1` stays as a bare "something happened" pin. It is NOT a correctness
  // claim and NOT derived: it fails only if follow issued no scroll at all,
  // which on a fixture asserting contentWidth > 3× viewport means follow is
  // broken. ⚠️ Its value is that it is LOCAL — not that it is the last line of
  // defence. A zero-scroll run also reddens the distinct-offsets leg, and a
  // short one reddens the `s.length >= 5` pin. But a leg that greens on nothing
  // and relies on a SIBLING to redden is the m23-bj shape; this one now answers
  // for itself.
  check("L1 arrange: PAGE-policy CEILING — not one scroll per transport tick",
        on.end.arrange.scrolls >= 1 && on.end.arrange.scrolls <= 12, `${on.end.arrange.scrolls}`);
  check("L1 roll: PAGE-policy CEILING — not one scroll per transport tick",
        on.end.pianoRoll.scrolls >= 1 && on.end.pianoRoll.scrolls <= 12, `${on.end.pianoRoll.scrolls}`);
  check("L1: follow never grew either surface's content (the clamp holds — no lane relayout)",
        on.end.arrange.contentWidthChanges === 0 && on.end.pianoRoll.contentWidthChanges === 0,
        `arrange ${on.end.arrange.contentWidthChanges}, roll ${on.end.pianoRoll.contentWidthChanges}`);
  check("L1: neither surface suspended itself during untouched playback",
        !on.end.arrange.suspended && !on.end.pianoRoll.suspended,
        `arrange ${on.end.arrange.suspended}, roll ${on.end.pianoRoll.suspended}`);
}
// The pixel/number cross-check is taken on a STOPPED frame. Under playback the
// capture and the numeric read are two separate round trips and the transport
// moves between them (measured: a consistent ~0.6 beat of drift), so a live
// comparison measures the RTT, not the surface. Stopped, it measures the thing
// that matters: the ruler and lanes really are drawn at the offset the app
// reports, so every offset number in this gate is about the visible view.
{
  const png = `${OUT}/on-stopped.png`;
  const cap = await req("debug.captureUI", { path: png });
  if (cap.width !== 2800 || cap.height !== 2000) throw new Error(`capture size ${cap.width}x${cap.height}`);
  const z = await req("debug.arrangeZoom", {});
  const m = probe(png, "on-stopped-aruler", W.ARULER);
  const predicted = ARRANGE_X0 + SCALE * z.playheadScreenX;
  check("L1 arrange (stopped): the DRAWN playhead sits where the reported offset says it does",
        lineX(m) != null && Math.abs(predicted - lineX(m)) <= 6,
        `predicted ${predicted.toFixed(0)} measured ${lineX(m)} (beat ${z.playheadBeat}, hOffset ${z.hOffset})`);
}

// ═══ LEG 1R — REWIND: follow-driven motion goes backward too ══════════════
//
// TWO REASONS THIS BLOCK EXISTS, restated so neither gets lost to the other.
//
// (1) THE ANTI-VACUITY CONTROL FOR THE TWO "NON-DECREASING" LEGS ABOVE (m23-gv).
// If `follow.<surface>.offset` could NEVER report a decrease under follow-driven
// motion — a monotonic clamp baked in somewhere between follow's own scroll
// calls and the value `debug.followPlayhead {}` reports, say — the two
// non-decreasing legs in LEG 1 would be vacuously true on a BROKEN build: green
// not because follow behaves correctly but because the channel cannot even
// REPORT the failure mode they exist to catch. This block proves the channel
// CAN go down, in the SAME REGIME LEG 1 samples — real playback, followPlayhead
// ON, offset read through `debug.followPlayhead {}` — and NOT through the
// `simulateUserScroll` debug seam. That distinction is the whole point: the
// seam WRITES THE SCROLLER DIRECTLY (see playAndSample's park-at-0 calls, lines
// 552-553, and Leg 3's drag simulation) — a monotonic clamp sitting between
// follow's own decisions and the number the app reports would leave the seam
// untouched and go undetected by any leg that used it as its evidence that
// "offset can decrease".
//
// (2) FIRST END-TO-END COVERAGE OF DOCUMENTED, SHIPPED BEHAVIOUR.
// `Sources/DAWAppKit/FollowPlayhead.swift:89-98` states the `landing`
// computation is explicitly SYMMETRIC: "a loop wrap or a rewind pages BACK by
// the same rule, so follow never leaves the playhead behind the viewport." A
// Swift unit test already pins the PURE function's backward branch
// (`FollowPlayheadTests.pageTurnBackward`,
// `Tests/DAWAppKitTests/FollowPlayheadTests.swift:41-48` — `pageOffset` fed a
// playhead x behind the current offset returns the expected backward target),
// so the rule itself is not unverified. But nothing anywhere drives it END TO
// END: a real seek, during real playback, read back through the real
// control-protocol offset two real scrolling surfaces report. This is that leg.
//
// SELF-GUARDING AGAINST THE NO-FORWARD-SCROLL CASE, ON PURPOSE: `peak` is only
// set once BOTH surfaces are observed to have scrolled forward (offset > 0)
// within the timeout below; a timed-out poll reports back the last real reading
// it has, which on a surface that never left 0 IS 0. `after < 0` can then never
// be true — NOT by assumption: `landing()` clamps its target to `0...ceiling`
// (`FollowPlayhead.swift:95`, `.clamped(to: 0...ceiling)`), so a reported offset
// cannot be negative BY CONSTRUCTION — so the check REDDENS instead of passing
// on nothing. No separate "it scrolled forward first" precondition leg is
// written here for that reason.
//
// POLLING, NOT A FIXED SLEEP, AND NOTHING HERE THROWS: a fixed sleep either
// wastes wall-clock margin or, on a loaded machine, samples too early and calls
// a live scroll "never happened". Both polls below carry a hard ~14 s timeout
// and never throw on expiry. `transport.seek` mid-playback is additionally the
// ONE command interaction nowhere else in this file exercises (every other
// seek in this gate is issued while stopped) — its own possible rejection is
// caught too, so a request failure becomes a string in a check's detail, never
// an unhandledRejection that would exit the whole gate at process.exit(3) with
// zero of the other 62 verdicts printed.
//
// ⚠️ THE TIMEOUT'S OWN MARGIN IS NOT ESTABLISHED HERE — ONLY LOGGED. A green
// pair says the drop happened inside 14 s; it does not say how much of that
// budget was spent, and a leg that passed near its own deadline is one slow
// launch from a red that means nothing about follow (the m23-gs / m23-ea
// slack trap, on a new axis: wall-clock, not offset count). Both polls below
// print their elapsed ms so that margin is a recorded number, not a guess —
// read it at the close of this item rather than re-deriving it blind.
console.log("\n── REWIND DURING FOLLOW (backward-follow: anti-vacuity for m23-gv + FollowPlayhead.swift:89-98)");
{
  const REWIND_TIMEOUT_MS = 14000, REWIND_POLL_MS = 400;
  let reqError = null;
  const safeFollow = async () => {
    try { return await req("debug.followPlayhead", {}); }
    catch (e) { reqError = reqError ?? `poll: ${e?.message ?? e}`; return null; }
  };
  const pollUntil = async (predicate) => {
    const t0 = Date.now();
    let last = await safeFollow();
    while ((!last || !predicate(last)) && Date.now() - t0 < REWIND_TIMEOUT_MS) {
      await sleep(REWIND_POLL_MS);
      const next = await safeFollow();
      if (next) last = next;
    }
    // Elapsed is reported (not just pass/fail) so the timeout's OWN margin is a
    // recorded number — see the header comment's "timeout's own margin" note.
    const elapsedMs = Date.now() - t0;
    return { value: last ?? { arrange: { offset: 0 }, pianoRoll: { offset: 0 } }, elapsedMs,
             timedOut: elapsedMs >= REWIND_TIMEOUT_MS };
  };

  await req("transport.stop", {});
  await req("debug.panelLayout", { followPlayhead: true });
  // Park BOTH scrollers at zero while stopped — same idiom as playAndSample
  // (lines 552-553): issued while stopped, so it can never register as a
  // manual scroll.
  await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "arrange" });
  await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "pianoRoll" });
  await req("transport.seek", { beats: 0 });
  await sleep(700);
  await req("debug.followPlayhead", { rearm: true, resetCounters: true });
  await sleep(200);

  await req("transport.play", {});
  const peakPoll = await pollUntil((f) => f.arrange.offset > 0 && f.pianoRoll.offset > 0);
  const peakArrange = peakPoll.value.arrange.offset, peakRoll = peakPoll.value.pianoRoll.offset;
  console.log(`  peak (both scrolled forward, or 14s timeout): arrange=${peakArrange} roll=${peakRoll} ` +
              `[poll took ${peakPoll.elapsedMs}ms of ${REWIND_TIMEOUT_MS}ms budget, timedOut=${peakPoll.timedOut}]`);

  try {
    await req("transport.seek", { beats: 0 });     // the ONE mid-playback seek in this file
  } catch (e) {
    reqError = `mid-play seek: ${e?.message ?? e}`;
  }
  const afterPoll = await pollUntil((f) => f.arrange.offset < peakArrange && f.pianoRoll.offset < peakRoll);
  const afterArrange = afterPoll.value.arrange.offset, afterRoll = afterPoll.value.pianoRoll.offset;
  console.log(`  after rewind (both dropped below peak, or 14s timeout): arrange=${afterArrange} roll=${afterRoll} ` +
              `[poll took ${afterPoll.elapsedMs}ms of ${REWIND_TIMEOUT_MS}ms budget, timedOut=${afterPoll.timedOut}]` +
              (reqError ? `  [ERROR: ${reqError}]` : ""));
  await req("transport.stop", {});

  check("L1R arrange: a rewind mid-playback pages the view BACK (offset drops below its pre-rewind peak — FollowPlayhead.swift:89-98's symmetric rule; also the anti-vacuity control for the arrange non-decreasing leg above)",
        reqError === null && afterArrange < peakArrange,
        `${peakArrange} → ${afterArrange}` + (reqError ? ` [ERROR: ${reqError}]` : ""));
  check("L1R roll: a rewind mid-playback pages the view BACK (offset drops below its pre-rewind peak — FollowPlayhead.swift:89-98's symmetric rule; also the anti-vacuity control for the roll non-decreasing leg above)",
        reqError === null && afterRoll < peakRoll,
        `${peakRoll} → ${afterRoll}` + (reqError ? ` [ERROR: ${reqError}]` : ""));
}

// ═══ LEG 2 — follow OFF: the same playback moves nothing ═══════════════════
const off = await playAndSample("off", { enabled: false });
report("FOLLOW OFF", off);
{
  const s = off.samples;
  // m23-bj: THIS is the block that was genuinely undefended. All three legs
  // below are `s.every(…)` over the same wall-clock-raced collection, and none
  // of them, nor anything upstream, asserts a count — so on a short run
  // "the offset never moves off zero" passes because there was nothing to move.
  // (A FULLY empty run would instead throw at `s[s.length - 1]` further down;
  // the silent case is the SHORT one, which is also the reachable one.)
  check("L2 samples: the run produced enough frames to mean anything",
        s.length >= 5, `${s.length} samples`);
  check("L2 arrange: the offset never moves off zero",
        s.every((x) => x.follow.arrange.offset === 0), [...new Set(s.map((x) => x.follow.arrange.offset))].join(","));
  check("L2 roll: the offset never moves off zero",
        s.every((x) => x.follow.pianoRoll.offset === 0), [...new Set(s.map((x) => x.follow.pianoRoll.offset))].join(","));
  check("L2: no scrolls were issued on either surface",
        off.end.arrange.scrolls === 0 && off.end.pianoRoll.scrolls === 0,
        `arrange ${off.end.arrange.scrolls}, roll ${off.end.pianoRoll.scrolls}`);
  // The positive control for leg 1: with follow off the playhead LEAVES, which is
  // the very complaint m23-c2 exists to fix.
  const lastA = s[s.length - 1], lastR = lastA;
  check("L2 arrange: the playhead has LEFT the viewport by the end (the pre-m23-c2 behaviour)",
        lineX(lastA.aRuler) === null, lastA.aRuler.runs);
  check("L2 roll: the playhead has LEFT the viewport by the end",
        lineX(lastR.rGrid) === null, lastR.rGrid.runs);
  // …and once it is gone, consecutive frames of the surface are byte-identical:
  // nothing is moving at all.
  const tail = s.slice(-3);
  check("L2: with the playhead gone, consecutive arrange frames are byte-identical (nothing moves)",
        new Set(tail.map((x) => x.aRuler.sha)).size === 1, tail.map((x) => x.aRuler.sha).join(","));
  check("L2: with the playhead gone, consecutive roll frames are byte-identical (nothing moves)",
        new Set(tail.map((x) => x.rGrid.sha)).size === 1, tail.map((x) => x.rGrid.sha).join(","));
}

// ═══ LEG 3 — a manual scroll during follow SUSPENDS that surface only ══════
console.log("\n── MANUAL SCROLL DURING FOLLOW");
{
  await req("transport.stop", {});
  await req("transport.seek", { beats: 0 });
  await req("debug.panelLayout", { followPlayhead: true });
  await req("debug.followPlayhead", { rearm: true, resetCounters: true });
  await sleep(400);
  await req("transport.play", {});
  await sleep(2500);
  // Drag the ROLL only.
  await req("debug.followPlayhead", { simulateUserScroll: 6000, surface: "pianoRoll" });
  await sleep(900);
  const a = await req("debug.followPlayhead", {});
  console.log(`  after roll drag: roll suspended=${a.pianoRoll.suspended} off=${a.pianoRoll.offset} | ` +
              `arrange suspended=${a.arrange.suspended} off=${a.arrange.offset}`);
  check("L3: dragging the ROLL suspends the ROLL", a.pianoRoll.suspended === true, JSON.stringify(a.pianoRoll));
  check("L3: …and does NOT suspend the arrange (suspension is PER SURFACE)",
        a.arrange.suspended === false, JSON.stringify(a.arrange));
  // The suspended surface then stops moving while the other keeps following.
  const rollOff = a.pianoRoll.offset, arrOff = a.arrange.offset;
  await sleep(3500);
  const b = await req("debug.followPlayhead", {});
  console.log(`  3.5 s later:     roll off=${b.pianoRoll.offset} (was ${rollOff}) | arrange off=${b.arrange.offset} (was ${arrOff})`);
  check("L3: the suspended roll does NOT fight the pointer (its offset stays where the drag left it)",
        b.pianoRoll.offset === rollOff, `${rollOff} → ${b.pianoRoll.offset}`);
  check("L3: the un-suspended arrange keeps following through the same playback",
        b.arrange.offset > arrOff, `${arrOff} → ${b.arrange.offset}`);
  // Now drag the arrange too, then prove BOTH resume paths.
  await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "arrange" });
  await sleep(900);
  const c = await req("debug.followPlayhead", {});
  check("L3: dragging the arrange suspends the arrange", c.arrange.suspended === true, JSON.stringify(c.arrange));
  // Resume path 1: the chip (debug.followPlayhead {rearm}) — same call the chip makes.
  const draggedA = c.arrange.offset, draggedR = c.pianoRoll.offset;
  await req("debug.followPlayhead", { rearm: true });
  await sleep(1600);
  const d = await req("debug.followPlayhead", {});
  check("L3: RESUME clears the suspension on both surfaces",
        !d.arrange.suspended && !d.pianoRoll.suspended, JSON.stringify({ a: d.arrange.suspended, r: d.pianoRoll.suspended }));
  // Following again means the view LEFT where the drag parked it and caught up.
  // (Not "the offset keeps changing": a page policy is silent between turns —
  // that silence is the feature, and asserting on it would be asserting the
  // continuous behaviour this item measured and rejected.)
  check("L3: after resuming, both surfaces have caught the playhead back up",
        d.arrange.offset !== draggedA && d.pianoRoll.offset !== draggedR,
        `arrange ${draggedA}→${d.arrange.offset}, roll ${draggedR}→${d.pianoRoll.offset}`);
  {
    const png = `${OUT}/resumed.png`;
    await req("debug.captureUI", { path: png });
    const g1 = probe(png, "resumed-rgrid", W.RGRID), a1 = probe(png, "resumed-aruler", W.ARULER);
    check("L3: …and the playhead is visibly back in frame on BOTH surfaces",
          lineX(a1) != null && lineX(g1) != null, `ruler=${a1.runs} grid=${g1.runs}`);
  }
  // Resume path 2: pressing PLAY again.
  await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "arrange" });
  await sleep(800);
  const f = await req("debug.followPlayhead", {});
  check("L3: (setup) the arrange is suspended again", f.arrange.suspended === true, `${f.arrange.suspended}`);
  await req("transport.stop", {});
  await req("transport.play", {});
  await sleep(800);
  const g = await req("debug.followPlayhead", {});
  check("L3: pressing PLAY re-arms follow (the other resume path)",
        g.arrange.suspended === false, `${g.arrange.suspended}`);
  await req("transport.stop", {});
}

// ═══ LEG 4 — OFF-CLIP: follow is not driving the roll, so a scroll is not a fight ══
console.log("\n── OFF-CLIP vs IN-CLIP (the roll's manual-scroll detector)");
{
  // Edit clip2 (beats 200…328) and play at beat 0: there is no playhead line in
  // the roll to keep in frame, so follow issues nothing — and must not blame the
  // user for scrolling a surface it was never contesting.
  await req("transport.stop", {});
  await req("debug.captureUI", { path: `${OUT}/offclip-open.png`, selectClip: clip2Id });
  await req("transport.seek", { beats: 0 });
  await req("debug.panelLayout", { followPlayhead: true });
  await req("debug.followPlayhead", { rearm: true, resetCounters: true });
  await sleep(500);
  await req("transport.play", {});
  await sleep(2000);
  await req("debug.followPlayhead", { simulateUserScroll: 5000, surface: "pianoRoll" });
  await sleep(1200);
  const offClip = await req("debug.followPlayhead", {});
  console.log(`  transport OUTSIDE the edited clip: roll suspended=${offClip.pianoRoll.suspended} scrolls=${offClip.pianoRoll.scrolls} off=${offClip.pianoRoll.offset}`);
  check("L4 off-clip: follow issued nothing for the roll (no line to keep in frame)",
        offClip.pianoRoll.scrolls === 0, `${offClip.pianoRoll.scrolls}`);
  check("L4 off-clip: a scroll follow was NEVER CONTESTING does not suspend it",
        offClip.pianoRoll.suspended === false, JSON.stringify(offClip.pianoRoll));
  // The control arm: same clip, same drag, transport INSIDE it.
  await req("transport.stop", {});
  await req("transport.seek", { beats: CLIP2_AT + 1 });
  await req("debug.followPlayhead", { rearm: true, resetCounters: true });
  await sleep(400);
  await req("transport.play", {});
  await sleep(2500);
  const beforeDrag = await req("debug.followPlayhead", {});
  await req("debug.followPlayhead", { simulateUserScroll: 9000, surface: "pianoRoll" });
  await sleep(1200);
  const inClip = await req("debug.followPlayhead", {});
  console.log(`  transport INSIDE the edited clip: roll suspended=${inClip.pianoRoll.suspended} scrolls=${beforeDrag.pianoRoll.scrolls}→${inClip.pianoRoll.scrolls}`);
  check("L4 in-clip (CONTROL): the identical drag DOES suspend the roll",
        inClip.pianoRoll.suspended === true, JSON.stringify(inClip.pianoRoll));
  await req("transport.stop", {});
}

// ═══ LEG 5 — the THIRD roll band: the controller strip follows too ═════════
// The strip carries no playhead of its own, so it does not follow for its own
// sake — it follows so the CC line stays under the notes it belongs to. That
// makes LOCKSTEP the claim, and lockstep is only measurable against a band that
// has ink: the CC lane, whose risers sit on the same beats as the notes.
console.log("\n── CTRL BAND (the third roll band)");
{
  await req("transport.stop", {});
  await req("debug.panelLayout", { followPlayhead: false });
  await req("debug.captureUI", { path: `${OUT}/ctrl-open.png`, selectClip: clipId });
  await req("transport.seek", { beats: 0 });
  await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "pianoRoll" });
  await sleep(900);
  const parked = `${OUT}/ctrl-parked.png`;
  await req("debug.captureUI", { path: parked });
  const ctrl0 = probe(parked, "ctrl-parked", W.RCTRL);
  const notes0 = probe(parked, "ctrl-parked-notes", W.RNOTES);
  const risers0 = ctrl0.runList.map(([a, b]) => (a + b) / 2);
  // m23-gt: WIDTH-FILTERED. The raw run list here is `note starts ∪ {playhead}`.
  const starts0 = noteStarts(notes0);
  const dropped0 = thinRuns(notes0);
  console.log(`  parked: risers ${risers0} vs note starts ${starts0} `
    + `(raw ${runText(notes0.runList)}; width-filtered out ${runText(dropped0)})`);
  check("L5 (ground truth): at offset 0 every CC riser sits on a WIDTH-FILTERED note start (playhead runs excluded — m23-gt)",
        risers0.length >= 3 && risers0.every((c) => starts0.some((s) => Math.abs(c - s) <= 3)),
        `risers ${risers0} vs filtered starts ${starts0} | raw ${runText(notes0.runList)} | dropped ${runText(dropped0)}`);
  // ── m23-gt ANTI-VACUITY. `.every()` ON AN EMPTY ARRAY IS TRUE. ──
  // The floor above (`risers0.length >= 3`) is on the RISER list and does
  // nothing for a `starts` list the new filter could have eaten. The floor here
  // is RELATIONAL, not a bare count, and that is the point: at the paged sample
  // an over-matching filter that dropped the right-clipped note would still
  // leave 3 starts, clearing any absolute floor worth writing, and would then
  // redden the MEMBERSHIP leg for a reason no reader could recover. Every start
  // the risers must be explained by has to survive, so `starts >= risers` is the
  // weakest true statement that catches it.
  //
  // ⚠️⚠️ BUT AT *THIS* SAMPLE THE RELATIONAL HALF IS BLIND, AND I ONLY KNOW THAT
  // BECAUSE I RAN THE INVERTED CONTROL. At offset 0 the beat-0 note's true start
  // is x=133, LEFT of this crop's origin (x=140) — so its CC riser is off-crop
  // too. Eating that note therefore removes one start AND leaves `risers` at 3,
  // and `3 >= 3` stays green. MEASURED: an inverted build with
  // PLAYHEAD_MAX_SPAN=173 reddened the paged pair and the keep-side control and
  // left THIS leg green, silently, with `dropped 140-310(w171)` sitting in its
  // own detail string. ⭐ A COUNT COMPARISON CANNOT SEE A LOSS THAT REMOVES ONE
  // ITEM FROM EACH SIDE.
  //
  // So the second clause is not belt-and-braces, it is the half that works here:
  // at offset 0 the beat-0 note is ALWAYS truncated by the crop (133 < 140, and
  // it is 177 px long), so its run ALWAYS begins at exactly `W.RNOTES.x` — 11/11
  // parked-geometry crops in the artefact set read `140-310`. If the filter eats
  // it, that value is gone from `starts`, whatever the counts do.
  check("L5 (m23-gt anti-vacuity): the width filter did not EAT a note at offset 0 — filtered starts still outnumber the risers AND still contain the LEFT-CLIPPED beat-0 note sitting on the crop edge",
        starts0.length >= risers0.length && starts0.includes(W.RNOTES.x),
        `filtered starts ${starts0.length} (${starts0}) vs risers ${risers0.length}; crop edge ${W.RNOTES.x} present=${starts0.includes(W.RNOTES.x)} | raw ${runText(notes0.runList)} | dropped ${runText(dropped0)}`);

  await req("debug.panelLayout", { followPlayhead: true });
  await req("debug.followPlayhead", { rearm: true, resetCounters: true });
  await req("transport.play", {});                    // REAL playback, never a seek
  let rollOffset = 0;
  for (let i = 0; i < 40; i++) {
    await sleep(700);
    rollOffset = (await req("debug.followPlayhead", {})).pianoRoll.offset;
    if (rollOffset > 800) break;
  }
  await req("transport.stop", {});
  await sleep(700);
  rollOffset = (await req("debug.followPlayhead", {})).pianoRoll.offset;
  const paged = `${OUT}/ctrl-paged.png`;
  await req("debug.captureUI", { path: paged });
  const ctrl1 = probe(paged, "ctrl-paged", W.RCTRL);
  const notes1 = probe(paged, "ctrl-paged-notes", W.RNOTES);
  const risers1 = ctrl1.runList.map(([a, b]) => (a + b) / 2);
  const starts1 = noteStarts(notes1);        // m23-gt: WIDTH-FILTERED, see above
  const dropped1 = thinRuns(notes1);
  console.log(`  paged @${rollOffset}: risers ${risers1} vs note starts ${starts1} `
    + `(raw ${runText(notes1.runList)}; width-filtered out ${runText(dropped1)})`);
  check("L5: follow paged the roll under playback", rollOffset > 800, `offset ${rollOffset}`);
  check("L5: the CTRL band MOVED — its ink is not where it was at offset 0",
        ctrl0.sha !== ctrl1.sha, `${ctrl0.sha} vs ${ctrl1.sha}`);
  check("L5: LOCKSTEP — after the page the risers are STILL on the WIDTH-FILTERED note starts (playhead runs excluded — m23-gt)",
        risers1.length >= 2 && risers1.every((c) => starts1.some((s) => Math.abs(c - s) <= 3)),
        `risers ${risers1} vs filtered starts ${starts1} | raw ${runText(notes1.runList)} | dropped ${runText(dropped1)}`);
  // Same anti-vacuity floor as at offset 0 — and THIS is the sample it exists
  // for: the rightmost note is the one truncated by the crop edge, so it is the
  // one an over-tuned width filter would eat.
  check("L5 (m23-gt anti-vacuity): the width filter did not EAT a note after the page — the filtered starts still outnumber the risers they have to explain",
        starts1.length >= risers1.length,
        `filtered starts ${starts1.length} (${starts1}) vs risers ${risers1.length} | raw ${runText(notes1.runList)} | dropped ${runText(dropped1)}`);
  // The strongest form: predict each riser from the offset the MODEL reports.
  // "The three bands agree with each other" and "the three bands are where the
  // follow model says they are" are different claims; this is the second one.
  const predicted = [];
  for (let b = 0; b < CLIP_BEATS; b += 4) {
    const x = ROLL_X0 + (b * PPB - rollOffset) * SCALE;
    if (x >= W.RCTRL.x + 6 && x <= W.RCTRL.x + W.RCTRL.w - 6) predicted.push(x);
  }
  check("L5: every riser lands where the REPORTED roll offset says it should",
        predicted.length >= 2 && predicted.every((p) => risers1.some((c) => Math.abs(c - p) <= 4)),
        `predicted ${predicted} vs measured ${risers1} @ offset ${rollOffset}`);

  // ══ m23-gt POSITIVE CONTROL for the width filter — TWO-SIDED and DERIVED ══
  //
  // A filter that is never shown doing its job is a filter nobody can trust, and
  // "the legs are still green" proves nothing about it: the filter can only make
  // a membership predicate HARDER, so a green run is green under both the old
  // and the new code. The two things that have to be demonstrated are therefore
  // the two sides of the filter, and each needs the case it acts on to be
  // PRESENT — asserted, not assumed (the m23-gu green-on-nothing class).
  //
  // ⚠️ NOTHING HERE IS A HARDCODED X, AND THAT IS NOT STYLE. The note lattice
  // MOVES run to run: the filed item quotes starts `259,654,1059,1859,2659` and
  // the run this control was written against reads `263,654,1063,1863,2663`,
  // because `rollOffset` differs by a few points between runs. Only the playhead
  // sat still. A control pinned to literals would be measuring a past run.
  //   • the playhead's x comes from RGRID — a DIFFERENT, note-free crop, i.e. a
  //     second instrument, not the list under test;
  //   • the clipped note is identified by GEOMETRY (it touches the crop edge) and
  //     by NOT being at that measured playhead x — neither of which is the width
  //     test, so the control is not circular.
  //
  // ⚠️ WHY A DEDICATED CAPTURE AND NOT THE `paged` ONE ABOVE. Opportunistic would
  // be FLAKY, quantified: notes are 0.9 beats long every 4 beats, so a playhead
  // stopped at an arbitrary moment is inside a note's x-range ~22% of the time,
  // where it MERGES into that note's run and no separate thin run exists to drop.
  // Beat 2 is 1.1 beats clear of the beat-0 note's end and 2 beats before the
  // next note, which makes the separation deterministic instead of lucky. At
  // offset 0 that also puts the beat-0 note (true start x=133) LEFT of the crop
  // origin (x=140), so the same capture carries the clipped-note case for free.
  await req("transport.stop", {});
  await req("debug.panelLayout", { followPlayhead: false });   // nothing may re-scroll under us
  await req("transport.seek", { beats: 2 });
  await req("debug.followPlayhead", { simulateUserScroll: 0, surface: "pianoRoll" });
  await sleep(900);
  const filterCtl = `${OUT}/ctrl-filter-control.png`;
  await req("debug.captureUI", { path: filterCtl });
  const fGrid = probe(filterCtl, "filter-control-rgrid", W.RGRID);
  const fNotes = probe(filterCtl, "filter-control-notes", W.RNOTES);
  const phX = lineX(fGrid);
  const fKept = noteStarts(fNotes);
  console.log(`  filter control @beat2/offset0: rgrid ${runText(fGrid.runList)} -> playhead x ${phX}; `
    + `notes raw ${runText(fNotes.runList)} -> filtered starts ${fKept}`);
  // (1) The second instrument has to be trustworthy before it can arbitrate.
  //     `lineX` silently takes the FIRST run, so without this a two-run RGRID
  //     would hand the legs below a garbage x that sits off every note — and both
  //     would go green having measured nothing.
  check("L5 FILTER CONTROL (setup): the note-free RGRID band shows EXACTLY ONE cyan run, so the playhead's x is measured INDEPENDENTLY of the row under test",
        fGrid.runList.length === 1 && phX != null,
        `rgrid runs ${runText(fGrid.runList)} -> phX ${phX}`);
  const phRaw = fNotes.runList.filter(([a, b]) => phX != null && phX >= a - 3 && phX <= b + 3);
  // (2) REMOVE side, precondition: the hazard is really on the row.
  check("L5 FILTER CONTROL (remove side, precondition): the note row REALLY DOES carry the playhead — a RAW run sits at the RGRID-measured x",
        phRaw.length === 1,
        `phX ${phX}; raw runs covering it ${runText(phRaw)}; all raw ${runText(fNotes.runList)}`);
  // (3) REMOVE side, the assertion: that run is thin, and it is gone after the filter.
  check("L5 FILTER CONTROL (remove side): the width filter DROPPED the playhead — its run is thin and NO filtered start survives at its x",
        phRaw.length === 1 && runSpan(phRaw[0]) <= PLAYHEAD_MAX_SPAN &&
        fKept.every((s) => Math.abs(s - phX) > 3),
        `phX ${phX}; its raw run ${runText(phRaw)} (span ${phRaw.length ? runSpan(phRaw[0]) : "n/a"} vs max ${PLAYHEAD_MAX_SPAN}); filtered starts ${fKept}`);
  // (4) KEEP side. `fullSpan` is measured over EDGE-FREE runs only — taking the
  //     max over all runs would let a degenerate case define "full note" as
  //     something clipped.
  const XL = W.RNOTES.x, XR = W.RNOTES.x + W.RNOTES.w - 1;
  const interior = fNotes.runList.filter(([a, b]) => a !== XL && b !== XR);
  const fullSpan = interior.length ? Math.max(...interior.map(runSpan)) : 0;
  const clippedNotes = fNotes.runList.filter(([a, b]) =>
    (a === XL || b === XR) && !(phX != null && phX >= a - 3 && phX <= b + 3) && runSpan([a, b]) < fullSpan);
  check("L5 FILTER CONTROL (keep side): a note TRUNCATED by the crop edge is present and the width filter KEPT it (selected by edge-touching + not-the-playhead's-x + shorter than a full note — none of which is the width test)",
        interior.length >= 1 && clippedNotes.length >= 1 &&
        clippedNotes.every(([a]) => fKept.includes(a)),
        `clipped ${runText(clippedNotes)} vs full-note span ${fullSpan} (from ${interior.length} interior runs); filtered starts ${fKept}; crop edges ${XL}/${XR}`);

  // ── m23-gy: RNOTES THRESHOLD MARGIN — asserted DIRECTLY, not inferred ─────
  //
  // RNOTES and RCTRL both ship at `thr: 20` (lines ~114/117 above), but they
  // read very different bands — RNOTES a 34px note row, RCTRL an 80px
  // controller band — so their ink margins are NOT comparable, and this file
  // already says so in the PLAYHEAD_MAX_SPAN comment (line ~227). What that
  // comment does not do is DEFEND the RNOTES margin with its own leg: if a
  // note is ever lost to THRESHOLD rather than to the width filter, it is the
  // m23-gt anti-vacuity legs above (~1230, ~1264) that redden — "filtered
  // starts no longer outnumber the risers" — which reads exactly like the
  // WIDTH FILTER (PLAYHEAD_MAX_SPAN, line ~237) over-matching, and sends the
  // next reader to the wrong constant. This block measures the threshold
  // margin on the SAME already-captured PNGs those legs (and Leg 1 / Leg 2)
  // already wrote to disk — `probe(png, tag, win)` takes a saved path, so
  // nothing here issues a new `debug.captureUI` call. It lives inside Leg 5's
  // own scope (not after it) so `parked`, `paged` and `filterCtl` — the two
  // Leg-5 RNOTES captures this file's own PLAYHEAD_MAX_SPAN comment already
  // counted alongside "the 16 sampled `*-rnotes` of one full run" (its "18
  // crops", line ~191) — are in reach without hoisting a single existing line.
  //
  // SOURCES ARE KEPT SEPARATE, NOT POOLED, so a collapse can be pinned to
  // WHERE it happens. ⚠️ `off`'s ~8 captures are NOT 8 independent
  // measurements: Leg 2's own legs assert the roll never scrolled and that
  // consecutive frames are byte-identical once the playhead is gone, so `off`
  // is one static geometry sampled repeatedly. A pooled "N/24 survive" would
  // silently let `off`'s duplicates outvote `on`'s real variety; reporting
  // per-source is what keeps that honest.
  const gySources = [
    ...on.samples.map((s) => ({ tag: `gy-on-${s.i}`, src: "on", png: s.png })),
    ...off.samples.map((s) => ({ tag: `gy-off-${s.i}`, src: "off", png: s.png })),
    { tag: "gy-parked", src: "parked", png: parked },
    { tag: "gy-paged", src: "paged", png: paged },
    { tag: "gy-filter-control", src: "filter-control", png: filterCtl },
  ];
  // Re-probes every source at threshold `t`, filtering to REAL note bodies —
  // `noteRuns()`, the SAME width filter (width > PLAYHEAD_MAX_SPAN) every
  // other consumer in this file uses — so a run counted here has ALREADY
  // passed the width test identically at every threshold. A survivor lost as
  // `t` rises is lost to THRESHOLD, full stop; the width filter cannot be the
  // explanation because it was applied before `t` ever varied.
  const sweepAt = (t) => gySources.map(({ tag, src, png }) => {
    const m = probe(png, `${tag}-thr${t}`, { ...W.RNOTES, thr: t });
    return { src, runs: noteRuns(m) };
  });
  // BROAD, not just the item's claimed 30-survives/40-gone pair — a sweep that
  // stops at the claimed cliff and finds it still green would leave the cliff
  // itself unmeasured, not confirmed. Extended well past 40 so an actual
  // collapse is observed, not assumed from the item's prose.
  const SWEEP_THR = [20, 25, 30, 33, 35, 38, 40, 50, 60, 80, 100, 120, 150, 200];
  console.log(`\n  RNOTES threshold sweep — m23-gy (${gySources.length} captures: ` +
    `${on.samples.length} on + ${off.samples.length} off + 3 Leg-5) — ` +
    `note bodies = runs with width > ${PLAYHEAD_MAX_SPAN}px (post width-filter):`);
  const distByThr = {};
  for (const t of SWEEP_THR) {
    const res = sweepAt(t);
    const bySrc = {};
    for (const { src, runs } of res) (bySrc[src] ??= []).push(runs.length >= 1);
    const bySrcLine = Object.entries(bySrc)
      .map(([src, hits]) => `${src} ${hits.filter(Boolean).length}/${hits.length}`).join("  ");
    const total = res.filter((r) => r.runs.length >= 1).length;
    distByThr[t] = total;
    console.log(`    thr=${String(t).padStart(3)}: ${String(total).padStart(2)}/${res.length} captures show >=1 note run   [${bySrcLine}]`);
  }

  // ASSERT_THR is chosen from the printed distribution above, not guessed —
  // see the item close-out for the measured numbers this value was set from.
  // ⚠️ NOT read out of `distByThr` — the two checks below call `sweepAt`
  // directly at `W.RNOTES.thr` (baseline) and `ASSERT_THR` (elevated), so
  // raising this constant to force a deliberate red (proving the leg CAN
  // fail) can never silently degrade into a missing-key `undefined`
  // comparison the way a `distByThr[ASSERT_THR]` lookup could if the probed
  // value fell outside `SWEEP_THR`.
  //
  // 30 IS MEASURED, NOT GUESSED, AND SITS MID-ZONE, NOT ON AN EDGE — see the
  // sweep printed above (and the item close-out for the numbers): on this
  // fixture 19/19 captures survive at every threshold from 20 through 35, the
  // collapse is UNSTABLE across the whole 38-40 band (three runs measured:
  // 6/19 and 6/19 at 38, 6/19 and 5/19 at 40 — the exact count wobbles run to
  // run in that band, which is itself a reason NOT to assert anywhere near
  // it), and it is total and STABLE by 50 (0/19, every run). 30 is squarely
  // inside the confirmed-100%-survival zone — 10 below the last point still
  // measured at 100% (35) and a further margin below where the unstable band
  // starts (35→38) — so this is not a borderline pick riding the cliff. It is
  // also the exact value the m23-gy item itself names ("note bodies survive
  // thr=30"), so the assertion directly defends the claim in the item rather
  // than a nearby one.
  const ASSERT_THR = 30;
  const baseline = sweepAt(W.RNOTES.thr);              // the SHIPPED threshold (20 today)
  const elevated = sweepAt(ASSERT_THR);
  const baselineHits = baseline.filter((r) => r.runs.length >= 1).length;
  const elevatedHits = elevated.filter((r) => r.runs.length >= 1).length;
  const elevatedSpans = elevated.flatMap((r) => r.runs.map(runSpan));
  const minElevatedSpan = elevatedSpans.length ? Math.min(...elevatedSpans) : null;
  console.log(`  GY baseline (thr=${W.RNOTES.thr}, shipped): ${baselineHits}/${gySources.length} captures | ` +
    `elevated (thr=${ASSERT_THR}): ${elevatedHits}/${gySources.length}, narrowest surviving run span ${minElevatedSpan}px`);
  check("GY precondition (anti-vacuity): the SHIPPED threshold (RNOTES.thr=20) actually detects note bodies in these captures — otherwise the elevated-threshold margin below would be comparing against nothing and would prove nothing",
        baselineHits === gySources.length,
        `baseline thr=${W.RNOTES.thr}: ${baselineHits}/${gySources.length} captures show >=1 note run — full sweep ${JSON.stringify(distByThr)}`);
  check("GY: RNOTES note-BODY margin, asserted DIRECTLY — note runs (already width-filtered; NOT the m23-gt width filter under test elsewhere) still survive well above the shipped thr=20 and are still full-width bodies, not slivers, so a real threshold loss reddens HERE, by name, instead of masquerading as the width filter (PLAYHEAD_MAX_SPAN, line ~237) eating a note in the L5 anti-vacuity legs above",
        elevatedHits === baselineHits && elevatedHits === gySources.length &&
        minElevatedSpan !== null && minElevatedSpan > PLAYHEAD_MAX_SPAN * 4,
        `thr=${ASSERT_THR} vs shipped thr=${W.RNOTES.thr}: ${elevatedHits}/${gySources.length} captures still show >=1 note run ` +
        `(baseline ${baselineHits}/${gySources.length}), narrowest surviving run ${minElevatedSpan}px wide ` +
        `(width-filter floor is PLAYHEAD_MAX_SPAN=${PLAYHEAD_MAX_SPAN}px — if THIS reddens instead, the loss is in RNOTES.thr, not in the width filter) — full sweep ${JSON.stringify(distByThr)}`);
}

// ── m23-bl: WHICH LEGS DEPEND ON "L6: the old process is gone" (:1479-ish), AND WHY ──
// The roadmap item that filed this said "three later passes" ride over that
// precondition — MEASURED, the real answer is FOUR, because the rule applied
// below is "does this check's CONCLUSION become false if the precondition
// failed", which is BROADER than "does this check's mechanism read the bad
// channel". If A (the pre-relaunch process) still holds port 17695 when B is
// spawned, B can fail to bind and die, and `connect()` a few lines later can
// silently land back on A. Every one of these four then either reads A's
// state or asserts something about a B that never really came up, so each
// one's CONCLUSION — not just its plumbing — stops being trustworthy:
//   - "the pidfile now names the RELAUNCHED process, so teardown can reach
//     it" — false if B died: the pidfile names a pid nothing is listening on,
//     and teardown cannot "reach" it in any sense that matters.
//   - "the process really did change" — the PIDs genuinely differ (A's vs
//     B's — that part is real), but a pid diff alone does not establish that
//     the SOCKET a few lines later is actually talking to B rather than A.
//   - "the follow preference SURVIVED the relaunch" — THE FALSE PASS THIS
//     ITEM WAS FILED ABOUT. If the reconnect landed on A, this reads A's
//     still-live in-memory preference, which no relaunch ever touched.
//   - "the shipped default (OFF) is restored before the gate exits" — writes
//     the restore to whichever process is on the other end of the socket. If
//     that is A, B's real preference is left untouched and unverified, and
//     this check certifies a restoration that happened in the wrong process.
// "L6 (setup) follow is ON before the relaunch" is NOT a dependent — it runs and
// is asserted BEFORE `process.kill(oldPid)`, so the kill cannot have invalidated
// it. ⭐ BUT IT IS ITSELF A SECOND PRECONDITION, and missing that was a real gap:
// the m23-bl brief originally marked only the process-gone check. If the setter
// silently failed and follow was never ON, then "the follow preference SURVIVED
// the relaunch" is unfounded whichever way it lands — PASS would be inexplicable,
// and FAIL would blame PERSISTENCE for what is actually a broken SETTER, sending
// the reader to the wrong mechanism. That is the same defect m23-bl was filed
// about, one leg upstream. So it carries `id: "L6-setup-follow-on"`, and the
// survival leg requires BOTH ids — which is why `requires:` accepts an array.
// ⭐ THE GENERAL RULE THIS CAME FROM: a claim resting on N preconditions must
// name all N. Marking only the one you happened to notice leaves the others
// still able to certify a conclusion they cannot support. This second one was
// found by the corpus sweep, not by reading Leg 6 again — the sweep paid for
// itself on the very gate that motivated it.
// ═══ LEG 6 — persistence across a REAL process relaunch ════════════════════
console.log("\n── PERSISTENCE ACROSS A RELAUNCH");
{
  await req("debug.panelLayout", { followPlayhead: true });
  const before = await req("debug.panelLayout", {});
  const oldPid = Number(fs.readFileSync(PIDFILE, "utf8").trim());
  check("L6 (setup) follow is ON before the relaunch", before.followPlayhead === true, JSON.stringify(before),
        { id: "L6-setup-follow-on" });
  ws.close();
  process.kill(oldPid);            // pidfile-EXACT; never pkill/pgrep
  await sleep(2500);
  let stillUp = true;
  try { process.kill(oldPid, 0); } catch { stillUp = false; }
  check("L6: the old process is gone", stillUp === false, `pid ${oldPid}`,
        { id: "L6-old-process-gone" });
  // We killed A outside the harness, so nothing released A's session.lock. This
  // is a no-op unless the lock is PROVABLY A's (strict typeof + pid equality),
  // so it can never delete a real crash-recovery lock in the user's profile.
  // ⚠️ m23-ay: A's lock is under the STAGING PROFILE ROOT, not in the user's
  // Autosave directory. Passing the path explicitly is what keeps this call
  // effective — with the default it would look in the user's profile, find
  // nothing of A's, and silently leave A's real lock behind in the staging root.
  releaseSessionLock(oldPid, stagingSessionLockPath(stagingProfileRoot()));
  const log = fs.openSync(`${OUT}/relaunch.log`, "a");
  // m23-gf-b: B must come up through the SAME DAWProStaging alias A did, or B
  // runs bare-binary-named and its UserDefaults land back in the user's real
  // DAWApp domain — the good failure mode (design F4: fails LOUD, because L6
  // below then reads a DIFFERENT domain and followPlayhead comes back false).
  // `stagingBinaryAlias` is idempotent/re-verifying, so calling it a second
  // time here (A's own `startStaging` already created it) is safe and cheap.
  const child = spawn(stagingBinaryAlias(BINARY, REPO), [], {
    cwd: REPO, detached: true, stdio: ["ignore", log, log],
    // ⚠️ THE ONE HAND-ROLLED LAUNCH IN THE WHOLE GATE CORPUS (m23-ay). Every
    // other staging process comes from `startStaging`, which sets this variable
    // itself; B is spawned here directly, so without this line B — and only B —
    // would resolve its profile to the USER'S OWN
    // ~/Library/Application Support/DAWPro/ and write a session.lock there.
    // `stagingProfileRoot()` is memoised per process, so B inherits exactly A's
    // root, which is also what makes this leg a real relaunch of the same
    // session rather than a fresh install.
    //
    // ⛔⛔ F9 PROHIBITION (m23-gf-b, design §6 F9) — DO NOT "clean up" this hand
    // rolled spawn by refactoring Leg 6 to call `startStaging` instead. That
    // function's `resetStagingDefaultsDomain()` would CLEAR the very
    // `followPlayhead` value this leg exists to prove survived a relaunch —
    // it is memoised ONCE PER NODE PROCESS, so A's own earlier `startStaging`
    // call already consumed that memo and a naive read of the code makes the
    // reset look like a no-op here. It is not a no-op if this call is ever
    // changed to route through `startStaging`: on a FRESH process (this gate
    // run alone, or a future refactor that resets the memo between legs) it
    // would wipe L6's assertion for the wrong reason, or turn a real
    // regression into a green run. Keep this launch hand-rolled.
    env: {
      ...process.env,
      DAW_CONTROL_PORT: String(PORT),
      [PROFILE_ROOT_ENV]: stagingProfileRoot(),
    },
  });
  child.unref();
  fs.writeFileSync(PIDFILE, String(child.pid));
  // ⚠️ LINK 2 OF THE TEARDOWN CHAIN, ASSERTED RATHER THAN INFERRED (m23-ac-3e-3).
  // startStaging writes A here; this leg kills A and must leave B here; stopStaging
  // and armTeardown both RE-READ this file to kill B. If the write above ever
  // landed somewhere else — a surviving env override, a second spelling of the
  // path — B would outlive the gate as a real orphan on the staging port, and the
  // usual "0 orphans" reading would report 1 without saying why. Read it back.
  const written = Number(fs.readFileSync(PIDFILE, "utf8").trim());
  check("L6: the pidfile now names the RELAUNCHED process, so teardown can reach it",
        written === child.pid, `pidfile ${PIDFILE} holds ${written}, spawned ${child.pid}`,
        { requires: "L6-old-process-gone" });
  await sleep(4000);
  ({ ws, req } = await connect());
  const after = await req("debug.panelLayout", {});
  console.log(`  pid ${oldPid} → ${child.pid}; followPlayhead after relaunch = ${after.followPlayhead}`);
  check("L6: the process really did change (a single-session capture proves nothing)",
        child.pid !== oldPid, `${oldPid} → ${child.pid}`,
        { requires: "L6-old-process-gone" });
  check("L6: the follow preference SURVIVED the relaunch (default is OFF, so this cannot be a default)",
        after.followPlayhead === true, JSON.stringify(after),
        { requires: ["L6-old-process-gone", "L6-setup-follow-on"] });
  // Restore the SHIPPED default before leaving: this store writes through to
  // UserDefaults.standard, which staging shares with the user's own app.
  await req("debug.panelLayout", { followPlayhead: false });
  const restored = await req("debug.panelLayout", {});
  check("L6: the shipped default (OFF) is restored before the gate exits",
        restored.followPlayhead === false, JSON.stringify(restored),
        { requires: "L6-old-process-gone" });
}
// Every `requires:` used above must resolve — see the function's own comment
// for why this must throw rather than warn. Called once, here, after the
// very last check() call in the file.
validateRequiresOrThrow();

console.log("\n=== GATE ===");
let failed = 0;
let unknownCount = 0;
for (const c of checks) {
  const label = c.outcome === "UNKNOWN" ? "UNKN" : (c.outcome === "PASS" ? "PASS" : "FAIL");
  if (c.outcome === "FAIL") failed++;
  else if (c.outcome === "UNKNOWN") unknownCount++;
  console.log(`${label}  ${c.name}\n        ${c.detail}`);
}
if (unknownCount > 0) {
  // m23-bl: UNKNOWN is reporting honesty, not a new exit code — the precondition
  // that produced it already failed, so `failed > 0` here regardless.
  console.log(`\n${unknownCount} check(s) UNKNOWN — outcome undetermined because a ` +
    `precondition they depend on failed; see the UNKN lines above for which ` +
    `precondition invalidated each one.`);
}
fs.writeFileSync(`${OUT}/gate.json`, JSON.stringify({ checks }, null, 2));
// UNKNOWN checks count toward neither `ran` nor `failed` — they produced no
// real PASS/FAIL verdict, so folding them into either count would misreport
// what this run actually established. `verdict()` still sees `failed <= ran`
// because the precondition itself is a real, counted FAIL whenever any
// dependent goes UNKNOWN.
const ran = checks.length - unknownCount;
console.log(`\n${ran - failed}/${ran} checks passed` +
  (unknownCount > 0 ? ` (${unknownCount} UNKNOWN excluded from ran)` : ""));
// m23-ei: put the two sticky zoom slots back before the process we are talking
// to goes away. MUST precede stopStaging — after it there is nobody to ask.
await restoreZoomSlots("normal exit");
await guard.restore("normal exit");   // m23-ej-2: same rule, pianoRoll density
// Link 3: re-reads the pidfile, so this SIGTERMs the RELAUNCHED process (B),
// not the one startStaging launched. Also releases B's session.lock.
stopStaging(GATE);
clearTimeout(killer); ws.close(); verdict({ ran, failed });
