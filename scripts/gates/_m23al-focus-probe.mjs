// m23-al MEASUREMENT PROBE — NOT A GATE. No pass/fail, no assertions: it prints
// what `pianoRollEditorFocused` actually does across clip switches so the item's
// stated cause can be checked before anything is built on it.
//
// `_`-prefixed on purpose: this is a harness/instrument, not a gate, and must not
// be counted in the gate corpus.
//
// WHY THIS EXISTS. m23-al is filed as a LIVE BUG on one inherited measurement:
// the flag read `true,false,true,false…`, exactly 6 true / 6 false over 12
// consecutive clip selections, with the cause given as
// `.onAppear{isFocused = true}` racing `.onDisappear{onFocusChange(false)}` at
// each `.id(clip.id)` rebuild.
//
// ⚠️ PERFECT ALTERNATION IS A SIGNATURE, NOT A RACE. A genuine lifecycle
// ordering race does not produce exactly-alternating results 12 times running.
// The obvious confound is the FIXTURE'S OWN PERIOD: if m23-x clicked A,B,A,B
// then a flag that tracks WHICH CLIP is selected is indistinguishable from a
// flag that alternates per switch. Those are different bugs with different
// fixes, and one of them is not a bug at all.
//
// SO THIS VARIES THE SEQUENCE PERIOD AND HOLDS EVERYTHING ELSE FIXED:
//   S1 ABAB     period 2  — reproduces the m23-x shape
//   S2 ABCABC   period 3  — alternation and identity now DISAGREE
//   S3 ABCD     period 4  — same, wider
//   S4 AABB     period 4, with REPEATS — clicking the SAME clip does not change
//               `.id(clip.id)`, so no rebuild happens and the flag must not move.
//               This is the control: it separates "changed on a switch" from
//               "changed on a click".
//   S5 AAAA…    12 clicks on ONE clip — ZERO rebuilds for the whole sequence.
//               ⚠️ ADDED AFTER S1-S4 HAD ALREADY PRODUCED A CONFIDENT (AND WRONG)
//               ANSWER. All four read as pure click parity, and that is what this
//               probe printed and what the roadmap entry first recorded. But every
//               one of S1-S4 rebuilds the roll on at least every other click, so
//               "parity" and "a rebuild happened" are confounded in all four —
//               the same confound, one level up, as the inherited A,B,A,B
//               measurement this probe was written to break. S5 separates them:
//               it reads true ONCE (the click that opens the roll) and false
//               eleven times. A click without a rebuild is NOT a toggle.
//
// READING THE RESULT
//   • a long run of repeats drives it false and HOLDS  -> the arrange root takes
//     focus on every click and only the roll's `.onAppear` (rebuild-only) hands
//     it back; the alternation in S1-S3 is those two racing, and `.onDisappear`
//     is not involved. THIS IS WHAT THE TREE ACTUALLY DOES (measured 2026-08-03).
//   • flips on every switch but HOLDS across repeats  -> tied to the rebuild;
//     m23-al's stated cause stands.
//   • pattern follows the CLIP (same clip -> same value)  -> the cause in the
//     filing is wrong; it is clip-identity-dependent, not switch-dependent.
//   • no flips anywhere  -> the filing collapses, as its own caveat allows.
//
// ⚠️ IF YOU ADD A SEQUENCE, ADD IT FOR A CONFOUND YOU CAN NAME. Every sequence
// here exists to break a specific tie, and the two that mattered (S4, S5) were
// both written because a previous verdict was too clean to trust.
//
// Each reading is taken TWICE — immediately and again after LATCH_MS — because
// the filing's own claim is that the false readings LATCH (i.e. are not a late
// report that settles). A value that differs between the two columns is a
// settling report and changes the diagnosis again.
//
//   node scripts/gates/_m23al-focus-probe.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23al";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23AL_OUT || "/tmp/m23al";
const PIDFILE = process.env.M23AL_PIDFILE || "/tmp/m23al-staging.pid";
const BINARY = process.env.M23AL_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23AL_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 900_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const LEN = 2;
const SETTLE_MS = 250;
// The filing measured the false readings still false 1.4 s later.
const LATCH_MS = 1400;

buildOrAbort({ root: REPO });

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

const staging = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY,
  detached: true, pidfile: PIDFILE, outDir: OUT,
});
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
const sel = (p = {}) => req("debug.arrangeSelection", p);

let teardownDone = false;
function teardown() {
  if (teardownDone) return;
  teardownDone = true;
  stopStaging(GATE, PIDFILE);
}

/** Four MIDI clips on ONE track, each carrying notes (a noteless clip is a
 *  different fixture and this probe must not silently become it). */
async function fixture(name) {
  const trackId = (await req("track.add", { kind: "instrument", name })).id;
  const clips = [];
  for (const beat of [0, 8, 16, 24]) {
    clips.push((await req("clip.addMIDI", {
      trackId, atBeat: beat, lengthBeats: LEN,
      notes: [
        { pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 },
        { pitch: 64, startBeat: 1, lengthBeats: 1, velocity: 100 },
      ],
    })).id);
  }
  await sleep(SETTLE_MS);
  return { trackId, clips };
}

const short = (id) => (id ? String(id).slice(0, 4) : "null");

/**
 * Click `order` (indices into `clips`) one at a time, reading the flag twice
 * after each. Returns the rows; prints them as it goes so a hang still leaves
 * evidence behind.
 */
async function runSequence(label, clips, order) {
  console.log(`\n══ ${label} — ${order.length} clicks ═══════════════════════════`);
  console.log("  #  clip  switch?  focused@250ms  focused@1.4s  editorClipId");
  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  const rows = [];
  let prev = null;
  for (let i = 0; i < order.length; i++) {
    const idx = order[i];
    const id = clips[idx];
    const isSwitch = prev !== null && prev !== id;
    await sel({ act: "click", clipId: id });
    await sleep(SETTLE_MS);
    const a = await sel({});
    await sleep(LATCH_MS - SETTLE_MS);
    const b = await sel({});
    const row = {
      i, clip: "ABCD"[idx], isSwitch,
      early: a.pianoRollEditorFocused, late: b.pianoRollEditorFocused,
      editor: b.editorClipId, editorMatches: b.editorClipId === id,
    };
    rows.push(row);
    console.log(
      `  ${String(i).padStart(2)}  ${row.clip}     ${isSwitch ? "yes" : "no "}` +
      `      ${String(row.early).padEnd(5)}         ${String(row.late).padEnd(5)}` +
      `        ${short(row.editor)}${row.editorMatches ? "" : "  ⚠️ MISMATCH"}`);
    prev = id;
  }
  const t = rows.filter((r) => r.late === true).length;
  const f = rows.filter((r) => r.late === false).length;
  const settling = rows.filter((r) => r.early !== r.late).length;
  // Does the flag depend on WHICH CLIP, or on the SWITCH?
  const byClip = new Map();
  let clipConsistent = true;
  for (const r of rows) {
    if (byClip.has(r.clip) && byClip.get(r.clip) !== r.late) clipConsistent = false;
    byClip.set(r.clip, r.late);
  }
  let flipsOnEverySwitch = true, holdsOnEveryRepeat = true, flipsOnEveryClick = true;
  for (let i = 1; i < rows.length; i++) {
    if (rows[i].isSwitch && rows[i].late === rows[i - 1].late) flipsOnEverySwitch = false;
    if (!rows[i].isSwitch && rows[i].late !== rows[i - 1].late) holdsOnEveryRepeat = false;
    if (rows[i].late === rows[i - 1].late) flipsOnEveryClick = false;
  }
  // The one that turned out to matter: is the value just the PARITY of the
  // click index, with clip identity and switch-vs-repeat both irrelevant?
  const parity = rows.every((r, i) => r.late === (i % 2 === 0));
  console.log(`  -> true=${t} false=${f}  settling(early!=late)=${settling}`);
  console.log(`  -> flips on EVERY CLICK (switch or not): ${flipsOnEveryClick}`);
  console.log(`  -> value == (click index is even) — pure parity: ${parity}`);
  console.log(`  -> flips on every switch: ${flipsOnEverySwitch}`);
  console.log(`  -> same clip always same value (clip-determined): ${clipConsistent}`);
  console.log(`  -> holds across REPEATS (no switch): ${holdsOnEveryRepeat}`);
  return { label, rows, t, f, settling, flipsOnEverySwitch, flipsOnEveryClick,
           parity, clipConsistent, holdsOnEveryRepeat };
}

const results = [];
try {
  await req("project.new", { discardChanges: true });
  const F = await fixture("AL-PROBE");
  console.log(`fixture: 4 MIDI clips ${F.clips.map(short).join(" ")}`);

  // Baseline: what does the flag read with NOTHING selected and no roll open?
  await sel({ act: "clear" });
  await sleep(SETTLE_MS);
  const base = await sel({});
  console.log(`\nBASELINE (nothing selected): focused=${base.pianoRollEditorFocused} ` +
              `editorClipId=${short(base.editorClipId)}`);

  results.push(await runSequence("S1 ABAB (period 2 — the m23-x shape)", F.clips,
    [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1]));
  results.push(await runSequence("S2 ABCABC (period 3)", F.clips,
    [0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2]));
  results.push(await runSequence("S3 ABCD (period 4)", F.clips,
    [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3]));
  results.push(await runSequence("S4 AABB (repeats — the CONTROL)", F.clips,
    [0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1]));
  // S5 CLOSES THE ONE GAP S4 LEFT. In S4 every repeat click happened to start
  // from `true` (the repeats land on odd indices), so it showed `true->false`
  // without a rebuild six times and `false->true` without a rebuild ZERO times.
  // Those are different claims and only the second one rules the roll's view
  // lifecycle out completely: `.onAppear` is the only thing that sets
  // `isFocused = true`, and it cannot run without a rebuild.
  //
  // 12 clicks on ONE clip: `.id(clip.id)` never changes, so NO `PianoRollView`
  // is ever created or destroyed for the whole sequence. If the flag still
  // alternates here, the toggle is SwiftUI handing focus back and forth between
  // two live `@FocusState` owners, with no view lifecycle involved at all.
  results.push(await runSequence("S5 AAAA… (ONE clip, 12 clicks — zero rebuilds)", F.clips,
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));

  console.log("\n══ VERDICT ══════════════════════════════════════════════════");
  const anyFlip = results.some((r) => r.t > 0 && r.f > 0);
  // ⚠️ THE REPEAT CONTROL IS TESTED FIRST, AND THAT ORDER IS THE WHOLE POINT.
  // An earlier draft of this block asked "does it flip on every switch?" first,
  // read `true`, and printed "m23-al's stated cause stands" — while its OWN S4
  // rows showed the flag flipping on a repeat click, which falsifies that cause.
  // A verdict that inspects only the rows its hypothesis predicts will confirm
  // any hypothesis. The control gets asked first.
  const flipsWithoutRebuild = results.some((r) => r.holdsOnEveryRepeat === false);
  if (!anyFlip) {
    console.log("NO FLIPS ANYWHERE — the flag never changed across any sequence.");
    console.log("m23-al's premise does not reproduce; the filing collapses as its");
    console.log("own caveat allows. Check the constant value against the baseline.");
  } else if (flipsWithoutRebuild) {
    console.log("THE FLAG FLIPS WITHOUT ANY REBUILD — m23-al's STATED CAUSE IS FALSE.");
    console.log("A repeat click on the ALREADY-selected clip does not change");
    console.log("`.id(clip.id)`, so no `PianoRollView` is created or destroyed and");
    console.log("neither `.onAppear` nor `.onDisappear` runs — yet the flag flipped.");
    console.log("The appear/disappear ordering race cannot be the mechanism.");
    // ⚠️ THE PARITY READING WAS WRONG AND THIS BLOCK USED TO PRINT IT. S1-S4 are
    // all parity=true, and on that evidence the entry (and this text) said the
    // value was pure click parity. S5 — a run of 12 clicks on ONE clip — reads
    // true once and false eleven times. Parity held only because every one of
    // S1-S4 rebuilds the roll on at least every other click, so "parity" and "a
    // rebuild happened" were confounded in all four. The `runOfRepeats` sequence
    // is what separates them, which is why it exists.
    const runs = results.filter((r) => r.rows.filter((x) => !x.isSwitch).length >= 5);
    if (runs.length) {
      console.log("");
      console.log("AND A LONG RUN OF REPEAT CLICKS DOES NOT TOGGLE — it drives the");
      console.log("flag to false and LEAVES it there:");
      for (const r of runs) console.log(`    ${r.label}: true=${r.t} false=${r.f}`);
      console.log("So a click without a rebuild is not a toggle. Reconstructed rule:");
      console.log("  (a) every click writes `focused = true` on the WORKSPACE ROOT via");
      console.log("      `arrangeKeyFocusNonce` — an ANCESTOR of the roll;");
      console.log("  (b) that write only MOVES focus when the arrange does not already");
      console.log("      hold it (writing true to a true @FocusState changes nothing);");
      console.log("  (c) the ONLY thing that hands focus back to the roll is its own");
      console.log("      `.onAppear`, which runs on a REBUILD and nowhere else.");
      console.log("Hence: no rebuild -> arrange takes it once and keeps it (this run);");
      console.log("every click rebuilds -> (b) and (c) alternate, the 2-cycle in S1-S3.");
    } else if (results.every((r) => r.parity)) {
      console.log("");
      console.log("Every sequence here is parity=true — BUT NONE OF THEM CONTAINS A RUN");
      console.log("OF REPEAT CLICKS, so parity and 'a rebuild happened' are confounded.");
      console.log("Do NOT conclude parity from this; add a one-clip sequence (S5).");
    }
  } else if (results.every((r) => r.flipsOnEverySwitch)) {
    console.log("FLIPS ON EVERY SWITCH AT EVERY PERIOD, and HOLDS across repeats —");
    console.log("independent of the fixture's own period, so not a period artifact");
    console.log("and tied to the rebuild. m23-al's stated cause stands.");
  } else if (results.every((r) => r.clipConsistent)) {
    console.log("CLIP-DETERMINED — the same clip always reads the same value.");
    console.log("m23-al's stated cause is WRONG: this tracks clip identity, not");
    console.log("switch count, and the 6/6 was the A,B,A,B fixture's own period.");
  } else {
    console.log("MIXED — read the per-sequence lines above; neither clean story");
    console.log("holds. Do not summarise this as either one.");
  }
  for (const r of results) {
    console.log(`  ${r.label}: true=${r.t} false=${r.f} ` +
                `parity=${r.parity} flipsEveryClick=${r.flipsOnEveryClick} ` +
                `flipsEverySwitch=${r.flipsOnEverySwitch} clipDetermined=${r.clipConsistent} ` +
                `holdsOnRepeat=${r.holdsOnEveryRepeat} settling=${r.settling}`);
  }
  fs.writeFileSync(`${OUT}/probe.json`, JSON.stringify(results, null, 2));
  console.log(`\nraw rows -> ${OUT}/probe.json`);
} catch (e) {
  console.error("PROBE ABORTED:", e.message);
} finally {
  try { ws.close(); } catch {}
  teardown();
  clearTimeout(killer);
}
