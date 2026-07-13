/**
 * arrange-ergonomics.test.ts — round-trip coverage for m15-d: `clip_duplicate`,
 * `arrange_insert_bars`, `arrange_delete_bars`.
 *
 * Same stub-bridge pattern as clip-time-range.test.ts / automation-master.test.ts:
 * unlike integration.test.ts (real spawned DAWApp + real control WebSocket), this
 * suite monkeypatches `DawBridge.prototype.send` before any tool call runs, so the
 * REAL `McpServer` from `src/server.ts` is driven over an in-memory transport with
 * no live app required. Asserts:
 *   - each tool forwards exactly the right command name + params verbatim
 *   - clip_duplicate's optional `toStartBeat`/`toTrackId` forward as no value at
 *     all when omitted (the ai_copilot_send/clip_set_stretch precedent: the tool
 *     always destructures both into the literal object, so the key may be PRESENT
 *     with value `undefined`, but is absent from the JSON wire frame — that's the
 *     behavior that actually matters)
 *   - a stubbed success round-trips back through each tool unchanged
 *   - a stubbed app-side error surfaces as an MCP tool error (isError: true)
 *     carrying the app's own message verbatim, never swallowed
 *   - a zod-schema-invalid call (atBar 0, negative count, etc.) is rejected at the
 *     MCP schema layer itself — an isError result with ZERO bridge calls (the
 *     clip-time-range/automation-master client-side-rejection precedent)
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

// ---------------------------------------------------------------------------
// Stub the bridge BEFORE any tool call runs (the clip-time-range.test.ts note:
// `new DawBridge()` at server.ts module scope does no networking, so patching
// the prototype here intercepts every server-wide call, DAW-app-free).
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
  client = new Client({ name: "arrange-ergonomics-test-client", version: "0.0.0" });
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
// clip_duplicate
// ---------------------------------------------------------------------------

test("clip_duplicate forwards clipId/toStartBeat/toTrackId to clip.duplicate and returns the new clip", async () => {
  const clipId = randomUUID();
  const toTrackId = randomUUID();
  const stubbedClip = {
    id: randomUUID(),
    name: "Test Riff copy",
    startBeat: 8,
    lengthBeats: 4,
    trimmed: [],
    removed: [],
  };
  queuedResult = stubbedClip;

  const result = await client.callTool({
    name: "clip_duplicate",
    arguments: { clipId, toStartBeat: 8, toTrackId },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.duplicate");
  assert.deepEqual(calls[0]!.params, { clipId, toStartBeat: 8, toTrackId });

  assert.deepEqual(parseJSON(result as any), stubbedClip, "the app's response round-trips back verbatim");
});

test("clip_duplicate omits toStartBeat/toTrackId from the wire frame when not supplied", async () => {
  const clipId = randomUUID();
  queuedResult = { id: randomUUID(), name: "Test Riff copy", startBeat: 4, lengthBeats: 4, trimmed: [], removed: [] };

  await client.callTool({ name: "clip_duplicate", arguments: { clipId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.equal(calls[0]!.params["toStartBeat"], undefined, "an omitted toStartBeat never reaches the app as a value");
  assert.equal(calls[0]!.params["toTrackId"], undefined, "an omitted toTrackId never reaches the app as a value");
  const wire = JSON.stringify(calls[0]!.params);
  assert.equal(wire?.includes("toStartBeat"), false, "an omitted toStartBeat does not appear in the JSON wire frame");
  assert.equal(wire?.includes("toTrackId"), false, "an omitted toTrackId does not appear in the JSON wire frame");
});

test("clip_duplicate surfaces an app-side error as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error("clip abc123 is a take/comp member — flatten the take group first");

  const result = await client.callTool({ name: "clip_duplicate", arguments: { clipId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.duplicate");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /flatten the take group first/, "the app's actionable error message passes through verbatim");
});

test("clip_duplicate rejects a negative toStartBeat at the MCP schema layer, no bridge call", async () => {
  const clipId = randomUUID();

  const result = await client.callTool({
    name: "clip_duplicate",
    arguments: { clipId, toStartBeat: -1 },
  });

  assert.equal(calls.length, 0, "a schema-invalid toStartBeat never reaches the bridge");
  assert.ok((result as any).isError, "a negative toStartBeat is a client-side schema rejection");
});

test("clip_duplicate rejects a non-UUID clipId at the MCP schema layer, no bridge call", async () => {
  const result = await client.callTool({
    name: "clip_duplicate",
    arguments: { clipId: "not-a-uuid" },
  });

  assert.equal(calls.length, 0, "a schema-invalid clipId never reaches the bridge");
  assert.ok((result as any).isError, "a non-UUID clipId is a client-side schema rejection");
});

// ---------------------------------------------------------------------------
// arrange_insert_bars
// ---------------------------------------------------------------------------

test("arrange_insert_bars forwards atBar/count to arrange.insertBars and returns the shift report", async () => {
  const stubbed = { atBeat: 4, insertedBeats: 4, beatsPerBar: 4 };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "arrange_insert_bars",
    arguments: { atBar: 2, count: 1 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "arrange.insertBars");
  assert.deepEqual(calls[0]!.params, { atBar: 2, count: 1 });

  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response round-trips back verbatim");
});

test("arrange_insert_bars surfaces an app-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("arrange.insertBars is refused while recording — stop first");

  const result = await client.callTool({
    name: "arrange_insert_bars",
    arguments: { atBar: 1, count: 1 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /refused while recording — stop first/);
});

test("arrange_insert_bars rejects atBar 0 at the MCP schema layer, no bridge call", async () => {
  const result = await client.callTool({
    name: "arrange_insert_bars",
    arguments: { atBar: 0, count: 1 },
  });

  assert.equal(calls.length, 0, "a schema-invalid atBar never reaches the bridge");
  assert.ok((result as any).isError, "atBar below 1 is a client-side schema rejection");
});

test("arrange_insert_bars rejects a negative count at the MCP schema layer, no bridge call", async () => {
  const result = await client.callTool({
    name: "arrange_insert_bars",
    arguments: { atBar: 1, count: -2 },
  });

  assert.equal(calls.length, 0, "a schema-invalid count never reaches the bridge");
  assert.ok((result as any).isError, "a negative count is a client-side schema rejection");
});

test("arrange_insert_bars rejects a non-integer atBar at the MCP schema layer, no bridge call", async () => {
  const result = await client.callTool({
    name: "arrange_insert_bars",
    arguments: { atBar: 2.5, count: 1 },
  });

  assert.equal(calls.length, 0, "a schema-invalid (non-integer) atBar never reaches the bridge");
  assert.ok((result as any).isError, "a fractional atBar is a client-side schema rejection");
});

// ---------------------------------------------------------------------------
// arrange_delete_bars
// ---------------------------------------------------------------------------

test("arrange_delete_bars forwards fromBar/count to arrange.deleteBars and returns the honesty arrays", async () => {
  const removedClipId = randomUUID();
  const removedMarkerId = randomUUID();
  const stubbed = {
    fromBeat: 4,
    deletedBeats: 8,
    removedClipIds: [removedClipId],
    removedMarkerIds: [removedMarkerId],
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "arrange_delete_bars",
    arguments: { fromBar: 2, count: 2 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "arrange.deleteBars");
  assert.deepEqual(calls[0]!.params, { fromBar: 2, count: 2 });

  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response round-trips back verbatim");
});

test("arrange_delete_bars surfaces an app-side error (meter-boundary refusal) verbatim", async () => {
  queuedError = new Error(
    "arrange.deleteBars would leave a meter change off its barline at beat 12 — refused"
  );

  const result = await client.callTool({
    name: "arrange_delete_bars",
    arguments: { fromBar: 3, count: 1 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /meter change off its barline/);
});

test("arrange_delete_bars rejects fromBar 0 at the MCP schema layer, no bridge call", async () => {
  const result = await client.callTool({
    name: "arrange_delete_bars",
    arguments: { fromBar: 0, count: 1 },
  });

  assert.equal(calls.length, 0, "a schema-invalid fromBar never reaches the bridge");
  assert.ok((result as any).isError, "fromBar below 1 is a client-side schema rejection");
});

test("arrange_delete_bars rejects a negative count at the MCP schema layer, no bridge call", async () => {
  const result = await client.callTool({
    name: "arrange_delete_bars",
    arguments: { fromBar: 1, count: -1 },
  });

  assert.equal(calls.length, 0, "a schema-invalid count never reaches the bridge");
  assert.ok((result as any).isError, "a negative count is a client-side schema rejection");
});
