/**
 * mcp-log.test.ts — coverage for append-only MCP call logging (m23-ca,
 * src/mcp-log.ts).
 *
 * Same stub-bridge pattern as clip-time-range.test.ts / connection-info.test.ts
 * (no live app, no real WebSocket): `DawBridge.prototype.send` and
 * `DawBridge.prototype.isConnected` are monkeypatched before `src/server.ts`
 * is imported, so the REAL `McpServer` (with the REAL patched `registerTool`
 * seam from `installMcpLogging`) is driven over an in-memory transport.
 *
 * `DAWPRO_MCP_LOG_DIR` is set to a throwaway temp directory BEFORE importing
 * `src/server.js` — `installMcpLogging` resolves and announces the log path
 * at that import, so this must happen first, exactly like the existing
 * pattern of patching `DawBridge.prototype` before import. This also keeps
 * the suite from writing into the real `~/Library/Logs/DAWPro/mcp/`.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, mkdtempSync, rmSync } from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

const tempLogDir = mkdtempSync(join(tmpdir(), "dawpro-mcp-log-test-"));
process.env["DAWPRO_MCP_LOG_DIR"] = tempLogDir;

import { DawBridge } from "../src/bridge.js";

// ---------------------------------------------------------------------------
// Stub the bridge BEFORE any tool call runs — see clip-time-range.test.ts for
// why patching the prototype here is safe and server-wide. `isConnected` is
// stubbed too (`connected`, toggled per test) since the real DawBridge never
// opens a socket in this suite; mcp-log.ts's before-capture gate reads it.
// ---------------------------------------------------------------------------

interface RecordedCall {
  command: string;
  params: Record<string, unknown>;
}

let calls: RecordedCall[];
let queuedResult: unknown;
let queuedError: Error | undefined;
let connected = false;
let overviewStub: unknown;

DawBridge.prototype.isConnected = function (): boolean {
  return connected;
};

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  if (command === "project.overview") {
    return overviewStub;
  }
  if (queuedError) {
    const err = queuedError;
    queuedError = undefined;
    throw err;
  }
  return queuedResult;
};

const { server } = await import("../src/server.js");
const { instrumentedToolNames, mcpLogFilePath } = await import("../src/mcp-log.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "mcp-log-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
  rmSync(tempLogDir, { recursive: true, force: true });
});

beforeEach(() => {
  calls = [];
  queuedResult = undefined;
  queuedError = undefined;
  connected = false;
  overviewStub = { transport: {}, master: {}, tracks: [] };
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function readLogLines(): any[] {
  const path = mcpLogFilePath();
  if (!existsSync(path)) return [];
  const raw = readFileSync(path, "utf8");
  return raw
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function lastLogLine(): any {
  const lines = readLogLines();
  assert.ok(lines.length > 0, "expected at least one log line");
  return lines[lines.length - 1];
}

// ---------------------------------------------------------------------------
// Instrumentation coverage (both registration paths)
// ---------------------------------------------------------------------------

test("both registration paths are instrumented: 192 total, empty symmetric difference vs tools/list", async () => {
  const instrumented = instrumentedToolNames();
  assert.equal(instrumented.length, 192, `expected 192 instrumented registrations, got ${instrumented.length}`);

  const listed = await client.listTools();
  const listedNames = new Set(listed.tools.map((t) => t.name));
  const instrumentedSet = new Set(instrumented);

  const missingFromInstrumented = [...listedNames].filter((n) => !instrumentedSet.has(n)).sort();
  const extraInInstrumented = [...instrumentedSet].filter((n) => !listedNames.has(n)).sort();

  assert.deepEqual(missingFromInstrumented, [], "tools/list names missing from the instrumented set");
  assert.deepEqual(extraInInstrumented, [], "instrumented names not present in tools/list");
});

// ---------------------------------------------------------------------------
// Breadth: the count test (192, empty symmetric difference) proves the
// wrapped SET of names is right; it does NOT prove every registration path's
// handler actually runs the wrapper. These three cover the three call
// SHAPES the SDK produces (mcp.js `executeToolHandler`): a mutating,
// `.strict()`-wrapped tool; a direct read-only tool with an EMPTY
// inputSchema (`{}`, still truthy — handler(args, extra)); and a direct
// read-only tool with NO inputSchema key AT ALL (handler(extra) only, one
// argument) — the one shape nothing else in this file's tests reaches.
// ---------------------------------------------------------------------------

test("both registration paths, including the no-inputSchema direct case, each write exactly one log line", async () => {
  queuedResult = { ok: true };

  const cases: Array<{ name: string; arguments: Record<string, unknown> }> = [
    { name: "track_set_volume", arguments: { trackId: randomUUID(), volume: 0.5 } }, // local `registerTool` wrapper (mutating, .strict())
    { name: "marker_list", arguments: {} }, // direct server.registerTool, inputSchema: {} (empty but present)
    { name: "edit_history", arguments: {} }, // direct server.registerTool, NO inputSchema key at all
  ];

  for (const { name, arguments: args } of cases) {
    const before = readLogLines().length;
    const result = await client.callTool({ name, arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok(!(result as any).isError, `${name} should succeed against the stub`);
    const lines = readLogLines();
    assert.equal(lines.length, before + 1, `${name}: exactly one new log line`);
    const entry = lines[lines.length - 1];
    assert.equal(entry.tool, name);
    assert.equal(typeof entry.durationMs, "number");
  }
});

test("marker_list (direct path, empty inputSchema {}): params is logged as an empty object, not absent", async () => {
  queuedResult = { markers: [] };
  await client.callTool({ name: "marker_list", arguments: {} });
  const entry = lastLogLine();
  assert.equal(entry.tool, "marker_list");
  assert.ok("params" in entry, "an empty-but-PRESENT inputSchema still logs a params key");
  assert.deepEqual(entry.params, {});
});

test("edit_history (direct path, no inputSchema at all): params is genuinely absent, never a fabricated {}", async () => {
  queuedResult = { undo: [], redo: [], canUndo: false, canRedo: false };
  await client.callTool({ name: "edit_history", arguments: {} });
  const entry = lastLogLine();
  assert.equal(entry.tool, "edit_history");
  assert.equal(entry.mutating, false);
  // The SDK calls handler(extra) only for this shape (mcp.js
  // `executeToolHandler`) — hasInputSchema is false, so `params` must be
  // logged as truly absent (JSON.stringify drops an `undefined` value), not
  // an empty-object guess that would misrepresent what the tool actually
  // received.
  assert.ok(!("params" in entry), "no params key when the tool has no inputSchema at all");
});

// ---------------------------------------------------------------------------
// One line per call, response + duration present
// ---------------------------------------------------------------------------

test("a call writes exactly one well-formed JSONL line, with response and duration present", async () => {
  const before = readLogLines().length;
  const trackId = randomUUID();
  queuedResult = { id: trackId, volume: 0.5 };

  await client.callTool({ name: "track_set_volume", arguments: { trackId, volume: 0.5 } });

  const lines = readLogLines();
  assert.equal(lines.length, before + 1, "exactly one new JSONL line for one tool call");

  const entry = lastLogLine();
  assert.equal(entry.tool, "track_set_volume");
  assert.equal(entry.mutating, true);
  assert.equal(entry.ok, true);
  assert.ok("result" in entry, "the response is present");
  assert.deepEqual(entry.result, { id: trackId, volume: 0.5 });
  assert.equal(typeof entry.durationMs, "number");
  assert.ok(entry.durationMs >= 0);
  assert.equal(typeof entry.ts, "string");
  assert.ok(!Number.isNaN(Date.parse(entry.ts)), "ts is a parseable ISO timestamp");
  assert.ok("before" in entry, "a before-capture attempt (captured or not) is always recorded");
});

// ---------------------------------------------------------------------------
// Error results
// ---------------------------------------------------------------------------

test("an error result is logged as an error, and the tool call still returns normally", async () => {
  queuedError = new Error("app not running — start DAW Pro or run `swift run DAWApp`");
  const trackId = randomUUID();

  const result = await client.callTool({ name: "track_set_volume", arguments: { trackId, volume: 0.5 } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the tool call itself still returns a normal MCP error result");

  const entry = lastLogLine();
  assert.equal(entry.tool, "track_set_volume");
  assert.equal(entry.ok, false);
  assert.match(entry.error, /app not running/);
});

// ---------------------------------------------------------------------------
// Redaction — positive control
// ---------------------------------------------------------------------------

test("redaction: a fake API-key-shaped secret in a declared free-text field never reaches the log, and a sibling declared field survives", async () => {
  const fakeSecret = "sk-ant-api03-FAKESECRETFAKESECRETFAKESECRETFAKESECRET1234";
  queuedResult = { id: randomUUID(), name: "irrelevant" };

  await client.callTool({
    name: "track_add",
    // `name` is a declared free-text field (not named "key"/"token"/etc) —
    // this is the real leak vector: a secret pasted into ordinary content,
    // which a key-name-only redactor would miss entirely.
    arguments: { name: `notes: key=${fakeSecret}`, kind: "bus" },
  });

  const entry = lastLogLine();
  const serialized = JSON.stringify(entry);
  assert.ok(!serialized.includes(fakeSecret), "the fake secret must not appear anywhere in the log line");
  assert.ok(serialized.includes("[REDACTED]"), "the redaction marker is present in its place");
  // Sibling declared field: proves this isn't a redactor that blanks
  // everything (which would pass the assertion above trivially).
  assert.equal(entry.params.kind, "bus", "a sibling declared field survives redaction unchanged");
});

// ---------------------------------------------------------------------------
// Large-blob truncation
// ---------------------------------------------------------------------------

test("a large blob field is reduced to hash + length rather than inlined", async () => {
  const bigName = "x".repeat(5000);
  queuedResult = { id: randomUUID() };

  await client.callTool({ name: "track_add", arguments: { name: bigName, kind: "audio" } });

  const entry = lastLogLine();
  const nameField = entry.params.name;
  assert.equal(typeof nameField, "object");
  assert.equal(nameField.__truncated, true);
  assert.equal(nameField.length, 5000);
  const expectedHash = createHash("sha256").update(bigName, "utf8").digest("hex");
  assert.equal(nameField.sha256, expectedHash);
  const serialized = JSON.stringify(entry);
  assert.ok(!serialized.includes(bigName), "the raw blob is never inlined in the log line");
});

// ---------------------------------------------------------------------------
// Before-capture: connected bridge -> real narrow value, no re-entrance
// ---------------------------------------------------------------------------

test("before-capture: a connected bridge yields a real narrow before-value (the pre-mutation volume), from exactly one bridge read", async () => {
  connected = true;
  const trackId = randomUUID();
  overviewStub = {
    transport: { tempoBPM: 120, isPlaying: false },
    master: { volume: 1.0 },
    tracks: [{ id: trackId, name: "Lead Vocal", volume: 0.8, pan: 0, muted: false, soloed: false }],
  };
  queuedResult = { id: trackId, volume: 0.5 };

  const before = readLogLines().length;
  await client.callTool({ name: "track_set_volume", arguments: { trackId, volume: 0.5 } });

  const lines = readLogLines();
  assert.equal(
    lines.length,
    before + 1,
    "exactly one log line for one tool call — the internal before-read must never itself be logged (re-entrance guard)"
  );

  const entry = lastLogLine();
  assert.equal(entry.before.captured, true);
  assert.equal(entry.before.source, "project.overview");
  assert.equal(entry.before.narrowScope, "track");
  assert.equal(entry.before.narrow.volume, 0.8, "captures the PRE-mutation volume, not the new 0.5 the call set");
  assert.equal(typeof entry.before.fullHash, "string");
  assert.equal(entry.before.fullHash.length, 64, "sha256 hex digest");
  assert.ok(entry.before.fullBytes > 0);
  assert.equal(typeof entry.before.captureMs, "number");

  // Two bridge calls happened (the before-read, then the real mutation), but
  // only ONE was an actual MCP tool invocation — the distinction the
  // preceding assertion (one log line) is checking.
  assert.equal(calls.filter((c) => c.command === "project.overview").length, 1);
  assert.equal(calls.filter((c) => c.command === "track.setVolume").length, 1);
});

test("before-capture: the master-fader case the item exists for — mixer_set_master_volume narrows to transport+master", async () => {
  connected = true;
  overviewStub = {
    transport: { tempoBPM: 120, isPlaying: true },
    master: { volume: 1.0097 },
    tracks: [],
  };
  queuedResult = { volume: 1.0762 };

  await client.callTool({ name: "mixer_set_master_volume", arguments: { volume: 1.0762 } });

  const entry = lastLogLine();
  assert.equal(entry.before.captured, true);
  assert.equal(entry.before.narrowScope, "transport+master");
  assert.equal(
    entry.before.narrow.master.volume,
    1.0097,
    "answers exactly the motivating question: what was the master fader BEFORE this call"
  );
  assert.deepEqual(entry.result, { volume: 1.0762 });
});

// ---------------------------------------------------------------------------
// Before-capture: honest partial coverage — explicit false + reason
// ---------------------------------------------------------------------------

test("before-capture: bridge not connected yields an explicit beforeCaptured:false with a reason, never a silently missing field", async () => {
  connected = false;
  const trackId = randomUUID();
  queuedResult = { id: trackId };

  await client.callTool({ name: "track_set_volume", arguments: { trackId, volume: 0.5 } });

  const entry = lastLogLine();
  assert.equal(entry.before.captured, false);
  assert.equal(entry.before.reason, "bridge not connected");
});

test("before-capture: a read-only tool never attempts a before-read, even with a connected bridge", async () => {
  connected = true;
  queuedResult = { transport: {}, master: {}, tracks: [] };
  const callsBefore = calls.length;

  await client.callTool({ name: "project_snapshot", arguments: {} });

  const entry = lastLogLine();
  assert.equal(entry.mutating, false);
  assert.equal(entry.before.captured, false);
  assert.equal(entry.before.reason, "read-only tool");
  assert.equal(calls.length, callsBefore + 1, "no extra project.overview read for a read-only tool");
});

test("before-capture: a mutating tool with no backing wire command (generate_lyrics) is never attempted", async () => {
  const savedAnthropic = process.env["ANTHROPIC_API_KEY"];
  const savedOpenAI = process.env["OPENAI_API_KEY"];
  delete process.env["ANTHROPIC_API_KEY"];
  delete process.env["OPENAI_API_KEY"];
  try {
    connected = true;
    const callsBefore = calls.length;

    const result = await client.callTool({ name: "generate_lyrics", arguments: { theme: "a rainy Tuesday" } });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, "no provider key configured — the call errors, which is fine here");
    const entry = lastLogLine();
    assert.equal(entry.tool, "generate_lyrics");
    assert.equal(entry.mutating, true);
    assert.equal(entry.before.captured, false);
    assert.match(entry.before.reason, /no backing wire command/);
    assert.equal(calls.length, callsBefore, "generate_lyrics never touches the DAW bridge at all, before-capture included");
  } finally {
    if (savedAnthropic === undefined) delete process.env["ANTHROPIC_API_KEY"];
    else process.env["ANTHROPIC_API_KEY"] = savedAnthropic;
    if (savedOpenAI === undefined) delete process.env["OPENAI_API_KEY"];
    else process.env["OPENAI_API_KEY"] = savedOpenAI;
  }
});

test("before-capture: DAWPRO_MCP_LOG_BEFORE=0 disables it even on a connected bridge", async () => {
  const saved = process.env["DAWPRO_MCP_LOG_BEFORE"];
  process.env["DAWPRO_MCP_LOG_BEFORE"] = "0";
  try {
    connected = true;
    const trackId = randomUUID();
    queuedResult = { id: trackId };
    const callsBefore = calls.length;

    await client.callTool({ name: "track_set_volume", arguments: { trackId, volume: 0.5 } });

    const entry = lastLogLine();
    assert.equal(entry.before.captured, false);
    assert.match(entry.before.reason, /DAWPRO_MCP_LOG_BEFORE=0/);
    assert.equal(calls.length, callsBefore + 1, "only the real mutating call, no before-read");
  } finally {
    if (saved === undefined) delete process.env["DAWPRO_MCP_LOG_BEFORE"];
    else process.env["DAWPRO_MCP_LOG_BEFORE"] = saved;
  }
});
