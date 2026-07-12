/**
 * clip-time-range.test.ts — round-trip coverage for clip_delete_time_range /
 * clip_insert_time_range (m10-h).
 *
 * Unlike integration.test.ts (real spawned DAWApp + real control WebSocket),
 * this suite proves the MCP <-> bridge WIRING without any live app: it
 * monkeypatches `DawBridge.prototype.send` (a prototype method, looked up at
 * CALL time — patching it here, before any tool is actually invoked, is
 * enough to intercept every `bridge.send()` the server makes, DAW-app-free)
 * so each tool call is driven through the REAL `McpServer` from `src/server.ts`
 * over an in-memory transport (the audit-tools.test.ts precedent), and
 * asserts:
 *   - the tool forwards exactly the right command name + params (clip-local
 *     beats passed through verbatim, no trackId — these two commands are
 *     clipId-only, the clip_quantize/clip_humanize precedent)
 *   - a stubbed success result round-trips back through the tool unchanged
 *   - a stubbed app-side error surfaces as an MCP tool error (isError: true)
 *     carrying the app's own message verbatim, never swallowed
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

// ---------------------------------------------------------------------------
// Stub the bridge BEFORE any tool call runs. `new DawBridge()` at
// server.ts's module scope does no networking (just stores a URL string), so
// patching the prototype here — after both imports above have run, before
// any test() body executes — safely intercepts every call server-wide.
// ---------------------------------------------------------------------------

interface RecordedCall {
  command: string;
  params: Record<string, unknown>;
}

let calls: RecordedCall[];
let queuedResult: unknown;
let queuedError: Error | undefined;

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  if (queuedError) {
    const err = queuedError;
    queuedError = undefined;
    throw err;
  }
  return queuedResult;
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "clip-time-range-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = undefined;
  queuedError = undefined;
});

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: any): any {
  const first = result.content[0];
  assert.ok(first && first.type === "text", `expected a text content item, got: ${JSON.stringify(result.content)}`);
  return JSON.parse(first.text as string);
}

// ---------------------------------------------------------------------------
// clip_delete_time_range
// ---------------------------------------------------------------------------

test("clip_delete_time_range forwards clip-local params to clip.deleteTimeRange and returns the updated clip", async () => {
  const clipId = randomUUID();
  const stubbedClip = {
    id: clipId,
    name: "Test Riff",
    startBeat: 0,
    lengthBeats: 6,
    notes: [{ id: randomUUID(), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1 }],
  };
  queuedResult = stubbedClip;

  const result = await client.callTool({
    name: "clip_delete_time_range",
    arguments: { clipId, startBeat: 2, lengthBeats: 1 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.deleteTimeRange");
  assert.deepEqual(calls[0]!.params, { clipId, startBeat: 2, lengthBeats: 1 });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedClip, "the app's response round-trips back verbatim");
});

test("clip_delete_time_range surfaces an app-side error as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    "deleteTimeRange startBeat 9 is outside clip 'Test Riff' [0, 4) — startBeat must fall within the clip"
  );

  const result = await client.callTool({
    name: "clip_delete_time_range",
    arguments: { clipId, startBeat: 9, lengthBeats: 1 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.deleteTimeRange");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(
    r.content[0].text as string,
    /startBeat must fall within the clip/,
    "the app's actionable error message passes through verbatim"
  );
});

// ---------------------------------------------------------------------------
// clip_insert_time_range
// ---------------------------------------------------------------------------

test("clip_insert_time_range forwards clip-local params to clip.insertTimeRange and returns the updated clip", async () => {
  const clipId = randomUUID();
  const stubbedClip = {
    id: clipId,
    name: "Test Riff",
    startBeat: 0,
    lengthBeats: 8,
    notes: [{ id: randomUUID(), pitch: 62, velocity: 90, startBeat: 6, lengthBeats: 1 }],
  };
  queuedResult = stubbedClip;

  const result = await client.callTool({
    name: "clip_insert_time_range",
    arguments: { clipId, atBeat: 4, lengthBeats: 2 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.insertTimeRange");
  assert.deepEqual(calls[0]!.params, { clipId, atBeat: 4, lengthBeats: 2 });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedClip, "the app's response round-trips back verbatim");
});

test("clip_insert_time_range allows atBeat equal to the clip length (append) without local validation", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId, name: "Test Riff", startBeat: 0, lengthBeats: 10, notes: [] };

  const result = await client.callTool({
    name: "clip_insert_time_range",
    arguments: { clipId, atBeat: 8, lengthBeats: 2 },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { clipId, atBeat: 8, lengthBeats: 2 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError, "a legal append-at-tail call is not rejected client-side");
});

test("clip_insert_time_range surfaces an app-side error as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error("clip abc123 is not a MIDI clip");

  const result = await client.callTool({
    name: "clip_insert_time_range",
    arguments: { clipId, atBeat: 0, lengthBeats: 1 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /not a MIDI clip/);
});
