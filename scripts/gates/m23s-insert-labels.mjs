// m23-s GATE — insert-row labels: built-ins are CONTROL LABELS and never
// truncate; an AU's name is SOFT DATA and still does.
//
// The arithmetic half of this cycle's gate is
// `Tests/DAWAppKitTests/InsertLabelBudgetTests.swift` — it sweeps
// `EffectDescriptor.Kind.allCases` against `MixerStripLayout.insertLabelWidth`
// with AppKit text metrics, so the ELEVENTH built-in effect somebody adds fails
// before anyone opens the mixer. This script is the drawing half: does SwiftUI's
// own layout agree, on the two strip classes the app actually renders?
//
// ⚠️ WHY A NEW SEAM WAS NEEDED. Nothing reported a drawn insert label before
// this cycle, which is why m23-s was filed from a capture a human squinted at.
// `debug.insertLabels` reports what each row DREW: `label` is the string the
// `Text` was built from, `pinned` is the argument handed to
// `.fixedSize(horizontal:)`, `drawn` is that `Text`'s own frame, `intrinsic` is
// the same string's single-line ideal from a hidden twin built by the same
// builder, `line` is the name line's own measured width. A probe that
// recomputed `effectDisplayName` and compared it to a layout constant would
// agree with itself while the view truncated (the m23-p2 law).
//
// ⚠️ BUILD FIRST. `spawn(".build/debug/DAWApp")` with no build step tests the
// PREVIOUS build; restoring a mutated source leaves the mutant binary on disk
// for the next run to adopt (the m23-o2 law). This script builds and aborts on
// failure.
//
// Staging 17695 ONLY. 17600 is the user's LIVE app and is never touched.
// Kill by EXACT pid from the pidfile — never pkill/pgrep.
import { spawn } from "node:child_process";   // leg D steals focus with `open -a`
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";

// The build/launch/pidfile-kill lifecycle lives in ONE place (m23-ac-1) —
// `_staging.mjs`. It used to be copy-pasted into every gate that had it at all.
import { launchStaging, stopStaging, sleep, ROOT, STAGING_PORT } from "./_staging.mjs";

const GATE = "m23s";
const OUT = "/tmp/daw-gate-out/m23s";
mkdirSync(OUT, { recursive: true });

// ---- label/layout constants -------------------------------------------------
// ⚠️ RECOVERED 2026-07-30 (m23-ac-1). The harness extraction deleted a region
// that also held these, and this file is untracked, so there was no git copy.
// Every value here was read back off the last known-good run's own transcript
// (33/33), which dumps each row as `kind "Label" drawn=… avail=… line=…` —
// so these are MEASURED, not reconstructed from taste. See
// scratchpad/ac1-baseline-preserved/m23s-insert-labels.txt.
const BUILT_INS = ["gain", "eq", "compressor", "limiter", "reverb",
                   "delay", "saturator", "gate", "chorus", "bassEnhancer"];
const EXPECTED_NAME = {
  gain: "Gain", eq: "EQ", compressor: "Compressor", limiter: "Limiter",
  reverb: "Reverb", delay: "Delay", saturator: "Saturator", gate: "Gate",
  chorus: "Chorus", bassEnhancer: "Bass Enhancer",
};
const CHANNEL_LINE = 98;
const MASTER_LINE = 118;  // MEASURED 2026-07-30 on the master strip (uniform
                          // across all ten kinds); the channel strip is 98.
const EPS = 0.5;

let ws, seq = 0;
function cmd(command, params = {}, timeoutMs = 60000) {
  return new Promise((res, rej) => {
    const id = `s-${++seq}`;
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
async function must(command, params = {}) {
  const r = await cmd(command, params);
  if (r.error) throw new Error(`${command} -> ${JSON.stringify(r.error)}`);
  return r.result ?? r;
}

let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};

// ── THE FOCUS-THEFT HARNESS (leg D) ───────────────────────────────────────
// `open -a Finder` rather than osascript: LaunchServices activation needs no
// Automation (TCC) grant, so the harness cannot be silently disarmed by a
// missing permission. The m22-e poll-discipline failure is INVISIBLE while the
// app is frontmost — that is the definition of the bug — so leg D is worthless
// without this.
let thief = null;
function stealFocusForever() {
  const steal = () => spawn("open", ["-a", "Finder"], { stdio: "ignore" });
  steal();
  thief = setInterval(steal, 1500);
}
function stopStealing() { if (thief) { clearInterval(thief); thief = null; } }

async function rows() {
  const r = await must("debug.insertLabels", {});
  return r;
}
function byKind(list, kind, chain) {
  return list.find((x) => x.kind === kind && x.chain === chain);
}

try {
  const staging = await launchStaging({ gate: GATE });
  ws = staging.ws;

  // ──────────────────────────────────────────────────────────────────────
  // LEG E — the row is still 24 pt tall, MEASURED, not asserted from the
  // constant. Removing the 16 pt editor glyph is what could have moved it, and
  // `insertRowHeight` is load-bearing for `insertsViewportHeight`,
  // `insertsRemainderSlots` and every strip class's reserve. The recipe for
  // OBSERVING the pitch has had to move twice as more strips became fixed — see
  // the note below the fixture — and now reads it off the bus valve's steps.
  // ──────────────────────────────────────────────────────────────────────
  await must("project.new", { discardChanges: true });
  const soloTrack = (await must("track.add", { name: "H" })).id;
  await must("ui.showMixer", { show: true });
  await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
  await must("debug.windowFrame", { width: 1440, height: 900 });
  await must("debug.explainMode", { on: true });
  await sleep(900);

  // ⚠️ THE MEASUREMENT HAS NOW MOVED TWICE, FOR THE SAME REASON BOTH TIMES.
  // m23-strip-reserve measured the 24 by differencing the CHANNEL section's
  // height as the chain grew — then that same cycle put those rows in a fixed
  // 3-slot viewport, so the channel section became a function of the strip's
  // height alone and differenced ZERO. The recipe moved to the MASTER chain,
  // which still hugged. **m23-ax then fixed the master too** (a flat 5-slot
  // reserve, at the user's request), so THAT source differences zero as well —
  // this leg failed with `[0,0,0]` the first time it ran after the change, which
  // is the gate working exactly as intended.
  //
  // The third source is the one place a row's pitch is still observable live:
  // **the BUS's degradation valve**. A bus reserves five rows and sheds them a
  // WHOLE row at a time as the window shrinks, so the distinct section heights it
  // takes across a window sweep are `section(n)` for consecutive n — and the step
  // between them IS the row pitch. Measured, not read off the constant, and it
  // exercises the valve as a bonus. If a future cycle fixes the bus's reserve
  // against window height too, this leg will difference zero and will need a
  // fourth source; that is the honest failure, not a false green.
  const busTrack = (await must("track.add", { name: "BUSPITCH", kind: "bus" })).id;
  const masterHeights = [], reserveHeights = [];
  for (let n = 1; n <= 4; n++) {
    await must("fx.add", { trackId: "master", kind: "gain" });
    await must("fx.add", { trackId: soloTrack, kind: "gain" });
    await must("fx.add", { trackId: busTrack, kind: "gain" });
    await sleep(600);
    const f = await must("debug.explainFrames", {
      ids: ["mixerMasterInserts", "mixerInserts"] });
    masterHeights.push(((f.frames.mixerMasterInserts || [])[0] || {}).height ?? null);
    reserveHeights.push(((f.frames.mixerInserts || [])[0] || {}).height ?? null);
  }
  ck("E1 section heights measured at every chain length",
     masterHeights.every((h) => typeof h === "number")
     && reserveHeights.every((h) => typeof h === "number"),
     JSON.stringify([masterHeights, reserveHeights]));

  // The pitch sweep. Heights chosen to straddle the 5→4 boundary (measured near
  // a 668 pt window); the assertion does not depend on WHERE the step lands, only
  // that every value is a whole number of rows and that consecutive distinct
  // values differ by one row's pitch.
  const busSeen = [];
  for (const h of [900, 800, 700, 680, 670, 660, 650, 640]) {
    await must("debug.windowFrame", { width: 1440, height: h });
    await sleep(650);
    const f = await must("debug.explainFrames", { ids: ["mixerInserts"] });
    const bus = ((f.frames.mixerInserts || [])[1] || {}).height ?? null;
    if (typeof bus === "number" && !busSeen.some((v) => Math.abs(v - bus) < 0.6)) busSeen.push(bus);
  }
  await must("debug.windowFrame", { width: 1440, height: 900 });
  await sleep(650);
  // Each observed height must decompose as header 16 + gap 4 + n rows of 24 with
  // (n-1) gaps of 4 — i.e. it must be `section(n)` for an integer n in 1…5.
  const slotsFor = (h) => (h - 16 - 4 + 4) / 28;
  const ints = busSeen.map(slotsFor);
  const sorted = [...busSeen].sort((a, b) => a - b);
  const steps = sorted.slice(1).map((v, i) => v - sorted[i]);
  ck("E2 a row's pitch is still 28 (row 24 + gap 4) — MEASURED off the bus valve's steps",
     busSeen.length >= 2
     && ints.every((n) => Math.abs(n - Math.round(n)) < 0.03 && n >= 1 && n <= 5)
     && steps.every((d) => Math.abs(d - 28) < 0.6),
     JSON.stringify({ busSeen, slots: ints.map((n) => +n.toFixed(2)), steps }));

  ck("E3 the channel's 3-slot reserve is unmoved: 100 pt at every chain length",
     reserveHeights.every((h) => Math.abs(h - 100) < 0.6), JSON.stringify(reserveHeights));
  // m23-ax: the master is now FIXED too, and this is the leg that says so. It
  // replaces nothing — E2's old assertion measured a pitch; this measures the
  // reserve. 156 = header 16 + gap 4 + five rows (5×24 + 4×4).
  ck("E4 the MASTER reserve is FIXED at 156 pt at every chain length (m23-ax; it HUGGED before)",
     masterHeights.every((h) => Math.abs(h - 156) < 0.6), JSON.stringify(masterHeights));
  await must("debug.explainMode", { on: false });

  // ──────────────────────────────────────────────────────────────────────
  // The sweep project: ALL TEN built-in kinds on a CHANNEL strip (the tight
  // case, 112 pt of content) and again on the MASTER chain (132 pt), with every
  // GR bar lit — an unseeded capture would measure the bar-less layout and prove
  // nothing about the rows that were truncating.
  // ──────────────────────────────────────────────────────────────────────
  await must("project.new", { discardChanges: true });
  // ⚠️ RESET HERE, BEFORE ANYTHING LAYS OUT — never between arranging and
  // reading. The reporters fire from `GeometryReader`s, so dropping the
  // readings and immediately asking for them measures nothing (verified: 0 rows
  // after a bare reset). Resetting on the empty project drops phase E's rows and
  // lets the next real layout repopulate every field.
  await must("debug.insertLabels", { reset: true });
  const chan = (await must("track.add", { name: "SWEEP" })).id;
  for (const k of BUILT_INS) await must("fx.add", { trackId: chan, kind: k });
  for (const k of BUILT_INS) await must("fx.add", { trackId: "master", kind: k });

  // Leg C's fixture: the longest-named AU effect installed on this machine.
  // Picking the longest is deliberate — a short vendor name would fit the 63 pt
  // AU budget and the leg would pass while proving nothing.
  let auName = null, auEffectId = null, auSkipReason = null;
  try {
    const list = await must("fx.listAudioUnits", {});
    const units = (list.audioUnits || []).slice().sort((a, b) => b.name.length - a.name.length);
    if (units.length === 0) {
      auSkipReason = "no AU effects installed";
    } else {
      const added = await must("debug.mixerAddAU", { trackId: chan, subType: units[0].subType });
      if (added.ok) { auName = added.name; auEffectId = added.effectId; }
      else auSkipReason = added.reason || "debug.mixerAddAU refused";
    }
  } catch (e) {
    auSkipReason = e.message;
  }

  await must("debug.grSeed", { db: 6 });
  await must("ui.showMixer", { show: true });
  await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
  await must("debug.windowFrame", { width: 1440, height: 900 });
  await sleep(1800);

  let r = await rows();
  ck("S0 every arranged row reported, with no field left unmeasured",
     r.rows.length >= 20
     && r.rows.every((x) => typeof x.drawn === "number" && typeof x.intrinsic === "number"
                            && typeof x.line === "number" && typeof x.pinned === "boolean"),
     `${r.rows.length} rows; unmeasured: ` + JSON.stringify(
       r.rows.filter((x) => x.intrinsic === null || x.line === null || x.pinned === null)
             .map((x) => x.label)));
  ck("S1 the mixer is showing in Pro (the rows exist to be measured)",
     r.mixerVisible === true && r.mixerDensity === "pro", JSON.stringify([r.mixerVisible, r.mixerDensity]));

  const chanRows = r.rows.filter((x) => x.chain === "track");
  const masterRows = r.rows.filter((x) => x.chain === "master");

  // ── LEG A — the CHANNEL sweep ─────────────────────────────────────────
  const chanBuiltIns = chanRows.filter((x) => x.kind !== "audioUnit");
  ck("A0 all ten built-in kinds reported a drawn label on the channel strip",
     chanBuiltIns.length === 10, `${chanBuiltIns.length}: ` +
     JSON.stringify(chanBuiltIns.map((x) => x.kind)));

  let a1 = true, a2 = true, a3 = true, a4 = true, a5 = true;
  const aDetail = [];
  for (const kind of BUILT_INS) {
    const row = byKind(chanRows, kind, "track");
    if (!row) { a1 = a2 = a3 = a4 = a5 = false; aDetail.push(`${kind}: MISSING`); continue; }
    const n = (v) => (typeof v === "number" ? v.toFixed(2) : String(v));
    aDetail.push(`${kind} "${row.label}" drawn=${n(row.drawn)} intrinsic=${n(row.intrinsic)} avail=${n(row.available)} line=${n(row.line)} pinned=${row.pinned}`);
    if (row.label !== EXPECTED_NAME[kind]) a1 = false;
    if (row.pinned !== true) a2 = false;
    if (row.truncated !== false) a3 = false;
    if (row.overflows !== false) a4 = false;
    if (Math.abs(row.line - CHANNEL_LINE) > EPS) a5 = false;
  }
  console.log(aDetail.map((d) => "     " + d).join("\n"));
  ck("A1 every channel row drew the vocabulary's exact string", a1);
  ck("A2 every built-in label is PINNED (fixedSize) — the classification", a2);
  ck("A3 NO built-in label truncates on a channel strip, Bass Enhancer included", a3);
  // ⚠️ A4 IS THE WEAK ONE, AND THE MUTATION PROVED IT. `overflows` compares the
  // label against the name line's MEASURED width — but an `HStack` whose pinned
  // child demands more than it was proposed reports the DEMANDED width, so the
  // line grows with the label and `overflows` can never fire. Measured: with the
  // row's horizontal padding mutated 7 → 18 the line reported 86 instead of 76
  // and A4 stayed GREEN. The legs that caught that mutation are A5 and A9, which
  // pin the line and the budget against LITERALS. Keep A4 anyway — it is the leg
  // that fires if the overflow ever becomes visible to the layout — but do not
  // mistake it for the guard.
  ck("A4 no built-in label overflows the row's content box (see the note: weak on its own)", a4);
  ck("A5 the channel name line measured 98 pt — the layout the budget assumes", a5);
  ck("A9 every channel built-in got the full 85 pt budget — intrinsic ≤ available, with available PINNED",
     chanBuiltIns.length === 10
     && chanBuiltIns.every((x) => Math.abs(x.available - 85) < EPS && x.intrinsic <= x.available + EPS),
     JSON.stringify(chanBuiltIns.map((x) => [x.kind, x.available])));

  // A pinned label cannot be wider than it wants to be: drawn == intrinsic is
  // the check that the twin has not drifted from the drawn label's type. If it
  // ever fails, `truncated` above is describing a different string.
  const a6 = chanBuiltIns.every((x) => Math.abs(x.drawn - x.intrinsic) < 0.01);
  ck("A6 pinned labels report drawn == intrinsic (the twin still measures the drawn type)", a6,
     JSON.stringify(chanBuiltIns.map((x) => [x.kind, x.drawn, x.intrinsic])));

  // ANTI-VACUITY, tied to the DEFECT rather than to a slack threshold. Each of
  // the three names the item was filed for is still WIDER than the budget it had
  // before this cycle — 33 pt with the GR bar in the flow, 63 pt without it — so
  // the leg cannot go green by the fix having been unnecessary, and it goes red
  // if a later change quietly re-narrows the row.
  const tight = ["limiter", "compressor", "bassEnhancer"].map((k) => byKind(chanRows, k, "track"));
  const OLD_WITH_BAR = 33, OLD_BAR_LESS = 63;
  ck("A7 the three REPORTED truncations still exceed their PRE-m23-s budgets, and now fit",
     tight.every((x) => !!x)
     && tight[0].drawn > OLD_WITH_BAR && tight[1].drawn > OLD_WITH_BAR
     && tight[2].drawn > OLD_BAR_LESS
     && tight.every((x) => x.drawn <= x.available + EPS),
     JSON.stringify(tight.map((x) => x && [x.kind, x.drawn, x.available])));
  const be = byKind(chanRows, "bassEnhancer", "track");
  ck("A8 Bass Enhancer measures 70…75 pt — the widest name, against an 85 pt budget",
     be && be.drawn > 70 && be.drawn < 75 && be.available > 84 && be.available < 86,
     be && JSON.stringify([be.drawn, be.available]));

  // ── LEG B — the MASTER sweep ──────────────────────────────────────────
  const masterBuiltIns = masterRows.filter((x) => x.kind !== "audioUnit");
  ck("B0 all ten built-in kinds reported a drawn label on the master chain",
     masterBuiltIns.length === 10, `${masterBuiltIns.length}`);
  let b1 = true, b2 = true, b3 = true;
  for (const kind of BUILT_INS) {
    const row = byKind(masterRows, kind, "master");
    if (!row) { b1 = b2 = b3 = false; continue; }
    if (row.pinned !== true || row.label !== EXPECTED_NAME[kind]) b1 = false;
    if (row.truncated !== false || row.overflows !== false) b2 = false;
    if (Math.abs(row.line - MASTER_LINE) > EPS) b3 = false;
  }
  ck("B1 every master row drew the exact string and is PINNED", b1);
  ck("B2 NO built-in label truncates on the master chain", b2);
  ck("B3 the master name line measured 118 pt", b3);
  ck("B4 every master built-in got the full 105 pt budget — intrinsic ≤ available, PINNED",
     masterBuiltIns.length === 10
     && masterBuiltIns.every((x) => Math.abs(x.available - 105) < EPS && x.intrinsic <= x.available + EPS),
     JSON.stringify(masterBuiltIns.map((x) => [x.kind, x.available])));

  // ── LEG C — an AU name is soft data and STILL truncates ───────────────
  if (auEffectId) {
    const au = r.rows.find((x) => x.effectId === auEffectId);
    ck("C0 the AU insert reported a drawn label", !!au, auName);
    ck("C1 the AU label is NOT pinned — the other half of the classification",
       au && au.pinned === false, au && String(au.pinned));
    ck("C2 the AU label STILL TRUNCATES (a fix that stopped this solved a different problem)",
       au && au.truncated === true,
       au && JSON.stringify([auName, au.label, au.drawn, au.intrinsic]));
    // The AU row keeps its 16 pt window glyph, so its label slot is 63 pt, not
    // the built-in 85. A truncated `Text` reports the width of what it actually
    // drew, which is at most the slot (measured 60 for `AUMultibandCompressor`)
    // — so the assertion is "inside the AU slot and nowhere near the built-in
    // budget", never an equality with the slot.
    ck("C3 the AU row still pays 22 pt for its window glyph (label ≤ 63, not 85)",
       au && au.drawn <= 63 + EPS && au.drawn > 40, au && String(au.drawn));
  } else {
    // Never skipped silently. The soft-name path is still pinned by the
    // headless suite (`vendorNamesStillTruncate`) and by the arithmetic that the
    // AU budget is 22 pt narrower than the built-in one — but the DRAWING half
    // is genuinely unproven on this machine, and the gate says so out loud.
    ck("C0 an AU effect was loadable for the soft-name leg", false,
       `NOT PROVEN IN PIXELS: ${auSkipReason}`);
  }

  // ── LEG D — m22-e behaviour unchanged: the GR underline still ticks in its
  // OWN UNPAUSED `.periodic` TimelineView, while the app is NOT frontmost.
  // ──────────────────────────────────────────────────────────────────────
  stealFocusForever();
  await sleep(2500);
  await must("debug.grSeed", { db: 2 });
  await must("debug.insertLabels", { resetBarTicks: true });
  await sleep(2000);
  const low = await rows();
  const lowLim = byKind(low.rows, "limiter", "track");
  ck("D0 the app was NOT frontmost while leg D measured (the bug is invisible if it was)",
     low.appActive === false, String(low.appActive));
  ck("D1 the GR underline drew frames while unfocused (its own unpaused .periodic timeline)",
     lowLim && lowLim.bar && lowLim.bar.ticks >= 8,
     lowLim && lowLim.bar && String(lowLim.bar.ticks));
  ck("D2 the underline spans the name line — 98 pt, not the old 24 pt chip",
     lowLim && lowLim.bar && Math.abs(lowLim.bar.width - CHANNEL_LINE) < EPS,
     lowLim && lowLim.bar && String(lowLim.bar.width));

  await must("debug.grSeed", { db: 18 });
  await must("debug.insertLabels", { resetBarTicks: true });
  await sleep(2000);
  const high = await rows();
  const highLim = byKind(high.rows, "limiter", "track");
  ck("D3 still not frontmost for the second reading", high.appActive === false);
  // ⚠️ D4 IS NOT THE FREEZE DETECTOR — D1 IS, and the mutation says so. With the
  // poll interval mutated to 3600 s (a layer that ticks once an hour) D4 stayed
  // GREEN: `grSeed` is observed, so re-seeding invalidates the view and the
  // TimelineView's content re-runs regardless of its schedule. D4 proves the
  // drawn value FOLLOWS THE DATA (no stale smoothing, no fabricated reading);
  // only D1's tick count proves the layer runs on its own clock. Both, always.
  ck("D4 the DRAWN fraction followed a re-seeded reading while unfocused (see note: not the freeze leg)",
     lowLim && highLim && highLim.bar.fraction > lowLim.bar.fraction + 0.1,
     JSON.stringify([lowLim && lowLim.bar.fraction, highLim && highLim.bar.fraction]));
  // A bar-less kind must still grow NO bar: nil poll = nothing drawn, never a
  // faked dead meter (the m22-e honesty rule the underline must not weaken).
  const be2 = byKind(high.rows, "bassEnhancer", "track");
  ck("D5 a non-dynamics insert still draws NO bar at all", be2 && be2.bar === undefined,
     be2 && JSON.stringify(be2.bar));
  stopStealing();

  // The forbidden idiom, by source. Cheap, and it catches the reintroduction a
  // behavioural leg would only catch when the machine happens to be unfocused.
  const grSrc = readFileSync(`${ROOT}/Sources/DAWApp/Components/GainReductionMeter.swift`, "utf8");
  // Comment lines are stripped first: the file DOCUMENTS the forbidden idiom by
  // name (that is how the law travels), so a naive substring search reports a
  // violation that is really a citation.
  const grCode = grSrc.split("\n").filter((l) => !l.trim().startsWith("//")).join("\n");
  ck("D6 `.animation(paused:` appears in no CODE line of the GR meter file",
     !grCode.includes(".animation(paused"));
  ck("D7 the underline still rides `TimelineView(.periodic`",
     grSrc.includes("TimelineView(.periodic(from: .now, by: Self.pollInterval))"));

  // ── PIXELS — the human-readable evidence, at both windows ─────────────
  await must("debug.grSeed", { db: 6 });
  for (const [w, h, tag] of [[1440, 900, "default"], [1440, 640, "floor"]]) {
    await must("debug.windowFrame", { width: w, height: h });
    await sleep(1200);
    await must("debug.captureUI", { path: `${OUT}/mixer-${tag}.png` });
  }
  // At the 640 pt floor the reserve degrades in WHOLE rows, so the labels must
  // still be whole there too — this is the same read, at the window that used to
  // clip.
  // No reset here on purpose (see above): the ids are unchanged, so the floor
  // read is the SAME rows re-measured at the smaller window.
  await sleep(1400);
  const floor = await rows();
  const floorBuiltIns = floor.rows.filter((x) => x.chain === "track" && x.kind !== "audioUnit");
  ck("F1 at the 1440×640 floor no built-in label truncates either",
     floorBuiltIns.length === 10 && floorBuiltIns.every((x) => !x.truncated && !x.overflows),
     `${floorBuiltIns.length} rows`);
  console.log(`\ncaptures in ${OUT}`);
} catch (e) {
  console.log("GATE ERROR:", e.message);
  fail++;
} finally {
  stopStealing();
  stopStaging(GATE);
}

console.log(`\nm23-s gate: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
