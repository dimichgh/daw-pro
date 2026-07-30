// m23-o2 SMOKE: does `debug.effectEditor` actually emit `instrumentGuide`?
//
// NOT the gate — the coordinator writes that. This exists because the DAWApp
// plumbing (effectEditorInstrumentGuide, guideProbeJSON, the payload block) is
// in the ONE target with no test suite, so nothing I wrote in DAWAppKitTests
// can prove it is wired up at all. Three states, live, over the wire.
//
// Staging 17695 ONLY. 17600 is the user's LIVE app and is never touched.
// Kill by EXACT pid from the pidfile — never pkill/pgrep.
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";

const PORT = 17695;
const OUT = "/tmp/daw-gate-out/m23o2-smoke";
const PIDFILE = `${OUT}/staging.pid`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
mkdirSync(OUT, { recursive: true });

let child = null;
function startStaging() {
  child = spawn(".build/debug/DAWApp", [], {
    cwd: "/Users/dsemenov/Views/daw-pro",
    env: { ...process.env, DAW_CONTROL_PORT: String(PORT) },
    stdio: ["ignore", "pipe", "pipe"],
    detached: false,
  });
  writeFileSync(PIDFILE, String(child.pid));
  const log = [];
  child.stdout.on("data", (d) => log.push(d.toString()));
  child.stderr.on("data", (d) => log.push(d.toString()));
  process.on("exit", () => writeFileSync(`${OUT}/staging.log`, log.join("")));
}
function stopStaging() {
  if (!existsSync(PIDFILE)) return;
  const pid = Number(readFileSync(PIDFILE, "utf8").trim());
  if (Number.isInteger(pid) && pid > 0) {
    try { process.kill(pid, "SIGTERM"); } catch { /* gone */ }
  }
  rmSync(PIDFILE, { force: true });
}
async function connect() {
  for (let i = 0; i < 40; i++) {
    try {
      return await new Promise((res, rej) => {
        const w = new WebSocket(`ws://127.0.0.1:${PORT}`);
        w.addEventListener("open", () => res(w));
        w.addEventListener("error", () => rej(new Error("refused")));
      });
    } catch { await sleep(1000); }
  }
  throw new Error(`could not connect to staging on ${PORT}`);
}
let ws, seq = 0, pass = 0, fail = 0;
const failures = [];
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = `o2s-${++seq}`;
    const timer = setTimeout(() => rej(new Error(`timeout ${command}`)), timeoutMs);
    const onMsg = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id !== id) return;
      clearTimeout(timer); ws.removeEventListener("message", onMsg); res(m);
    };
    ws.addEventListener("message", onMsg);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
function ck(label, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS ${label}`); }
  else { fail++; failures.push(label); console.log(`FAIL ${label} :: ${detail}`); }
}

startStaging();
try {
  ws = await connect();
  let r = await cmd("project.new", { discardChanges: true });
  ck("S1 project.new", r.ok, r.error);
  r = await cmd("debug.panelDensity", { panel: "effectEditor", mode: "simple" });
  ck("S2 effect editor density = simple (the curve surface)", r.ok, r.error);

  // --- A: AUDIO track -> the honest EMPTY STATE (the common case) ---
  r = await cmd("track.add", { kind: "audio", name: "VoxDI" });
  const audioTid = (r.result?.track ?? r.result)?.id;
  r = await cmd("fx.add", { trackId: audioTid, kind: "eq" });
  const audioEq = r.result?.effectId ?? r.result?.effect?.id;
  ck("S3 audio track + EQ insert", !!audioTid && !!audioEq, JSON.stringify(r.result));

  r = await cmd("debug.effectEditor", { trackId: audioTid, effectId: audioEq, open: true });
  let g = r.result?.instrumentGuide;
  console.log("AUDIO guide:", JSON.stringify(g, null, 1));
  ck("A1 instrumentGuide is present at all (the DAWApp plumbing is wired)",
     g != null && typeof g === "object", JSON.stringify(r.result)?.slice(0, 400));
  ck("A2 state is the honest empty state, not a defaulted family",
     g?.state === "unknown", `state=${g?.state}`);
  ck("A3 the reason names the audio-track case", g?.reason === "audioTrackHasNoInstrument",
     `reason=${g?.reason}`);
  ck("A4 empty state carries user-facing words", typeof g?.headline === "string"
     && g.headline.length > 0 && typeof g?.detail === "string" && g.detail.length > 0,
     JSON.stringify({ h: g?.headline, d: g?.detail }));
  ck("A5 no wire verb leaks into the user copy",
     !/frequency\.reference|fx\.spectrum|trackId|coveredNotes/.test(
       `${g?.headline} ${g?.detail}`), `${g?.headline} | ${g?.detail}`);
  ck("A6 an unresolved card draws NO marks", (g?.markCount ?? -1) === 0, `markCount=${g?.markCount}`);
  ck("A6b an empty state DOES draw its row (showsRow is explicit, not inferred)",
     g?.showsRow === true, `showsRow=${g?.showsRow}`);
  // ⚠️ FIRST-OPEN TRANSIENT, CONFIRMED NOT ASSUMED. The very first card read
  // after opening can report `layoutConstant`: the probe round-trip beats the
  // Canvas's first layout, so no measured width exists yet. That is the field
  // doing its job — the number is honest and labelled — but a gate that
  // asserts `measured` without settling first WILL flake. Re-read and prove it
  // converges rather than hard-coding a sleep and hoping.
  const firstSource = g?.widthSource;
  await sleep(400);
  r = await cmd("debug.effectEditor", {});
  const settled = r.result?.instrumentGuide;
  ck("A7b widthSource converges to measured once the card has laid out",
     settled?.widthSource === "measured",
     `first=${firstSource} settled=${settled?.widthSource}`);
  ck("A7c the settled width is the real content column",
     Math.abs((settled?.width ?? 0) - 528) < 0.5, `width=${settled?.width}`);
  ck("A7 no family/range fields are reported for an empty state",
     g?.family == null && g?.fundamentalHz == null,
     JSON.stringify({ f: g?.family, hz: g?.fundamentalHz }));

  // --- B: GM electric bass (program 33) -> a resolved family with marks ---
  r = await cmd("track.add", { kind: "instrument", name: "Bass" });
  const bassTid = (r.result?.track ?? r.result)?.id;
  r = await cmd("track.setInstrument", {
    trackId: bassTid, kind: "soundBank",
    soundBank: { source: "gm", program: 33, bankMSB: 121, bankLSB: 0 },
  });
  ck("S4 GM program 33 (Electric Bass finger) set", r.ok, r.error);
  r = await cmd("fx.add", { trackId: bassTid, kind: "eq" });
  const bassEq = r.result?.effectId ?? r.result?.effect?.id;

  r = await cmd("debug.effectEditor", { trackId: bassTid, effectId: bassEq, open: true });
  g = r.result?.instrumentGuide;
  console.log("BASS guide:", JSON.stringify(g, null, 1));
  ck("B1 family resolved", g?.state === "family" && g?.family === "electricBass",
     JSON.stringify({ s: g?.state, f: g?.family }));
  ck("B2 the RUNG that resolved it is reported", g?.resolvedFrom === "gmProgram",
     `resolvedFrom=${g?.resolvedFrom}`);
  // BOTH coordinate spaces — "right Hz" and "right place on this axis" are
  // different claims and a coordinate bug satisfies only the first.
  const fHz = g?.fundamentalHz, fX = g?.fundamentalX;
  ck("B3 fundamental reported in Hz as [lo, hi]",
     Array.isArray(fHz) && fHz.length === 2 && fHz.every(Number.isFinite)
     && fHz[0] < fHz[1],
     JSON.stringify(fHz));
  ck("B4 fundamental reported as on-screen x too, inside the reported width",
     Array.isArray(fX) && fX.length === 2 && fX.every(Number.isFinite)
     && fX[0] >= 0 && fX[1] <= g.width && fX[0] < fX[1],
     JSON.stringify({ x: fX, w: g?.width }));
  // ⚠️ THE TWO SPACES MUST AGREE, and agreement is the whole point of
  // reporting both: a coordinate-space bug keeps the Hz right while the x
  // silently drifts. Recompute the plot's own log map here, independently.
  const axisX = (hz) => g.width * Math.log(hz / 20) / Math.log(1000);
  ck("B4b the reported x IS the reported Hz through the plot's log axis",
     Array.isArray(fHz) && Array.isArray(fX)
     && Math.abs(axisX(fHz[0]) - fX[0]) < 0.01
     && Math.abs(axisX(fHz[1]) - fX[1]) < 0.01
     && Math.abs(axisX(g.highPassHz) - g.highPassX) < 0.01,
     JSON.stringify({ wantLo: axisX(fHz?.[0]), gotLo: fX?.[0],
                      wantHp: axisX(g?.highPassHz), gotHp: g?.highPassX }));
  ck("B5 high-pass corner in both spaces", Number.isFinite(g?.highPassHz)
     && Number.isFinite(g?.highPassX) && g.highPassX > 0 && g.highPassX < g.width,
     JSON.stringify({ hz: g?.highPassHz, x: g?.highPassX }));
  ck("B6 noneRecommended low-pass reported BY NAME, not 0 and not the axis edge",
     typeof g?.lowPassNone === "string" && g.lowPassNone.length > 0
     && g?.lowPassHz == null && g?.lowPassX == null,
     JSON.stringify({ none: g?.lowPassNone, hz: g?.lowPassHz, x: g?.lowPassX }));
  ck("B7 marks are drawn", (g?.markCount ?? 0) > 0, `markCount=${g?.markCount}`);
  ck("B8 tags are drawn text, and share NO vocabulary with the band handles",
     Array.isArray(g?.tags) && g.tags.length > 0
     && g.tags.every((t) => !/(^|\s)(HP|LP|LS|HS)(\s|$)/.test(t)),
     JSON.stringify(g?.tags));
  // ⚠️ THE PROBE MUST REPORT THE WIDTH THAT WAS DRAWN, NOT THE CONSTANT.
  // `DAWApp` has no test target, so this leg is the ONLY place the
  // view->model->probe width path is observable at all.
  ck("B8b the probe reports a MEASURED width, not the layout constant",
     g?.widthSource === "measured", `widthSource=${g?.widthSource}`);
  ck("B8c the measured width is the card's real content column",
     Math.abs((g?.width ?? 0) - 528) < 0.5, `width=${g?.width}`);
  ck("B9 softness is reported per fact", typeof g?.fundamentalSource === "string"
     && typeof g?.highPassSource === "string",
     JSON.stringify({ f: g?.fundamentalSource, h: g?.highPassSource }));

  // --- C: GM percussion bank -> .drumKit, never a member family ---
  r = await cmd("track.add", { kind: "instrument", name: "Kit" });
  const kitTid = (r.result?.track ?? r.result)?.id;
  await cmd("track.setInstrument", {
    trackId: kitTid, kind: "soundBank",
    soundBank: { source: "gm", program: 0, bankMSB: 120, bankLSB: 0 },
  });
  r = await cmd("fx.add", { trackId: kitTid, kind: "eq" });
  const kitEq = r.result?.effectId ?? r.result?.effect?.id;
  r = await cmd("debug.effectEditor", { trackId: kitTid, effectId: kitEq, open: true });
  g = r.result?.instrumentGuide;
  console.log("KIT guide:", JSON.stringify(g, null, 1));
  ck("C1 a drum kit is its OWN state, never a representative piece",
     g?.state === "drumKit" && g?.family == null,
     JSON.stringify({ s: g?.state, f: g?.family }));
  ck("C2 a drum kit draws no marks", (g?.markCount ?? -1) === 0, `markCount=${g?.markCount}`);

  // --- D: MASTER insert -> notApplicable, and the row is not drawn at all ---
  r = await cmd("fx.add", { trackId: "master", kind: "eq" });
  const mEq = r.result?.effectId ?? r.result?.effect?.id;
  r = await cmd("debug.effectEditor", { trackId: "master", effectId: mEq, open: true });
  g = r.result?.instrumentGuide;
  console.log("MASTER guide:", JSON.stringify(g, null, 1));
  ck("D1 a master insert is notApplicable — no empty state for a question nobody asked",
     g?.state === "notApplicable", `state=${g?.state}`);
  ck("D2 notApplicable draws neither marks nor a row",
     (g?.markCount ?? -1) === 0 && g?.showsRow === false,
     JSON.stringify({ mc: g?.markCount, showsRow: g?.showsRow }));

  await cmd("debug.effectEditor", { close: true });
} catch (e) {
  fail++; failures.push(`EXCEPTION ${e.message}`);
  console.log("EXCEPTION", e.stack);
} finally {
  try { ws?.close(); } catch { /* ignore */ }
  stopStaging();
}
console.log(`\n=== m23-o2 probe smoke: ${pass} pass / ${fail} fail ===`);
if (failures.length) console.log(failures.join("\n"));
process.exit(fail === 0 ? 0 : 1);
