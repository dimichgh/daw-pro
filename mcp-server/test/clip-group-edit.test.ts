/**
 * clip-group-edit.test.ts — wiring coverage for clip_remove_many /
 * clip_move_many (m23-w: the wire half of m23-g1's group delete and
 * m23-g2's group drag).
 *
 * The track-reorder.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive
 * the tools over an in-memory transport, and assert:
 *   - each tool forwards exactly `clip.removeMany {ids}` / `clip.moveMany
 *     {ids, byBeats}`, with no translation
 *   - the app's answer round-trips verbatim
 *   - the strict wrapper rejects an unknown key at the boundary (the Swift
 *     parameter name `clipIds` is the most plausible typo for `ids`; a
 *     `toStartBeat` is the most plausible typo for `byBeats`) — none of
 *     these ever reach the bridge
 *   - a missing/wrong-typed required param is rejected at the boundary
 *   - an app-side refusal (e.g. a take-group member) surfaces verbatim
 *   - the descriptions teach the clamp/all-or-nothing semantics an agent
 *     needs to not misread a partial-looking result as a bug
 *
 * Domain correctness (whole-group beat-0 clamp, non-contiguous overlap
 * resolution, permutation invariance) is proven in
 * Tests/DAWCoreTests/ClipGroupMoveTests.swift and RemoveClipsTests.swift;
 * this file is wire-boundary coverage only, never `tools/call` against a
 * real app.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

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
  client = new Client({ name: "clip-group-edit-test-client", version: "0.0.0" });
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
  assert.ok(
    first && first.type === "text",
    `expected a text content item, got: ${JSON.stringify(result.content)}`
  );
  return JSON.parse(first.text as string);
}

// ---------------------------------------------------------------------------
// clip_remove_many
// ---------------------------------------------------------------------------

test("clip_remove_many forwards {ids} verbatim and round-trips {clips}", async () => {
  const ids = [randomUUID(), randomUUID(), randomUUID()];
  const stubbed = { clips: ids.map((id) => ({ id, name: "X", startBeat: 0 })) };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "clip_remove_many", arguments: { ids } });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.removeMany");
  assert.deepEqual(calls[0]!.params, { ids });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("clip_remove_many accepts an empty ids array (a legal no-op)", async () => {
  queuedResult = { clips: [] };

  const result = await client.callTool({ name: "clip_remove_many", arguments: { ids: [] } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { ids: [] });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError, "an empty array must not be rejected at the boundary");
});

test("clip_remove_many boundary rejects: missing ids, non-UUID entries, and the clipIds typo", async () => {
  const bad: Array<Record<string, unknown>> = [
    {}, // ids is required
    { ids: "not-an-array" },
    { ids: [randomUUID(), "not-a-uuid"] },
    { clipIds: [randomUUID()] }, // the Swift/take_group param name, not the wire key
    { ids: [randomUUID()], clipIds: [randomUUID()] }, // unknown key alongside a valid one
  ];

  for (const args of bad) {
    const result = await client.callTool({ name: "clip_remove_many", arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `expected a boundary rejection for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("clip_remove_many surfaces an app-side refusal (take-group member) verbatim", async () => {
  queuedError = new Error(
    "clip belongs to take group 'Vox Takes' — edit the comp (take.setComp) or take.flatten first"
  );

  const result = await client.callTool({
    name: "clip_remove_many",
    arguments: { ids: [randomUUID(), randomUUID()] },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app refusal is a tool error");
  assert.match(r.content[0].text as string, /belongs to take group/);
});

test("clip_remove_many's description teaches the all-or-nothing contract and the returned shape", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_remove_many");
  assert.ok(tool, "clip_remove_many is listed");
  const description = tool!.description ?? "";
  assert.match(description, /ONE undo step/);
  assert.match(description, /ALL-OR-NOTHING/);
  assert.match(description, /\{clips\}/);
});

// ---------------------------------------------------------------------------
// clip_move_many
// ---------------------------------------------------------------------------

test("clip_move_many forwards {ids, byBeats} verbatim and round-trips the full response shape", async () => {
  const ids = [randomUUID(), randomUUID(), randomUUID()];
  const stubbed = {
    requestedDeltaBeats: -8,
    effectiveDeltaBeats: -2,
    clamped: true,
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: ids.map((id, i) => ({ id, name: `C${i}`, startBeat: i * 4 })),
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_move_many",
    arguments: { ids, byBeats: -8 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.moveMany");
  assert.deepEqual(calls[0]!.params, { ids, byBeats: -8 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("clip_move_many passes a negative byBeats through untouched (signed delta, not a typo)", async () => {
  queuedResult = {
    requestedDeltaBeats: -3,
    effectiveDeltaBeats: -3,
    clamped: false,
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: [],
  };

  await client.callTool({ name: "clip_move_many", arguments: { ids: [], byBeats: -3 } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { ids: [], byBeats: -3 });
});

test("clip_move_many boundary rejects: missing byBeats, non-numeric byBeats, and the toStartBeat typo", async () => {
  const id = randomUUID();
  const bad: Array<Record<string, unknown>> = [
    { ids: [id] }, // byBeats is required
    { ids: [id], byBeats: "4" }, // not a number
    { ids: [id], toStartBeat: 4 }, // the clip_move param name, not byBeats
    { byBeats: 4 }, // ids is required
    { ids: [id], byBeats: 4, snap: true }, // unknown key
  ];

  for (const args of bad) {
    const result = await client.callTool({ name: "clip_move_many", arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `expected a boundary rejection for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("clip_move_many surfaces an app-side refusal (take-group member) verbatim", async () => {
  queuedError = new Error(
    "clip belongs to take group 'Vox Takes' — edit the comp (take.setComp) or take.flatten first"
  );

  const result = await client.callTool({
    name: "clip_move_many",
    arguments: { ids: [randomUUID(), randomUUID()], byBeats: 4 },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app refusal is a tool error");
  assert.match(r.content[0].text as string, /belongs to take group/);
});

test("clip_move_many's description teaches the clamp — an agent must check clamped/effectiveDeltaBeats", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_move_many");
  assert.ok(tool, "clip_move_many is listed");
  const description = tool!.description ?? "";
  assert.match(description, /clamped/);
  assert.match(description, /effectiveDeltaBeats/);
  assert.match(description, /beat 0/);
});
