// m23-r3b gate — the THREE remaining live layers that paused on window-inactive.
//
// m23-r3 fixed ONE site (the EQ card's spectrum). Sweeping the family found
// three more, all user-visible meters: the transport-bar VIBE ORB
// (`Components/VibeMeterView.swift`), the goniometer TRAIL and the mono-safety
// READOUTS (`Components/StereoScopeView.swift`). Each carried
// `TimelineView(.animation(paused: controlActiveState == .inactive))` — the
// idiom the m22-e law forbids in writing (`Mixer/ReferencePanelView.swift:26`,
// "a capture agent's app is never frontmost").
//
// Staging: DAW_CONTROL_PORT=17695 .build/debug/DAWApp   (17600 is the user's
// LIVE app — never touched). Kill staging by EXACT PID from its pidfile.
// Output: captures land under /tmp/daw-gate-out/m23r3b/.
//
// ⚠️ THE FOCUS-THEFT LAW — without it this gate is decorative.
// The bug is INVISIBLE while the app is frontmost: that is the definition of
// the bug. So this gate holds focus somewhere else for the WHOLE run (a steal
// every ~1.5 s, because a window that gains focus back silently un-freezes and
// the run goes green for the wrong reason). Two consequences, both mandatory:
//   (a) THE HARNESS MUST PROVE ITSELF. If the steal silently fails — no
//       automation permission, Finder refusing to come forward, the app
//       re-activating on a new window — every leg passes and proves NOTHING,
//       including under a restored forbidden idiom. F1 therefore asserts
//       `appActive === false` from inside the app, and EVERY measurement leg
//       re-asserts it (`quiet()` returns it, and no leg may ignore it).
//   (b) MEASURE IN A QUIET WINDOW. A paused TimelineView still re-evaluates
//       its content when SwiftUI invalidates the subtree for another reason —
//       an observable seed write, a moving playhead. So every count is taken
//       with the transport STOPPED and with NO command sent inside the window:
//       reset, wait, read. Anything else measures invalidations, not ticks.
//
// WHAT EACH LEG IS FOR — read before editing one:
//
//   F   The harness itself: focus really is stolen and stays stolen.
//   L0  All three layers tick at their designed rates while unfocused, twice
//       over — TWO consecutive windows, because a burst of invalidations can
//       fill one window and a frozen layer cannot fill two.
//   L1  THE VIBE ORB, and the strongest leg in the gate: the drawn value must
//       CONVERGE on freshly seeded data while the app is unfocused. This works
//       where a tick count alone would not, because `VibeSmoother` advances by
//       `timeline.date` and a paused timeline hands out a FROZEN date — dt = 0,
//       and `VibeMeterModel.update` no-ops on a non-positive dt. A frozen orb
//       is therefore stuck at its last value even if SwiftUI re-renders it for
//       another reason. Ordered DIM → BRIGHT → DIM so the value is proven to
//       move in both directions, never just "it is high now".
//   L2  THE GONIOMETER TRAIL: unlike the orb it keeps no smoothed state, so the
//       load-bearing signal is the count in a quiet window, plus the
//       DISCRIMINATION leg — Simple density removes the well entirely, and the
//       trail's zero must be distinguishable from a freeze. It is, because the
//       READOUTS keep ticking through it: same app, same window, same instant.
//       (A layer that is not on screen cannot tick; that is what makes the
//       count a presence proof and not just a liveness one.)
//   L3  THE MONO-SAFETY READOUTS: the same shape at 10 Hz. This is the worst
//       shape of the bug — an SF Mono number that looks authoritative and has
//       silently stopped — so the leg also proves the DRAWN correlation and the
//       DRAWN zone word follow a seed change while unfocused.
//   L4  THE SWEEP: no non-comment line in Sources/ may mention
//       `controlActiveState`, and no `TimelineView` may take a `paused:` at
//       all. Pinned at ZERO — with the pattern PROVEN to match first (the same
//       scan including comments must find the law's own doc mentions), because
//       an empty sweep is a result, not a pass. A token search finds the token
//       and not the behaviour, which is why L0-L3 exist.
import { mkdirSync, readdirSync, readFileSync, statSync } from "node:fs";
import { spawn } from "node:child_process";

const OUT = "/tmp/daw-gate-out/m23r3b";
mkdirSync(OUT, { recursive: true });

const sleep = ms => new Promise(r => setTimeout(r, ms));
async function connect() {
  for (let i = 0; i < 20; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket("ws://127.0.0.1:17695");
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(1000); }
  }
  throw new Error("could not connect to staging on 17695");
}
const ws = await connect();
let n = 0, pass = 0, fail = 0;
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const i = `r3b_${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};

// ── THE FOCUS-THEFT HARNESS ───────────────────────────────────────────────
// `open -a Finder` rather than osascript: LaunchServices activation needs no
// Automation (TCC) grant, so the harness cannot be silently disarmed by a
// missing permission on a fresh machine. Every 1.5 s for the whole run — a
// single steal is not enough, because the staging app takes focus back on its
// own whenever it creates or orders a window.
//
// `R3B_NO_THEFT=1` disarms the theft. That switch exists to PROVE the harness
// load-bearing rather than to make life easier: run it with the forbidden idiom
// restored and everything below goes green except F1 — which is exactly what a
// gate without focus theft is worth against this bug class. Never use it for a
// real run.
const NO_THEFT = process.env.R3B_NO_THEFT === "1";
let thief = null;
function stealFocusForever() {
  if (NO_THEFT) { console.log("     (R3B_NO_THEFT=1 — focus theft DISARMED)"); return; }
  const steal = () => spawn("open", ["-a", "Finder"], { stdio: "ignore" });
  steal();
  thief = setInterval(steal, 1500);
}
function stopStealing() { if (thief) { clearInterval(thief); thief = null; } }

// A QUIET measurement window: reset the counts, send NOTHING for `sec`
// seconds, then read. `appActive` comes back with the counts so no leg can
// forget to check that the window was actually unfocused.
async function quiet(sec) {
  await cmd("debug.liveLayers", { reset: true });
  await sleep(sec * 1000);
  const r = await cmd("debug.liveLayers", {});
  if (!r.ok) throw new Error("debug.liveLayers failed: " + r.error);
  const s = r.result;
  s.brief = () =>
    `active=${s.appActive} vibe=${s.vibe.ticks}(b=${s.vibe.brightness.toFixed(3)} `
    + `h=${s.vibe.hue.toFixed(3)}) trail=${s.trail.ticks}(pts=${s.trail.points} `
    + `calm=${s.trail.calm} ${s.trail.zone}) readouts=${s.readouts.ticks}`
    + `(c=${s.readouts.correlation.toFixed(3)} ${s.readouts.zone}) `
    + `scopeShown=${s.scopeShown}`;
  return s;
}
// "still unfocused" for a measurement leg. Under R3B_NO_THEFT this is vacuous
// BY DESIGN: the control run's point is to show what the OTHER legs are worth
// without focus theft, and a run where all of them fail on the focus check
// shows nothing about that. F1 keeps the raw check and is the one leg that must
// then go red.
const unfocused = w => NO_THEFT || w.appActive === false;
// Designed rates: orb 60 Hz, trail 20 Hz, readouts 10 Hz. The thresholds are
// deliberately ~half the designed rate: this gate's claim is "still ticking
// while unfocused", not "hits its exact rate on a loaded machine". A frozen
// layer reads 0-2 (only stray invalidations), so the margin is enormous.
const RATE = { vibe: 60, trail: 20, readouts: 10 };
const expect = (layer, sec) => Math.floor(RATE[layer] * sec * 0.5);

// ── Setup ─────────────────────────────────────────────────────────────────
let r = await cmd("project.new", { discardChanges: true });
ck("S1 project.new", r.ok, r.error);
r = await cmd("ui.showMixer", { show: true });
ck("S2 mixer visible (the master strip carries the scope + readouts)", r.ok, r.error);
r = await cmd("debug.panelDensity", { panel: "mixer", mode: "pro" });
ck("S3 mixer density = pro (the goniometer well is Pro-only)", r.ok, r.error);
// The transport stays STOPPED for every counting leg: a moving playhead is an
// observable change, and observable changes re-render a subtree whether or not
// its timeline is paused. Counting under playback would measure invalidations.
r = await cmd("transport.stop");
ck("S4 transport stopped (quiet windows measure TICKS, not invalidations)", r.ok, r.error);

// ── F: the harness proves itself ──────────────────────────────────────────
let s = await quiet(0.6);
ck("F0 baseline: the app is FRONTMOST before any theft (else the run below "
  + "proves nothing about focus at all)", s.appActive === true, s.brief());
stealFocusForever();
await sleep(2000);
s = await quiet(0.6);
ck("F1 FOCUS IS STOLEN — the app reports itself INACTIVE. If this fails the "
  + "whole gate is void: every leg below would pass frozen or live alike",
  s.appActive === false, s.brief());
ck("F2 the scope well is on screen (Pro + mixer), so its zero would MEAN "
  + "something", s.scopeShown === true && s.readoutsShown === true, s.brief());

// ── L0: all three tick while unfocused, over TWO windows ──────────────────
const w1 = await quiet(1.0);
const w2 = await quiet(1.0);
for (const [i, w] of [w1, w2].entries()) {
  const tag = `window ${i + 1}`;
  ck(`L0a[${tag}] still unfocused for the whole window`, unfocused(w), w.brief());
  ck(`L0b[${tag}] the VIBE ORB keeps drawing (transport bar, always on screen)`,
    w.vibe.ticks >= expect("vibe", 1), w.brief());
  ck(`L0c[${tag}] the GONIOMETER TRAIL keeps drawing`,
    w.trail.ticks >= expect("trail", 1), w.brief());
  ck(`L0d[${tag}] the MONO-SAFETY READOUTS keep drawing`,
    w.readouts.ticks >= expect("readouts", 1), w.brief());
}
// The rate is a DESIGN decision (m23-r3b chose 60 Hz for the orb off
// VibeMeterModel.attackTau = 50 ms). Pin the ORDER of the three rates: if the
// orb ever silently drops to the readouts' rate this leg reddens, while a
// bare "> 0" would not.
ck("L0e the orb ticks fastest and the readouts slowest — the three chosen "
  + "rates, in order (60 / 20 / 10 Hz)",
  w2.vibe.ticks > w2.trail.ticks && w2.trail.ticks > w2.readouts.ticks, w2.brief());
console.log(`     (measured over 1 s, app INACTIVE: orb=${w2.vibe.ticks} `
  + `trail=${w2.trail.ticks} readouts=${w2.readouts.ticks} — designed 60/20/10)`);

// ── L1: THE VIBE ORB — the drawn value converges while unfocused ──────────
// Seeded DIM first, so "bright" later cannot be the state it started in.
//
// The two LOUD seeds differ in spectral TILT at the SAME level — and the tilt
// has to be seeded through `centroidHz`, not through the band shape. Hue reads
// `MasterAnalysisSnapshot.centroidHz`; the bands only shape the silhouette, and
// `debug.vibeSeed` defaults the centroid to 2000 Hz whatever the bands say. The
// first two versions of this leg compared band shapes and measured hue
// 0.652 → 0.653 — a leg failing for entirely the wrong reason, which is the
// same class of mistake as asserting on silence: the input never differed.
const dim = { bands: Array.from({ length: 24 }, () => -78), levelDB: -78 };
const loudBass = { bands: Array.from({ length: 24 }, (_, i) => (i <= 4 ? -10 : -66)),
  levelDB: -4, centroidHz: 120 };
const loudTreble = { bands: Array.from({ length: 24 }, (_, i) => (i >= 19 ? -10 : -66)),
  levelDB: -4, centroidHz: 9000 };
r = await cmd("debug.vibeSeed", dim);
ck("L1a seed the orb DIM", r.ok, r.error);
s = await quiet(1.2);
ck("L1b it draws the dim ember (and is still unfocused)",
  unfocused(s) && s.vibe.dormant === true && s.vibe.brightness < 0.1, s.brief());
r = await cmd("debug.vibeSeed", loudBass);
ck("L1c seed the orb LOUD and BASS-heavy", r.ok, r.error);
s = await quiet(1.2);
// THE DECISIVE ONE. The smoother advances by `timeline.date`; a paused
// timeline freezes that date, dt = 0, and `VibeMeterModel.update` no-ops — so
// a frozen orb CANNOT converge here even when SwiftUI re-renders it for some
// other reason. This is a value proof, not a counter proof.
ck("L1d THE DRAWN STATE FOLLOWED THE DATA while the app was in the "
  + "background — brightness climbed off the floor",
  unfocused(s) && s.vibe.brightness > 0.5 && s.vibe.dormant === false, s.brief());
const bassHue = s.vibe.hue;
r = await cmd("debug.vibeSeed", loudTreble);
ck("L1c2 re-seed the same level, TREBLE-heavy (tilt only)", r.ok, r.error);
s = await quiet(1.2);
ck("L1e and the drawn HUE followed the spectral tilt (bass burns warm, "
  + "treble reads cool — the mapping the orb exists to show)",
  unfocused(s) && s.vibe.hue > bassHue + 0.2,
  `hue ${bassHue.toFixed(3)} → ${s.vibe.hue.toFixed(3)}`);
r = await cmd("debug.captureUI", { path: `${OUT}/L1-vibe-orb-live-unfocused.png` });
ck("L1f captured the orb, live, with the app unfocused", r.ok, r.error);
// Back down: a one-way convergence could be a value that only ever rises.
r = await cmd("debug.vibeSeed", dim);
ck("L1g re-seed DIM", r.ok, r.error);
s = await quiet(2.0);
ck("L1h the drawn state came back DOWN while STILL TICKING — the release "
  + "ballistic ran while unfocused too (a stuck-high orb is the same lie as a "
  + "stuck-low one, and a FROZEN orb satisfies \"it is dim now\" for free)",
  unfocused(s) && s.vibe.brightness < 0.1 && s.vibe.dormant === true
  && s.vibe.ticks >= expect("vibe", 1), s.brief());
await cmd("debug.vibeSeed", { clear: true });

// ── L2: THE GONIOMETER TRAIL ──────────────────────────────────────────────
r = await cmd("debug.scopeSeed", { preset: "cloud" });
ck("L2a seed a decorrelated CLOUD (a trail with real points, not calm)", r.ok, r.error);
s = await quiet(1.0);
ck("L2b the trail is drawing the cloud while unfocused — ticking, not calm, "
  + "with points on screen",
  unfocused(s) && s.trail.ticks >= expect("trail", 1)
  && s.trail.calm === false && s.trail.points > 8, s.brief());
r = await cmd("debug.scopeSeed", { preset: "antiPhase" });
ck("L2c seed ANTI-PHASE (the red zone)", r.ok, r.error);
s = await quiet(1.0);
// ⚠️ THE CONJUNCTION IS LOAD-BEARING — "the value followed" ALONE passes under
// a freeze. Measured under mutation M2: writing a seed is an OBSERVABLE change,
// SwiftUI invalidates the subtree, and a PAUSED TimelineView still re-evaluates
// its content ONCE for that invalidation (the run showed `trail=1` with the new
// value already drawn). So a value leg pins the WIRING; only the count in a
// quiet window pins LIVENESS. Both, or the leg is decorative.
ck("L2d the DRAWN trail tint followed to the anti-phase zone — and the layer "
  + "was ticking on its own, not re-rendered once by the seed write",
  s.trail.zone === "antiPhase" && s.trail.ticks >= expect("trail", 1), s.brief());
r = await cmd("debug.captureUI", { path: `${OUT}/L2-scope-antiphase-unfocused.png` });
ck("L2e captured the scope", r.ok, r.error);
// THE DISCRIMINATION LEG. Simple density removes the goniometer well
// altogether, so the trail's count must go to ZERO — and that zero must be
// distinguishable from a freeze. It is: the READOUTS render in both densities
// and keep ticking in the same window, same app, same instant.
r = await cmd("debug.panelDensity", { panel: "mixer", mode: "simple" });
ck("L2f mixer density → simple (the well is gone; the verdict row stays)", r.ok, r.error);
s = await quiet(1.0);
ck("L2g the trail layer is GONE — no layer, no ticks", s.trail.ticks === 0, s.brief());
ck("L2h and the app is demonstrably still drawing: the readouts ticked "
  + "through the same window (so L2g is an ABSENT layer, not a frozen app)",
  s.readouts.ticks >= expect("readouts", 1) && unfocused(s), s.brief());
ck("L2i the probe agrees the well is off screen", s.scopeShown === false, s.brief());
r = await cmd("debug.panelDensity", { panel: "mixer", mode: "pro" });
ck("L2j mixer density → pro", r.ok, r.error);
s = await quiet(1.0);
ck("L2k the trail returns and ticks again — closing the live → dead → live "
  + "sandwich", s.trail.ticks >= expect("trail", 1) && s.scopeShown === true, s.brief());

// ── L3: THE MONO-SAFETY READOUTS ──────────────────────────────────────────
r = await cmd("debug.scopeSeed", { preset: "mono", correlation: 0.97, width: 0.05,
  balance: 0 });
ck("L3a seed a MONO image (correlation +0.97)", r.ok, r.error);
s = await quiet(1.0);
ck("L3b the readouts drew it while unfocused — the SF Mono number and the "
  + "verdict word both followed",
  unfocused(s) && s.readouts.ticks >= expect("readouts", 1)
  && Math.abs(s.readouts.correlation - 0.97) < 0.02 && s.readouts.zone === "inPhase",
  s.brief());
r = await cmd("debug.scopeSeed", { preset: "antiPhase", correlation: -0.88, width: 0.9,
  balance: 0.3 });
ck("L3c seed OUT OF PHASE (correlation −0.88)", r.ok, r.error);
s = await quiet(1.0);
// Same conjunction as L2d, same reason (measured under mutation M3): the seed
// write alone re-renders a frozen row once, so "the number followed" is a
// wiring pin and the count is the liveness pin. L3e/L3f below stay pure wiring
// pins on purpose — they are what would catch a mis-wired reporter.
ck("L3d the drawn correlation moved to the new value AND the row is ticking "
  + "on its own — a stale readout is the worst shape of this bug: an "
  + "authoritative-looking number that stopped",
  Math.abs(s.readouts.correlation + 0.88) < 0.02
  && s.readouts.ticks >= expect("readouts", 1), s.brief());
ck("L3e the drawn VERDICT WORD moved with it (one semantic, three places)",
  s.readouts.zone === "antiPhase", s.brief());
ck("L3f and the other two scalars followed too, so the row is redrawing "
  + "whole rather than one field updating",
  Math.abs(s.readouts.width - 0.9) < 0.02 && Math.abs(s.readouts.balance - 0.3) < 0.02,
  `w=${s.readouts.width.toFixed(3)} bal=${s.readouts.balance.toFixed(3)}`);
await cmd("debug.scopeSeed", { clear: true });

// ── L4: THE SWEEP — no fourth site, ever ──────────────────────────────────
// A token search finds the TOKEN, not the behaviour (L0-L3 are the behaviour).
// This is the half that catches a NEW site nobody has written a leg for.
function swiftFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const p = `${dir}/${entry}`;
    const st = statSync(p);
    if (st.isDirectory()) out.push(...swiftFiles(p));
    else if (entry.endsWith(".swift")) out.push(p);
  }
  return out;
}
// Comment-stripped source: the law is WRITTEN in doc comments in five files
// (that is the point of writing it down), so a raw grep can never reach zero
// and would have to be weakened into decoration. Line comments only — this
// codebase uses no `/* */` blocks, and a scan that quietly mishandled one
// would show up as a changed `withComments` count below.
function codeText(text) {
  return text.split("\n")
    .map(l => {
      const t = l.trimStart();
      if (t.startsWith("//")) return "";          // whole-line comment
      const idx = l.indexOf("//");
      return idx >= 0 ? l.slice(0, idx) : l;      // trailing comment
    })
    .join("\n");
}
const PATTERNS = [
  ["controlActiveState", /controlActiveState/g],
  ["paused:", /paused\s*:/g],
];
const files = swiftFiles("Sources");
ck("L4a the sweep actually walked the tree (an empty scan passes everything)",
  files.length > 200, `${files.length} .swift files`);
for (const [label, re] of PATTERNS) {
  let withComments = 0, inCode = [];
  for (const f of files) {
    const raw = readFileSync(f, "utf8");
    withComments += (raw.match(re) ?? []).length;
    const code = codeText(raw);
    const lines = code.split("\n");
    for (let i = 0; i < lines.length; i++) {
      if (re.test(lines[i])) inCode.push(`${f}:${i + 1}`);
      re.lastIndex = 0;
    }
  }
  // PROVE THE PATTERN MATCHES SOMETHING FIRST. Both patterns appear in the
  // law's own doc comments; if this count ever hits zero the regex is broken
  // and the zero below is meaningless, not clean.
  ck(`L4b[${label}] the pattern is not broken — it still finds the law's own `
    + `doc mentions`, withComments >= 4, `withComments=${withComments}`);
  // If this reddens, READ THE HIT BEFORE TOUCHING THE PIN. `paused:` is a
  // generic label — some unrelated API may legitimately take one, and this
  // needle is deliberately wider than the bug. When the hit is NOT a
  // `TimelineView` schedule, narrow the needle to the schedule; NEVER delete
  // the pin. Deleting it is how the m22-e freeze class comes back a third time.
  ck(`L4c[${label}] ZERO non-comment occurrences anywhere in Sources/ — the `
    + `forbidden idiom has no fourth site`, inCode.length === 0,
    inCode.length
      ? `${inCode.join(", ")} — if a hit is NOT a TimelineView schedule, `
        + `narrow the needle to the schedule, never delete the pin`
      : "");
}

stopStealing();
console.log(`M23R3B_GATE pass=${pass} fail=${fail}`);
ws.close();
process.exit(fail ? 1 : 0);
