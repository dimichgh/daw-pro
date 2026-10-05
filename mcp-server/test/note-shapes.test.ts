/**
 * note-shapes.test.ts — wiring coverage for W7-WIRE2's `clip_set_note_shapes`,
 * the BATCH twin of `clip_set_note_shape` (note-shape.test.ts): several
 * notes' drawn pitch lines in ONE call and ONE undo step, over the same
 * `ProjectStore.setClipNoteShapes` the single verb already calls.
 *
 * The note-shape.test.ts / natural-tuning.test.ts stub-bridge pattern
 * verbatim: monkeypatch `DawBridge.prototype.send` before importing the real
 * `McpServer`, drive the tool over an in-memory transport, and assert:
 *   - clip_set_note_shapes forwards {clipId, notes} verbatim, response
 *     round-trips
 *   - requires clipId (UUID) at the schema layer, zero bridge calls
 *   - an empty `notes` array IS rejected at the schema layer, zero bridge
 *     calls — a deliberate departure from clip_set_note_vibratos/
 *     clip_set_note_pitches, which forward an empty list to the app instead
 *   - each `notes` element is its own `.strict()` schema (m30-c nested-strict
 *     precedent): a typo'd field inside one element is rejected, never
 *     silently stripped; `noteId` is a required UUID; `points`/`clear` are
 *     both schema-optional (the app's "exactly one of the two" rule is a WIRE
 *     refusal, not a schema one), and each point inside `points` is its own
 *     `.strict()` schema too
 *   - registered via the STRICT-SCHEMA wrapper: an unrecognized top-level
 *     argument is rejected
 *   - an app-side error (a refusal sentence) surfaces as an MCP tool error,
 *     verbatim
 *   - the tool's own text names ONE undo step
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
  client = new Client({ name: "note-shapes-test-client", version: "0.0.0" });
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

function makeStubbedResponse(extra: Record<string, unknown> = {}) {
  return {
    clipId: randomUUID(),
    hasPitchEdits: true,
    hasTuningEdits: true,
    formantCorrection: 1.0,
    predatesNaturalTuning: false,
    segments: [],
    notes: [],
    skippedSoundIds: [],
    ...extra,
  };
}

test("clip_set_note_shapes forwards {clipId, notes} verbatim, response round-trips", async () => {
  const clipId = randomUUID();
  const noteA = randomUUID();
  const noteB = randomUUID();
  const notes = [
    { noteId: noteA, points: [{ seconds: 0.15, cents: 20 }] },
    { noteId: noteB, clear: true },
  ];
  const stubbed = makeStubbedResponse({
    notes: [
      { noteId: noteA, shape: { startSeconds: 0.1, stepSeconds: 0.01, cents: [0, 20] } },
      { noteId: noteB, shape: { startSeconds: 0, stepSeconds: 0.01, cents: [] } },
    ],
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId, notes },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteShapes");
  assert.deepEqual(calls[0]!.params, { clipId, notes });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_set_note_shapes requires a UUID clipId at the schema layer, zero bridge calls", async () => {
  const missingClipId = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { notes: [{ noteId: randomUUID(), clear: true }] },
  });
  const badClipId = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId: "not-a-uuid", notes: [{ noteId: randomUUID(), clear: true }] },
  });
  for (const response of [missingClipId, badClipId]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((response as any).isError);
  }
  assert.equal(calls.length, 0);
});

test("clip_set_note_shapes requires notes (a non-empty array) at the schema layer, zero bridge calls", async () => {
  const missingNotes = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId: randomUUID() },
  });
  const notAnArray = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId: randomUUID(), notes: randomUUID() },
  });
  for (const response of [missingNotes, notAnArray]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((response as any).isError);
  }
  assert.equal(calls.length, 0);
});

test("clip_set_note_shapes: an empty notes array IS rejected at the schema layer, zero bridge calls (unlike clip_set_note_vibratos/clip_set_note_pitches)", async () => {
  const result = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId: randomUUID(), notes: [] },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "an empty notes array must be refused before the bridge, not by the app");
  assert.equal(calls.length, 0, "the schema's .min(1) must pre-empt the store's own empty-list refusal");
});

test("clip_set_note_shapes: a notes element that is not an object, or has a non-UUID noteId, is rejected at the schema layer", async () => {
  const notAnObject = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId: randomUUID(), notes: ["not-an-object"] },
  });
  const badNoteId = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId: randomUUID(), notes: [{ noteId: "not-a-uuid", clear: true }] },
  });
  const missingNoteId = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId: randomUUID(), notes: [{ clear: true }] },
  });
  for (const response of [notAnObject, badNoteId, missingNoteId]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((response as any).isError);
  }
  assert.equal(calls.length, 0);
});

test("clip_set_note_shapes: an unrecognized key INSIDE one notes[] element is rejected (the m30-c nested-strict precedent)", async () => {
  const result = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: {
      clipId: randomUUID(),
      notes: [{ noteId: randomUUID(), clear: true, bogus: true }],
    },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "a typo'd field inside a notes element must be REJECTED, not silently stripped");
  assert.equal(calls.length, 0);
});

test("clip_set_note_shapes: each point inside one item's `points` is its OWN strict schema — an extra key inside one point is rejected, zero bridge calls", async () => {
  const result = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: {
      clipId: randomUUID(),
      notes: [{ noteId: randomUUID(), points: [{ seconds: 0.1, cents: 10, bogus: true }] }],
    },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_shapes' points/clear are both schema-optional — an item with neither still reaches the bridge (the app's 'exactly one of' refusal is a WIRE rule, not a schema one)", async () => {
  queuedError = new Error(
    "needs exactly one of 'points' (an array of {seconds, cents} to draw onto the note) or 'clear' (true, to remove its drawing) — not both, not neither."
  );
  const result = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId: randomUUID(), notes: [{ noteId: randomUUID() }] },
  });
  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /exactly one of/);
});

test("clip_set_note_shapes is registered via the STRICT-SCHEMA wrapper: an unrecognized top-level argument IS rejected", async () => {
  const result = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: { clipId: randomUUID(), notes: [{ noteId: randomUUID(), clear: true }], bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_shapes surfaces an app-side error (e.g. the same note named twice, or a SOUND has no pitch line) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  queuedError = new Error(`Note ${noteId} is named twice in this batch. Name each note once.`);

  const result = await client.callTool({
    name: "clip_set_note_shapes",
    arguments: {
      clipId,
      notes: [
        { noteId, clear: true },
        { noteId, points: [{ seconds: 0.1, cents: 5 }] },
      ],
    },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /named twice in this batch/);
});

test("clip_set_note_shapes' own text names ONE undo step and points at clip_set_note_shape for one note", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_set_note_shapes");
  assert.ok(tool, "clip_set_note_shapes is registered");
  const description = tool!.description ?? "";
  assert.match(description, /ONE call and ONE undo step/);
  assert.match(description, /Use clip_set_note_shape instead for one note/);
  assert.match(description, /skippedSoundIds/);
  assert.match(description, /skippedSoundsSentence/);
});
