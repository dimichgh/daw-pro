// m23-ah GATE — the empty-lane hint SPELLS the pinned copy, in pixels.
//
// Staging 17695 ONLY; 17600 is the user's LIVE app and is never touched. Staging
// is killed PIDFILE-EXACT, never pkill/pgrep. Nothing is written to the tree.
//
// ── WHY A SECOND GATE RATHER THAN MORE m23-v LEGS ────────────────────────────
// `m23v-empty-lane-hint.mjs` (27 legs) proves the hint is DRAWN, DIM, on exactly
// the right lanes, and that it VANISHES when a lane gains a clip. It does NOT
// prove it spells the hint, and m23-ah exists because that gap was MEASURED, not
// suspected: its E-legs read the ECHO (`hint.text` — the MODEL's value, which
// cannot see glyphs) and its P-legs bound ink HEIGHT/PEAK/LANE/disappearance, all
// of which a different string at the same font size satisfies. Replacing
// `Text(hint.text)` with the literal `"Double-click to odd a clip"` at
// `TimelineLanesView.swift:1757` scored **27/27 GREEN** on that gate.
//
// It is kept SEPARATE for the m23-ag/m23-ag2 reason: a regression here is a WORDS
// regression, one there is a drawn/dim/placement regression, and collapsing them
// would hide which one broke. It also must not touch m23-v's ink derivation —
// m23-ag's L9b asserts against exactly that independent derivation, and rewriting
// it to consume `captureOrigin` would make the pair circular. THIS gate may use
// `captureOrigin` freely: the payload is proven, and the origin is not what m23-ah
// is testing.
//
// ⚠️ A WIDTH PIN IS NOT AN ACCEPTABLE FIX and this gate deliberately is not one.
// In SF Pro `a` and `o` carry near-identical advances: the pinned copy and the
// measured mutant typeset to 134.191 pt vs 134.621 pt, a 0.43 pt difference. A
// width pin's gap contains the exact mutant that motivated the item.
//
// ── HOW IT WORKS, IN TWO IDEAS ───────────────────────────────────────────────
// Both live in `scripts/probes/m23ah-hint-glyph-probe.swift`; read its header for
// the measurement detail. In brief:
//
//   1. THE GRID IS CANCELLED THE WAY m23-v CANCELS IT, BUT IN 2D. The label window
//      and a control window in the SAME lane, both starting at x ≡ 4 (mod 64),
//      span identical bar/beat lines; `ink = max(0, A − B)` per pixel leaves glyph
//      ink only. That is the m23-p2 law in two dimensions. MEASURED: on a lane
//      with no hint the two windows are byte-identical, so the ink is exactly 0.0.
//
//   2. THE VERDICT IS A RANKING, NOT A THRESHOLD. CoreText renders each candidate
//      string; NCC maximized over integer shifts says which one the frame's ink
//      most resembles. NCC is amplitude-invariant, so a 255-valued reference
//      against ink peaking near 106 needs no tuned scale factor, and no absolute
//      agreement threshold between two different rasterizers has to be invented.
//
// MEASURED SCORES (clean tree, lane 0): pinned 0.9893, single-glyph near-miss
// 0.9323, "Right-click…" 0.4979, "…a loop" 0.9059 → MARGIN +0.0570. With the
// mutant compiled in the top two swap almost exactly (0.9331 / 0.9895, MARGIN
// −0.0564). THE 0.02 MARGIN FLOOR IS DERIVED FROM THAT PAIR: the clean margin
// clears it by 0.0370 and the mutant misses it by 0.0764, so the threshold sits
// with room on BOTH sides rather than being fitted to one run.
//
// ── WHAT THIS GATE DOES NOT COVER (say it out loud) ──────────────────────────
//   * NOT visibility. NCC is amplitude-invariant BY DESIGN, so a label rendered
//     far too faint — as long as it clears the probe's ink floor — still ranks the
//     pinned copy first. m23-v's PEAK_MIN is what proves "dim but actually
//     visible", and this gate does not duplicate it.
//   * NOT position. The matcher sweeps ±8 pt of integer shift to absorb the
//     reference's arbitrary draw origin, so a label displaced by up to that much
//     scores unchanged. m23-v's P8/P9/P15 own lane placement.
//   * NOT drawn/vanishing/per-lane-rule. All m23-v's, deliberately not repeated.
//   * NOT the wording CHOICE. The reference text is read from the SOURCE OF TRUTH
//     (`ArrangeEmptyLaneHints.copy`), so this gate proves view pixels ≡ that
//     constant. A deliberate copy edit follows through and stays green — which is
//     the invariant m23-ah asked for; it is not a copy-review gate.
//   * LANE 3 IS A PLACEMENT CHECK, NOT AN INDEPENDENT GLYPH SAMPLE. MEASURED: the
//     lane-0 and lane-3 label crops are byte-identical (both sha f83a7c813773), as
//     they must be — same string, same inset, same lane background. The lane-3
//     legs prove ink of the right shape sits at `laneTop(3)`; they are not a
//     second, independent reading of the words. That the crop genuinely TRACKS y
//     is proven by the N1 leg below, where the audio lane between them reads
//     exactly 0.0 ink.
//
// Usage:
//   node scripts/gates/m23ah-hint-glyphs.mjs
// Env: M23AH_SKIP_BUILD=1 to reuse .build/debug/DAWApp — only safe immediately
// after a build of the tree under test, since A-GATE-THAT-LAUNCHES-A-PREBUILT-
// BINARY-TESTS-THE-PREVIOUS-BUILD.
import fs from "fs";
import { execFileSync } from "child_process";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23ah";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23AH_OUT || "/tmp/m23ah";
const PIDFILE = process.env.M23AH_PIDFILE || "/tmp/m23ah-staging.pid";
const BINARY = process.env.M23AH_BINARY || ".build/debug/DAWApp";
const PROBE = process.env.M23AH_PROBE || "/tmp/m23ah-probe";
const REPO = process.env.M23AH_REPO || "/Users/dsemenov/Views/daw-pro";
const PROBE_SRC = "scripts/probes/m23ah-hint-glyph-probe.swift";

// The two files this gate reads its expectations OUT OF rather than restating.
const COPY_SRC = `${REPO}/Sources/DAWAppKit/ArrangeEmptyLaneHint.swift`;
const VIEW_SRC = `${REPO}/Sources/DAWApp/Timeline/TimelineLanesView.swift`;

const WIN_W = 1400, WIN_H = 1000;
const PPB = 16;
const ROW_H = 50;                          // rowStep "large"
const LANE_SPACING = 6;
const LANE_PITCH = ROW_H + LANE_SPACING;   // 56 pt lane to lane
// The two x windows, in CONTENT points — the SAME constants m23v uses at :117.
// Equal width, both at x ≡ 4 (mod 64), so the beat/bar grid cancels exactly.
const LABEL_X = 4, CTRL_X = 196, WIN_PT = 176;
// The label's frame top is `laneTop(i) + (rowHeight − fontSize)/2 − 2`
// (`TimelineLanesView.swift:1763`) = laneTop + 17.5 at rowHeight 50 / font 11, and
// its glyphs occupy roughly 13 pt below that. BAND_TOP/BAND_H bracket that by
// 3.5 pt on each side. Both are MEASURED at those two inputs, which is why the
// fixture leg F1 and the font leg S2 pin them — change either and re-derive.
const BAND_TOP = 14, BAND_H = 20;
const MARGIN_MIN = 0.02;                   // derived above from +0.0570 / −0.0564
const NCC_MIN = 0.95;                      // measured 0.9893; catches a drifted crop
const SEEK_BEATS = 400;                    // playhead x = 6400 pt, far off-screen
const SETTLE = 600;

fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 900_000);

// ── build, so the gate cannot certify the previous binary ────────────────────
buildOrAbort({ root: REPO, skip: !!process.env.M23AH_SKIP_BUILD });
// Compile the matcher if it is missing OR STALE. The corpus convention is
// "if absent"; the staleness check is added because this probe's CoreText
// reference IS the assertion — an old binary would silently score against an old
// reference and read exactly like a pass.
const probeSrcPath = `${REPO}/${PROBE_SRC}`;
const probeStale = !fs.existsSync(PROBE)
  || fs.statSync(PROBE).mtimeMs < fs.statSync(probeSrcPath).mtimeMs;
if (probeStale) {
  console.log("compiling the glyph matcher…");
  execFileSync("swiftc", ["-O", "-o", PROBE, PROBE_SRC], { cwd: REPO, stdio: "inherit" });
}

const staging = startStaging({ gate: GATE, root: REPO, port: PORT, binary: BINARY,
                               detached: true, pidfile: PIDFILE, outDir: OUT });
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4000);

// Armed BEFORE the first thing that can throw, not after the connect — a leaked
// detached app holding :17695 is the one outcome this gate must never produce,
// and `connect()` itself can reject. (`_staging.mjs` also arms an `exit` hook, so
// staging would come down anyway; these handlers add the reason to the log and a
// deterministic rc=2 instead of an unhandled-rejection trace.) They deliberately
// close over only GATE/PIDFILE, so they are valid the instant staging exists.
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => {
    console.error(`${ev}:`, e && e.stack ? e.stack : e);
    try { stopStaging(GATE, PIDFILE); } catch {}
    process.exit(2);
  });
}

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

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const near = (a, b, eps = 1e-6) => typeof a === "number" && Math.abs(a - b) < eps;

let capSeq = 0;
async function capture(tag) {
  const path = `${OUT}/${tag}-${capSeq++}.png`;
  const r = await req("debug.captureUI", { path });
  return { path, width: r.width, height: r.height };
}
function shaOf(p) {
  return execFileSync("/usr/bin/shasum", ["-a", "256", p]).toString().split(" ")[0];
}
/// A STABLE capture: two consecutive byte-identical frames (the m23-g3 law — a
/// single unlucky pair can make a pixel leg meaningless). Failing to stabilise is
/// a FAILURE, never a skip.
async function stableCapture(tag) {
  let prevSha = shaOf((await capture(tag)).path);
  for (let i = 0; i < 10; i++) {
    await sleep(150);
    const next = await capture(tag);
    const sha = shaOf(next.path);
    if (sha === prevSha) return next;
    prevSha = sha;
  }
  return null;
}

/// Run the matcher and PARSE it. Never throws on a nonzero exit: the probe exits 1
/// on a losing margin (that is the red baseline) and 2 on an ink refusal, with its
/// numbers already on stdout in both cases. Treating either as an exception would
/// turn the two most interesting outcomes into a crash.
function runProbe(png, xA, xB, y0, w, h, scale, candidates) {
  const args = [png, String(xA), String(xB), String(y0), String(w), String(h), String(scale), ...candidates];
  let out = "", code = 0;
  try {
    out = execFileSync(PROBE, args, { encoding: "utf8" });
  } catch (e) {
    code = typeof e.status === "number" ? e.status : -1;
    out = (e.stdout ?? "").toString();
  }
  const r = { code, out, ncc: [], refused: /^REFUSED /m.test(out), ink: null, margin: null, best: null };
  const ink = out.match(/^INK sum=([-\d.]+) max=([-\d.]+) xA=(\d+) xB=(\d+) y0=(\d+) w=(\d+) h=(\d+) scale=([\d.]+) font=([\d.]+) refx=([\d.]+)$/m);
  if (ink) r.ink = { sum: +ink[1], max: +ink[2], xA: +ink[3], xB: +ink[4], y0: +ink[5],
                     w: +ink[6], h: +ink[7], scale: +ink[8], font: +ink[9], refx: +ink[10] };
  for (const line of out.split("\n")) {
    const m = line.match(/^NCC (\d+) ([-\d.]+) (-?\d+) (-?\d+) (.*)$/);
    if (m) r.ncc.push({ i: +m[1], score: +m[2], dx: +m[3], dy: +m[4], text: m[5] });
  }
  const mg = out.match(/^MARGIN ([-+\d.]+)$/m); if (mg) r.margin = +mg[1];
  const bs = out.match(/^BEST (\d+) ([-\d.]+)$/m); if (bs) r.best = { i: +bs[1], score: +bs[2] };
  return r;
}
const scoreOf = (r, text) => r.ncc.find((n) => n.text === text)?.score ?? null;

try {
  // ══ THE PINNED COPY, FROM THE SOURCE OF TRUTH ══════════════════════════════
  // Read, not restated. `ArrangeEmptyLaneHints.copy` is where the words live; a
  // gate carrying its own literal would go green on a source that had changed.
  const copySrc = fs.readFileSync(COPY_SRC, "utf8");
  const copyHits = copySrc.match(/public static let copy = "([^"]*)"/g) ?? [];
  const COPY = copyHits.length === 1
    ? copySrc.match(/public static let copy = "([^"]*)"/)[1] : null;
  check("S1 the pinned copy is READ FROM THE SOURCE OF TRUTH (ArrangeEmptyLaneHints.copy), "
        + "matched EXACTLY ONCE — a copy change re-aims this gate instead of silently "
        + "leaving it asserting a stale literal",
        copyHits.length === 1 && !!COPY && COPY.length > 4,
        `matches=${copyHits.length} copy=${JSON.stringify(COPY)} (${COPY_SRC})`);
  if (!COPY) throw new Error("could not read the pinned copy from source");

  // THE SELF-TEST CANDIDATE, derived from the copy by a SINGLE-GLYPH substitution.
  // This is the string that scored 27/27 GREEN on m23-v; beating it means beating
  // anything coarser, which is the whole reason the item was filed.
  const addCount = COPY.split("add").length - 1;
  const NEAR_GLYPH = addCount === 1 ? COPY.replace("add", "odd") : null;
  check("S3 the SINGLE-GLYPH near-miss is DERIVED from the pinned copy (add -> odd), on an "
        + "anchor occurring exactly once — this is the gate's own self-test and it must not "
        + "be quietly underivable",
        addCount === 1 && NEAR_GLYPH !== null && NEAR_GLYPH !== COPY,
        `"add" occurrences=${addCount} derived=${JSON.stringify(NEAR_GLYPH)}`);
  if (!NEAR_GLYPH) throw new Error("could not derive the single-glyph near-miss");

  // CONTEXT candidates — coarser near-misses, present so the ranking is visibly a
  // ranking and not a two-horse race. Derived where the substring exists; simply
  // omitted when it does not, since they are context and not load-bearing.
  const CANDIDATES = [COPY, NEAR_GLYPH];
  for (const [from, to] of [["Double-click", "Right-click"], ["clip", "loop"]]) {
    if (COPY.split(from).length - 1 === 1) CANDIDATES.push(COPY.replace(from, to));
  }
  console.log(`candidates: ${JSON.stringify(CANDIDATES)}`);

  // ══ FIXTURE — the geometry the band arithmetic was measured at ═════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: WIN_W, height: WIN_H });
  await req("debug.panelDensity", { panel: "arrange", mode: "simple" });
  const lead = (await req("track.add", { kind: "instrument", name: "Lead" })).id;
  const vox = (await req("track.add", { kind: "audio", name: "Vox" })).id;
  const bus = (await req("track.add", { kind: "bus", name: "Reverb" })).id;
  const pad = (await req("track.add", { kind: "instrument", name: "Pad" })).id;
  await req("debug.arrangeZoom", { reset: true });
  const zoom = await req("debug.arrangeZoom", { ppb: PPB });
  await req("debug.arrangeZoom", { rowStep: "large" });
  await req("transport.seek", { beats: SEEK_BEATS });
  // Scroll reset AFTER the seek: the label is drawn in lane CONTENT space, so a
  // scrolled viewport would move it out from under a crop measured at content x=4.
  await req("debug.arrangeScroll", { reset: true });
  await req("debug.arrangePointer", { act: "clear" });   // no ghost line in the windows
  await sleep(SETTLE);

  const layout = await req("debug.panelLayout", {});
  check(`F1 fixture: ppb ${PPB} and rowHeight ${ROW_H} — the two inputs BAND_TOP ${BAND_TOP} / `
        + `BAND_H ${BAND_H} were measured at (label top = laneTop + (rowHeight - font)/2 - 2)`,
        near(zoom.ppb, PPB) && near(layout.rowHeight, ROW_H),
        `ppb=${zoom.ppb} rowHeight=${layout.rowHeight}`);
  const ov = await req("project.overview", {});
  check("F2 fixture: four EMPTY tracks in ladder order instrument/audio/bus/instrument — "
        + "so lanes 0 and 3 are the hinted ones and lane 1 is the negative control",
        ov.tracks.length === 4 && ov.tracks.every((t) => t.clips.length === 0)
        && ov.tracks.map((t) => t.id).join() === [lead, vox, bus, pad].join(),
        `tracks=${ov.tracks.length} clips=${ov.tracks.map((t) => t.clips.length).join()}`);

  // ══ E — the MODEL tier, tied to the same source of truth ═══════════════════
  // The NCC legs tie SOURCE -> PIXELS. This ties SOURCE -> MODEL, so the pair
  // spans the whole path. m23-v's E5 makes the same assertion against a hardcoded
  // literal; here the expected value comes out of the file.
  const ptr = await req("debug.arrangePointer", {});
  const hints = ptr.emptyLaneHints ?? [];
  check("E1 the echo reports the SOURCE-OF-TRUTH copy on exactly the two hinted lanes 0 and 3 "
        + "— the model tier of the same claim, and the precondition for aiming the crops",
        hints.length === 2 && hints.every((h) => h.text === COPY)
        && hints.map((h) => h.laneIndex).join() === "0,3",
        `laneIndex=${hints.map((h) => h.laneIndex).join()} text=${JSON.stringify(hints.map((h) => h.text))}`);

  // ══ GEOMETRY — derived from the m23-ag payload, never hardcoded ════════════
  // Explain frames flow only while explain mode is on, and explain chrome must
  // never be in frame, so it is turned OFF again before any capture.
  await req("debug.explainMode", { on: true });
  await sleep(SETTLE);
  const ef = await req("debug.explainFrames", { ids: ["arrangePlayhead"] });
  await req("debug.explainMode", { on: false });
  await sleep(SETTLE);
  const rects = ef.frames?.arrangePlayhead ?? [];
  const org = ef.captureOrigin;
  check("G1 exactly ONE arrangePlayhead instance, and m23-ag's captureOrigin is present — "
        + "together they place the lanes' content origin in CAPTURE points without the "
        + "gate assuming an offset",
        ef.explainActive === true && rects.length === 1
        && org && typeof org.x === "number" && typeof org.y === "number",
        `explainActive=${ef.explainActive} instances=${rects.length} `
        + `frame=${JSON.stringify(rects[0])} captureOrigin=${JSON.stringify(org)}`);
  if (rects.length !== 1 || !org) throw new Error("no usable lanes geometry");
  const lanesX = rects[0].x + org.x, lanesY = rects[0].y + org.y;

  const shot = await stableCapture("hint");
  check("G2 a stable resting image could be established — without one no pixel claim below "
        + "can be trusted (m23-g3: a skip here is NOT a pass)",
        shot !== null, shot ? `${shot.width}x${shot.height} ${shot.path}` : "10 consecutive pairs differed");
  if (!shot) throw new Error("no stable capture");
  const scale = Math.round(shot.height / WIN_H);
  check("G3 the capture scale is a sane backing factor, derived from the frame rather than assumed",
        scale === 1 || scale === 2,
        `capture ${shot.width}x${shot.height} vs window ${WIN_W}x${WIN_H} -> scale ${scale}`);
  console.log(`lanes content origin (capture pts) x=${lanesX} y=${lanesY}, scale ${scale}`);

  /// Crop arguments in PIXELS for one lane's label band, plus its structurally
  /// identical control window in the SAME lane.
  const bandArgs = (lane) => [
    Math.round((lanesX + LABEL_X) * scale),                        // xA — the label window
    Math.round((lanesX + CTRL_X) * scale),                         // xB — the control window
    Math.round((lanesY + lane * LANE_PITCH + BAND_TOP) * scale),   // y0
    Math.round(WIN_PT * scale), Math.round(BAND_H * scale), scale,
  ];

  const runs = {};
  for (const [lane, who] of [[0, "Lead"], [3, "Pad"]]) {
    const [xA, xB, y0, w, h, s] = bandArgs(lane);
    const r = runProbe(shot.path, xA, xB, y0, w, h, s, CANDIDATES);
    runs[lane] = r;
    console.log(`\n── lane ${lane} (${who}) ──\n${r.out.trim()}`);

    const pinned = scoreOf(r, COPY);
    const others = r.ncc.filter((n) => n.text !== COPY);
    const bestOther = others.length ? others.reduce((a, b) => (b.score > a.score ? b : a)) : null;
    const placement = lane === 0 ? "" :
      ". ⚠️ A PLACEMENT check: this crop is byte-identical to lane 0's, so it proves ink of the "
      + "right shape sits at laneTop(3) — it is NOT a second independent reading of the words";

    check(`P${lane}a lane ${lane} (${who}): the label window CARRIES INK — a crop that drifted off `
          + `the text would score every candidate low TOGETHER, and a pure ranking cannot tell that `
          + `from wrong words, so the matcher REFUSES below its floor`,
          r.ink !== null && !r.refused && r.ncc.length === CANDIDATES.length,
          r.ink ? `sum=${r.ink.sum} max=${r.ink.max} at y0=${r.ink.y0} h=${r.ink.h} `
                  + `(xA=${r.ink.xA} xB=${r.ink.xB} w=${r.ink.w}), candidates scored `
                  + `${r.ncc.length}/${CANDIDATES.length}, probe rc=${r.code}`
                : `no INK line — probe rc=${r.code}: ${r.out.trim().slice(0, 200)}`);

    check(`P${lane}b lane ${lane} (${who}): THE PIXELS SPELL THE PINNED COPY — of every candidate `
          + `rendered by CoreText, the frame's ink most resembles ${JSON.stringify(COPY)}${placement}`,
          r.best !== null && r.best.i === 0 && pinned !== null,
          `best=${r.best ? JSON.stringify(r.ncc[r.best.i]?.text) : "none"} `
          + `scores=[${r.ncc.map((n) => `${JSON.stringify(n.text)}:${n.score.toFixed(4)}`).join(", ")}]`);

    check(`P${lane}c lane ${lane} (${who}): it wins by MARGIN >= ${MARGIN_MIN} over the best near-miss, `
          + `which includes the SINGLE-GLYPH mutant that scored 27/27 GREEN on m23-v. Floor derived, `
          + `not fitted: clean measured +0.0570 (clears by 0.0370), mutant measured -0.0564 `
          + `(misses by 0.0764)`,
          r.margin !== null && r.margin >= MARGIN_MIN,
          `margin=${r.margin === null ? "n/a" : r.margin.toFixed(4)} `
          + `(pinned ${pinned === null ? "n/a" : pinned.toFixed(4)} - best near-miss `
          + `${bestOther ? `${bestOther.score.toFixed(4)} ${JSON.stringify(bestOther.text)}` : "n/a"})`);

    check(`P${lane}d lane ${lane} (${who}): the pinned copy's ABSOLUTE agreement is >= ${NCC_MIN} `
          + `(measured 0.9893 — CoreText systemFont(11) reproduces SwiftUI .system(size: 11) `
          + `essentially exactly). A pure ranking cannot see a crop that drifted off the text; `
          + `this can`,
          pinned !== null && pinned >= NCC_MIN,
          `pinned NCC=${pinned === null ? "n/a" : pinned.toFixed(4)} floor=${NCC_MIN}`);
  }

  // ══ THE SELF-TEST WAS ACTUALLY ASKED ═══════════════════════════════════════
  // Guards the failure mode where the candidate list is edited or reordered and
  // the hardest case silently drops out, leaving legs that still read green.
  check(`S4 every scored run was actually asked the SINGLE-GLYPH near-miss `
        + `${JSON.stringify(NEAR_GLYPH)} — verified in the probe's OWN echoed candidate list, not `
        + `in the gate's intent`,
        [0, 3].every((l) => runs[l]?.ncc.some((n) => n.text === NEAR_GLYPH)),
        [0, 3].map((l) => `lane${l}:${scoreOf(runs[l], NEAR_GLYPH)?.toFixed(4) ?? "ABSENT"}`).join(" "));

  // ══ S2 — the reference font is pinned to the view's own constant ═══════════
  const viewSrc = fs.readFileSync(VIEW_SRC, "utf8");
  const constOf = (name) => {
    const hits = viewSrc.match(new RegExp(`${name}: CGFloat = ([\\d.]+)`, "g")) ?? [];
    return hits.length === 1
      ? { n: hits.length, v: Number(viewSrc.match(new RegExp(`${name}: CGFloat = ([\\d.]+)`))[1]) }
      : { n: hits.length, v: null };
  };
  const font = constOf("emptyLaneHintFontSize");
  check("S2 the matcher's CoreText reference is rendered at the SAME point size the view draws "
        + "at — read from TimelineLanesView.emptyLaneHintFontSize and compared against the size "
        + "the probe echoes, so a font change fails HERE instead of quietly detuning the reference",
        font.v !== null && runs[0]?.ink != null && near(runs[0].ink.font, font.v, 1e-6),
        `view constant=${font.v} (matches=${font.n}) probe font=${runs[0]?.ink?.font ?? "n/a"}`);

  // ══ H1 — the label's HORIZONTAL position, recovered from the winning shift ══
  // THE GAP THIS CLOSES. LABEL_X and CTRL_X are CONTENT offsets, while `lanesX`
  // comes from the explain frame and is the lanes VIEWPORT origin — which does not
  // move when the content scrolls. So a horizontally scrolled viewport slides the
  // label out from under `xA` while every x the gate prints still reads correct.
  // The big cases are already caught (a large scroll drops the ink below the floor
  // or below P0d's 0.95), but a SMALL one sits in a blind band: most glyphs stay in
  // the 176 pt window and the matcher's ±8 pt shift sweep silently absorbs the
  // offset. This is the m23-v four-boxes-on-the-ruler false negative one scale down.
  //
  // ⚠️ AT THE TIME THIS WAS WRITTEN it was closed without a new seam, because
  // `debug.arrangeScroll` could not answer it: that seam was VERTICAL only (it
  // scrolls to a track) and reported no offset, and a bare `{}` read was not a
  // read at all — it fell through to "scroll to the last track" (m23-ah-2 filed
  // exactly this). m23-ah-2 later fixed BOTH: a bare read is now side-effect-free
  // (classified by `ArrangeScrollQuery.isQuery`) and the response carries a real
  // `hOffset`/`hOffsetMirror` from the SAME ground truth `debug.arrangeZoom`
  // echoes — a future rewrite of this leg could read it directly instead of
  // inverting the shift below. Left as-is here (the inversion trick is proven and
  // this gate did not need touching to fix m23-ah-2). Instead the winning shift, a
  // byproduct the search already produced, is inverted back into a content x:
  //     contentX = (xA / scale) + refx − dx / scale
  // and compared with the view's OWN inset constant. MEASURED dx = 0 on every run
  // (clean and mutant alike), which is exactly (LABEL_X 4 + refx 6) == insetX 10.
  //
  // ⚠️ THE SIGN IS MINUS, and dx = 0 cannot tell you that. The matcher pairs
  // `act[y][x]` with `ref[y+dy][x+dx]`, so ink at window offset `o` pairs with
  // reference ink at `o + dx`; the reference's own ink starts at `refx * scale`,
  // giving `o = refx * scale − dx`. VERIFIED EMPIRICALLY rather than by algebra
  // alone: re-running both windows shifted +8 px (both by the SAME amount, so they
  // stay a multiple of 64 pt apart and the grid still cancels) moves dx to exactly
  // +8 and leaves the recovered content x unchanged at 308.
  const inset = constOf("emptyLaneHintInsetX");
  const r0 = runs[0], n0 = r0?.ncc?.[0];
  const contentX = (r0?.ink && n0) ? (r0.ink.xA / r0.ink.scale) + r0.ink.refx - n0.dx / r0.ink.scale : null;
  check("H1 the label's ink sits at the view's OWN emptyLaneHintInsetX, recovered by inverting the "
        + "matcher's winning shift — so the lanes viewport is at CONTENT ORIGIN. Without this a "
        + "small horizontal scroll would slide the label under a crop whose x still reads correct, "
        + "and the ±8 pt shift sweep would absorb it silently (debug.arrangeScroll's hOffset now "
        + "answers this directly post-m23-ah-2; this leg predates that and keeps the proven "
        + "shift-inversion instead)",
        inset.v !== null && contentX !== null
        && Math.abs(contentX - (lanesX + inset.v)) <= 1.0,
        `recovered content x=${contentX === null ? "n/a" : contentX.toFixed(2)} vs lanesX ${lanesX} + `
        + `inset ${inset.v} (matches=${inset.n}) = ${inset.v === null ? "n/a" : lanesX + inset.v}; `
        + `winning shift dx=${n0?.dx ?? "n/a"} px, refx=${r0?.ink?.refx ?? "n/a"} pt`);

  // ══ N1 — the negative control ══════════════════════════════════════════════
  // The AUDIO lane sits BETWEEN the two hinted lanes and carries no hint. Two
  // things at once: the ink really is glyph ink and not grid residue (it reads
  // exactly 0.0, so the two windows cancel byte-for-byte), and the crop genuinely
  // TRACKS y — without which the lane-3 measurement could be a duplicate read of
  // lane 0 and would look identical.
  const [nxA, nxB, ny0, nw, nh, ns] = bandArgs(1);
  const neg = runProbe(shot.path, nxA, nxB, ny0, nw, nh, ns, CANDIDATES);
  console.log(`\n── lane 1 (Vox, audio — negative control) ──\n${neg.out.trim()}`);
  check("N1 [RED] the IDENTICAL measurement on the AUDIO lane between them REFUSES for want of "
        + "ink — proving both that the ink is glyph ink rather than grid residue, and that the "
        + "crop tracks y0 (so lane 3 is not a duplicate read of lane 0)",
        neg.refused === true && neg.ink !== null && neg.ink.sum < 100 && neg.code === 2,
        `sum=${neg.ink?.sum ?? "n/a"} max=${neg.ink?.max ?? "n/a"} at y0=${neg.ink?.y0 ?? "n/a"} `
        + `refused=${neg.refused} rc=${neg.code}`);

  // ══ normalize ══════════════════════════════════════════════════════════════
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.arrangePointer", { act: "clear" });
  await req("project.new", { discardChanges: true });
} catch (err) {
  check("gate ran to completion", false, String(err && err.stack ? err.stack : err));
}

const pass = checks.filter((c) => c.ok).length;
console.log(`\nM23AH ${pass}/${checks.length}`);
for (const c of checks) if (!c.ok) console.log(`FAIL ${c.name}\n     ${c.detail}`);
fs.writeFileSync(`${OUT}/results.json`, JSON.stringify(checks, null, 2));
try { ws.close(); } catch {}
stopStaging(GATE, PIDFILE);   // pidfile-EXACT, positional signature (_staging.mjs:265)
clearTimeout(killer);
// Explicit: without it node waits on lingering handles and never returns.
process.exit(pass === checks.length ? 0 : 1);
