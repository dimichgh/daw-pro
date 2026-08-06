// m23-m3b gate — the track-header "Export MIDI…" surface, through the LIVE app.
// Staging: the port comes from the harness (`STAGING_PORT` = 17695) and is NOT
// configurable from the environment — see m23-bi. 17600 is the user's live app;
// `assertStagingPort` hard-exits on it.
// Usage: node m23m3b-track-midi-export.mjs <ABSOLUTE outdir>
//
// What this can and CANNOT reach, stated up front so nobody reads more into a
// green run than it earns:
//
//   CAN   — `debug.trackMenu` echoes the ITEM LIST the SwiftUI row renders from
//           (both call `AppModel.trackHeaderMenuItems(for:)`, the one binding of
//           live state to `TrackHeaderMenu`), and `track.exportMIDI` writes the
//           bytes the menu item's save panel hands the store.
//   CANNOT — open the context menu. An AppKit popup has no headless seam. The
//           mitigation is STRUCTURAL, not observational: the `.contextMenu`
//           builder has zero inline conditions left, so "the view ignores the
//           model" would have to be a visible edit in TrackListView.swift.
// m23-ac-3b-2: staging lifecycle from the ONE home. Was "class 3". `OUT` now DEFAULTS
// to the staging out dir, which RETIRES the old `usage:` guard — that guard existed
// because the gate had no default and would otherwise mkdir `undefined`; it exited 2,
// and an exit-2 from a gate that never ran looks a lot like a gate that ran and failed.
// The old local `connect` was a SINGLE 5 s shot with no retry, which raced our own boot;
// the harness retries 40x1 s and refuses port 17600 outright.
import fs from "fs";
import path from "path";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";
const GATE = "m23m3b-track-midi-export";   // names the pidfile + out dir = the default OUT
const OUT = process.argv[2] || `/tmp/daw-gate-out/${GATE}`;
const log = (s) => fs.writeSync(1, s + "\n");
fs.mkdirSync(OUT, { recursive: true });
let seq = 0;

function cmd(ws, command, params = {}, timeoutMs = 60000) {
  return new Promise((res, rej) => {
    const id = "r" + ++seq;
    const t = setTimeout(() => rej(new Error("timeout " + command)), timeoutMs);
    const onMsg = (e) => {
      const m = JSON.parse(e.data);
      if (m.id !== id) return;
      clearTimeout(t);
      ws.removeEventListener("message", onMsg);
      if (m.error) rej(new Error(command + ": " + m.error));
      else res(m.result);
    };
    ws.addEventListener("message", onMsg);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
// A command we EXPECT to be refused. Returns the error text.
async function refused(ws, command, params, label) {
  try {
    await cmd(ws, command, params);
    return null;                       // no refusal — the caller fails the leg
  } catch (e) {
    return String(e.message);
  }
}

const legs = [];
const leg = (name, ok, detail = "") => {
  legs.push({ name, ok: !!ok, detail });
  log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  — " + detail : ""}`);
};

// ---- A hand-rolled SMF walker. Deliberately NOT the shipped reader: a file
// validated by the code that wrote it proves only self-consistency.
function parseSMF(buf) {
  if (buf.length < 14) throw new Error("shorter than a header chunk");
  if (buf.toString("ascii", 0, 4) !== "MThd") throw new Error("no MThd magic");
  const headerLen = buf.readUInt32BE(4);
  if (headerLen !== 6) throw new Error(`MThd length ${headerLen}, want 6`);
  const format = buf.readUInt16BE(8);
  const ntrks = buf.readUInt16BE(10);
  const division = buf.readUInt16BE(12);
  let off = 8 + headerLen;
  const chunks = [];
  while (off + 8 <= buf.length) {
    const tag = buf.toString("ascii", off, off + 4);
    const len = buf.readUInt32BE(off + 4);
    if (off + 8 + len > buf.length) throw new Error(`chunk ${tag} runs past EOF`);
    // Every MTrk must END with the meta end-of-track event FF 2F 00.
    const body = buf.subarray(off + 8, off + 8 + len);
    const endsProperly = len >= 3 && body[len - 3] === 0xff
      && body[len - 2] === 0x2f && body[len - 1] === 0x00;
    chunks.push({ tag, len, endsProperly });
    off += 8 + len;
  }
  if (off !== buf.length) throw new Error(`${buf.length - off} trailing bytes`);
  return { format, ntrks, division, chunks };
}

buildOrAbort({ label: "building staging binary (m23m3b)…" });
startStaging({ gate: GATE });
const ws = await connect();   // port from the harness; no env override (m23-bi)
try {
  // ---- Fixture: one track of every kind, plus one instrument routed through a
  // bus (the configuration where "exports" and "bounces" disagree).
  await cmd(ws, "project.new", { discardChanges: true });
  const lead = await cmd(ws, "track.add", { name: "Lead", kind: "instrument" });
  const vox = await cmd(ws, "track.add", { name: "Vox", kind: "audio" });
  const bus = await cmd(ws, "track.add", { name: "Reverb", kind: "bus" });
  const routed = await cmd(ws, "track.add", { name: "Pad", kind: "instrument" });
  await cmd(ws, "track.setOutput", { trackId: routed.id, busId: bus.id })
    .catch(async () => { await cmd(ws, "track.update", { id: routed.id, outputBusId: bus.id }); });

  const clip = await cmd(ws, "clip.addMIDI", { trackId: lead.id, atBeat: 0, lengthBeats: 4 });
  await cmd(ws, "clip.setNotes", {
    clipId: clip.id,
    notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1 },
            { pitch: 64, startBeat: 1, lengthBeats: 1 },
            { pitch: 67, startBeat: 2, lengthBeats: 2 }],
  });

  // ---- LEG 1-4: the item list, per kind. FULL list equality, not membership:
  // the ForEach refactor could drop or reorder an item and a `contains` leg
  // would never see it.
  const menuOf = async (id) => (await cmd(ws, "debug.trackMenu", { trackId: id }));
  const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

  const mLead = await menuOf(lead.id);
  leg("L1 instrument -> master offers rename/bounce/exportMIDI/remove",
      eq(mLead.actions, ["rename", "bounceInPlace", "exportMIDI", "removeTrack"]),
      JSON.stringify(mLead.actions));

  const mRouted = await menuOf(routed.id);
  leg("L2 instrument -> bus offers exportMIDI but NOT bounceInPlace",
      eq(mRouted.actions, ["rename", "exportMIDI", "removeTrack"]),
      JSON.stringify(mRouted.actions));

  const mVox = await menuOf(vox.id);
  leg("L3 audio track has NO exportMIDI item",
      eq(mVox.actions, ["rename", "bounceInPlace", "removeTrack"]),
      JSON.stringify(mVox.actions));

  const mBus = await menuOf(bus.id);
  leg("L4 bus track has NO exportMIDI item",
      eq(mBus.actions, ["rename", "bounceInPlace", "removeTrack"]),
      JSON.stringify(mBus.actions));

  // ---- LEG 5: the echoed predicate and the echoed list agree. If they ever
  // part, the menu is reading something other than `Track.canExportMIDI`.
  const agree = [mLead, mRouted, mVox, mBus].every(
    (m) => m.actions.includes("exportMIDI") === m.canExportMIDI);
  leg("L5 item presence == canExportMIDI, on every track", agree);

  // ---- LEG 6: the item's TITLE (what the user actually reads).
  const title = mLead.items.find((i) => i.action === "exportMIDI")?.title;
  const destructive = mLead.items.find((i) => i.action === "exportMIDI")?.destructive;
  leg("L6 the item reads 'Export MIDI…' and is not destructive",
      title === "Export MIDI…" && destructive === false, `title=${title}`);

  // ---- LEG 7: the seam refuses a bad id rather than answering vacuously.
  const bad = await refused(ws, "debug.trackMenu", { trackId: "not-a-uuid" });
  const missing = await refused(ws, "debug.trackMenu",
    { trackId: "00000000-0000-0000-0000-000000000000" });
  leg("L7 debug.trackMenu refuses a malformed id and an unknown track",
      bad && missing && /trackId/.test(bad) && /no such track/.test(missing),
      `${bad} | ${missing}`);

  // ---- LEG 8: the bytes. `track.exportMIDI` is exactly what the menu item's
  // save panel calls; validated by a walker that did not write them.
  const dest = path.join(OUT, "Lead.mid");
  // The wire shape is {written, report:{…}} — the numbers live one level down.
  const response = await cmd(ws, "track.exportMIDI", { trackId: lead.id, path: dest });
  const report = response.report;
  const buf = fs.readFileSync(dest);
  let smf = null, parseErr = null;
  try { smf = parseSMF(buf); } catch (e) { parseErr = String(e.message); }
  leg("L8 the exported file parses as an SMF (MThd + walkable chunks)",
      smf && smf.chunks.length === 2 && smf.chunks.every((c) => c.tag === "MTrk" || c.tag === "MThd"),
      parseErr || `format=${smf.format} ntrks=${smf.ntrks} division=${smf.division} ` +
                  `bytes=${buf.length} reported=${report.byteCount}`);
  leg("L8b every MTrk ends with FF 2F 00, and the byte count matches the report",
      smf && smf.chunks.every((c) => c.endsProperly) && buf.length === report.byteCount);
  leg("L8c the file carries the TRACK, not the whole project",
      report.notesExported === 3 && smf && smf.ntrks === 2,
      `notesExported=${report.notesExported}`);

  // ---- LEG 9: the refusal the menu makes unreachable is still there. This is
  // the backstop; the menu hiding the item is what keeps a user off it.
  const audioRefusal = await refused(ws, "track.exportMIDI",
    { trackId: vox.id, path: path.join(OUT, "should-not-exist.mid") });
  const busRefusal = await refused(ws, "track.exportMIDI",
    { trackId: bus.id, path: path.join(OUT, "should-not-exist-2.mid") });
  leg("L9 the store still refuses both ineligible kinds, and writes NO file",
      audioRefusal && busRefusal
      && !fs.existsSync(path.join(OUT, "should-not-exist.mid"))
      && !fs.existsSync(path.join(OUT, "should-not-exist-2.mid")),
      `${audioRefusal}`);

  // ---- LEG 10: sidebar width does not change the EXPORT item (only the
  // automation one is width-sensitive) — a guard against a copy-pasted rule.
  // m23-dv-1: `sidebarWidth` is a STICKY pref in the shared `DAWApp` domain, and
  // this leg used to leave 400 behind on every green run (MEASURED from a seeded
  // app-defaults baseline: 400 vs a default of 260). Capture the prior BEFORE the
  // first write — after it, the "prior" is this gate's own value.
  // ⚠️ THIS FILE'S `cmd` RESOLVES `m.result` DIRECTLY (`:43`), unlike m22g/m23c2
  // whose helpers resolve the whole envelope. Reading `.result` here yields
  // undefined — measured: the first version of this restore silently no-opped and
  // the gate still leaked 400 with a green run.
  const priorSidebarWidth = (await cmd(ws, "debug.panelLayout", {}))?.sidebarWidth;
  await cmd(ws, "debug.panelLayout", { sidebarWidth: 250 });
  const narrow = await menuOf(lead.id);
  await cmd(ws, "debug.panelLayout", { sidebarWidth: 400 });
  const wide = await menuOf(lead.id);
  leg("L10 the export item is width-insensitive; the echo reports the width it used",
      eq(narrow.actions, wide.actions) && narrow.sidebarWidth === 250 && wide.sidebarWidth === 400,
      `${narrow.sidebarWidth} vs ${wide.sidebarWidth}`);
  // Put it back immediately: nothing after this leg needs the width, and an
  // inline restore cannot be skipped by the `process.exit` below (which does NOT
  // unwind the `finally` — the m23-bd law).
  // ⚠️ NO `if (prior !== undefined)` GUARD. The first version had one, the prior
  // read was undefined for the reason above, and the guard turned a broken restore
  // into a SILENT no-op that still exited 0 — the failure mode this whole item is
  // about. An unreadable prior is a real defect and must be loud, not skipped.
  if (priorSidebarWidth === undefined) {
    console.error("  ⚠️ could not read prior sidebarWidth — NOT restoring, and this is a BUG");
  } else {
    await cmd(ws, "debug.panelLayout", { sidebarWidth: priorSidebarWidth });
    const back = (await cmd(ws, "debug.panelLayout", {}))?.sidebarWidth;
    console.log(`  sidebarWidth restored: ${back} (prior was ${priorSidebarWidth})`);
  }

  // ---- LEG 11: the automation input reaches the model. `ui.showAutomation`
  // opens the row; the echo must SEE it (this track has no take groups, so the
  // ITEM stays inline/absent — what is proven here is the input binding, which
  // is the half a headless seam can actually reach).
  await cmd(ws, "ui.showAutomation", { trackId: lead.id });
  const opened = await menuOf(lead.id);
  leg("L11 the echo reads LIVE automation state, not a default",
      opened.automationExpanded === true && mLead.automationExpanded === false,
      `before=${mLead.automationExpanded} after=${opened.automationExpanded}`);

  const failed = legs.filter((l) => !l.ok);
  fs.writeFileSync(path.join(OUT, "legs.json"), JSON.stringify(legs, null, 2));
  log(`\n${legs.length - failed.length}/${legs.length} legs passed`);
  // ⚠️ Teardown must happen HERE, before process.exit — not only in the `finally`.
  // `process.exit()` terminates immediately and does NOT run pending finally blocks,
  // so on the normal path that `ws.close()` below has never executed. Harmless for a
  // socket the OS reaps anyway; fatal for a staging app, which would be left running.
  // stopStaging is idempotent (a missing pidfile is an early return), so having it on
  // both paths is safe and the `finally` still covers a throw.
  stopStaging(GATE);
  process.exit(failed.length ? 1 : 0);
} finally {
  ws.close();
  stopStaging(GATE);
}
