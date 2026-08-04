/**
 * clip-cross-track-move.test.ts — wiring coverage for clip_move_many_by_tracks /
 * clip_move_many_to_track (m23-aj-2: the WIRE half of m23-aj-1's cross-track
 * group move, `ProjectStore.moveClips(ids:byTracks:byBeats:)` /
 * `moveClips(ids:toTrackId:byBeats:)`).
 *
 * The clip-group-edit.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tools over an in-memory transport, and assert:
 *   - each tool forwards its params verbatim (`clip.moveManyByTracks
 *     {ids, byTracks, byBeats}` / `clip.moveManyToTrack {ids, toTrackId,
 *     byBeats}`), with no translation
 *   - the app's answer round-trips verbatim
 *   - the strict wrapper rejects an unknown key / wrong type at the boundary
 *     (the OTHER command's own param name is the most plausible typo)
 *   - a missing required param is rejected at the boundary
 *   - an app-side refusal (e.g. the manufactured-collision message) surfaces
 *     verbatim
 *   - the descriptions teach the facts an agent cannot infer from the schema
 *     alone: the whole-move kind refusal, the clamp, and (moveManyToTrack
 *     only) the COLLAPSE + the omitted track-delta keys
 *
 * Domain correctness (landing policy, the two-phase mechanic, the
 * manufactured-collision refusal) is proven in
 * Tests/DAWCoreTests/ClipCrossTrackMoveTests.swift; the wire encoding
 * (byTracks integrality, key omission, byte-exact error surfacing) is proven
 * in Tests/DAWControlTests/ClipCrossTrackMoveCommandTests.swift. This file is
 * MCP-boundary coverage only, never `tools/call` against a real app.
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
  client = new Client({ name: "clip-cross-track-move-test-client", version: "0.0.0" });
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
// clip_move_many_by_tracks
// ---------------------------------------------------------------------------

test("clip_move_many_by_tracks forwards {ids, byTracks, byBeats} verbatim and round-trips the response", async () => {
  const ids = [randomUUID(), randomUUID()];
  const stubbed = {
    requestedTrackDelta: 1,
    effectiveTrackDelta: 1,
    clampedTracks: false,
    requestedDeltaBeats: 0,
    effectiveDeltaBeats: 0,
    clamped: false,
    landings: ids.map((id) => ({ clipId: id, fromTrackId: randomUUID(), toTrackId: randomUUID() })),
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: ids.map((id) => ({ id, name: "X", startBeat: 0 })),
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_move_many_by_tracks",
    arguments: { ids, byTracks: 1, byBeats: 0 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.moveManyByTracks");
  assert.deepEqual(calls[0]!.params, { ids, byTracks: 1, byBeats: 0 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("clip_move_many_by_tracks: byTracks is required but byBeats is optional (omitted, not defaulted at this layer)", async () => {
  queuedResult = {
    requestedTrackDelta: -1,
    effectiveTrackDelta: -1,
    clampedTracks: false,
    requestedDeltaBeats: 0,
    effectiveDeltaBeats: 0,
    clamped: false,
    landings: [],
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: [],
  };

  await client.callTool({ name: "clip_move_many_by_tracks", arguments: { ids: [], byTracks: -1 } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { ids: [], byTracks: -1, byBeats: undefined });
});

test("clip_move_many_by_tracks accepts an empty ids array (a legal no-op)", async () => {
  queuedResult = {
    requestedTrackDelta: 1,
    effectiveTrackDelta: 0,
    clampedTracks: true,
    requestedDeltaBeats: 0,
    effectiveDeltaBeats: 0,
    clamped: false,
    landings: [],
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: [],
  };

  const result = await client.callTool({
    name: "clip_move_many_by_tracks",
    arguments: { ids: [], byTracks: 1 },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError, "an empty array must not be rejected at the boundary");
});

test("clip_move_many_by_tracks boundary rejects: missing ids, missing byTracks, non-numeric byTracks, the toTrackId typo, and an unknown key", async () => {
  const id = randomUUID();
  const bad: Array<Record<string, unknown>> = [
    { byTracks: 1 }, // ids is required
    { ids: [id] }, // byTracks is required
    { ids: [id], byTracks: "1" }, // not a number
    { ids: [id], toTrackId: randomUUID() }, // the OTHER command's param, not byTracks
    { ids: [id], byTracks: 1, snap: true }, // unknown key
  ];

  for (const args of bad) {
    const result = await client.callTool({ name: "clip_move_many_by_tracks", arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `expected a boundary rejection for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("clip_move_many_by_tracks surfaces an app-side refusal (a bus landing) verbatim", async () => {
  queuedError = new Error(
    "track kind 'bus' cannot hold this content — only audio tracks accept audio clips."
  );

  const result = await client.callTool({
    name: "clip_move_many_by_tracks",
    arguments: { ids: [randomUUID()], byTracks: 1 },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app refusal is a tool error");
  assert.match(r.content[0].text as string, /cannot hold this content/);
});

test("clip_move_many_by_tracks's description teaches the whole-move kind refusal, the clamp, and REFUSES a non-integral byTracks", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_move_many_by_tracks");
  assert.ok(tool, "clip_move_many_by_tracks is listed");
  const description = tool!.description ?? "";
  assert.match(description, /REFUSES THE WHOLE CALL/);
  assert.match(description, /bus tracks hold no clips/);
  assert.match(description, /CLAMPED/);
  assert.match(description, /landings/);
  // The byTracks param description must say non-integral is refused, not
  // rounded/truncated — the design's §9.1 corrected premise.
  const byTracksSchema = tool!.inputSchema.properties?.byTracks as { description?: string } | undefined;
  assert.match(byTracksSchema?.description ?? "", /REFUSED/);
});

// ---------------------------------------------------------------------------
// clip_move_many_to_track
// ---------------------------------------------------------------------------

test("clip_move_many_to_track forwards {ids, toTrackId, byBeats} verbatim and round-trips the response MINUS the track-delta keys", async () => {
  const ids = [randomUUID(), randomUUID()];
  const toTrackId = randomUUID();
  const stubbed = {
    clampedTracks: false,
    requestedDeltaBeats: 0,
    effectiveDeltaBeats: 0,
    clamped: false,
    landings: ids.map((id) => ({ clipId: id, fromTrackId: randomUUID(), toTrackId })),
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: ids.map((id) => ({ id, name: "X", startBeat: 0 })),
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_move_many_to_track",
    arguments: { ids, toTrackId, byBeats: 0 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.moveManyToTrack");
  assert.deepEqual(calls[0]!.params, { ids, toTrackId, byBeats: 0 });
  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed);
  assert.ok(!("requestedTrackDelta" in parsed), "requestedTrackDelta must not round-trip a phantom key");
  assert.ok(!("effectiveTrackDelta" in parsed), "effectiveTrackDelta must not round-trip a phantom key");
});

test("clip_move_many_to_track accepts an empty ids array with a toTrackId still required and forwarded", async () => {
  queuedResult = {
    clampedTracks: false,
    requestedDeltaBeats: 0,
    effectiveDeltaBeats: 0,
    clamped: false,
    landings: [],
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: [],
  };
  const toTrackId = randomUUID();

  const result = await client.callTool({
    name: "clip_move_many_to_track",
    arguments: { ids: [], toTrackId },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { ids: [], toTrackId, byBeats: undefined });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError, "an empty array must not be rejected at the boundary");
});

test("clip_move_many_to_track boundary rejects: missing ids, missing toTrackId, a non-uuid toTrackId, the byTracks typo, and an unknown key", async () => {
  const id = randomUUID();
  const toTrackId = randomUUID();
  const bad: Array<Record<string, unknown>> = [
    { toTrackId }, // ids is required
    { ids: [id] }, // toTrackId is required
    { ids: [id], toTrackId: "not-a-uuid" },
    { ids: [id], byTracks: 1 }, // the OTHER command's param, not toTrackId
    { ids: [id], toTrackId, snap: true }, // unknown key
  ];

  for (const args of bad) {
    const result = await client.callTool({ name: "clip_move_many_to_track", arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `expected a boundary rejection for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("clip_move_many_to_track surfaces the manufactured-collision refusal verbatim (no re-wording at this layer)", async () => {
  const firstId = randomUUID();
  const secondId = randomUUID();
  const expectedMessage =
    `clips 'X' (${firstId}) and 'Y' (${secondId}) would overlap on the destination track — ` +
    "moving several tracks' clips onto one track needs them at different beats (move them one " +
    "at a time, or use clip.moveManyByTracks to keep them on separate tracks)";
  // `DawBridge.prototype.send` above clears `queuedError` the instant it is
  // thrown — so the expectation must be captured BEFORE the call, not read
  // back off `queuedError` afterwards (which is `undefined` by then).
  queuedError = new Error(expectedMessage);

  const result = await client.callTool({
    name: "clip_move_many_to_track",
    arguments: { ids: [firstId, secondId], toTrackId: randomUUID() },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a manufactured collision is a tool error");
  assert.equal(r.content[0].text, expectedMessage, "byte-identical at the MCP layer too");
});

test("clip_move_many_to_track's description teaches the COLLAPSE, the whole-move kind refusal, the manufactured-collision refusal, and the omitted track-delta keys", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_move_many_to_track");
  assert.ok(tool, "clip_move_many_to_track is listed");
  const description = tool!.description ?? "";
  assert.match(description, /COLLAPSES/);
  assert.match(description, /REFUSES THE WHOLE CALL/);
  assert.match(description, /refused EVEN WHEN.*ids.*is empty/);
  assert.match(description, /same beats.*destination.*ALSO refused|ALSO refused/);
  assert.match(description, /omitted, not null/);
  assert.match(description, /clip_move_many_by_tracks/);
});
