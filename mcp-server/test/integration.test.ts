/**
 * integration.test.ts — end-to-end MCP integration suite.
 *
 * Unlike audit-tools.test.ts (in-memory transport, `tools/list` only, no
 * app), this suite drives the REAL wire: an SDK `Client` talks to the
 * compiled MCP server over `StdioClientTransport` (spawning
 * `node dist/index.js`), which in turn bridges over the control-protocol
 * WebSocket to a REAL, spawned `DAWApp` binary. It regression-pins the two
 * bugs fixed alongside this suite:
 *
 *  - bug-1 (src/server.ts `textResult`): void-result tools (e.g.
 *    track_set_volume, transport_play) used to serialize an invalid
 *    `{type:"text", text: undefined}` content item, which the CLIENT's own
 *    result-schema validation rejected with "-32602: Invalid tools/call
 *    result" even though the app-side command had already executed. Fixed
 *    to read the literal string "ok".
 *  - bug-2 (src/bridge.ts `DawBridge.send`): a flat 5s request timeout ate
 *    long renders (`render.bounce`/`render.measureLoudness` can take ~25s
 *    wall for a full-length mix) — the reply arrived after the bridge had
 *    already given up and discarded it. Fixed with a 180s timeout for
 *    `LONG_RUNNING_COMMANDS`.
 *
 * SKIPS ENTIRELY (never a silent pass — see `test.skip`-style handling
 * below) if the app binary can't be found: set `DAWPRO_APP_BINARY` to
 * override the default `<repo>/.build/debug/DAWApp` location, or build it
 * first with `swift build`.
 *
 * Loopback-only, port 17690 (never the app's default 17600, so this suite
 * can run alongside a normal dev instance of the app). Teardown is
 * try/finally at every level so a failure never leaves a stray DAWApp
 * process running.
 */

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, type ChildProcess } from "node:child_process";
import { connect } from "node:net";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

// ---------------------------------------------------------------------------
// Locating the mcp-server package root and the app binary (see
// test/audit-tools.test.ts for the same walk-up-to-package.json pattern —
// duplicated here, not imported, so this file has no dependency on the
// audit's internals).
// ---------------------------------------------------------------------------

function findMcpServerRoot(startDir: string): string {
  let dir = startDir;
  for (let i = 0; i < 12; i++) {
    const candidate = join(dir, "package.json");
    if (existsSync(candidate)) {
      try {
        const pkg = JSON.parse(readFileSync(candidate, "utf8")) as { name?: string };
        if (pkg.name === "daw-pro-mcp") return dir;
      } catch {
        // Not JSON, or unreadable — keep walking up.
      }
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error(
    `Could not locate the mcp-server/ package root by walking up from ${startDir}. ` +
      "This test expects to live somewhere under mcp-server/ (source or compiled)."
  );
}

const here = dirname(fileURLToPath(import.meta.url));
const mcpServerRoot = findMcpServerRoot(here);
const repoRoot = join(mcpServerRoot, "..");

const TEST_PORT = "17690";
const PORT_POLL_TIMEOUT_MS = 20000;
const PORT_POLL_INTERVAL_MS = 200;

const DEFAULT_APP_BINARY = join(repoRoot, ".build", "debug", "DAWApp");
const APP_BINARY = process.env["DAWPRO_APP_BINARY"] || DEFAULT_APP_BINARY;

const SKIP_REASON = existsSync(APP_BINARY)
  ? undefined
  : `DAW Pro app binary not found at "${APP_BINARY}" (set DAWPRO_APP_BINARY to point at a built ` +
    "DAWApp, or build it first with `swift build`). Skipping the whole MCP integration suite " +
    "(test/integration.test.ts) — see docs/ARCHITECTURE.md's MCP section for what this suite spawns.";

if (SKIP_REASON) {
  console.error(`[integration.test] ${SKIP_REASON}`);
}

// ---------------------------------------------------------------------------
// App + client lifecycle — spawned once for the whole file, torn down
// robustly (try/finally) whether setup succeeds, a test fails, or the whole
// process is interrupted.
// ---------------------------------------------------------------------------

let appProcess: ChildProcess | undefined;
let client: Client | undefined;

function waitForControlPort(port: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const socket = connect({ host: "127.0.0.1", port });
      socket.once("connect", () => {
        socket.removeAllListeners();
        socket.end();
        resolve();
      });
      socket.once("error", () => {
        socket.removeAllListeners();
        socket.destroy();
        if (Date.now() >= deadline) {
          reject(
            new Error(
              `Timed out after ${timeoutMs}ms waiting for the DAW app's control port ` +
                `127.0.0.1:${port} to open. Is "${APP_BINARY}" runnable on this machine?`
            )
          );
          return;
        }
        setTimeout(attempt, PORT_POLL_INTERVAL_MS);
      });
    };
    attempt();
  });
}

/** SIGTERM, escalating to SIGKILL after 5s if the process hasn't exited. */
async function killApp(): Promise<void> {
  const proc = appProcess;
  appProcess = undefined;
  if (!proc || proc.exitCode !== null || proc.signalCode !== null) return;
  await new Promise<void>((resolve) => {
    const forceKillTimer = setTimeout(() => {
      try {
        proc.kill("SIGKILL");
      } catch {
        // already gone
      }
    }, 5000);
    proc.once("exit", () => {
      clearTimeout(forceKillTimer);
      resolve();
    });
    try {
      proc.kill("SIGTERM");
    } catch {
      clearTimeout(forceKillTimer);
      resolve();
    }
  });
}

async function teardownAll(): Promise<void> {
  const c = client;
  client = undefined;
  if (c) {
    try {
      await c.close();
    } catch {
      // best-effort — transport/process may already be gone
    }
  }
  await killApp();
}

before(async () => {
  if (SKIP_REASON) return;
  try {
    appProcess = spawn(APP_BINARY, [], {
      env: { ...process.env, DAW_CONTROL_PORT: TEST_PORT },
      stdio: ["ignore", "ignore", "inherit"],
    });
    // Required: an unhandled 'error' event on a ChildProcess crashes the
    // process. If spawning genuinely fails (e.g. permissions), this logs
    // instead — the control-port poll below then times out with an
    // actionable message rather than the test runner dying opaquely.
    appProcess.on("error", (err) => {
      console.error(`[integration.test] DAW app process error: ${err.message}`);
    });

    await waitForControlPort(Number(TEST_PORT), PORT_POLL_TIMEOUT_MS);

    const transport = new StdioClientTransport({
      command: process.execPath,
      args: [join(mcpServerRoot, "dist", "index.js")],
      cwd: mcpServerRoot,
      env: { DAW_CONTROL_PORT: TEST_PORT },
    });
    client = new Client({ name: "integration-test-client", version: "0.0.0" });
    await client.connect(transport);
  } catch (err) {
    await teardownAll();
    throw err;
  }
});

after(async () => {
  await teardownAll();
});

// ---------------------------------------------------------------------------
// Small call helpers
// ---------------------------------------------------------------------------

interface CallToolResult {
  content: Array<{ type: string; text?: string }>;
  isError?: boolean;
  [key: string]: unknown;
}

async function callTool(name: string, args: Record<string, unknown> = {}): Promise<CallToolResult> {
  if (!client) throw new Error("client not connected — before() hook did not run or failed");
  return (await client.callTool({ name, arguments: args })) as unknown as CallToolResult;
}

/** Extract the first text content item's string, asserting the shape is valid. */
function firstText(result: CallToolResult): string {
  const first = result.content[0];
  assert.ok(first && first.type === "text", `expected a text content item, got: ${JSON.stringify(result.content)}`);
  assert.equal(typeof first.text, "string", `content[0].text should be a string, got: ${JSON.stringify(first)}`);
  return first.text as string;
}

/** Parse a JSON-object tool result's text (every tool here except the bug-1 "ok" results). */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: CallToolResult): any {
  return JSON.parse(firstText(result));
}

// ---------------------------------------------------------------------------
// Shared state across the file's (intentionally sequential — node:test's
// default concurrency is off) tests, per the brief's "use project_new
// {discardChanges:true} between groups".
// ---------------------------------------------------------------------------

let group1TrackId: string;
let sharedMidiClipId: string;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let skeletonResult: any;

// ---------------------------------------------------------------------------
// 1. tools/list count
// ---------------------------------------------------------------------------

test("tools/list returns exactly the audit-enforced tool count", { skip: SKIP_REASON }, async () => {
  const result = await client!.listTools();
  // The authoritative count is enforced by test/audit-tools.test.ts's "tool
  // count is a bijection" check (commands.length + exception-table-B size).
  // Hardcoded here (per the brief) as a fast, focused real-transport check —
  // if this drifts, audit-tools.test.ts is the source of truth for why.
  assert.equal(result.tools.length, 128);
});

// ---------------------------------------------------------------------------
// 2. project_new -> track_add -> project_snapshot
// ---------------------------------------------------------------------------

test("project_new -> track_add(instrument) -> project_snapshot shows the new track", { skip: SKIP_REASON }, async () => {
  await callTool("project_new", { discardChanges: true });
  const added = parseJSON(await callTool("track_add", { name: "Integration Test Track", kind: "instrument" }));
  assert.equal(typeof added.id, "string");
  assert.ok(added.id.length > 0, "track_add result carries a non-empty id");
  group1TrackId = added.id;

  const snapshot = parseJSON(await callTool("project_snapshot"));
  assert.ok(Array.isArray(snapshot.tracks), "project_snapshot returns a tracks array");
  assert.ok(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    snapshot.tracks.some((t: any) => t.id === group1TrackId),
    "project_snapshot lists the newly added track"
  );
});

// ---------------------------------------------------------------------------
// 3. bug-1 regression: void-result tools
// ---------------------------------------------------------------------------

test('bug-1 regression: void-result tools return a valid, non-error result reading "ok"', { skip: SKIP_REASON }, async () => {
  const calls: Array<[string, Record<string, unknown>]> = [
    ["track_set_volume", { trackId: group1TrackId, volume: 0.8 }],
    ["track_set_pan", { trackId: group1TrackId, pan: -0.3 }],
    ["transport_play", {}],
    ["transport_stop", {}],
  ];
  for (const [name, args] of calls) {
    const result = await callTool(name, args);
    assert.ok(!result.isError, `${name} should not be an error result: ${JSON.stringify(result)}`);
    const text = firstText(result);
    assert.equal(text, "ok", `${name}'s void result should read "ok" (pre-fix this would never even parse: was ${JSON.stringify(text)})`);
  }
});

// ---------------------------------------------------------------------------
// 4. clip_add_midi: inline notes normalized/sorted, server-minted ids
// ---------------------------------------------------------------------------

test("clip_add_midi creates a MIDI clip with server-normalized, sorted notes", { skip: SKIP_REASON }, async () => {
  const clip = parseJSON(
    await callTool("clip_add_midi", {
      trackId: group1TrackId,
      name: "Integration Test Riff",
      atBeat: 0,
      notes: [
        { pitch: 64, velocity: 90, startBeat: 2, lengthBeats: 1 },
        { pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1 },
        { pitch: 67, velocity: 80, startBeat: 1, lengthBeats: 1 },
      ],
    })
  );
  assert.equal(typeof clip.id, "string");
  assert.ok(Array.isArray(clip.notes) && clip.notes.length === 3, "clip carries all three notes");

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const startBeats = clip.notes.map((n: any) => n.startBeat);
  assert.deepEqual(startBeats, [0, 1, 2], "notes come back normalized and sorted by startBeat");

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const ids = new Set(clip.notes.map((n: any) => n.id));
  assert.equal(ids.size, 3, "each note got a distinct server-minted id");
  for (const noteId of ids) {
    assert.equal(typeof noteId, "string");
    assert.ok((noteId as string).length > 0);
  }

  sharedMidiClipId = clip.id;
});

// ---------------------------------------------------------------------------
// 5. macro_song_skeleton over real MCP (first real-transport exercise)
// ---------------------------------------------------------------------------

test("macro_song_skeleton(pop) over real MCP scaffolds tracks/sections/loop", { skip: SKIP_REASON }, async () => {
  const result = parseJSON(await callTool("macro_song_skeleton", { genre: "pop" }));
  skeletonResult = result;

  assert.equal(result.tracks.length, 6, "5 pop-roster tracks + the Arrangement guide track");
  assert.equal(result.tracks[result.tracks.length - 1].name, "Arrangement", "Arrangement track is listed last");
  assert.equal(
    result.arrangementTrackId,
    result.tracks[result.tracks.length - 1].id,
    "arrangementTrackId matches the last listed track's id"
  );
  assert.equal(result.loopStart, 0);
  assert.equal(result.loopEnd, 208, "pop's 8 default sections sum to 52 bars = 208 beats");
  assert.equal(result.sectionClips.length, 8);
});

// ---------------------------------------------------------------------------
// 6. mixer_apply_preset on the skeleton's Bass track
// ---------------------------------------------------------------------------

test("mixer_apply_preset(bass-tight) on the skeleton's Bass track lays down eq -> compressor", { skip: SKIP_REASON }, async () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const bass = skeletonResult.tracks.find((t: any) => t.name === "Bass");
  assert.ok(bass, "the pop skeleton created a Bass track");

  const result = parseJSON(await callTool("mixer_apply_preset", { trackId: bass.id, preset: "bass-tight" }));
  assert.equal(result.trackId, bass.id);
  assert.ok(Array.isArray(result.effects) && result.effects.length === 2, "bass-tight lays down exactly 2 effects");
  assert.equal(result.effects[0].kind, "eq", "eq processes first");
  assert.equal(result.effects[1].kind, "compressor", "compressor processes second");
});

// ---------------------------------------------------------------------------
// 7. clip_humanize: seeded determinism + seedUsed echo
// ---------------------------------------------------------------------------

test("clip_humanize is deterministic per seed and always echoes seedUsed", { skip: SKIP_REASON }, async () => {
  // Humanize needs a clip with real notes (the skeleton's Arrangement
  // section clips are empty) — reuse test 4's clip.
  const first = parseJSON(await callTool("clip_humanize", { clipId: sharedMidiClipId, seed: 42 }));
  assert.equal(first.seedUsed, 42);

  // Undo so the second call starts from the SAME base note state — humanize
  // jitters whatever the clip's CURRENT notes are, so re-humanizing an
  // already-jittered clip with the same seed would legitimately differ.
  await callTool("edit_undo");

  const second = parseJSON(await callTool("clip_humanize", { clipId: sharedMidiClipId, seed: 42 }));
  assert.equal(second.seedUsed, 42);
  assert.deepEqual(second.notes, first.notes, "same seed from the same base state reproduces identical notes");

  const unseeded = parseJSON(await callTool("clip_humanize", { clipId: sharedMidiClipId }));
  assert.equal(typeof unseeded.seedUsed, "number", "an omitted seed still echoes the seed actually drawn");
});

// ---------------------------------------------------------------------------
// 8. project_overview: compact, ids present, noteCount not notes, < 8 KB
// ---------------------------------------------------------------------------

test("project_overview stays compact: ids present, noteCount not notes, < 8 KB", { skip: SKIP_REASON }, async () => {
  const result = await callTool("project_overview");
  const text = firstText(result);
  const overview = JSON.parse(text);

  assert.ok(Array.isArray(overview.tracks) && overview.tracks.length > 0);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  for (const track of overview.tracks as any[]) {
    assert.equal(typeof track.id, "string");
    assert.ok(track.id.length > 0);
  }

  assert.ok(!text.includes('"notes"'), "project_overview must summarize note counts, never a raw notes array");
  const hasNoteCount = (overview.tracks as Array<{ clips?: Array<{ noteCount?: number }> }>).some(
    (t) => Array.isArray(t.clips) && t.clips.some((c) => typeof c.noteCount === "number")
  );
  assert.ok(hasNoteCount, "at least one MIDI clip reports noteCount");

  const byteLength = Buffer.byteLength(text, "utf8");
  assert.ok(byteLength < 8192, `project_overview should encode under 8 KB for this small project, was ${byteLength} bytes`);
});

// ---------------------------------------------------------------------------
// 9. edit_undo: one undo reverts the whole skeleton scaffold
// ---------------------------------------------------------------------------

test("edit_undo reverts macro_song_skeleton's entire scaffold in one step", { skip: SKIP_REASON }, async () => {
  await callTool("project_new", { discardChanges: true });
  const before = parseJSON(await callTool("project_snapshot"));
  const beforeCount = before.tracks.length;

  await callTool("macro_song_skeleton", { genre: "house" });
  const afterSkeleton = parseJSON(await callTool("project_snapshot"));
  assert.equal(afterSkeleton.tracks.length, beforeCount + 6, "house adds 5 roster tracks + Arrangement");

  const undoResult = parseJSON(await callTool("edit_undo"));
  assert.equal(typeof undoResult.undone, "string");
  assert.ok(undoResult.undone.length > 0);
  assert.equal(
    undoResult.snapshot.tracks.length,
    beforeCount,
    "a single edit_undo reverts the whole skeleton scaffold — the one-undo contract"
  );
});

// ---------------------------------------------------------------------------
// 10. bug-2 regression: render_measure_loudness survives a >5s render
// ---------------------------------------------------------------------------

test("bug-2 regression: render_measure_loudness survives a >5s render (used to die at the flat 5s timeout)", { skip: SKIP_REASON }, async () => {
  await callTool("project_new", { discardChanges: true });
  const skeleton = parseJSON(await callTool("macro_song_skeleton", { genre: "pop" }));
  const instrumentTracks = (skeleton.tracks as Array<{ id: string; name: string }>).filter(
    (t) => t.name === "Drums" || t.name === "Bass"
  );
  assert.equal(instrumentTracks.length, 2, "pop's skeleton has Drums and Bass instrument tracks");

  // A couple of 16-bar (64-beat) MIDI clips with real notes, so the render
  // window (below) is genuinely audible rather than trivially silent.
  const notes = Array.from({ length: 16 }, (_, i) => ({
    pitch: 48 + (i % 12),
    velocity: 100,
    startBeat: i * 4,
    lengthBeats: 3,
  }));
  for (const track of instrumentTracks) {
    await callTool("clip_add_midi", { trackId: track.id, atBeat: 0, notes });
  }

  // ~2.3x realtime offline render => ~15s audio ≈ 6.5s render wall,
  // comfortably exceeding the old flat 5s bridge timeout without wasting
  // suite time (brief: keep total suite wall < ~90s).
  const durationSeconds = 15;
  const started = Date.now();
  const measured = parseJSON(await callTool("render_measure_loudness", { fromBeat: 0, durationSeconds }));
  const elapsedMs = Date.now() - started;
  console.error(
    `[integration.test] render_measure_loudness(${durationSeconds}s audio) took ${elapsedMs}ms wall (bridge timeout is now 180000ms for this command; was 5000ms pre-fix)`
  );

  assert.ok(measured && typeof measured === "object", "the loudness report arrived at all (this call died at 5s before the fix)");
  assert.ok("measurement" in measured, "response carries a measurement object");
  assert.equal(typeof measured.durationSeconds, "number");
  assert.equal(typeof measured.sampleRate, "number");
});

// ---------------------------------------------------------------------------
// 11. Error surface through real MCP
// ---------------------------------------------------------------------------

test("error surface through real MCP: bad genre lists all genres; MIDI-on-audio-track is a readable error", { skip: SKIP_REASON }, async () => {
  const badGenre = await callTool("macro_song_skeleton", { genre: "polka" });
  assert.ok(badGenre.isError, "an invalid genre must be a tool error");
  const badGenreText = firstText(badGenre);
  for (const genre of ["pop", "house", "hip-hop", "rock", "ballad"]) {
    assert.ok(badGenreText.includes(genre), `error text should mention genre "${genre}": ${badGenreText}`);
  }

  await callTool("project_new", { discardChanges: true });
  const audioTrack = parseJSON(await callTool("track_add", { name: "Audio Only", kind: "audio" }));
  const midiOnAudio = await callTool("clip_add_midi", { trackId: audioTrack.id, notes: [] });
  assert.ok(midiOnAudio.isError, "clip_add_midi on an audio track must be a tool error");
  const midiOnAudioText = firstText(midiOnAudio);
  assert.ok(midiOnAudioText.length > 0, "error text is non-empty");
  assert.match(midiOnAudioText.toLowerCase(), /midi|instrument/, "error text should be readable/actionable");
});

// ---------------------------------------------------------------------------
// 12. render_bounce: file exists, report present, output re-measured
// ---------------------------------------------------------------------------

test("render_bounce writes a WAV file and reports re-measured output loudness", { skip: SKIP_REASON }, async () => {
  await callTool("project_new", { discardChanges: true });
  const track = parseJSON(await callTool("track_add", { name: "Bounce Source", kind: "instrument" }));
  await callTool("clip_add_midi", {
    trackId: track.id,
    atBeat: 0,
    notes: Array.from({ length: 8 }, (_, i) => ({
      pitch: 60 + i,
      velocity: 100,
      startBeat: i,
      lengthBeats: 0.9,
    })),
  });

  const tempPath = join(tmpdir(), `daw-pro-mcp-integration-${process.pid}-${Date.now()}.wav`);
  try {
    const result = parseJSON(await callTool("render_bounce", { path: tempPath, durationSeconds: 6, lufsTarget: -14 }));
    assert.equal(typeof result.path, "string");
    assert.ok(existsSync(tempPath), "render_bounce should write the WAV file to the requested path");
    assert.ok(result.report && typeof result.report === "object", "render_bounce reports a loudness report");
    assert.ok("output" in result.report, "report.output is the re-measured, post-gain loudness");
  } finally {
    if (existsSync(tempPath)) {
      rmSync(tempPath);
    }
  }
});

// ---------------------------------------------------------------------------
// 13. instrument_list_sound_banks -> track_set_instrument(soundBank gm) ->
//     project_snapshot round trip (m10-n-2 MCP half, real app + real GM bank)
// ---------------------------------------------------------------------------

test("General MIDI sound bank round-trips: list -> set gm/56 -> snapshot carries the resolved object", { skip: SKIP_REASON }, async () => {
  const banks = parseJSON(await callTool("instrument_list_sound_banks"));
  assert.ok(Array.isArray(banks.banks) && banks.banks.length > 0, "at least the built-in GM bank is listed");
  assert.equal(banks.banks[0].source, "gm", "General MIDI is always listed first");
  assert.equal(banks.banks[0].builtin, true);
  assert.equal(banks.banks[0].name, "General MIDI");

  const programs = parseJSON(await callTool("instrument_list_sound_bank_programs", { source: "gm" }));
  assert.equal(programs.namesParsed, true);
  assert.equal(programs.programs.length, 129, "128 melodic GM programs + 1 drum kit");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const trumpet = programs.programs.find((p: any) => p.program === 56 && p.bankMSB === 121);
  assert.ok(trumpet, "GM program 56/bankMSB 121 (Trumpet) is listed");
  assert.equal(trumpet.name, "Trumpet");

  await callTool("project_new", { discardChanges: true });
  const track = parseJSON(await callTool("track_add", { name: "GM Horns", kind: "instrument" }));
  const setResult = parseJSON(
    await callTool("track_set_instrument", { trackId: track.id, soundBank: { source: "gm", program: 56 } })
  );
  assert.equal(setResult.kind, "soundBank");
  assert.equal(setResult.soundBank.source, "gm");
  assert.equal(setResult.soundBank.program, 56);
  assert.equal(setResult.soundBank.bankMSB, 121, "melodic default");
  assert.equal(setResult.soundBank.name, "Trumpet — General MIDI", "server-derived display name");
  assert.ok(["pending", "ready"].includes(setResult.soundBank.status), `unexpected status: ${setResult.soundBank.status}`);

  const snapshot = parseJSON(await callTool("project_snapshot"));
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const horns = snapshot.tracks.find((t: any) => t.id === track.id);
  assert.ok(horns, "project_snapshot lists the GM Horns track");
  assert.equal(horns.instrument.soundBank.source, "gm");
  assert.equal(horns.instrument.soundBank.name, "Trumpet — General MIDI");
});
