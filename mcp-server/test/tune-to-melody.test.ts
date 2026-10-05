/**
 * tune-to-melody.test.ts — Tune to Melody M2 (W7-TTM2, design
 * docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md §3.4): the
 * three additive fields on clip_auto_correct_pitch.
 *
 * The pitch-correction.test.ts stub-bridge pattern: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - melodyClipId / melodyTrackId / octaveMatch forward verbatim
 *   - OMITTED, they are ABSENT from the bridge params (not undefined-valued
 *     keys): a call without them sends exactly the keys it sent before, so
 *     pitch-correction.test.ts's deepStrictEqual on the full param object
 *     stays green
 *   - octaveMatch is an enum and both ids are UUIDs, at the schema layer
 *     (zero bridge calls); exclusivity of the two ids is the APP's refusal,
 *     which surfaces verbatim as an MCP tool error
 *   - the app's reply (with its melody{} block) round-trips verbatim
 *   - the description and field texts say what Tune to Melody does
 * The tool count does not change (the same tool gains fields).
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
  client = new Client({ name: "tune-to-melody-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { clipId: randomUUID(), segments: [], warnings: [] };
  queuedError = undefined;
});

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: any): any {
  const first = result.content[0];
  assert.ok(first && first.type === "text", `expected a text content item, got: ${JSON.stringify(result.content)}`);
  return JSON.parse(first.text as string);
}

test("N1 clip_auto_correct_pitch forwards melodyClipId and octaveMatch verbatim", async () => {
  const clipId = randomUUID();
  const melodyClipId = randomUUID();
  await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, preset: "natural", melodyClipId, octaveMatch: "exact" },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.autoCorrectPitch");
  assert.equal(calls[0]!.params["melodyClipId"], melodyClipId);
  assert.equal(calls[0]!.params["octaveMatch"], "exact");
  assert.equal(calls[0]!.params["preset"], "natural");
  assert.ok(!("melodyTrackId" in calls[0]!.params), "an omitted melodyTrackId is ABSENT, not undefined");
});

test("N2 clip_auto_correct_pitch forwards melodyTrackId verbatim (octaveMatch omitted stays absent)", async () => {
  const clipId = randomUUID();
  const melodyTrackId = randomUUID();
  await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, melodyTrackId },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["melodyTrackId"], melodyTrackId);
  assert.ok(!("melodyClipId" in calls[0]!.params));
  assert.ok(!("octaveMatch" in calls[0]!.params), "the app's own default (nearestOctave) applies");
});

test("N3 without the melody fields, the bridge params carry NONE of the three keys", async () => {
  const clipId = randomUUID();
  await client.callTool({ name: "clip_auto_correct_pitch", arguments: { clipId } });
  assert.equal(calls.length, 1);
  for (const key of ["melodyClipId", "melodyTrackId", "octaveMatch"]) {
    assert.ok(!(key in calls[0]!.params), `${key} must be absent when not given`);
  }
});

test("N4 octaveMatch is an enum at the schema layer (zero bridge calls)", async () => {
  const result = (await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId: randomUUID(), melodyClipId: randomUUID(), octaveMatch: "loudest" },
  })) as any;
  assert.equal(result.isError, true);
  assert.equal(calls.length, 0);
});

test("N5 melodyClipId and melodyTrackId must be UUIDs at the schema layer (zero bridge calls)", async () => {
  for (const key of ["melodyClipId", "melodyTrackId"]) {
    const result = (await client.callTool({
      name: "clip_auto_correct_pitch",
      arguments: { clipId: randomUUID(), [key]: "Lead" },
    })) as any;
    assert.equal(result.isError, true, `${key}: a name is not an id`);
  }
  assert.equal(calls.length, 0);
});

test("N6 the app's refusal (both ids, or no melody note under the vocal) surfaces verbatim as a tool error", async () => {
  const message =
    "Send 'melodyClipId' or 'melodyTrackId', not both: the melody is one MIDI clip, or every MIDI clip on one track.";
  queuedError = new Error(message);
  const result = (await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId: randomUUID(), melodyClipId: randomUUID(), melodyTrackId: randomUUID() },
  })) as any;
  assert.equal(result.isError, true);
  assert.equal(calls.length, 1, "exclusivity is the app's refusal: the call reaches the bridge");
  const text = result.content[0].text as string;
  assert.ok(text.includes(message), `message verbatim, got: ${text}`);
});

test("N7 the description and the three field texts say what Tune to Melody does", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_auto_correct_pitch");
  assert.ok(tool, "the tool is registered");
  const description = tool!.description ?? "";
  for (const phrase of ["TUNE TO MELODY", "melodyClipId", "melodyTrackId", "octaveMatch",
                        "strength 1", "unsungNotes", "farMoves", "never both"]) {
    assert.ok(description.includes(phrase), `description mentions ${phrase}`);
  }
  const props = (tool!.inputSchema as any).properties;
  for (const key of ["melodyClipId", "melodyTrackId", "octaveMatch"]) {
    assert.ok(props[key], `${key} is in the schema`);
    assert.ok((props[key].description ?? "").length > 40, `${key} has a real description`);
  }
  assert.deepEqual(props["octaveMatch"].enum, ["nearestOctave", "exact"]);
  assert.ok(!(tool!.inputSchema as any).required?.includes("melodyClipId"), "optional");
});

test("N8 the reply, melody block included, round-trips verbatim", async () => {
  const segmentId = randomUUID();
  const reply = {
    clipId: randomUUID(),
    appliedOptions: { strength: 1 },
    segments: [],
    warnings: [],
    melody: {
      source: { kind: "clip", clipId: randomUUID(), name: "Lead" },
      octaveMatch: "nearestOctave",
      unmatched: "asSung",
      notesConsidered: 3,
      notesUsed: 3,
      matchedParts: 3,
      unmatchedParts: [],
      unsungNotes: [],
      outvotedNotes: [],
      cutsAdded: [],
      chordsReduced: [],
      octaveFolded: [{ segmentId, octaves: -1 }],
      farMoves: [],
    },
  };
  queuedResult = reply;
  const result = await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId: randomUUID(), melodyClipId: randomUUID() },
  });
  assert.deepEqual(parseJSON(result as any), reply);
});
