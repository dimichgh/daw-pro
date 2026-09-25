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
 *
 * I7a (interaction-batch design section 10, ruled in section 17) adds
 * clip_set_note_cleared:
 *   - forwards {clipId, segmentIds, cleared} verbatim, response round-trips
 *   - requires clipId/segmentIds (array of UUID)/cleared at the schema layer
 *   - registered via the STRICT-SCHEMA wrapper
 *   - an app-side error (e.g. "no stored note table", ALL-OR-NOTHING unknown
 *     id) surfaces as an MCP tool error, message verbatim
 *
 * U-D (unpitched-notes-presets-midi-targets design section 1.8, as amended by
 * interaction-batch section 17.3) adds clip_set_note_gain, the level twin:
 *   - forwards {clipId, segmentIds, gainDb} verbatim, response round-trips
 *   - gainDb is UNCHECKED at the schema layer (the clamp is the store's job)
 *   - requires clipId/segmentIds (array of UUID)/gainDb at the schema layer
 *   - registered via the STRICT-SCHEMA wrapper
 *   - an app-side error surfaces as an MCP tool error, message verbatim
 *
 * m23-ap I4 wire leg (mcp-integration-engineer, part 1 of 2) adds
 * clip_set_note_pitches, the BATCH twin of clip_set_note_pitch (each note
 * carries its OWN cents, unlike clip_set_note_gain/clip_set_note_cleared's
 * one shared value):
 *   - forwards {clipId, notes} verbatim, response round-trips
 *   - each note's cents is UNCHECKED at the schema layer (the clamp is the
 *     store's job, the clip_set_note_pitch/clip_set_note_gain precedent)
 *   - requires clipId/notes (array of {segmentId, cents}) at the schema layer
 *   - the inner {segmentId, cents} object is ALSO `.strict()` (m30-c): an
 *     unrecognized key inside one `notes` element is rejected, not silently
 *     stripped
 *   - an empty `notes` array is NOT rejected at the schema layer (no
 *     `.min(1)`, the clip_set_note_cleared/clip_set_note_gain precedent) —
 *     it reaches the bridge, so the store's own teaching refusal ("Name at
 *     least one note to tune…") surfaces verbatim rather than a generic
 *     schema error
 *   - registered via the STRICT-SCHEMA wrapper
 *   - an app-side error (e.g. ALL-OR-NOTHING unknown id, a repeated id with
 *     two different cents) surfaces as an MCP tool error, message verbatim
 *
 * m23-ap I1 wire leg (mcp-integration-engineer, part 2 of 2) adds
 * clip_audition_note (HEAR one or more sung notes now, pitch edits
 * included -- design `2026-09-24-pitch-editor-interaction-batch.md` §4, §12):
 *   - forwards {clipId, segmentIds, contextSeconds} verbatim -- an omitted
 *     contextSeconds forwards as undefined, never a fabricated default (the
 *     app's own ClipNoteAuditionPolicy.contextSeconds, 0.060s, applies)
 *   - the response round-trips verbatim, including a REAL, non-throwing
 *     `audible:false` answer -- that is a SUCCESS, never a tool error
 *   - contextSeconds is UNCHECKED at the schema layer (the range 0...2 is
 *     the app's job, the clip_set_note_pitch cents/clip_set_note_gain
 *     gainDb precedent)
 *   - requires clipId and segmentIds (array of UUID) at the schema layer;
 *     an empty segmentIds array is NOT rejected at the schema layer (no
 *     `.min(1)`, the clip_set_note_pitches precedent) -- it reaches the
 *     bridge, so the store's own teaching refusal surfaces verbatim
 *   - registered via the STRICT-SCHEMA wrapper (the note_audition
 *     precedent this tool otherwise has the least in common with -- see
 *     server.ts for why: both are "sounds now, not an edit" doors)
 *   - an app-side error (e.g. ALL-OR-NOTHING unknown id, a MIDI clip)
 *     surfaces as an MCP tool error, message verbatim
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

// --- clip_set_note_cleared (I7a) --------------------------------------------

test("clip_set_note_cleared forwards {clipId, segmentIds, cleared} verbatim, and the response merges segmentIds + cleared", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const stubbed = makeStubbedResponse({
    segmentIds: [segmentId],
    cleared: true,
    segments: [
      {
        id: segmentId,
        startSeconds: 0.0,
        endSeconds: 0.5,
        detectedHz: 220.0,
        detectedConfidence: 0.95,
        pitchOffsetCents: 0,
        driftScale: 1.0,
        vibratoScale: 1.0,
        cleared: true,
      },
    ],
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_note_cleared",
    arguments: { clipId, segmentIds: [segmentId], cleared: true },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteCleared");
  assert.deepEqual(calls[0]!.params, { clipId, segmentIds: [segmentId], cleared: true });

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
});

test("clip_set_note_cleared forwards a MULTI-note segmentIds array verbatim, in request order (dedup is the store's job)", async () => {
  const clipId = randomUUID();
  const first = randomUUID();
  const second = randomUUID();
  queuedResult = makeStubbedResponse({ segmentIds: [first, second], cleared: false });

  await client.callTool({
    name: "clip_set_note_cleared",
    arguments: { clipId, segmentIds: [first, second], cleared: false },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params["segmentIds"], [first, second]);
  assert.equal(calls[0]!.params["cleared"], false);
});

test("clip_set_note_cleared requires clipId, segmentIds (array of UUID) and cleared (schema layer, zero bridge calls)", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();

  let r = (await client.callTool({
    name: "clip_set_note_cleared",
    arguments: { segmentIds: [segmentId], cleared: true },
  })) as any;
  assert.ok(r.isError, "missing clipId must be rejected");

  r = (await client.callTool({ name: "clip_set_note_cleared", arguments: { clipId, cleared: true } })) as any;
  assert.ok(r.isError, "missing segmentIds must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_cleared",
    arguments: { clipId, segmentIds: [segmentId] },
  })) as any;
  assert.ok(r.isError, "missing cleared must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_cleared",
    arguments: { clipId, segmentIds: ["not-a-uuid"], cleared: true },
  })) as any;
  assert.ok(r.isError, "a non-UUID entry in segmentIds must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_cleared",
    arguments: { clipId, segmentIds: segmentId, cleared: true },
  })) as any;
  assert.ok(r.isError, "a bare string segmentIds (not an array) must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_cleared",
    arguments: { clipId, segmentIds: [segmentId], cleared: "yes" },
  })) as any;
  assert.ok(r.isError, "a non-boolean cleared must be rejected");

  assert.equal(calls.length, 0, "every schema rejection above must never reach the bridge");
});

test("clip_set_note_cleared is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const result = (await client.callTool({
    name: "clip_set_note_cleared",
    arguments: { clipId, segmentIds: [segmentId], cleared: true, bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_cleared surfaces an app-side error (e.g. ALL-OR-NOTHING unknown id) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  queuedError = new Error(
    "No note with id 11111111-1111-1111-1111-111111111111 on clip " + clipId + ". That clip carries 1 note(s)."
  );

  const result = await client.callTool({
    name: "clip_set_note_cleared",
    arguments: { clipId, segmentIds: [segmentId], cleared: true },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteCleared");
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /No note with id/);
});

// --- clip_set_note_gain (U-D, the per-note LEVEL verb) ----------------------

test("clip_set_note_gain forwards {clipId, segmentIds, gainDb} verbatim, and the response merges segmentIds + gainDb", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const stubbed = makeStubbedResponse({
    segmentIds: [segmentId],
    gainDb: -6,
    segments: [
      {
        id: segmentId,
        startSeconds: 0.0,
        endSeconds: 0.5,
        detectedHz: 220.0,
        detectedConfidence: 0.95,
        pitchOffsetCents: 0,
        driftScale: 1.0,
        vibratoScale: 1.0,
        amplitudeDb: -6,
      },
    ],
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_note_gain",
    arguments: { clipId, segmentIds: [segmentId], gainDb: -6 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteGain");
  assert.deepEqual(calls[0]!.params, { clipId, segmentIds: [segmentId], gainDb: -6 });

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
});

test("clip_set_note_gain's gainDb is UNCHECKED at the schema layer — an out-of-range value still reaches the bridge (the clamp is the store's job)", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  // The app would clamp 999 to 24 (Clip.gainDbRange) and report that back;
  // this test only proves the MCP schema layer does not pre-empt the store
  // by rejecting the raw value itself — clamp-and-read-back is asserted in
  // DAWControl.
  queuedResult = makeStubbedResponse({ segmentIds: [segmentId], gainDb: 24 });
  const result = await client.callTool({
    name: "clip_set_note_gain",
    arguments: { clipId, segmentIds: [segmentId], gainDb: 999 },
  });
  assert.equal(calls.length, 1, "an out-of-range gainDb must still reach the bridge, unclamped");
  assert.equal(calls[0]!.params["gainDb"], 999, "the schema forwards the raw value, not a clamped one");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.equal(parseJSON(r).gainDb, 24, "the RESPONSE carries the app's clamped value");
});

test("clip_set_note_gain requires clipId, segmentIds (array of UUID) and gainDb (schema layer, zero bridge calls)", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();

  let r = (await client.callTool({
    name: "clip_set_note_gain",
    arguments: { segmentIds: [segmentId], gainDb: -6 },
  })) as any;
  assert.ok(r.isError, "missing clipId must be rejected");

  r = (await client.callTool({ name: "clip_set_note_gain", arguments: { clipId, gainDb: -6 } })) as any;
  assert.ok(r.isError, "missing segmentIds must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_gain",
    arguments: { clipId, segmentIds: [segmentId] },
  })) as any;
  assert.ok(r.isError, "missing gainDb must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_gain",
    arguments: { clipId, segmentIds: ["not-a-uuid"], gainDb: -6 },
  })) as any;
  assert.ok(r.isError, "a non-UUID entry in segmentIds must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_gain",
    arguments: { clipId, segmentIds: segmentId, gainDb: -6 },
  })) as any;
  assert.ok(r.isError, "a bare string segmentIds (not an array) must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_gain",
    arguments: { clipId, segmentIds: [segmentId], gainDb: "-6" },
  })) as any;
  assert.ok(r.isError, "a string gainDb must be rejected");

  assert.equal(calls.length, 0, "every schema rejection above must never reach the bridge");
});

test("clip_set_note_gain is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const result = (await client.callTool({
    name: "clip_set_note_gain",
    arguments: { clipId, segmentIds: [segmentId], gainDb: -6, bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_gain surfaces an app-side error (e.g. no stored note table) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  queuedError = new Error(
    "This clip has no notes to edit yet — run clip.autoCorrectPitch first to build a note table."
  );

  const result = await client.callTool({
    name: "clip_set_note_gain",
    arguments: { clipId, segmentIds: [segmentId], gainDb: -6 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteGain");
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /run clip\.autoCorrectPitch first/);
});

// --- clip_set_note_pitches (m23-ap I4 wire leg, the BATCH twin of clip_set_note_pitch) ---

test("clip_set_note_pitches forwards {clipId, notes} verbatim, and the response merges notes (echoed from the app)", async () => {
  const clipId = randomUUID();
  const segmentIdA = randomUUID();
  const segmentIdB = randomUUID();
  const stubbed = makeStubbedResponse({
    notes: [
      { segmentId: segmentIdA, pitchOffsetCents: 50 },
      { segmentId: segmentIdB, pitchOffsetCents: -30 },
    ],
    segments: [
      {
        id: segmentIdA,
        startSeconds: 0.0,
        endSeconds: 0.5,
        detectedHz: 220.0,
        detectedConfidence: 0.95,
        pitchOffsetCents: 50,
        driftScale: 1.0,
        vibratoScale: 1.0,
      },
      {
        id: segmentIdB,
        startSeconds: 0.5,
        endSeconds: 1.0,
        detectedHz: 246.94,
        detectedConfidence: 0.95,
        pitchOffsetCents: -30,
        driftScale: 1.0,
        vibratoScale: 1.0,
      },
    ],
  });
  queuedResult = stubbed;

  const notes = [
    { segmentId: segmentIdA, cents: 50 },
    { segmentId: segmentIdB, cents: -30 },
  ];
  const result = await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNotePitches");
  assert.deepEqual(calls[0]!.params, { clipId, notes });

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
});

test("clip_set_note_pitches's cents is UNCHECKED at the schema layer, per note — an out-of-range value still reaches the bridge (the clamp is the store's job)", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  // The app would clamp 9999 to 2400 (NoteSegment.pitchOffsetCentsRange) and
  // report that back; this test only proves the MCP schema layer does not
  // pre-empt the store by rejecting the raw value itself — clamp-and-read-back
  // is asserted in DAWControl.
  queuedResult = makeStubbedResponse({ notes: [{ segmentId, pitchOffsetCents: 2400 }] });
  const result = await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes: [{ segmentId, cents: 9999 }] },
  });
  assert.equal(calls.length, 1, "an out-of-range cents must still reach the bridge, unclamped");
  assert.deepEqual(
    calls[0]!.params["notes"],
    [{ segmentId, cents: 9999 }],
    "the schema forwards the raw value, not a clamped one"
  );
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.equal(parseJSON(r).notes[0].pitchOffsetCents, 2400, "the RESPONSE carries the app's clamped value");
});

test("clip_set_note_pitches requires clipId and notes (array of {segmentId, cents}) at the schema layer, zero bridge calls", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();

  let r = (await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { notes: [{ segmentId, cents: 50 }] },
  })) as any;
  assert.ok(r.isError, "missing clipId must be rejected");

  r = (await client.callTool({ name: "clip_set_note_pitches", arguments: { clipId } })) as any;
  assert.ok(r.isError, "missing notes must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes: segmentId },
  })) as any;
  assert.ok(r.isError, "a bare string notes (not an array) must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes: ["not-an-object"] },
  })) as any;
  assert.ok(r.isError, "a notes element that is not an object must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes: [{ segmentId: "not-a-uuid", cents: 50 }] },
  })) as any;
  assert.ok(r.isError, "a non-UUID segmentId inside a notes element must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes: [{ segmentId }] },
  })) as any;
  assert.ok(r.isError, "a notes element missing cents must be rejected");

  r = (await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes: [{ segmentId, cents: "50" }] },
  })) as any;
  assert.ok(r.isError, "a string cents inside a notes element must be rejected");

  assert.equal(calls.length, 0, "every schema rejection above must never reach the bridge");
});

test("clip_set_note_pitches: an unrecognized key INSIDE one notes[] element is rejected (m30-c nested-strict)", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const result = (await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes: [{ segmentId, cents: 50, bogus: true }] },
  })) as any;
  assert.ok(result.isError, "a typo'd field inside a notes element must be REJECTED, not silently stripped");
  assert.equal(calls.length, 0);
});

test("clip_set_note_pitches: an empty notes array is NOT rejected at the schema layer — it reaches the bridge (no .min(1))", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    "Name at least one note to tune. Read the clip's note ids with `clip.getPitchEdits` first."
  );
  const result = await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes: [] },
  });
  assert.equal(calls.length, 1, "an empty notes array must reach the bridge, not be pre-empted by the schema");
  assert.deepEqual(calls[0]!.params, { clipId, notes: [] });
  const r = result as any;
  assert.ok(r.isError, "the store's own empty-list refusal must surface as a tool error");
  assert.match(r.content[0].text as string, /Name at least one note to tune/);
});

test("clip_set_note_pitches is registered via the STRICT-SCHEMA wrapper: an unrecognized top-level argument IS rejected", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const result = (await client.callTool({
    name: "clip_set_note_pitches",
    arguments: { clipId, notes: [{ segmentId, cents: 50 }], bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_pitches surfaces an app-side error (e.g. ALL-OR-NOTHING unknown id, or a repeated id with two different cents) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  queuedError = new Error(
    "No note with id 11111111-1111-1111-1111-111111111111 on clip " +
      clipId +
      ". That clip carries 2 note(s); read them back with `clip.getPitchEdits` before editing one."
  );

  const result = await client.callTool({
    name: "clip_set_note_pitches",
    arguments: {
      clipId,
      notes: [
        { segmentId, cents: 50 },
        { segmentId: "11111111-1111-1111-1111-111111111111", cents: 50 },
      ],
    },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNotePitches");
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /No note with id .* 2 note\(s\)/);
});

// --- clip_audition_note (m23-ap I1 wire leg, part 2 of 2) -------------------

function makeAuditionResponse(extra: Record<string, unknown> = {}) {
  return {
    clipId: randomUUID(),
    segmentIds: [randomUUID()],
    startSeconds: 1.94,
    endSeconds: 2.61,
    source: "render",
    audible: true,
    outcome: "sounded",
    reason: null,
    ...extra,
  };
}

test("clip_audition_note forwards {clipId, segmentIds} with contextSeconds undefined when omitted, and the response round-trips verbatim", async () => {
  const clipId = randomUUID();
  const segmentIds = [randomUUID(), randomUUID()];
  const stubbed = makeAuditionResponse({ clipId, segmentIds });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_audition_note",
    arguments: { clipId, segmentIds },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.auditionNote");
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.deepEqual(calls[0]!.params["segmentIds"], segmentIds);
  assert.equal(calls[0]!.params["contextSeconds"], undefined,
    "an omitted contextSeconds forwards as undefined, never a fabricated default");

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
});

test("clip_audition_note forwards contextSeconds explicitly when given", async () => {
  const clipId = randomUUID();
  const segmentIds = [randomUUID()];
  queuedResult = makeAuditionResponse({ clipId, segmentIds });

  await client.callTool({
    name: "clip_audition_note",
    arguments: { clipId, segmentIds, contextSeconds: 0.3 },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { clipId, segmentIds, contextSeconds: 0.3 });
});

test("clip_audition_note: a REAL, non-throwing audible:false answer round-trips as a SUCCESS, never a tool error", async () => {
  const clipId = randomUUID();
  const segmentIds = [randomUUID()];
  queuedResult = makeAuditionResponse({
    clipId,
    segmentIds,
    audible: false,
    outcome: null,
    reason: "transport-running",
  });

  const result = (await client.callTool({
    name: "clip_audition_note",
    arguments: { clipId, segmentIds },
  })) as any;

  assert.equal(calls.length, 1);
  assert.ok(!result.isError, "a refusal without a throw is a SUCCESS, never a tool error");
  const parsed = parseJSON(result);
  assert.equal(parsed.audible, false);
  assert.equal(parsed.reason, "transport-running");
});

test("clip_audition_note: contextSeconds is UNCHECKED at the schema layer — an out-of-range value still reaches the bridge (the range check is the app's job)", async () => {
  const clipId = randomUUID();
  const segmentIds = [randomUUID()];
  queuedError = new Error("contextSeconds must be 0…2 s, got 9");

  const result = await client.callTool({
    name: "clip_audition_note",
    arguments: { clipId, segmentIds, contextSeconds: 9 },
  });

  assert.equal(calls.length, 1, "the schema must not pre-empt an out-of-range contextSeconds");
  assert.deepEqual(
    calls[0]!.params["contextSeconds"],
    9,
    "the schema forwards the raw value, not a clamped or rejected one"
  );
  const r = result as any;
  assert.ok(r.isError, "the app's own range refusal must surface as a tool error");
  assert.match(r.content[0].text as string, /contextSeconds must be/);
});

test("clip_audition_note requires clipId and segmentIds (array of UUID) at the schema layer, zero bridge calls", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();

  let r = (await client.callTool({
    name: "clip_audition_note",
    arguments: { segmentIds: [segmentId] },
  })) as any;
  assert.ok(r.isError, "missing clipId must be rejected");

  r = (await client.callTool({ name: "clip_audition_note", arguments: { clipId } })) as any;
  assert.ok(r.isError, "missing segmentIds must be rejected");

  r = (await client.callTool({
    name: "clip_audition_note",
    arguments: { clipId, segmentIds: segmentId },
  })) as any;
  assert.ok(r.isError, "a bare string segmentIds (not an array) must be rejected");

  r = (await client.callTool({
    name: "clip_audition_note",
    arguments: { clipId, segmentIds: ["not-a-uuid"] },
  })) as any;
  assert.ok(r.isError, "a non-UUID segmentIds element must be rejected");

  r = (await client.callTool({
    name: "clip_audition_note",
    arguments: { clipId, segmentIds: [segmentId], contextSeconds: "loud" },
  })) as any;
  assert.ok(r.isError, "a non-numeric contextSeconds must be rejected");

  assert.equal(calls.length, 0, "every schema rejection above must never reach the bridge");
});

test("clip_audition_note: an empty segmentIds array is NOT rejected at the schema layer — it reaches the bridge (no .min(1))", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    "Name at least one note to hear. Read the clip's note ids with `clip.getPitchEdits` first."
  );
  const result = await client.callTool({
    name: "clip_audition_note",
    arguments: { clipId, segmentIds: [] },
  });
  assert.equal(calls.length, 1, "an empty segmentIds array must reach the bridge, not be pre-empted by the schema");
  // contextSeconds is present as an explicit `undefined` VALUE (the object
  // literal in the tool handler always names the key), not an ABSENT key —
  // the same shape the very first clip_audition_note test above pins via
  // calls[0]!.params["contextSeconds"] === undefined; deepEqual here must
  // match that actual shape, not the key-omitted shape clip_set_note_pitches's
  // {clipId, notes} sibling test could assume (neither of ITS two params is
  // optional, so it never has this third key at all).
  assert.deepEqual(calls[0]!.params, { clipId, segmentIds: [], contextSeconds: undefined });
  const r = result as any;
  assert.ok(r.isError, "the store's own empty-list refusal must surface as a tool error");
  assert.match(r.content[0].text as string, /Name at least one note to hear/);
});

test("clip_audition_note is registered via the STRICT-SCHEMA wrapper: an unrecognized top-level argument IS rejected", async () => {
  const clipId = randomUUID();
  const segmentIds = [randomUUID()];
  const result = (await client.callTool({
    name: "clip_audition_note",
    arguments: { clipId, segmentIds, bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_audition_note surfaces an app-side error (e.g. ALL-OR-NOTHING unknown id, or a MIDI clip) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  queuedError = new Error(
    "No note with id 11111111-1111-1111-1111-111111111111 on clip " +
      clipId +
      ". That clip carries 1 note(s); read them back with `clip.getPitchEdits`."
  );

  const result = await client.callTool({
    name: "clip_audition_note",
    arguments: {
      clipId,
      segmentIds: [segmentId, "11111111-1111-1111-1111-111111111111"],
    },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.auditionNote");
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /No note with id .* 1 note\(s\)/);
});
