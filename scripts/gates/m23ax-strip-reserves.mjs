// m23-ax GATE — per-class insert reserves: the master and bus strips get MORE
// slots than a channel, drawn FIXED, with a longer chain scrolling inside.
//
// THE USER'S WORDS (2026-07-30): "inserts in master and bus with more slots by
// default should also be fixed and scrollable." Three asks, and they land
// differently per strip class, which is what this gate exists to keep straight:
//   • a BUS was already fixed and scrollable (it renders through
//     `MixerChannelStrip`) — it lacked only the extra slots;
//   • the MASTER had NONE of the three: it passed `rowsViewportHeight: nil` and
//     HUGGED its chain, so every insert pushed the fader and everything under it
//     28 pt further down;
//   • a CHANNEL was deliberately left at three, so every channel assertion here
//     and in `MixerStripLayoutTests` is a live CONTROL on the change.
//
// ⚠️ DISCRIMINATION — this gate's assertions are stated against numbers MEASURED
// ON THE PRE-CHANGE BINARY, before a line of the feature was written
// (`scratchpad/measure-ax.mjs`, transcript in /tmp/daw-gate-out/ax-measure).
// That is stronger evidence than mutating the source afterwards, because it is
// the real old build rather than a reconstruction of it. What it recorded, at
// 1440x900, master chain 0 → 8:
//     master inserts section  35, 44, 72, 100, 128, 156, 184, 212, 240  (+28/insert)
//     master fader region y  275, 284, 312, 340, 368, 396, 424, 452, 480  (205 pt of travel)
//     channel + bus section  100 at every single one of those lengths
// Every leg below would have FAILED on that binary except the channel control,
// which must still pass unchanged. If a future edit makes these legs pass for a
// new reason, that table is what to re-measure against.
//
// Staging 17695 ONLY. 17600 is the user's LIVE app and is never touched.
// Kill by EXACT pid from the pidfile — never pkill/pgrep.
import { mkdirSync, writeFileSync } from "node:fs";

// Build → launch 17695 → pidfile-exact kill, in ONE place (m23-ac-1).
import { launchStaging, stopStaging, sleep, STAGING_PORT } from "./_staging.mjs";

const GATE = "m23ax";
const OUT = "/tmp/daw-gate-out/m23ax";
mkdirSync(OUT, { recursive: true });

// ---- the expected geometry, from `MixerStripLayout` -------------------------
// Spelled as literals, not imported: a gate that recomputed the app's own
// arithmetic would agree with itself while the view drew something else
// (the m23-p2 law).
const ROW = 24, GAP = 4, HEADER = 16;
const rows = (n) => n * ROW + (n - 1) * GAP;
const section = (n) => HEADER + GAP + rows(n);
const CHANNEL_SECTION = section(3);   // 100 — UNCHANGED, the control
const WIDE_SECTION    = section(5);   // 156 — bus + master
const EPS = 0.6;

let ws, seq = 0;
function cmd(command, params = {}, timeoutMs = 60000) {
  return new Promise((res, rej) => {
    const id = `ax-${++seq}`;
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
const same = (xs, target) => xs.length > 0 && xs.every((v) =>
  typeof v === "number" && Math.abs(v - target) < EPS);

const IDS = ["mixerMasterInserts", "mixerInserts", "mixerMaster", "masterAutomation"];
async function frames() {
  const f = await must("debug.explainFrames", { ids: IDS });
  const pick = (id) => (f.frames[id] || []).map((r) => ({ y: r.y, h: r.height }));
  return { master: pick("mixerMasterInserts"), strips: pick("mixerInserts"),
           fader: pick("mixerMaster"), automation: pick("masterAutomation") };
}

const record = {};

try {
  const staging = await launchStaging({ gate: GATE, port: STAGING_PORT, settleMs: 3500 });
  ws = staging.ws;

  // ── the fixture: one channel, one bus, and the master ────────────────────
  await must("project.new", { discardChanges: true });
  const chan = (await must("track.add", { name: "CH" })).id;
  const bus = (await must("track.add", { name: "BUS", kind: "bus" })).id;
  await must("ui.showMixer", { show: true });
  await must("debug.panelDensity", { panel: "mixer", mode: "pro" });
  await must("debug.windowFrame", { width: 1440, height: 900 });
  await must("debug.explainMode", { on: true });
  await sleep(1200);

  const masterH = [], chanH = [], busH = [], faderY = [], autoY = [];
  const collect = (f) => {
    masterH.push(f.master[0]?.h ?? null);
    chanH.push(f.strips[0]?.h ?? null);
    busH.push(f.strips[1]?.h ?? null);
    faderY.push(f.fader[0]?.y ?? null);
    autoY.push(f.automation[0]?.y ?? null);
  };

  const f0 = await frames();
  ck("A0 the console drew one channel strip AND one bus strip (the fixture is real)",
     f0.strips.length === 2, JSON.stringify(f0.strips));
  collect(f0);

  // Grow all three chains together, 1 → 8. The master's own recorded growth
  // (+28/insert) is what this loop is refuting.
  for (let n = 1; n <= 8; n++) {
    await must("fx.add", { trackId: "master", kind: "gain" });
    await must("fx.add", { trackId: chan, kind: "gain" });
    await must("fx.add", { trackId: bus, kind: "gain" });
    await sleep(420);
    collect(await frames());
  }
  record.default900 = { masterH, chanH, busH, faderY, autoY };

  // ── LEG A — the MASTER is FIXED (ask b) and WIDER (ask a) ────────────────
  ck(`A1 the master inserts section is FIXED at ${WIDE_SECTION} pt across chains 0-8`,
     same(masterH, WIDE_SECTION), JSON.stringify(masterH));
  ck("A2 …and it is the same at chain 0 as at chain 8 — the hug is gone (was 35 → 240)",
     masterH[0] === masterH[8], JSON.stringify([masterH[0], masterH[8]]));
  ck("A3 the master reserve is WIDER than a channel's — the actual request",
     masterH[0] > CHANNEL_SECTION, JSON.stringify([masterH[0], CHANNEL_SECTION]));

  // ── LEG B — what the fix is FOR: the blocks below stop moving ────────────
  // The user's complaint in geometric form. Before this change the master's
  // fader travelled 275 → 480 as the chain grew; the automation lane above it
  // moved too. Both must now be still.
  ck("B1 the master FADER region does not move as the chain grows (was 275 → 480)",
     same(faderY, faderY[0]), JSON.stringify(faderY));
  ck("B2 the master AUTOMATION lane does not move either (it sits between them)",
     same(autoY, autoY[0]), JSON.stringify(autoY));

  // ── LEG C — the BUS gets more slots (ask a) ──────────────────────────────
  ck(`C1 the BUS reserve is ${WIDE_SECTION} pt at the default window (was 100)`,
     same(busH, WIDE_SECTION), JSON.stringify(busH));
  ck("C2 …and is FIXED across every chain length, as it already was at 3 slots",
     busH[0] === busH[8], JSON.stringify([busH[0], busH[8]]));

  // ── LEG D — THE CONTROL. The channel must be untouched ───────────────────
  // If this ever goes red the change leaked out of its blast radius, and the
  // whole "the existing suite is a control" argument collapses with it.
  ck(`D1 CONTROL: the channel reserve is still exactly ${CHANNEL_SECTION} pt at every chain length`,
     same(chanH, CHANNEL_SECTION), JSON.stringify(chanH));

  // ── LEG E — SCROLLABLE (ask c): a chain LONGER than the reserve ──────────
  // What can honestly be proven over the wire: all eight rows are laid out and
  // reporting, while the container that holds them is bounded at five slots. So
  // the scroll content (8 rows = 220 pt) exceeds its viewport (136 pt) by 84 pt,
  // which is precisely the condition under which a SwiftUI ScrollView scrolls.
  // ⚠️ This gate does NOT synthesise a scroll gesture — it proves the geometry
  // that makes scrolling possible and necessary, not the wheel event.
  const labels = await must("debug.insertLabels", {});
  const masterRows = (labels.rows || []).filter((r) => r.chain === "master");
  const busRows = (labels.rows || []).filter((r) => r.chain !== "master");
  record.rowCounts = { master: masterRows.length, other: busRows.length };
  ck("E1 all EIGHT master rows are laid out and reporting, though only five fit",
     masterRows.length === 8, JSON.stringify(masterRows.length));
  const content = rows(8), viewport = rows(5);
  ck(`E2 the master scroll content (${content} pt) exceeds its viewport (${viewport} pt)`,
     content > viewport, JSON.stringify([content, viewport]));
  ck("E3 …and the section as DRAWN equals the viewport plus its header, not the content",
     Math.abs(masterH[8] - (HEADER + GAP + viewport)) < EPS
     && Math.abs(masterH[8] - (HEADER + GAP + content)) > EPS,
     JSON.stringify([masterH[8], HEADER + GAP + viewport, HEADER + GAP + content]));

  await must("debug.captureUI", { path: `${OUT}/reserves-8-900.png` });

  // ── LEG F — the VALVE, and the class that has none ───────────────────────
  // At the 640 pt window floor five rows cannot be seated, so the bus SHEDS. The
  // master has no valve at all — it rides its own scroller, so it cannot clip and
  // keeps all five. Both facts in one leg because the contrast IS the design.
  //
  // ⚠️ IT SHEDS TO FOUR HERE, NOT THREE, and that gap is worth understanding.
  // `MixerStripLayout.stripHeightAtWindowFloor` is **430**, documented as
  // "conservatively rounded DOWN from ~440". Feed 430 through the budget and you
  // predict 126 pt of room → 106 pt of allowance → three slots, because four need
  // 108. The REAL strip at a 640 pt window is those ~10 pt taller, so the app
  // seats four (128 = header 16 + gap 4 + rows(4) 108). Nothing is broken: the
  // conservative constant is doing its job, and it is conservative in the SAFE
  // direction. But it means the headless
  // `busReserveDegradesOnlyWithRoom` test and this leg disagree by one slot BY
  // CONSTRUCTION — the test pins the model, this pins the pixels. Do not
  // "reconcile" them by loosening either; the pair is the point.
  await must("debug.windowFrame", { width: 1440, height: 640 });
  await sleep(1100);
  const ff = await frames();
  record.floor640 = { master: ff.master[0]?.h, chan: ff.strips[0]?.h, bus: ff.strips[1]?.h };
  ck(`F1 at the 640 pt window floor the BUS sheds to FOUR slots (${section(4)} pt) — MEASURED`,
     Math.abs((ff.strips[1]?.h ?? -1) - section(4)) < EPS, JSON.stringify(ff.strips));
  ck("F1b …i.e. it really did shed — fewer than five, and a WHOLE number of rows",
     (ff.strips[1]?.h ?? -1) < WIDE_SECTION - EPS
     && [1, 2, 3, 4, 5].some((n) => Math.abs((ff.strips[1]?.h ?? -1) - section(n)) < EPS),
     JSON.stringify(ff.strips[1]));
  ck("F2 the CHANNEL is unchanged at the floor too (control, second window size)",
     Math.abs((ff.strips[0]?.h ?? -1) - CHANNEL_SECTION) < EPS, JSON.stringify(ff.strips));
  ck(`F3 the MASTER keeps all five at the floor — it scrolls, so it never has to shed`,
     Math.abs((ff.master[0]?.h ?? -1) - WIDE_SECTION) < EPS, JSON.stringify(ff.master));
  await must("debug.captureUI", { path: `${OUT}/reserves-8-640.png` });

  // ── LEG G — collapse still hands EVERYTHING back, on all three classes ───
  // The disclosure's help text promises the fader more room. A reserve that
  // survived the fold would make that text false (DESIGN-LANGUAGE forbids a
  // do-nothing toggle), and the master is a NEW member of this rule.
  await must("debug.windowFrame", { width: 1440, height: 900 });
  await sleep(700);
  await must("debug.panelLayout", { mixerInsertsCollapsed: true });
  await sleep(800);
  const cf = await frames();
  record.collapsed = { master: cf.master[0]?.h, chan: cf.strips[0]?.h, bus: cf.strips[1]?.h };
  ck("G1 collapsed, every class is its 16 pt header alone — master included",
     [cf.master[0]?.h, cf.strips[0]?.h, cf.strips[1]?.h]
       .every((h) => typeof h === "number" && Math.abs(h - HEADER) < EPS),
     JSON.stringify(record.collapsed));
  await must("debug.panelLayout", { mixerInsertsCollapsed: false });

  await must("debug.explainMode", { on: false });
  writeFileSync(`${OUT}/record.json`, JSON.stringify(record, null, 2));
} catch (e) {
  fail++;
  console.log("GATE ERROR: " + (e?.stack || e));
} finally {
  try { ws?.close(); } catch {}
  stopStaging(GATE);
}

console.log(`\nm23ax: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
