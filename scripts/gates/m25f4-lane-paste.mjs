// m25-f-4 GATE — RIGHT-CLICK ▸ PASTE ON EMPTY LANE SPACE, against a REAL app on
// staging (port 17695 ONLY; 17600 is the user's LIVE app and is never touched.
// Staging is killed PIDFILE-EXACT, never pkill/pgrep).
//
// ═══ WHAT THIS PROVES ═══
//
//   The COMPOSITION the empty-lane right-click rides, end to end through the
//   real `AppModel`: that a destination TRACK named by the gesture and an ANCHOR
//   BEAT named by the gesture are BOTH honoured, on an ordinary copy whose
//   source track is still live. That is the exact configuration the item was
//   blocked on: before m25-l-3 a live-source paste was always `.inPlace` and the
//   named track was DISCARDED, so the menu would have pasted into a lane other
//   than the one it was opened on — and the menu's POSITION is itself a promise.
//
//   It also proves the two side effects that must NOT happen (the playhead does
//   not move, the stored active-track cursor does not move), and that a payload
//   the destination lane cannot hold is refused BY NAME rather than silently.
//
// ═══ WHAT IT DOES NOT PROVE — stated plainly, because a green run looks like
//     proof ═══
//
//     • THE RIGHT-CLICK ITSELF. Nothing in this tree can right-click, and
//       `.contextMenu` builders are not reachable from the wire (the m23-ek-3
//       gate's own skip, verbatim). Every leg below drives the SAME
//       `pasteClipsFromClipboardDetailed(intoTrack:atBeat:)` the menu's Button
//       calls — that is what the `edit.pasteClips` seam is FOR — but the last
//       inch from a right-click to that method is UNPROVEN HERE and needs hands.
//     • THE MENU ITEM'S TITLE / GREYED STATE. Decided headlessly by
//       `ClipboardMenuPolicy.laneContextPasteItem` and pinned in
//       `ClipboardMenuPolicyTests`; no wire seam echoes this menu.
//     • WHICH LANE THE POINTER RESOLVES. `ArrangePointer.emptyLaneIndex` is
//       pinned in `ArrangePointerModelTests`, including the playhead-grab trap.
//
// FIXTURE ARITHMETIC, computed BEFORE any assertion was written (FIXTURE LAW):
//   T0 (instrument) holds clip A @ beat 0, len 2 — the copy source.
//   T1, T2 (instrument) are empty. TA (audio) is the wrong-kind destination.
//   PLAYHEAD_BEAT = 8 and LANE_BEAT = 37.5 are DISTINCT, and 37.5 is off every
//   grid the arrange snaps to, so a landing there cannot be produced by any
//   fallback that re-snapped or re-derived the anchor.
//   T2 is DISTINCT from T0, so "landed on the named track" cannot pass by
//   landing at home. Both anti-vacuity facts are asserted, not assumed.
//
// Setup: none — run it.
//
//   node scripts/gates/m25f4-lane-paste.mjs
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, panelDensityGuard, verdict } from "./_staging.mjs";

const GATE = "m25f4lp";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M25F4LP_OUT || "/tmp/m25f4lp";
const PIDFILE = process.env.M25F4LP_PIDFILE || "/tmp/m25f4lp-staging.pid";
const BINARY = process.env.M25F4LP_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M25F4LP_REPO || process.cwd();
fs.mkdirSync(OUT, { recursive: true });

let guard = null;
const killer = setTimeout(async () => {
  console.error("TIMEOUT");
  await guard?.restore("timeout");
  process.exit(2);
}, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SETTLE_MS = 250;

// The fixture's numbers, named once so no assertion can quietly disagree.
const PLAYHEAD_BEAT = 8;
const LANE_BEAT = 37.5;
const WRONG_KIND_BEAT = 50;

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
          setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

buildOrAbort();
const { pid: stagingPid } = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY, pidfile: PIDFILE,
  outDir: OUT, detached: true, logPath: `${OUT}/staging.log`,
});
console.log(`staging pid ${stagingPid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
guard = panelDensityGuard(req);
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };
const near = (a, b, eps = 1e-6) => typeof a === "number" && Math.abs(a - b) < eps;

const cb = (p = {}) => req("debug.editClipboard", p);
const sel = (p = {}) => req("debug.arrangeSelection", p);

try {
  // ══ FIXTURE ══════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  await req("debug.windowFrame", { width: 1400, height: 1000 });
  await guard.set("arrange", "pro");
  await req("debug.panelLayout", { reset: true });
  const t0 = (await req("track.add", { kind: "instrument", name: "LP0" })).id;
  const t1 = (await req("track.add", { kind: "instrument", name: "LP1" })).id;
  const t2 = (await req("track.add", { kind: "instrument", name: "LP2" })).id;
  const ta = (await req("track.add", { kind: "audio", name: "LPAudio" })).id;
  const clipA = (await req("clip.addMIDI", {
    trackId: t0, atBeat: 0, lengthBeats: 2,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, velocity: 100 }],
  })).id;
  await sleep(SETTLE_MS);

  // ══ L1 — copy the clip, the ORDINARY way (source track stays live) ════════
  await sel({ act: "click", clipId: clipA });
  await sleep(SETTLE_MS);
  let e = await cb({ act: "copy" });
  check("L1 an ordinary copy loads the clipboard with one clip",
        e.result === true && e.kind === "clips" && e.clipCount === 1,
        `kind=${e.kind} count=${e.clipCount}`);

  // ══ L2 — the anti-vacuity facts, READ rather than assumed ═════════════════
  await req("transport.seek", { beats: PLAYHEAD_BEAT });
  await sleep(SETTLE_MS);
  e = await cb({});
  const playheadBefore = e.playheadBeat;
  const sourceStart = e.clips.find((c) => c.id === clipA)?.startBeat;
  check("L2 ANTI-VACUITY: the named lane is NOT the source track, and the named "
        + "beat is NEITHER the playhead NOR the source's start",
        t2 !== t0 && near(playheadBefore, PLAYHEAD_BEAT)
        && !near(LANE_BEAT, playheadBefore) && !near(LANE_BEAT, sourceStart),
        `source track=T0 destination=T2 (distinct=${t2 !== t0}); source@${sourceStart}, `
        + `playhead@${playheadBefore}, lane beat ${LANE_BEAT} — so a landing at `
        + `T2/${LANE_BEAT} cannot be produced by anything that ignored the params`);

  // ══ L3 — THE ITEM'S PROMISE: both coordinates honoured ════════════════════
  const r3 = await req("edit.pasteClips", { trackId: t2, atBeat: LANE_BEAT });
  const landing = r3.landings?.[0];
  check("L3 a lane-named TRACK and a pointer-named BEAT are BOTH honoured, on a "
        + "copy whose source track is still live",
        r3.pasted === true && r3.landings?.length === 1
        && landing?.trackId === t2 && near(landing?.startBeat, LANE_BEAT),
        `pasted=${r3.pasted} landing=${JSON.stringify(landing)} (expected track T2 `
        + `@ ${LANE_BEAT}) — this is the leg that was BLOCKED before m25-l-3, when a `
        + `live-source paste was always in-place and the named track was discarded`);

  // ══ L4 — the two side effects that must NOT happen ════════════════════════
  const afterSel = await sel({});
  e = await cb({});
  check("L4a the paste did NOT move the playhead",
        near(e.playheadBeat, playheadBefore),
        `playhead ${playheadBefore} → ${e.playheadBeat}`);
  check("L4b the paste did NOT move the stored active-track cursor",
        afterSel.explicitActiveTrackId === null || afterSel.explicitActiveTrackId === undefined,
        `explicitActiveTrackId=${JSON.stringify(afterSel.explicitActiveTrackId)} — a `
        + `right-click permanently relocating the cursor is a side effect the user `
        + `did not ask for (`
        + `AppModel.explicitActiveTrackID's "exactly three things move it" list)`);

  // ══ L5 — NEGATIVE CONTROL: the same clipboard with NO params ══════════════
  const r5 = await req("edit.pasteClips", {});
  const landing5 = r5.landings?.[0];
  check("L5 NEGATIVE CONTROL: with no params the SAME clipboard lands HOME at the "
        + "PLAYHEAD — so L3's coordinates came from L3's parameters",
        r5.pasted === true && landing5?.trackId === t0
        && near(landing5?.startBeat, playheadBefore),
        `landing=${JSON.stringify(landing5)} (expected track T0 @ ${playheadBefore})`);

  // ══ L6 — the refusal is NAMED, never silent ══════════════════════════════
  const r6 = await req("edit.pasteClips", { trackId: ta, atBeat: WRONG_KIND_BEAT });
  const skipped = r6.skipped?.[0];
  check("L6 a MIDI payload aimed at an AUDIO lane is refused BY NAME — which clip "
        + "and why — never a silent no-op",
        r6.pasted === false && r6.reason === "all-skipped"
        && skipped?.reason === "track-kind-mismatch" && typeof skipped?.clipName === "string"
        && skipped.clipName.length > 0,
        `result=${JSON.stringify(r6)} — this is the same skip the arrange's amber `
        + `refusal bubble renders, which is why the menu item is NOT greyed on kind`);

  // ══ L7 — a negative anchor slides the GROUP, never welds or errors ════════
  const r7 = await req("edit.pasteClips", { trackId: t1, atBeat: -4 });
  const landing7 = r7.landings?.[0];
  check("L7 a NEGATIVE anchor is clamped by the GROUP clamp, not rejected at the wire",
        r7.pasted === true && landing7?.trackId === t1 && near(landing7?.startBeat, 0),
        `landing=${JSON.stringify(landing7)} (expected track T1 @ 0) — `
        + `PasteAnchorPolicy owns max(0, anchor) and is the ONE home for it`);

  // ══ what this gate structurally cannot reach ═════════════════════════════
  skip("the right-click itself, and the menu item's mount",
       "nothing in this tree can right-click, and `.contextMenu` builders are not reachable "
       + "from the wire (the m23-ek-3 gate's own skip). Every leg above drives the SAME "
       + "`pasteClipsFromClipboardDetailed(intoTrack:atBeat:)` the menu's Button calls, so "
       + "the COMPOSITION is proven end to end and only the last inch is not. A HUMAN must "
       + "right-click empty lane space on a lane that is not the source and confirm the clip "
       + "lands there, at that bar.");
  skip("the menu item's TITLE and GREYED state",
       "decided by `ClipboardMenuPolicy.laneContextPasteItem` and pinned in "
       + "`ClipboardMenuPolicyTests`; no wire seam echoes THIS menu (the `debug.editClipboard` "
       + "echo carries the EDIT menu's items, which are a different policy).");
  skip("which lane the pointer resolves",
       "`ArrangePointer.emptyLaneIndex` is pinned in `ArrangePointerModelTests`, including "
       + "the playhead-grab trap that would have lost the target on exactly the spot a "
       + "preceding click had just seeked to.");

  // ══ summary ══════════════════════════════════════════════════════════════
  const bad = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - bad.length}/${checks.length} legs passed`
    + (skips.length ? `, ${skips.length} skipped` : ""));
  for (const s of skips) console.log(`  SKIP ${s.name}: ${s.why}`);
  if (bad.length) { for (const b of bad) console.log(`  FAIL ${b.name}: ${b.detail}`); }
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips }, null, 2));
  clearTimeout(killer);
  // ⚠️ m23-ej-2: guard.restore() round-trips over `req`/`ws` — it MUST run
  // before ws.close(), never after.
  await guard.restore("normal exit");
  ws.close();
  stopStaging(GATE, PIDFILE);
  verdict({ ran: checks.length, failed: bad.length });
} catch (e) {
  console.error("GATE ERROR", e);
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips, error: String(e) }, null, 2));
  clearTimeout(killer);
  await guard?.restore("catch");
  try { ws.close(); } catch {}
  stopStaging(GATE, PIDFILE);
  process.exit(2);
}
