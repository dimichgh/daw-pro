/**
 * note-shape.test.ts — wiring coverage for C5b-3b's freehand pitch-line tool
 * (docs/design/2026-09-24-pitch-editor-timing-and-freehand.md §5.7).
 *
 * The clip-detect-pitch.test.ts / natural-tuning.test.ts stub-bridge pattern
 * verbatim: monkeypatch `DawBridge.prototype.send` before importing the real
 * `McpServer`, drive the tool over an in-memory transport, and assert:
 *   - clip_set_note_shape forwards {clipId, noteId, points, clear} verbatim
 *     (points/clear each present as `undefined` on the object when the
 *     caller sent only the other one — an object literal keeps an
 *     `undefined`-valued key, so the round-trip assertion says so explicitly
 *     rather than omitting it, the widthMs precedent)
 *   - requires clipId and noteId (both UUID) at the schema layer, zero
 *     bridge calls; `points`/`clear` are both schema-optional (the app's
 *     "exactly one of the two" rule is a WIRE refusal, not a schema one)
 *   - each point in `points` is its OWN `.strict()` schema (m30-c nested-
 *     strict-gap precedent): an extra key inside one point is rejected at
 *     the MCP boundary, never silently stripped through to the wire
 *   - registered via the STRICT-SCHEMA wrapper: an unrecognized top-level
 *     argument is rejected
 *   - an app-side error (a refusal sentence) surfaces as an MCP tool error,
 *     verbatim
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
  client = new Client({ name: "note-shape-test-client", version: "0.0.0" });
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
    ...extra,
  };
}

test("clip_set_note_shape forwards {clipId, noteId, points} verbatim (clear undefined), response round-trips", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  const points = [
    { seconds: 0.15, cents: 20 },
    { seconds: 0.25, cents: -10 },
  ];
  const stubbed = makeStubbedResponse({
    noteId,
    shape: { startSeconds: 0.1, stepSeconds: 0.01, cents: [0, 0, 20, -10, 0] },
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_note_shape",
    arguments: { clipId, noteId, points },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteShape");
  assert.deepEqual(calls[0]!.params, { clipId, noteId, points, clear: undefined });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_set_note_shape forwards {clipId, noteId, clear: true} verbatim (points undefined), response round-trips", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  const stubbed = makeStubbedResponse({
    noteId,
    shape: { startSeconds: 0, stepSeconds: 0.01, cents: [] },
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_note_shape",
    arguments: { clipId, noteId, clear: true },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteShape");
  assert.deepEqual(calls[0]!.params, { clipId, noteId, points: undefined, clear: true });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_set_note_shape requires clipId and noteId (both UUID) at the schema layer, zero bridge calls", async () => {
  const missingClipId = await client.callTool({
    name: "clip_set_note_shape",
    arguments: { noteId: randomUUID(), clear: true },
  });
  const missingNoteId = await client.callTool({
    name: "clip_set_note_shape",
    arguments: { clipId: randomUUID(), clear: true },
  });
  const badClipId = await client.callTool({
    name: "clip_set_note_shape",
    arguments: { clipId: "not-a-uuid", noteId: randomUUID(), clear: true },
  });
  for (const response of [missingClipId, missingNoteId, badClipId]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((response as any).isError);
  }
  assert.equal(calls.length, 0);
});

test("clip_set_note_shape's points/clear are both schema-optional — a call with neither still reaches the bridge (the app's 'exactly one of' refusal is a WIRE rule, not a schema one)", async () => {
  queuedError = new Error(
    "clip.setNoteShape needs exactly one of 'points' (an array of {seconds, cents} to draw onto the note) or 'clear' (true, to remove its drawing) — not both, not neither."
  );
  const result = await client.callTool({
    name: "clip_set_note_shape",
    arguments: { clipId: randomUUID(), noteId: randomUUID() },
  });
  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /exactly one of/);
});

test("clip_set_note_shape: each point is its OWN strict schema — an extra key inside one point is rejected, zero bridge calls", async () => {
  const result = await client.callTool({
    name: "clip_set_note_shape",
    arguments: {
      clipId: randomUUID(),
      noteId: randomUUID(),
      points: [{ seconds: 0.1, cents: 10, bogus: true }],
    },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_shape is registered via the STRICT-SCHEMA wrapper: an unrecognized top-level argument IS rejected", async () => {
  const result = await client.callTool({
    name: "clip_set_note_shape",
    arguments: { clipId: randomUUID(), noteId: randomUUID(), clear: true, bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_shape surfaces an app-side refusal (e.g. a SOUND has no pitch line) as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "Note deadbeef is a breath or a consonant, not a sung note, so it has no pitch line to draw. Nothing was changed. Name sung notes only."
  );
  const result = await client.callTool({
    name: "clip_set_note_shape",
    arguments: { clipId: randomUUID(), noteId: randomUUID(), points: [{ seconds: 0.1, cents: 10 }] },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /has no pitch line to draw/);
});
