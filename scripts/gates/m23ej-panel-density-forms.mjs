// m23-ej-2's prerequisite decision (made by the user 2026-08-09): promote a
// REAL staging gate that pins the `debug.panelDensity` COMMAND-FORM parsing.
//
// WHY THIS EXISTS. `debug.*` ships from `Sources/DAWApp`, which has NO test
// target — m23-ej-1's unit tests cover the STORE contract
// (`PanelDensityStore`/`PanelDensityBacking`) only, never the wire parsing in
// `DAWProApp.setPanelDensity`. The four command forms and their eight error
// paths were each proven exactly once by ephemeral scratchpad probes that are
// now gone. m23-ej-2 is going to wire ~23 OTHER gates against precisely these
// forms; if the parsing regresses, those 23 gates fail for an unexplained
// reason unless something pins the seam itself first. This is that pin.
//
// WHAT THIS PROVES, read the seam at `DAWProApp.swift:4003` (`setPanelDensity`)
// yourself before trusting this summary:
//   FORM 1  {}                          read-ALL, only when `mode` AND `clear`
//                                        are BOTH ABSENT (presence, not truthiness)
//   FORM 2  {panel}                     read one — `mode` (effective) + `stored`
//                                        (EXPLICIT, null when never set)
//   FORM 3  {panel, mode}               write — response `{panel, mode}`, no
//                                        `stored` key (a distinct shape from FORM 2)
//   FORM 4  {panel, clear:true}         clear — response IS the post-clear read
//   8 error paths (missing/empty panel, non-bool clear, the mode+clear
//   contradiction winning over mode, non-string mode, unknown mode enum, and
//   the `clear:false` non-error fallthrough to a plain read).
//
// WHAT THIS DELIBERATELY DOES NOT PROVE. Nothing about the SwiftUI chip that
// reads this store (`SimpleProToggle`) or persistence surviving a real
// relaunch — `UserDefaultsPanelDensityBacking` is exercised through the SAME
// process for the life of this gate, never restarted. Pure wire-parsing pin.
//
// ⚠️ UserDefaults.standard IS AMBIENT, NOT PROFILE-ISOLATED. `DAWPRO_PROFILE_ROOT`
// (`_staging.mjs`) relocates `AppDirectories` file paths (autosave, recordings,
// …) but NOT `UserDefaults.standard`, which `PanelDensityStore`'s real backing
// writes through. A previous interrupted run of THIS gate (or any other debug
// session on this machine) can leave `panelDensity.<panelID>` keys behind. Two
// defenses, both required:
//   (a) every panel id this gate uses is a synthetic probe id
//       (`m23ejGate*`) that can never collide with a real UI panel
//       ("pianoRoll", "mixer", …), so even a shared domain never corrupts a
//       real user preference;
//   (b) every probe panel is defensively CLEARED at setup (state asserted
//       AFTER the clear, never assumed pristine) and again at teardown;
//   (c) the clear ALSO runs on the FAILURE paths (throw / unhandled rejection
//       / gate timeout) — see `cleanupProbeKeys`. Without (c) a gate that
//       throws mid-run leaves its probe keys written, which is exactly what a
//       real perturbation run of this gate did before this was added.
//
// ANTI-VACUITY NOTES (this gate's whole point, so stated plainly):
//   - Every error leg asserts the THROWN MESSAGE's distinctive content, never
//     merely that the call rejected — a typo'd command name also rejects.
//   - `differentErrorsAreDifferent` (leg D1) proves two malformed inputs
//     produce two DIFFERENT messages — the leg that shows this gate can tell
//     error paths apart rather than rubber-stamping any throw.
//   - `expectError()` THROWS (not "fails a check") if the call it wraps
//     unexpectedly SUCCEEDS — an error leg whose precondition silently didn't
//     arm must be loud, never a quiet pass.
//   - Every write/restore leg seeds the OPPOSITE value first (m23-ej-2's own
//     warning): never asserting a write against a prior that already equals
//     the target.
//
// Staging port law: DAW_CONTROL_PORT env, default 17695 — NEVER 17600 (the
// user's live app port). Non-harness tier gate.
// Usage: node scripts/gates/m23ej-panel-density-forms.mjs [outdir]

import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, connect, verdict, STAGING_DEFAULTS_DOMAIN } from "./_staging.mjs";

const GATE = "m23ej-panel-density-forms";
const PORT = Number(process.env.DAW_CONTROL_PORT || 17695);
const OUT = process.argv[2] || `/tmp/daw-gate-out/${GATE}`;
fs.mkdirSync(OUT, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── synthetic probe panel ids — never collide with a real UI panel ─────────
// Declared HERE, above every teardown path, so the failure-path cleanup below
// can name them without a temporal-dead-zone ReferenceError.
const PANEL_A = "m23ejGateA";
const PANEL_B = "m23ejGateB";

const killer = setTimeout(async () => {
  console.error("GATE TIMEOUT");
  await cleanupProbeKeys("timeout");
  try { stopStaging(GATE); } catch {}
  process.exit(2);
}, 120_000);

buildOrAbort({ label: "building staging binary (m23ej)…" });
startStaging({ gate: GATE });
const ws = await connect({ port: PORT });

let nextId = 1;
const pending = new Map();
function req(command, params = {}) {
  const id = String(nextId++);
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject, command });
    ws.send(JSON.stringify({ id, command, params }));
    setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 15000);
  });
}
ws.onmessage = (event) => {
  let msg; try { msg = JSON.parse(event.data); } catch { return; }
  const e = pending.get(msg.id);
  if (!e) return;
  pending.delete(msg.id);
  if (msg.ok === false || msg.error) e.reject(new Error(msg.error ?? "unknown error"));
  else e.resolve(msg.result ?? msg);
};
console.log("connected");

/**
 * Best-effort removal of this gate's probe keys from the AMBIENT
 * `UserDefaults` domain, on EVERY exit path — not just the green one.
 *
 * ⚠️ WHY THIS EXISTS (measured, not theorised): the happy-path teardown at the
 * bottom clears both probe panels, but a gate that THROWS — a fixture that
 * fails to arm, or an `expectError` whose call unexpectedly succeeds — jumps
 * straight to the handler below and never reaches it. A real perturbation run
 * of this gate died at leg E4 with `panelDensity.m23ejGateB` still written,
 * and `defaults read DAWApp` found it afterwards (pre-m23-gf — staging now
 * writes into its own DAWProStaging domain, so a repeat of this incident
 * today would show up under `defaults read DAWProStaging`, not `DAWApp`).
 * `process.on('exit')` cannot
 * do this job: the clear is a WebSocket ROUND TRIP and `exit` handlers must be
 * synchronous. So it is done here, bounded, before the exit.
 *
 * Bounded and swallowing by construction: a cleanup that hangs or throws must
 * never mask the failure that triggered it, so every fault is absorbed and the
 * whole thing races a 3 s cap. Failure to clean is REPORTED, never fatal.
 */
async function cleanupProbeKeys(why) {
  try {
    await Promise.race([
      Promise.allSettled([
        req("debug.panelDensity", { panel: PANEL_A, clear: true }),
        req("debug.panelDensity", { panel: PANEL_B, clear: true }),
      ]),
      sleep(3000),
    ]);
  } catch (e) {
    console.error(`  (probe-key cleanup after ${why} failed: ${e && e.message}`
      // m23-gf-b: staging writes into DAWProStaging, not the user's real DAWApp.
      + ` — 'defaults delete ${STAGING_DEFAULTS_DOMAIN} panelDensity.${PANEL_A}' clears it by hand)`);
  }
}

for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, async (e) => {
    console.error(`\n${ev} — tearing down staging:`, e && e.message);
    await cleanupProbeKeys(ev);
    try { stopStaging(GATE); } catch {}
    process.exit(2);
  });
}

const results = [];
const check = (label, cond, detail) => {
  results.push({ label, cond });
  console.log(`${cond ? "PASS" : "FAIL"}  ${label}${detail !== undefined ? "  :: " + JSON.stringify(detail) : ""}`);
};

/**
 * Calls `debug.panelDensity` expecting the promise to REJECT. If it instead
 * resolves, THROWS (propagates, uncaught by anything local) rather than
 * quietly returning something a caller might mistake for "the error" — the
 * exact vacuous-leg trap this whole gate exists to avoid.
 */
async function expectError(params, label) {
  let succeeded = false, okResult;
  try { okResult = await req("debug.panelDensity", params); succeeded = true; }
  catch (e) { return e.message; }
  throw new Error(`FIXTURE: ${label} expected debug.panelDensity to reject `
    + `${JSON.stringify(params)} but it resolved: ${JSON.stringify(okResult)}`);
}

// (PANEL_A / PANEL_B are declared near the top, above the teardown paths.)

// ── setup: defensively clear both probes; state asserted AFTER, never
// assumed pristine (UserDefaults.standard is ambient — see header) ─────────
await req("debug.panelDensity", { panel: PANEL_A, clear: true });
await req("debug.panelDensity", { panel: PANEL_B, clear: true });

// ── L1 FORM 2 read on a confirmed-cleared panel ─────────────────────────────
// RED under: density() fallback broken, or the setup clear silently failed.
const l1 = await req("debug.panelDensity", { panel: PANEL_A });
check("L1 FORM2 read of a cleared panel: mode falls back to simple, stored is null",
  l1.mode === "simple" && l1.stored === null,
  l1);

// ── L2 FORM 3 write, seeded to the OPPOSITE of "never set" (pro) ───────────
// RED under: setDensity broken, or write/read response shapes collapsed.
const l2 = await req("debug.panelDensity", { panel: PANEL_A, mode: "pro" });
check("L2 FORM3 write response is exactly {panel, mode} — no 'stored' key (write shape != read shape)",
  l2.panel === PANEL_A && l2.mode === "pro" && !Object.prototype.hasOwnProperty.call(l2, "stored"),
  l2);

// ── L3 FORM 2 read after the write — discriminates from L1's null ──────────
// RED under: the write not persisting, or a read that always reports the default.
const l3 = await req("debug.panelDensity", { panel: PANEL_A });
check("L3 FORM2 read after write: mode AND stored both report the written value",
  l3.mode === "pro" && l3.stored === "pro",
  l3);

// ── L4 FORM 1 bare read-all includes the explicitly-set panel ──────────────
// Deliberately does NOT assert whole-object equality on `panels` — the domain
// is ambient and may carry keys from real app/gate usage on this machine; only
// OUR key is asserted.
// RED under: bare read-all broken, or omitting explicitly-set panels.
const l4 = await req("debug.panelDensity", {});
check("L4 FORM1 bare {} read-all: panels object present and includes our written panel",
  typeof l4.panels === "object" && l4.panels !== null && l4.panels[PANEL_A] === "pro",
  l4.panels);

// ── L5/L6 THE CACHE EVICTION — the way m23-ej-1 ships broken while looking
// right (m23-ej-2's own warning). PANEL_A is currently CACHED "pro" in this
// session from L2/L3. Clear it, then prove `stored` is null TWO independent
// ways: the clear's own immediate response (L5), and a fully separate
// subsequent read (L6) — a bug that only manifests on the read path and not
// the clear's own response (or vice versa) is still caught. ─────────────────
const l5 = await req("debug.panelDensity", { panel: PANEL_A, clear: true });
check("L5 FORM4 clear response IS the post-clear read: mode=simple, stored=null (not the stale cached 'pro')",
  l5.panel === PANEL_A && l5.mode === "simple" && l5.stored === null,
  l5);
const l6 = await req("debug.panelDensity", { panel: PANEL_A });
check("L6 EVICTION cross-check: an INDEPENDENT read after the clear still reports stored=null (no cache resurrection)",
  l6.mode === "simple" && l6.stored === null,
  l6);

// ── L7 a cleared panel is ABSENT from the bare read-all, not present-null ──
// RED under: storedDensities() reporting cleared/unset panels as null instead
// of omitting them (a caller enumerating "panels[panel] !== null" would then
// falsely count PANEL_A as set).
const l7 = await req("debug.panelDensity", {});
check("L7 FORM1 after clear: the cleared panel key is ABSENT from panels, not present-with-null",
  !Object.prototype.hasOwnProperty.call(l7.panels, PANEL_A),
  l7.panels);

// ── L8 clearing an already-clear (stand-in for never-set) panel is a NO-OP ─
// PANEL_B was cleared at setup and never written since — the closest reachable
// proxy for "never set" on an ambient, persistent UserDefaults domain.
// RED under: clearing an unset/already-clear panel throwing, rather than the
// documented no-op that returns the same post-clear-read shape.
const l8 = await req("debug.panelDensity", { panel: PANEL_B, clear: true });
check("L8 clearing a never-set/already-clear panel is a NO-OP, not an error: same post-clear-read shape",
  l8.panel === PANEL_B && l8.mode === "simple" && l8.stored === null,
  l8);

// ── L9 explicit-simple vs never-set — the mode/stored distinction the
// command exists for. Write PANEL_B to "simple" explicitly (its EFFECTIVE
// mode does not change — the default was already simple — but `stored` must
// flip from null to the explicit value). ────────────────────────────────────
// RED under: storedDensity() conflating "explicitly simple" with "never set"
// (would report null here despite an explicit write just having happened).
await req("debug.panelDensity", { panel: PANEL_B, mode: "simple" });
const l9 = await req("debug.panelDensity", { panel: PANEL_B });
check("L9 an EXPLICIT write of the default value still shows stored='simple', not null (mode/stored distinction)",
  l9.mode === "simple" && l9.stored === "simple",
  l9);

// ── E1 {mode:'pro'} with NO panel key → 'requires a panel' ─────────────────
// RED under: the missing-panel guard removed, or the message drifting so a
// caller can no longer tell this error class apart from any other throw.
const e1 = await expectError({ mode: "pro" }, "E1");
check("E1 {mode:'pro'} no panel -> 'requires a panel'", e1.includes("requires a panel"), e1);

// ── E2 {clear:true} with NO panel key → SAME 'requires a panel' message ────
// This is why FORM1's bare-call test is by PRESENCE of `mode` OR `clear`, not
// just `mode`. RED under: the bare-call read-all regressing to test only
// `mode`'s presence, letting a bare `{clear:true}` leak through as an
// unintended (and undocumented) whole-domain read or wipe.
const e2 = await expectError({ clear: true }, "E2");
check("E2 {clear:true} no panel -> SAME 'requires a panel' (presence test covers clear too)",
  e2.includes("requires a panel"), e2);

// ── E2b — the leg that actually discriminates PRESENCE from TRUTHINESS.
// `{clear: true}` above passes under a truthiness guard too (true is truthy),
// so it does not by itself prove the guard tests presence. `{clear: false}`
// no-panel is the discriminating input: the shipped guard is
// `params["clear"] == nil`, which throws here regardless of the boolean's
// value; a regression to truthiness (`params["clear"] == true`) would instead
// fall through this guard and return the FORM1 read-all, which `expectError`
// would catch as an unexpected resolution and throw its own FIXTURE error.
const e2b = await expectError({ clear: false }, "E2b");
check("E2b {clear:false} no panel -> STILL 'requires a panel' (PRESENCE, not truthiness)",
  e2b.includes("requires a panel"), e2b);

// ── E3 {panel:''} → 'requires a panel' (empty string treated as absent) ────
// RED under: an empty-string panel id silently accepted, which would corrupt
// storedDensities() with an empty key.
const e3 = await expectError({ panel: "" }, "E3");
check("E3 {panel:''} -> 'requires a panel'", e3.includes("requires a panel"), e3);

// ── E4 {panel, clear:5} → 'clear must be true or false', NOT a silent read ─
// RED under: a non-bool `clear` coercing to false and degrading into FORM2 —
// `expectError` itself is the proof: a degraded read would RESOLVE, not
// reject, and `expectError` throws loudly on any unexpected resolution.
const e4 = await expectError({ panel: PANEL_A, clear: 5 }, "E4");
check("E4 {panel, clear:5} -> 'clear must be true or false' (rejects, does not degrade to a read)",
  e4.includes("clear must be true or false"), e4);

// ── E5 {panel, mode:5, clear:true} → the CONTRADICTION wins, before mode is
// even type-checked. Using an INVALID mode (5, not a valid string) is the
// sharper form of this test: if the contradiction check ran AFTER mode
// parsing, this would instead surface "requires a mode", masking the
// contradiction — so asserting the contradiction message AND the absence of
// the mode message together pins the CHECK ORDER, not just the outcome. ────
const e5 = await expectError({ panel: PANEL_A, mode: 5, clear: true }, "E5");
check("E5 {panel, mode:5, clear:true} -> the contradiction error, and it is NOT the mode error (order pinned)",
  e5.includes("cannot take mode and clear") && !e5.includes("requires a mode"),
  e5);

// ── E5b — the brief's LITERAL error path #5 input, {mode:'pro', clear:true},
// which E5's `mode:5` variant cannot exercise: with a syntactically VALID
// mode there is something for a regression to actually apply. Seeded to the
// OPPOSITE of "pro" first so the readback below discriminates BOTH ways a
// "wins over the mode" regression could fail — mode:5 (E5) only proves check
// ORDER; this proves the WRITE never happens even when it legally could.
await req("debug.panelDensity", { panel: PANEL_A, mode: "simple" });
const e5b = await expectError({ panel: PANEL_A, mode: "pro", clear: true }, "E5b");
check("E5b {panel, mode:'pro', clear:true} -> the contradiction error",
  e5b.includes("cannot take mode and clear"), e5b);
const e5bAfter = await req("debug.panelDensity", { panel: PANEL_A });
check("E5b state: NEITHER verb took — stored is still the seeded 'simple' ('pro' would mean the mode wrote, null would mean the clear fired)",
  e5bAfter.stored === "simple", e5bAfter);

// ── E6 {panel, mode:5} (no clear) → 'requires a mode', NOT a silent read ───
// RED under: `expectError` throwing its own FIXTURE error, proving a
// degraded-to-read regression the same way E4 does.
const e6 = await expectError({ panel: PANEL_A, mode: 5 }, "E6");
check("E6 {panel, mode:5} -> 'requires a mode' (rejects, does not degrade to a read)",
  e6.includes("requires a mode"), e6);

// ── D1 DISCRIMINATION — E4 and E6 are two DIFFERENT malformed inputs and
// must produce two DIFFERENT messages. This is the leg that proves the gate
// (and the seam) can tell error paths apart rather than rubber-stamping any
// rejection with the same generic text. ─────────────────────────────────────
check("D1 two different malformed inputs (bad clear vs bad mode) produce two DIFFERENT error messages",
  e4 !== e6 && e4.includes("clear") && e6.includes("mode") && !e4.includes("requires a mode") && !e6.includes("clear must be"),
  { e4, e6 });

// ── E7 {panel, mode:'bogus'} → unknown-mode enum error, names the bad value ─
// RED under: an unrecognised mode string silently accepted/coerced.
const e7 = await expectError({ panel: PANEL_A, mode: "bogus" }, "E7");
check("E7 {panel, mode:'bogus'} -> unknown mode, names the offending value",
  e7.includes("unknown mode") && e7.includes("bogus"), e7);

// ── E8 {panel, clear:false} with NO mode → NOT an error: falls through to a
// FORM2 read. The one leg in the error-path list that must NOT throw. ──────
// Seeded to "pro" FIRST (not left at whatever default state a prior leg left
// behind) so the response can only pass by reporting the REAL current state —
// a stubbed handler returning a canned `{mode:"simple", stored:null}` read
// shape would fail this exact assertion, where it would have silently passed
// against an unseeded/default panel.
// RED under: `clear:false` misclassified as a write attempt, a contradiction,
// made to throw at all, or answering with a canned default instead of the
// actual stored state.
await req("debug.panelDensity", { panel: PANEL_A, mode: "pro" });
let e8caught = null, e8result = null;
try { e8result = await req("debug.panelDensity", { panel: PANEL_A, clear: false }); }
catch (err) { e8caught = err.message; }
check("E8 {panel, clear:false} no mode -> NOT an error, falls through to a FORM2 read of the REAL seeded state (mode/stored='pro', not a canned default)",
  e8caught === null && e8result !== null
    && e8result.mode === "pro" && e8result.stored === "pro"
    && Object.prototype.hasOwnProperty.call(e8result, "stored")
    && e8result.panel === PANEL_A,
  e8caught !== null ? { threw: e8caught } : e8result);

// ── teardown: leave both probe panels genuinely unset ───────────────────────
await req("debug.panelDensity", { panel: PANEL_A, clear: true });
await req("debug.panelDensity", { panel: PANEL_B, clear: true });

const pass = results.filter((r) => r.cond).length;
console.log(`\n${GATE}: ${pass}/${results.length} passed`);
for (const r of results.filter((r) => !r.cond)) console.log(`  FAILED: ${r.label}`);

try { ws.close(); } catch {}
stopStaging(GATE);
clearTimeout(killer);
verdict({ ran: results.length, failed: results.length - pass });
