// m23-ag SUPPLEMENTARY GATE — the shipping consumer the origin gate cannot see.
//
// `m23ag-explain-capture-origin.mjs` proves the PAYLOAD is right: it drives
// `debug.*` and reads pixels. It says nothing about the app's OWN consumer of the
// same coordinate space, and m23-ag changed the neighbourhood that consumer lives
// in: `explainCoordinateSpaceRoot()` (`ContentView.swift:224`) now mounts an
// `NSViewRepresentable` probe as the `.background` of the view wrapping the ENTIRE
// content tree — every overlay included — and the implementation hit a
// type-checker budget error that forced a restructure of that chain. Two claims in
// the m23-ag close-out were code-read plus inference, not exercised:
//
//   "the explain overlay card still anchors on its control"
//   "the probe is hit-test transparent, so it changes no behaviour"
//
// This gate exercises both. It is deliberately SEPARATE from the origin gate: a
// regression here is a UI-anchoring regression, not a payload regression, and
// collapsing them would hide which one broke.
//
// ── A: the card anchors ───────────────────────────────────────────────────
// `ExplainOverlay.cardCenter(anchoredTo:in:)` (`Explain.swift`) places the card in
// explainRoot POINTS: horizontally centred on the control (width 300), 8 pt BELOW
// when it fits, else 8 pt ABOVE, then clamped 8 pt from both window edges.
//
//   A1/A2  ABSOLUTE — predict from `frame + captureOrigin` and go find the card.
//          This is a cross-check of m23-ag's payload against a consumer the ink
//          legs never touch: if `captureOrigin` were wrong, these miss.
//   A3     DIFFERENTIAL — the SAME id at two instances, found by the IDENTICAL
//          detector, so every render inset cancels and what is left is pure
//          anchoring. This is the leg that carries the claim.
//   A4     [RED] the same prediction with the origin OMITTED must miss.
//   A5     the ABOVE branch fires for a bottom-anchored control, and the card
//          clamps to the margin instead of running off-window.
//
// ⚠️ WHY THE ABSOLUTE TOLERANCES ARE 8/12 pt AND NOT 2 — this is a property of the
// DETECTOR, not slack in the anchor, and it was measured then confirmed by eye on
// the crop before any tolerance was written (the m23-c2 law):
//   * The card carries a violet OUTER GLOW. A luma-delta column scan fires on the
//     glow ~9 pt OUTSIDE the panel border. The border itself sits on the
//     prediction to 0.0 pt — verified visually at 1400x1000, mixerMute[0]:
//     predicted left 51.0, panel border 51.0, first changed column 42.0.
//   * The card's FILL is low-contrast against the dark workspace, so the row
//     detector's first >3 delta is the TITLE TEXT, ~5.5 pt INSIDE the panel top.
// ⚠️ AND WHY A5 DOES NOT ASSERT THE CARD'S BOTTOM EDGE: the row detector takes the
// longest CONTIGUOUS run of changed rows, and the "Ask the Copilot" button is
// dark-on-dark, so the run ends at the last text row — ~60 pt short of the panel
// edge. Asserting there measures the button's contrast, not the anchor. A5 asserts
// the two things that ARE measurable: which SIDE of the control the card is on
// (the branch), and its clamped left edge.
//
// ── B: the probe is inert ─────────────────────────────────────────────────
// The lanes are a scroll surface the probe spans. ⚠️ THIS IS A BOUNDED CLAIM:
// `debug.arrangeScroll` is PROGRAMMATIC, so B proves the viewport still moves — it
// does NOT prove wheel-event routing is unblocked. That remains a code-read, and
// it rests on two independent facts: `ExplainSpaceProbeView.hitTest` returns nil,
// AND a SwiftUI `.background` view sits BEHIND the content it backs. Do not
// upgrade B's wording to cover the wheel without an actual wheel event.
//
// ⚠️ B NEEDS ENOUGH TRACKS TO OVERFLOW. At 14 tracks in a 1400x1000 window they
// all fit, `arrangeScroll` is correctly a no-op, and the leg reads byte-identical
// captures — a VACUOUS leg that presents as a failure and would be "fixed" by
// loosening it. 40 tracks is what makes the scroll real. (This gate found that on
// its first run; the fix was arithmetic, not tolerance.)
//
// Staging 17695 only — never 17600, the user's live app. Nothing written to the tree.
//
// Usage:
//   node scripts/gates/m23ag2-explain-card-anchor.mjs
// Env: M23AG2_SKIP_BUILD=1 to reuse .build/debug/DAWApp (only safe immediately
// after a build of the tree under test — a gate that launches a prebuilt binary
// tests the PREVIOUS build).
import fs from "fs";
import { execFileSync } from "child_process";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23ag2";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23AG2_OUT || "/tmp/m23ag2";
const PIDFILE = process.env.M23AG2_PIDFILE || "/tmp/m23ag2-staging.pid";
const BINARY = process.env.M23AG2_BINARY || ".build/debug/DAWApp";
const PROBE = process.env.M23AG2_PROBE || "/tmp/m23v-probe"; // shared with m23v/m23ag — same contract
const REPO = process.env.M23AG2_REPO || "/Users/dsemenov/Views/daw-pro";
const CARD_W = 300;    // ExplainOverlay.cardWidth — a design constant, legitimately pinned
const GAP = 8;         // cardCenter's gap
const MARGIN = 8;      // cardCenter's on-window clamp
const GLOW_H = 12;     // measured detector inset, horizontal (glow, ~9 pt observed)
const GLOW_V = 8;      // measured detector inset, vertical (low-contrast fill, ~5.5 pt observed)
const TRACKS = 40;     // enough that the lanes OVERFLOW — see the ⚠️ above
const SETTLE = 600;
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 900_000);

buildOrAbort({ root: REPO, skip: !!process.env.M23AG2_SKIP_BUILD });
if (!fs.existsSync(PROBE)) {
  console.log("compiling the box/row/col probe…");
  execFileSync("swiftc", ["-O", "-o", PROBE, "scripts/probes/m23g1-clip-box-probe.swift"],
               { cwd: REPO, stdio: "inherit" });
}

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

// Any throw past this point must STILL stop staging — a leaked detached app
// holding :17695 is the one thing this gate must never do.
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => {
    console.error(`${ev}:`, e && e.message);
    try { stopStaging(GATE, PIDFILE); } catch {}
    process.exit(2);
  });
}

const results = [];
const check = (n, ok, d) => { results.push({ n, ok, d }); console.log(`  ${ok ? "ok  " : "!!  "} ${n}\n        ${d}`); };

function profile(mode, png, a, b, c, d) {
  const raw = execFileSync(PROBE, [mode, png, String(Math.round(a)), String(Math.round(b)),
                                   String(Math.round(c)), String(Math.round(d))]).toString().trim().split("\n");
  return raw.map((l) => { const [k, v] = l.split(" "); return { k: +k, v: +v }; });
}
function boxes(png, specs) {
  const args = ["boxes", png, OUT, ...specs.map((s) => `${s.label}:${Math.round(s.x)},${Math.round(s.y)},${Math.round(s.w)},${Math.round(s.h)}`)];
  const out = {};
  for (const line of execFileSync(PROBE, args).toString().trim().split("\n")) {
    const m = line.match(/^(\S+) dims=(\d+)x(\d+) mean=([\d.,]+) luma=([\d.]+) sha=(\w+)$/);
    if (!m) throw new Error(`unparsed probe line: ${line}`);
    out[m[1]] = { luma: +m[5], sha: m[6] };
  }
  return out;
}
let capSeq = 0;
async function capture(tag) {
  const path = `${OUT}/${tag}-${capSeq++}.png`;
  const r = await req("debug.captureUI", { path });
  return { path, ...r };
}

// ── setup ────────────────────────────────────────────────────────────────
await req("project.new", { discardChanges: true });
const tracks = [];
for (let i = 0; i < TRACKS; i++) {
  const t = await req("track.add", { name: `T${i}`, kind: "instrument" });
  tracks.push(t.id ?? t.trackId ?? t);
}
const wf = await req("debug.windowFrame", { width: 1400, height: 1000 });
await sleep(SETTLE);
console.log(`content ${wf.width}x${wf.height}, ${tracks.length} tracks`);
await req("debug.arrangeZoom", { reset: true });
await req("debug.arrangeScroll", { reset: true });
await req("debug.arrangePointer", { act: "clear" });
await sleep(SETTLE);

// ══════════════════ A — the explain card anchors ═════════════════════════
await req("debug.explainMode", { on: true });
await sleep(SETTLE);
const ef = await req("debug.explainFrames", { ids: ["mixerMute", "transportPlay"] });
const org = ef.captureOrigin;
if (!org || !ef.captureSize) {
  check("A payload present", false, `captureOrigin=${JSON.stringify(org)} captureSize=${JSON.stringify(ef.captureSize)}`);
  stopStaging(GATE, PIDFILE);
  process.exit(1);
}
console.log(`captureOrigin=${JSON.stringify(org)} captureSize=${JSON.stringify(ef.captureSize)}`);
const baseShot = await capture("A-nofocus");
const S = baseShot.scale ?? 2;
const mutes = ef.frames?.mixerMute ?? [];
console.log(`mixerMute instances: ${mutes.length}`);

// Locate a focused card: longest contiguous run of changed ROWS in a column
// through its predicted centre, then the first changed COLUMN in a band inside it.
async function measureCard(id, inst, fr, tag) {
  await req("debug.explainMode", { on: true, focus: id, instance: inst });
  await sleep(SETTLE);
  const shot = await capture(tag);
  const cx = (fr.x + fr.width / 2 + org.x) * S;
  const pa = profile("rows", baseShot.path, cx - 3 * S, 6 * S, 0, ef.captureSize.height * S);
  const pb = profile("rows", shot.path, cx - 3 * S, 6 * S, 0, ef.captureSize.height * S);
  const changed = [];
  for (let i = 0; i < Math.min(pa.length, pb.length); i++)
    if (Math.abs(pa[i].v - pb[i].v) > 3) changed.push(pa[i].k);
  if (!changed.length) return null;
  let best = [changed[0], changed[0]], cur = [changed[0], changed[0]];
  for (let i = 1; i < changed.length; i++) {
    if (changed[i] - changed[i - 1] <= 4 * S) cur[1] = changed[i];
    else { if (cur[1] - cur[0] > best[1] - best[0]) best = cur; cur = [changed[i], changed[i]]; }
  }
  if (cur[1] - cur[0] > best[1] - best[0]) best = cur;
  const top = best[0] / S, bottom = best[1] / S;

  const predLeft = fr.x + fr.width / 2 + org.x - CARD_W / 2;
  const bandY = (top + (bottom - top) * 0.35) * S, bandH = Math.max(6 * S, (bottom - top) * 0.3 * S);
  const scanX0 = Math.max(0, (predLeft - 40) * S);
  const ca = profile("cols", baseShot.path, scanX0, 80 * S, bandY, bandH);
  const cb = profile("cols", shot.path, scanX0, 80 * S, bandY, bandH);
  let left = null;
  for (let i = 0; i < Math.min(ca.length, cb.length); i++)
    if (Math.abs(ca[i].v - cb[i].v) > 3) { left = ca[i].k / S; break; }
  await req("debug.explainMode", { on: false });
  await sleep(SETTLE);
  return { top, bottom, left, predLeft, fr };
}

const m0fr = mutes[0];
const m0 = m0fr ? await measureCard("mixerMute", 0, m0fr, "A-mute0") : null;
if (!m0) check("A card located", false, `no changed rows for mixerMute[0] (instances=${mutes.length})`);
else {
  const predTop = m0fr.y + m0fr.height + org.y + GAP;
  check(`A1 the explain card sits on the ${GAP} pt gap below its control — the overlay still anchors, `
        + `in the SAME space captureOrigin describes (tolerance ${GLOW_V} pt is the detector's inset `
        + `into the low-contrast fill, NOT anchor slack)`,
        Math.abs(m0.top - predTop) <= GLOW_V,
        `card band ${m0.top.toFixed(1)}..${m0.bottom.toFixed(1)} pt, control y=${m0fr.y.toFixed(1)} `
        + `h=${m0fr.height.toFixed(1)}, predicted top ${predTop.toFixed(1)}, err ${Math.abs(m0.top - predTop).toFixed(2)} pt`);

  const clamped = Math.max(MARGIN, Math.min(m0.predLeft, ef.captureSize.width - MARGIN - CARD_W));
  check(`A2 the card's left edge is centred on the control (width ${CARD_W}); the detector fires on the `
        + `violet OUTER GLOW ~9 pt outside the panel border, which itself sits on the prediction`,
        m0.left !== null && Math.abs(m0.left - clamped) <= GLOW_H,
        `measured ${m0.left === null ? "none" : m0.left.toFixed(1)} pt vs predicted ${clamped.toFixed(1)} `
        + `(midX ${(m0fr.x + m0fr.width / 2).toFixed(1)} + originX ${org.x} - ${CARD_W / 2}), err `
        + `${m0.left === null ? "n/a" : Math.abs(m0.left - clamped).toFixed(2)} pt`);

  check(`A4 [RED] the same anchor computed WITHOUT captureOrigin misses the card — the origin is `
        + `load-bearing for the overlay consumer too, not only for the ink legs`,
        Math.abs(m0.top - (m0fr.y + m0fr.height + GAP)) > GLOW_V,
        `naive top ${(m0fr.y + m0fr.height + GAP).toFixed(1)} vs measured ${m0.top.toFixed(1)} — err `
        + `${Math.abs(m0.top - (m0fr.y + m0fr.height + GAP)).toFixed(2)} pt (origin y=${org.y})`);
}

// A3 — DIFFERENTIAL. Same detector, second instance: every render inset cancels.
const IDX = Math.min(5, mutes.length - 1);
const m5fr = mutes[IDX];
const m5 = m5fr && IDX > 0 ? await measureCard("mixerMute", IDX, m5fr, `A-mute${IDX}`) : null;
if (!m5 || !m0) check("A3 second instance located", false, `instances=${mutes.length}, IDX=${IDX}`);
else {
  const dControl = m5fr.y - m0fr.y, dCard = m5.top - m0.top;
  const dX = (m5fr.x + m5fr.width / 2) - (m0fr.x + m0fr.width / 2);
  const dLeft = (m5.left ?? NaN) - (m0.left ?? NaN);
  check(`A3 DIFFERENTIAL: the card FOLLOWS its control — mixerMute[0] vs [${IDX}] moves it by exactly `
        + `the controls' own displacement. Identical detector both times, so the render inset cancels `
        + `and this is PURE ANCHORING (tolerance 2 pt, not ${GLOW_V})`,
        Math.abs(dCard - dControl) <= 2 && Math.abs(dLeft - dX) <= 2,
        `control moved Δy ${dControl.toFixed(1)} Δx ${dX.toFixed(1)}; card moved Δtop ${dCard.toFixed(1)} `
        + `Δleft ${Number.isNaN(dLeft) ? "n/a" : dLeft.toFixed(1)} — residual `
        + `${Math.abs(dCard - dControl).toFixed(2)} / ${Math.abs(dLeft - dX).toFixed(2)} pt`);
}

// A5 — the other cardCenter branch.
const tpFr = (ef.frames?.transportPlay ?? [])[0];
const tp = tpFr ? await measureCard("transportPlay", 0, tpFr, "A-play") : null;
if (!tp) check("A5 transportPlay card located", false, "no changed rows");
else {
  const clampedLeft = Math.max(MARGIN, Math.min(tp.predLeft, ef.captureSize.width - MARGIN - CARD_W));
  check(`A5 a bottom-anchored control flips the card ABOVE itself — the OTHER cardCenter branch — and `
        + `its left edge clamps to the ${MARGIN} pt margin rather than running off-window`,
        tp.bottom < tpFr.y + org.y && tp.left !== null && Math.abs(tp.left - clampedLeft) <= GLOW_H,
        `card band ${tp.top.toFixed(1)}..${tp.bottom.toFixed(1)} pt is entirely above the control top `
        + `${(tpFr.y + org.y).toFixed(1)} (capture pts); left ${tp.left === null ? "none" : tp.left.toFixed(1)} `
        + `vs clamped ${clampedLeft.toFixed(1)} (unclamped would be ${tp.predLeft.toFixed(1)}), err `
        + `${tp.left === null ? "n/a" : Math.abs(tp.left - clampedLeft).toFixed(2)} pt`);
}

// ══════════════════ B — the probe does not freeze the scroll surface ═════
await req("debug.explainMode", { on: false });
await req("debug.arrangeScroll", { reset: true });
await sleep(SETTLE);
const sTop = await capture("B-top");
await req("debug.arrangeScroll", { trackId: tracks[tracks.length - 1], bottom: true });
await sleep(SETTLE);
const sDeep = await capture("B-deep");
await req("debug.arrangeScroll", { reset: true });
await sleep(SETTLE);
const sBack = await capture("B-back");

const band = { label: "lanes", x: 20 * S, y: 320 * S, w: 340 * S, h: 400 * S };
const bTop = boxes(sTop.path, [band]).lanes;
const bDeep = boxes(sDeep.path, [band]).lanes;
const bBack = boxes(sBack.path, [band]).lanes;
check(`B1 a deep debug.arrangeScroll MOVES lane pixels — the probe spans this surface as a .background `
      + `and does not freeze it (${TRACKS} tracks, so the lanes actually overflow; at 14 they all fit `
      + `and this leg is VACUOUS). ⚠️ PROGRAMMATIC scroll — says nothing about wheel routing.`,
      bTop.sha !== bDeep.sha,
      `top sha ${bTop.sha.slice(0, 12)} luma ${bTop.luma} vs deep sha ${bDeep.sha.slice(0, 12)} luma ${bDeep.luma}`);
check(`B2 reset returns the viewport — the move was a scroll, not a one-way repaint`,
      bBack.sha === bTop.sha,
      `back sha ${bBack.sha.slice(0, 12)} luma ${bBack.luma} vs top ${bTop.sha.slice(0, 12)} luma ${bTop.luma}`);

const pass = results.filter((r) => r.ok).length;
console.log(`\n════ ${pass}/${results.length} ════`);
for (const r of results) if (!r.ok) console.log(`FAIL ${r.n}\n     ${r.d}`);
try { ws.close(); } catch {}
stopStaging(GATE, PIDFILE);
clearTimeout(killer);
process.exit(pass === results.length ? 0 : 1);
