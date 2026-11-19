#!/usr/bin/env node
// p2-sing-e part 2 — THE SINGING VERBS, END TO END, IN A REAL STAGING APP.
//
// What the Swift suites cannot see: the app's OWN wiring (DAWProApp.swift) —
// the ONE SingJobCoordinator, its cache folder being the manager's cacheDir,
// the presence card's "sing-" routing, the launch-time consent flag, the
// lifecycle registration of the singing engine — reached over the real control
// socket. The engine is the STUB facade (`SING_USE_STUB=1`, scripts/sing/
// stub_server.py through run.sh, the product's own launch path) on an
// EPHEMERAL loopback port; the real SoulX engine is never started.
//
// ⚠️ PORT 17695 ONLY (the _staging.mjs guard). 17600 is the user's live app.
// ⚠️ The staging profile is isolated (DAWPRO_PROFILE_ROOT, set by
//    startStaging), so voices and the phrase cache land in a temp root; the
//    engine's runtime is a temp folder named SingingEngine
//    (DAWPRO_SING_RUNTIME_DIR), never ~/Library/Application Support.
// ⚠️ Teardown stops the stub through the wire (sing.sidecarStop, which
//    returns the stop evidence) and then the app pid-exact (stopStaging).
//
// Legs (each a PASS/FAIL line):
//   1. a bare melody: clip.setLyrics stores (one undo step), clip.getLyrics
//      reads the same words back, a refusal reads "<code>: <sentence>";
//   2. sing.render {dryRun} plans and stores nothing;
//   3. sing.installEngine from the wire ASKS (awaitingUserConsent) — the stub
//      runtime is incomplete, so a real app would offer to repair it — and
//      sing.cancelInstall withdraws the request: nothing downloads;
//   4. sing.render → poll sing.jobStatus → done; a new track is in the song;
//      edit.undo twice restores the track count;
//   5. sing.sidecarStop proves the stop (stopped, portFree, probeUnreachable);
//   6. sing.listVoices lists the built-in singer; sing.openVoiceRecorder
//      refuses singNoWindow until item p2-sing-f registers the recorder;
//   7. project.transpose {dryRun} answers without moving anything.
//
// Exit: verdict() — 0 all legs passed, non-zero otherwise.
//
// NOT RUN by W8-SE2 (the user was at the Mac: no staging app that round).

import { createServer } from "node:net";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { ROOT, buildOrAbort, startStaging, stopStaging, connect, verdict, sleep } from "./_staging.mjs";

const GATE = "p2sing-e-wire";

/** A free loopback port for the stub engine (bind to 0, read it, close). */
function freePort() {
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.once("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

const root = mkdtempSync(join(tmpdir(), "p2sing-e-wire-"));
const runtime = join(root, "SingingEngine"); // the uninstall guard requires this folder name
mkdirSync(runtime, { recursive: true });
writeFileSync(join(runtime, "install.json"), "{}");
const enginePort = await freePort();

buildOrAbort({ label: "building staging binary (p2-sing-e wire)…" });
startStaging({
  gate: GATE,
  env: {
    // Named outright rather than left to the manager's walk-up from the binary (the staging launch runs an alias).
    DAWPRO_SING_SCRIPTS_DIR: join(ROOT, "scripts", "sing"),
    DAWPRO_SING_RUNTIME_DIR: runtime,
    SING_API_URL: `http://127.0.0.1:${enginePort}`,
    SING_USE_STUB: "1",
    // DAWPRO_SING_TEST_AUTO_CONSENT deliberately NOT set: leg 3 proves the ask.
  },
});
const ws = await connect();

let n = 0;
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = `p2sing${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), timeoutMs);
    const h = (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id !== id) return;
      clearTimeout(t);
      ws.removeEventListener("message", h);
      res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id, command, params }));
  });
}

let pass = 0;
let fail = 0;
const ck = (name, cond, extra) => {
  if (cond) {
    pass++;
    console.log("PASS " + name);
  } else {
    fail++;
    console.log("FAIL " + name + (extra !== undefined ? " :: " + JSON.stringify(extra) : ""));
  }
};

let r;
try {
  r = await cmd("project.new", { discardChanges: true });
  ck("project.new (a fresh, unsaved staging song)", r.ok, r.error);
  r = await cmd("track.add", { name: "SE2 sing E2E melody", kind: "instrument" });
  ck("track.add (instrument)", r.ok, r.error);
  const trackId = r.result?.id;
  // Eight quarter notes, C4 up to C5: two lines of four words.
  const pitches = [60, 62, 64, 65, 67, 69, 71, 72];
  r = await cmd("clip.addMIDI", {
    trackId,
    name: "SE2 sing E2E melody",
    atBeat: 0,
    lengthBeats: 8,
    notes: pitches.map((pitch, i) => ({ pitch, startBeat: i, lengthBeats: 0.9, velocity: 90 })),
  });
  ck("clip.addMIDI (8 notes)", r.ok, r.error);
  const clipId = r.result?.id;
  const lyrics = "row row row your\nboat gently down the";

  // 1. lyrics
  r = await cmd("clip.setLyrics", { clipId, text: lyrics });
  ck("1 clip.setLyrics stores", r.ok && r.result?.stored === true && r.result?.changed === true, r.error ?? r.result);
  ck("1 eight words on eight notes", r.result?.assignment?.words?.length === 8, r.result?.assignment);
  r = await cmd("clip.getLyrics", { clipId });
  ck("1 clip.getLyrics reads the same text back", r.ok && r.result?.text === lyrics, r.error ?? r.result?.text);
  r = await cmd("clip.setLyrics", { clipId, text: "one two three four five six seven eight nine" });
  ck("1 too many words refuses as \"<code>: <sentence>\"",
     !r.ok && /^lyricsTooManyWords: /.test(r.error ?? ""), r.error);

  // 2. dry run
  const before = (await cmd("project.snapshot")).result?.tracks?.length;
  r = await cmd("sing.render", { clipId, dryRun: true });
  ck("2 sing.render {dryRun} plans", r.ok && r.result?.dryRun === true && Array.isArray(r.result?.plan?.units),
     r.error ?? r.result);
  ck("2 the dry run added no track", (await cmd("project.snapshot")).result?.tracks?.length === before);

  // 3. consent
  r = await cmd("sing.installEngine");
  ck("3 sing.installEngine from the wire ASKS",
     r.ok && r.result?.state === "awaitingUserConsent", r.error ?? r.result);
  r = await cmd("sing.sidecarStatus");
  ck("3 status shows the waiting request", r.ok && (r.result?.consent?.length ?? 0) === 1, r.error ?? r.result);
  r = await cmd("sing.cancelInstall");
  ck("3 sing.cancelInstall withdraws it", r.ok && typeof r.result?.withdrewRequestId === "string",
     r.error ?? r.result);

  // 4. a take, start to finish
  r = await cmd("sing.render", { clipId, octaveShift: 0, seed: 7 });
  ck("4 sing.render returns a job at once", r.ok && /^sing-/.test(r.result?.jobId ?? ""), r.error ?? r.result);
  const jobId = r.result?.jobId;
  let status;
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    status = (await cmd("sing.jobStatus", { jobId })).result;
    if (["done", "failed", "cancelled"].includes(status?.state)) break;
    await sleep(1000);
  }
  ck("4 the job finishes done", status?.state === "done", status?.error ?? status?.stageText);
  const afterTracks = (await cmd("project.snapshot")).result?.tracks?.length;
  ck("4 one new track holds the take", afterTracks === before + 1, { before, afterTracks });
  r = await cmd("edit.undo");
  ck("4 the first undo removes the take", r.ok, r.error);
  ck("4 the track count is back", (await cmd("project.snapshot")).result?.tracks?.length === before);
  r = await cmd("sing.jobStatus");
  ck("4 sing.jobStatus with no id lists the job", r.ok && r.result?.jobs?.some((j) => j.jobId === jobId),
     r.error ?? r.result);

  // 5. stop, with evidence
  r = await cmd("sing.sidecarStop", {}, 200000);
  ck("5 sing.sidecarStop proves the stop",
     r.ok && r.result?.stopped === true && r.result?.evidence?.portFree === true &&
       r.result?.evidence?.probeUnreachable === true,
     r.error ?? r.result);

  // 6. voices and the recorder seam
  r = await cmd("sing.listVoices");
  ck("6 the built-in singer is listed first", r.ok && r.result?.voices?.[0]?.id === "builtin-1", r.error ?? r.result);
  r = await cmd("sing.openVoiceRecorder");
  ck("6 no recorder registered yet → singNoWindow", !r.ok && /^singNoWindow: /.test(r.error ?? ""), r.error);

  // 7. the song's key, as a dry run
  r = await cmd("project.transpose", { semitones: 2, dryRun: true });
  ck("7 project.transpose {dryRun} answers", r.ok, r.error);
} catch (error) {
  fail++;
  console.log("FAIL the run threw :: " + (error?.message ?? String(error)));
} finally {
  // Belt and braces: the stub is a child of the staging app's manager; stop it through the wire first (no-op if
  // already stopped), then the app pid-exact.
  try { await cmd("sing.sidecarStop", { cancelJobs: true }, 200000); } catch { /* reported above if it matters */ }
  stopStaging(GATE);
}

verdict({ ran: pass + fail, failed: fail });
