// _m23fk-delete-character-probe.mjs — the BEFORE/AFTER measurement for m23-fk.
//
// ⚠️ A PROBE, NOT A GATE (the `_` prefix, same as `_m23fi-onkeypress-census.mjs`).
// It prints a table and always exits 0 unless the INSTRUMENT itself is broken.
// The verdicts are read by a human; a "before" run and an "after" run of the
// SAME file are what make the fix's effect visible.
//
// ═══ WHAT IT MEASURES ═══
// m23-fi measured that `KeyEquivalent.delete` is 0x08 while `NSEvent.characters`
// for `kVK_Delete` is 0x7F, so `.onKeyPress(.delete)` can never fire for ⌫.
// m23-fk respells the three mounts. Every leg below exists because re-arming
// three claimants can only be read as safe if the states where the m23-cf-3
// NSEvent monitor RETURNS the event (rather than swallowing it) are measured,
// not reasoned about. `DeleteKeyMonitorRouting.decide` returns the event for:
//   otherKey · chord · keyRepeat · textEditing · secondaryWindow
// ...and `handleKeyDownEvent` ALSO returns it when the monitor was eligible but
// `handleDeleteKey()` answered false ("nobody owned it") — which is the path the
// Mix console's master lane depends on.
//
// ⭐⭐ WHAT THIS PROBE FOUND THAT THE ITEM DID NOT ANTICIPATE (2026-08-10), and
// it is why the shipped mounts carry `phases: [.down]`. With the argument
// OMITTED — SwiftUI's documented default for this overload — the mounts receive
// presses whose `KeyPress.phase` reads `.repeat` (read out of SwiftUI inside the
// closure). The monitor refuses an auto-repeat and RETURNS the event, so L16's
// sequence measured: key-down → notes 3→0 (monitor owned it, swallowed), FIRST
// AUTO-REPEAT → mount fired, selection now empty, routing said `.arrangeClips`,
// CLIP GONE. A held ⌫ destroyed the clip being edited. With `phases: [.down]`:
// funnel +0 on every repeat, clip alive. KEEP L14/L16 — they are the only thing
// in the tree that can see it.
//
// ⚠️ TWO INSTRUMENTS, NEVER CROSSED. `deleteKeyFunnelSeq` sees the arrange and
// roll mounts (both route into `handleDeleteKey`). It is BLIND to the mixer
// lane mount by construction: `onDeleteKey == nil` there, so that closure calls
// `deleteSelection()` and never enters the funnel. The lane mounts are measured
// with `KeyPressProbe.automationLaneDelete` instead.
//
// Staging (17695) only. Never 17600.
import {
  buildOrAbort, startStaging, stopStaging, STAGING_PORT, sleep, panelDensityGuard,
} from "./_staging.mjs";

const GATE = "m23fkprobe";
const PORT = STAGING_PORT;
const OUT = "/tmp/m23fkprobe";
const PIDFILE = "/tmp/m23fkprobe-staging.pid";
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

buildOrAbort({ label: "building staging binary (m23-fk delete-character probe)…" });
const { pid } = startStaging({
  gate: GATE, port: PORT, pidfile: PIDFILE, outDir: OUT,
  detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${pid} on :${PORT}`);
await sleep(4500);
const { ws, req } = await connect();

let exitCode = 0;
const rows = [];
const row = (id, what, measured) => { rows.push({ id, what, measured }); };
// m23-en: `debug.panelDensity` writes are a LEAK CLASS. Snapshot/restore.
const density = panelDensityGuard((c, p) => req(c, p));

try {
  const sel = (p = {}) => req("debug.arrangeSelection", p);
  const ks = (p = {}) => req("debug.keySpace", p);
  const probe = async () => (await sel({})).keyPressProbe;
  const hex = (n) => `0x${Number(n).toString(16).toUpperCase().padStart(2, "0")}`;

  // How many clips exist anywhere in the project — the DELETION COUNT.
  const clipCount = async () => {
    const tracks = (await req("project.snapshot", {})).tracks ?? [];
    return tracks.reduce((n, t) => n + (t.clips ?? []).length, 0);
  };

  // ── FIXTURE ───────────────────────────────────────────────────────────────
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  const trackA = (await req("track.add", { kind: "instrument", name: "A" })).id;
  const mkClip = async () => (await req("clip.addMIDI", {
    trackId: trackA, atBeat: 4, lengthBeats: 8,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  let clipId = await mkClip();
  const markerId = (await req("marker.add", { beat: 16, name: "RenameMe" })).id;
  await sleep(300);

  const armArrange = async () => {
    let id = clipId;
    const tracks = (await req("project.snapshot", {})).tracks ?? [];
    const alive = tracks.flatMap((t) => (t.clips ?? []).map((c) => c.id));
    if (!alive.includes(id)) { id = await mkClip(); clipId = id; }
    await req("ui.showMixer", { show: false });
    await sel({ act: "click", clipId: id });
    await sel({ act: "pianoRollNotes", select: false });
    await sleep(400);
    return id;
  };

  // ── L0 — the instrument is live (positive control) ────────────────────────
  {
    const amb = await ks({});
    const a = await probe();
    await sel({ act: "probeSelfTest" });
    const b = await probe();
    const keys = ["arrangeHorizontalArrow", "arrangeVerticalArrow",
      "automationLaneDelete", "markerRenameEscape", "trackRenameEscape"];
    const moved = keys.filter((k) => b[k] === a[k] + 1);
    const ke = b.keyEquivalentScalars;
    console.log("\n════ L0 — INSTRUMENT + AMBIENT ════");
    console.log(`   appActive=${amb.appActive} windowRole=${amb.windowRole} `
      + `monitorInstalled=${amb.monitorInstalled} fullKeyboardAccess=${amb.fullKeyboardAccess}`);
    console.log(`   probeSelfTest moved ${moved.length}/5 counters by exactly 1`);
    console.log(`   SwiftUI constants: .delete=${hex(ke.delete)} .deleteForward=${hex(ke.deleteForward)}`
      + ` .rightArrow=${hex(ke.rightArrow)} .escape=${hex(ke.escape)}`);
    row("L0", "probe counters live / SwiftUI constants",
      `${moved.length}/5 moved; .delete=${hex(ke.delete)} .deleteForward=${hex(ke.deleteForward)}`);
    if (moved.length !== 5) {
      console.log("INSTRUMENT BROKEN — a zero below cannot be read as 'the key never arrived'.");
      exitCode = 2;
    }
    // the event queue itself, via the SPACE monitor (m23-fi's C2 control)
    const t0 = await ks({});
    await ks({ press: true, post: true });
    await sleep(SETTLE);
    const t1 = await ks({});
    if (t1.isPlaying) await req("transport.stop");
    console.log(`   NSApp.postEvent delivers (SPACE): isPlaying ${t0.isPlaying} -> ${t1.isPlaying}`);
    row("L0b", "NSApp.postEvent delivers (SPACE control)", `${t0.isPlaying} -> ${t1.isPlaying}`);
    if (t0.isPlaying === t1.isPlaying) {
      console.log("INSTRUMENT BROKEN — the queue is dead; nothing below says anything.");
      exitCode = 3;
    }
  }

  // ── L1 — WHAT THE REAL KEYS SEND (the whole premise) ─────────────────────
  {
    console.log("\n════ L1 — AUTHENTIC HID→NSEvent TRANSLATION (system, not our literals) ════");
    const table = [];
    for (const [name, code] of [["kVK_Delete(51)", 51], ["kVK_ForwardDelete(117)", 117],
      ["kVK_RightArrow(124)", 124]]) {
      const e = await sel({ act: "postKey", key: "delete", keyCode: code, authentic: true });
      table.push(`${name} -> ${e.authenticCharactersHex}`);
      console.log(`   ${name.padEnd(24)} NSEvent.characters = ${e.authenticCharactersHex}`);
      await sleep(250);
    }
    row("L1", "authentic NSEvent characters", table.join(" | "));
  }

  // ── L2 — BARE ⌫, ARRANGE, ONE CLIP SELECTED: the no-double-fire count ─────
  {
    await armArrange();
    const c0 = await clipCount();
    const s0 = await sel({});
    const p0 = await probe();
    await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true });
    await sleep(SETTLE);
    const c1 = await clipCount();
    const s1 = await sel({});
    const p1 = await probe();
    console.log("\n════ L2 — ⭐ NO-DOUBLE-FIRE: bare authentic ⌫, arrange, 1 clip selected ════");
    console.log(`   clips           ${c0} -> ${c1}   (DELETIONS = ${c0 - c1})`);
    console.log(`   funnel          ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   (+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq})`);
    console.log(`   monitor         ${s0.deleteKeyMonitorSeq} -> ${s1.deleteKeyMonitorSeq}`
      + `   refusedBy=${s1.deleteKeyMonitorRefusedBy}`);
    console.log(`   automationLaneDelete ${p0.automationLaneDelete} -> ${p1.automationLaneDelete}`);
    row("L2", "bare ⌫ arrange, 1 clip selected",
      `deletions=${c0 - c1} funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq} `
      + `monitor+${s1.deleteKeyMonitorSeq - s0.deleteKeyMonitorSeq}(${s1.deleteKeyMonitorRefusedBy})`);
  }

  // ── L3 — ⇧⌫ CHORD: the monitor REFUSES and returns the event ─────────────
  {
    await armArrange();
    const c0 = await clipCount();
    const s0 = await sel({});
    await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true, shift: true });
    await sleep(SETTLE);
    const c1 = await clipCount();
    const s1 = await sel({});
    console.log("\n════ L3 — ⇧⌫ (monitor refuses .chord and RETURNS the event) ════");
    console.log(`   clips   ${c0} -> ${c1}   (DELETIONS = ${c0 - c1})`);
    console.log(`   funnel  ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   monitor refusedBy=${s1.deleteKeyMonitorRefusedBy}`);
    row("L3", "⇧⌫ arrange, 1 clip selected",
      `deletions=${c0 - c1} funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq} `
      + `refusedBy=${s1.deleteKeyMonitorRefusedBy}`);
  }

  // ── L4 — ⌥⌫ CHORD (the "land grab" the monitor names by name) ────────────
  {
    await armArrange();
    const c0 = await clipCount();
    const s0 = await sel({});
    await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true, option: true });
    await sleep(SETTLE);
    const c1 = await clipCount();
    const s1 = await sel({});
    console.log("\n════ L4 — ⌥⌫ (\"delete word left\" everywhere else in macOS) ════");
    console.log(`   clips   ${c0} -> ${c1}   (DELETIONS = ${c0 - c1})`);
    console.log(`   funnel  ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`);
    row("L4", "⌥⌫ arrange, 1 clip selected",
      `deletions=${c0 - c1} funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq}`);
  }

  // ── L5 — MOUNT-ONLY ROUTE: 0x7F on a key code the monitor does not own ────
  // The monitor keys on `keyCode` (51/117); SwiftUI matches on CHARACTERS. An
  // event carrying keyCode 0 with characters 0x7F is therefore refused by the
  // monitor (`.otherKey`, which falls through to the transport branch and
  // returns the event) and offered to SwiftUI intact — the ONE reading of the
  // three mounts that no monitor can confound.
  {
    await armArrange();
    const c0 = await clipCount();
    const s0 = await sel({});
    await sel({ act: "postKey", key: "delete", keyCode: 0, charCode: 127 });
    await sleep(SETTLE);
    const c1 = await clipCount();
    const s1 = await sel({});
    console.log("\n════ L5 — ⭐ MOUNT-ONLY: characters=0x7F, keyCode=0 (monitor blind) ════");
    console.log(`   funnel  ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   <- a SwiftUI mount fired = ${s1.deleteKeyFunnelSeq !== s0.deleteKeyFunnelSeq}`);
    console.log(`   monitor ${s0.deleteKeyMonitorSeq} -> ${s1.deleteKeyMonitorSeq} (must NOT move)`);
    console.log(`   clips   ${c0} -> ${c1}   (DELETIONS = ${c0 - c1})`);
    row("L5", "0x7F with keyCode 0 (mount-only)",
      `funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq} `
      + `monitor+${s1.deleteKeyMonitorSeq - s0.deleteKeyMonitorSeq} deletions=${c0 - c1}`);
  }

  // ── L6 — 0x08 on keyCode 0: what `.onKeyPress(.delete)` ACTUALLY matches ──
  {
    await armArrange();
    const c0 = await clipCount();
    const s0 = await sel({});
    await sel({ act: "postKey", key: "delete", keyCode: 0, charCode: 8 });
    await sleep(SETTLE);
    const c1 = await clipCount();
    const s1 = await sel({});
    console.log("\n════ L6 — CONTROL: characters=0x08 (KeyEquivalent.delete), keyCode=0 ════");
    console.log(`   funnel  ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   <- a SwiftUI mount fired = ${s1.deleteKeyFunnelSeq !== s0.deleteKeyFunnelSeq}`);
    console.log(`   clips   ${c0} -> ${c1}   (DELETIONS = ${c0 - c1})`);
    row("L6", "0x08 with keyCode 0 (the old spelling's character)",
      `funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq} deletions=${c0 - c1}`);
  }

  // ── L7 — NOTHING OWNS IT: monitor eligible, handleDeleteKey false ────────
  // `handleKeyDownEvent` returns the event when `handleDeleteKey()` is false, so
  // the mounts DO see this one. Two funnel runs with zero deletions is the
  // CORRECT outcome, not a double-fire.
  {
    await armArrange();
    await sel({ act: "clear" });
    await sleep(300);
    const c0 = await clipCount();
    const s0 = await sel({});
    await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true });
    await sleep(SETTLE);
    const c1 = await clipCount();
    const s1 = await sel({});
    console.log("\n════ L7 — NOBODY OWNS IT: arrange, EMPTY selection, bare ⌫ ════");
    console.log(`   funnel  ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   (+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq})`);
    console.log(`   clips   ${c0} -> ${c1}   (DELETIONS = ${c0 - c1} — must be 0)`);
    row("L7", "bare ⌫ arrange, EMPTY selection",
      `funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq} deletions=${c0 - c1}`);
  }

  // ── L8 — TEXT EDITING: a ⌫ typed into a rename field must not delete clips ─
  {
    const id = await armArrange();
    await req("debug.markerRename", { markerId: markerId });
    await sleep(400);
    const before = await sel({});
    const ks0 = await ks({});
    const c0 = await clipCount();
    await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true });
    await sleep(SETTLE);
    const c1 = await clipCount();
    const s1 = await sel({});
    const ks1 = await ks({});
    console.log("\n════ L8 — m17-d: ⌫ while a RENAME FIELD is focused ════");
    console.log(`   textEditing=${before.textEditing} selectedClips=${before.count} `
      + `firstResponder=${ks0.firstResponder}`);
    console.log(`   fieldText  "${ks0.fieldText}" -> "${ks1.fieldText}"`);
    console.log(`   clips      ${c0} -> ${c1}   (DELETIONS = ${c0 - c1} — must be 0)`);
    console.log(`   funnel     ${before.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`);
    row("L8", "⌫ with rename field focused",
      `textEditing=${before.textEditing} clips-deleted=${c0 - c1} `
      + `fieldText "${ks0.fieldText}"->"${ks1.fieldText}"`);
    await req("debug.markerRename", { cancel: true }).catch(() => {});
    await sleep(300);
    void id;
  }

  // ── L9 — ⭐⭐ THE PRIZE: the MIX console master-automation lane ───────────
  {
    // ⚠️ THE MOUNT IS DENSITY-GATED. `MixerStripView.masterBody` wraps
    // `MasterAutomationSection` in `if isPro`, so in Simple density the lane
    // editor is NOT IN THE TREE AT ALL — and an absent mount produces exactly
    // the same zero as a mounted-but-unfocused one. Force Pro, then WITNESS the
    // mount through `debug.explainFrames` so the zero below can only mean
    // "mounted and not focused".
    await req("ui.showMixer", { show: true });
    await density.set("mixer", "pro");
    await sleep(600);
    const lane = (await req("automation.addLane", {
      trackId: "master", target: { type: "volume" },
    })).lane;
    await req("automation.setPoints", {
      trackId: "master", laneId: lane.id,
      points: [{ beat: 0, value: 1.0 }, { beat: 8, value: 0.5 }, { beat: 16, value: 1.0 }],
    });
    await sleep(800);
    const lanePoints = async () => {
      const snap = await req("project.snapshot", {});
      const lanes = snap.masterAutomation ?? snap.project?.masterAutomation
        ?? snap.masterAutomationLanes ?? [];
      const l = lanes.find((x) => x.id === lane.id);
      if (!l) {
        console.log(`   (lane not found in project.snapshot; top-level keys: ${Object.keys(snap)})`);
        return null;
      }
      return l.points.length;
    };
    // MOUNT WITNESS — frames flow only while explain mode is on, so it is
    // turned on for the read and straight back off before any key is posted.
    await req("debug.explainMode", { on: true });
    await sleep(500);
    const frames = (await req("debug.explainFrames", { ids: ["masterAutomation"] })).frames;
    const mounted = (frames?.masterAutomation ?? []).length;
    await req("debug.explainMode", { on: false });
    await sleep(400);
    const n0 = await lanePoints();
    const s0 = await sel({});
    const p0 = await probe();
    await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true });
    await sleep(SETTLE);
    const n1 = await lanePoints();
    const s1 = await sel({});
    const p1 = await probe();
    console.log("\n════ L9 — ⭐⭐ MIX CONSOLE master-automation lane, bare authentic ⌫ ════");
    console.log(`   workspaceMode        ${s0.workspaceMode}`);
    console.log(`   masterAutomation frames ${mounted}   <- MOUNT WITNESS (0 = not in the tree)`);
    console.log(`   lanes FOCUSED        ${p0.automationLanesFocusedCount}`
      + "   <- `.onKeyPress` needs focus; 0 means the mount cannot be reached at all");
    console.log(`   automationLaneDelete ${p0.automationLaneDelete} -> ${p1.automationLaneDelete}`
      + `   <- the mixer mount's closure RAN = ${p1.automationLaneDelete !== p0.automationLaneDelete}`);
    console.log(`   master lane points   ${n0} -> ${n1}`);
    console.log(`   funnel               ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   monitor refusedBy=${s1.deleteKeyMonitorRefusedBy}`);
    row("L9", "MIX console, bare ⌫ (the prize)",
      `workspace=${s0.workspaceMode} mounted=${mounted} `
      + `lanesFocused=${p0.automationLanesFocusedCount} `
      + `laneDelete+${p1.automationLaneDelete - p0.automationLaneDelete} points ${n0}->${n1}`);
  }

  // ── L10 — ⭐ IS THE MIXER MOUNT REACHABLE AT ALL? (the focus question) ────
  // Posted with the character the CURRENT spelling matches (0x08) on a key code
  // the monitor does not own. If `automationLaneDelete` moves here on the
  // UNFIXED tree, the mixer mount is focus-REACHABLE and only the character is
  // wrong — i.e. m23-fk's respelling is sufficient for the prize. If it does
  // not move, the mount is ALSO focus-dead in this (headless, never-clicked)
  // state and the character fix alone cannot be claimed to deliver it.
  {
    await req("ui.showMixer", { show: true });
    await sleep(600);
    const p0 = await probe();
    await sel({ act: "postKey", key: "delete", keyCode: 0, charCode: 8 });
    await sleep(SETTLE);
    const p1 = await probe();
    console.log("\n════ L10 — MIX console, 0x08 on keyCode 0 (mount reachability) ════");
    console.log(`   lanes FOCUSED        ${p0.automationLanesFocusedCount}`);
    console.log(`   automationLaneDelete ${p0.automationLaneDelete} -> ${p1.automationLaneDelete}`
      + `   <- mount REACHABLE = ${p1.automationLaneDelete !== p0.automationLaneDelete}`);
    row("L10", "MIX console, 0x08/keyCode 0 (reachability)",
      `lanesFocused=${p0.automationLanesFocusedCount} `
      + `laneDelete+${p1.automationLaneDelete - p0.automationLaneDelete}`);
  }

  // ── L11 — `deleteSelection()` REALLY REMOVES A BREAKPOINT ────────────────
  // The ARRANGE lane mount, armed through the `pointSelection` bridge (the only
  // mount anything outside can arm) and driven by a bare ⌫ through the monitor.
  // This is the SAME `deleteSelection()` the mixer mount's `??` branch calls.
  {
    await req("ui.showMixer", { show: false });
    const laneA = (await req("automation.addLane", {
      trackId: trackA, target: { type: "volume" },
    })).lane.id;
    await req("automation.setPoints", {
      trackId: trackA, laneId: laneA,
      points: [{ beat: 0, value: 0.5 }, { beat: 4, value: 0.8 }, { beat: 8, value: 0.6 }],
    });
    await req("ui.showAutomation", { trackId: trackA });
    await sleep(700);
    const id = await armArrange();
    const trackPoints = async () => {
      const tracks = (await req("project.snapshot", {})).tracks ?? [];
      const t = tracks.find((x) => x.id === trackA);
      const l = (t?.automation ?? []).find((x) => x.id === laneA);
      return l ? l.points.length : null;
    };
    await sel({ act: "automationPoints", select: true });
    await sleep(300);
    const n0 = await trackPoints();
    const e0 = await sel({});
    const p0 = await probe();
    await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true });
    await sleep(SETTLE);
    const n1 = await trackPoints();
    const p1 = await probe();
    console.log("\n════ L11 — `deleteSelection()` removes a breakpoint (arrange lane, armed) ════");
    console.log(`   lanes claiming       ${e0.automationPointLaneCount}  (fixture armed)`);
    console.log(`   lane points          ${n0} -> ${n1}   (REMOVED = ${n0 - n1})`);
    console.log(`   automationLaneDelete ${p0.automationLaneDelete} -> ${p1.automationLaneDelete}`
      + "   (routed branch — the MOUNT need not have fired)");
    row("L11", "deleteSelection() removes a breakpoint",
      `armed=${e0.automationPointLaneCount} points ${n0}->${n1} `
      + `laneDelete+${p1.automationLaneDelete - p0.automationLaneDelete}`);
    void id;
  }

  // ── L12 — THE PIANO ROLL MOUNT (the one view that focuses ITSELF) ────────
  // `PianoRollView` does `.onAppear { isFocused = true }`, so unlike the lane
  // editors it is genuinely focused headlessly. 0x08 is the CONTROL (the
  // character the unfixed spelling matches); 0x7F is the fix's target. Both on
  // key code 0, so the monitor is blind to each.
  {
    const noteCount = async (id) => {
      const tracks = (await req("project.snapshot", {})).tracks ?? [];
      for (const t of tracks) {
        const c = (t.clips ?? []).find((x) => x.id === id);
        if (c) return (c.notes ?? []).length;
      }
      return null;
    };
    const armRoll = async () => {
      const id = (await req("clip.addMIDI", {
        trackId: trackA, atBeat: 32, lengthBeats: 8,
        notes: [0, 1, 2].map((i) => ({
          pitch: 60 + i, startBeat: i, lengthBeats: 1, velocity: 100,
        })),
      })).id;
      await sel({ act: "click", clipId: id });
      await sleep(500);
      await sel({ act: "pianoRollNotes", select: true });
      await sleep(300);
      return id;
    };
    const legs = [];
    console.log("\n════ L12 — PIANO ROLL mount, note selection armed ════");
    for (const [label, charCode] of [["0x08 (control)", 8], ["0x7F (the fix)", 127]]) {
      const id = await armRoll();
      const n0 = await noteCount(id);
      const s0 = await sel({});
      await sel({ act: "postKey", key: "delete", keyCode: 0, charCode });
      await sleep(SETTLE);
      const n1 = await noteCount(id);
      const s1 = await sel({});
      legs.push(`${label}: notes ${n0}->${n1} funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq}`);
      console.log(`   ${label.padEnd(16)} notes ${n0} -> ${n1}`
        + `   funnel +${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq}`);
    }
    row("L12", "piano roll mount (0x08 control vs 0x7F)", legs.join(" | "));
  }

  // ── L13 — DOES `.onKeyPress` MATCH UNDER A CHORD AT ALL? ─────────────────
  // Asked with 0x08, the character BOTH the old and the new spelling match, so
  // the answer is a property of SwiftUI's matching and not of this item's edit.
  // It decides whether "⇧⌫/⌥⌫ now delete" is something m23-fk INTRODUCED or
  // something the old spelling would have done the moment the character was right.
  {
    await armArrange();
    const c0 = await clipCount();
    const s0 = await sel({});
    await sel({ act: "postKey", key: "delete", keyCode: 0, charCode: 8, shift: true });
    await sleep(SETTLE);
    const c1 = await clipCount();
    const s1 = await sel({});
    console.log("\n════ L13 — ⇧ + 0x08 on keyCode 0: does SwiftUI match under a chord? ════");
    console.log(`   funnel  ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   <- mount matched WITH ⇧ held = ${s1.deleteKeyFunnelSeq !== s0.deleteKeyFunnelSeq}`);
    console.log(`   clips   ${c0} -> ${c1}   (DELETIONS = ${c0 - c1})`);
    row("L13", "⇧ + 0x08 keyCode 0 (chord matching)",
      `funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq} deletions=${c0 - c1}`);
  }

  // ── L14 — ⭐⭐ HELD ⌫ (AUTO-REPEAT): the destructive pass-through ─────────
  // `DeleteKeyMonitorRouting` refuses `.keyRepeat` and RETURNS the event, so
  // re-armed mounts see auto-repeats for the first time. The monitor's own doc
  // names the stake: the first press empties the roll's note selection, so the
  // NEXT press routes to `.arrangeClips` and deletes the clip being edited.
  // SwiftUI's `phases:` defaults to `.down` and a repeat is `.repeat` — this
  // leg is what makes that a measurement instead of an assumption.
  {
    const id = (await req("clip.addMIDI", {
      trackId: trackA, atBeat: 48, lengthBeats: 8,
      notes: [0, 1, 2].map((i) => ({
        pitch: 64 + i, startBeat: i, lengthBeats: 1, velocity: 100,
      })),
    })).id;
    await sel({ act: "click", clipId: id });
    await sleep(500);
    await sel({ act: "pianoRollNotes", select: true });
    await sleep(300);
    const noteCount = async () => {
      const tracks = (await req("project.snapshot", {})).tracks ?? [];
      for (const t of tracks) {
        const c = (t.clips ?? []).find((x) => x.id === id);
        if (c) return (c.notes ?? []).length;
      }
      return null;   // the clip itself is gone — the destructive outcome
    };
    const n0 = await noteCount();
    const c0 = await clipCount();
    const s0 = await sel({});
    await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true, isRepeat: true });
    await sleep(SETTLE);
    const n1 = await noteCount();
    const c1 = await clipCount();
    const s1 = await sel({});
    console.log("\n════ L14 — HELD ⌫ (isARepeat=true), roll open with 3 notes selected ════");
    console.log(`   monitor  ${s0.deleteKeyMonitorSeq} -> ${s1.deleteKeyMonitorSeq}`
      + `   refusedBy=${s1.deleteKeyMonitorRefusedBy}  (must be "key-repeat")`);
    console.log(`   funnel   ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   (must be +0 — a mount firing here is the regression)`);
    console.log(`   notes    ${n0} -> ${n1}      clips ${c0} -> ${c1}`);
    row("L14", "HELD ⌫ auto-repeat (roll armed)",
      `refusedBy=${s1.deleteKeyMonitorRefusedBy} `
      + `funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq} notes ${n0}->${n1} `
      + `clips ${c0}->${c1}`);
  }

  // ── L15 — ⌘⌫ ("move to trash" on macOS — the chord a user would notice) ──
  {
    await armArrange();
    const c0 = await clipCount();
    const s0 = await sel({});
    await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true, command: true });
    await sleep(SETTLE);
    const c1 = await clipCount();
    const s1 = await sel({});
    console.log("\n════ L15 — ⌘⌫ (macOS \"move to trash\") ════");
    console.log(`   clips   ${c0} -> ${c1}   (DELETIONS = ${c0 - c1})`);
    console.log(`   funnel  ${s0.deleteKeyFunnelSeq} -> ${s1.deleteKeyFunnelSeq}`
      + `   monitor refusedBy=${s1.deleteKeyMonitorRefusedBy}`);
    row("L15", "⌘⌫ arrange, 1 clip selected",
      `deletions=${c0 - c1} funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq} `
      + `refusedBy=${s1.deleteKeyMonitorRefusedBy}`);
  }

  // ── L16 — ⭐⭐⭐ THE REAL HOLD: down, then repeat, then repeat ────────────
  // L14 posted a LONE repeat event, which cannot distinguish two mechanisms:
  // SwiftUI ignoring `NSEvent.isARepeat` outright, versus SwiftUI deriving the
  // `.repeat` phase from its own key-state tracking (in which case a repeat with
  // no preceding down looks like a fresh `.down` to it). The difference decides
  // whether L14 is a synthesis artifact or the user's actual hold. So: send the
  // SEQUENCE a held key really produces. Note the trap this leg exists to see —
  // the monitor SWALLOWS the first press, so SwiftUI never sees the initial
  // key-down and any state-based repeat tracking starts from nothing.
  {
    const id = (await req("clip.addMIDI", {
      trackId: trackA, atBeat: 64, lengthBeats: 8,
      notes: [0, 1, 2].map((i) => ({
        pitch: 67 + i, startBeat: i, lengthBeats: 1, velocity: 100,
      })),
    })).id;
    await sel({ act: "click", clipId: id });
    await sleep(500);
    await sel({ act: "pianoRollNotes", select: true });
    await sleep(300);
    const alive = async () => {
      const tracks = (await req("project.snapshot", {})).tracks ?? [];
      for (const t of tracks) {
        const c = (t.clips ?? []).find((x) => x.id === id);
        if (c) return (c.notes ?? []).length;
      }
      return "CLIP GONE";
    };
    console.log("\n════ L16 — A REAL HOLD: keyDown, then auto-repeat, then auto-repeat ════");
    console.log(`   start                notes=${await alive()}`);
    const steps = [
      ["1 keyDown  (isARepeat=false)", false],
      ["2 REPEAT   (isARepeat=true) ", true],
      ["3 REPEAT   (isARepeat=true) ", true],
    ];
    const trail = [];
    for (const [label, isRepeat] of steps) {
      const s0 = await sel({});
      await sel({ act: "postKey", key: "delete", keyCode: 51, authentic: true, isRepeat });
      await sleep(SETTLE);
      const s1 = await sel({});
      const state = await alive();
      console.log(`   ${label}  funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq}`
        + `  refusedBy=${String(s1.deleteKeyMonitorRefusedBy).padEnd(10)} -> ${state}`);
      trail.push(`${label.trim()}: funnel+${s1.deleteKeyFunnelSeq - s0.deleteKeyFunnelSeq} `
        + `${s1.deleteKeyMonitorRefusedBy} -> ${state}`);
    }
    row("L16", "held ⌫ SEQUENCE (down, repeat, repeat)", trail.join(" | "));
  }

  console.log("\n════════ SUMMARY ════════");
  for (const r of rows) console.log(`   ${r.id.padEnd(4)} ${r.what.padEnd(46)} ${r.measured}`);
} catch (err) {
  console.log(`PROBE ERROR: ${err.message}`);
  exitCode = 4;
} finally {
  try { await density.restore("m23-fk probe teardown"); }
  catch (e) { console.log(`density restore: ${e.message}`); }
  try { ws.close(); } catch {}
  // POSITIONAL, not an options object (m23-ah-1: `stopStaging({...})` silently
  // tore nothing down until `_staging.mjs` started throwing on it).
  stopStaging(GATE, PIDFILE);
}
process.exit(exitCode);
