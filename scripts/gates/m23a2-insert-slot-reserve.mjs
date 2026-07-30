// m23-strip-reserve GATE — the FIXED 3-SLOT INSERT RESERVE on the mixer strip,
// against a REAL app on staging (port 17695 ONLY; 17600 is the user's LIVE app and
// is never touched. Staging is killed PIDFILE-EXACT, never pkill/pgrep).
//
// USER-REQUESTED, and it SUPERSEDES m23-a's "strips hug independently" rule:
//   "we need to put inserts into a scrollable section to make all other elements
//    stable in their position instead of pushing everything down"
// m23-a stopped a long chain pushing the app header and transport OFF the window;
// it did nothing about the chain pushing the strip's OWN controls down. Measured
// before this item: five ordinary inserts moved that strip's PAN row, fader and dB
// readout down 121 pt while the neighbouring strip's stayed put.
//
// WHAT THIS PROVES
//   Positional stability DIRECTLY, on the live window, by measuring where controls
//   actually are — never by re-stating the reserve constant (which would only check
//   the code against itself). Every Y comes from `debug.explainFrames`, which reads
//   the frames the explain overlay itself anchors cards on, in the window's own
//   `explainRoot` space. Strips are identified by measured minX, not list order.
//
//   Each count change is proved OBSERVABLE before its stability is claimed: the
//   inserts section's own content height must GROW, otherwise "the fader did not
//   move" is vacuous (an fx.add that silently failed would pass it). The witness is
//   the chain length echoed back on the WIRE by fx.add/fx.remove, NOT the section's
//   frame height — that height is now (correctly) constant, so it can no longer
//   witness anything.
//
// THE COORDINATE SPACE IS VERIFIED, NOT ASSUMED (checked at m23-strip-reserve close)
//   `explainRoot` is the window's CONTENT space at unit scale. Cross-checked against
//   a `debug.captureUI` PNG at 1440x900 (capture 2880x1800, so 2x): a control
//   reported at y=740 h=20 lands at capture pixel rows (740+28)*2 .. (760+28)*2, and
//   x maps with NO offset. The +28 pt is the macOS title bar, which the capture
//   includes and `explainRoot` does not. So: constant Y offset, unit scale. Every
//   equality/difference assertion below is exact regardless (a constant cancels),
//   and absolute figures quoted in comments are true in content space.
//
// WHAT IT DOES NOT PROVE
//   Sends/Output are stable against the INSERT count only. They still hug, so the
//   OUTPUT row still moves when a SEND is added — asserted here as the honest
//   scope, not fixed. A bus strip drops sends+output entirely, so it agrees with
//   other buses, not with channels.
//
// Usage: node scripts/gates/m23a2-insert-slot-reserve.mjs
//   env: M23SR_OUT (capture dir), M23SR_BINARY, M23SR_PIDFILE
import fs from "fs";
import zlib from "zlib";
import { execFileSync } from "child_process";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23a2";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23SR_OUT || "/tmp/m23-strip-reserve";
const PIDFILE = process.env.M23SR_PIDFILE || "/tmp/m23-strip-reserve-staging.pid";
const BINARY = process.env.M23SR_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23SR_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SETTLE = 420;

// ── staging up, through the ONE home (m23-ac-2a) ────────────────────────────
// `buildOrAbort` is the half this gate never had: before this it ran whatever
// was compiled last. `startStaging` keeps the pidfile-exact teardown of a
// previous run and refuses port 17600 in ONE place. Every M23SR_* override is
// preserved — they let the gate be pointed at a bundle, which is deliberate.
buildOrAbort();
const { pid: stagingPid } = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY, pidfile: PIDFILE,
  outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${stagingPid} on :${PORT}`);
await sleep(4500);

let ws;
for (let i = 0; i < 60 && !ws; i++) {
  try {
    ws = await new Promise((res, rej) => {
      const w = new WebSocket(`ws://127.0.0.1:${PORT}`);
      w.addEventListener("open", () => res(w));
      w.addEventListener("error", () => rej(new Error("refused")));
    });
  } catch { await sleep(500); }
}
if (!ws) { console.error("no connect"); process.exit(2); }

let seq = 0;
const cmd = (command, params = {}) => new Promise((res, rej) => {
  const id = `sr${++seq}`;
  const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 30000);
  const h = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id !== id) return;
    clearTimeout(t); ws.removeEventListener("message", h); res(m);
  };
  ws.addEventListener("message", h);
  ws.send(JSON.stringify({ id, command, params }));
});
async function must(command, params) {
  const r = await cmd(command, params);
  if (!r.ok) throw new Error(`${command} failed: ${JSON.stringify(r.error)}`);
  return r.result;
}

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const r3 = (v) => Math.round(v * 1000) / 1000;
const same = (xs, eps = 0.5) => xs.length > 0 && Math.max(...xs) - Math.min(...xs) <= eps;

const teardown = async (code) => {
  clearTimeout(killer);
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify(checks, null, 2));
  try { ws.close(); } catch {}
  // m23-ac-2c: this gate's bespoke session.lock cleanup MOVED into
  // `stopStaging`, which now reads the pid before it deletes the pidfile and
  // does the ownership check itself.
  //
  // The ac-2a note that used to sit here said the extra step was kept local
  // because "seventeen other callers do not want lock cleanup". That was
  // WRONG, and provably so: every gate that SIGTERMs staging leaves a lock
  // behind, so every one of them was leaving the user a false crash recovery.
  // This gate was not special in needing the cleanup — it was just the only
  // one that had noticed. A step that looks bespoke is worth re-checking
  // against the other callers before it is used as a reason not to share it.
  //
  // The 1200 ms sleep that preceded the check is also gone; see `stopStaging`
  // for why both orderings are safe.
  stopStaging(GATE, PIDFILE);
  process.exit(code);
};

/// Every measured frame we care about, keyed by id, each sorted LEFT TO RIGHT by
/// its measured minX — strips are a horizontal rack of fixed-width panels, so minX
/// identifies a strip unambiguously and we never assume the preference-merge order.
const IDS = ["mixerInserts", "mixerFader", "mixerPan", "mixerSends", "mixerOutput",
             "mixerMute", "mixerMasterInserts", "mixerMaster"];
async function frames() {
  const r = await must("debug.explainFrames", { ids: IDS });
  const out = { explainActive: r.explainActive };
  for (const [id, list] of Object.entries(r.frames)) {
    out[id] = list.slice().sort((a, b) => a.x - b.x);
  }
  return out;
}
const ys = (f, id) => (f[id] ?? []).map((r) => r3(r.y));
const hs = (f, id) => (f[id] ?? []).map((r) => r3(r.height));

try {
  // ── fixture: three CHANNEL strips + two BUS strips + a master chain ────────
  await must("project.new", { discardChanges: true });
  const A = (await must("track.add", { kind: "audio", name: "A" })).id;   // grows 0→12
  const B = (await must("track.add", { kind: "audio", name: "B" })).id;   // holds 1
  const C = (await must("track.add", { kind: "audio", name: "C" })).id;   // holds 5
  const busR = (await must("track.add", { kind: "bus", name: "Rev" })).id;
  const busD = (await must("track.add", { kind: "bus", name: "Dly" })).id;
  // One send on every channel, so the sends block is the ordinary (measured) shape.
  for (const t of [A, B, C]) await must("track.addSend", { trackId: t, busId: busR });
  // `fx.add` echoes the whole resolved chain, so the WIRE — not a view height —
  // is the witness that a chain really has the length a stability claim assumes.
  const chainLen = {};
  chainLen[B] = (await must("fx.add", { trackId: B, kind: "eq" })).effects.length;
  for (const k of ["eq", "reverb", "delay", "chorus", "saturator"]) {
    chainLen[C] = (await must("fx.add", { trackId: C, kind: k })).effects.length;
  }
  chainLen[A] = 0;
  for (const k of ["eq", "limiter"]) await must("fx.add", { trackId: "master", kind: k });
  await must("ui.showMixer", { show: true });
  await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
  await must("debug.windowFrame", { width: 1440, height: 900 });
  await must("debug.explainMode", { on: true });
  await sleep(800);

  let f = await frames();
  check("A0 the window reports measured frames (explain mode on, frames flowing)",
        f.explainActive === true && (f.mixerFader ?? []).length >= 3,
        JSON.stringify({ active: f.explainActive, faders: (f.mixerFader ?? []).length }));
  check("A1 three channel strips + two buses are measured, left to right",
        (f.mixerFader ?? []).length === 5 && (f.mixerSends ?? []).length === 3,
        JSON.stringify({ faderX: (f.mixerFader ?? []).map((r) => r3(r.x)),
                         sendsX: (f.mixerSends ?? []).map((r) => r3(r.x)) }));
  // Anti-vacuity: the three channels really do carry DIFFERENT chain lengths — read
  // off the WIRE, because the section's own height is (correctly) no longer a witness.
  const insH = hs(f, "mixerInserts");
  check("A2 the three channels carry 0 / 1 / 5 inserts (per the wire, not the view)",
        chainLen[A] === 0 && chainLen[B] === 1 && chainLen[C] === 5,
        JSON.stringify({ A: chainLen[A], B: chainLen[B], C: chainLen[C] }));
  check("A3 …and all three inserts sections are nonetheless the SAME height",
        insH.length === 5 && same(insH.slice(0, 3)),
        JSON.stringify({ insertsSectionHeights: insH }));

  // ── B: THE USER'S REQUEST, asserted directly ──────────────────────────────
  const chanFader = ys(f, "mixerFader").slice(0, 3);
  check("B1 THE ASK — fader/dB sits at ONE Y on every channel strip, 0 vs 1 vs 5 inserts",
        same(chanFader),
        JSON.stringify({ faderY: chanFader, spread: r3(Math.max(...chanFader) - Math.min(...chanFader)) }));
  const chanPan = ys(f, "mixerPan").slice(0, 3);
  check("B2 …and so does the VOL|PAN knob row above it",
        same(chanPan), JSON.stringify(chanPan));
  const chanSends = ys(f, "mixerSends");
  check("B3 …and SENDS (they sit below the inserts — stabilised for free, verified)",
        same(chanSends), JSON.stringify(chanSends));
  const chanOut = ys(f, "mixerOutput");
  check("B4 …and the OUTPUT picker",
        same(chanOut), JSON.stringify(chanOut));
  const chanMute = ys(f, "mixerMute").slice(0, 3);
  check("B5 …and Mute/Solo/Arm (already floor-pinned by m23-a; must stay so)",
        same(chanMute), JSON.stringify(chanMute));
  const busFader = ys(f, "mixerFader").slice(3);
  check("B6 the two BUS strips agree with each other too (buses drop sends+output)",
        same(busFader), JSON.stringify(busFader));

  // ── C: the SAME strip, before and after the chain changes ─────────────────
  const before = await frames();
  const y0 = ys(before, "mixerFader")[0];
  const h0 = hs(before, "mixerInserts")[0];
  const trail = [{ n: 0, wire: 0, faderY: y0, sectionH: h0 }];
  const added = [];
  for (const n of [1, 3, 4, 12]) {
    let wire = 0;
    while (added.length < n) {
      const res = await must("fx.add", { trackId: A, kind: "eq" });
      added.push(res.effectId);
      wire = res.effects.length;
    }
    await sleep(SETTLE);
    const g = await frames();
    trail.push({ n, wire, faderY: ys(g, "mixerFader")[0], sectionH: hs(g, "mixerInserts")[0] });
  }
  check("C1 the chain really grew each step (else 'it did not move' is vacuous)",
        trail.every((t, i) => i === 0 || t.wire === t.n) &&
        trail.map((t) => t.n).join() === "0,1,3,4,12",
        JSON.stringify(trail.map((t) => `asked ${t.n} / wire ${t.wire}`)));
  check("C2 THE ASK — that strip's fader never moved, 0 → 1 → 3 → 4 → 12 inserts",
        same(trail.map((t) => t.faderY)),
        JSON.stringify(trail.map((t) => `${t.n}:${t.faderY}`)));
  const at12 = await frames();
  check("C3 …including PAST the reserve: a 12-insert chain scrolls INSIDE a section " +
        "whose height is identical to an EMPTY one's",
        same([...ys(at12, "mixerFader").slice(0, 3)]) && same(trail.map((t) => t.sectionH)),
        JSON.stringify({ faderY: ys(at12, "mixerFader").slice(0, 3),
                         sectionH: trail.map((t) => `${t.n}:${t.sectionH}`) }));
  await cap("h900-A12-B1-C5");

  // Remove them all again — the Y must come back to exactly where it started.
  while (added.length) await must("fx.remove", { trackId: A, effectId: added.pop() });
  await sleep(SETTLE);
  const after = await frames();
  check("C4 removing every insert restores the SAME Y (no drift, no rounding creep)",
        r3(ys(after, "mixerFader")[0]) === r3(y0) && r3(hs(after, "mixerInserts")[0]) === r3(h0),
        JSON.stringify({ before: y0, after: ys(after, "mixerFader")[0] }));

  // ── D: SENDS still hug — the MEASURED scope limit of this fix ─────────────
  // Recorded as a passing leg stating what is TRUE, not as an aspiration: the
  // reserve covers the INSERT count and nothing else. A send still grows the
  // block, so it still moves the output picker AND the fader below it. That is
  // the documented scope (sends are rarely added mid-mix, and reserving send
  // slots too would cost every strip a second permanent void) — if a later
  // cycle extends the reserve to sends, THIS leg is the one that must flip.
  const outBefore = ys(after, "mixerOutput")[0];
  const faderBefore = ys(after, "mixerFader")[0];
  const send2 = (await must("track.addSend", { trackId: A, busId: busD })).sendId;
  await sleep(SETTLE);
  const withSend = await frames();
  check("D1 SCOPE: a SEND still moves the OUTPUT picker — only inserts are reserved",
        ys(withSend, "mixerOutput")[0] > outBefore + 10,
        JSON.stringify({ before: outBefore, after: ys(withSend, "mixerOutput")[0] }));
  check("D2 SCOPE: a SEND still moves the fader too — measured, and out of scope here",
        ys(withSend, "mixerFader")[0] > faderBefore + 10,
        JSON.stringify({ before: faderBefore, after: ys(withSend, "mixerFader")[0],
                         note: "insert-count stability is the ask; send-count is not" }));
  await must("track.removeSend", { trackId: A, sendId: send2 });
  await sleep(SETTLE);
  const sendGone = await frames();
  check("D3 …and removing it returns the fader exactly where it was",
        r3(ys(sendGone, "mixerFader")[0]) === r3(faderBefore),
        JSON.stringify({ was: faderBefore, now: ys(sendGone, "mixerFader")[0] }));

  // ── E: the COLLAPSED decision, pinned ─────────────────────────────────────
  const expanded = sendGone;
  await must("debug.panelLayout", { mixerInsertsCollapsed: true });
  await sleep(SETTLE);
  const collapsed = await frames();
  check("E1 collapsed hands the space BACK — the fold is not a do-nothing toggle",
        ys(collapsed, "mixerFader")[0] < ys(expanded, "mixerFader")[0] - 40,
        JSON.stringify({ expanded: ys(expanded, "mixerFader")[0],
                         collapsed: ys(collapsed, "mixerFader")[0] }));
  check("E2 …and collapsed is itself consistent: every strip still agrees",
        same(ys(collapsed, "mixerFader").slice(0, 3)) && same(ys(collapsed, "mixerPan").slice(0, 3)),
        JSON.stringify({ fader: ys(collapsed, "mixerFader").slice(0, 3),
                         pan: ys(collapsed, "mixerPan").slice(0, 3) }));
  await cap("h900-collapsed");
  await must("debug.panelLayout", { mixerInsertsCollapsed: false });
  await sleep(SETTLE);
  const reexpanded = await frames();
  check("E3 unfolding restores the reserve exactly",
        r3(ys(reexpanded, "mixerFader")[0]) === r3(ys(expanded, "mixerFader")[0]),
        JSON.stringify({ was: ys(expanded, "mixerFader")[0], now: ys(reexpanded, "mixerFader")[0] }));

  // ── F: the MASTER strip is RESERVED TOO now (m23-ax) ──────────────────────
  const mBefore = hs(reexpanded, "mixerMasterInserts")[0];
  for (const k of ["reverb", "delay", "chorus"]) await must("fx.add", { trackId: "master", kind: k });
  await sleep(SETTLE);
  const mAfter = await frames();
  // ⚠️ THIS LEG WAS INVERTED ON PURPOSE (m23-ax, 2026-07-30). It used to read
  // "the MASTER chain still HUGS — and its growth pins the MEASURED row height",
  // asserting that three inserts add exactly 3 × (24 + 4) = 84 pt, and it was the
  // ONLY leg that could still see a row's height because a channel strip's reserve
  // (correctly) absorbs it. At the user's request the master is now reserved too —
  // a flat five slots — so it grows by ZERO and that assertion could no longer be
  // true. It failed with `grew: 0` the first time it ran after the change, which is
  // the gate doing its job, not collateral.
  //
  // The ROW-HEIGHT ruler moved with it: `m23s-insert-labels.mjs` leg E2 now reads
  // the pitch off the BUS's degradation valve, which is the last place in the app
  // where a row's height is still observable as a difference. If that ever becomes
  // fixed as well, the pitch needs a fourth home — do not let it quietly become
  // unmeasured.
  const mGrew = r3(hs(mAfter, "mixerMasterInserts")[0] - mBefore);
  check("F1 the MASTER chain is RESERVED and does NOT grow with its chain (m23-ax; it hugged before)",
        mGrew === 0 && r3(hs(mAfter, "mixerMasterInserts")[0]) === 156,
        JSON.stringify({ before: mBefore, after: hs(mAfter, "mixerMasterInserts")[0],
                         grew: mGrew, expected: "0, and a flat 156 = 16 + 4 + 5x24 + 4x4" }));
  check("F2 …and a master insert never moves a CHANNEL strip's fader",
        same(ys(mAfter, "mixerFader").slice(0, 3)),
        JSON.stringify(ys(mAfter, "mixerFader").slice(0, 3)));

  // ── G: m23-a's guarantee at the measured WINDOW FLOOR ─────────────────────
  for (const k of ["eq", "reverb", "delay", "chorus", "saturator", "gain", "limiter", "gate"]) {
    await must("fx.add", { trackId: A, kind: k });
  }
  await must("debug.windowFrame", { width: 1440, height: 640 });
  await sleep(700);
  const floor = await frames();
  const capInfo = await must("debug.captureUI", { path: `${OUT}/h640-full-chain.png` });
  const contentH = capInfo.height / (capInfo.height > 1400 ? 2 : 1);
  check("G1 at the 640 pt window floor the strips STILL agree, 8-insert chain and all",
        same(ys(floor, "mixerFader").slice(0, 3)) && same(ys(floor, "mixerPan").slice(0, 3)),
        JSON.stringify({ fader: ys(floor, "mixerFader").slice(0, 3),
                         pan: ys(floor, "mixerPan").slice(0, 3) }));
  const muteBottom = (floor.mixerMute ?? []).map((r) => r3(r.y + r.height));
  check("G2 m23-a HOLDS: the Mute/Solo/Arm row is still inside the window, not clipped",
        muteBottom.length >= 3 && Math.max(...muteBottom) < contentH,
        JSON.stringify({ muteBottom, windowContent: contentH }));
  check("G3 …and the reserved cluster is intact — the fader region kept its floor",
        (floor.mixerFader ?? []).slice(0, 3).every((r) => r.height >= 100),
        JSON.stringify(hs(floor, "mixerFader").slice(0, 3)));

  // ── H: the EMPTY state occupies the reserve (capture for pixel review) ────
  await must("debug.windowFrame", { width: 1440, height: 900 });
  // Strip A must genuinely be EMPTY for this leg and its capture — otherwise the
  // frame filed as evidence of the empty well shows a full chain instead.
  // `fx.remove` echoes the resolved chain, so the last one tells us it is really 0.
  let chain = (await must("fx.add", { trackId: A, kind: "gain" })).effects;
  let remaining = chain.length;
  for (const e of chain) {
    remaining = (await must("fx.remove", { trackId: A, effectId: e.id })).effects.length;
  }
  await sleep(700);
  check("H0 strip A is genuinely EMPTY for the empty-state leg (0 per the wire)",
        remaining === 0, JSON.stringify({ remaining }));
  const empt2 = await frames();
  check("H1 an EMPTY chain holds the same space as a full one (the deliberate well)",
        same([ys(empt2, "mixerFader")[0], ys(empt2, "mixerFader")[1], ys(empt2, "mixerFader")[2]]),
        JSON.stringify({ empty: ys(empt2, "mixerFader")[0], oneInsert: ys(empt2, "mixerFader")[1],
                         fiveInserts: ys(empt2, "mixerFader")[2] }));
  await cap("h900-empty-well");

  // ── J: the dashed REMAINDER finishes a partial chain ──────────────────────
  // The user's follow-up: a 1-of-3 chain must read as "three slots, one filled",
  // not as a chip above a void. Strip B still carries exactly ONE insert here, so
  // rows 2 and 3 of its reserve are the empty slots.
  //
  // WHAT THIS COUNTS, precisely: horizontal DASHED BORDERS, not brightness. Measured
  // off this very capture at 2x, the band reads panel 21 → dashed hairline 29 → slot
  // fill 23. **The fill is invisible against the panel** (23 vs 21, a 2/255 step), so
  // a "the region got lighter" pin would be vacuous — the slots are visible ONLY by
  // their border, and that is the thing worth pinning. With the remainder removed the
  // whole band is a flat 21 and the run count drops to 0.
  const HEADER = 16, GAP = 4, ROW = 24;
  const insB = (await frames()).mixerInserts[1];
  await must("debug.captureUI", { path: `${OUT}/j-remainder.png` });
  const bandB = rowProfile(`${OUT}/j-remainder.png`,
                           insB.x, insB.y + HEADER + GAP + ROW + GAP, insB.width, 2 * ROW + GAP);
  check("J1 the remainder is DRAWN — dashed slot borders counted under a 1-insert chain",
        hairlineRuns(bandB) >= 3,
        JSON.stringify({ runs: hairlineRuns(bandB), levels: levels(bandB) }));

  // J2 answers "does 3 → 4 read as a glitch?" with a live witness rather than an
  // argument. Three ordinary inserts fill the reserve EXACTLY (24+4+24+4+24 = 80), so
  // at three there is no dashed remainder and nothing sliced; at four the at-rest
  // picture is the same three whole chips and only scrolling differs. Same strip,
  // same pixels, so no cross-strip chip-name identity is needed.
  let cA = 0;
  for (const kind of ["eq", "reverb", "delay"]) {
    cA = (await must("fx.add", { trackId: A, kind })).effects.length;
  }
  await sleep(SETTLE);
  const insA = (await frames()).mixerInserts[0];
  const viewport = [insA.x, insA.y + HEADER + GAP, insA.width, 3 * ROW + 2 * GAP];
  const header = [insA.x, insA.y, insA.width, HEADER];
  await must("debug.captureUI", { path: `${OUT}/j-three.png` });
  const three = rowProfile(`${OUT}/j-three.png`, ...viewport);
  const threeHead = rowProfile(`${OUT}/j-three.png`, ...header);
  const c4 = (await must("fx.add", { trackId: A, kind: "limiter" })).effects.length;
  await sleep(SETTLE);
  await must("debug.captureUI", { path: `${OUT}/j-four.png` });
  const four = rowProfile(`${OUT}/j-four.png`, ...viewport);
  const fourHead = rowProfile(`${OUT}/j-four.png`, ...header);
  const drift = Math.max(...three.map((v, i) => Math.abs(v - (four[i] ?? 0))));
  // The HEADER is asserted to CHANGE, and that is not decoration: it is this leg's
  // anti-vacuity. Two identical screenshots would sail through "the rows didn't
  // move", so the count badge going 3 → 4 is the proof that the capture really is a
  // different app state. It is also the only correct difference — the badge is what
  // tells the truth about a chain that is merely scrolled past.
  const headDrift = Math.max(...threeHead.map((v, i) => Math.abs(v - (fourHead[i] ?? 0))));
  check("J2 a FOURTH insert changes nothing at rest — the 3→4 step is not a glitch",
        cA === 3 && c4 === 4 && three.length === four.length && drift === 0 && headDrift > 1,
        JSON.stringify({ wire: [cA, c4], rowsDrift: drift, countBadgeDrift: r3(headDrift) }));

  // J3 the case the height-aware arithmetic exists for: a KEYABLE insert (compressor
  // on a track) is a 42 pt row, not 24, because it carries the sidechain KEY sub-row.
  // Counting it as an ordinary row would score the chain 4 pt short and draw a SECOND
  // slot where only one fits. One chip + one slot is the correct picture.
  let chainA = (await must("fx.add", { trackId: A, kind: "gain" })).effects;
  for (const e of chainA) await must("fx.remove", { trackId: A, effectId: e.id });
  const keyChain = (await must("fx.add", { trackId: A, kind: "compressor" })).effects.length;
  await sleep(SETTLE);
  const keyF = await frames();
  const insK = keyF.mixerInserts[0];
  await must("debug.captureUI", { path: `${OUT}/j-keyable.png` });
  // 42 pt chip, then the gap, then whatever slot still fits (exactly one: 42+4+24=70).
  const bandK = rowProfile(`${OUT}/j-keyable.png`,
                           insK.x, insK.y + HEADER + GAP + 42 + GAP, insK.width, ROW);
  // …and CLEARANCE is what makes this leg discriminating. "At least one slot" passes
  // whether one or two are drawn, because a second one lands below the fold — the
  // first version of this leg went GREEN under the very mutation it exists to catch.
  //
  // The property that actually matters is that no dashed border appears where the
  // viewport should already have ended. A compressor chain occupies 42 + 4 + 24 = 70
  // of the 80 pt viewport, so the last border must sit clear of the bottom.
  //
  // MEASURED on the real window, section-relative, NOT modelled — these are the two
  // observed values, correct build vs MUT-D (keyable scored as an ordinary 24 pt row):
  //   correct → last hairline leaves 6 pt of clear panel below it.
  //   mutant  → an extra slot's TOP border intrudes, leaving 1 pt. The box is not
  //             "sliced in half"; a hairline simply appears where clean panel belongs,
  //             and the viewport becomes scrollable when nothing should overflow.
  // The >= 4 threshold sits between the two measured values.
  //
  // Clearance is measured, not modelled: reading the profile beats assuming a row
  // origin, because the rows begin 4 pt lower than header+gap alone predicts.
  const sectK = rowProfile(`${OUT}/j-keyable.png`, insK.x, insK.y, insK.width, insK.height);
  const clearK = lastHairlineClearance(sectK);
  check("J3 a KEYABLE 42 pt row is measured as itself — one chip, ONE slot, 6 pt clear below",
        keyChain === 1 && r3(insK.height) === 100 && hairlineRuns(bandK) >= 1
          && clearK >= 4 && same(ys(keyF, "mixerFader").slice(0, 3)),
        JSON.stringify({ sectionH: r3(insK.height), slotRuns: hairlineRuns(bandK),
                         bottomClearancePt: clearK,
                         fader: ys(keyF, "mixerFader").slice(0, 3) }));

  // ── I: SIMPLE density is untouched ────────────────────────────────────────
  await must("debug.panelDensity", { panel: "mixer", mode: "simple" });
  await sleep(SETTLE);
  const simple = await frames();
  check("I1 SIMPLE hides the whole signal-flow block — strips agree, no reserve shown",
        (simple.mixerInserts ?? []).length === 0 && same(ys(simple, "mixerFader").slice(0, 3)),
        JSON.stringify({ inserts: (simple.mixerInserts ?? []).length,
                         fader: ys(simple, "mixerFader").slice(0, 3) }));
  await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
  await sleep(SETTLE);
  await cap("h900-pro-final");

  const bad = checks.filter((c) => !c.ok);
  console.log(`\nm23-strip-reserve gate: ${checks.length - bad.length} pass / ${bad.length} fail`);
  await teardown(bad.length ? 1 : 0);
} catch (e) {
  console.error("GATE ERROR", e);
  checks.push({ name: "GATE ERROR", ok: false, detail: String(e) });
  await teardown(2);
}

async function cap(name) {
  const r = await must("debug.captureUI", { path: `${OUT}/${name}.png` });
  console.log(`      capture ${name}: ${r.width}x${r.height}`);
}

// ── Pixel reading (the J legs) ───────────────────────────────────────────────
// A vertical luminance PROFILE of a rect: one value per captured pixel row, at the
// capture's own 2x, so a 1 pt dashed hairline survives as its own row instead of
// being averaged away. Rect is given in `explainRoot` points — the SAME space the
// frames come in — and converted here: y + 28 (the title bar the capture includes
// and explainRoot does not) then x2. That mapping is verified, not assumed; see the
// coordinate-space note in this file's header.
function rowProfile(png, xPt, yPt, wPt, hPt) {
  const tmp = `${OUT}/_profile.png`;
  const hPx = Math.round(hPt * 2);
  execFileSync("sips", ["-c", String(hPx), String(Math.round(wPt * 2)),
                        "--cropOffset", String(Math.round((yPt + 28) * 2)),
                        String(Math.round(xPt * 2)), png, "--out", tmp], { stdio: "ignore" });
  execFileSync("sips", ["--resampleHeightWidth", String(hPx), "1", tmp, "--out", tmp],
               { stdio: "ignore" });
  const { channels, rows } = decodePNG(tmp);
  return rows.map((l) => (channels <= 2 ? l[0] : 0.299 * l[0] + 0.587 * l[1] + 0.114 * l[2]));
}

// Runs of rows standing clear of the panel — i.e. how many horizontal hairlines the
// band contains. The threshold is derived from the band's OWN darkest row (the bare
// panel) rather than a hardcoded colour, so a theme tweak retunes it automatically.
// Measured levels in this band: panel 21, slot fill 23, dashed border 29 — a lift of
// 6 sits between the fill and the border, which is what makes this count BORDERS.
// `function`, not `const`: these are called from the top-level gate body ABOVE this
// point, and a `const` arrow would still be in its temporal dead zone there.
function hairlineRuns(p, lift = 6) {
  const base = Math.min(...p);
  let n = 0, hot = false;
  for (const v of p) { const on = v >= base + lift; if (on && !hot) n += 1; hot = on; }
  return n;
}
function levels(p) {
  return [...new Set(p.map((v) => Math.round(v)))].sort((a, b) => a - b);
}

// Distance in POINTS from the last hairline in a band to the band's bottom edge —
// "is anything cut off down there?". The profile is in capture pixels (2 per point).
function lastHairlineClearance(p, lift = 6) {
  const base = Math.min(...p);
  let last = -1;
  for (let i = 0; i < p.length; i += 1) if (p[i] >= base + lift) last = i;
  // NO hairline at all returns 0 — a FAILING clearance, deliberately. This helper is
  // only ever asked about a band whose premise is that a slot IS drawn, so "I found
  // no border" must fail the caller rather than report a huge clearance and pass it.
  // The threshold is relative to the band's own darkest row, so a band that somehow
  // contained no bare panel would raise it above the border level and find nothing —
  // that path must fail closed, not open.
  if (last < 0) return 0;
  return (p.length - 1 - last) / 2;
}

// Minimal PNG reader: enough for the greyscale/RGB(A) 8-bit files `debug.captureUI`
// writes. No dependency — the repo's gates run on bare node.
function decodePNG(path) {
  const buf = fs.readFileSync(path);
  let off = 8, ihdr = null; const idat = [];
  while (off < buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("ascii", off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === "IHDR") ihdr = { w: data.readUInt32BE(0), h: data.readUInt32BE(4), color: data[9] };
    if (type === "IDAT") idat.push(data);
    off += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const channels = ihdr.color === 6 ? 4 : ihdr.color === 2 ? 3 : ihdr.color === 4 ? 2 : 1;
  const stride = ihdr.w * channels;
  const rows = [];
  let prev = Buffer.alloc(stride), o = 0;
  for (let y = 0; y < ihdr.h; y += 1) {
    const ft = raw[o]; o += 1;
    const line = Buffer.from(raw.subarray(o, o + stride)); o += stride;
    for (let i = 0; i < stride; i += 1) {
      const a = i >= channels ? line[i - channels] : 0;
      const b = prev[i];
      const c = i >= channels ? prev[i - channels] : 0;
      let v = line[i];
      if (ft === 1) v = (v + a) & 255;
      else if (ft === 2) v = (v + b) & 255;
      else if (ft === 3) v = (v + ((a + b) >> 1)) & 255;
      else if (ft === 4) {
        const pp = a + b - c;
        const pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
        v = (v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 255;
      }
      line[i] = v;
    }
    rows.push(line); prev = line;
  }
  return { channels, rows };
}
