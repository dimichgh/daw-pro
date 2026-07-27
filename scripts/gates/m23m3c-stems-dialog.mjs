// m23-m3c stems-export gate — the PLAN the dialog shows vs the FILES on disk,
// driven through the LIVE app. Staging: DAW_CONTROL_PORT=17695 ONLY
// (17600 is the user's live app and is never touched).
//
// The assertion that matters is never "the preview lists four names" — it is
// "the folder afterwards holds EXACTLY those names". A preview that mirrored
// `StemPlan`'s numbering instead of calling it would pass every echo leg and
// still promise files nobody gets, which is why every listing here comes from
// fs.readdirSync and every format claim from a byte reader that did not write
// the file.
//
// Usage: node m23m3c-stems-dialog.mjs <ABSOLUTE outdir>
//
// PREMISE: run this against a FRESHLY LAUNCHED staging app. The dialog is
// sticky WITHIN a session (m23-m3, measured), so legs 1/3/5/7/8 — which assert
// the LAUNCH defaults — go red if anything drove the sheet first, and they read
// exactly like a product regression when they do (observed 2026-07-27: a floor
// soak left mode=stems + 16-bit AIFF behind and this gate reported 22/27 on an
// unchanged build). The guard below refuses instead of mis-reporting.
const PORT = process.env.PORT || "17695";
const OUT = process.argv[2];
import fs from "fs";
import path from "path";
const log = (s) => fs.writeSync(1, s + "\n");
fs.mkdirSync(OUT, { recursive: true });
let seq = 0;

function connect(timeoutMs = 5000) {
  return new Promise((res, rej) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
    const t = setTimeout(() => rej(new Error("connect timeout")), timeoutMs);
    ws.onopen = () => { clearTimeout(t); res(ws); };
    ws.onerror = () => { clearTimeout(t); rej(new Error("connect failed")); };
  });
}
function cmd(ws, command, params = {}, timeoutMs = 120000) {
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
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
// Directory listing, dotfile-tolerant (a Finder visit must not redden a leg
// about stem names). A MISSING directory fails its leg instead of crashing the
// run — the m23-m3 lesson: the first casualty must not truncate the map.
const listing = (dir) => {
  try { return fs.readdirSync(dir).filter((n) => !n.startsWith(".")).sort(); }
  catch (e) { return ["<unreadable: " + e.code + ">"]; }
};

const ws = await connect();
const cap = async (name, params = {}) => {
  const r = await cmd(ws, "debug.captureUI", { path: `${OUT}/${name}.png`, ...params });
  log(`  captured ${name} ${r?.width}x${r?.height}`);
  return r;
};

// --- the session the eligibility rule turns on ------------------------------
// Keys (direct), Verb (bus), Bass (routed INTO Verb — no stem of its own),
// Keys again (same name — the " 2" collision suffix). Partition therefore reads
// 01 Keys / 02 Verb / 03 Keys 2, and Bass is absent.
await cmd(ws, "project.new", { discardChanges: true });
const keys = await cmd(ws, "track.add", { name: "Keys", kind: "instrument" });
const verb = await cmd(ws, "track.add", { name: "Verb", kind: "bus" });
const bass = await cmd(ws, "track.add", { name: "Bass", kind: "instrument" });
const keys2 = await cmd(ws, "track.add", { name: "Keys", kind: "instrument" });
await cmd(ws, "track.setOutput", { trackId: bass.id, busId: verb.id });
for (const [t, pitch] of [[keys, 60], [bass, 40], [keys2, 67]]) {
  await cmd(ws, "clip.addMIDI", {
    trackId: t.id, atBeat: 0, lengthBeats: 4,
    notes: [{ pitch, startBeat: 0, lengthBeats: 2, velocity: 100 }] });
}

const STEMS = ["01 Keys.wav", "02 Verb.wav", "03 Keys 2.wav"];

// --- 1. the mode ------------------------------------------------------------
let st = await cmd(ws, "debug.exportDialog", { open: true });
// The fresh-launch premise, checked before anything is asserted ON it. A dirty
// session is a HARNESS fault, and saying so beats five legs that look like bugs.
// (Read the RAW request fields, not the top-level ones: `container` echoes the
//  RESOLVED default "wav" even when nothing has been chosen, so it can never be
//  null and a guard on it would refuse every fresh launch.)
if (st.mode !== "bounce" || st.request.bitDepth !== null || st.request.container !== null ||
    st.includeMixdown === true || st.includeMasteredMixdown === true) {
  log("PREMISE VIOLATED — this dialog has already been driven this session " +
      `(mode=${st.mode} bitDepth=${st.request.bitDepth} container=${st.request.container} ` +
      `includeMixdown=${st.includeMixdown} includeMasteredMixdown=${st.includeMasteredMixdown}). ` +
      "Relaunch the staging app and re-run; the sheet keeps its settings until quit.");
  process.exit(2);
}
check("sheet opens in BOUNCE mode", st.visible === true && st.mode === "bounce", st.mode);
st = await cmd(ws, "debug.exportDialog", { mode: "stems" });
check("mode switches to stems", st.mode === "stems", st.mode);
check("a fresh stems request is renderStems' own defaults",
  st.stemRequest.trackIds === null && st.stemRequest.includeMixdown === false &&
  st.stemRequest.includeMasteredMixdown === false &&
  st.stemRequest.masteredLufsTarget === null &&
  st.stemRequest.masteredTruePeakCeilingDb === -1 &&
  st.stemRequest.bitDepth === null && st.stemRequest.container === null,
  JSON.stringify(st.stemRequest));
await cap("01-stems-default");

// --- 2. the plan: eligibility, renumbering, collision ------------------------
check("the plan drops the bus-routed track, renumbers, and suffixes the duplicate",
  eq(st.plannedFiles, STEMS), JSON.stringify(st.plannedFiles));
check("no file is planned for the bus-routed source",
  !st.plannedFiles.some((n) => n.includes("Bass")), JSON.stringify(st.plannedFiles));

// --- 3. the siblings, in write order ----------------------------------------
st = await cmd(ws, "debug.exportDialog", { includeMixdown: true });
check("the reference mix joins at the head",
  eq(st.plannedFiles, ["00 Mixdown.wav", ...STEMS]), JSON.stringify(st.plannedFiles));
st = await cmd(ws, "debug.exportDialog", { includeMasteredMixdown: true });
check("the mastered sibling follows it, and the stems keep their numbers",
  eq(st.plannedFiles, ["00 Mixdown.wav", "00 Mastered Mix.wav", ...STEMS]),
  JSON.stringify(st.plannedFiles));

// --- 4. the SHARED format control reaches the plan --------------------------
st = await cmd(ws, "debug.exportDialog", { bitDepth: 16, container: "aiff" });
const PLANNED_AIFF = ["00 Mixdown.aiff", "00 Mastered Mix.aiff",
                      "01 Keys.aiff", "02 Verb.aiff", "03 Keys 2.aiff"];
check("every planned name takes the chosen container's extension",
  eq(st.plannedFiles, PLANNED_AIFF), JSON.stringify(st.plannedFiles));
check("…and it is ONE control: the bounce's suggested name moved too",
  st.suggestedFileName.endsWith(".aiff") && st.bitDepth === 16, st.suggestedFileName);

// --- 5. a mastered target rides the file that uses it ------------------------
st = await cmd(ws, "debug.exportDialog", { masteredNormalize: true, masteredLufsTarget: -14 });
check("target carried while the mastered file is being written",
  st.stemRequest.masteredLufsTarget === -14, JSON.stringify(st.stemRequest));
st = await cmd(ws, "debug.exportDialog", { includeMasteredMixdown: false });
check("…and dropped when it is not — a setting that changes no samples is not sent",
  st.stemRequest.masteredLufsTarget === null &&
  st.stemRequest.masteredTruePeakCeilingDb === -1, JSON.stringify(st.stemRequest));
st = await cmd(ws, "debug.exportDialog", { includeMasteredMixdown: true });
await cap("02-stems-all-lit");

// --- 6. THE ITEM: the plan vs the folder ------------------------------------
const dir1 = path.join(OUT, "stems-run-1");
const promised = st.plannedFiles;
await cmd(ws, "debug.exportDialog", { exportToDirectory: dir1 });
let done = null;
for (let i = 0; i < 120; i++) {
  await new Promise((r) => setTimeout(r, 500));
  const s = await cmd(ws, "debug.exportDialog", {});
  if (s.lastStemExport || s.lastError) { done = s; break; }
}
check("the stems export completed", !!done?.lastStemExport, done?.lastError || "");
if (done?.lastStemExport) {
  const outcome = done.lastStemExport;
  const onDisk = listing(outcome.directory);
  check("THE FOLDER HOLDS EXACTLY WHAT THE CARD PROMISED",
    eq(onDisk, [...promised].sort()), `promised ${JSON.stringify(promised)} / on disk ${JSON.stringify(onDisk)}`);
  check("the result strip names the files that landed, in plan order",
    eq(outcome.files, promised), JSON.stringify(outcome.files));
  check("no stem was written for the bus-routed track",
    !onDisk.some((n) => n.includes("Bass")), JSON.stringify(onDisk));
  check("the format label describes the delivered files",
    outcome.formatLabel === "16-bit integer AIFF", outcome.formatLabel);
  check("this project has no master chain, and the card says so",
    outcome.masterChainExcluded === false, String(outcome.masterChainExcluded));

  // Magic bytes on a STEM — the shared format control must reach the stem
  // writer, not only the bounce's. Read by a parser that did not write it.
  const stem = path.join(outcome.directory, "01 Keys.aiff");
  const buf = fs.readFileSync(stem);
  const magic = buf.toString("ascii", 0, 4);
  const form = buf.toString("ascii", 8, 12);
  check("a stem's magic bytes are FORM/AIFC", magic === "FORM" && form === "AIFC",
    magic + "/" + form);
  let off = 12, bits = 0;
  while (off + 8 <= buf.length) {
    const id = buf.toString("ascii", off, off + 4);
    const size = buf.readUInt32BE(off + 4);
    if (id === "COMM") { bits = buf.readUInt16BE(off + 14); break; }
    off += 8 + size + (size % 2);
  }
  check("a stem's COMM says 16-bit", bits === 16, "sampleSize=" + bits);

  // The mastered sibling is a SEPARATE render, not a copy: normalization was on
  // for it and the reference mixdown is never normalized, so the two files must
  // differ. Identical bytes here would mean one of them was copied.
  const mix = fs.readFileSync(path.join(outcome.directory, "00 Mixdown.aiff"));
  const mastered = fs.readFileSync(path.join(outcome.directory, "00 Mastered Mix.aiff"));
  check("the mastered sibling is its own render, not a copy of the reference mix",
    !mix.equals(mastered), `${mix.length} vs ${mastered.length} bytes`);
}
await cap("03-stems-result");

// --- 7. a master chain shows up in the honesty field -------------------------
await cmd(ws, "fx.add", { trackId: "master", kind: "compressor" });
const dir2 = path.join(OUT, "stems-run-2");
await cmd(ws, "debug.exportDialog", { open: true, mode: "stems" });
await cmd(ws, "debug.exportDialog", { exportToDirectory: dir2 });
let done2 = null;
for (let i = 0; i < 120; i++) {
  await new Promise((r) => setTimeout(r, 500));
  const s = await cmd(ws, "debug.exportDialog", {});
  if (s.lastStemExport || s.lastError) { done2 = s; break; }
}
check("a project WITH a master chain reports the stems as chain-excluded",
  done2?.lastStemExport?.masterChainExcluded === true,
  JSON.stringify(done2?.lastStemExport?.masterChainExcluded ?? done2?.lastError));
if (done2?.lastStemExport) {
  check("…and the folder still equals the plan",
    eq(listing(done2.lastStemExport.directory), [...done2.lastStemExport.files].sort()),
    JSON.stringify(listing(done2.lastStemExport.directory)));
}
await cap("04-stems-result-chain-excluded");

// --- 8. bounce mode is untouched (the m23-m3 regression) ---------------------
st = await cmd(ws, "debug.exportDialog", { open: true, mode: "bounce" });
check("bounce mode still requests through its own builder",
  st.mode === "bounce" && st.request.bitDepth === 16 && st.request.container === "aiff" &&
  st.request.excludeTrackIds === null,
  JSON.stringify(st.request));
check("the exclusion list is still bounce-only and still prunes",
  Array.isArray(st.tracks) && st.tracks.length === 4 && eq(st.excluded, []),
  JSON.stringify(st.tracks));
await cap("05-bounce-mode");

// --- 9. nothing reaches the main mix ----------------------------------------
await cmd(ws, "project.new", { discardChanges: true });
st = await cmd(ws, "debug.exportDialog", { open: true, mode: "stems" });
check("an empty project plans NO files — not even the siblings",
  eq(st.plannedFiles, []), JSON.stringify(st.plannedFiles));
st = await cmd(ws, "debug.exportDialog", { includeMixdown: true, includeMasteredMixdown: true });
check("…and asking for the siblings does not conjure a set out of nothing",
  eq(st.plannedFiles, []), JSON.stringify(st.plannedFiles));
await cap("06-stems-empty");

st = await cmd(ws, "debug.exportDialog", { close: true });
check("sheet closes", st.visible === false);

log(`\n${PASS} passed, ${FAIL} failed`);
ws.close();
process.exit(FAIL ? 1 : 0);
