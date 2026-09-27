// W7-TBF1 — THE TRANSPORT BAR AT THE WINDOW FLOOR: looked-at captures + explain
// frames on STAGING (port 17695 only; 17600 is the user's live app and is never
// touched).
//
// What it proves: in every state the fit rule (`DAWAppKit.TransportBarFit`) plans
// for — Simple and Pro × looper closed, open and recording × notices off and on —
// at 1208, 1600 and 2400 pt, the master meter and the SIMPLE/PRO toggle end INSIDE
// the bar (their explain frames' right edges ≤ the bar's content edge, W − 28),
// the drawn loop deck is the width the rule MODELLED (after binaries; see
// DECK_MODEL), and a capture of the bar exists to LOOK at. Run it once per binary:
//
//   TBF1_LABEL=before TBF1_BINARY=<abs path to the pre-change DAWApp> node scripts/gates/w7-tbf1-capture.mjs
//   TBF1_LABEL=after  TBF1_BINARY=<abs path to the post-change DAWApp> node scripts/gates/w7-tbf1-capture.mjs
//
// TBF1_LAUNCH_PROBE=1 launches, measures ONE state's frames (Pro, a notice, an open
// deck, 1208 pt — TB-F1's worst resting case) and stops, WITHOUT captures: the
// proof that the script reaches and passes its launch step while the screen is
// locked (a capture then would be inconclusive). TBF1_PROBE_CAPTURE=1 adds
// DIAGNOSTIC shots (recording at 1208 and 1600, open at 1600) — looked at, never
// counted as the gate's before/after evidence.
//
// The user may be at the keyboard, so: DAWPRO_STAGING_NO_ACTIVATE=1 (the app
// never takes focus), the frontmost app is recorded before the launch and after
// the gate (a change to the staging app or to Finder is a FOCUS THEFT and fails
// the run), and the staging child is killed PIDFILE-EXACT by `stopStaging`.
// It takes `$S/locks/staging.lock` itself and releases it only if it still
// carries this run's tag. It builds nothing: the binary is the caller's.
import { mkdirSync, writeFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { join, isAbsolute } from "node:path";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  ROOT, DEFAULT_BINARY, STAGING_DEFAULTS_DOMAIN, sleep, launchStaging, stopStaging,
  panelDensityGuard,
} from "./_staging.mjs";

const GATE = "w7-tbf1";
const SCR = process.env.TBF1_SCRATCH
  || "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/cc1b3823-79f0-4b80-950f-ca6f315857d1/scratchpad";
const LANE = join(SCR, "w7", "TBF1");
const LABEL = process.env.TBF1_LABEL || "after";
const PROBE = process.env.TBF1_LAUNCH_PROBE === "1";
// A DIAGNOSTIC capture in probe mode (never the gate's evidence: on a locked
// screen a capture is inconclusive by the lane's rule).
const PROBE_CAPTURE = PROBE && process.env.TBF1_PROBE_CAPTURE === "1";
const BINARY = process.env.TBF1_BINARY || join(ROOT, DEFAULT_BINARY);
const WIDTHS = (process.env.TBF1_WIDTHS || "1208,1600,2400").split(",").map(Number);
const HEIGHT = 672;
const OUT = join(LANE, PROBE ? "probe" : `cap-${LABEL}`);
const LOCK = join(SCR, "locks", "staging.lock");
const TAG = `W7-TBF1 capture ${LABEL} pid${process.pid} ${Date.now()}`;
const PROJECT = join(LANE, "TBF1 Transport Floor.dawproj");
mkdirSync(join(OUT, "crops"), { recursive: true });

// ── The frontmost app (the w7 focus law's instrument) ──────────────────────────
function frontmostApp() {
  const front = spawnSync("lsappinfo", ["front"], { encoding: "utf8" });
  const asn = (front.stdout ?? "").trim();
  if (!asn) return { name: null, pid: null, raw: `lsappinfo front: ${(front.stderr ?? "").trim() || "no output"}` };
  const info = spawnSync("lsappinfo", ["info", "-only", "pid,name", asn], { encoding: "utf8" });
  const raw = (info.stdout ?? "").trim();
  const m = /"LSDisplayName"="([^"]*)"/.exec(raw);
  const p = /"pid"=(\d+)/.exec(raw);
  return { name: m ? m[1] : null, pid: p ? Number(p[1]) : null, raw };
}

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok: !!ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}${detail === undefined ? "" : `\n        ${typeof detail === "string" ? detail : JSON.stringify(detail)}`}`);
};

// ── Preconditions: an unlocked screen, a real binary, the staging lock ─────────
const front0 = frontmostApp();
console.log(`label ${LABEL}${PROBE ? " (LAUNCH PROBE)" : ""}; frontmost before the launch: ${front0.name ?? front0.raw}`);
if (front0.name === null) { console.log(`ABORT (proves nothing): lsappinfo named no frontmost app (${front0.raw})`); process.exit(2); }
if (front0.name === "loginwindow" && !PROBE) {
  console.log("PENDING: the screen is LOCKED (frontmost: loginwindow). A capture now would be inconclusive; "
    + "re-run on an unlocked screen, or set TBF1_LAUNCH_PROBE=1 to prove the launch step.");
  process.exit(2);
}
if (front0.name === STAGING_DEFAULTS_DOMAIN) {
  console.log(`ABORT: a staging app (${STAGING_DEFAULTS_DOMAIN}) is ALREADY frontmost — a previous run left it.`);
  process.exit(2);
}
if (!isAbsolute(BINARY) || !existsSync(BINARY)) { console.log(`ABORT: no binary at ${BINARY}`); process.exit(2); }
const sha = createHash("sha256").update(readFileSync(BINARY)).digest("hex");
console.log(`binary ${BINARY}\n  sha256 ${sha}`);

function takeLock() {
  for (let i = 0; i < 90; i++) {
    try {
      mkdirSync(LOCK);
      writeFileSync(join(LOCK, "owner.txt"), `${TAG} ${new Date().toISOString()}\n`);
      return true;
    } catch {
      let owner = "?";
      try { owner = readFileSync(join(LOCK, "owner.txt"), "utf8").trim(); } catch { /* none */ }
      if (i % 6 === 0) console.log(`staging.lock held (${owner}) — waiting`);
      spawnSync("sleep", ["10"]);
    }
  }
  return false;
}
function releaseLock() {
  try {
    if (readFileSync(join(LOCK, "owner.txt"), "utf8").includes(TAG)) {
      rmSync(LOCK, { recursive: true, force: true });
      console.log("staging.lock released");
    } else {
      console.log("staging.lock no longer carries this run's tag — left alone");
    }
  } catch { /* not ours / already gone */ }
}
if (!takeLock()) { console.log("ABORT: staging.lock not free after 15 min"); process.exit(2); }

const killer = setTimeout(() => {
  console.log("TIMEOUT 14 min");
  try { stopStaging(GATE); } catch { /* best effort */ }
  releaseLock();
  process.exit(3);
}, 14 * 60_000);

// ── The session ────────────────────────────────────────────────────────────────
let session;
try {
  session = await launchStaging({
    gate: GATE, binary: BINARY, skipBuild: true, settleMs: 1500,
    env: { DAWPRO_STAGING_NO_ACTIVATE: "1" },
  });
} catch (e) {
  console.log(`ABORT: launch failed — ${e.message}`);
  releaseLock();
  process.exit(2);
}
console.log(`staging pid ${session.pid} (DAWPRO_STAGING_NO_ACTIVATE=1)`);
const ws = session.ws;
let n = 0;
function raw(command, params = {}) {
  return new Promise((resolve, reject) => {
    const id = `tbf1-${++n}`;
    const t = setTimeout(() => reject(new Error(`TIMEOUT ${command}`)), 25000);
    const on = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id !== id) return;
      clearTimeout(t); ws.removeEventListener("message", on); resolve(m);
    };
    ws.addEventListener("message", on);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
async function must(command, params = {}) {
  const r = await raw(command, params);
  if (!r || r.ok !== true) throw new Error(`${command} failed — ${JSON.stringify(r?.error ?? r)}`);
  return r.result;
}
const density = panelDensityGuard(raw);

const IDS = [
  "transportPosition", "transportTime", "transportTempo",
  "musicalTyping", "loopDeck", "transportExport", "transportTestTone",
  "transportEngineNotices", "vibeMeter", "transportMasterFader", "panelDensity",
];
async function measure() {
  await must("debug.explainMode", { on: true });
  await sleep(450);
  const f = await must("debug.explainFrames", { ids: IDS });
  await must("debug.explainMode", { on: false });
  await sleep(350);
  const out = {};
  for (const id of IDS) {
    const list = f.frames[id];
    if (!list || !list.length) continue;
    // panelDensity is shared by four panels — the transport's is the lowest on screen.
    const pick = id === "panelDensity" ? list.reduce((a, b) => (b.y > a.y ? b : a)) : list[list.length - 1];
    out[id] = { x: +pick.x.toFixed(1), y: +pick.y.toFixed(1), w: +pick.width.toFixed(1), h: +pick.height.toFixed(1) };
  }
  return out;
}

function cropBar(src, tag, width) {
  // The capture includes the 32 pt titlebar; the bar is the 64 pt row above the
  // window's 12 pt bottom padding. Scale 2. Crop the right region (x ≥ 725 pt).
  const y = (32 + HEIGHT - 32 - 12 - 64 - 6) * 2;       // a few points above the bar
  const h = (64 + 12) * 2;
  const x = 725 * 2;
  const w = (width - 725) * 2;
  const crop = (name, cx, cw) => {
    const dst = join(OUT, "crops", `${tag}-${name}.png`);
    const r = spawnSync("sips", ["--cropToHeightWidth", String(h), String(cw), "--cropOffset", String(y), String(cx),
      src, "--out", dst], { encoding: "utf8" });
    return r.status === 0 ? dst : `crop failed: ${(r.stderr || "").trim()}`;
  };
  // The whole bar where it is narrow enough to read in one image; the right
  // region (where every give happens) always.
  return { right: crop("right", x, w), bar: width <= 1400 ? crop("bar", 0, width * 2) : null };
}

// ── The drawn deck against the rule's model ("after" binaries only: the before
// binary has no compact deck). These numbers MIRROR `TransportBarFit`; the Swift
// suite pins the model's arithmetic, and this pins the DRAWN frame to it — the
// check that caught the compact ARM's 25 pt menu box (80 drawn vs 75 modelled).
const DECK_MODEL = {
  // CompactDeck.fixedWidth: capsule padding 6 + 6, sweep 4, 5 + 5 spacing, grid 25 + 3 + 20.
  compactFixed: 74,
  // lampBoxIdeal: one bar (or the empty hint) is 6 pt; n bars are 6 pt, 2 pt apart.
  lampIdeal: (n) => (n <= 1 ? 6 : n * 6 + (n - 1) * 2),
  // The full deck: strip chrome 40 + the drawn "N BAR" label (5 glyphs × 6.8 pt) + 8 + the
  // 119 pt row (the ARM framed to 26; TB's binary drew it at the menu's own 25, hence TB's 226).
  fullFixed: 40 + 34 + 8 + 119,
  fullLamps: (n) => (n <= 0 ? 26 : n * 42 + (n - 1) * 8),
};
function expectedDeckWidth(width, lamps) {
  if (lamps === null || lamps > 1) return null;   // closed, or a box that depends on the whole plan
  return width <= 1208
    ? DECK_MODEL.compactFixed + DECK_MODEL.lampIdeal(lamps)
    : DECK_MODEL.fullFixed + DECK_MODEL.fullLamps(lamps);
}

const results = [];
async function shot(tag, width, extra = {}) {
  await must("debug.windowFrame", { width, height: HEIGHT });
  await sleep(700);
  const echo = await must("debug.windowFrame", {});
  const frames = await measure();
  const deck = await raw("looper.status");
  const edge = echo.width - 28;   // 12 pt window padding + 16 pt bar padding
  const right = (id) => (frames[id] ? frames[id].x + frames[id].w : null);
  const row = {
    tag, width, echo, frames, extra,
    phase: deck.result?.pendingPhase ?? null, lamps: deck.result?.lamps?.length ?? null,
    edge, toggleRight: right("panelDensity"), masterRight: right("transportMasterFader"),
    vibeRight: right("vibeMeter"),
  };
  if (!PROBE || PROBE_CAPTURE) {
    const path = join(OUT, `${tag}.png`);
    const cap = await must("debug.captureUI", { path });
    row.capture = { path: cap.path, w: cap.width, h: cap.height, scale: cap.scale, appActive: cap.appActive };
    row.crop = cropBar(cap.path, tag, echo.width);
  }
  results.push(row);
  const fits = row.toggleRight !== null && row.toggleRight <= edge + 0.5
    && row.masterRight !== null && row.masterRight <= edge + 0.5;
  check(`${tag}: the toggle and the master meter end inside the bar`, fits,
    `toggle→${row.toggleRight} master→${row.masterRight} vibe→${row.vibeRight} edge ${edge}; `
    + `deck w ${frames.loopDeck?.w} notices w ${frames.transportEngineNotices?.w ?? "-"} tone w ${frames.transportTestTone?.w ?? "-"} `
    + `keys ${frames.musicalTyping?.w} export ${frames.transportExport?.w}; phase ${row.phase} lamps ${row.lamps}`);
  if (LABEL !== "before" && frames.loopDeck) {
    const want = extra.expectDeck ?? expectedDeckWidth(width, row.lamps);
    if (want !== null) {
      check(`${tag}: the drawn deck is the width the rule modelled`,
        Math.abs(frames.loopDeck.w - want) <= 0.5, `drawn ${frames.loopDeck.w}, modelled ${want}`);
    }
  }
  return row;
}

let code = 0;
let trackId;
async function setLooper(state) {
  // Idempotent: with no session open, `looper.end` is refused, harmlessly.
  await raw("looper.end", {});
  await raw("transport.stop", {});
  await sleep(300);
  if (state === "closed") return;
  if (state === "open") { await must("looper.begin", { bars: 2 }); await sleep(300); return; }
  // recording: play, arm, wait for the launch boundary, confirm the phase.
  await must("transport.play");
  await sleep(300);
  await must("looper.begin", { bars: 4 });
  const arm = await must("looper.armLayer", { trackId });
  const launch = arm.pendingLaunchBeat;
  const deadline = Date.now() + 20000;
  for (;;) {
    const s = await raw("looper.status");
    if (s.result?.pendingPhase === "recording") return;
    if (Date.now() > deadline) throw new Error(`never reached recording (launch beat ${launch}, phase ${s.result?.pendingPhase})`);
    await sleep(150);
  }
}

try {
  await must("project.new", { discardChanges: true });
  const t = await must("track.add", { name: "TBF1 Keys", kind: "instrument" });
  trackId = t.id;
  await must("project.save", { path: PROJECT });
  // Silent by construction: no click, no count-in, no notes are ever played.
  await must("transport.setMetronome", { enabled: false, countInBars: 0 });
  await must("debug.vibeSeed", {});
  await must("transport.setTempo", { bpm: 120 }).catch((e) => console.log(`setTempo: ${e.message}`));

  if (PROBE) {
    await density.set("transport", "pro");
    if (PROBE_CAPTURE) {
      // Pro at rest with no notice — the window floor's BINDING state (TB's stacked
      // door, no TB-F1 give, 6 pt to spare in the model).
      await setLooper("closed");
      await shot("probe-pro-closed-1208", 1208, { expectDeck: 107.5 });
    }
    await must("debug.postEngineNotice", { code: "clip-fades-skipped" });
    await setLooper("open");
    await shot("probe-pro-notice-open-1208", 1208);
    if (PROBE_CAPTURE) {
      await setLooper("recording");
      await shot("probe-pro-notice-recording-1208", 1208);
      // The FULL deck's ARM, lit, at its 26 pt chip — the light TB-F1 moved out of
      // the menu's label, which the platform flattened (a diagnostic; LOOK at it).
      if ((await raw("looper.status")).result?.pendingPhase !== "recording") await setLooper("recording");
      await shot("probe-pro-notice-recording-1600", 1600);
      await setLooper("open");
      await shot("probe-pro-notice-open-1600", 1600);
      // Pro's TIGHT door — `[⧉][FREE]` over `[− 4 BAR +]` — with a notice at the floor:
      // the one compact form no open-deck shot shows (TightDoor.width, 72 pt).
      await setLooper("closed");
      await shot("probe-pro-notice-closed-1208", 1208, { expectDeck: 72 });
    }
  } else {
    for (const notices of ["off", "on"]) {
      if (notices === "on") await must("debug.postEngineNotice", { code: "clip-fades-skipped" });
      for (const looper of ["closed", "open", "recording"]) {
        await setLooper(looper);
        for (const mode of ["simple", "pro"]) {
          await density.set("transport", mode);
          await sleep(300);
          for (const w of WIDTHS) {
            if (looper === "recording") {
              const s = await raw("looper.status");
              if (s.result?.pendingPhase !== "recording") await setLooper("recording");
            }
            await shot(`${mode}-${looper}-notices-${notices}-${w}`, w, { mode, looper, notices });
          }
        }
      }
    }
    // The bounded lamp box: three layers, Pro, a notice, at the floor.
    try {
      await setLooper("closed");
      await must("transport.play");
      await must("looper.begin", { bars: 1 });
      for (let i = 0; i < 3; i++) {
        const arm = await must("looper.armLayer", { trackId });
        const deadline = Date.now() + 15000;
        while ((await raw("looper.status")).result?.pendingPhase !== "recording" && Date.now() < deadline) await sleep(150);
        await raw("looper.finishLayer", {});
        while ((await raw("looper.status")).result?.pendingPhase && Date.now() < deadline + 15000) await sleep(150);
        void arm;
      }
      await density.set("transport", "pro");
      // Every give taken (433.5 pt with the box at its 8 pt floor), then the box
      // takes back the 4.5 pt above the 5 pt safety: 74 + 12.5.
      await shot("pro-3layers-notices-on-1208", 1208,
        { mode: "pro", looper: "3 layers", notices: "on", expectDeck: 86.5 });
    } catch (e) {
      console.log(`three-layer state skipped: ${e.message}`);
    }
  }
} catch (e) {
  console.log(`ERROR ${e.stack || e}`);
  code = 1;
} finally {
  try { await raw("looper.end", {}); await raw("transport.stop", {}); } catch { /* best effort */ }
  try { await density.restore("tbf1 capture done"); } catch (e) { console.log(`density restore: ${e.message}`); }
  writeFileSync(join(OUT, "frames.json"), JSON.stringify({ label: LABEL, probe: PROBE, binary: BINARY, sha, results }, null, 1));
  try { ws.close(); } catch { /* closed */ }
  stopStaging(GATE);
  releaseLock();
  clearTimeout(killer);
  await sleep(800);
  const front1 = frontmostApp();
  console.log(`frontmost after the gate: ${front1.name ?? front1.raw}`);
  check("FOCUS — the gate left the user's frontmost app where it was (not staging, not Finder)",
    front1.name !== STAGING_DEFAULTS_DOMAIN && front1.name !== "Finder" && front1.pid !== session.pid,
    `before ${front0.name} (pid ${front0.pid}) → after ${front1.name} (pid ${front1.pid})`);
  const failed = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - failed.length}/${checks.length} checks ok; wrote ${join(OUT, "frames.json")}`);
  if (failed.length && code === 0) code = 1;
  process.exit(code);
}
