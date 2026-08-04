// m23-am GATE — A REFUSED TRACK-HEADER GROUP DELETE ANCHORS ITS AMBER BUBBLE ON
// A CLIP THAT ACTUALLY REFUSED, against a REAL app on staging (port 17695 ONLY;
// 17600 is the user's LIVE app and is never touched. Staging is killed
// PIDFILE-EXACT, never pkill/pgrep — at start AND at exit).
//
// IT BUILDS AND LAUNCHES ITS OWN BINARY (the m23-x/m23-aj/m23-ak pattern), so
// the thing under test has KNOWN PROVENANCE. A gate that drives whatever
// instance happens to be on the port can pass against code that is minutes or
// days old, and it cannot tell you that it did (m23-ac).
//
// ══ THE ITEM AS FILED WAS WRONG, AND THIS GATE ENCODES THE MEASUREMENT ══════
// m23-am says the user "gets silence" because a header click adopts no focus and
// there is therefore no clip to anchor the bubble to. MEASURED FALSE on a live
// staging binary before any code changed: `deleteArrangeSelection` already fell
// back to `targets.first`, and `targets` is guarded non-empty one line earlier,
// so an anchor ALWAYS existed and the message was present and verbatim.
//
// THE REAL DEFECT — worse than silence, because silence at least does not send
// the user to edit the wrong clip: `targets` is a `Set<UUID>`, so `.first` was an
// ARBITRARY element with no relationship to what refused. With 8 clips on one
// track and the comp member at creation index 4, the refusal anchored on
// creation index 3 — an INNOCENT clip wearing an amber bubble reading "clip
// belongs to take group 'PROBE TAKES'". Set order is also per-process (Swift
// seeds hashing per launch), so it was not even reproducible.
//
// ══ WHAT THIS PROVES ═══════════════════════════════════════════════════════
//   • CONTROL (C): the `take.group` VERB still refuses this fixture on this very
//     tree. Without it, the save/hand-author/open route below reads like an
//     excuse for not using the verb rather than what it is — a measurement that
//     m23-y's "a take group is unbuildable from the wire" was a limit of ONE
//     VERB, not of the wire.
//   • FIXTURE (F): the hand-authored comp members are LIVE — `clip.trim` refuses
//     one with the take-group message, while the SAME verb SUCCEEDS on an
//     innocent clip on the same track. Both halves: a refusal with no control is
//     indistinguishable from a malformed request (the trap the m23-am probe hit,
//     where `startBeat` instead of `newStartBeat` reported exactly like a fixture
//     that failed to take).
//   • PREMISE (P): a header click really does adopt NO focus, and really does
//     select all 8 clips. Both are the item's stated premise; neither is assumed.
//   • THE FIX (A): the refusal anchors on the FIRST comp member in track-then-
//     clip order — not on an innocent clip, and not merely on "some offender".
//   • ALL-OR-NOTHING (N): every clip survives, on BOTH tracks, and the undo
//     journal is untouched. This semantics is deliberate and must not have been
//     traded away to get the anchor right.
//   • VISIBILITY (V): whether the anchored block is actually MOUNTED, which is
//     the question "the bubble is anchored correctly" cannot answer on its own.
//
// ══ WHY TWO COMP MEMBERS, NOT ONE — the leg that makes A non-vacuous ════════
// With exactly ONE comp member in the selection, EVERY implementation names it:
// the throw fires when that id is reached and it is the only id that can throw,
// so iteration order is unobservable. A single-offender fixture proves the
// payload and says nothing about determinism. Two members (creation indices 4
// and 6) let A assert WHICH one, and the pre-fix code names either — or an
// innocent clip entirely, since pre-fix the anchor never consulted the error at
// all.
//
// ══ FIXTURE ARITHMETIC, computed BEFORE any assertion was written ═══════════
//   Track A: 8 MIDI clips at beats 0,4,8,…,28, length 4 -> [0,4) [4,8) … [28,32).
//     Contiguous but NON-OVERLAPPING, so nothing here is reading the overlap
//     resolver's output. `addMIDIClip` APPENDS, so clip index == creation index.
//   Track B: 1 MIDI clip at beat 0. It exists solely to prove the all-or-nothing
//     spill onto a track the user never took near a take group.
//   COMP MEMBERS: creation indices 4 (beat 16) and 6 (beat 24). Index 4 is the
//     expected anchor (lower clip index). Neither is first nor last, so "named
//     the first id" and "named the last id" both fail.
//   9 clips total: an arbitrary `Set.first` has a 1-in-9 chance of coinciding
//     with index 4, so a RED baseline that comes back green on A is a
//     coincidence to be re-rolled with a fresh fixture, NOT evidence.
//
// ══ THE TAKE-GROUP FIXTURE ROUTE ═══════════════════════════════════════════
// `take.group` needs >= 2 OVERLAPPING clips while every clip verb resolves
// overlaps on the way in, so the verb cannot build one from the wire. But
// `ClipDocument` PERSISTS `takeGroupId`, so: project.save -> hand-author a
// `takeGroups` array into the bundle's project.json and tag the clips ->
// project.open. Verified by F below, not assumed.
//
// Setup: none — run it.
//
//   node scripts/gates/m23am-refusal-anchor.mjs
import fs from "fs";
import path from "path";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23am";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23AM_OUT || "/tmp/m23am";
const PIDFILE = process.env.M23AM_PIDFILE || "/tmp/m23am-staging.pid";
const BINARY = process.env.M23AM_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23AM_REPO || process.cwd();
const PROJ = `${OUT}/m23am-fixture.dawproj`;
fs.mkdirSync(OUT, { recursive: true });
fs.rmSync(PROJ, { recursive: true, force: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const N_A = 8;              // clips on track A
const LEN = 4;              // clip length in beats
const OFFENDER_I = 4;       // creation index of the FIRST comp member — the expected anchor
const OFFENDER_J = 6;       // creation index of the SECOND comp member
const GROUP_NAME = "PROBE TAKES";
const MESSAGE = `clip belongs to take group '${GROUP_NAME}' — edit the comp (take.setComp) or take.flatten first`;

// ── build FIRST: a gate that tests the previous binary proves nothing ───────
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
      // `raw` NEVER rejects — it resolves `{__error}` instead, because several
      // legs here are ABOUT a refusal and a throw would abort the gate on its
      // own subject matter.
      const raw = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve) => {
          pending.set(id, { resolve, reject: (e) => resolve({ __error: e.message }), command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); resolve({ __error: `timeout ${command}` }); }
          }, 25000);
        });
      };
      const req = async (c, p) => {
        const r = await raw(c, p);
        if (r && r.__error) throw new Error(r.__error);
        return r;
      };
      return { ws, req, raw };
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

const { ws, req, raw } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };
const short = (s) => (typeof s === "string" ? s.slice(0, 8) : String(s));

const teardown = () => { try { stopStaging(GATE, PIDFILE); } catch {} };
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => { console.error(`${ev}:`, e && e.message); teardown(); process.exit(2); });
}

/** Live clip ids, from the STORE, in the store's own (track, clip index) order. */
async function liveClips() {
  const ov = await req("project.overview", {});
  return (ov.tracks ?? []).flatMap((t) =>
    (t.clips ?? []).map((c) => ({ trackId: t.id, id: c.id, startBeat: c.startBeat })));
}
const depth = async () => (await req("edit.history", {})).undo.length;

try {
  // ══ FIXTURE: ordinary clips ════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  const tA = (await req("track.add", { kind: "instrument", name: "AM-A" })).id;
  const tB = (await req("track.add", { kind: "instrument", name: "AM-B" })).id;
  const aIDs = [];
  for (let i = 0; i < N_A; i++) {
    // ⚠️ `atBeat`, NOT `startBeat` — the standing trap.
    aIDs.push((await req("clip.addMIDI", { trackId: tA, atBeat: i * LEN, lengthBeats: LEN })).id);
  }
  const bID = (await req("clip.addMIDI", { trackId: tB, atBeat: 0, lengthBeats: LEN })).id;
  const offender = aIDs[OFFENDER_I];
  const offender2 = aIDs[OFFENDER_J];
  const innocents = aIDs.filter((_, i) => i !== OFFENDER_I && i !== OFFENDER_J).concat([bID]);
  console.log(`\ntrack A ${short(tA)} clips: ${aIDs.map(short).join(",")}`);
  console.log(`offenders: [${OFFENDER_I}]=${short(offender)}  [${OFFENDER_J}]=${short(offender2)}`);

  // ══ C — CONTROL: the take.group VERB still refuses on THIS tree ════════════
  console.log("\n── C: control (the verb route, so the fixture route is a measurement) ──");
  const viaVerb = await raw("take.group",
    { trackId: tA, clipIds: [aIDs[0], aIDs[1]], name: "verb attempt" });
  check("C1 the take.group VERB refuses these non-overlapping clips",
        !!viaVerb.__error,
        `take.group -> ${JSON.stringify(viaVerb).slice(0, 180)}`);

  // ══ FIXTURE: save -> hand-author a take group -> open ══════════════════════
  await req("project.save", { path: PROJ });
  const walk = (d) => fs.readdirSync(d, { withFileTypes: true })
    .flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]));
  const jsonFile = walk(PROJ).find((f) => f.endsWith(".json"));
  if (!jsonFile) throw new Error("saved bundle has no project.json");
  const doc = JSON.parse(fs.readFileSync(jsonFile, "utf8"));
  const trackA = (doc.tracks ?? []).find((t) => t.id === tA);
  if (!trackA) throw new Error("saved project.json has no track A");

  const groupId = "11111111-2222-3333-4444-555555555555";
  const seed = trackA.clips.find((c) => c.id === offender);
  const laneClip = (id) => ({ ...seed, id });
  trackA.takeGroups = [{
    id: groupId,
    name: GROUP_NAME,
    lanes: [
      { id: "aaaaaaaa-0000-0000-0000-000000000001", name: "Take 1", clip: laneClip("cccccccc-0000-0000-0000-000000000001") },
      { id: "aaaaaaaa-0000-0000-0000-000000000002", name: "Take 2", clip: laneClip("cccccccc-0000-0000-0000-000000000002") },
    ],
  }];
  for (const id of [offender, offender2]) {
    trackA.clips.find((c) => c.id === id).takeGroupId = groupId;
  }
  fs.writeFileSync(jsonFile, JSON.stringify(doc, null, 2));
  const opened = await raw("project.open", { path: PROJ, discardChanges: true });
  if (opened.__error) throw new Error(`project.open failed: ${opened.__error}`);

  // ══ F — the fixture TOOK, with a control that separates "refused because of
  //        the take group" from "refused because the request was malformed" ═══
  console.log("\n── F: the hand-authored comp members are LIVE ──");
  const trimOffender = await raw("clip.trim",
    { trackId: tA, clipId: offender, newStartBeat: 1, newLengthBeats: 2 });
  check("F1 clip.trim on the comp member refuses with the take-group message",
        trimOffender.__error?.includes("belongs to take group") === true
          && trimOffender.__error?.includes(GROUP_NAME) === true,
        `-> ${JSON.stringify(trimOffender).slice(0, 200)}`);
  const trimOffender2 = await raw("clip.trim",
    { trackId: tA, clipId: offender2, newStartBeat: 1, newLengthBeats: 2 });
  check("F2 …and on the SECOND comp member too (two offenders is the fixture)",
        trimOffender2.__error?.includes("belongs to take group") === true,
        `-> ${JSON.stringify(trimOffender2).slice(0, 160)}`);
  // THE CONTROL HALF. Without it F1 cannot tell a live comp member from a
  // malformed request — the exact trap the m23-am probe hit.
  const trimInnocent = await raw("clip.trim",
    { trackId: tA, clipId: aIDs[0], newStartBeat: 0.5, newLengthBeats: 2 });
  check("F3 CONTROL: the SAME verb SUCCEEDS on an innocent clip on the same track",
        !trimInnocent.__error,
        `-> ${JSON.stringify(trimInnocent).slice(0, 160)}`);
  // Put it back so the survivor arithmetic below reads a clean fixture.
  if (!trimInnocent.__error) {
    await raw("clip.trim", { trackId: tA, clipId: aIDs[0], newStartBeat: 0, newLengthBeats: LEN });
  }

  // ══ P — the item's PREMISE, measured rather than assumed ═══════════════════
  console.log("\n── P: a header click selects the track and adopts NO focus ──");
  const clicked = await req("debug.arrangeSelection", { act: "clickTrack", trackId: tA });
  check("P1 the header click selects exactly track A's 8 clips",
        clicked.count === N_A
          && aIDs.every((id) => (clicked.selectedIds ?? []).includes(id)),
        `count=${clicked.count} ids=${(clicked.selectedIds ?? []).length}`);
  check("P2 …and adopts NO focus (the whole reason the anchor had to guess)",
        clicked.focusClipId === null,
        `focusClipId=${JSON.stringify(clicked.focusClipId)}`);

  // ══ A — THE FIX ═══════════════════════════════════════════════════════════
  console.log("\n── A: the refusal anchors on a clip that ACTUALLY refused ──");
  const depthBefore = await depth();
  const before = await liveClips();
  const del = await raw("debug.arrangeSelection", { act: "delete" });
  const ptr = await req("debug.arrangePointer", {});
  const anchor = ptr.refusalClipId;

  check("A1 the refusal message is present and VERBATIM",
        ptr.refusal === MESSAGE,
        `refusal=${JSON.stringify(ptr.refusal)}`);
  check("A2 the bubble is anchored on the FIRST comp member (track, then clip index)",
        anchor === offender,
        `refusalClipId=${short(anchor)} expected=${short(offender)} `
        + `(second member=${short(offender2)})`);
  check("A3 …and NOT on any innocent clip — the measured pre-fix behaviour",
        !!anchor && !innocents.includes(anchor),
        `anchor=${short(anchor)} innocents=[${innocents.map(short).join(",")}]`);
  check("A4 …and NOT merely on 'some offender': the SECOND member is not chosen",
        anchor !== offender2,
        `anchor=${short(anchor)} secondMember=${short(offender2)}`);
  check("A5 the delete reports itself as refused, not as done",
        del.__error ? true : del.deleted === false,
        `delete -> ${JSON.stringify(del).slice(0, 160)}`);

  // ══ N — ALL-OR-NOTHING, which must survive the anchoring change ════════════
  console.log("\n── N: all-or-nothing is unchanged ──");
  const after = await liveClips();
  check("N1 every clip survives — including on the OTHER track",
        after.length === before.length && after.length === N_A + 1
          && after.some((c) => c.id === bID),
        `${before.length} -> ${after.length} clips; trackB clip present=${after.some((c) => c.id === bID)}`);
  check("N2 the undo journal is untouched (no half-done edit hiding in one entry)",
        (await depth()) === depthBefore,
        `depth ${depthBefore} -> ${await depth()}`);

  // ══ V — VISIBILITY: is the anchored block actually on screen? ══════════════
  // The open question the item's gate really asks. `TimelineLanesView` renders
  // the bubble INSIDE the matching `ClipBlock` (`refusalBubble`, :3064-3070), so
  // an unmounted block shows nothing however correct the id is.
  console.log("\n── V: is the anchored block MOUNTED, and is it in the viewport? ──");
  await req("debug.explainMode", { on: true });
  await sleep(400);
  const framesOn = await req("debug.explainFrames", { ids: ["clipBlock"] });
  const rects = framesOn.frames?.clipBlock ?? [];
  check("V0 explain frames are flowing (an empty dict would fake every V leg)",
        framesOn.explainActive === true && rects.length > 0,
        `explainActive=${framesOn.explainActive} rects=${rects.length}`);
  const zoom = await req("debug.arrangeZoom", {});
  const ppb = zoom.ppb;
  // THE ANSWER TO THE ITEM'S OPEN QUESTION, and it needs no per-clip identity:
  // `clipBlocks` is a PLAIN `ForEach` (not Lazy) inside the horizontal
  // ScrollView, so EVERY clip gets a block whatever the scroll position. If the
  // rect count equals the clip count then the anchored block is mounted —
  // whichever clip it is — and the bubble is in the view tree.
  check("V1 every clip block is MOUNTED — one rect per clip, all 9",
        rects.length === N_A + 1,
        `rects=${rects.length} clips=${N_A + 1}`);
  // NON-VACUITY for V1: these really are the clip blocks, not some other
  // control. Every fixture clip is LEN beats long, so every rect must be exactly
  // LEN·ppb wide.
  check("V1b …and they really are the clip blocks (width == LEN·ppb for all 9)",
        rects.length > 0 && rects.every((r) => Math.abs(r.width - LEN * ppb) < 0.5),
        `ppb=${ppb} expected width=${LEN * ppb} widths=[${rects.map((r) => r.width).join(",")}]`);
  // ⚠️ MEASURED LIMIT OF THE SEAM, pinned so no later gate reads rect[i] as
  // clip[i]. `TimelineLanesView` places blocks with `.offset(x:y:)` and hangs
  // `.explainable` OUTSIDE that offset, so what `debug.explainFrames` reports is
  // the LAYOUT frame — identical for every block — not the rendered position.
  // Widths track `ppb` (V1b) while origins do not move at all. So this seam can
  // answer HOW MANY blocks are mounted and NOTHING about where any one of them
  // is drawn; the viewport legs below therefore compute from the app's own
  // reported `ppb`/`hOffset`/`viewportWidth` and the clip's start beat, never
  // from a rect. If this assertion ever fails, the offsets became measurable and
  // V3/V4 can be tightened to name the block.
  check("V2 SEAM LIMIT: every clipBlock rect shares one origin (offsets are not measured)",
        new Set(rects.map((r) => `${r.x},${r.y}`)).size === 1,
        `distinct origins=${new Set(rects.map((r) => `${r.x},${r.y}`)).size} `
        + `sample=${JSON.stringify(rects.slice(0, 3))}`);
  // Viewport arithmetic from the app's OWN reported numbers plus the store's own
  // start beat — the only route left, and the honest one.
  const anchorStart = OFFENDER_I * LEN;
  const screenX = (beat, z) => beat * z.ppb - z.hOffset;
  const inView = (beat, z) => screenX(beat, z) + LEN * z.ppb > 0 && screenX(beat, z) < z.viewportWidth;
  check("V3 at the default zoom the anchored clip lies inside the reported viewport",
        inView(anchorStart, zoom),
        `beat=${anchorStart} ppb=${zoom.ppb} hOffset=${zoom.hOffset} `
        + `screenX=${screenX(anchorStart, zoom)} viewportWidth=${zoom.viewportWidth}`);
  // NOW THE HONEST HALF. Zoom to the top of the ladder: the block stays MOUNTED
  // (so the bubble is still in the view tree and the anchor is still correct)
  // but the clip leaves the viewport. "Anchored correctly" is therefore NOT the
  // same claim as "the user sees it", and the gap is a SCROLL question, not an
  // anchoring one.
  await req("debug.arrangeZoom", { ppb: 400 });   // clamps to the ladder's max
  await sleep(400);
  const zoomed = await req("debug.arrangeZoom", {});
  const framesZoomed = await req("debug.explainFrames", { ids: ["clipBlock"] });
  const zRects = framesZoomed.frames?.clipBlock ?? [];
  check("V4 zoomed in, every block is STILL MOUNTED (non-lazy ForEach)",
        zRects.length === N_A + 1,
        `rects=${zRects.length} at ppb=${zoomed.ppb}`);
  check("V5 …but the anchored clip is now OUTSIDE the viewport — mounted != visible",
        !inView(anchorStart, zoomed),
        `beat=${anchorStart} ppb=${zoomed.ppb} hOffset=${zoomed.hOffset} `
        + `screenX=${screenX(anchorStart, zoomed)} viewportWidth=${zoomed.viewportWidth} `
        + `— if this is false the fixture did not push it off; raise ppb rather than `
        + `reading it as a fix`);
  await req("debug.arrangeZoom", { reset: true });
  await req("debug.explainMode", { on: false });

  // ══ Recorded as SKIP, never as a pass ══════════════════════════════════════
  skip("that a REAL DELETE key (rather than the seam) reaches this handler",
       "m23-g1 MEASURED that an unbundled staging binary does not route real key "
       + "events (`act:\"keyDelete\"` -> delivered:false: the window is not key, so "
       + "nothing reaches SwiftUI's focus arbitration). The seam calls the SAME "
       + "`AppModel.deleteArrangeSelection` the key handler calls — that is the "
       + "documented contract on the method — but the final hop needs a human at a "
       + "real window. m23-x / m23-y / m23-ak record the same hop as a skip.");
  skip("that the amber bubble is legible where it lands",
       "V1-V5 prove the anchored ClipBlock is mounted and measure whether it is "
       + "inside the reported viewport, which is as far as any seam reaches. The "
       + "bubble itself carries no `.explainable` tag, so its own rect cannot be "
       + "read back; and whether a 6-second chip 30 pt above a clip is NOTICED is "
       + "a human judgement no gate can make. AUTO-SCROLLING to a refusal that "
       + "lands off-viewport (V5) is a separate feature, not an anchoring defect.");

  // ══ SUMMARY ════════════════════════════════════════════════════════════════
  const failed = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - failed.length}/${checks.length} assertions passed`
    + `  (${skips.length} skipped)`);
  for (const c of failed) console.log(`  FAILED: ${c.name} — ${c.detail}`);
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips }, null, 2));
  clearTimeout(killer);
  ws.close();
  teardown();
  process.exit(failed.length ? 1 : 0);
} catch (err) {
  console.error("GATE ERROR:", err);
  clearTimeout(killer);
  try { ws.close(); } catch {}
  teardown();
  process.exit(2);
}
