#!/usr/bin/env node
// m34-j REPRODUCTION PROBE — ARE THE ARROW NUDGES INTERMITTENTLY DEAD AFTER A
// CLIP SWITCH, THE WAY ⌫ WAS BEFORE m23-cf-3?
//
// ⚠️ A PROBE, NOT A GATE. Staging (17695) only. Run BEFORE any edit.
//
// ═══ THE PREMISE UNDER TEST ═══
//
// m34-j predicts: ←/→ and ↑/↓ fire ONLY through `.onKeyPress` on
// `ArrangeDeleteKey`'s `@FocusState` (`ContentView.swift`), that focus is the
// ancestor of `PianoRollView.isFocused`, and m23-al measured that pair
// ALTERNATING 6-true/6-false across 12 consecutive clip selections. So the
// arrow nudges should be dead on roughly half the presses that follow a clip
// switch, with no `NSEvent` monitor backstop to rescue them.
//
// ⚠️ TWO IN-TREE MEASUREMENTS ALREADY PULL IN OPPOSITE DIRECTIONS, WHICH IS
// EXACTLY WHY THIS RUNS BEFORE ANY FIX:
//   • m23-fi (`KeyPressProbe`'s banner, `DeleteKeyMonitorRouting`'s banner):
//     "focus is HEALTHY — `arrangeWorkspaceFocused` reads true with a clip
//     selected … the ←/→ and ↑/↓ mounts on that very view fire on real posted
//     key events." But that was ONE press in ONE quiescent state.
//   • m23-al / m23-cf: `pianoRollEditorFocused` alternates 6/12 strictly, and
//     `handleArrangeNudgeKey`'s own comment says using it as a guard term "makes
//     the guard INTERMITTENT".
// Neither settles the other. Nobody has posted a real arrow key ACROSS CLIP
// SWITCHES and counted.
//
// ═══ THE INSTRUMENT ═══
//
// `KeyPressProbe.arrangeHorizontalArrow` / `.arrangeVerticalArrow` are bumped as
// the FIRST STATEMENT of their `.onKeyPress` closures, before any guard. That
// separates the two silences a bare "the clip did not move" conflates:
//   • counter did NOT move → SwiftUI never delivered the key. THE PREMISE.
//   • counter moved, clip did not → the key arrived and a guard declined. A
//     DIFFERENT defect (report it; do not fix it here).
//
// ═══ CONTROLS, BECAUSE A CLEAN RUN IS WORTHLESS WITHOUT THEM ═══
//
//   K0  THE ALTERNATION ITSELF. `pianoRollEditorFocused` is read on every round.
//       If it does NOT alternate during this run, a 12/12 "arrows alive" result
//       does NOT refute the premise — it only means the coin sat still. This is
//       the positive control that the antecedent condition was PRESENT.
//   K1  COUNTER SPECIFICITY. Post ESCAPE and assert `arrangeHorizontalArrow`
//       does NOT move. Without it, "the counter moved" could be a counter that
//       ticks on any seam call.
//   K2  INJECTION LIVENESS. `act:"keyDelete", post:true` must move
//       `deleteKeyMonitorSeq` — the `_m23cf3-onkeypress-probe` E3 lesson. Only
//       needed if an arrow leg reads dead; run unconditionally so it is on the
//       record either way.
//   K3  POLICY LIVENESS on any dead press: drive `act:"nudge"` through the seam
//       immediately. If the policy grants where the key did nothing, DELIVERY is
//       the confirmed failure rather than the handler.
//
//   node scripts/gates/_m34j-arrow-nudge-repro.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "./_staging.mjs";

const GATE = "m34jrepro";
const PORT = STAGING_PORT;
const OUT = "/tmp/m34jrepro";
const PIDFILE = "/tmp/m34jrepro-staging.pid";
const ROUNDS = 12;          // the same 12 the focus alternation was measured over
const SETTLE = 450;         // the census's post-key settle

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
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
          }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

buildOrAbort({ label: "building staging binary (m34-j arrow repro)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();

const sel = (p = {}) => req("debug.arrangeSelection", p);
const probe = async () => (await sel({})).keyPressProbe;
const pattern = (a) => a.map((v) => (v ? "1" : "0")).join("");

/** Where is this clip? `null` if it is gone. */
async function clipState(clipId) {
  const tracks = (await req("project.snapshot", {})).tracks ?? [];
  for (const t of tracks) {
    const c = (t.clips ?? []).find((x) => x.id === clipId);
    if (c) return { trackId: t.id, startBeat: c.startBeat };
  }
  return null;
}

try {
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackA = (await req("track.add", { kind: "instrument", name: "ARROW A" })).id;
  const trackB = (await req("track.add", { kind: "instrument", name: "ARROW B" })).id;
  console.log(`fixture: trackA=${trackA} trackB=${trackB}`);

  // ── K1 — COUNTER SPECIFICITY ──────────────────────────────────────────────
  {
    const seedId = (await req("clip.addMIDI", {
      trackId: trackA, atBeat: 0, lengthBeats: 4,
      notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
    })).id;
    await sel({ act: "click", clipId: seedId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(300);

    const b = await probe();
    await sel({ act: "postKey", key: "escape" });
    await sleep(SETTLE);
    const mid = await probe();
    await sel({ act: "postKey", key: "right" });
    await sleep(SETTLE);
    const a = await probe();

    console.log("\n════ K1 — COUNTER SPECIFICITY (the instrument discriminates) ════");
    console.log(`   after ESCAPE : arrangeHorizontalArrow ${b.arrangeHorizontalArrow} -> `
      + `${mid.arrangeHorizontalArrow}   moved = ${mid.arrangeHorizontalArrow !== b.arrangeHorizontalArrow}`);
    console.log(`   after →      : arrangeHorizontalArrow ${mid.arrangeHorizontalArrow} -> `
      + `${a.arrangeHorizontalArrow}   moved = ${a.arrangeHorizontalArrow !== mid.arrangeHorizontalArrow}`);
    console.log("   WANT: escape = false, → = true. A counter that moves on BOTH is");
    console.log("   not measuring the arrow mount and every number below is void.");
    await req("clip.remove", { clipId: seedId });
  }

  // ── K2 — INJECTION LIVENESS (the E3 control) ──────────────────────────────
  {
    const seedId = (await req("clip.addMIDI", {
      trackId: trackA, atBeat: 0, lengthBeats: 4,
      notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
    })).id;
    await sel({ act: "click", clipId: seedId });
    await sleep(300);
    const b = await sel({});
    await sel({ act: "keyDelete", post: true });
    await sleep(SETTLE);
    const a = await sel({});
    console.log("\n════ K2 — INJECTION LIVENESS (NSApp.postEvent delivers at all) ════");
    console.log(`   deleteKeyMonitorSeq ${b.deleteKeyMonitorSeq} -> ${a.deleteKeyMonitorSeq}`
      + `   moved = ${a.deleteKeyMonitorSeq !== b.deleteKeyMonitorSeq}`);
    const still = await clipState(seedId);
    if (still) await req("clip.remove", { clipId: seedId });
  }

  // ═══ LEG 1 — THE m23-cf-3 RECIPE EXACTLY: A FRESH CLIP AND A CLICK EACH
  //     ROUND, WHICH IS WHAT THE 6/12 ALTERNATION WAS MEASURED OVER ═══
  const l1 = { entered: [], moved: [], rollFocus: [], wsFocus: [], seamGrant: [] };
  console.log(`\n════ LEG 1 — ${ROUNDS} FRESH-CLIP SELECTIONS, ONE POSTED → EACH ════`);
  for (let i = 0; i < ROUNDS; i++) {
    const clipId = (await req("clip.addMIDI", {
      trackId: trackA, atBeat: 4, lengthBeats: 4,
      notes: [{ pitch: 60 + i, startBeat: 0, lengthBeats: 1, velocity: 100 }],
    })).id;
    await sel({ act: "click", clipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(250);

    const before = await sel({});
    const b = await clipState(clipId);
    await sel({ act: "postKey", key: "right" });
    await sleep(SETTLE);
    const after = await sel({});
    const a = await clipState(clipId);

    const entered = after.keyPressProbe.arrangeHorizontalArrow
      !== before.keyPressProbe.arrangeHorizontalArrow;
    const moved = b?.startBeat !== a?.startBeat;
    l1.entered.push(entered);
    l1.moved.push(moved);
    l1.rollFocus.push(before.pianoRollEditorFocused);
    l1.wsFocus.push(before.keyPressProbe.arrangeWorkspaceFocused);

    // K3 — on a dead press, ask the POLICY the same question through the seam.
    let grant = null;
    if (!moved) {
      const out = await sel({ act: "nudge", direction: "right" });
      grant = out.nudge?.handled === true;
      const c = await clipState(clipId);
      console.log(`   r${String(i).padStart(2)}  entered=${entered ? "Y" : "n"} moved=${moved ? "Y" : "n"}`
        + `  rollFocus=${before.pianoRollEditorFocused ? 1 : 0}`
        + `  wsFocus=${before.keyPressProbe.arrangeWorkspaceFocused ? 1 : 0}`
        + `  startBeat ${b?.startBeat}->${a?.startBeat}`
        + `   K3 seam nudge: handled=${out.nudge?.handled} refusedBy=${out.nudge?.refusedBy ?? "null"}`
        + ` startBeat->${c?.startBeat}`);
    } else {
      console.log(`   r${String(i).padStart(2)}  entered=${entered ? "Y" : "n"} moved=${moved ? "Y" : "n"}`
        + `  rollFocus=${before.pianoRollEditorFocused ? 1 : 0}`
        + `  wsFocus=${before.keyPressProbe.arrangeWorkspaceFocused ? 1 : 0}`
        + `  startBeat ${b?.startBeat}->${a?.startBeat}`);
    }
    l1.seamGrant.push(grant);
    await req("clip.remove", { clipId });
  }

  // ═══ LEG 2 — TWO PERSISTENT CLIPS, CLICKED ALTERNATELY. The user's actual
  //     gesture ("switch between clips"), and the roll re-mounts on each. ═══
  const l2 = { entered: [], moved: [], rollFocus: [], wsFocus: [] };
  console.log(`\n════ LEG 2 — ${ROUNDS} ALTERNATING CLICKS BETWEEN TWO CLIPS, ONE → EACH ════`);
  {
    const c1 = (await req("clip.addMIDI", {
      trackId: trackA, atBeat: 0, lengthBeats: 2,
      notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
    })).id;
    const c2 = (await req("clip.addMIDI", {
      trackId: trackB, atBeat: 32, lengthBeats: 2,
      notes: [{ pitch: 67, startBeat: 0, lengthBeats: 1, velocity: 100 }],
    })).id;
    for (let i = 0; i < ROUNDS; i++) {
      const clipId = i % 2 === 0 ? c1 : c2;
      await sel({ act: "click", clipId });
      await sel({ act: "pianoRollNotes", select: false });
      await sleep(250);

      const before = await sel({});
      const b = await clipState(clipId);
      // alternate the direction so the clip walks back and forth and never
      // clamps at the beat-0 wall (a clamped nudge reports handled but moves
      // nothing, which would read exactly like the bug).
      const key = i % 2 === 0 ? "right" : "left";
      await sel({ act: "postKey", key });
      await sleep(SETTLE);
      const after = await sel({});
      const a = await clipState(clipId);

      const entered = after.keyPressProbe.arrangeHorizontalArrow
        !== before.keyPressProbe.arrangeHorizontalArrow;
      const moved = b?.startBeat !== a?.startBeat;
      l2.entered.push(entered);
      l2.moved.push(moved);
      l2.rollFocus.push(before.pianoRollEditorFocused);
      l2.wsFocus.push(before.keyPressProbe.arrangeWorkspaceFocused);
      console.log(`   r${String(i).padStart(2)}  clip=${clipId === c1 ? "1" : "2"} key=${key}`
        + `  entered=${entered ? "Y" : "n"} moved=${moved ? "Y" : "n"}`
        + `  rollFocus=${before.pianoRollEditorFocused ? 1 : 0}`
        + `  wsFocus=${before.keyPressProbe.arrangeWorkspaceFocused ? 1 : 0}`
        + `  startBeat ${b?.startBeat}->${a?.startBeat}`);
    }
    await req("clip.remove", { clipId: c1 });
    await req("clip.remove", { clipId: c2 });
  }

  // ═══ LEG 3 — ↑/↓ ACROSS TRACKS, same recipe ═══
  const l3 = { entered: [], moved: [], rollFocus: [] };
  console.log(`\n════ LEG 3 — ${ROUNDS} FRESH-CLIP SELECTIONS, ONE POSTED ↓/↑ EACH ════`);
  for (let i = 0; i < ROUNDS; i++) {
    const clipId = (await req("clip.addMIDI", {
      trackId: i % 2 === 0 ? trackA : trackB, atBeat: 8, lengthBeats: 4,
      notes: [{ pitch: 60 + i, startBeat: 0, lengthBeats: 1, velocity: 100 }],
    })).id;
    await sel({ act: "click", clipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(250);

    const before = await sel({});
    const b = await clipState(clipId);
    const key = i % 2 === 0 ? "down" : "up";
    await sel({ act: "postKey", key });
    await sleep(SETTLE);
    const after = await sel({});
    const a = await clipState(clipId);

    const entered = after.keyPressProbe.arrangeVerticalArrow
      !== before.keyPressProbe.arrangeVerticalArrow;
    const moved = b?.trackId !== a?.trackId;
    l3.entered.push(entered);
    l3.moved.push(moved);
    l3.rollFocus.push(before.pianoRollEditorFocused);
    console.log(`   r${String(i).padStart(2)}  key=${key} entered=${entered ? "Y" : "n"}`
      + ` movedTrack=${moved ? "Y" : "n"}  rollFocus=${before.pianoRollEditorFocused ? 1 : 0}`
      + `  track ${b?.trackId === trackA ? "A" : "B"}->${a?.trackId === trackA ? "A" : "B"}`);
    await req("clip.remove", { clipId });
  }

  // ═══ SUMMARY ═══
  const n = (a) => a.filter(Boolean).length;
  console.log("\n════════════════════════ SUMMARY ════════════════════════");
  for (const [name, leg, key] of [
    ["LEG 1 ←/→ fresh clip", l1, "moved"],
    ["LEG 2 ←/→ alternating", l2, "moved"],
    ["LEG 3 ↑/↓ fresh clip", l3, "moved"],
  ]) {
    console.log(`\n${name}`);
    console.log(`   mount ENTERED   ${n(leg.entered)}/${ROUNDS}   ${pattern(leg.entered)}`);
    console.log(`   clip MOVED      ${n(leg[key])}/${ROUNDS}   ${pattern(leg[key])}`);
    console.log(`   pianoRollFocus  ${n(leg.rollFocus)}/${ROUNDS}   ${pattern(leg.rollFocus)}`);
    if (leg.wsFocus) {
      console.log(`   wsFocus(@Focus) ${n(leg.wsFocus)}/${ROUNDS}   ${pattern(leg.wsFocus)}`);
    }
  }

  const alternated = [l1, l2, l3].some((l) => n(l.rollFocus) > 0 && n(l.rollFocus) < ROUNDS);
  const allAlive = [l1, l2, l3].every((l) => n(l.entered) === ROUNDS && n(l.moved) === ROUNDS);

  console.log("\n════ VERDICT ON THE PREMISE ════");
  if (allAlive && alternated) {
    console.log("REFUTED, WITH THE ANTECEDENT PRESENT. Every posted arrow entered its");
    console.log("mount and moved the clip, ACROSS clip switches, WHILE");
    console.log("`pianoRollEditorFocused` was alternating during the run. That is the");
    console.log("live demonstration of independence, not a run in which the coin sat");
    console.log("still. The arrow nudges are NOT riding the alternating flag.");
  } else if (allAlive && !alternated) {
    console.log("NOT REPRODUCED, BUT THE CONTROL IS MISSING. Arrows worked 12/12, but");
    console.log("`pianoRollEditorFocused` did NOT vary this run, so the antecedent");
    console.log("condition was never present and this refutes nothing. Find a recipe");
    console.log("that makes the flag alternate before drawing any conclusion.");
  } else {
    console.log("REPRODUCED (at least partly). Read the two patterns per leg: if");
    console.log("`entered` tracks `pianoRollFocus` the arrows ARE riding the focus coin");
    console.log("flip and the monitor fix is the right shape. If `entered` is 12/12 but");
    console.log("`moved` is not, the key ARRIVED and a GUARD declined — a different");
    console.log("defect, to be reported rather than fixed under this item.");
  }
  process.exit(0);
} catch (e) {
  console.error("PROBE ERROR", e);
  process.exit(2);
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
