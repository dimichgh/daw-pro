/**
 * clip-repeat-notes.test.ts — wiring coverage for clip_repeat_notes (m31-c):
 * literal, time-shifted, optionally chromatically-transposed copies of a
 * clip-relative note window (or an explicit note selection), written back
 * into the SAME clip. The store-level algorithm (coalescing, geometry, meter
 * span, auto-extend, transpose/clamp) is proven in
 * Tests/DAWCoreTests/RepeatNotesTests.swift and the wire round-trip in
 * Tests/DAWControlTests/ClipRepeatNotesCommandTests.swift; this file proves
 * only the MCP schema/forwarding boundary, the clip-get-notes.test.ts
 * stub-bridge pattern verbatim:
 *   - the tool forwards {clipId, periodBeats, count} (bare) to
 *     clip.repeatNotes with every optional param forwarded as `undefined`,
 *     never a fabricated default
 *   - every optional param (fromBeat, toBeat, noteIds, firstCopyAtBeat,
 *     transposeSemitones, extendClip) forwards verbatim under its own wire
 *     key when supplied
 *   - the app's response round-trips verbatim, and NEVER carries a `notes`
 *     key (the whole point of this tool)
 *   - clipId is required and must be a UUID; periodBeats and count are
 *     required (schema layer, zero bridge calls)
 *   - count is a whole number, 1-512, HARD-REJECTED outside that range or
 *     when fractional (schema layer, zero bridge calls)
 *   - transposeSemitones entries must be whole numbers (schema layer)
 *   - noteIds entries must be UUIDs (schema layer)
 *   - registered via the STRICT-SCHEMA wrapper: an unrecognized extra
 *     argument IS rejected before the bridge call
 *   - an app-side error (e.g. the mutually-exclusive-selection refusal)
 *     surfaces as an MCP tool error, message verbatim
 *   - the description teaches the load-bearing facts: clip-relative,
 *     half-open, no notes returned, chromatic-not-diatonic, compounds on
 *     re-run / one undo step
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
  client = new Client({ name: "clip-repeat-notes-test-client", version: "0.0.0" });
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
    copiesMade: 11,
    sourceNoteCount: 13,
    notesAdded: 143,
    totalNotes: 156,
    patternSpanBeats: 4.0,
    firstCopyStartBeat: 4.0,
    lastCopyEndBeat: 48.0,
    clipLengthBeats: 48.0,
    extended: true,
    extendRefusal: null,
    latentNotesPastClipEnd: 0,
    meterChangesInSpan: 0,
    preExistingNotesInSpan: 0,
    copiesOverlapEachOther: false,
    pitchesClamped: 0,
  };
}

test("clip_repeat_notes forwards {clipId, periodBeats, count} (bare) with every optional param undefined, and the app's response round-trips verbatim with NO notes key", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedReport(clipId);
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 4, count: 11 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.repeatNotes");
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.equal(calls[0]!.params["periodBeats"], 4);
  assert.equal(calls[0]!.params["count"], 11);
  for (const key of ["fromBeat", "toBeat", "noteIds", "firstCopyAtBeat", "transposeSemitones", "extendClip"]) {
    assert.equal(calls[0]!.params[key], undefined, `${key} must forward as undefined, never a fabricated default`);
  }

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
  assert.ok(!("notes" in parsed), "the response must never carry a notes array");
});

test("clip_repeat_notes forwards every optional param explicitly under its own wire key", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  queuedResult = makeStubbedReport(clipId);

  await client.callTool({
    name: "clip_repeat_notes",
    arguments: {
      clipId,
      noteIds: [noteId],
      periodBeats: 4,
      count: 3,
      firstCopyAtBeat: 8,
      transposeSemitones: [0, 5, -5],
      extendClip: false,
    },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    clipId,
    // The handler destructures ALL params unconditionally, so an omitted
    // one (fromBeat/toBeat here, mutually exclusive with noteIds) still
    // creates an `undefined`-valued key on the forwarded object — harmless
    // over the real wire (JSON.stringify drops it), but deepEqual against
    // an in-memory stub must account for it explicitly.
    fromBeat: undefined,
    toBeat: undefined,
    noteIds: [noteId],
    periodBeats: 4,
    count: 3,
    firstCopyAtBeat: 8,
    transposeSemitones: [0, 5, -5],
    extendClip: false,
  });
});

test("clip_repeat_notes forwards fromBeat/toBeat explicitly (the alternative selection form)", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedReport(clipId);

  await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, fromBeat: 0, toBeat: 4, periodBeats: 4, count: 1 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["fromBeat"], 0);
  assert.equal(calls[0]!.params["toBeat"], 4);
});

test("clip_repeat_notes requires a UUID clipId (rejected at the schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { periodBeats: 4, count: 1 },
  })) as any;
  assert.ok(missing.isError, "a missing clipId must be rejected before the bridge call");

  const notAUuid = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId: "not-a-uuid", periodBeats: 4, count: 1 },
  })) as any;
  assert.ok(notAUuid.isError, "a non-UUID clipId must be rejected before the bridge call");

  assert.equal(calls.length, 0);
});

test("clip_repeat_notes requires periodBeats and count (rejected at the schema layer, zero bridge calls)", async () => {
  const clipId = randomUUID();

  const noPeriod = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, count: 1 },
  })) as any;
  assert.ok(noPeriod.isError);

  const noCount = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 4 },
  })) as any;
  assert.ok(noCount.isError);

  assert.equal(calls.length, 0);
});

test("clip_repeat_notes: count is a whole number 1-512, HARD-REJECTED outside that range or when fractional", async () => {
  const clipId = randomUUID();

  const zero = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 1, count: 0 },
  })) as any;
  assert.ok(zero.isError, "count 0 must be rejected");

  const tooMany = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 1, count: 513 },
  })) as any;
  assert.ok(tooMany.isError, "count 513 must be rejected (the 512 ceiling)");

  const fractional = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 1, count: 1.5 },
  })) as any;
  assert.ok(fractional.isError, "a fractional count must be rejected");

  assert.equal(calls.length, 0, "schema rejections never reach the bridge");
});

test("clip_repeat_notes: count accepts its boundaries, 1 and 512", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedReport(clipId);

  const low = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 1, count: 1 },
  })) as any;
  assert.ok(!low.isError, "count 1 must be accepted");

  const high = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 1, count: 512 },
  })) as any;
  assert.ok(!high.isError, "count 512 must be accepted");

  assert.equal(calls.length, 2);
});

test("clip_repeat_notes: transposeSemitones entries must be whole numbers (schema layer)", async () => {
  const clipId = randomUUID();

  const fractional = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 1, count: 2, transposeSemitones: [1, 2.5] },
  })) as any;
  assert.ok(fractional.isError, "a fractional transpose entry must be rejected");

  assert.equal(calls.length, 0);
});

test("clip_repeat_notes: noteIds entries must be UUIDs (schema layer)", async () => {
  const clipId = randomUUID();

  const notAUuid = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 1, count: 1, noteIds: ["not-a-uuid"] },
  })) as any;
  assert.ok(notAUuid.isError, "a non-UUID noteIds entry must be rejected");

  assert.equal(calls.length, 0);
});

test("clip_repeat_notes is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedReport(clipId);

  const result = (await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, periodBeats: 4, count: 1, bogus: true },
  })) as any;

  assert.ok(result.isError, "the strict schema rejects an unrecognized key before the bridge call");
  assert.equal(calls.length, 0);
});

test("clip_repeat_notes surfaces an app-side error (e.g. the mutually-exclusive-selection refusal) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error("clip.repeatNotes: pass either 'noteIds' or 'fromBeat'/'toBeat', not both");

  const result = await client.callTool({
    name: "clip_repeat_notes",
    arguments: { clipId, fromBeat: 0, toBeat: 1, noteIds: [randomUUID()], periodBeats: 4, count: 1 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.repeatNotes");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /not both/, "the app's teaching message passes through verbatim");
});

test("the description teaches: clip-relative, half-open, no notes returned, chromatic-not-diatonic, and one undo step / compounds on re-run", async () => {
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "clip_repeat_notes");
  assert.ok(tool, "clip_repeat_notes must be registered");
  const description = tool!.description ?? "";

  assert.match(description, /CLIP-RELATIVE/i);
  assert.match(description, /HALF-OPEN/i);
  assert.match(description, /NO NOTES ARE RETURNED/i);
  assert.match(description, /CHROMATIC/i);
  assert.match(description, /NOT diatonic/i);
  assert.match(description, /COMPOUNDS/i);
  assert.match(description, /undo step/i);
});
