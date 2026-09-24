/**
 * pitch-correction.test.ts — wiring coverage for the m23-q Phase 2 writer
 * leg's three tools: clip_auto_correct_pitch / clip_clear_pitch_edits /
 * clip_get_pitch_edits.
 *
 * The clip-detect-pitch.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive
 * each tool over an in-memory transport, and assert:
 *   - clip_auto_correct_pitch forwards {clipId, preset, tonicPitchClass,
 *     mode, strength, retuneMs, preserveVibrato} verbatim, omitted params as
 *     undefined never fabricated defaults
 *   - the app's response round-trips verbatim
 *   - preset/mode enums reject an unrecognized value at the SCHEMA layer,
 *     zero bridge calls (the app's own field-named-error path is a
 *     DIFFERENT, deeper defense this test does not re-prove)
 *   - strength/retuneMs range rejection at the schema layer
 *   - all three registered via the STRICT-SCHEMA wrapper (unrecognized
 *     extra argument rejected, even on the read-only getter/clear)
 *   - an app-side error surfaces as an MCP tool error, message verbatim
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
  client = new Client({ name: "pitch-correction-test-client", version: "0.0.0" });
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

function makeStubbedResponse(extra: Record<string, unknown> = {}) {
  return {
    clipId: randomUUID(),
    hasPitchEdits: true,
    analysisVersion: 1,
    retuneMs: 30,
    segmentCount: 1,
    isIdentity: false,
    segments: [
      {
        id: randomUUID(),
        startSeconds: 0.0,
        endSeconds: 0.5,
        detectedHz: 220.0,
        detectedConfidence: 0.95,
        pitchOffsetCents: 15.0,
        driftScale: 1.0,
        vibratoScale: 1.0,
      },
    ],
    warnings: [],
    ...extra,
  };
}

// --- clip_auto_correct_pitch ------------------------------------------------

test("clip_auto_correct_pitch forwards {clipId} (bare) with every optional undefined, and returns the app's response verbatim", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedResponse();
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.autoCorrectPitch");
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.equal(calls[0]!.params["preset"], undefined, "an omitted param forwards as undefined, never a fabricated default");
  assert.equal(calls[0]!.params["tonicPitchClass"], undefined);
  assert.equal(calls[0]!.params["mode"], undefined);
  assert.equal(calls[0]!.params["strength"], undefined);
  assert.equal(calls[0]!.params["retuneMs"], undefined);
  assert.equal(calls[0]!.params["preserveVibrato"], undefined);

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
});

test("clip_auto_correct_pitch forwards every optional param explicitly", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedResponse();

  await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: {
      clipId,
      preset: "gentle",
      tonicPitchClass: 7,
      mode: "minor",
      strength: 0.8,
      retuneMs: 60,
      preserveVibrato: false,
    },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    clipId,
    preset: "gentle",
    tonicPitchClass: 7,
    mode: "minor",
    strength: 0.8,
    retuneMs: 60,
    preserveVibrato: false,
  });
});

test("clip_auto_correct_pitch requires a UUID clipId (rejected at the schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({ name: "clip_auto_correct_pitch", arguments: {} })) as any;
  assert.ok(missing.isError);

  const notAUuid = (await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId: "not-a-uuid" },
  })) as any;
  assert.ok(notAUuid.isError);

  assert.equal(calls.length, 0);
});

test("clip_auto_correct_pitch: preset must be one of the four pinned raw values (schema-layer enum, zero bridge calls)", async () => {
  const clipId = randomUUID();
  const result = (await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, preset: "bogus" },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_auto_correct_pitch: mode must be chromatic|major|minor (schema-layer enum, zero bridge calls)", async () => {
  const clipId = randomUUID();
  const result = (await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, mode: "dorian" },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_auto_correct_pitch: strength/retuneMs are range-checked at the schema layer", async () => {
  const clipId = randomUUID();

  const badStrength = (await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, strength: 1.5 },
  })) as any;
  assert.ok(badStrength.isError);

  const badRetuneLow = (await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, retuneMs: 10 },
  })) as any;
  assert.ok(badRetuneLow.isError);

  const badRetuneHigh = (await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, retuneMs: 900 },
  })) as any;
  assert.ok(badRetuneHigh.isError);

  assert.equal(calls.length, 0, "schema rejections never reach the bridge");
});

test("clip_auto_correct_pitch is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedResponse();

  const result = (await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, bogus: true },
  })) as any;

  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_auto_correct_pitch surfaces an app-side error (e.g. the MIDI-clip rejection) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    `clip ${clipId} is a MIDI clip — clip.autoCorrectPitch applies only to audio clips`
  );

  const result = await client.callTool({ name: "clip_auto_correct_pitch", arguments: { clipId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.autoCorrectPitch");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /is a MIDI clip/);
});

// --- clip_clear_pitch_edits -------------------------------------------------

test("clip_clear_pitch_edits forwards {clipId} and returns the app's response verbatim", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedResponse({ hasPitchEdits: false, segmentCount: 0, isIdentity: true, segments: [] });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_clear_pitch_edits",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.clearPitchEdits");
  assert.deepEqual(calls[0]!.params, { clipId });

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed);
});

test("clip_clear_pitch_edits requires a UUID clipId (schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({ name: "clip_clear_pitch_edits", arguments: {} })) as any;
  assert.ok(missing.isError);
  assert.equal(calls.length, 0);
});

test("clip_clear_pitch_edits: STRICT-SCHEMA wrapper rejects an unrecognized argument even though the tool is otherwise a bare clipId call", async () => {
  const clipId = randomUUID();
  const result = (await client.callTool({
    name: "clip_clear_pitch_edits",
    arguments: { clipId, bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_clear_pitch_edits surfaces an app-side error as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(`no clip with id ${clipId}`);

  const result = await client.callTool({ name: "clip_clear_pitch_edits", arguments: { clipId } });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /no clip with id/);
});

// --- clip_get_pitch_edits ----------------------------------------------------

test("clip_get_pitch_edits forwards {clipId} and returns the app's response verbatim, no appliedOptions", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedResponse();
  delete (stubbed as Record<string, unknown>)["appliedOptions"];
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_get_pitch_edits",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.getPitchEdits");
  assert.deepEqual(calls[0]!.params, { clipId });

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed);
  assert.ok(!("appliedOptions" in parsed), "the getter never claims to have applied anything");
});

test("clip_get_pitch_edits requires a UUID clipId (schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({ name: "clip_get_pitch_edits", arguments: {} })) as any;
  assert.ok(missing.isError);
  assert.equal(calls.length, 0);
});

test("clip_get_pitch_edits: STRICT-SCHEMA wrapper rejects an unrecognized argument", async () => {
  const clipId = randomUUID();
  const result = (await client.callTool({
    name: "clip_get_pitch_edits",
    arguments: { clipId, bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_get_pitch_edits surfaces an app-side error as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(`no clip with id ${clipId}`);

  const result = await client.callTool({ name: "clip_get_pitch_edits", arguments: { clipId } });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /no clip with id/);
});
