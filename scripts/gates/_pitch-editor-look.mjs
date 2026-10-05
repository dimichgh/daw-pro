// _pitch-editor-look.mjs — the shared "open the pitch editor on a known
// vocal and look at it" harness (Wave 1 lane L1e, item X1, X-infra.json).
//
// WHY THIS EXISTS. The interaction-batch design's §12 calls for "one
// looked-at capture per item" on I2/I5/I6b/U-A/U-B/C5a/C5b, and the survey
// found the only prior recipe for that (an "i4-look" probe) lived in a PRIOR
// SESSION's /private/tmp scratchpad — gone, and never in this repo (a
// designFactsContradictedByCode entry, X-infra.json). Six lanes independently
// re-deriving "open a clip, wait for the pane, stage a gesture, capture" is
// exactly the copy-paste shape `_staging.mjs`'s own header warns about (there,
// it was the launch lifecycle; here it is the pitch-editor round trip on top
// of it). This module is the ONE home for that round trip, same spirit as
// `_staging.mjs`: SCOPE is the round trip only — each caller still writes its
// own capture paths, its own staged gestures, and its own pass/fail text.
//
// THE RECIPE (`PitchEditorDebugStaging.swift`'s own banner, mirrored here,
// never re-derived): a clip's SEED (the live, unsaved detection the pane
// draws the instant it opens) and its STORE (`clip.pitchEdits`) can
// legitimately disagree until `clip.autoCorrectPitch` has run once — after
// that the pane's `PitchEditorModel.noteTable` prefers the store
// unconditionally, so `notesAsDrawn` (the pixels) and `clip.getPitchEdits`
// (the SECOND instrument, read independently of anything drawn) converge.
// `openTunedClip` below always runs `clip.autoCorrectPitch` before opening
// the pane, for exactly that reason — a look gate that skipped it would be
// comparing a screenshot against a store that was never asked to agree with it.
//
// FIXTURE. Never a WAV committed to the repo (a binary diff for a change that
// touches none) and never the /private/tmp WAV earlier ad hoc probes used (X-
// infra.json risks: "ephemeral" — ✓ and it is a PRIOR SESSION's tmp dir, gone
// by the time a later lane would want it). `synthesizeVocalFixture` below
// regenerates a short sung-like WAV with ffmpeg's lavfi sources on every call:
// a noise burst (a consonant) followed by a three-harmonic vibrato'd tone (a
// vowel) — enough voiced, monophonic content for SwiftF0 to lock onto a pitch
// track and non-empty for `clip.autoCorrectPitch` to hand back segments.
// DETERMINISTIC: every generator carries an explicit seed or expression —
// `anoisesrc`'s default `seed=-1` reseeds PER RUN (measured: two runs with no
// seed hashed to two different files; `seed=42` hashed identically twice).
//
// WHAT THIS DOES NOT DO. It never launches with anything but `skipBuild:
// true` — this lane runs beside other Wave 1 lanes that measure build/test/
// latency TIMINGS on the SAME machine (`briefs/timing-lock-protocol.md`), and
// a look gate that triggers its own `swift build` pollutes every one of them.
// A caller that genuinely needs a fresh build owns that decision itself,
// outside this module, via `_staging.mjs` directly. It also never drives a
// real pointer — `scripts/video/screenrec` is the answer for MOTION (pinch,
// autoscroll, a brush drag); this module's `stagePitchEditorStep` only
// reaches the synthetic `debug.pitchEditor {act}` steps `Pitch
// EditorDebugStaging.swift` documents, the same "nothing in this tree can
// drive a real pointer" ceiling that file's own I0 banner states (m23-g1).
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { launchStaging, stopStaging, sleep } from "./_staging.mjs";

/** The pidfile/out-dir name this module's own launch helper uses by default.
 * A caller driving several look gates back to back may pass its own `gate`
 * name to `launchLook`/`stopLook` to keep pidfiles apart; nothing here
 * requires it. */
export const GATE = "pitch-editor-look";

// ═══════════════════════════════════════════════════════════════════════════
// FIXTURE
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Synthesise a WAV into `outDir` and return its absolute path.
 *
 * `silent: false` (the default) builds the SUNG-LIKE fixture: 0.12 s of white
 * noise (a consonant) then one or more NOTE LEGS, each three sine partials
 * (hz/2hz/3hz, weighted 1 / 0.45 / 0.22, an approximation of a voice's
 * falling harmonic series) run through ffmpeg's `vibrato` filter (5.5 Hz,
 * depth 0.4) — enough pitch wander that a note editor's vibrato/drift
 * reading has something to show. Each leg is faded 40 ms in / 60 ms out (its
 * OWN timeline, so every concat seam is click-free, not just the outer
 * edges).
 *
 * `opts.notes` — an array of `{hz, seconds}` — defaults to a SINGLE leg,
 * `[{hz: 220, seconds: 1.3}]`, unchanged from this function's first version
 * (so every existing caller keeps the same one-note fixture). Pass more than
 * one leg for a fixture with several DISTINCT notes (each becomes its own
 * `clip.autoCorrectPitch` segment — measured with 4 legs of 1.2 s: 4
 * segments, 4 `notesAsDrawn` rects).
 *
 * ⚠️ **NOT, BY ITSELF, ENOUGH FOR `contentW > viewportW`** (I6b's auto-
 * scroll-while-dragging precondition) — MEASURED, not assumed: 4 legs
 * (≈4.9 s total) laid out to `contentW: 315` inside a `viewportW: 1364` pane,
 * i.e. still ~64 px of laid-out content per SECOND of clip, at the pane's
 * default zoom. Getting past 1364 px needs roughly 21+ seconds of legs at
 * that same zoom — or fewer/shorter legs plus a zoomed-in
 * `debug.panelLayout {pitchEditorPPB: <a larger pixels-per-beat>}`
 * (`DAWProApp.swift:6047`; cheaper than a 20+ s fixture and detection pass).
 * Left as the I6b lane's own call, not solved here.
 *
 * `silent: true` builds the NEGATIVE-CONTROL fixture instead: 1.0 s of true
 * digital silence (`anullsrc`), no pitch anywhere (`opts.notes` is ignored).
 * `clip.autoCorrectPitch` on this reports `segmentCount: 0`, and the pane's
 * own analysis settles on `statusKey: "noNotes"` — never `"ready"` — which is
 * exactly the case `waitPitchEditorReady` below must fail LOUDLY on rather
 * than time out silently or, worse, resolve against a stale prior poll.
 *
 * DETERMINISM, MEASURED, NOT ASSUMED: every generator here carries an
 * explicit seed or expression. `anoisesrc`'s default `seed=-1` reseeds PER
 * RUN — two calls with no seed hashed to two different files; pinning
 * `seed=42` hashed the SAME. That was checked on the noise leg alone the
 * first time this function shipped; the full composite (noise + the default
 * single note, run twice into separate directories) was later hashed
 * end-to-end and also matched byte for byte — the claim this doc block
 * makes, not a narrower one it was never re-checked against.
 *
 * @param {string} outDir - an existing, writable directory
 * @param {object} [opts]
 * @param {boolean} [opts.silent=false]
 * @param {Array<{hz:number, seconds?:number}>} [opts.notes] - default one
 *   220 Hz / 1.3 s leg
 * @returns {string} absolute path to the written WAV
 */
export function synthesizeVocalFixture(outDir, { silent = false, notes } = {}) {
  // Named by CONTENT, not a fixed "vocal-fixture.wav" for every shape: two
  // calls with different `notes` into the same `outDir` must not silently
  // clobber the path a caller is still holding from the first (measured —
  // this file's own validation run did exactly that before this line
  // existed), and a human reading a capture's clip-name badge should be able
  // to tell a 1-note fixture from a 4-note one without re-reading the script.
  const legCount = notes && notes.length > 0 ? notes.length : 1;
  const path = join(outDir, silent ? "silent-fixture.wav"
    : legCount === 1 ? "vocal-fixture.wav" : `vocal-fixture-${legCount}notes.wav`);
  if (silent) {
    const args = [
      "-hide_banner", "-y",
      "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono",
      "-t", "1.0", "-c:a", "pcm_s16le", path,
    ];
    const r = spawnSync("ffmpeg", args, { encoding: "utf8" });
    if (r.status !== 0 || !existsSync(path)) {
      throw new Error(`synthesizeVocalFixture(silent=true): ffmpeg failed (exit ${r.status})\n`
        + `${r.stderr ?? ""}`);
    }
    return path;
  }

  const legs = notes && notes.length > 0 ? notes : [{ hz: 220, seconds: 1.3 }];
  const args = [
    "-hide_banner", "-y",
    "-f", "lavfi", "-i", "anoisesrc=color=white:duration=0.12:amplitude=0.4:seed=42",
  ];
  const filterParts = [];
  const concatLabels = ["cons"];
  filterParts.push("[0]volume=0.5[cons]");
  legs.forEach((leg, i) => {
    const hz = leg.hz;
    const seconds = leg.seconds ?? 1.3;
    const outFade = Math.max(seconds - 0.06, 0.01).toFixed(3);
    const base = 1 + i * 3; // input index of this leg's fundamental (0 is the noise burst)
    args.push(
      "-f", "lavfi", "-i", `sine=frequency=${hz}:duration=${seconds}`,
      "-f", "lavfi", "-i", `sine=frequency=${hz * 2}:duration=${seconds}`,
      "-f", "lavfi", "-i", `sine=frequency=${hz * 3}:duration=${seconds}`,
    );
    const label = `v${i}`;
    filterParts.push(
      `[${base}][${base + 1}][${base + 2}]amix=inputs=3:weights='1.0 0.45 0.22':normalize=0,`
      + `vibrato=f=5.5:d=0.4,volume=0.35,`
      + `afade=t=in:st=0:d=0.04,afade=t=out:st=${outFade}:d=0.06[${label}]`);
    concatLabels.push(label);
  });
  const concatInputs = concatLabels.map((l) => `[${l}]`).join("");
  filterParts.push(`${concatInputs}concat=n=${concatLabels.length}:v=0:a=1[out]`);
  args.push(
    "-filter_complex", filterParts.join(";"),
    "-map", "[out]", "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", path);

  const r = spawnSync("ffmpeg", args, { encoding: "utf8" });
  if (r.status !== 0 || !existsSync(path)) {
    throw new Error(`synthesizeVocalFixture: ffmpeg failed (exit ${r.status})\n${r.stderr ?? ""}`);
  }
  return path;
}

// ═══════════════════════════════════════════════════════════════════════════
// LAUNCH / TEARDOWN
// ═══════════════════════════════════════════════════════════════════════════

/**
 * `launchStaging` with `skipBuild: true` PINNED — never a caller override
 * (see this file's header). Every other option passes through unchanged.
 * @returns {Promise<{ws, out, pid, profileRoot, binary, defaultsDomain, stop:()=>void}>}
 */
export async function launchLook({ gate = GATE, binary, port, env, settleMs, attempts } = {}) {
  return launchStaging({ gate, binary, port, env, settleMs, attempts, skipBuild: true });
}

/** Pid-exact stop, re-exported so a caller never has to import `_staging.mjs`
 * just to tear this down. Never pkill/pgrep (`_staging.mjs`'s own standing
 * rule) — this delegates to the one function that reads the pidfile. */
export function stopLook(gate = GATE, pidfileOverride) {
  return stopStaging(gate, pidfileOverride);
}

/**
 * Wrap an open `ws` (from `launchLook`, or a caller's own `connect()`) in the
 * `cmd(command, params) => Promise<{id, ok, result, error}>` shape every
 * function below expects — the RAW envelope, never a wrapper that throws or
 * `process.exit()`s on a failing command: a caller driving the negative
 * control needs to see a refusal, not have the process die on it.
 */
export function makeCmd(ws) {
  let n = 0;
  return function cmd(command, params = {}) {
    return new Promise((resolve, reject) => {
      const id = `look${++n}`;
      const timer = setTimeout(() => reject(new Error(`TIMEOUT ${command}`)), 25000);
      const onMessage = (ev) => {
        let msg;
        try { msg = JSON.parse(ev.data); } catch { return; }
        if (msg.id !== id) return;
        clearTimeout(timer);
        ws.removeEventListener("message", onMessage);
        resolve(msg);
      };
      ws.addEventListener("message", onMessage);
      ws.send(JSON.stringify({ id, command, params }));
    });
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// THE ROUND TRIP
// ═══════════════════════════════════════════════════════════════════════════

/** Run one command and unwrap its result, or throw naming the step and the
 * server's own error — the shared failure shape every step of
 * `openTunedClip` uses, so a caller's stack trace always says WHICH wire call
 * refused, not just that "openTunedClip" did. */
async function step(cmd, command, params, label) {
  const r = await cmd(command, params);
  if (!r || r.ok !== true) {
    throw new Error(`${label ?? command} failed — ${JSON.stringify(r?.error ?? r ?? "no response")}`);
  }
  return r.result;
}

/**
 * The round trip this file exists for: a fresh project, one audio track, the
 * fixture imported at beat 0, `clip.autoCorrectPitch` run (this file's header
 * — the store/seed convergence), and the pane opened with
 * `view.openPitchEditor`. Throws the moment any step refuses; never returns a
 * partial result for a caller to have to notice went wrong.
 *
 * ⚠️ Does NOT wait for the pane to have drawn — call `waitPitchEditorReady`
 * next. Kept separate because a caller proving the NEGATIVE control (a clip
 * with no voiced pitch) needs `openTunedClip` to succeed structurally
 * (`segmentCount: 0` is a legitimate, non-throwing answer) while
 * `waitPitchEditorReady` is the call that must then fail loudly.
 *
 * @param {(command:string, params?:object)=>Promise<any>} cmd
 * @param {object} opts
 * @param {string} opts.fixturePath - required; the WAV to import
 * @param {string} [opts.preset] - forwarded to `clip.autoCorrectPitch`
 * @returns {Promise<{clipId:string, trackId:string, segmentCount:number,
 *   hasPitchEdits:boolean, opened:true}>}
 */
export async function openTunedClip(cmd, { fixturePath, preset } = {}) {
  if (!fixturePath) throw new Error("openTunedClip requires { fixturePath }");
  await step(cmd, "project.new", { discardChanges: true }, "project.new");
  const track = await step(cmd, "track.add",
    { name: "Look Vocal", kind: "audio" }, "track.add");
  const clip = await step(cmd, "clip.addAudio",
    { trackId: track.id, path: fixturePath, atBeat: 0 }, "clip.addAudio");
  const autoCorrectParams = preset ? { clipId: clip.id, preset } : { clipId: clip.id };
  const autoCorrect = await step(cmd, "clip.autoCorrectPitch",
    autoCorrectParams, "clip.autoCorrectPitch");
  const opened = await step(cmd, "view.openPitchEditor",
    { clipId: clip.id }, "view.openPitchEditor");
  if (opened.opened !== true) {
    throw new Error(`view.openPitchEditor did not open — reason: ${opened.reason}`);
  }
  return {
    clipId: clip.id,
    trackId: track.id,
    segmentCount: autoCorrect.segmentCount,
    hasPitchEdits: autoCorrect.hasPitchEdits,
    opened: true,
  };
}

/** `PitchEditorState.statusKey`s (`PitchEditorModel.swift`) that can NEVER
 * become `"ready"` on their own — the pane's analysis has already finished
 * and landed somewhere else. Polling these out to `timeoutMs` would still
 * eventually report the right thing, just `timeoutMs` late every single
 * time; `waitPitchEditorReady` below fails on the FIRST poll that sees one. */
const PITCH_EDITOR_TERMINAL_NON_READY = new Set(["noNotes", "engineUnavailable", "refused"]);

/**
 * Poll `debug.pitchEditor {}` until the pane has actually DRAWN something —
 * THREE instruments, not one (the m23-ap I0 lesson, `PitchEditorDebugStaging
 * .swift`'s own header): `chrome.statusKey === "ready"`,
 * `notesAsDrawn.length > 0` (the surface's own rects — what a staged
 * hover/press would actually be aimed at), and `viewport.viewportW > 0` (the
 * pane has been laid out at all, not just mounted).
 *
 * FAILS FAST on a TERMINAL non-ready state (`noNotes` / `engineUnavailable` /
 * `refused`, see `PITCH_EDITOR_TERMINAL_NON_READY`) — those can never turn
 * into `ready` by waiting longer, so this throws the moment one is seen
 * rather than spending the full `timeoutMs` finding out (a caller driving
 * several fixtures pays that timeout once per broken one). Otherwise bounded
 * and THROWS on timeout rather than returning the last poll's echo — a
 * caller wanting "still noNotes after N seconds" (the negative control)
 * should catch either throw, never inspect a partial echo that looks
 * superficially plausible.
 *
 * @param {(command:string, params?:object)=>Promise<any>} cmd
 * @param {object} [opts]
 * @param {number} [opts.timeoutMs=8000]
 * @param {number} [opts.intervalMs=200]
 * @returns {Promise<object>} the settled `debug.pitchEditor {}` echo
 */
export async function waitPitchEditorReady(cmd, { timeoutMs = 8000, intervalMs = 200 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    const r = await cmd("debug.pitchEditor", {});
    if (!r || r.ok !== true) {
      throw new Error(`waitPitchEditorReady: debug.pitchEditor failed — `
        + `${JSON.stringify(r?.error ?? r)}`);
    }
    last = r.result;
    const statusKey = last?.chrome?.statusKey;
    const ready = statusKey === "ready"
      && Array.isArray(last?.notesAsDrawn) && last.notesAsDrawn.length > 0
      && typeof last?.viewport?.viewportW === "number" && last.viewport.viewportW > 0;
    if (ready) return last;
    if (PITCH_EDITOR_TERMINAL_NON_READY.has(statusKey)) {
      throw new Error(
        `waitPitchEditorReady: the pane settled at TERMINAL state "${statusKey}" — it cannot `
        + `reach "ready" from here, so this fails now instead of waiting out the full `
        + `${timeoutMs}ms. Pane text: ${JSON.stringify(last?.chrome?.statusText)}`);
    }
    await sleep(intervalMs);
  }
  throw new Error(
    `waitPitchEditorReady: TIMED OUT after ${timeoutMs}ms — last statusKey=`
    + `${JSON.stringify(last?.chrome?.statusKey)}, notesAsDrawn=`
    + `${last?.notesAsDrawn?.length ?? "?"}, viewportW=${last?.viewport?.viewportW ?? "?"}. `
    + `Never reached "ready" and never saw a terminal state either — the pane may still be `
    + `mounting, or analysing an unusually long clip.`);
}

/**
 * Stage one `{act, ...}` step through `debug.pitchEditor` — the catalogue
 * `PitchEditorDebugStaging.swift`'s own banner documents (hover, hoverEnd,
 * press, drag, release, tool, scroll, escape, selectAll, clearSelection,
 * noteMenu, auditionSpanRender). Throws on a non-ok response: an unbalanced
 * gesture (e.g. a press already in flight) is a caller bug, never a value
 * worth returning to paper over.
 *
 * @param {(command:string, params?:object)=>Promise<any>} cmd
 * @param {object} act - e.g. `{act:"press", x, y}`
 * @returns {Promise<object>} the echo, WITH its `stage` field (the step's own ack)
 */
export async function stagePitchEditorStep(cmd, act) {
  return step(cmd, "debug.pitchEditor", act, `debug.pitchEditor ${JSON.stringify(act)}`);
}

/**
 * `view.capture` — screenshots the app's main window to a PNG. `path` should
 * be an ABSOLUTE path under the CALLER's own scratch directory (this module
 * writes nothing on its own account); omitted, the server auto-names one
 * under `NSTemporaryDirectory()/DAWPro`.
 *
 * @param {(command:string, params?:object)=>Promise<any>} cmd
 * @param {string} [path]
 * @returns {Promise<{path:string, width:number, height:number, method:string,
 *   rect:object, scale:number, appActive:boolean}>}
 */
export async function captureLook(cmd, path) {
  return step(cmd, "view.capture", path ? { path } : {}, "view.capture");
}

/**
 * The SECOND instrument (this file's header) — `clip.getPitchEdits`, the
 * STORED note table, read independently of anything the pane drew: no
 * `performEdit`, no engine call, strictly read-only. Compare its
 * `segmentCount` against a capture's `notesAsDrawn.length` — after
 * `openTunedClip` (which always runs `clip.autoCorrectPitch` first) the two
 * must agree; a disagreement there is the signal, not a flake to retry past.
 *
 * @param {(command:string, params?:object)=>Promise<any>} cmd
 * @param {string} clipId
 * @returns {Promise<object>} `{clipId, hasPitchEdits, analysisVersion,
 *   retuneMs, segmentCount, isIdentity, handEditedSinceAutoCorrect, segments,
 *   warnings}`
 */
export async function getStoredPitchEdits(cmd, clipId) {
  return step(cmd, "clip.getPitchEdits", { clipId }, "clip.getPitchEdits");
}
