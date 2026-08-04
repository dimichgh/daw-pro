// _m23am — MEASUREMENT INSTRUMENT, not a gate. `_`-prefixed so the corpus
// classifier skips it (a synthetic probe counted as coverage is worse than no
// probe at all).
//
// ⚠️ FROZEN 2026-08-03 — THIS IS A RECORD, NOT A LIVE TOOL. The save ->
// hand-author -> open fixture builder it discovered is now MAINTAINED in
// `m23am-refusal-anchor.mjs`, which is the copy that actually runs. Nothing
// executes this file, so it can rot silently while still reading like a
// working instrument. Kept because it is the measurement record for the
// fixture route (and for the falsified `.first`-anchor story) — if you need
// the fixture, take it from the GATE, and do not "fix" this file to match.
//
// TWO THINGS TO MEASURE, BOTH OF WHICH THE m23-am ITEM ASSERTS WITHOUT PROOF:
//
//  ① IS A TAKE GROUP REALLY UNBUILDABLE FROM THE WIRE? m23-y concluded it is,
//    and skipped its end-to-end leg on that basis. But it only tested the
//    `take.group` VERB, which needs >=2 OVERLAPPING clips while every clip verb
//    resolves overlaps on the way in. `ClipDocument` PERSISTS `takeGroupId`
//    (`ProjectDocument.swift:261/1112`) and the loader says the materialized
//    comp members "already ride in `clips`" — so save -> hand-author -> open
//    may reach the state the verb cannot. If it does, m23-y's skip was a limit
//    of one verb mistaken for a limit of the wire.
//
//  ② DOES THE USER ACTUALLY GET SILENCE? The item says a header click adopts no
//    focus "so there may be no clip to anchor the bubble to and the user gets
//    silence". But `deleteArrangeSelection` (`DAWProApp.swift:855`) already
//    falls back to `targets.first`, and `targets` is guarded NON-EMPTY one line
//    earlier — so an anchor always exists. What `Set.first` returns is
//    ARBITRARY, which is a different defect: the bubble may land on an INNOCENT
//    clip while naming the take group, or on one scrolled out of view.
//
// Reading `refusalClipId` off the `debug.arrangePointer` echo (`:3805`) is what
// separates those two stories. Staging :17695 ONLY.

import fs from "fs";
import path from "path";
import { startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23am-probe";
const PORT = 17695;
const REPO = "/Users/dsemenov/Views/daw-pro";
const OUT = `/tmp/daw-gate-out/${GATE}`;
const PIDFILE = `${OUT}/staging.pid`;
const SCRATCH = "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/299c6f79-aecb-4cf6-b17e-49d08d302e91/scratchpad";
const PROJ = `${SCRATCH}/m23am-fixture.dawproj`;

fs.mkdirSync(OUT, { recursive: true });
fs.rmSync(PROJ, { recursive: true, force: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);

const staging = startStaging({ gate: GATE, root: REPO, port: PORT,
  binary: ".build/debug/DAWApp", detached: true, pidfile: PIDFILE, outDir: OUT });
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4000);

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
      const rawSend = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve) => {
          pending.set(id, { resolve, reject: (e) => resolve({ __error: e.message }), command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => { if (pending.has(id)) { pending.delete(id); resolve({ __error: `timeout ${command}` }); } }, 25000);
        });
      };
      const req = async (c, p) => {
        const r = await rawSend(c, p);
        if (r && r.__error) throw new Error(r.__error);
        return r;
      };
      return { ws, req, raw: rawSend };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}
const { req, raw } = await connect();

for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => {
    console.error(`${ev}:`, e && e.message);
    try { stopStaging(GATE, PIDFILE); } catch {}
    process.exit(2);
  });
}

const say = (s) => console.log(s);

try {
  // ── build an ordinary two-track project ────────────────────────────────────
  await req("project.new", { discardChanges: true });
  const tA = (await req("track.add", { kind: "instrument", name: "AM-A" })).id;
  const tB = (await req("track.add", { kind: "instrument", name: "AM-B" })).id;
  // ⚠️ addMIDI takes `atBeat`, NOT `startBeat` (the standing trap).
  // ⚠️ WIDE ON PURPOSE. With TWO clips, `targets.first` on a Set has a ~50%
  // chance of coincidentally BEING the offender, and a run that got lucky reads
  // exactly like a correct anchor. Eight clips with the offender in the MIDDLE
  // makes coincidence a 1-in-8 story instead of a coin flip.
  const aIDs = [];
  for (let i = 0; i < 8; i++) {
    aIDs.push((await req("clip.addMIDI",
      { trackId: tA, atBeat: i * 4, lengthBeats: 4 })).id);
  }
  const a0 = aIDs[4];              // THE OFFENDER — deliberately not first/last
  const a1 = aIDs[0];
  const b0 = (await req("clip.addMIDI", { trackId: tB, atBeat: 0, lengthBeats: 4 })).id;
  say(`tracks A=${tA.slice(0,8)} B=${tB.slice(0,8)}`);
  say(`track A clips (creation order): ${JSON.stringify(aIDs.map((s) => s.slice(0,8)))}`);
  say(`OFFENDER (index 4) = ${a0.slice(0,8)}`);

  // ── ① CONTROL: does the take.group VERB refuse, as m23-y measured? ─────────
  const viaVerb = await raw("take.group", { trackId: tA, clipIds: [aIDs[0], aIDs[1]], name: "probe" });
  say(`\n① CONTROL take.group verb -> ${JSON.stringify(viaVerb).slice(0, 200)}`);

  // ── ① THE NEW ROUTE: save, hand-author a take group, reopen ────────────────
  await req("project.save", { path: PROJ });
  const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)]);
  const files = walk(PROJ);
  say(`\nsaved bundle contains ${files.length} file(s):`);
  files.forEach((f) => say(`   ${f.replace(PROJ, "<bundle>")}`));

  const jsonFile = files.find((f) => f.endsWith(".json"));
  const doc = JSON.parse(fs.readFileSync(jsonFile, "utf8"));
  const trackA = (doc.tracks ?? []).find((t) => t.id === tA);
  say(`\ntrack A persisted keys: ${Object.keys(trackA).join(", ")}`);
  say(`clip a0 persisted keys: ${Object.keys(trackA.clips[0]).join(", ")}`);

  // Author the group: a0 becomes a COMP MEMBER of a 2-lane group. The lanes
  // carry ClipDocument payloads; a0 keeps riding in `clips` (the loader's
  // "materialized comp members already ride in clips"), now tagged.
  const groupId = "11111111-2222-3333-4444-555555555555";
  const clipA0 = trackA.clips.find((c) => c.id === a0);
  const laneClip = (id) => ({ ...clipA0, id });
  trackA.takeGroups = [{
    id: groupId,
    name: "PROBE TAKES",
    lanes: [
      { id: "aaaaaaaa-0000-0000-0000-000000000001", name: "Take 1", clip: laneClip("cccccccc-0000-0000-0000-000000000001") },
      { id: "aaaaaaaa-0000-0000-0000-000000000002", name: "Take 2", clip: laneClip("cccccccc-0000-0000-0000-000000000002") },
    ],
  }];
  clipA0.takeGroupId = groupId;
  fs.writeFileSync(jsonFile, JSON.stringify(doc, null, 2));

  const opened = await raw("project.open", { path: PROJ, discardChanges: true });
  say(`\n① project.open after hand-authoring -> ${opened.__error ? "ERROR " + opened.__error : "OK"}`);
  if (opened.warnings) say(`   warnings: ${JSON.stringify(opened.warnings)}`);

  // ── Is a0 REALLY a comp member now? Ask the store, don't assume. ───────────
  // ⚠️ THREE OUTCOMES, NOT TWO. My first version regexed the error text for
  // "take group" and read EVERYTHING else as "not a comp member" — so a
  // malformed request (I had used `startBeat`/`lengthBeats`; the verb wants
  // `newStartBeat`/`newLengthBeats`) reported exactly like a fixture that
  // failed to take. A verdict must distinguish REFUSED-FOR-THE-RIGHT-REASON
  // from REFUSED-FOR-A-DIFFERENT-REASON from NOT-REFUSED-AT-ALL.
  const snap = await req("project.overview");
  const snapA = (snap.tracks ?? []).find((t) => t.id === tA);
  say(`\n① ROUND-TRIP: track A reports takeGroups=${JSON.stringify(snapA?.takeGroups?.map?.((g) => g.name) ?? snapA?.takeGroups)}`);
  say(`   track A clip ids: ${JSON.stringify((snapA?.clips ?? []).map((c) => c.id.slice(0,8)))}`);

  const trimProbe = await raw("clip.trim",
    { trackId: tA, clipId: a0, newStartBeat: 1, newLengthBeats: 2 });
  const errText = trimProbe.__error ?? "";
  say(`① IS IT LIVE? clip.trim on a0 -> ${JSON.stringify(trimProbe).slice(0, 260)}`);
  const refusedForTakeGroup = /take group|PROBE TAKES/i.test(errText);
  const refusedOther = !!trimProbe.__error && !refusedForTakeGroup;
  const notRefused = !trimProbe.__error;
  say(`   refused BECAUSE take group : ${refusedForTakeGroup}`);
  say(`   refused for another reason : ${refusedOther}${refusedOther ? "  <-- INSTRUMENT FAULT, not a result" : ""}`);
  say(`   not refused at all         : ${notRefused}`);
  const isCompMember = refusedForTakeGroup;
  say(`   => comp member reachable from the wire: ${isCompMember ? "YES — m23-y's skip was a VERB limit, not a WIRE limit" : "NO"}`);

  if (!isCompMember) {
    say("\n⛔ fixture did not take. Everything below would be measuring the wrong state.");
  } else {
    // ── ② the header click, then the refused delete ─────────────────────────
    await req("debug.arrangeSelection", { act: "clickTrack", trackId: tA });
    const sel = await req("debug.arrangeSelection", { act: "report" }).catch(() => null)
      ?? await req("debug.arrangeSelection", {});
    say(`\n② after clickTrack A: focusClipId=${JSON.stringify(sel.focusClipId)} count=${sel.count} ids=${JSON.stringify((sel.selectedIds||[]).map(s=>s.slice(0,8)))}`);

    const del = await raw("debug.arrangeSelection", { act: "delete" });
    say(`   delete -> ${JSON.stringify(del).slice(0, 200)}`);

    const ptr = await req("debug.arrangePointer", {});
    say(`\n② REFUSAL ECHO: refusal=${JSON.stringify(ptr.refusal)} refusalClipId=${JSON.stringify(ptr.refusalClipId)}`);
    const anchored = ptr.refusalClipId;
    say(`   anchor is the OFFENDER (a0)? ${anchored === a0}`);
    say(`   anchor is an INNOCENT clip?  ${!!anchored && anchored !== a0}`);
    say(`   anchor is ABSENT (silence)?  ${!anchored}`);

    const ov = await req("project.overview");
    const live = (ov.tracks ?? []).flatMap((t) => (t.clips ?? []).map((c) => c.id));
    say(`\n② survivors: ${live.length} clip(s) — offender=${live.includes(a0)} trackA=${aIDs.filter((x)=>live.includes(x)).length}/8 b0=${live.includes(b0)}`);
  }
} finally {
  clearTimeout(killer);
  try { stopStaging(GATE, PIDFILE); } catch {}
}
