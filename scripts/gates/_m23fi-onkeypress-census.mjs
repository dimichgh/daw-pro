// m23-fi PROBE — a PER-MOUNT CENSUS of every real `.onKeyPress` in this app.
//
// ⚠️ A PROBE, NOT A GATE: it MEASURES and prints a per-mount verdict. It exits 0
// whenever the measurement itself is VALID; it exits non-zero only when the
// instrument is broken (no delivery, dead counters), because "the mount is dead"
// is the finding, not a failure. Staging (17695) only.
//
// ═══ WHY ═══
// m23-cf measured that `.onKeyPress(.delete)` never fires in this app and fixed
// DELETE with a window-level `NSEvent` monitor that BYPASSES SwiftUI focus. The
// root cause — `arrangeKeyFocusNonce`'s focus assertion never reaching AppKit —
// is still live (m23-fi). This probe answers: WHICH OTHER MOUNTS ARE DEAD?
//
// There are exactly 7 real `.onKeyPress` mounts in Swift code (55 grep hits, 48
// of them comments):
//   M1 ContentView.swift:1740   .delete            → handleDeleteKey
//   M2 ContentView.swift:1762   ←/→                → handleArrangeNudgeKey (horizontal)
//   M3 ContentView.swift:1791   ↑/↓                → handleArrangeNudgeKey (vertical)
//   M4 PianoRollView.swift:490  .delete            → onDeleteKey
//   M5 AutomationLaneEditor:130 .delete            → onDeleteKey ?? deleteSelection
//   M6 TrackListView.swift:863  .escape            → cancelRename (track rename)
//   M7 TimelineLanesView:2399   .escape            → cancelRename (marker rename)
//
// ═══ THE DISCRIMINATOR ═══
// Five mounts bump a `KeyPressProbe` counter as the FIRST STATEMENT of their
// closure, before any guard — the m23-cf technique. A counter that does not move
// means SwiftUI never delivered; a counter that moves with no effect means a
// guard declined.
//
// TWO MOUNTS CANNOT CARRY ONE: `DeleteKeySiteTests` pins the exact one-line
// spelling of M1's and M4's closures, and weakening a shipped guard for
// scaffolding is the wrong trade. Their discriminator is `deleteKeyFunnelSeq`
// UNDER A ⇧ CHORD — the m23-cf-3 monitor refuses `.chord` and RETURNS the
// event, so with a modifier held the monitor can neither bump the funnel nor
// swallow the key, and a funnel bump can only have come from a SwiftUI mount.
// A BARE ⌦ proves nothing about these mounts and the probe says so at each leg.
//
// ═══ THE CONTROLS (without these the zeros prove nothing) ═══
//   C1  ECHO↔STORAGE: `{act:"probeSelfTest"}` bumps all five. If the echo did
//       not move, it is reading different fields and every zero is meaningless.
//   C2  QUEUE: a posted SPACE toggles the transport (rides the NSEvent monitor,
//       bypassing SwiftUI). Proves `NSApp.postEvent` delivers.
//   C3  DELIVERY-TO-A-FOCUSED-MOUNT: ESC into the marker rename field (M7). The
//       ONE mount armable headlessly. If M7 fires, the arrow zeros are a real
//       negative rather than a dead synthesis path.
//   C4  POLICY ARMED: `{act:"nudge"}` drives the SAME handler the arrow mounts
//       call, with the chord passed explicitly. If it moves the clip, the
//       fixture is armed and a dead arrow key is the KEY's failure, not the
//       policy's.
//   C5  CHORD MATCHING: ⇧→ must still enter the arrow mount. Without it, every
//       ⇧-chord delete reading below could be explained by `.onKeyPress`
//       refusing modified keys, which has nothing to do with the bug.
//
// ⚠️ EXIT DISCIPLINE (m23-es): `process.exit()` does NOT unwind `try/finally` in
// Node, so the probe this one descends from orphans a staging app on every exit
// path. Here the code is set in a variable and the function RETURNS, so the
// `finally` that calls `stopStaging` always runs.
//
//   node scripts/gates/_m23fi-onkeypress-census.mjs
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep,
} from "./_staging.mjs";

const GATE = "m23ficensus";
const PORT = STAGING_PORT;
const OUT = "/tmp/m23ficensus";
const PIDFILE = "/tmp/m23ficensus-staging.pid";
const SETTLE = 700;

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

buildOrAbort({ label: "building staging binary (m23-fi census)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();

let exitCode = 0;
// The ⇧-chord verdict for M1/M4/M5, set by the unshadowing leg and folded into
// the census at the end — the ONE reading that is not monitor-confounded.
let chordVerdict = null;
try {
  const sel = (p = {}) => req("debug.arrangeSelection", p);
  const ks = (p = {}) => req("debug.keySpace", p);
  const probe = async () => (await sel({})).keyPressProbe;
  const postKey = async (key) => { await sel({ act: "postKey", key }); await sleep(SETTLE); };
  const verdicts = [];
  const record = (id, site, key, action, entered, note) => {
    verdicts.push({ id, site, key, action, entered, note });
  };

  // ── FIXTURE ──────────────────────────────────────────────────────────────
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackA = (await req("track.add", { kind: "instrument", name: "A" })).id;
  const trackB = (await req("track.add", { kind: "instrument", name: "B" })).id;
  const clipId = (await req("clip.addMIDI", {
    trackId: trackA, atBeat: 4, lengthBeats: 8,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  const markerId = (await req("marker.add", { beat: 16, name: "RenameMe" })).id
    ?? (await req("marker.list", {})).markers?.[0]?.id;
  await sleep(300);

  // ── AMBIENT FACTS THAT BOUND EVERY VERDICT BELOW ─────────────────────────
  const amb = await ks({});
  console.log("\n════ AMBIENT (the validity bound on every focus verdict) ════");
  console.log(`   appActive          = ${amb.appActive}`);
  console.log(`   fullKeyboardAccess = ${amb.fullKeyboardAccess}`);
  console.log(`   windowRole         = ${amb.windowRole}`);
  console.log(`   monitorInstalled   = ${amb.monitorInstalled}`);
  {
    const ke = (await sel({})).keyPressProbe.keyEquivalentScalars;
    const hex = (n) => `0x${n.toString(16).toUpperCase().padStart(2, "0")}`;
    console.log("   SwiftUI KeyEquivalent constants, READ OUT OF SwiftUI:");
    console.log(`      .delete=${hex(ke.delete)}  .deleteForward=${hex(ke.deleteForward)}`
      + `  .rightArrow=${hex(ke.rightArrow)}  .escape=${hex(ke.escape)}`);
  }

  // ── C1 — ECHO↔STORAGE ────────────────────────────────────────────────────
  const c1a = await probe();
  await sel({ act: "probeSelfTest" });
  const c1b = await probe();
  const c1Keys = ["arrangeHorizontalArrow", "arrangeVerticalArrow",
    "automationLaneDelete", "markerRenameEscape", "trackRenameEscape"];
  const c1Moved = c1Keys.filter((k) => c1b[k] === c1a[k] + 1);
  console.log("\n════ C1 — the echo reads the fields the closures write ════");
  console.log(`   ${c1Moved.length}/5 counters moved by exactly 1: ${c1Moved.join(", ")}`);
  console.log("   (ContentView's and PianoRollView's ⌦ closures have NO counter — their exact");
  console.log("    spelling is pinned by DeleteKeySiteTests. Their discriminator is");
  console.log("    `deleteKeyFunnelSeq` under a ⇧ chord, which the monitor refuses and passes on.)");
  if (c1Moved.length !== 5) {
    console.log("INSTRUMENT BROKEN: the self-test did not move all 7 counters, so a");
    console.log("zero below cannot be read as 'the key never arrived'.");
    exitCode = 2;
  }

  // ── C2 — the queue delivers ──────────────────────────────────────────────
  const t0 = await ks({});
  await ks({ press: true, post: true });
  await sleep(SETTLE);
  const t1 = await ks({});
  const queueWorks = t0.isPlaying !== t1.isPlaying;
  if (t1.isPlaying) await req("transport.stop");
  console.log("\n════ C2 — NSApp.postEvent delivers (SPACE, monitor route) ════");
  console.log(`   isPlaying ${t0.isPlaying} -> ${t1.isPlaying}  => delivers = ${queueWorks}`);
  if (!queueWorks) {
    console.log("INCONCLUSIVE: the queue itself is dead; nothing below says anything.");
    exitCode = 3;
  }

  // ── ARM THE ARRANGE: select a clip, which asserts workspace focus ─────────
  await sel({ act: "click", clipId });
  await sel({ act: "pianoRollNotes", select: false });
  await sleep(400);
  const armed = await sel({});
  const armedKs = await ks({});
  console.log("\n════ ⭐ THE ROOT-CAUSE READ — focus VALUES vs the responder ════");
  console.log(`   keyFocusNonce            = ${armed.keyFocusNonce}   (assertions made)`);
  console.log(`   arrangeWorkspaceFocused  = ${armed.keyPressProbe.arrangeWorkspaceFocused}`
    + "   <- did `focused = true` STICK?");
  console.log(`   pianoRollEditorFocused   = ${armed.pianoRollEditorFocused}`);
  console.log(`   firstResponder           = ${armedKs.firstResponder} (${armedKs.responderClass})`);
  console.log(`   selected clips           = ${armed.count}`);

  // ── M1 — ContentView .onKeyPress(.delete) ────────────────────────────────
  // ⚠️ CONFOUND STATED: the m23-cf monitor swallows ⌦ before SwiftUI sees it.
  // The per-mount counter is what separates the two; the monitor seq is read
  // alongside so the confound is visible rather than argued.
  {
    const before = await probe();
    const s0 = await sel({});
    const clipsBefore = (await req("debug.editClipboard", {})).clips.length;
    await sel({ act: "keyDelete", post: true });
    await sleep(SETTLE);
    const after = await probe();
    const s1 = await sel({});
    const clipsAfter = (await req("debug.editClipboard", {})).clips.length;
    const entered = null; // CONFOUNDED: the monitor swallows a bare ⌦. See the ⇧ leg.
    console.log("\n════ M1 — ContentView.swift:1740  ⌦  (delete arrange selection) ════");
    console.log("   BARE ⌦ IS CONFOUNDED — the m23-cf-3 monitor swallows it before SwiftUI.");
    console.log("   The verdict comes from the ⇧-chord leg below; this leg shows the confound.");
    console.log(`   monitor seq    ${s0.deleteKeyMonitorSeq} -> ${s1.deleteKeyMonitorSeq}`
      + `  funnel ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`);
    console.log(`   clips ${clipsBefore} -> ${clipsAfter}  (the OPERATION still works via the monitor)`);
    record("M1", "ContentView.swift:1740", "⌦", "delete arrange selection", entered,
      `monitor ${s1.deleteKeyMonitorSeq - s0.deleteKeyMonitorSeq}, funnel `
      + `${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq}, clips ${clipsBefore}->${clipsAfter}`);
  }

  // Re-arm: M1 may have deleted the clip.
  let liveClipId = clipId;
  {
    const tracks = (await req("project.snapshot", {})).tracks ?? [];
    const found = tracks.flatMap((t) => (t.clips ?? []).map((c) => c.id));
    if (!found.includes(clipId)) {
      liveClipId = (await req("clip.addMIDI", {
        trackId: trackA, atBeat: 4, lengthBeats: 8,
        notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
      })).id;
    }
    await sel({ act: "click", clipId: liveClipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(400);
  }

  const clipState = async (id) => {
    const tracks = (await req("project.snapshot", {})).tracks ?? [];
    for (const t of tracks) {
      const c = (t.clips ?? []).find((x) => x.id === id);
      if (c) return { trackId: t.id, startBeat: c.startBeat };
    }
    return null;
  };

  // ── C4 — the nudge POLICY is armed (drives the same handler, seam route) ──
  {
    const b = await clipState(liveClipId);
    const out = await sel({ act: "nudge", direction: "right" });
    const a = await clipState(liveClipId);
    console.log("\n════ C4 — the nudge POLICY grants in this exact state ════");
    console.log(`   act:"nudge" right → startBeat ${b?.startBeat} -> ${a?.startBeat}`
      + `   handled=${out.nudge?.handled} refusedBy=${out.nudge?.refusedBy ?? "null"}`);
    // put it back so M2's before/after starts where C4 started
    await sel({ act: "nudge", direction: "left" });
    await sleep(200);
  }

  // ── M2 — ←/→ arrow nudge ─────────────────────────────────────────────────
  {
    const before = await probe();
    const b = await clipState(liveClipId);
    await postKey("right");
    const after = await probe();
    const a = await clipState(liveClipId);
    const entered = after.arrangeHorizontalArrow !== before.arrangeHorizontalArrow;
    console.log("\n════ M2 — ContentView.swift:1762  ←/→  (nudge clips in time) ════");
    console.log(`   mount counter  ${before.arrangeHorizontalArrow} -> ${after.arrangeHorizontalArrow}`
      + `   entered = ${entered}`);
    console.log(`   clip startBeat ${b?.startBeat} -> ${a?.startBeat}   moved = ${b?.startBeat !== a?.startBeat}`);
    record("M2", "ContentView.swift:1762", "←/→", "nudge arrange selection in time", entered,
      `startBeat ${b?.startBeat}->${a?.startBeat}`);
  }

  // ── M3 — ↑/↓ arrow nudge across tracks ───────────────────────────────────
  {
    const before = await probe();
    const b = await clipState(liveClipId);
    await postKey("down");
    const after = await probe();
    const a = await clipState(liveClipId);
    const entered = after.arrangeVerticalArrow !== before.arrangeVerticalArrow;
    const movedTrack = b?.trackId !== a?.trackId;
    console.log("\n════ M3 — ContentView.swift:1791  ↑/↓  (move clips across tracks) ════");
    console.log(`   mount counter  ${before.arrangeVerticalArrow} -> ${after.arrangeVerticalArrow}`
      + `   entered = ${entered}`);
    console.log(`   clip track     ${b?.trackId === trackA ? "A" : "B"} -> `
      + `${a?.trackId === trackA ? "A" : "B"}   moved = ${movedTrack}`);
    // control: the same handler through the seam
    const ctl = await sel({ act: "nudge", direction: "down" });
    const c = await clipState(liveClipId);
    console.log(`   CONTROL act:"nudge" down → track ${c?.trackId === trackA ? "A" : "B"}`
      + `  handled=${ctl.nudge?.handled} refusedBy=${ctl.nudge?.refusedBy ?? "null"}`);
    record("M3", "ContentView.swift:1791", "↑/↓", "move arrange selection across tracks", entered,
      `track moved by key = ${movedTrack}; seam control handled=${ctl.nudge?.handled}`);
  }

  // ── M4 — PianoRollView .onKeyPress(.delete) ──────────────────────────────
  {
    await sel({ act: "click", clipId: liveClipId });
    await sleep(400);
    await sel({ act: "pianoRollNotes", select: true });
    await sleep(400);
    const s0 = await sel({});
    const before = await probe();
    await sel({ act: "keyDelete", post: true });
    await sleep(SETTLE);
    const after = await probe();
    const s1 = await sel({});
    const entered = null; // CONFOUNDED, same as M1.
    console.log("\n════ M4 — PianoRollView.swift:490  ⌦  (delete selected notes) ════");
    console.log(`   roll open on clip = ${s0.editorClipId !== null}`
      + `  noteSelection = ${s0.pianoRollNoteSelection}`
      + `  rollFocused = ${s0.pianoRollEditorFocused}`);
    console.log("   BARE ⌦ CONFOUNDED by the monitor; verdict from the ⇧-chord leg below.");
    console.log(`   monitor seq    ${s0.deleteKeyMonitorSeq} -> ${s1.deleteKeyMonitorSeq}`
      + `  funnel ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`);
    record("M4", "PianoRollView.swift:490", "⌦", "delete selected notes", entered,
      `rollFocused=${s0.pianoRollEditorFocused}, monitor `
      + `${s1.deleteKeyMonitorSeq - s0.deleteKeyMonitorSeq}, funnel `
      + `${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq}`);
  }

  // ── M5 — AutomationLaneEditor .onKeyPress(.delete) ───────────────────────
  {
    let laneArmed = false;
    try {
      const lane = (await req("automation.addLane",
        { trackId: trackA, target: { type: "volume" } })).lane;
      await req("automation.setPoints", {
        trackId: trackA, laneId: lane.id,
        points: [{ beat: 2, value: 0.5 }, { beat: 6, value: 0.9 }],
      });
      laneArmed = true;
    } catch (e) { console.log(`   (automation lane setup failed: ${e.message})`); }
    let expanded = null;
    try { expanded = await req("ui.showAutomation", { trackId: trackA }); } catch (e) {
      console.log(`   (ui.showAutomation refused: ${e.message})`);
    }
    await sleep(600);
    let pointsSel = null;
    try { pointsSel = await sel({ act: "automationPoints", select: true }); } catch (e) {
      console.log(`   (act:"automationPoints" refused: ${e.message})`);
    }
    await sleep(400);
    const s0 = await sel({});
    const before = await probe();
    await sel({ act: "keyDelete", post: true });
    await sleep(SETTLE);
    const after = await probe();
    const s1 = await sel({});
    const entered = after.automationLaneDelete !== before.automationLaneDelete;
    console.log("\n════ M5 — AutomationLaneEditor.swift:130  ⌦  (delete breakpoint) ════");
    console.log("   (bare ⌦ is monitor-confounded here too; the ⇧-chord leg is the verdict)");
    console.log(`   laneArmed=${laneArmed} expanded=${expanded?.expanded ?? "?"}`
      + ` selectedLaneId=${expanded?.selectedLaneId ? "set" : "null"}`
      + `  lanesClaimingSelection=${s0.automationPointLaneCount}`
      + `  lanesFocused=${s0.keyPressProbe.automationLanesFocusedCount}`);
    console.log(`   mount counter  ${before.automationLaneDelete} -> ${after.automationLaneDelete}`
      + `   entered = ${entered}`);
    console.log(`   monitor seq    ${s0.deleteKeyMonitorSeq} -> ${s1.deleteKeyMonitorSeq}`
      + `  funnel ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`);
    record("M5", "AutomationLaneEditor.swift:130", "⌦", "delete selected breakpoint", entered,
      `lanesFocused=${s0.keyPressProbe.automationLanesFocusedCount}, `
      + `lanesClaiming=${s0.automationPointLaneCount}, pointsSel=${pointsSel !== null}`);
  }

  // ── M7 / C3 — ESC in the marker rename field (the DELIVERY control) ───────
  {
    // negative control first: ESC with no field open must not move the counter
    const n0 = await probe();
    await postKey("escape");
    const n1 = await probe();
    const ambientBump = n1.markerRenameEscape !== n0.markerRenameEscape;

    await req("debug.markerRename", markerId ? { markerId } : {});
    await sleep(500);
    const fieldKs = await ks({});
    const before = await probe();
    const namesBefore = (await req("marker.list", {})).markers.map((m) => m.name).join("|");
    await postKey("escape");
    const after = await probe();
    const namesAfter = (await req("marker.list", {})).markers.map((m) => m.name).join("|");
    const entered = after.markerRenameEscape !== before.markerRenameEscape;
    console.log("\n════ M7 / C3 — TimelineLanesView.swift:2399  ESC  (cancel marker rename) ════");
    console.log(`   ambient ESC with no field open bumped the counter = ${ambientBump} (want false)`);
    console.log(`   field focused = ${before.markerRenameFieldFocused}`
      + `  firstResponder = ${fieldKs.firstResponder} (${fieldKs.responderClass})`);
    console.log(`   mount counter  ${before.markerRenameEscape} -> ${after.markerRenameEscape}`
      + `   entered = ${entered}`);
    console.log(`   marker names  ${namesBefore} -> ${namesAfter}`);
    record("M7", "TimelineLanesView.swift:2399", "ESC", "cancel a marker rename", entered,
      `fieldFocused=${before.markerRenameFieldFocused}, responder=${fieldKs.firstResponder}, `
      + `ambientBump=${ambientBump}`);
    try { await req("debug.markerRename", { clear: true }); } catch { /* already closed */ }
    await sleep(300);
  }

  // ── ⭐⭐ THE UNSHADOWING LEG — is the DELETE mount DEAD, or SHADOWED? ─────
  //
  // M1/M4/M5 above are CONFOUNDED and the probe says so: since m23-cf-3 the
  // `NSEvent` monitor calls `handleDeleteKey()` and returns `nil`, which
  // SWALLOWS the key before SwiftUI can route it. A dead mount and a shadowed
  // mount look identical from a bare ⌦.
  //
  // The monitor's SECOND guard separates them for free: `.chord` refuses any
  // ⌘/⌥/⌃/⇧ delete and RETURNS THE EVENT, so a ⇧⌫ passes straight through the
  // monitor and reaches SwiftUI exactly as an unmonitored ⌫ would.
  //
  // ⚠️ C5 IS NOT OPTIONAL. `.onKeyPress(_ key:)` matching a key while a modifier
  // is held is an assumption, and if it is wrong every counter below reads 0 for
  // a reason that has nothing to do with focus. C5 posts ⇧→ at the mount that
  // was just MEASURED live and requires it to still fire.
  {
    await sel({ act: "click", clipId: liveClipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(400);

    const c5a = await probe();
    await sel({ act: "postKey", key: "right", shift: true });
    await sleep(SETTLE);
    const c5b = await probe();
    const chordMatches = c5b.arrangeHorizontalArrow !== c5a.arrangeHorizontalArrow;
    console.log("\n════ C5 — does `.onKeyPress` still match with a modifier held? ════");
    console.log(`   ⇧→ at the LIVE arrow mount: ${c5a.arrangeHorizontalArrow} -> `
      + `${c5b.arrangeHorizontalArrow}   matches = ${chordMatches}`);
    if (!chordMatches) {
      console.log("   ⚠️ CHORDED KEYS DO NOT MATCH — the unshadowing leg below is INVALID.");
    }

    const before = await probe();
    const s0 = await sel({});
    const b = await clipState(liveClipId);
    const shifted = await sel({ act: "postKey", key: "delete", shift: true });
    await sleep(SETTLE);
    const after = await probe();
    const s1 = await sel({});
    const a = await clipState(liveClipId);
    console.log("\n════ ⭐⭐ M1-UNSHADOWED — ⇧⌫ (monitor refuses `chord`, SwiftUI gets it) ════");
    console.log(`   posted = ${shifted.posted}`);
    console.log(`   monitor seq  ${s0.deleteKeyMonitorSeq} -> ${s1.deleteKeyMonitorSeq}`
      + `  refusedBy=${JSON.stringify(s1.deleteKeyMonitorRefusedBy)}  (want "chord")`);
    console.log(`   funnel       ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   <- M1/M4 fired = ${s1.deleteKeyFunnelSeq !== s0.deleteKeyFunnelSeq}`);
    console.log(`   M5 counter   ${before.automationLaneDelete} -> ${after.automationLaneDelete}`
      + `   <- M5 fired = ${after.automationLaneDelete !== before.automationLaneDelete}`);
    chordVerdict = s1.deleteKeyFunnelSeq !== s0.deleteKeyFunnelSeq
      || after.automationLaneDelete !== before.automationLaneDelete;
    console.log(`   clip present ${b !== null} -> ${a !== null}`);
    console.log(`   arrangeWorkspaceFocused = ${s1.keyPressProbe.arrangeWorkspaceFocused}`
      + `  pianoRollEditorFocused = ${s1.pianoRollEditorFocused}`
      + `  lanesFocused = ${s1.keyPressProbe.automationLanesFocusedCount}`);
  }

  // ── ⭐ THE CHARACTER SWEEP — what DOES `.onKeyPress(.delete)` match? ─────
  //
  // The unshadowing leg narrowed the failure to the KEY, not the focus: the same
  // focused view took ⇧→ and refused ⇧⌫. The remaining candidate is the
  // CHARACTER. Every variant below is posted with ⇧ held so the monitor refuses
  // `chord` and SwiftUI gets the event; the only thing that varies is what the
  // event carries. `arrangeDelete` moving names the character the mount wants.
  {
    await sel({ act: "click", clipId: liveClipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(400);
    const variants = [
      { label: "keyCode 51  char 0x7F (NSDeleteCharacter — what the app sends)", keyCode: 51, charCode: 0x7F },
      { label: "keyCode 51  char 0x08 (NSBackspaceCharacter)", keyCode: 51, charCode: 0x08 },
      { label: "keyCode 117 char 0xF728 (NSDeleteFunctionKey — forward delete)", keyCode: 117, charCode: 0xF728 },
      { label: "keyCode 51  char 0xF728", keyCode: 51, charCode: 0xF728 },
    ];
    console.log("\n════ ⭐ CHARACTER SWEEP at the arrange mount (⇧ held throughout) ════");
    for (const v of variants) {
      const b = await sel({});
      await sel({ act: "postKey", key: "delete", shift: true, keyCode: v.keyCode, charCode: v.charCode });
      await sleep(SETTLE);
      const a = await sel({});
      const hit = a.deleteKeyFunnelSeq !== b.deleteKeyFunnelSeq
        || a.keyPressProbe.automationLaneDelete !== b.keyPressProbe.automationLaneDelete;
      console.log(`   ${hit ? "✓ ENTERED" : "  silent "}  ${v.label}`);
    }
  }

  // ── ⭐⭐ THE AUTHENTIC KEY — what does the REAL ⌫ produce on this Mac? ────
  //
  // Everything above leaves ONE ambiguity that decides the whole item: does the
  // REAL delete key send 0x7F (in which case the mount is genuinely dead for the
  // user) or 0x08 (in which case the mount is ALIVE and every headless "delete
  // is dead" reading since m23-g1 was the SEAM'S synthesis being wrong)?
  //
  // `CGEvent(virtualKey:)` + `NSEvent(cgEvent:)` runs the system's own
  // HID→Unicode translation for the live keyboard layout. No permission, no
  // human, no posting at the HID tap.
  {
    await sel({ act: "click", clipId: liveClipId });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(400);
    console.log("\n════ ⭐⭐ AUTHENTIC-CHARACTER TRANSLATION (the system's own) ════");
    for (const [label, keyCode] of [["⌫ (kVK_Delete 51)", 51], ["⌦ (kVK_ForwardDelete 117)", 117],
      ["→ (kVK_RightArrow 124)", 124], ["ESC (kVK_Escape 53)", 53]]) {
      const before = await sel({});
      const r = await sel({ act: "postKey", key: "delete", shift: true, keyCode, authentic: true });
      await sleep(SETTLE);
      const after = await sel({});
      const hit = after.deleteKeyFunnelSeq !== before.deleteKeyFunnelSeq
        || after.keyPressProbe.arrangeHorizontalArrow !== before.keyPressProbe.arrangeHorizontalArrow
        || after.keyPressProbe.automationLaneDelete !== before.keyPressProbe.automationLaneDelete;
      console.log(`   ${label.padEnd(26)} → characters ${r.authenticCharactersHex}`
        + `   entered a mount = ${hit}`);
    }
  }

  // ── M2/M3 CONDITIONALITY — DELIBERATELY NOT MEASURED HERE ────────────────
  //
  // `applyArrangeMarquee` (DAWProApp.swift:952) deliberately does NOT bump
  // `arrangeKeyFocusNonce`, so "do the arrows work after a rubber band?" is a
  // real question about M2/M3's reachability. It CANNOT be answered in this
  // process: every leg above ran an `act:"click"`, which asserts focus, and
  // `project.new` does not reset it — a marquee leg added at the end read
  // `keyFocusNonce = 6` and `arrangeWorkspaceFocused = true` BEFORE the band was
  // drawn, i.e. it could not have failed. That leg was REMOVED rather than kept
  // and caveated; a leg that cannot fail is the vacuity shape this milestone
  // keeps paying for.
  //
  // ⭐ The cold-app answer lives in `_m23fi-marquee-focus-probe.mjs`, which
  // starts its own staging process and bands BEFORE clicking anything. Measured
  // there: `arrangeWorkspaceFocused` is ALREADY true at `keyFocusNonce == 0`, so
  // the arrows work with a marquee-only selection and M2/M3 are unconditional.
  console.log("\n════ M2/M3 after a MARQUEE ════");
  console.log("   NOT MEASURABLE IN THIS PROCESS (focus is inherited from the legs above).");
  console.log("   See scripts/gates/_m23fi-marquee-focus-probe.mjs — cold app, answer: REACHED.");

  // ── M6 — the track rename field's ESC. NO HEADLESS SEAM EXISTS. ──────────
  {
    const p = await probe();
    console.log("\n════ M6 — TrackListView.swift:863  ESC  (cancel a track rename) ════");
    console.log("   NOT MEASURABLE HEADLESSLY: there is no `debug.trackRename` seam, so");
    console.log("   nothing can open the field. Its idiom is byte-for-byte M7's (TextField");
    console.log("   + .focused + .onKeyPress(.escape) + focus-loss commit), so M7's");
    console.log("   measured verdict transfers by INFERENCE, labelled as such.");
    console.log(`   trackRenameFieldFocused = ${p.trackRenameFieldFocused} (never opened)`);
    record("M6", "TrackListView.swift:863", "ESC", "cancel a track rename", null,
      "no headless seam; inferred from M7");
  }

  // ── SUMMARY ──────────────────────────────────────────────────────────────
  for (const v of verdicts) {
    if (["M1", "M4", "M5"].includes(v.id)) {
      v.entered = chordVerdict;
      v.note += `; ⇧-chord (unconfounded) fired = ${chordVerdict}`;
    }
  }
  console.log("\n════ PER-MOUNT CENSUS ════");
  for (const v of verdicts) {
    const tag = v.entered === null ? "NOT MEASURED" : (v.entered ? "REACHED     " : "DEAD        ");
    console.log(`   ${v.id}  ${tag}  ${v.key.padEnd(4)} ${v.site}`);
    console.log(`         ${v.action}`);
    console.log(`         ${v.note}`);
  }
  const dead = verdicts.filter((v) => v.entered === false).length;
  const live = verdicts.filter((v) => v.entered === true).length;
  console.log(`\n   reached ${live} · dead ${dead} · not measured `
    + `${verdicts.filter((v) => v.entered === null).length}`);
  console.log(`   ambient: appActive=${amb.appActive} fullKeyboardAccess=${amb.fullKeyboardAccess}`);
} catch (e) {
  console.error("PROBE ERROR", e);
  exitCode = 2;
} finally {
  try { ws.close(); } catch { /* already gone */ }
  stopStaging(GATE, PIDFILE);
}
process.exit(exitCode);
