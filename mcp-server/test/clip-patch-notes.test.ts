/**
 * clip-patch-notes.test.ts — wiring coverage for clip_patch_notes
 * (m26-a / m27-n): BY-ID partial note edit, the missing rung between
 * clip_get_notes (read) and clip_set_notes (whole-array replace). The
 * store-level algorithm (coalescing, ALL-OR-NOTHING validation, field
 * apply) is proven in Tests/DAWCoreTests/PatchNotesTests.swift and the wire
 * round-trip in Tests/DAWControlTests/ClipPatchNotesCommandTests.swift; this
 * file proves only the MCP schema/forwarding boundary, the
 * clip-repeat-notes.test.ts stub-bridge pattern verbatim:
 *   - the tool forwards {clipId, update} to clip.patchNotes verbatim
 *   - the app's response round-trips verbatim, and NEVER carries a `notes`
 *     key (the whole point of this tool)
 *   - clipId is required and must be a UUID; update is required (schema
 *     layer, zero bridge calls)
 *   - each update[] entry requires `id` (a UUID); pitch/velocity/startBeat/
 *     lengthBeats are all optional (schema layer)
 *   - out-of-range fields (pitch, velocity, lengthBeats) are HARD-REJECTED
 *     at the schema layer, zero bridge calls
 *   - a typo'd field INSIDE one update[] entry is rejected — the nested
 *     `.strict()` on notePatchSchema, not just the top-level wrapper
 *     (m30-c: the wrapper only strictens the TOP level of its own schema)
 *   - registered via the STRICT-SCHEMA wrapper: an unrecognized top-level
 *     argument IS rejected before the bridge call
 *   - an app-side error (e.g. an unknown note id) surfaces as an MCP tool
 *     error, message verbatim
 *   - the description teaches the load-bearing facts: NOT clip_set_notes,
 *     ALL-OR-NOTHING, counts-only response, no auto-extend, one undo step
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
  client = new Client({ name: "clip-patch-notes-test-client", version: "0.0.0" });
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

function makeStubbedReport(clipId: string) {
  return {
    clipId,
    updated: 2,
    totalNotes: 907,
    latentNotesPastClipEnd: 0,
  };
}

test("clip_patch_notes forwards {clipId, update} verbatim, and the app's response round-trips verbatim with NO notes key", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  const stubbed = makeStubbedReport(clipId);
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ id: noteId, velocity: 30 }] },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.patchNotes");
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.deepEqual(calls[0]!.params["update"], [{ id: noteId, velocity: 30 }]);

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
  assert.ok(!("notes" in parsed), "the response must never carry a notes array");
});

test("clip_patch_notes forwards every field of an update entry under its own wire key", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  queuedResult = makeStubbedReport(clipId);

  await client.callTool({
    name: "clip_patch_notes",
    arguments: {
      clipId,
      update: [{ id: noteId, pitch: 72, velocity: 80, startBeat: 1.5, lengthBeats: 0.5 }],
    },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params["update"], [
    { id: noteId, pitch: 72, velocity: 80, startBeat: 1.5, lengthBeats: 0.5 },
  ]);
});

test("clip_patch_notes: an empty update array forwards as an empty array (schema layer accepts it)", async () => {
  const clipId = randomUUID();
  queuedResult = { clipId, updated: 0, totalNotes: 3, latentNotesPastClipEnd: 0 };

  const result = await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [] },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params["update"], []);
  const parsed = parseJSON(result as any);
  assert.equal(parsed.updated, 0);
});

test("clip_patch_notes requires a UUID clipId (rejected at the schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { update: [] },
  })) as any;
  assert.ok(missing.isError, "a missing clipId must be rejected before the bridge call");

  const notAUuid = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId: "not-a-uuid", update: [] },
  })) as any;
  assert.ok(notAUuid.isError, "a non-UUID clipId must be rejected before the bridge call");

  assert.equal(calls.length, 0);
});

test("clip_patch_notes requires update (rejected at the schema layer, zero bridge calls)", async () => {
  const clipId = randomUUID();

  const missing = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId },
  })) as any;
  assert.ok(missing.isError, "a missing update must be rejected before the bridge call");

  assert.equal(calls.length, 0);
});

test("clip_patch_notes: update[].id is required and must be a UUID (schema layer, zero bridge calls)", async () => {
  const clipId = randomUUID();

  const missingId = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ velocity: 1 }] },
  })) as any;
  assert.ok(missingId.isError, "an update entry with no id must be rejected");

  const badId = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ id: "not-a-uuid", velocity: 1 }] },
  })) as any;
  assert.ok(badId.isError, "an update entry with a non-UUID id must be rejected");

  assert.equal(calls.length, 0);
});

test("clip_patch_notes: out-of-range fields are HARD-REJECTED at the schema layer, zero bridge calls", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();

  const badPitch = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ id: noteId, pitch: 200 }] },
  })) as any;
  assert.ok(badPitch.isError, "pitch 200 must be rejected");

  const badVelocity = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ id: noteId, velocity: 0 }] },
  })) as any;
  assert.ok(badVelocity.isError, "velocity 0 must be rejected (0 is note-off)");

  const badLength = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ id: noteId, lengthBeats: 0 }] },
  })) as any;
  assert.ok(badLength.isError, "lengthBeats 0 must be rejected (must be > 0)");

  const badStart = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ id: noteId, startBeat: -1 }] },
  })) as any;
  assert.ok(badStart.isError, "a negative startBeat must be rejected");

  assert.equal(calls.length, 0, "every schema rejection must happen before the bridge call");
});

test("clip_patch_notes: a typo'd field INSIDE an update entry is rejected — the NESTED .strict(), not just the top level", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();

  // The wrapper (`registerTool`) only strictens the TOP-level inputSchema
  // (m30-c). Without `.strict()` on `notePatchSchema` ITSELF, a typo like
  // "velocty" would be silently STRIPPED by zod's default parse mode rather
  // than rejected — the call would appear to succeed while the field never
  // changed, exactly the silent-failure class this whole tree refuses to
  // ship.
  const result = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ id: noteId, velocty: 90 }] },
  })) as any;
  assert.ok(result.isError, "a typo'd field inside an update[] entry must be rejected, not silently stripped");
  assert.equal(calls.length, 0, "a nested schema rejection must never reach the bridge");
});

test("clip_patch_notes is registered via the STRICT-SCHEMA wrapper: an unrecognized top-level argument IS rejected", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  queuedResult = makeStubbedReport(clipId);

  const result = (await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ id: noteId, velocity: 1 }], bogus: true },
  })) as any;

  assert.ok(result.isError, "the strict schema rejects an unrecognized top-level key before the bridge call");
  assert.equal(calls.length, 0);
});

test("clip_patch_notes surfaces an app-side error (e.g. an unknown note id) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  const bogusId = randomUUID();
  queuedError = new Error(
    `clip.patchNotes: no note with id ${bogusId} in clip ${clipId} — nothing was changed`
  );

  const result = await client.callTool({
    name: "clip_patch_notes",
    arguments: { clipId, update: [{ id: bogusId, velocity: 1 }] },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.patchNotes");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /no note with id/, "the app's teaching message passes through verbatim");
});

test("the description teaches: NOT clip_set_notes, ALL-OR-NOTHING, counts-only, no auto-extend, one undo step", async () => {
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "clip_patch_notes");
  assert.ok(tool, "clip_patch_notes must be registered");
  const description = tool!.description ?? "";

  assert.match(description, /NOT clip_set_notes/i);
  assert.match(description, /REFUSES THE WHOLE CALL/i);
  assert.match(description, /COUNTS ONLY/i);
  assert.match(description, /auto-extend/i);
  assert.match(description, /undo step/i);
  assert.match(description, /clip_get_notes/);
});

test("clip_set_notes' description no longer claims to be the only note-editing primitive, and points at clip_patch_notes", async () => {
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "clip_set_notes");
  assert.ok(tool, "clip_set_notes must be registered");
  const description = tool!.description ?? "";

  assert.doesNotMatch(description, /the only note-editing/i);
  assert.match(description, /clip_patch_notes/);
});

test("clip_get_notes' description points at clip_patch_notes as the safe partial-edit path", async () => {
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "clip_get_notes");
  assert.ok(tool, "clip_get_notes must be registered");
  const description = tool!.description ?? "";

  assert.match(description, /clip_patch_notes/);
});
