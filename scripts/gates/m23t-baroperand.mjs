// m23-t GATE — the piano-roll header's BAR readout is an OPERAND, not a position.
//
// The defect: the readout drew in `DAWTheme.playback` under the in-source
// comment "cyan = position readout". Cyan in this app means playback/position,
// and cyan in the PIANO ROLL specifically is the transport playhead — so with
// the transport four bars outside the edited clip the header showed a cyan
// `BAR 1` while the transport was nowhere near bar 1. The value is the +/−
// buttons' operand; the words never claimed a position, the colour did.
//
// WHY THIS GATE EXISTS AT ALL: `DAWApp` is the package's one target with no
// test suite. The label's arithmetic now lives in `DAWAppKit.PianoRollBarOps`
// and is pinned by `Tests/DAWAppKitTests/PianoRollBarOpsTests.swift`; what only
// a live run can see is which STRING and which INK the header actually put on
// screen. That is what `debug.pianoRollBarOps` reports — from inside the
// `Text(...)` / `.foregroundStyle(...)` ARGUMENTS, so the reported value IS the
// drawn value (m23-p2: a reporter in a sibling `.onChange` survived a literal
// colour mutation twice).
//
// TWO TRANSPORT STATES, OR THIS GATE IS VACUOUS. Off-clip (project beat 40,
// outside a clip spanning 16…32) must read `BAR 1`; inside at clip-local bar 3
// (project beat 24) must read `BAR 3`. One state alone is passed by a hardcoded
// `Text("BAR 1")`. Each state's transport position is asserted INDEPENDENTLY
// through `project.overview` — a different subsystem from the view probe — and
// its off/inside classification is checked against the clip geometry read back
// from `project.snapshot`, never assumed.
//
// THE INK LEG IS PIXELS. A probe can be decoupled from a draw; a capture cannot.
// The readout's crop is measured with the m23-c1 cyan-column probe, and the
// discriminator is the crop's ABSOLUTE cyan ceiling (`baseline + peak`) — not
// the median-normalised `peak` alone, which self-cancels on a crop that is
// uniformly cyan.
//
// TWO ANTI-VACUITY LEGS, because "no cyan here" is passed by a crop of empty
// glass:
//   (a) the crop's sha must DIFFER between the two transport states — "BAR 1"
//       and "BAR 3" are different glyphs, so a crop actually on the readout
//       changes and a crop on blank panel is byte-identical;
//   (b) the same metric must FIND cyan in the same capture — measured over the
//       transport bar's POSITION readout, which is a genuine cyan position
//       readout and exactly what this one is not.
// Plus an attribution leg: a neutral header chip beside the cluster must be
// byte-IDENTICAL across the two states, so (a)'s difference is the readout and
// not a global redraw.
//
// ⚠️ BUILD FIRST. `spawn(".build/debug/DAWApp")` with no build step tests the
// PREVIOUS build; restoring a mutated source leaves the mutant binary on disk
// for the next run to adopt. This script builds and aborts on failure.
//
// Staging 17695 ONLY. 17600 is the user's LIVE app and is never touched.
// Kill by EXACT pid from the pidfile — never pkill/pgrep.
//
// Setup (the probe is m23-c1's, reused unchanged):
//   swiftc -O -o /tmp/m23t-probe scripts/probes/m23c1-cyan-column-probe.swift
//   node scripts/gates/m23t-baroperand.mjs
import { spawn, spawnSync, execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";

// The build/launch/pidfile-kill lifecycle lives in ONE place (m23-ac-1) —
// `_staging.mjs`. It used to be copy-pasted into every gate that had it at all.
import { launchStaging, stopStaging, sleep, ROOT, STAGING_PORT } from "./_staging.mjs";

const GATE = "m23t";
const OUT = process.env.M23T_OUT || "/tmp/daw-gate-out/m23t";
const PROBE = process.env.M23T_PROBE || "/tmp/m23t-probe";
mkdirSync(OUT, { recursive: true });

// The m23-c1 cyan-column probe, rebuilt every run for the same reason the app
// is: a stale probe measures the previous one's idea of the pixels.
const probeBuild = spawnSync("swiftc", ["-O", "-o", PROBE,
                              "scripts/probes/m23c1-cyan-column-probe.swift"],
                             { cwd: ROOT, stdio: "inherit" });
if (probeBuild.status !== 0) {
  console.log("ABORT: probe compile failed — the pixel legs would be measuring a stale probe");
  process.exit(2);
}
let ws, seq = 0, pass = 0, fail = 0;
const failures = [];
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = `t-${++seq}`;
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
function ck(label, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS ${label}`); }
  else { fail++; failures.push(label); console.log(`FAIL ${label} :: ${detail}`); }
}

// ---- crop geometry and cyan thresholds --------------------------------------
// ⚠️ RECOVERED BY MEASUREMENT 2026-07-30 (m23-ac-1), not re-derived from taste.
// The orchestrator's harness extraction deleted a region that also held these,
// and this file is untracked, so there was no git copy to restore. They were
// recovered from the artefacts of the last known-good run (71/71): the crop PNGs
// in /tmp/daw-gate-out/m23t fix each w×h exactly, and their (x,y) was found by
// locating each crop inside its parent capture — a UNIQUE exact-byte match for
// all three, so the origins are measured, not guessed. The two thresholds were
// read back off that run's own printed output (`… 118.0 > 80`, `ceiling 12.0 < 30`).
// Coordinates are BACKING-STORE PIXELS (captures are 2880x1800 for a 1440x900
// window) with a BOTTOM-LEFT origin — the probe's convention, confirmed twice
// over: the top-left reading put CYAN_CONTROL's cyan at 11.1 where the good run
// recorded 118.4, and that run's own leftover crops are named `t-off-861.png`,
// i.e. the y this gate passes for the readout.
// If these ever redden, RE-MEASURE — do not nudge them until the leg goes green.
const READOUT      = { x: 2576, y: 861,  w: 84,  h: 44 };
const NEUTRAL_CHIP = { x: 2400, y: 861,  w: 160, h: 44 };
const CYAN_CONTROL = { x: 800,  y: 1700, w: 180, h: 56 };
const CYAN_PRESENT_MIN = 80;
const CYAN_ABSENT_MAX  = 30;

// A crop reading. HARD dimension assertion first: a silently-failed crop is the
// known false-negative mode on this surface, and it would read as "no cyan".
function crop(png, tag, win) {
  const out = `${OUT}/crop-${tag}.png`;
  const raw = execFileSync(PROBE, [png, out, String(win.x), String(win.y),
                                   String(win.w), String(win.h), "8.0"]).toString();
  const kv = Object.fromEntries(raw.trim().split("\n").map((l) => l.split("=")));
  const expect = `${win.w}x${win.h}`;
  if (kv.dims !== expect) throw new Error(`crop ${tag}: dims ${kv.dims} != ${expect}`);
  // The crop's ABSOLUTE cyan ceiling. `peak` alone is median-normalised, so a
  // crop that is uniformly cyan reports ~0 — the exact false negative that
  // makes "cyan absent" meaningless. baseline + peak is the real ceiling.
  kv.cyan = Number(kv.baseline) + Number(kv.peak);
  kv.path = out;
  return kv;
}

const staging = await launchStaging({ gate: GATE });
try {
  ws = staging.ws;

  // ---- fixture: every dimension the crop literals depend on, pinned ---------
  let r = await cmd("project.new", { discardChanges: true });
  ck("F1 project.new", r.ok, JSON.stringify(r.error));

  r = await cmd("debug.windowFrame", { width: 1440, height: 900 });
  ck("F2 window is the DEFAULT 1440x900 (the window the defect was reported at)",
     r.result?.width === 1440 && r.result?.height === 900, JSON.stringify(r.result));

  // The editor's height fraction is an app-sticky UserDefaults preference, so a
  // staging launch inherits whatever the machine last persisted — and it moves
  // the header's y. Reset, then assert the applied values.
  r = await cmd("debug.panelLayout", { reset: true });
  const layout = r.result ?? {};
  // Pinned to the LITERAL default, not just "is a number": the crop y below was
  // measured at this fraction, and a changed default silently moves the header
  // under a still-green type check. If this leg reddens, RE-MEASURE the crops.
  ck("F3 panel layout reset to the 0.45 default (the header's y was measured at this fraction)",
     layout.editorFraction === 0.45 && typeof layout.rowHeight === "number",
     JSON.stringify(layout));

  r = await cmd("debug.panelDensity", { panel: "pianoRoll", mode: "pro" });
  ck("F4 piano roll staged to Pro", r.result?.mode === "pro", JSON.stringify(r.result));

  r = await cmd("track.add", { name: "Bar Ops Probe", kind: "instrument" });
  const trackId = r.result?.id;
  ck("F5 track.add", r.ok && typeof trackId === "string", JSON.stringify(r.error ?? r.result));

  // Four bars long, so clip-local bar 3 EXISTS. m23-c1's own fixture is two bars
  // and tops out at BAR 2 — the inside state would be unreachable on it.
  const notes = [4, 5, 6].map((b, i) => ({
    pitch: [60, 64, 67][i], startBeat: b, lengthBeats: 0.9, velocity: 100,
  }));
  r = await cmd("clip.addMIDI", { trackId, atBeat: 16, lengthBeats: 16, notes });
  const clipId = r.result?.id;
  ck("F6 clip.addMIDI", r.ok && typeof clipId === "string", JSON.stringify(r.error ?? r.result));

  // The clip's geometry, READ BACK — the two transport states are classified
  // against this, never against the numbers this script asked for.
  const snap = (await cmd("project.snapshot")).result ?? {};
  const clip = (snap.tracks ?? []).flatMap((t) => t.clips ?? []).find((c) => c.id === clipId);
  ck("F7 the clip is on the timeline and reports its own geometry",
     clip != null, JSON.stringify((snap.tracks ?? []).map((t) => (t.clips ?? []).length)));
  const clipStart = clip?.startBeat, clipLen = clip?.lengthBeats;
  ck("F8 clip spans project beats 16…32 (four bars, so clip-local bar 3 exists)",
     clipStart === 16 && clipLen === 16, `start=${clipStart} len=${clipLen}`);
  const clipEnd = clipStart + clipLen;

  // ---- the states ----------------------------------------------------------
  const STATES = [
    { tag: "OFF", beat: 40, density: "pro", expect: "BAR 1", inside: false,
      note: "4 bars AFTER the clip — the bar-1 fallback, the reported defect's frame" },
    { tag: "IN", beat: 24, density: "pro", expect: "BAR 3", inside: true,
      note: "inside the clip at clip-local bar 3" },
    { tag: "SIMPLE", beat: 24, density: "simple", expect: "BAR 3", inside: true,
      note: "same transport, DEFAULT density — the mode most users are in" },
  ];
  const seen = {};
  for (const st of STATES) {
    r = await cmd("debug.panelDensity", { panel: "pianoRoll", mode: st.density });
    ck(`${st.tag}.0 density staged to ${st.density}`, r.result?.mode === st.density,
       JSON.stringify(r.result));
    await cmd("transport.seek", { beats: st.beat });
    await sleep(700);

    // INDEPENDENT of the view probe: the store's own transport, over the wire.
    const overview = (await cmd("project.overview")).result ?? {};
    ck(`${st.tag}.1 transport really landed on beat ${st.beat} (project.overview, not assumed)`,
       overview.transport?.positionBeats === st.beat,
       JSON.stringify(overview.transport?.positionBeats));
    const isInside = st.beat >= clipStart && st.beat <= clipEnd;
    ck(`${st.tag}.2 that beat is ${st.inside ? "INSIDE" : "OUTSIDE"} the clip's own span`,
       isInside === st.inside, `beat=${st.beat} span=${clipStart}…${clipEnd}`);

    const cap = (await cmd("debug.captureUI", { path: `${OUT}/${st.tag}.png`, selectClip: clipId }))
      .result ?? {};
    ck(`${st.tag}.3 capture is 2880x1800 (the crop literals are in these pixels)`,
       cap.width === 2880 && cap.height === 1800, `${cap.width}x${cap.height}`);

    const probe = (await cmd("debug.pianoRollBarOps")).result ?? {};
    const role = probe.roles?.barReadout;
    ck(`${st.tag}.4 the header reported a barReadout role at all`, role != null,
       JSON.stringify(probe.roles));
    // A half-filled role is the signature of a call site replaced by a literal.
    // It FAILS here; it is never skipped.
    ck(`${st.tag}.5 the role carries BOTH halves (text and ink) — a null half means a call site went literal`,
       typeof role?.text === "string" && typeof role?.ink === "string", JSON.stringify(role));
    ck(`${st.tag}.6 the DRAWN string is "${st.expect}"`, role?.text === st.expect,
       JSON.stringify(role?.text));

    const tokens = probe.inkTokens ?? {};
    // Pinned against the DOC's literal, not against the app's own token.
    ck(`${st.tag}.7 the drawn ink is NOT cyan #3EE6FF (DESIGN-LANGUAGE Accent system)`,
       role?.ink?.toUpperCase() !== "#3EE6FF", String(role?.ink));
    ck(`${st.tag}.8 the drawn ink is NOT the playback token`, role?.ink !== tokens.playback,
       `${role?.ink} vs ${tokens.playback}`);
    ck(`${st.tag}.9 the drawn ink is NOT violet (violet is AI-touched content, and this is not)`,
       role?.ink !== tokens.ai, `${role?.ink} vs ${tokens.ai}`);
    // Neither of the cluster's own BUTTON inks: `barOpButton` draws
    // `enabled ? textPrimary : textFaint`, so either would read as a third
    // button — and textFaint additionally MEANS "can't act" inside this cluster.
    ck(`${st.tag}.10 the drawn ink is NOT the enabled-button ink (textPrimary)`,
       role?.ink !== tokens.textPrimary, `${role?.ink} vs ${tokens.textPrimary}`);
    ck(`${st.tag}.11 the drawn ink is NOT the disabled-button ink (textFaint, and under Rule 5's 4.5:1)`,
       role?.ink !== tokens.textFaint, `${role?.ink} vs ${tokens.textFaint}`);
    ck(`${st.tag}.12 the drawn ink IS the caption tier (textDim — the sibling zoom readout's ink)`,
       role?.ink === tokens.textDim, `${role?.ink} vs ${tokens.textDim}`);

    // PIXELS — the drawn truth, which needs no probe at all.
    const readout = crop(cap.path, `${st.tag}-readout`, READOUT);
    ck(`${st.tag}.13 PIXELS: no cyan over the readout (ceiling ${readout.cyan.toFixed(1)} < ${CYAN_ABSENT_MAX})`,
       readout.cyan < CYAN_ABSENT_MAX,
       `baseline=${readout.baseline} peak=${readout.peak} runs=${readout.runs}`);
    const control = crop(cap.path, `${st.tag}-control`, CYAN_CONTROL);
    ck(`${st.tag}.14 PIXELS: the SAME metric finds cyan in the transport's real position readout (${control.cyan.toFixed(1)} > ${CYAN_PRESENT_MIN})`,
       control.cyan > CYAN_PRESENT_MIN,
       `baseline=${control.baseline} peak=${control.peak} runs=${control.runs}`);

    seen[st.tag] = { role, readout, control, capture: cap.path,
                     neutral: st.density === "pro" ? crop(cap.path, `${st.tag}-neutral`, NEUTRAL_CHIP)
                                                   : null };
    console.log(`   ${st.tag}: ${st.note} — drew ${JSON.stringify(role?.text)} in ${role?.ink}, ` +
                `readout cyan ${readout.cyan.toFixed(1)}, control cyan ${control.cyan.toFixed(1)}`);
  }

  // ---- cross-state: the legs that make "no cyan HERE" mean something --------
  ck("X1 the readout crop is really ON the readout — its pixels DIFFER between the two transport states",
     seen.OFF.readout.sha !== seen.IN.readout.sha,
     `${seen.OFF.readout.sha} vs ${seen.IN.readout.sha}`);
  ck("X2 attribution: a neutral header chip beside the cluster is byte-IDENTICAL across the two states, so X1 is the readout and not a global redraw",
     seen.OFF.neutral.sha === seen.IN.neutral.sha,
     `${seen.OFF.neutral.sha} vs ${seen.IN.neutral.sha}`);
  ck("X3 the DRAWN strings differ across the two states — a hardcoded Text(\"BAR 1\") fails here",
     seen.OFF.role.text !== seen.IN.role.text,
     `${seen.OFF.role.text} vs ${seen.IN.role.text}`);
  ck("X4 the ink is the SAME in all three states — it is not derived from the transport, which is the whole point",
     seen.OFF.role.ink === seen.IN.role.ink && seen.IN.role.ink === seen.SIMPLE.role.ink,
     `${seen.OFF.role.ink} / ${seen.IN.role.ink} / ${seen.SIMPLE.role.ink}`);
  ck("X5 Simple and Pro draw the same readout — the cluster ships in BOTH densities",
     seen.SIMPLE.role.text === seen.IN.role.text && seen.SIMPLE.readout.sha === seen.IN.readout.sha,
     `${seen.SIMPLE.role.text}/${seen.SIMPLE.readout.sha} vs ${seen.IN.role.text}/${seen.IN.readout.sha}`);

  // ---- the report is LIVE, not a one-time record ---------------------------
  let reset = (await cmd("debug.pianoRollBarOps", { reset: true })).result ?? {};
  ck("L1 {reset:true} empties the ledger", Object.keys(reset.roles ?? {}).length === 0,
     JSON.stringify(reset.roles));
  await cmd("transport.seek", { beats: 16 });
  await sleep(700);
  const refilled = (await cmd("debug.pianoRollBarOps")).result ?? {};
  ck("L2 the next redraw refills it with the NEW value — the report runs every body, it is not a stale record",
     refilled.roles?.barReadout?.text === "BAR 1" &&
     refilled.roles?.barReadout?.ink === refilled.inkTokens?.textDim,
     JSON.stringify(refilled.roles));
  ck("L3 a bare call is READ-ONLY (the m11-a law) — reading twice does not change what is reported",
     JSON.stringify((await cmd("debug.pianoRollBarOps")).result?.roles) ===
     JSON.stringify(refilled.roles), "");

  // ---- the per-frame allocation budget -------------------------------------
  // This readout is fed `positionBeats`, so it redraws for as long as the
  // transport runs, and drawing code does not get to allocate per frame. The
  // reporter must therefore be free in the steady state — which is invisible
  // from outside unless the app counts it, so it counts two things: every
  // report (`ticks`) and every report that cost an NSColor round-trip
  // (`inkResolutions`). P2 exists so P3 cannot pass on a frozen view: a
  // `inkResolutions === 1` over zero redraws would be a vacuous green.
  await cmd("debug.pianoRollBarOps", { reset: true });
  await sleep(2000);
  const idle = (await cmd("debug.pianoRollBarOps")).result ?? {};
  ck("P1 idle for 2s costs NOTHING — a still transport draws no frames at all",
     idle.ticks === 0, `ticks=${idle.ticks}`);

  await cmd("debug.pianoRollBarOps", { reset: true });
  await cmd("transport.play", {});
  const playT0 = Date.now();
  await sleep(2000);
  const playing = (await cmd("debug.pianoRollBarOps")).result ?? {};
  const playSecs = (Date.now() - playT0) / 1000;
  ck(`P2 playing REDRAWS the cluster — ${playing.ticks} reports in ${playSecs.toFixed(2)}s (TWO per body, so ~${(playing.ticks / 2 / playSecs).toFixed(0)} redraws/s; floor 40 reports, so P3 cannot pass on a frozen view)`,
     playing.ticks > 40, `ticks=${playing.ticks} secs=${playSecs}`);
  // ⚠️ If this ever reddens with a count > 1, check WHY before assuming a memo
  // bug: `1` is right only while this readout's ink is CONSTANT (X4 pins that).
  // Make the ink state-dependent — dim it when delete can't act, say — and this
  // leg is the wrong SHAPE, not the code; it would become "resolutions ≪ ticks".
  ck(`P3 and it resolves the ink exactly ONCE across all of them — no per-frame NSColor round-trip`,
     playing.inkResolutions === 1, `ticks=${playing.ticks} inkResolutions=${playing.inkResolutions}`);

  // The memo is only safe because clear() drops it too; otherwise a reset would
  // leave lastInk matching, every later report would skip resolution, and the
  // role would read back with a permanently null ink. Reset MID-PLAYBACK so
  // this is the live path, not a stopped one.
  await cmd("debug.pianoRollBarOps", { reset: true });
  await sleep(1200);
  const refilledLive = (await cmd("debug.pianoRollBarOps")).result ?? {};
  await cmd("transport.stop", {});
  ck("P4 a reset MID-PLAYBACK still comes back with a real ink — the memo is dropped with the entries, never stranded null",
     refilledLive.roles?.barReadout?.ink === refilledLive.inkTokens?.textDim &&
     refilledLive.inkResolutions === 1 && refilledLive.ticks > 10,
     JSON.stringify({ roles: refilledLive.roles, ticks: refilledLive.ticks,
                      inkResolutions: refilledLive.inkResolutions }));

  // ---- no new wire surface -------------------------------------------------
  const commands = readFileSync(`${ROOT}/Sources/DAWControl/Commands.swift`, "utf8");
  const body = commands.slice(commands.indexOf("public static let allCommands: [String] = ["));
  const arr = body.slice(0, body.indexOf("\n    ]"));
  const verbs = [...arr.matchAll(/"([a-zA-Z0-9._]+)"/g)].map((m) => m[1]);
  // ⚠️ CROSS-CYCLE TRIPWIRE, not an m23-t claim. A LATER cycle that legitimately
  // adds a wire command turns this leg red for a reason that has nothing to do
  // with the bar readout. When that happens: confirm the new verb is intended,
  // UPDATE THIS NUMBER, and move on — do not debug it. The legs that actually
  // assert m23-t's claim are W2/W3.
  //
  // BUMP LOG (append a line; do not rewrite history):
  //   163 — m23-t, the count this gate shipped with.
  //   165 — m23-ac, 2026-07-29. m23-w added `clip.removeMany` + `clip.moveMany`
  //         deliberately (group delete/move as ONE undo step). Confirmed intended
  //         and cross-checked against the m23-at close (allCommands 165).
  //         The gate had been sitting RED since m23-w; nobody ran it in between,
  //         which is the m23-ac hazard wearing its other face — a gate nobody
  //         runs is indistinguishable from one that passes.
  //   171 — m23-aj-2, 2026-08-03. Bumped from 165, which had been RED since
  //         before this cycle. ⚠️ HONESTY NOTE ON THIS BUMP: only the LAST 2 of
  //         the 6 added verbs are audited. m23-aj-2 added `clip.moveManyByTracks`
  //         + `clip.moveManyToTrack` (169 -> 171) deliberately. The 165 -> 169
  //         interim was NOT audited here, and it CANNOT be audited by position:
  //         m20-j inserted `output.listDevices`/`output.setDevice` into the
  //         `output.*` GROUPING at array positions 114-115 rather than appending,
  //         so the array tail is NOT the chronology and reading the last N entries
  //         gives a confidently wrong answer (measured 2026-08-03). Anyone
  //         re-auditing this number must use git history, not array order.
  //   173 — m23-dl, 2026-08-05. `ai.modelResidency` + `ai.modelUnload`, both
  //         APPENDED at the end of the array (verified: they are the last two
  //         entries), so for this bump the array tail IS the chronology.
  //         Confirmed intended. ⚠️ THIS GATE WAS FOUND RED-BY-PENDING-BUMP
  //         during the m23-dl review: the cycle bumped 17 Swift count pins and
  //         the MCP tool pin and never grepped `scripts/gates/` for a wire
  //         count, so this was one unrun gate away from repeating the exact
  //         m23-w -> m23-ac failure logged three lines up. Cross-checked TWO
  //         ways before writing it: this gate's own regex over the array body
  //         gives 173, and a comment-stripped count gives 173, with 173 UNIQUE
  //         verbs and zero duplicates.
  const EXPECTED_VERBS = 173;
  ck(`W1 allCommands still holds ${EXPECTED_VERBS} verbs (counted off the ARRAY body, not the case labels)`,
     verbs.length === EXPECTED_VERBS, String(verbs.length));
  ck("W2 the probe added NO wire verb — nothing bar-ops-shaped is in allCommands",
     !verbs.some((v) => /barOps/i.test(v)), verbs.filter((v) => /barOps/i.test(v)).join(","));
  const server = readFileSync(`${ROOT}/mcp-server/src/server.ts`, "utf8");
  ck("W3 the probe is not exposed to agents — no bar-ops tool in the MCP server",
     !/pianoRollBarOps|bar_ops/i.test(server), "");

  // ---- the string's home ---------------------------------------------------
  const view = readFileSync(`${ROOT}/Sources/DAWApp/PianoRoll/PianoRollView.swift`, "utf8");
  // Sliced to the cluster's BODY, not the whole file: the doc comment above it
  // quotes the removed comment verbatim (that quote is the supersession record
  // and must survive), so a file-wide search would fail on the documentation
  // rather than on the code.
  const clusterStart = view.indexOf("private var barOpsCluster: some View {");
  const clusterBody = clusterStart < 0 ? "" : view.slice(clusterStart, view.indexOf("\n    }", clusterStart));
  // H3 is a claim about CODE, so it runs on the body with comment lines
  // stripped. The first draft ran it on the raw body and failed on the cluster's
  // OWN comment explaining why `.frame(width:)` and `.fixedSize` are refused
  // here — a token search finding the token instead of the behaviour. H2 is a
  // claim about a COMMENT and so keeps the raw body.
  const clusterCode = clusterBody.split("\n").filter((l) => !l.trim().startsWith("//")).join("\n");
  ck("H1 the cluster exists and no longer composes the label itself — it draws what DAWAppKit returns",
     clusterStart > 0 && !/Text\("BAR \\\(/.test(clusterCode) &&
     /PianoRollBarOps\.barReadoutLabel/.test(view), "");
  ck("H2 the false \"cyan = position readout\" comment is gone, and so is the playback token it labelled",
     clusterBody.length > 0 && !/cyan = position readout/.test(clusterBody) &&
     !/DAWTheme\.playback/.test(clusterCode), clusterBody.slice(0, 200));
  ck("H3 the readout is NOT pinned to a fixed width — the number is data, and a pin without the width clips mid-glyph",
     clusterCode.length > 0 && !/\.fixedSize/.test(clusterCode) && !/\.frame\(width:/.test(clusterCode),
     "");
} catch (err) {
  fail++; failures.push(`EXCEPTION ${err.message}`);
  console.log(`FAIL EXCEPTION :: ${err.stack}`);
} finally {
  try { ws?.close(); } catch { /* closed */ }
  stopStaging(GATE);
}

console.log(`\n=== GATE === ${pass}/${pass + fail} checks passed`);
if (failures.length) console.log(failures.map((f) => `  FAILED: ${f}`).join("\n"));
writeFileSync(`${OUT}/gate.json`, JSON.stringify({ pass, fail, failures }, null, 2));
process.exit(fail === 0 ? 0 : 1);
