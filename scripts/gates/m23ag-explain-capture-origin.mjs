// m23-ag GATE — `debug.explainFrames` and `debug.captureUI` DO NOT SHARE A
// COORDINATE SPACE (docs/ROADMAP.md m23-ag). Before this cycle a pixel gate that
// placed a crop box off a reported explain frame's Y silently measured the wrong
// rows and reported a confident FALSE NEGATIVE — the m23-v gate hit this for real:
// four crop boxes landed on the pinned ruler's bar-number strip, whose pixels are
// identical whether the feature under test is shown or suppressed, and it read
// exactly like "not drawn". m23-ag made both payloads self-describing so a
// consumer CONVERTS instead of assuming:
//
//   debug.explainFrames  -> also returns captureOrigin {x,y} (explain-space origin
//                            in captureUI's space, POINTS, top-left) and
//                            captureSize {width,height} (contentView.bounds size,
//                            POINTS). Both explicitly null when no window hosts the
//                            explain root.
//   debug.captureUI      -> also returns rect {x,y,width,height} (points) and scale.
//   conversion: contentPoint = frame.origin + captureOrigin
//               scale        = png.height / captureSize.height
//
// Single origin definition: Sources/DAWApp/Components/Explain.swift:107
// (`ExplainSpaceAnchor.captureGeometry(in:)`); pure arithmetic in
// Sources/DAWAppKit/CaptureSpaceGeometry.swift. This gate does not re-derive
// either — it exercises the WIRE, against a real running app.
//
// THIS GATE'S CONSTRUCTION (mine, independent of the implementer's own ink-based
// verification): place crop boxes STRAIGHT off `frame.origin + captureOrigin` — no
// derivation, no search, no hand correction — and ask whether a change confined to
// that surface shows up inside them. The red arm is the strongest one available
// and costs nothing: run the SAME box with the origin OMITTED, i.e. exactly what a
// consumer did before this cycle. It must find nothing. That single pair is
// simultaneously the proof the fix works and the proof the defect was real.
//
//   L1/L2  mixerMute (18x18)     : toggle mute -> the box at frame+origin sees it;
//                                   the SAME box at frame ALONE is blind.      [L2 RED]
//   L3/L4  arrangePlayhead lane2 : add a clip on LANE 2 -> the box at
//                                   frame+origin+2*lanePitch sees it; without the
//                                   origin it lands in the EMPTY lane 1 and is
//                                   blind — a confident false negative.        [L4 RED]
//   L5     captureUI.rect/scale present and self-consistent with the PNG.
//   L6     captureSize matches the size debug.windowFrame ACTUALLY applied (the
//          floor clamps a requested 1200 to 1208 — never the requested size).
//   L7/L8  transportLoop (BOTTOM-anchored) : toggle loop -> box at frame+origin
//                                   sees it; without the origin, blind.        [L8 RED]
//          L7/L8 are what make the SECOND window size mean anything: L1-L4 read
//          TOP-anchored pixels that do not move when the window resizes, so
//          re-running them at another size reads byte-identical luma and proves
//          nothing. transportLoop's frame is bottom-anchored, so its reported y
//          genuinely moves between sizes and the conversion is re-exercised for
//          real.
//   L9/L9b ink-derived origin cross-check (NEW — the filing's ninth leg). L1/L3/L7
//          already redden if the origin diverges, but only as "no ink found where
//          expected", which reads exactly like a broken fixture. This leg instead
//          STATES the divergence directly, independent of any box placement: it
//          differences ONE narrow content-point column between a capture with the
//          playhead at beat A and one at beat B — everything static in that column
//          (the beat grid, bar numbers, lane backgrounds) is literally the same
//          pixel in both shots and cancels exactly; only the playhead's own ink
//          (present in A, absent at that column in B) survives. Because the column
//          runs the FULL window height, it crosses BOTH places the playhead is
//          drawn: the pinned ruler block (its own TimelineLanesView instance,
//          height == rulerHeight 80 — TimelineLanesView.swift:401) and,
//          arrangeBlockGap (6, ContentView.swift:40) below it, the lanes block —
//          two separate views, two separate ink runs. The lanes run's top is the
//          lanes' TRUE capture-space Y, located from pixels alone; L9b asserts
//          `arrangePlayhead.frame.y + captureOrigin.y` against THAT, never against
//          a literal (hardcoding the ~32pt offset is precisely how this class of
//          defect returns wearing a different hat — see the roadmap entry).
//          ⚠️ LIKE L1-L4, L9/L9b are TOP-anchored: the ruler+lanes vertical origin
//          does not move when the window is resized (only its visible BOTTOM
//          extent does), so at 1320x880 this leg locates the identical ink runs
//          and reports the identical 0.00 pt error it did at 1400x1000 — MEASURED,
//          not assumed (see the two size blocks below print byte-identical `runs`).
//          It is L7/L8, not L9/L9b, that makes the second size mean something for
//          the origin's Y — this leg's real job is being independent of L1-L8's
//          box-placement machinery entirely, not of window size.
//
// Everything above runs at TWO content sizes: 1400x1000 and 1320x880 (both above
// the 1208x640 WindowFloor). The second size is the should-stay-green arm for the
// BOTTOM-anchored legs (L7/L8); the top-anchored legs (L1-L4, L9/L9b) re-run there
// too but, correctly, measure the same thing twice.
//
// MEASURED (real run against staging, 2026-08-02): tally 20/20 (10 checks x 2
// sizes: L6, L5, L9, L9b, L1, L2, L3, L4, L7, L8). L9b: predicted 163.00 + 32.00 =
// 195.00, ink-located lanes top 195.00, error 0.00 pt, at BOTH sizes. RED-BASELINE
// (same date): with captureOrigin zeroed in the corrected legs, tally 12/20 — L9b,
// L1, L3, L7 fail at both sizes (8 legs), L9b's error reads 32.00 pt (predicted
// 163.00 vs ink 195.00 — the real, not a stub, divergence); L2/L4/L8 do not
// "go green from red" (they were already the passing blind-arm) — they instead
// CONVERGE with L1/L3/L7, reading the identical box and the identical delta, because
// zeroing the origin makes the "corrected" and "uncorrected" boxes the same box. The
// red-baseline mutation was applied, run, then reverted byte-exact (sha256-verified)
// BEFORE this header was written. Per-leg numbers are also recorded next to each
// check() call below, from the same real run — this header states the shape, the
// live output remains the source of truth for drift.
//
// Staging port 17695 ONLY — 17600 is the user's LIVE app and is never touched.
// Kill is pidfile-EXACT (`_staging.mjs`), never pkill/pgrep. Nothing written to
// the tree; every command used is `debug.*`/`transport.*`/`track.*`/`clip.*`
// against a throwaway staging project (`project.new {discardChanges:true}`).
//
// Usage:
//   node scripts/gates/m23ag-explain-capture-origin.mjs
// Env: M23AG_SKIP_BUILD=1 to reuse .build/debug/DAWApp (only safe immediately
// after a build of the tree under test — a gate that launches a prebuilt binary
// tests the PREVIOUS build).
import fs from "fs";
import { execFileSync } from "child_process";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23ag";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23AG_OUT || "/tmp/m23ag";
const PIDFILE = process.env.M23AG_PIDFILE || "/tmp/m23ag-staging.pid";
const BINARY = process.env.M23AG_BINARY || ".build/debug/DAWApp";
const PROBE = process.env.M23AG_PROBE || "/tmp/m23v-probe"; // shared with m23v — same probe, same contract
const REPO = process.env.M23AG_REPO || "/Users/dsemenov/Views/daw-pro";
const PPB = 16, ROW_H = 50, LANE_SPACING = 6, LANE_PITCH = ROW_H + LANE_SPACING;
const RULER_HEIGHT = 80;       // TimelineLanesView.swift:401 — a layout constant,
                                // unrelated to the capture-origin bug; pinning it
                                // is legitimate (only captureOrigin must never be
                                // a literal).
const ARRANGE_BLOCK_GAP = 6;   // ContentView.swift:40 — ditto.
const SETTLE = 500;
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);

// ── build, so the gate cannot test the previous build ─────────────────────
buildOrAbort({ root: REPO, skip: !!process.env.M23AG_SKIP_BUILD });
if (!fs.existsSync(PROBE)) {
  console.log("compiling the box/row probe…");
  execFileSync("swiftc", ["-O", "-o", PROBE, "scripts/probes/m23g1-clip-box-probe.swift"],
               { cwd: REPO, stdio: "inherit" });
}

// ── launch staging (pidfile-EXACT teardown of any previous run) ───────────
const staging = startStaging({ gate: GATE, root: REPO, port: PORT,
  binary: BINARY, detached: true, pidfile: PIDFILE, outDir: OUT });
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4000);

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
const { ws, req } = await connect();

const results = [];
const check = (n, ok, d) => { results.push({ n, ok, d }); console.log(`  ${ok ? "ok  " : "!!  "} ${n}\n        ${d}`); };

function boxes(png, specs) {
  const args = ["boxes", png, OUT, ...specs.map((s) => `${s.label}:${Math.round(s.x)},${Math.round(s.y)},${Math.round(s.w)},${Math.round(s.h)}`)];
  const raw = execFileSync(PROBE, args).toString().trim().split("\n");
  const out = {};
  for (const line of raw) {
    const m = line.match(/^(\S+) dims=(\d+)x(\d+) mean=([\d.,]+) luma=([\d.]+) sha=(\w+)$/);
    if (!m) throw new Error(`unparsed probe line: ${line}`);
    out[m[1]] = { luma: +m[5], sha: m[6] };
  }
  return out;
}

/// Per-row mean luma over an x window, through the probe's `rows` mode. Returns a
/// Map of capture-row (pixels) -> luma. The probe DIES on an out-of-bounds window
/// rather than silently returning nothing (the m23-c1 false-negative mode).
function rowProfile(png, x, w, y0, h) {
  const raw = execFileSync(PROBE, ["rows", png, String(x), String(w), String(y0), String(h)])
    .toString().trim().split("\n");
  const out = new Map();
  for (const line of raw) {
    const [y, luma] = line.split(" ");
    out.set(Number(y), Number(luma));
  }
  return out;
}

/// Contiguous rows whose |delta| clears `thresh`, each with its top/bottom/height/peak.
function inkRuns(delta, thresh) {
  const runs = [];
  let cur = null;
  for (const { y, d } of delta) {
    if (d > thresh) {
      if (!cur) cur = { top: y, bottom: y, peak: d };
      else { cur.bottom = y; cur.peak = Math.max(cur.peak, d); }
    } else if (cur) { runs.push(cur); cur = null; }
  }
  if (cur) runs.push(cur);
  return runs.map((r) => ({ ...r, height: r.bottom - r.top + 1 }));
}

let capSeq = 0;
async function capture(tag) {
  const path = `${OUT}/${tag}-${capSeq++}.png`;
  const r = await req("debug.captureUI", { path });
  return { path, ...r };
}

async function frames(ids) {
  await req("debug.explainMode", { on: true });
  await sleep(SETTLE);
  const ef = await req("debug.explainFrames", { ids });
  await req("debug.explainMode", { on: false });
  await sleep(SETTLE);
  return ef;
}

const DELTA_MIN = 1.5;   // a real colour change on a small box is many luma points
const DELTA_MAX_NULL = 0.4;
const INK_RUN_THRESH = 3.0;      // per-row |delta| that counts as playhead ink
                                  // (same order as m23v's RUN_THRESH — far above
                                  // antialiasing residue, far below the expected
                                  // playhead-vs-background jump)

async function sizeRun(reqW, reqH, tag, tracks) {
  const wf = await req("debug.windowFrame", { width: reqW, height: reqH });
  await sleep(SETTLE);
  console.log(`\n════════ content ${wf.width}x${wf.height} (requested ${reqW}x${reqH}) ════════`);
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await req("debug.arrangePointer", { act: "clear" });
  await req("transport.seek", { beats: 60 });        // playhead far from every box
  await sleep(SETTLE);

  const ef = await frames(["arrangePlayhead", "mixerMute"]);
  const org = ef.captureOrigin, size = ef.captureSize;
  console.log(`captureOrigin=${JSON.stringify(org)} captureSize=${JSON.stringify(size)}`);
  check(`${tag} L6 captureSize matches the content size debug.windowFrame ACTUALLY applied `
        + `(not the requested one — the floor clamps 1200 to 1208)`,
        size && size.width === wf.width && size.height === wf.height,
        `payload ${JSON.stringify(size)} vs windowFrame ${wf.width}x${wf.height}`);

  const shot = await capture(`${tag}-probe`);
  const scale = shot.rect ? shot.height / shot.rect.height : null;
  check(`${tag} L5 captureUI reports the rect it rasterised and a scale consistent with the PNG`,
        !!shot.rect && shot.scale === scale && shot.rect.width === size.width && shot.rect.height === size.height,
        `rect=${JSON.stringify(shot.rect)} scale=${shot.scale} png=${shot.width}x${shot.height} derived=${scale}`);

  const S = scale ?? 2;
  const mute = (ef.frames?.mixerMute ?? [])[0];
  const lanes = (ef.frames?.arrangePlayhead ?? [])[0];
  if (!mute || !lanes) { check(`${tag} frames present`, false, JSON.stringify(ef.frames)); return; }

  // ── L9/L9b ink-derived origin cross-check (the filing's ninth leg) ──────
  // See the file header for the full construction. beatA is placed well inside
  // the visible lanes viewport (55% of its reported width, so it never depends on
  // a hardcoded beat that might sit off-screen at the smaller window size);
  // beatB is far left and, at any window size this gate drives, hundreds of
  // points away from beatA — far more than COL_HALF, so the two playhead
  // positions never share a pixel of the sampled column.
  const beatA = Math.max(5, Math.floor((lanes.width * 0.55) / PPB));
  const beatB = 2;
  const COL_HALF = 10;   // pt each side of the line — covers the 1.5pt stroke
                          // (TimelineLanesView.swift `playhead`) plus its 5pt glow
                          // radius with margin, narrower than one beat (16pt) so it
                          // cannot straddle a neighbouring hairline differently
                          // between the two frames.

  await req("transport.seek", { beats: beatA });
  await sleep(SETTLE);
  const inkA = await capture(`${tag}-ink-a`);
  await req("transport.seek", { beats: beatB });
  await sleep(SETTLE);
  const inkB = await capture(`${tag}-ink-b`);
  await req("transport.seek", { beats: 60 });   // restore — subsequent legs assume this
  await sleep(SETTLE);

  const colX = Math.round((lanes.x + org.x + beatA * PPB - COL_HALF) * S);
  const colW = Math.round(COL_HALF * 2 * S);
  const sweepH = Math.min(inkA.height, inkB.height);   // the PNGs' OWN height, never a
                                                        // computed size*scale — a mismatch
                                                        // between two independently-timed
                                                        // reads must not crash the probe
  const profA = rowProfile(inkA.path, colX, colW, 0, sweepH);
  const profB = rowProfile(inkB.path, colX, colW, 0, sweepH);
  const delta = [];
  for (const [y, v] of profA) delta.push({ y, d: Math.abs(v - (profB.get(y) ?? 0)) });
  delta.sort((a, b) => a.y - b.y);
  const runs = inkRuns(delta, INK_RUN_THRESH);

  // Identify the two runs STRUCTURALLY, never by array index (a stray third run
  // anywhere above the ruler would silently relabel runs[0]/runs[1]):
  //   ruler run  = the one whose height matches rulerHeight (80), generously banded
  //   lanes run  = the one whose top sits arrangeBlockGap (6) below the ruler run's
  //                bottom — anchored off the ruler run, not off a row index.
  const ruler = runs.find((r) => r.height >= 0.6 * RULER_HEIGHT * S && r.height <= 1.3 * RULER_HEIGHT * S);
  const lanesRun = ruler && runs.find((r) =>
    r.top >= ruler.bottom && Math.abs(r.top - (ruler.bottom + ARRANGE_BLOCK_GAP * S)) <= 4 * S);

  check(`${tag} L9 differencing ONE column across a playhead move (beat ${beatA} -> `
        + `${beatB}) structurally locates two ink runs — the ruler playhead `
        + `(height ≈ rulerHeight ${RULER_HEIGHT}) and, arrangeBlockGap `
        + `(${ARRANGE_BLOCK_GAP}) below it, the lanes playhead — with no box and no `
        + `hand-derived correction`,
        !!ruler && !!lanesRun,
        `runs=${JSON.stringify(runs)} ruler=${JSON.stringify(ruler)} lanes=${JSON.stringify(lanesRun)}`);

  if (lanesRun) {
    const lanesTopPt = lanesRun.top / S;
    const predicted = lanes.y + org.y;
    const err = Math.abs(lanesTopPt - predicted);
    check(`${tag} L9b arrangePlayhead.frame.y (${lanes.y}) + captureOrigin.y (${org.y}) `
          + `= ${predicted.toFixed(2)} matches the INK-LOCATED lanes-run top `
          + `${lanesTopPt.toFixed(2)} within ±2 pt — asserted against MEASURED `
          + `ink, never against a literal (hardcoding the offset is exactly how this `
          + `defect returns)`,
          err <= 2, `predicted=${predicted.toFixed(2)} ink=${lanesTopPt.toFixed(2)} err=${err.toFixed(2)}`);
  } else {
    check(`${tag} L9b arrangePlayhead conversion vs ink`, false,
          "could not structurally locate the lanes ink run — see L9's runs dump");
  }

  // ── L1/L2 mixerMute: a colour change confined to an 18x18 button ────────
  const muteBox = (useOrigin) => ({
    x: (mute.x + (useOrigin ? org.x : 0)) * S,
    y: (mute.y + (useOrigin ? org.y : 0)) * S,
    w: mute.width * S, h: mute.height * S,
  });
  const before = await capture(`${tag}-mute-off`);
  await req("track.setMute", { trackId: tracks[0], muted: true });
  await sleep(SETTLE);
  const after = await capture(`${tag}-mute-on`);
  await req("track.setMute", { trackId: tracks[0], muted: false });
  await sleep(SETTLE);

  const mkC = boxes(before.path, [{ label: "c", ...muteBox(true) }]).c;
  const mkC2 = boxes(after.path, [{ label: "c", ...muteBox(true) }]).c;
  const mkU = boxes(before.path, [{ label: "u", ...muteBox(false) }]).u;
  const mkU2 = boxes(after.path, [{ label: "u", ...muteBox(false) }]).u;
  const dC = Math.abs(mkC2.luma - mkC.luma), dU = Math.abs(mkU2.luma - mkU.luma);
  check(`${tag} L1 a crop box placed STRAIGHT off mixerMute's reported frame + captureOrigin, `
        + `with NO hand-derived correction, sees the mute toggle`,
        dC >= DELTA_MIN, `box ${JSON.stringify(muteBox(true))} luma ${mkC.luma} -> ${mkC2.luma} (Δ ${dC.toFixed(2)}, floor ${DELTA_MIN})`);
  check(`${tag} L2 [RED ARM] the SAME box WITHOUT captureOrigin — exactly what a consumer `
        + `did before this cycle — is blind to it`,
        dU <= DELTA_MAX_NULL, `box ${JSON.stringify(muteBox(false))} luma ${mkU.luma} -> ${mkU2.luma} (Δ ${dU.toFixed(2)}, must be <= ${DELTA_MAX_NULL})`);

  // ── L3/L4 arrangePlayhead: a clip added on LANE 2 ───────────────────────
  // ⚠️ GEOMETRY, not taste: the offset (32) is SMALLER than the lane pitch (56),
  // so a box placed low in lane 2 still overlaps lane 2 when shifted up by the
  // omitted origin — the first run of this script put it at inset 8 with h 30 and
  // the red arm caught 6 pt of real clip ink (Δ 10.14). Placing it in the lane's
  // TOP band makes the uncorrected copy land in lane 1, which carries no clip:
  //   corrected   163 + 112 + 10 + 32 = 317 .. 331
  //   uncorrected 163 + 112 + 10      = 285 .. 299   (lane 1 spans 251..301, empty)
  // Lane 2's clip row begins at 307, so the arms are disjoint by 8 pt.
  const laneTop = 2 * LANE_PITCH;
  const clipBox = (useOrigin) => ({
    x: (lanes.x + 20 * PPB + (useOrigin ? org.x : 0)) * S,
    y: (lanes.y + laneTop + 10 + (useOrigin ? org.y : 0)) * S,
    w: 48 * S, h: 14 * S,
  });
  const noClip = await capture(`${tag}-noclip`);
  const clip = await req("clip.addMIDI", { trackId: tracks[2], atBeat: 20, lengthBeats: 4 });
  await sleep(SETTLE);
  const withClip = await capture(`${tag}-clip`);

  const cC = boxes(noClip.path, [{ label: "c", ...clipBox(true) }]).c;
  const cC2 = boxes(withClip.path, [{ label: "c", ...clipBox(true) }]).c;
  const cU = boxes(noClip.path, [{ label: "u", ...clipBox(false) }]).u;
  const cU2 = boxes(withClip.path, [{ label: "u", ...clipBox(false) }]).u;
  const dcC = Math.abs(cC2.luma - cC.luma), dcU = Math.abs(cU2.luma - cU.luma);
  check(`${tag} L3 a crop box placed STRAIGHT off arrangePlayhead's frame + captureOrigin + `
        + `lane 2's pitch finds the clip drawn on lane 2`,
        dcC >= DELTA_MIN, `box ${JSON.stringify(clipBox(true))} luma ${cC.luma} -> ${cC2.luma} (Δ ${dcC.toFixed(2)}, floor ${DELTA_MIN})`);
  check(`${tag} L4 [RED ARM] the same box WITHOUT captureOrigin lands on lane 1 and is blind `
        + `to it — a confident false negative, which is the class this item retires`,
        dcU <= DELTA_MAX_NULL, `box ${JSON.stringify(clipBox(false))} luma ${cU.luma} -> ${cU2.luma} (Δ ${dcU.toFixed(2)}, must be <= ${DELTA_MAX_NULL})`);

  const cid = clip.id ?? clip.clip?.id;
  if (cid) await req("clip.remove", { clipId: cid });
  await sleep(SETTLE);

  // ── L7/L8 transportLoop: the leg that MAKES THE SECOND SIZE MEAN SOMETHING ──
  // ⚠️ L1-L4 above read pixels that do NOT move with the window: mixerMute and
  // lane 2 are both TOP-anchored, so re-running them at 1320x880 reads the SAME
  // pixels and the "should stay green at another size" arm is vacuous — the two
  // runs printed byte-identical luma, which is the tell. The loop button is
  // BOTTOM-anchored, so its reported frame moves with the content height and the
  // second size genuinely re-exercises the conversion.
  const loop = (await frames(["transportLoop"])).frames?.transportLoop?.[0];
  if (loop) {
    const loopBox = (useOrigin) => ({
      x: (loop.x + (useOrigin ? org.x : 0)) * S,
      y: (loop.y + (useOrigin ? org.y : 0)) * S,
      w: loop.width * S, h: loop.height * S,
    });
    const lOff = await capture(`${tag}-loop-off`);
    await req("transport.setLoop", { enabled: true, startBeat: 0, endBeat: 8 });
    await sleep(SETTLE);
    const lOn = await capture(`${tag}-loop-on`);
    await req("transport.setLoop", { enabled: false });
    await sleep(SETTLE);
    const lC = boxes(lOff.path, [{ label: "c", ...loopBox(true) }]).c;
    const lC2 = boxes(lOn.path, [{ label: "c", ...loopBox(true) }]).c;
    const lU = boxes(lOff.path, [{ label: "u", ...loopBox(false) }]).u;
    const lU2 = boxes(lOn.path, [{ label: "u", ...loopBox(false) }]).u;
    const dlC = Math.abs(lC2.luma - lC.luma), dlU = Math.abs(lU2.luma - lU.luma);
    check(`${tag} L7 a BOTTOM-anchored surface (transportLoop, frame y=${loop.y} at this size) `
          + `converts with the same payload — no reprint, no per-size constant`,
          dlC >= DELTA_MIN, `box ${JSON.stringify(loopBox(true))} luma ${lC.luma} -> ${lC2.luma} (Δ ${dlC.toFixed(2)}, floor ${DELTA_MIN})`);
    check(`${tag} L8 [RED ARM] the same bottom-anchored box WITHOUT captureOrigin is blind`,
          dlU <= DELTA_MAX_NULL, `box ${JSON.stringify(loopBox(false))} luma ${lU.luma} -> ${lU2.luma} (Δ ${dlU.toFixed(2)}, must be <= ${DELTA_MAX_NULL})`);
  } else {
    check(`${tag} L7/L8 transportLoop frame present`, false, "no frame reported");
  }
  return { org, size, loopY: loop?.y ?? null };
}

try {
  await req("project.new", { discardChanges: true });
  const t0 = (await req("track.add", { kind: "instrument", name: "Lead" })).id;
  const t1 = (await req("track.add", { kind: "instrument", name: "Keys" })).id;
  const t2 = (await req("track.add", { kind: "instrument", name: "Pad" })).id;
  await req("debug.panelDensity", { panel: "arrange", mode: "simple" });
  await sleep(SETTLE);
  const tracks = [t0, t1, t2];

  const a = await sizeRun(1400, 1000, "A", tracks);
  const b = await sizeRun(1320, 880, "B", tracks);

  console.log("\n════════ SUMMARY ════════");
  if (a && b) {
    console.log(`origin A ${JSON.stringify(a.org)}  B ${JSON.stringify(b.org)}`);
    console.log(`transportLoop frame y: A ${a.loopY}  B ${b.loopY}  -> ${a.loopY !== b.loopY
      ? "MOVED, so the second size is a real re-exercise" : "DID NOT MOVE — the B arm is vacuous, fix the leg"}`);
  }
  const bad = results.filter((r) => !r.ok);
  console.log(`\nM23AG ${results.length - bad.length}/${results.length}`);
  if (bad.length) { console.log("FAILED:"); bad.forEach((r) => console.log(`  ${r.n}\n     ${r.d}`)); }
  fs.writeFileSync(`${OUT}/results.json`, JSON.stringify(results, null, 2));
} catch (err) {
  results.push({ n: "gate ran to completion", ok: false, d: String(err && err.stack ? err.stack : err) });
  console.log(`\nM23AG ${results.filter((r) => r.ok).length}/${results.length}`);
} finally {
  try { ws.close(); } catch {}
  stopStaging(GATE, PIDFILE);
  clearTimeout(killer);
}
process.exit(results.every((r) => r.ok) ? 0 : 1);
