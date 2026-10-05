#!/usr/bin/env node
// m35-f GATE — the `view.*` surface, driven against a REAL app, with the
// STALE-FRAME case as its scored leg.
//
// ══ WHY THIS EXISTS ════════════════════════════════════════════════════════
// Measured on staging 2026-09-04, before the fix this gate now guards:
//
//     view.panelLayout {editorMaximized:true}
//     view.selectClip {clipId}   → {"reason":"piano-roll-opened","editorOpen":true}
//     view.capture   {path}      → the roll at its DEFAULT anchor, EMPTY GRID
//     view.capture   {path}      → one round trip later, the notes framed
//
// The reply was TRUE and the photograph was a LIE. Setting the selection only
// SCHEDULES the SwiftUI update; the two production verbs are separate wire
// requests, so nothing spun the main runloop between them. That is this tree's
// characteristic failure mode — a success that means nothing — and no headless
// test can see it: it is an AppKit/SwiftUI timing fact about a laid-out window.
// So it gets a gate that drives the real app instead.
//
// ══ WHAT IT SCORES ═════════════════════════════════════════════════════════
// For each trial (a clip low in the pitch stack, a clip high in it, then the
// low one again — ALTERNATING, so every selection is a real change):
//
//   F0  capture BEFORE the selection            (the outgoing frame)
//   F1  view.selectClip, then view.capture      (the pair under test)
//   F2  one no-op round trip, then view.capture (the settled frame)
//
//   SCORED   sha256(F1) === sha256(F2)  — the capture showed the new state.
//            When it fails, F1 === F0 says so explicitly: the photograph is
//            of the PREVIOUS frame, which is the defect above, exactly.
//
//   CONTROL  sha256(F0) !== sha256(F2)  — the selection MOVED the picture.
//            ⭐ Without this, a probe whose fixture draws the same pixels for
//            both clips reports a serene green while seeing nothing at all.
//            A hand-built probe returning a confident negative is the weakest
//            evidence there is, so if the control does not fire this exits 3
//            and scores NOTHING (`doc-count-drift.mjs`'s shape).
//
//   CONTROL  appActive equal across F0/F1/F2. m23-ds: a focus change moves
//            window chrome by ~94 B, so a sha comparison across a focus flip
//            is comparing two different experiments. The capture reports its
//            own ambient; this asserts on it rather than hoping.
//
// The same pair is scored for `view.openEditor` (opening the Poly Synth card
// schedules a SwiftUI update the same way a selection does), so all four
// `view.*` verbs are exercised: `panelLayout` arms the fixture, `selectClip`
// and `openEditor` are the two state-changing verbs under test, and `capture`
// is the instrument.
//
// ══ HOW IT PROVED IT CAN GO RED ════════════════════════════════════════════
// It was written BEFORE the fix and run against the unfixed tree, where it
// failed on exactly the scored leg (F1 === F0 ≠ F2) for every trial. That is
// this gate's redden demonstration and it is not synthetic — the defect was
// real. `M35F_ASSERT_STALE=1` re-runs it with the polarity INVERTED (it then
// demands the stale frame and fails if the capture is fresh), which is how the
// same demonstration can be repeated on a FIXED tree without editing the gate.
//
// ══ USAGE ══════════════════════════════════════════════════════════════════
//   node scripts/gates/m35-view-surface-probe.mjs
//   M35F_ASSERT_STALE=1 node scripts/gates/m35-view-surface-probe.mjs   # redden demo
//
// Exit codes:  0 clean · 1 a scored leg failed · 2 could not reach the subject
//              3 a self-control did not fire (nothing was scored)
//
// ⚠️ PORT 17695, ITS OWN INSTANCE, KILLED PID-EXACT, PROFILE-ISOLATED — all of
// that comes from `_staging.mjs`, which is the ONE home for the lifecycle.
// 17600 is the user's live app and is never addressed here.
import { createHash } from "node:crypto";
import { readFileSync, mkdirSync } from "node:fs";
import { launchStaging, sleep, verdict } from "./_staging.mjs";

const GATE = "m35-view-surface-probe";
const OUT = `/tmp/daw-gate-out/${GATE}`;
// Inverted polarity: demand the DEFECT. Used to show this gate can go red on a
// tree where the bug is fixed — see the header.
const ASSERT_STALE = process.env.M35F_ASSERT_STALE === "1";

mkdirSync(OUT, { recursive: true });

let n = 0;
function mkCmd(ws) {
  return (command, params = {}, timeoutMs = 30000) =>
    new Promise((res, rej) => {
      const id = `m35f_${++n}`;
      const t = setTimeout(() => rej(new Error(`TIMEOUT ${command}`)), timeoutMs);
      const h = (ev) => {
        let m;
        try { m = JSON.parse(ev.data); } catch { return; }
        if (m.id !== id) return;
        clearTimeout(t);
        ws.removeEventListener("message", h);
        res(m);
      };
      ws.addEventListener("message", h);
      ws.send(JSON.stringify({ id, command, params }));
    });
}

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}${detail ? `\n        ${detail}` : ""}`);
};

// A control failing is NOT a scored failure — it means the instrument is blind
// and nothing measured with it counts. Recorded separately, exits 3.
const controlFailures = [];
const control = (name, ok, detail) => {
  console.log(`  ${ok ? "ctl " : "XX  "} ${name}${detail ? `\n        ${detail}` : ""}`);
  if (!ok) controlFailures.push(`${name} — ${detail}`);
};

let app;
try {
  app = await launchStaging({ gate: GATE, settleMs: 0 });
} catch (e) {
  console.error(`CANNOT REACH THE SUBJECT (exit 2) — staging would not launch: ${e?.message ?? e}`);
  process.exit(2);
}

try {
  const ws = app.ws;
  const cmd = mkCmd(ws);
  const must = async (command, params = {}) => {
    const r = await cmd(command, params);
    if (!r.ok) throw new Error(`${command} failed: ${JSON.stringify(r.error)}`);
    return r.result ?? {};
  };

  let shot = 0;
  /** One capture through the PRODUCTION verb, hashed, with its own ambient. */
  async function capture(tag) {
    const path = `${OUT}/${String(++shot).padStart(2, "0")}-${tag}.png`;
    // Wall time is EVIDENCE, not decoration: the fix is a bounded flush inside
    // the verb, so a capture that returns in ~0 ms is a capture that did not
    // flush — which is how the FIRST attempted fix (a nested RunLoop spin) was
    // caught returning byte-identical frames while looking plausible.
    const t0 = Date.now();
    const r = await must("view.capture", { path });
    const ms = Date.now() - t0;
    const buf = readFileSync(r.path);
    const s = {
      tag,
      path: r.path,
      bytes: buf.length,
      sha: createHash("sha256").update(buf).digest("hex").slice(0, 16),
      appActive: r.appActive,
      dims: `${r.width}x${r.height}`,
    };
    console.log(`     ${tag.padEnd(18)} ${s.dims} ${String(s.bytes).padStart(8)} B  ${s.sha}  active=${s.appActive}  ${String(ms).padStart(4)} ms`);
    return s;
  }

  // A wire round trip that changes NOTHING. `view.panelLayout` with no
  // arguments is READ-ONLY by contract (the m11-a bare-call law), so this buys
  // exactly one main-runloop turn and no state change — which is what makes F2
  // "the same frame, one round trip later" rather than "a different frame".
  const noopRoundTrip = async () => { await must("view.panelLayout", {}); await sleep(300); };

  // ── fixture ───────────────────────────────────────────────────────────────
  await must("project.new", { discardChanges: true });
  await must("transport.stop");
  await sleep(1500); // launch animation

  const track = await must("track.add", { kind: "instrument", name: "M35F" });
  const trackId = track.id ?? track.track?.id;
  if (!trackId) throw new Error(`track.add returned no id: ${JSON.stringify(track)}`);

  // ⭐ THE TWO CLIPS ARE AT OPPOSITE ENDS OF THE 128-ROW PITCH STACK ON
  // PURPOSE. m35-h centres the roll on the selected clip's own note range, so
  // a C1 clip and a C7 clip cannot possibly photograph the same — which is
  // what gives the F0 !== F2 control something real to detect. Two clips at
  // the same pitch would make this gate blind and green.
  const mkClip = async (atBeat, pitches) => {
    const c = await must("clip.addMIDI", {
      trackId, atBeat, lengthBeats: 4,
      notes: pitches.map((pitch, i) => ({
        pitch, velocity: 100, startBeat: i * 0.5, lengthBeats: 0.5,
      })),
    });
    const id = c.id ?? c.clip?.id;
    if (!id) throw new Error(`clip.addMIDI returned no id: ${JSON.stringify(c)}`);
    return id;
  };
  const lowClip = await mkClip(0, [24, 26]);   // C1 / D1 — the 808 register
  const highClip = await mkClip(8, [96, 98]);  // C7 / D7

  // `view.panelLayout` — verb 1 of 4. Maximizing the editor is what makes the
  // roll large enough that its anchor is the dominant thing in the frame.
  const layout = await must("view.panelLayout", { workspace: "arrange", editorMaximized: true });
  console.log(`  fixture: track ${trackId}`);
  console.log(`  fixture: layout ${JSON.stringify(layout)}`);
  await sleep(600);

  // ── the scored trials ─────────────────────────────────────────────────────
  const trials = [
    ["selectClip low  (C1/D1)", lowClip],
    ["selectClip high (C7/D7)", highClip],
    ["selectClip low  again", lowClip],
  ];

  for (const [label, clipId] of trials) {
    console.log(`\n── ${label}`);
    const f0 = await capture("F0-before");
    const sel = await must("view.selectClip", { clipId });   // verb 2 of 4
    console.log(`     reply: ${JSON.stringify(sel)}`);
    const f1 = await capture("F1-immediate");                // verb 3 of 4
    await noopRoundTrip();
    const f2 = await capture("F2-settled");

    control(
      `${label}: the picture MOVED (F0 ≠ F2)`,
      f0.sha !== f2.sha,
      f0.sha === f2.sha
        ? `F0 and F2 are the SAME image (${f0.sha}). Selecting this clip changed nothing `
          + `on screen, so the scored comparison below can only ever pass. The fixture or `
          + `the roll's focus policy is not doing what this gate assumes — nothing is scored.`
        : null);
    control(
      `${label}: focus ambient constant across F0/F1/F2`,
      f0.appActive === f1.appActive && f1.appActive === f2.appActive,
      `appActive ${f0.appActive}/${f1.appActive}/${f2.appActive} — a focus flip moves window `
      + `chrome (m23-ds, ~94 B), so these shas describe different experiments.`);

    const fresh = f1.sha === f2.sha;
    if (ASSERT_STALE) {
      check(
        `${label}: [INVERTED] view.capture photographs the STALE frame`,
        !fresh,
        fresh
          ? `F1 === F2 — the capture is FRESH. This is the CORRECT behaviour; the inverted `
            + `polarity is failing on purpose, which is this gate demonstrating it can go red.`
          : null);
    } else {
      check(
        `${label}: view.capture photographs the NEW frame (F1 === F2)`,
        fresh,
        fresh ? null
          : `F1 (${f1.sha}) differs from F2 (${f2.sha})`
            + (f1.sha === f0.sha
              ? ` and is BYTE-IDENTICAL TO F0 — view.capture photographed the frame from `
                + `BEFORE view.selectClip. The reply was honest and the picture is a lie.`
              : ` — the capture caught a partially-updated frame.`)
            + ` Frames: ${f0.path} ${f1.path} ${f2.path}`);
    }
  }

  // ── verb 4 of 4: view.openEditor, scored the SAME way ─────────────────────
  // Opening an editor card schedules a SwiftUI update exactly as a selection
  // does, so it is the second place this defect could live. The control here
  // is the same shape: the card must actually change the picture.
  console.log(`\n── openEditor (instrument)`);
  const g0 = await capture("G0-before");
  const opened = await must("view.openEditor", { trackId });
  console.log(`     reply: ${JSON.stringify(opened)}`);
  const g1 = await capture("G1-immediate");
  await noopRoundTrip();
  const g2 = await capture("G2-settled");

  control(
    `openEditor: the picture MOVED (G0 ≠ G2)`,
    g0.sha !== g2.sha,
    g0.sha === g2.sha
      ? `opening "${opened.title}" changed no pixels, so the scored comparison is vacuous.`
      : null);
  control(
    `openEditor: focus ambient constant across G0/G1/G2`,
    g0.appActive === g1.appActive && g1.appActive === g2.appActive,
    `appActive ${g0.appActive}/${g1.appActive}/${g2.appActive}`);

  const openFresh = g1.sha === g2.sha;
  if (ASSERT_STALE) {
    check(`openEditor: [INVERTED] view.capture photographs the STALE frame`, !openFresh,
      openFresh ? `G1 === G2 — the capture is FRESH (correct behaviour, inverted polarity).` : null);
  } else {
    check(`openEditor: view.capture photographs the NEW frame (G1 === G2)`, openFresh,
      openFresh ? null
        : `G1 (${g1.sha}) differs from G2 (${g2.sha})`
          + (g1.sha === g0.sha ? ` and is BYTE-IDENTICAL TO G0 — the card was not drawn yet.` : ``)
          + ` Frames: ${g0.path} ${g1.path} ${g2.path}`);
  }

  ws.close();
} catch (e) {
  console.error(`\nCANNOT REACH THE SUBJECT (exit 2) — ${e?.stack ?? e}`);
  app.stop();
  process.exit(2);
} finally {
  try { app.stop(); } catch {}
}

// ── the controls decide whether anything above counts ───────────────────────
if (controlFailures.length) {
  console.error(`\n✘ ${controlFailures.length} SELF-CONTROL(S) DID NOT FIRE (exit 3) — NOTHING SCORED.`);
  for (const f of controlFailures) console.error(`    ${f}`);
  console.error(
    `\n  A green from a blind instrument is worse than no result. Fix the fixture or the\n`
    + `  ambient — do NOT relax the scored leg to make this run report something.`);
  process.exit(3);
}

console.log(
  `\nm35-f view-surface probe${ASSERT_STALE ? " [INVERTED POLARITY]" : ""}: `
  + `${checks.filter((c) => c.ok).length}/${checks.length} legs pass, `
  + `${controlFailures.length === 0 ? "all self-controls fired" : "CONTROLS FAILED"}`);
verdict({ ran: checks.length, failed: checks.filter((c) => !c.ok).length });
