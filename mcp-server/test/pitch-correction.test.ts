/**
 * pitch-correction.test.ts — wiring coverage for the m23-q Phase 2 writer
 * leg's three tools (clip_auto_correct_pitch / clip_clear_pitch_edits /
 * clip_get_pitch_edits) plus the pitch-editor command-surface door's two
 * per-note edit tools (clip_set_note_pitch / clip_split_note,
 * `docs/design/2026-09-22-pitch-editor-ui.md` §9).
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
 *   - clip_set_note_pitch forwards {clipId, segmentId, cents} verbatim —
 *     `cents` is UNCHECKED at the schema layer (the clamp is the store's
 *     job; this suite proves the tool does not second-guess it by adding
 *     its own range check that would reject a value the app would have
 *     clamped and accepted)
 *   - clip_split_note forwards {clipId, segmentId, atSourceSeconds}
 *     verbatim, same unchecked-number shape (the 60ms floor is the store's
 *     job too)
 *
 * m23-ap C-0c / C-F3 (2026-09-24) add two more:
 *   - clip_auto_correct_pitch forwards its new optional `replaceExisting`
 *     verbatim -- omitted forwards as undefined (never a fabricated
 *     true/false), explicit true/false both forward literally
 *   - clip_get_played_pitch forwards {clipId, fromSeconds, durationSeconds,
 *     maxPoints} verbatim (all three optional forward as undefined when
 *     omitted), round-trips the app's response verbatim, requires a UUID
 *     clipId, is registered via the STRICT-SCHEMA wrapper, and surfaces an
 *     app-side error (e.g. "no stored note table") as an MCP tool error
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
  assert.equal(calls[0]!.params["replaceExisting"], undefined,
    "omitted replaceExisting forwards as undefined -- never a fabricated true/false (C-F3)");

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
});

test("clip_auto_correct_pitch forwards every optional param explicitly, including replaceExisting", async () => {
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
      replaceExisting: false,
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
    replaceExisting: false,
  });
});

test("clip_auto_correct_pitch forwards replaceExisting:true literally (not just omitted)", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedResponse();

  await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, replaceExisting: true },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["replaceExisting"], true);
});

test("clip_auto_correct_pitch surfaces the replaceExisting:false refusal as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    "This clip's pitch edits (1 note(s)) have changed by hand since the last auto-correct " +
      "pass -- pitch moves, timing changes or drawn shapes -- and running a preset now would " +
      "replace ALL of them. Call again with replaceExisting:true (today's default -- just " +
      "omit the flag) to replace them anyway, or clip.clearPitchEdits first if you want to " +
      "start over deliberately."
  );

  const result = await client.callTool({
    name: "clip_auto_correct_pitch",
    arguments: { clipId, replaceExisting: false },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "the replaceExisting refusal must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /replaceExisting:true/);
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

// --- clip_set_note_pitch (pitch-editor command-surface door) ---------------

test("clip_set_note_pitch forwards {clipId, segmentId, cents} verbatim, and the response merges segmentId + the stored pitchOffsetCents", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const stubbed = makeStubbedResponse({
    segmentId,
    pitchOffsetCents: 50.0,
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_note_pitch",
    arguments: { clipId, segmentId, cents: 50 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNotePitch");
  assert.deepEqual(calls[0]!.params, { clipId, segmentId, cents: 50 });

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
});

test("clip_set_note_pitch sends cents ABSOLUTE, not accumulated — two calls with the same value forward the same value twice", async () => {
  // The tool itself holds no state to accumulate with; this pins that the
  // wire call carries the literal `cents` argument both times, which is the
  // client-observable half of the "absolute, not a delta" contract (the
  // clamp-and-store half is the DAWControl suite's job, unreachable from a
  // stubbed bridge).
  const clipId = randomUUID();
  const segmentId = randomUUID();
  queuedResult = makeStubbedResponse({ segmentId, pitchOffsetCents: 100 });
  await client.callTool({ name: "clip_set_note_pitch", arguments: { clipId, segmentId, cents: 100 } });
  queuedResult = makeStubbedResponse({ segmentId, pitchOffsetCents: 100 });
  await client.callTool({ name: "clip_set_note_pitch", arguments: { clipId, segmentId, cents: 100 } });

  assert.equal(calls.length, 2);
  assert.equal(calls[0]!.params["cents"], 100);
  assert.equal(calls[1]!.params["cents"], 100, "the second call still carries 100, not 200");
});

test("clip_set_note_pitch's cents is UNCHECKED at the schema layer — an out-of-range value still reaches the bridge (the clamp is the store's job)", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  // The app would clamp 9999 to 2400 and report that back; this test only
  // proves the MCP schema layer does not pre-empt the store by rejecting
  // the raw value itself — clamp-and-read-back is asserted in DAWControl.
  queuedResult = makeStubbedResponse({ segmentId, pitchOffsetCents: 2400 });
  const result = await client.callTool({
    name: "clip_set_note_pitch",
    arguments: { clipId, segmentId, cents: 9999 },
  });
  assert.equal(calls.length, 1, "an out-of-range cents must still reach the bridge, unclamped");
  assert.equal(calls[0]!.params["cents"], 9999, "the schema forwards the raw value, not a clamped one");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.equal(parseJSON(r).pitchOffsetCents, 2400, "the RESPONSE carries the app's clamped value");
});

test("clip_set_note_pitch requires clipId, segmentId (both UUID) and cents (schema layer, zero bridge calls)", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();

  let r = (await client.callTool({ name: "clip_set_note_pitch", arguments: { segmentId, cents: 10 } })) as any;
  assert.ok(r.isError, "missing clipId must be rejected");

  r = (await client.callTool({ name: "clip_set_note_pitch", arguments: { clipId, cents: 10 } })) as any;
  assert.ok(r.isError, "missing segmentId must be rejected");

  r = (await client.callTool({ name: "clip_set_note_pitch", arguments: { clipId, segmentId } })) as any;
  assert.ok(r.isError, "missing cents must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_pitch",
    arguments: { clipId: "not-a-uuid", segmentId, cents: 10 },
  })) as any;
  assert.ok(r.isError, "a non-UUID clipId must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_pitch",
    arguments: { clipId, segmentId: "not-a-uuid", cents: 10 },
  })) as any;
  assert.ok(r.isError, "a non-UUID segmentId must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_pitch",
    arguments: { clipId, segmentId, cents: "50" },
  })) as any;
  assert.ok(r.isError, "a string cents must be rejected");

  assert.equal(calls.length, 0, "every schema rejection above must never reach the bridge");
});

test("clip_set_note_pitch is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const result = (await client.callTool({
    name: "clip_set_note_pitch",
    arguments: { clipId, segmentId, cents: 10, bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_pitch surfaces an app-side error (e.g. MIDI clip, no stored table, unknown segmentId) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  queuedError = new Error(
    "This clip has no notes to edit yet — run clip.autoCorrectPitch first to build a note table."
  );

  const result = await client.callTool({
    name: "clip_set_note_pitch",
    arguments: { clipId, segmentId, cents: 10 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNotePitch");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /run clip\.autoCorrectPitch first/);
});

// --- clip_split_note (pitch-editor command-surface door) -------------------

test("clip_split_note forwards {clipId, segmentId, atSourceSeconds} verbatim, and the response merges leftSegmentId + rightSegmentId", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const rightSegmentId = randomUUID();
  const stubbed = makeStubbedResponse({
    segmentCount: 2,
    leftSegmentId: segmentId,
    rightSegmentId,
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_split_note",
    arguments: { clipId, segmentId, atSourceSeconds: 1.25 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.splitNote");
  assert.deepEqual(calls[0]!.params, { clipId, segmentId, atSourceSeconds: 1.25 });

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
  // Node's assert/strict `deepEqual` is an assertion signature
  // (`asserts actual is T`), so TS narrows `parsed` to `typeof stubbed`
  // after the line above — cast back to read a property generically, the
  // same shape parseJSON's own callers use everywhere else in this suite.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((parsed as any).leftSegmentId, segmentId, "the LEFT half keeps the parent's own id");
});

test("clip_split_note's atSourceSeconds is UNCHECKED at the schema layer — the 60ms minimum-half floor is the store's job", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  queuedError = new Error(
    "atSourceSeconds is too close to this note's edge — each half must be at least 60ms " +
      "long (note spans 0.000s-0.040s); pick a point nearer the middle."
  );

  const result = await client.callTool({
    name: "clip_split_note",
    arguments: { clipId, segmentId, atSourceSeconds: 0.001 },
  });

  assert.equal(calls.length, 1, "the too-close value must still reach the bridge — no schema pre-check exists");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "the store's minimum-half refusal must surface as a tool error");
  assert.match(r.content[0].text as string, /60ms/);
});

test("clip_split_note requires clipId, segmentId (both UUID) and atSourceSeconds (schema layer, zero bridge calls)", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();

  let r = (await client.callTool({
    name: "clip_split_note",
    arguments: { segmentId, atSourceSeconds: 1.0 },
  })) as any;
  assert.ok(r.isError, "missing clipId must be rejected");

  r = (await client.callTool({
    name: "clip_split_note",
    arguments: { clipId, atSourceSeconds: 1.0 },
  })) as any;
  assert.ok(r.isError, "missing segmentId must be rejected");

  r = (await client.callTool({ name: "clip_split_note", arguments: { clipId, segmentId } })) as any;
  assert.ok(r.isError, "missing atSourceSeconds must be rejected");

  r = (await client.callTool({
    name: "clip_split_note",
    arguments: { clipId: "not-a-uuid", segmentId, atSourceSeconds: 1.0 },
  })) as any;
  assert.ok(r.isError, "a non-UUID clipId must be rejected");

  assert.equal(calls.length, 0, "every schema rejection above must never reach the bridge");
});

test("clip_split_note is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const result = (await client.callTool({
    name: "clip_split_note",
    arguments: { clipId, segmentId, atSourceSeconds: 1.0, bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_split_note surfaces an app-side error (e.g. MIDI clip, no stored table) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  queuedError = new Error(
    `clip ${clipId} is a MIDI clip — clip.splitNote applies only to audio clips`
  );

  const result = await client.callTool({
    name: "clip_split_note",
    arguments: { clipId, segmentId, atSourceSeconds: 1.0 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.splitNote");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /is a MIDI clip/);
});

// --- clip_get_played_pitch (m23-ap C-0c) -----------------------------------

function makePlayedPitchResponse(extra: Record<string, unknown> = {}) {
  return {
    clipId: randomUUID(),
    basis: "render",
    unresolvedNoteIds: [],
    fromSeconds: 0,
    durationSeconds: 2.0,
    maxPoints: 2000,
    decimated: false,
    pointCount: 2,
    totalPointCount: 2,
    runs: [
      [
        { sourceSeconds: 0.008, editedSeconds: 0.008, sungMidi: 57.0, playedMidi: 57.5 },
        { sourceSeconds: 0.024, editedSeconds: 0.024, sungMidi: 57.1, playedMidi: 57.6 },
      ],
    ],
    ...extra,
  };
}

test("clip_get_played_pitch forwards {clipId} (bare) with every optional undefined, and returns the app's response verbatim", async () => {
  const clipId = randomUUID();
  const stubbed = makePlayedPitchResponse();
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_get_played_pitch",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.getPlayedPitch");
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.equal(calls[0]!.params["fromSeconds"], undefined, "an omitted param forwards as undefined, never a fabricated default");
  assert.equal(calls[0]!.params["durationSeconds"], undefined);
  assert.equal(calls[0]!.params["maxPoints"], undefined);

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim, including nested runs/points");
});

test("clip_get_played_pitch forwards every optional param explicitly", async () => {
  const clipId = randomUUID();
  queuedResult = makePlayedPitchResponse();

  await client.callTool({
    name: "clip_get_played_pitch",
    arguments: { clipId, fromSeconds: 1.5, durationSeconds: 3.0, maxPoints: 500 },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    clipId,
    fromSeconds: 1.5,
    durationSeconds: 3.0,
    maxPoints: 500,
  });
});

test("clip_get_played_pitch requires a UUID clipId (rejected at the schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({ name: "clip_get_played_pitch", arguments: {} })) as any;
  assert.ok(missing.isError);

  const notAUuid = (await client.callTool({
    name: "clip_get_played_pitch",
    arguments: { clipId: "not-a-uuid" },
  })) as any;
  assert.ok(notAUuid.isError);

  assert.equal(calls.length, 0);
});

test("clip_get_played_pitch: fromSeconds/durationSeconds/maxPoints are range-checked at the schema layer", async () => {
  const clipId = randomUUID();

  const badFrom = (await client.callTool({
    name: "clip_get_played_pitch",
    arguments: { clipId, fromSeconds: -1 },
  })) as any;
  assert.ok(badFrom.isError);

  const badDuration = (await client.callTool({
    name: "clip_get_played_pitch",
    arguments: { clipId, durationSeconds: 0 },
  })) as any;
  assert.ok(badDuration.isError);

  const badMaxPointsLow = (await client.callTool({
    name: "clip_get_played_pitch",
    arguments: { clipId, maxPoints: 0 },
  })) as any;
  assert.ok(badMaxPointsLow.isError);

  const badMaxPointsHigh = (await client.callTool({
    name: "clip_get_played_pitch",
    arguments: { clipId, maxPoints: 1_000_000 },
  })) as any;
  assert.ok(badMaxPointsHigh.isError);

  const badMaxPointsFraction = (await client.callTool({
    name: "clip_get_played_pitch",
    arguments: { clipId, maxPoints: 1.5 },
  })) as any;
  assert.ok(badMaxPointsFraction.isError);

  assert.equal(calls.length, 0, "schema rejections never reach the bridge");
});

test("clip_get_played_pitch is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const clipId = randomUUID();
  queuedResult = makePlayedPitchResponse();

  const result = (await client.callTool({
    name: "clip_get_played_pitch",
    arguments: { clipId, bogus: true },
  })) as any;

  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_get_played_pitch surfaces an app-side error (no stored note table) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    "This clip has no pitch edits yet, so there is nothing for clip.getPlayedPitch to read " +
      "back -- it shows what clip.autoCorrectPitch / clip.setNotePitch already did, not a " +
      "general-purpose pitch reader. Run clip.autoCorrectPitch first (or call clip.detectPitch " +
      "to hear the plain sung pitch with no edits at all)."
  );

  const result = await client.callTool({ name: "clip_get_played_pitch", arguments: { clipId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.getPlayedPitch");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /clip\.autoCorrectPitch/);
});

test("clip_get_played_pitch: an honest 'estimate' basis with an empty runs array (no wire-path detection) round-trips as-is", async () => {
  const clipId = randomUUID();
  const stubbed = makePlayedPitchResponse({
    basis: "estimate",
    reason: "The app couldn't analyse this recording (no model loaded), so wobble changes can't be applied. Pitch moves still play.",
    runs: [],
    pointCount: 0,
    totalPointCount: 0,
  });
  queuedResult = stubbed;

  const result = await client.callTool({ name: "clip_get_played_pitch", arguments: { clipId } });
  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "an empty-runs estimate is a normal success, not an error");
});
