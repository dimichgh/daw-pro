/**
 * clip-get-notes.test.ts — wiring coverage for clip_get_notes, the read-only
 * counterpart to clip_set_notes (added alongside `clip.getNotes` on the wire:
 * clip_set_notes replaces the ENTIRE note array, and project_snapshot is the
 * only other way to read notes back — too big to use as a routine read).
 *
 * The clip-detect-pitch.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards {clipId} (bare) to clip.getNotes with every optional
 *     param forwarded as `undefined`, never a fabricated default
 *   - every optional param (fromBeat, toBeat, pitchMin, pitchMax) forwards
 *     verbatim under its own wire key when supplied
 *   - the app's response round-trips verbatim (totalNotes/returnedNotes/notes
 *     included, byte for byte)
 *   - clipId is required and must be a UUID (schema layer, zero bridge calls)
 *   - pitchMin/pitchMax are schema-bounded to 0-127 (schema layer, zero
 *     bridge calls)
 *   - registered via the STRICT-SCHEMA wrapper despite being read-only (the
 *     audio_profile_file/clip_detect_pitch precedent), so an unrecognized
 *     extra argument IS rejected before the bridge call
 *   - an app-side error (e.g. the audio-clip rejection) surfaces as an MCP
 *     tool error, message verbatim
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
  client = new Client({ name: "clip-get-notes-test-client", version: "0.0.0" });
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

function makeStubbedNotesResponse(clipId: string, trackId: string) {
  return {
    clipId,
    trackId,
    clipName: "MIDI Clip 1",
    clipStartBeat: 0,
    clipLengthBeats: 8,
    totalNotes: 2,
    returnedNotes: 2,
    notes: [
      { id: randomUUID(), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1 },
      { id: randomUUID(), pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 0.5 },
    ],
  };
}

test("clip_get_notes forwards {clipId} (bare) to clip.getNotes with every optional param undefined, and the app's response round-trips verbatim", async () => {
  const clipId = randomUUID();
  const trackId = randomUUID();
  const stubbed = makeStubbedNotesResponse(clipId, trackId);
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_get_notes",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.getNotes");
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.equal(calls[0]!.params["fromBeat"], undefined, "an omitted param forwards as undefined, never a fabricated default");
  assert.equal(calls[0]!.params["toBeat"], undefined);
  assert.equal(calls[0]!.params["pitchMin"], undefined);
  assert.equal(calls[0]!.params["pitchMax"], undefined);

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim, including totalNotes/returnedNotes/notes");
});

test("clip_get_notes forwards every optional param explicitly under its own wire key", async () => {
  const clipId = randomUUID();
  const trackId = randomUUID();
  queuedResult = makeStubbedNotesResponse(clipId, trackId);

  await client.callTool({
    name: "clip_get_notes",
    arguments: {
      clipId,
      fromBeat: 1.0,
      toBeat: 2.0,
      pitchMin: 60,
      pitchMax: 64,
    },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    clipId,
    fromBeat: 1.0,
    toBeat: 2.0,
    pitchMin: 60,
    pitchMax: 64,
  });
});

test("clip_get_notes requires a UUID clipId (rejected at the schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({ name: "clip_get_notes", arguments: {} })) as any;
  assert.ok(missing.isError, "a missing clipId must be rejected before the bridge call");

  const notAUuid = (await client.callTool({
    name: "clip_get_notes",
    arguments: { clipId: "not-a-uuid" },
  })) as any;
  assert.ok(notAUuid.isError, "a non-UUID clipId must be rejected before the bridge call");

  assert.equal(calls.length, 0);
});

test("clip_get_notes schema bounds pitchMin/pitchMax to 0-127 at the schema layer", async () => {
  const clipId = randomUUID();

  const tooHigh = (await client.callTool({
    name: "clip_get_notes",
    arguments: { clipId, pitchMax: 128 },
  })) as any;
  assert.ok(tooHigh.isError);

  const negative = (await client.callTool({
    name: "clip_get_notes",
    arguments: { clipId, pitchMin: -1 },
  })) as any;
  assert.ok(negative.isError);

  const notAnInt = (await client.callTool({
    name: "clip_get_notes",
    arguments: { clipId, pitchMin: 1.5 },
  })) as any;
  assert.ok(notAnInt.isError);

  assert.equal(calls.length, 0, "schema rejections never reach the bridge");
});

test("clip_get_notes is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected, even though the tool is read-only", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedNotesResponse(clipId, randomUUID());

  const result = (await client.callTool({
    name: "clip_get_notes",
    arguments: { clipId, bogus: true },
  })) as any;

  assert.ok(result.isError, "the strict schema rejects an unrecognized key before the bridge call");
  assert.equal(calls.length, 0);
});

test("clip_get_notes surfaces an app-side error (e.g. the audio-clip rejection) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    `clip ${clipId} is an audio clip — clip.getNotes applies only to MIDI clips (created via clip.addMIDI)`
  );

  const result = await client.callTool({ name: "clip_get_notes", arguments: { clipId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.getNotes");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /is an audio clip/, "the app's teaching message passes through verbatim");
});
