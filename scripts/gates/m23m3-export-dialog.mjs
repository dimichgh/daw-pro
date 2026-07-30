// m23-m3 export-dialog gate — capture + on-disk assertions through the LIVE app.
// Staging: DAW_CONTROL_PORT=17695 ONLY (17600 is the user's live app).
// Usage: node m23m3-export-dialog.mjs <ABSOLUTE outdir>
// m23-ac-3b-2: staging lifecycle from the ONE home. Was "class 3" — it launched
// nothing and drove whatever sat on the port, so its greens certified a hand-prepared
// instance. Two things changed besides build+launch. (1) `OUT` now DEFAULTS to the
// staging out dir, so the gate runs with no arguments like every other converted gate;
// an explicit argv still wins. (2) The old local `connect` was a SINGLE 5 s shot with
// no retry — fine when a human had the app up already, a race against our own boot now.
// The harness retries 40x1 s and refuses port 17600 outright.
import fs from "fs";
import { buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";
const PORT = process.env.PORT || "17695";
const GATE = "m23m3-export-dialog";   // names the pidfile + out dir = the default OUT
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

let PASS = 0, FAIL = 0;
const check = (name, ok, detail = "") => {
  if (ok) { PASS++; log(`  PASS ${name}${detail ? " — " + detail : ""}`); }
  else { FAIL++; log(`  FAIL ${name}${detail ? " — " + detail : ""}`); }
};

buildOrAbort({ label: "building staging binary (m23m3)…" });
startStaging({ gate: GATE });
const ws = await connect({ port: Number(PORT) });
const cap = async (name, params = {}) => {
  const r = await cmd(ws, "debug.captureUI", { path: `${OUT}/${name}.png`, ...params });
  log(`  captured ${name} ${r?.width}x${r?.height}`);
  return r;
};

// --- a session with real content -------------------------------------------
await cmd(ws, "project.new", { discardChanges: true });
const drums = await cmd(ws, "track.add", { name: "Drums", kind: "instrument" });
const vox = await cmd(ws, "track.add", { name: "Lead Vocal", kind: "instrument" });
await cmd(ws, "track.add", { name: "A Very Long Track Name For Truncation", kind: "instrument" });
await cmd(ws, "clip.addMIDI", {
  trackId: drums.id, atBeat: 0, lengthBeats: 4,
  notes: [{ pitch: 36, startBeat: 0, lengthBeats: 1, velocity: 100 },
          { pitch: 38, startBeat: 2, lengthBeats: 1, velocity: 100 }] });
await cmd(ws, "clip.addMIDI", {
  trackId: vox.id, atBeat: 0, lengthBeats: 4,
  notes: [{ pitch: 67, startBeat: 0, lengthBeats: 4, velocity: 100 }] });

// --- 1. the sheet opens headlessly and captures ----------------------------
let st = await cmd(ws, "debug.exportDialog", { open: true });
check("sheet opens", st.visible === true, JSON.stringify(st.request));
check("default request is the shipped bounce",
  st.request.bitDepth === null && st.request.container === null &&
  st.request.excludeTrackIds === null && st.request.lufsTarget === null &&
  st.request.truePeakCeilingDb === -1, JSON.stringify(st.request));
await cap("01-default");

// --- 2. every control lit, for the truncation review ------------------------
st = await cmd(ws, "debug.exportDialog", {
  bitDepth: 16, container: "aiff", excludeNamed: ["Lead Vocal"],
  normalize: true, lufsTarget: -14, truePeakCeilingDb: -1 });
check("format staged", st.container === "aiff" && st.bitDepth === 16, st.formatLabel);
check("suggested name carries the format's extension",
  st.suggestedFileName.endsWith(".aiff"), st.suggestedFileName);
check("exclusion staged", JSON.stringify(st.excluded) === '["Lead Vocal"]', JSON.stringify(st.excluded));
await cap("02-all-controls");

// --- 3. a long track name + many tracks (the list bound) --------------------
for (let i = 0; i < 8; i++) await cmd(ws, "track.add", { name: `Extra Track ${i + 1}`, kind: "bus" });
await cmd(ws, "debug.exportDialog", { open: true });
await cmd(ws, "debug.exportDialog", { bitDepth: 24, container: "wav", normalize: true });
await cap("03-long-list");

// --- 4. the real export, through the UI's own path --------------------------
await cmd(ws, "debug.exportDialog", { open: true, includeAll: true,
  bitDepth: 16, container: "aiff", normalize: false, excludeNamed: ["Lead Vocal"] });
const path = `${OUT}/gate-export`;
const before = (await cmd(ws, "debug.exportDialog", {})).renderCompletedCount;
await cmd(ws, "debug.exportDialog", { exportToPath: path });
let done = null;
for (let i = 0; i < 60; i++) {
  await new Promise((r) => setTimeout(r, 500));
  const s = await cmd(ws, "debug.exportDialog", {});
  if (s.lastExport || s.lastError) { done = s; break; }
}
check("export completed", !!done?.lastExport, done?.lastError || "");
if (done?.lastExport) {
  const p = done.lastExport.path;
  check("path took the container's extension", p.endsWith(".aiff"), p);
  const buf = fs.readFileSync(p);
  const magic = buf.toString("ascii", 0, 4);
  const form = buf.toString("ascii", 8, 12);
  check("magic bytes are FORM/AIFC", magic === "FORM" && form === "AIFC", magic + "/" + form);
  // walk to COMM for the sample size (big-endian IFF)
  let off = 12, bits = 0;
  while (off + 8 <= buf.length) {
    const id = buf.toString("ascii", off, off + 4);
    const size = buf.readUInt32BE(off + 4);
    if (id === "COMM") { bits = buf.readUInt16BE(off + 14); break; }
    off += 8 + size + (size % 2);
  }
  check("COMM says 16-bit", bits === 16, "sampleSize=" + bits);
  check("excludedTracks echoed", JSON.stringify(done.lastExport.excludedTracks) === '["Lead Vocal"]',
    JSON.stringify(done.lastExport.excludedTracks));
  check("renderCompletedCount advanced (the onboarding signal path)",
    done.renderCompletedCount === before + 1, `${before} -> ${done.renderCompletedCount}`);
}
await cap("04-result");

// --- 5. the project itself is untouched -------------------------------------
const snap = await cmd(ws, "project.snapshot", {});
const muted = (snap.tracks || []).filter((t) => t.muted).map((t) => t.name);
check("no track was muted by the export", muted.length === 0, JSON.stringify(muted));

// --- 6. DELETE is inert while the sheet is up (the maintenance obligation) ---
// `isModalPresented` names it outright: a new blocking modal must join that
// list, and the failure it prevents is SILENT destruction of clips behind a
// panel the user is looking at. m23-m3 incurred that obligation, so m23-m3
// closes it. The second half is the positive control — without it a `false`
// verdict is indistinguishable from an empty selection.
{
  const before = await cmd(ws, "project.snapshot", {});
  const clipsOf = (s) => (s.tracks || []).reduce((n, t) => n + (t.clips || []).length, 0);
  const clipId = (before.tracks || []).flatMap((t) => t.clips || [])[0]?.id;
  await cmd(ws, "debug.arrangeSelection", { act: "click", clipId });
  const sel = await cmd(ws, "debug.exportDialog", { open: true });
  const guarded = await cmd(ws, "debug.arrangeSelection", { act: "keyHandler" });
  const mid = await cmd(ws, "project.snapshot", {});
  check("DELETE is refused while the export sheet is up",
    sel.visible === true && guarded.deleted === false && clipsOf(mid) === clipsOf(before),
    `deleted=${guarded.deleted} clips ${clipsOf(before)} -> ${clipsOf(mid)}`);

  await cmd(ws, "debug.exportDialog", { close: true });
  const freed = await cmd(ws, "debug.arrangeSelection", { act: "keyHandler" });
  const after = await cmd(ws, "project.snapshot", {});
  check("…and NOT refused once it closes (the guard, not an empty selection)",
    freed.deleted === true && clipsOf(after) === clipsOf(before) - 1,
    `deleted=${freed.deleted} clips ${clipsOf(mid)} -> ${clipsOf(after)}`);
  await cmd(ws, "edit.undo", {});
}

// --- 7. close ---------------------------------------------------------------
st = await cmd(ws, "debug.exportDialog", { close: true });
check("sheet closes", st.visible === false);
await cap("05-closed");

log(`\n${PASS} passed, ${FAIL} failed`);
ws.close();
stopStaging(GATE);   // SIGTERMs by exact pid AND releases our session.lock
process.exit(FAIL ? 1 : 0);
