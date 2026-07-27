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
//   swiftc -O -o /tmp/m23c2-probe scripts/probes/m23c1-cyan-column-probe.swift
//   M23C2_PROBE=/tmp/m23c2-probe M23C2_OUT=/tmp/m23c2 \
//     M23C2_PIDFILE=/tmp/staging.pid node scripts/gates/m23c2-follow-playhead.mjs
//
// Staging port 17695 only — 17600 is the user's live app.
import fs from "fs";
import { execFileSync, spawn } from "child_process";

const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23C2_OUT || "/tmp/m23c2";
const PROBE = process.env.M23C2_PROBE || "/tmp/m23c2-probe";
const PIDFILE = process.env.M23C2_PIDFILE || "/tmp/m23c2-staging.pid";
const BINARY = process.env.M23C2_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23C2_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 900_000);
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
const W = {
  ARULER:  { x: 620, y: 280,  w: 2150, h: 80,  thr: 20 },
  ALANE:   { x: 800, y: 380,  w: 1970, h: 100, thr: 8 },
  RGRID:   { x: 140, y: 1350, w: 2635, h: 150, thr: 20 },
  RNOTES:  { x: 140, y: 1275, w: 2635, h: 34,  thr: 20 },
  RVEL:    { x: 140, y: 1570, w: 2635, h: 100, thr: 20 },
  RGUTTER: { x: 30,  y: 840,  w: 95,   h: 680, thr: 20 },
  RCTRL:   { x: 140, y: 1745, w: 2635, h: 80,  thr: 20 },
};
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

let { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => { checks.push({ name, ok, detail }); if (!ok) console.log(`   !! ${name} — ${detail}`); };

// ── fixture ───────────────────────────────────────────────────────────────
const PPB = 100, CLIP_BEATS = 128, CLIP2_AT = 200;
async function buildFixture() {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  await req("debug.panelDensity", { panel: "pianoRoll", mode: "pro" });
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
const { clipId, clip2Id } = await buildFixture();
console.log(`fixture: clip1 @0 len ${CLIP_BEATS}, clip2 @${CLIP2_AT} len ${CLIP_BEATS}, ${PPB} pt/beat`);

// Open the editor once; later captures keep it open without re-selecting (a
// re-select would be an edit-state change in the middle of a measurement).
await req("debug.captureUI", { path: `${OUT}/open-editor.png`, selectClip: clipId });
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
  check("L1 arrange: the surface actually SCROLLED (several distinct offsets)",
        new Set(s.map((x) => x.follow.arrange.offset)).size >= 3,
        [...new Set(s.map((x) => x.follow.arrange.offset))].join(","));
  check("L1 roll: the playhead is in frame in EVERY sample (note-free grid crop)",
        s.every((x) => lineX(x.rGrid) != null),
        s.map((x) => (lineX(x.rGrid) ?? "GONE")).join(" "));
  check("L1 roll: the VELOCITY lane shows the playhead at the SAME x as the grid (m23-c1 two-bands law)",
        s.every((x) => covers(x.rVel, lineX(x.rGrid))),
        s.map((x) => `${lineX(x.rGrid)}∈[${x.rVel.runs}]`).join(" "));
  check("L1 roll: the surface actually SCROLLED (several distinct offsets)",
        new Set(s.map((x) => x.follow.pianoRoll.offset)).size >= 3,
        [...new Set(s.map((x) => x.follow.pianoRoll.offset))].join(","));
  check("L1 roll: the NON-FOLLOWED (vertical) axis holds — the keyboard gutter is byte-identical throughout",
        new Set(s.map((x) => x.rGutter.sha)).size === 1,
        [...new Set(s.map((x) => x.rGutter.sha))].join(","));
  // PAGE, not per-tick: ~15 s at 120 bpm is 30 beats = 3000 pt, under 3 arrange
  // viewports and under 3 roll viewports. A continuous policy would have issued
  // hundreds (measured: 262 over 8 bars — see FollowPlayhead's doc table).
  check("L1 arrange: PAGE policy — a handful of scrolls, not one per transport tick",
        on.end.arrange.scrolls >= 2 && on.end.arrange.scrolls <= 12, `${on.end.arrange.scrolls}`);
  check("L1 roll: PAGE policy — a handful of scrolls, not one per transport tick",
        on.end.pianoRoll.scrolls >= 2 && on.end.pianoRoll.scrolls <= 12, `${on.end.pianoRoll.scrolls}`);
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

// ═══ LEG 2 — follow OFF: the same playback moves nothing ═══════════════════
const off = await playAndSample("off", { enabled: false });
report("FOLLOW OFF", off);
{
  const s = off.samples;
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
  const starts0 = notes0.runList.map(([a]) => a);
  console.log(`  parked: risers ${risers0} vs note starts ${starts0}`);
  check("L5 (ground truth): at offset 0 every CC riser sits on a note start",
        risers0.length >= 3 && risers0.every((c) => starts0.some((s) => Math.abs(c - s) <= 3)),
        `risers ${risers0} vs starts ${starts0}`);

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
  const starts1 = notes1.runList.map(([a]) => a);
  console.log(`  paged @${rollOffset}: risers ${risers1} vs note starts ${starts1}`);
  check("L5: follow paged the roll under playback", rollOffset > 800, `offset ${rollOffset}`);
  check("L5: the CTRL band MOVED — its ink is not where it was at offset 0",
        ctrl0.sha !== ctrl1.sha, `${ctrl0.sha} vs ${ctrl1.sha}`);
  check("L5: LOCKSTEP — after the page the risers are STILL on the note starts",
        risers1.length >= 2 && risers1.every((c) => starts1.some((s) => Math.abs(c - s) <= 3)),
        `risers ${risers1} vs starts ${starts1}`);
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
}

// ═══ LEG 6 — persistence across a REAL process relaunch ════════════════════
console.log("\n── PERSISTENCE ACROSS A RELAUNCH");
{
  await req("debug.panelLayout", { followPlayhead: true });
  const before = await req("debug.panelLayout", {});
  const oldPid = Number(fs.readFileSync(PIDFILE, "utf8").trim());
  check("L6 (setup) follow is ON before the relaunch", before.followPlayhead === true, JSON.stringify(before));
  ws.close();
  process.kill(oldPid);            // pidfile-EXACT; never pkill/pgrep
  await sleep(2500);
  let stillUp = true;
  try { process.kill(oldPid, 0); } catch { stillUp = false; }
  check("L6: the old process is gone", stillUp === false, `pid ${oldPid}`);
  const log = fs.openSync(`${OUT}/relaunch.log`, "a");
  const child = spawn(BINARY, [], {
    cwd: REPO, detached: true, stdio: ["ignore", log, log],
    env: { ...process.env, DAW_CONTROL_PORT: PORT },
  });
  child.unref();
  fs.writeFileSync(PIDFILE, String(child.pid));
  await sleep(4000);
  ({ ws, req } = await connect());
  const after = await req("debug.panelLayout", {});
  console.log(`  pid ${oldPid} → ${child.pid}; followPlayhead after relaunch = ${after.followPlayhead}`);
  check("L6: the process really did change (a single-session capture proves nothing)",
        child.pid !== oldPid, `${oldPid} → ${child.pid}`);
  check("L6: the follow preference SURVIVED the relaunch (default is OFF, so this cannot be a default)",
        after.followPlayhead === true, JSON.stringify(after));
  // Restore the SHIPPED default before leaving: this store writes through to
  // UserDefaults.standard, which staging shares with the user's own app.
  await req("debug.panelLayout", { followPlayhead: false });
  const restored = await req("debug.panelLayout", {});
  check("L6: the shipped default (OFF) is restored before the gate exits",
        restored.followPlayhead === false, JSON.stringify(restored));
}

console.log("\n=== GATE ===");
let failed = 0;
for (const c of checks) {
  if (!c.ok) failed++;
  console.log(`${c.ok ? "PASS" : "FAIL"}  ${c.name}\n        ${c.detail}`);
}
fs.writeFileSync(`${OUT}/gate.json`, JSON.stringify({ checks }, null, 2));
console.log(`\n${checks.length - failed}/${checks.length} checks passed`);
clearTimeout(killer); ws.close(); process.exit(failed === 0 ? 0 : 1);
