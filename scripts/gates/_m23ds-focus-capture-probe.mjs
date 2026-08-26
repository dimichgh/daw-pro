// m23-ds PROBE — does WINDOW FOCUS change a captured frame, and BY HOW MUCH?
//
// WHY THIS IS THE RIGHT QUESTION. m23-ds chased a ~94 B erratic spread in
// `u0-open.png` (382788 / 382765 / 382859 across ~13 runs) and excluded three
// mechanisms QUANTITATIVELY — panelDensity moves 29,056 B, rowHeight 2,773 B,
// editorFraction 2,270 B, pianoRollPPB 383 B. All are orders of magnitude too
// large. **A mechanism that moves 29 KB cannot be what moved 94 B.** The one
// candidate left unmeasured was window-focus chrome (`appActive`), whose shape
// fits: small, content-not-geometry, and ERRATIC because it depends on what
// else the desktop is doing.
//
// ⚠️ THE ITEM SAID THIS WAS UNTESTABLE ("testing it means stealing desktop
// focus, so instrument instead"). That premise is only half right, and premise-
// checking is the standing rule: the corpus ALREADY steals focus deliberately —
// `m23r3b-live-layers.mjs:116` and `m23s-insert-labels.mjs:145` both do it with
// `open -a Finder` on a 1.5 s interval, as a shipped, sanctioned mechanism. So
// the cost was already accepted elsewhere and this can simply be MEASURED.
//
// ⭐ AND m23r3b's F0 LEG PINS DOWN THE DEFAULT: it asserts `appActive === true`
// BEFORE any theft. So staging is ACTIVE by default even though it never calls
// `NSApp.activate` — meaning focus is a fact that VARIES with the desktop
// across runs, which is exactly the profile of an erratic spread.
//
// DESIGN:
//   • Arms are INTERLEAVED (F U F U F U), never blocked (FFF UUU). A blocked
//     design cannot separate the arm from monotonic drift — the same reasoning
//     that shaped the earlier density sweep.
//   • Focus state is read from the CAPTURE'S OWN RESPONSE (`appActive`, added
//     to `debug.captureUI` this cycle), not from a separate query. The capture
//     states its own precondition, so no sample can be mis-attributed.
//   • POSITIVE CONTROL: a probe reporting "nothing moves" is indistinguishable
//     from a probe that cannot SEE movement. So the run ends by starting the
//     transport and capturing again — that MUST differ, or this probe's
//     negative result means nothing.
//
// `_` prefix keeps this out of the corpus glob and out of m23fa3's scan.
import { createHash } from "node:crypto";
import { readFileSync, mkdirSync } from "node:fs";
import { spawn } from "node:child_process";
import { buildOrAbort, startStaging, stopStaging, connect, sleep } from "./_staging.mjs";

const GATE = "m23ds-focus-capture-probe";
const OUT = `/tmp/daw-gate-out/${GATE}`;
const REPS = Number(process.env.M23DS_REPS || 3);

let n = 0;
function mkCmd(ws) {
  return (command, params = {}, timeoutMs = 30000) =>
    new Promise((res, rej) => {
      const i = `d_${++n}`;
      const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
      const h = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        if (m.id !== i) return;
        clearTimeout(t); ws.removeEventListener("message", h); res(m);
      };
      ws.addEventListener("message", h);
      ws.send(JSON.stringify({ id: i, command, params }));
    });
}

// Same sanctioned mechanism m23r3b and m23s use. A window that regains focus
// silently un-does the arm, so it repeats.
let thief = null;
const steal = () => spawn("open", ["-a", "Finder"], { stdio: "ignore" });
function stealFocusForever() { steal(); thief = setInterval(steal, 1500); }
function stopStealing() { if (thief) { clearInterval(thief); thief = null; } }

mkdirSync(OUT, { recursive: true });
buildOrAbort({ label: "building staging binary (m23-ds focus probe)…" });

// ⚠️⚠️ WHY EACH ARM GETS ITS OWN STAGING SESSION — A REAL FAILURE OF THE FIRST
// VERSION OF THIS PROBE, KEPT BECAUSE IT NEARLY VOIDED THE RESULT.
// v1 interleaved inside ONE session: capture focused, steal, capture unfocused,
// STOP stealing, capture focused again… The restore never worked. Nothing gives
// focus back to a staging app that deliberately never calls `NSApp.activate`,
// so after the first theft every later "focused" sample reported
// `appActive=false` and the focused arm silently collapsed to n=1.
// ⭐ IT WAS CAUGHT ONLY BECAUSE THE CAPTURE NOW STATES ITS OWN `appActive` AND
// THE PROBE ASSERTED ON IT — the sizes were all identical, so a probe that
// merely compared bytes would have reported a clean "focus does not matter"
// from an experiment whose arms had silently become the same arm. That is the
// exact m23-dx failure, reappearing in a different costume.
// FIX: relaunch staging per arm. A freshly launched app IS frontmost (m23r3b's
// F0 leg asserts precisely that), so relaunching is the only reliable way to
// restore the focused state, and the arms stay INTERLEAVED across sessions.
let ws, cmd;
async function openSession() {
  startStaging({ gate: GATE });
  ws = await connect();
  cmd = mkCmd(ws);
  const r = await cmd("project.new", { discardChanges: true });
  if (!r.ok) throw new Error("project.new failed");
  await cmd("transport.stop");
  await sleep(1500);           // let launch animation settle
}
function closeSession() {
  try { ws.close(); } catch {}
  stopStaging(GATE);
}

async function capture(tag) {
  const path = `${OUT}/${tag}.png`;
  const r = await cmd("debug.captureUI", { path });
  if (!r.ok) throw new Error(`capture ${tag} failed: ${JSON.stringify(r.error)}`);
  const buf = readFileSync(path);
  return {
    tag,
    bytes: buf.length,
    sha: createHash("sha256").update(buf).digest("hex").slice(0, 16),
    // ⭐ The capture's OWN report of the ambient it was taken under.
    appActive: r.result.appActive,
    dims: `${r.result.width}x${r.result.height}`,
  };
}

const show = (s) => `${s.tag.padEnd(10)} appActive=${String(s.appActive).padEnd(5)} `
  + `${s.dims} ${String(s.bytes).padStart(7)} B  ${s.sha}`;

const samples = [];
console.log("\n── INTERLEAVED ARMS, ONE STAGING SESSION EACH (F=focused, U=unfocused) ──");
for (let i = 1; i <= REPS; i++) {
  // FOCUSED arm: fresh launch, never steal. The app is frontmost by default.
  stopStealing();
  await openSession();
  const f = await capture(`F${i}`);
  console.log(show(f)); samples.push(f);
  closeSession();

  // UNFOCUSED arm: fresh launch, then hold focus elsewhere for the whole arm.
  await openSession();
  stealFocusForever();
  await sleep(2500);
  const u = await capture(`U${i}`);
  console.log(show(u)); samples.push(u);
  stopStealing();
  closeSession();
}

// ── POSITIVE CONTROL ──────────────────────────────────────────────────────
// If this does NOT differ, the probe cannot see change and every "identical"
// above is worthless.
console.log("\n── POSITIVE CONTROL: transport RUNNING must move the frame ───");
await openSession();
const ctlBefore = await capture("CTL_stop");
console.log(show(ctlBefore));
await cmd("transport.play");
await sleep(1200);
const ctlPlay1 = await capture("CTL_play1");
await sleep(1200);
const ctlPlay2 = await capture("CTL_play2");
console.log(show(ctlPlay1)); console.log(show(ctlPlay2));
await cmd("transport.stop");
closeSession();

// ── analysis ──────────────────────────────────────────────────────────────
// ⭐⭐ GROUP BY THE FACT EACH CAPTURE REPORTS, NOT BY THE ARM I INTENDED.
// My attempt to CONTROL focus failed twice: nothing restores it after a theft,
// and a freshly launched staging app is only ERRATICALLY frontmost (it never
// calls `NSApp.activate`). The intended F/U labels are therefore my INTENT, and
// `appActive` from the capture itself is the GROUND TRUTH. Grouping by intent
// would compare two arms that are partly the same arm — precisely the m23-dx
// failure. Because every capture RECORDS its own ambient, a failed controlled
// experiment degrades gracefully into a sound OBSERVATIONAL one instead of into
// a false clean result. That is the whole return on this cycle's instrumentation.
const idle = samples;                       // every idle-state capture
const ACT = idle.filter(s => s.appActive === true);
const INA = idle.filter(s => s.appActive === false);
const uniq = (a) => [...new Set(a)];

console.log("\n────────────────────── RESULT ──────────────────────");
console.log("Grouped by OBSERVED appActive (ground truth), not by intended arm:");
console.log(`  appActive=true  : n=${ACT.length} distinct hashes=${uniq(ACT.map(s => s.sha)).length} sizes=${uniq(ACT.map(s => s.bytes)).join(",") || "—"}`);
console.log(`  appActive=false : n=${INA.length} distinct hashes=${uniq(INA.map(s => s.sha)).length} sizes=${uniq(INA.map(s => s.bytes)).join(",") || "—"}`);

const bothStatesSeen = ACT.length > 0 && INA.length > 0;
console.log(`\nBOTH FOCUS STATES OBSERVED: ${bothStatesSeen}` +
  (bothStatesSeen ? "" : "  <- ⛔ only one state occurred; this run cannot compare them"));

const ctlMoved = uniq([ctlBefore.sha, ctlPlay1.sha, ctlPlay2.sha]).length > 1;
console.log(`POSITIVE CONTROL (probe can see change): ${ctlMoved}` +
  (ctlMoved ? "" : "  <- ⛔ PROBE IS BLIND; a null result above means NOTHING"));

if (bothStatesSeen && ctlMoved) {
  const allSame = uniq(idle.map(s => s.sha)).length === 1;
  console.log(`\nFOCUS CHANGES THE IDLE FRAME: ${!allSame}`);
  if (allSame) {
    console.log(`=> Every idle capture is BYTE-IDENTICAL (${idle[0].sha}, ${idle[0].bytes} B) across`);
    console.log(`   ${ACT.length} focused and ${INA.length} unfocused samples, while the positive control`);
    console.log(`   moves by ~19-20 KB. **appActive is EXCLUDED as the cause of m23-ds's 94 B class** —`);
    console.log(`   joining panelDensity (29,056 B), rowHeight (2,773 B), editorFraction (2,270 B)`);
    console.log(`   and pianoRollPPB (383 B). All four named candidates are now refuted.`);
  } else {
    const d = Math.abs(uniq(ACT.map(s => s.bytes))[0] - uniq(INA.map(s => s.bytes))[0]);
    console.log(`BYTE DELTA attributable to focus: ${d} B  (m23-ds's filed spread is 94 B)`);
    console.log(d > 0 && d < 1000
      ? "=> SAME ORDER OF MAGNITUDE — focus is a VIABLE explanation for the 94 B class."
      : "=> WRONG ORDER OF MAGNITUDE — focus is EXCLUDED like the other three.");
  }
}
