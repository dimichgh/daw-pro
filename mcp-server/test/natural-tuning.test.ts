/**
 * natural-tuning.test.ts — wiring coverage for NT-W's six natural-tuning
 * verbs (docs/design/2026-09-25-natural-tuning.md §1(e)/§4.e, and NT-C C2's
 * §2e consonant setter): the two VOICE (formant) tools, the three SLIDE
 * (transition) tools, and the CONSONANT-PROTECTION toggle.
 *
 * The clip-detect-pitch.test.ts / pitch-correction.test.ts stub-bridge
 * pattern verbatim: monkeypatch `DawBridge.prototype.send` before importing
 * the real `McpServer`, drive each tool over an in-memory transport, and
 * assert:
 *   - clip_set_note_formant forwards {clipId, segmentIds, formantSemitones}
 *     verbatim; requires all three at the schema layer; registered via the
 *     STRICT-SCHEMA wrapper; an app-side error (a refusal sentence, or
 *     ALL-OR-NOTHING unknown id) surfaces as an MCP tool error, verbatim
 *   - clip_set_formant_correction forwards {clipId, amount} verbatim —
 *     `amount` is number|null, REQUIRED (an omitted key forwards as
 *     `undefined`, which JSON.stringify drops before the wire, so it reads
 *     as genuinely absent there too — never silently treated as `null`)
 *   - clip_set_note_transition forwards {clipId, noteId, widthMs} verbatim,
 *     `widthMs` number|null, REQUIRED the same way
 *   - clip_set_pitch_transition_smoothness forwards {clipId,
 *     centsPerSecond} verbatim, REQUIRED the same way
 *   - clip_set_note_glide_follow forwards {clipId, noteId, amount} verbatim,
 *     `amount` a plain required number (never null)
 *   - clip_set_consonant_protection forwards {clipId, enabled} verbatim, a
 *     plain required boolean; NT-E2 has landed, so its text is present-tense
 *     honest about the live render mix, not a forward-looking prediction
 *   - every one of the six is registered via the STRICT-SCHEMA wrapper
 *   - the teaching-text additions this lane made to clip_set_note_pitch,
 *     clip_set_stretch and clip_get_pitch_edits are present, and
 *     clip_auto_correct_pitch's stale "always 0" formant text is gone
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
  client = new Client({ name: "natural-tuning-test-client", version: "0.0.0" });
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
    analysisVersion: 1,
    retuneMs: 30,
    formantCorrection: null,
    transitionSlopeCentsPerSecond: 0,
    predatesNaturalTuning: false,
    keepConsonantsUntuned: false,
    consonantProtection: { active: false, inactiveReason: null },
    segmentCount: 1,
    isIdentity: false,
    handEditedSinceAutoCorrect: false,
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
        formantOffsetSemitones: 0,
        transitionOutMs: 0,
        glideFollow: 0,
        joinToNext: "last",
        effectiveTransitionMs: null,
        origin: "detected",
      },
    ],
    warnings: [],
    ...extra,
  };
}

// --- clip_set_note_formant ---------------------------------------------

test("clip_set_note_formant forwards {clipId, segmentIds, formantSemitones} verbatim, and the response round-trips", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  const stubbed = makeStubbedResponse({
    segmentIds: [segmentId],
    formantSemitones: -2,
    formantCorrection: null,
    clamped: false,
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_note_formant",
    arguments: { clipId, segmentIds: [segmentId], formantSemitones: -2 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteFormant");
  assert.deepEqual(calls[0]!.params, { clipId, segmentIds: [segmentId], formantSemitones: -2 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_set_note_formant requires clipId, segmentIds (array of UUID) and formantSemitones at the schema layer, zero bridge calls", async () => {
  const clipId = randomUUID();

  const missingClipId = await client.callTool({
    name: "clip_set_note_formant",
    arguments: { segmentIds: [randomUUID()], formantSemitones: 1 },
  });
  const missingSegmentIds = await client.callTool({
    name: "clip_set_note_formant",
    arguments: { clipId, formantSemitones: 1 },
  });
  const badSegmentId = await client.callTool({
    name: "clip_set_note_formant",
    arguments: { clipId, segmentIds: ["not-a-uuid"], formantSemitones: 1 },
  });
  const missingFormant = await client.callTool({
    name: "clip_set_note_formant",
    arguments: { clipId, segmentIds: [randomUUID()] },
  });

  for (const response of [missingClipId, missingSegmentIds, badSegmentId, missingFormant]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((response as any).isError, JSON.stringify(response));
  }
  assert.equal(calls.length, 0, "a schema-layer rejection must never reach the bridge");
});

test("clip_set_note_formant's formantSemitones is UNCHECKED at the schema layer — an out-of-range value still reaches the bridge (the clamp is the app's job)", async () => {
  const clipId = randomUUID();
  const segmentId = randomUUID();
  queuedResult = makeStubbedResponse();

  await client.callTool({
    name: "clip_set_note_formant",
    arguments: { clipId, segmentIds: [segmentId], formantSemitones: 999 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.formantSemitones, 999);
});

test("clip_set_note_formant is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const result = await client.callTool({
    name: "clip_set_note_formant",
    arguments: { clipId: randomUUID(), segmentIds: [randomUUID()], formantSemitones: 1, bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_formant surfaces an app-side error (e.g. a SOUND named among the ids) as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "Note deadbeef is a sound with no sung pitch (a breath or a consonant), so it has no voice to make deeper or brighter. Nothing was changed. Name sung notes only."
  );
  const result = await client.callTool({
    name: "clip_set_note_formant",
    arguments: { clipId: randomUUID(), segmentIds: [randomUUID()], formantSemitones: 1 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /no voice to make deeper or brighter/);
});

// --- clip_set_formant_correction ----------------------------------------

test("clip_set_formant_correction forwards {clipId, amount} verbatim (a number), response round-trips", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedResponse({
    formantCorrection: 0.75,
    amount: 0.75,
    clamped: false,
    plainLanguage: "Voice kept natural: 75 %.",
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_formant_correction",
    arguments: { clipId, amount: 0.75 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setFormantCorrection");
  assert.deepEqual(calls[0]!.params, { clipId, amount: 0.75 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_set_formant_correction forwards amount:null literally (not omitted) — legacy request", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedResponse({ formantCorrection: null, amount: null, clamped: false });

  await client.callTool({ name: "clip_set_formant_correction", arguments: { clipId, amount: null } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.clipId, clipId);
  assert.equal(calls[0]!.params.amount, null, "an explicit null must forward as null, not undefined");
  assert.ok("amount" in calls[0]!.params, "the amount key must be PRESENT (value null), not dropped");
});

test("clip_set_formant_correction: an OMITTED amount forwards as undefined, which JSON.stringify would drop before the wire — the schema layer alone does not refuse it (the app's own required-key refusal is a deeper, separate defense)", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedResponse();

  const result = await client.callTool({ name: "clip_set_formant_correction", arguments: { clipId } });

  assert.equal(calls.length, 1, "an omitted nullable-optional field still reaches the bridge");
  assert.equal(calls[0]!.params.amount, undefined);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal((result as any).isError, undefined);
});

test("clip_set_formant_correction requires a UUID clipId (schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({
    name: "clip_set_formant_correction",
    arguments: { clipId: "not-a-uuid", amount: 0.5 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_formant_correction is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const result = await client.callTool({
    name: "clip_set_formant_correction",
    arguments: { clipId: randomUUID(), amount: 0.5, bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_formant_correction surfaces the app's required-key refusal as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "'amount' is required: a number from 0 to 1, or null to go back to the behaviour from before voice-keeping. Nothing was changed."
  );
  const result = await client.callTool({ name: "clip_set_formant_correction", arguments: { clipId: randomUUID() } });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /'amount' is required/);
});

// --- clip_set_note_transition --------------------------------------------

test("clip_set_note_transition forwards {clipId, noteId, widthMs} verbatim (a number), response round-trips", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  const stubbed = makeStubbedResponse({
    noteId,
    widthMs: 150,
    effectiveWidthMs: 150,
    joinToNext: "soft",
    clamped: false,
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_note_transition",
    arguments: { clipId, noteId, widthMs: 150 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteTransition");
  assert.deepEqual(calls[0]!.params, { clipId, noteId, widthMs: 150 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_set_note_transition forwards widthMs:null literally (Auto)", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  queuedResult = makeStubbedResponse({ noteId, widthMs: 0, joinToNext: "soft" });

  await client.callTool({ name: "clip_set_note_transition", arguments: { clipId, noteId, widthMs: null } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.widthMs, null);
  assert.ok("widthMs" in calls[0]!.params);
});

test("clip_set_note_transition requires clipId, noteId (both UUID) at the schema layer, zero bridge calls", async () => {
  const missingClipId = await client.callTool({
    name: "clip_set_note_transition",
    arguments: { noteId: randomUUID(), widthMs: 100 },
  });
  const missingNoteId = await client.callTool({
    name: "clip_set_note_transition",
    arguments: { clipId: randomUUID(), widthMs: 100 },
  });
  const badNoteId = await client.callTool({
    name: "clip_set_note_transition",
    arguments: { clipId: randomUUID(), noteId: "not-a-uuid", widthMs: 100 },
  });
  for (const response of [missingClipId, missingNoteId, badNoteId]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((response as any).isError);
  }
  assert.equal(calls.length, 0);
});

test("clip_set_note_transition's widthMs is UNCHECKED at the schema layer — an out-of-range value still reaches the bridge (the clamp is the app's job)", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  queuedResult = makeStubbedResponse();

  await client.callTool({ name: "clip_set_note_transition", arguments: { clipId, noteId, widthMs: 5000 } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.widthMs, 5000);
});

test("clip_set_note_transition is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const result = await client.callTool({
    name: "clip_set_note_transition",
    arguments: { clipId: randomUUID(), noteId: randomUUID(), widthMs: 100, bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_transition surfaces an app-side error (e.g. a note followed by a gap) as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "Note deadbeef is followed by a gap (a silence, a breath or a consonant) before the next sung note, so there is no slide between them to shape. Nothing was changed."
  );
  const result = await client.callTool({
    name: "clip_set_note_transition",
    arguments: { clipId: randomUUID(), noteId: randomUUID(), widthMs: 100 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /no slide between them to shape/);
});

// --- clip_set_pitch_transition_smoothness --------------------------------

test("clip_set_pitch_transition_smoothness forwards {clipId, centsPerSecond} verbatim, response round-trips", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedResponse({ transitionSlopeCentsPerSecond: 6000, centsPerSecond: 6000, clamped: false });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_pitch_transition_smoothness",
    arguments: { clipId, centsPerSecond: 6000 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setPitchTransitionSmoothness");
  assert.deepEqual(calls[0]!.params, { clipId, centsPerSecond: 6000 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_set_pitch_transition_smoothness forwards centsPerSecond:null literally (the default)", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedResponse({ transitionSlopeCentsPerSecond: 3000 });

  await client.callTool({ name: "clip_set_pitch_transition_smoothness", arguments: { clipId, centsPerSecond: null } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.centsPerSecond, null);
});

test("clip_set_pitch_transition_smoothness requires a UUID clipId (schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({
    name: "clip_set_pitch_transition_smoothness",
    arguments: { clipId: "not-a-uuid", centsPerSecond: 3000 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_pitch_transition_smoothness is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const result = await client.callTool({
    name: "clip_set_pitch_transition_smoothness",
    arguments: { clipId: randomUUID(), centsPerSecond: 3000, bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_pitch_transition_smoothness surfaces the app's 0-is-refused sentence as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "The slide smoothness has to be a speed from 500 to 20000 cents per second, or null for the default (3000). 0 is not a setting: to go back to how this vocal slid before, use Undo. Nothing was changed."
  );
  const result = await client.callTool({
    name: "clip_set_pitch_transition_smoothness",
    arguments: { clipId: randomUUID(), centsPerSecond: 0 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /0 is not a setting/);
});

// --- clip_set_note_glide_follow ------------------------------------------

test("clip_set_note_glide_follow forwards {clipId, noteId, amount} verbatim, response round-trips", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  const stubbed = makeStubbedResponse({ noteId, amount: 1, clamped: false });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_note_glide_follow",
    arguments: { clipId, noteId, amount: 1 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setNoteGlideFollow");
  assert.deepEqual(calls[0]!.params, { clipId, noteId, amount: 1 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_set_note_glide_follow requires clipId, noteId (both UUID) and amount at the schema layer, zero bridge calls", async () => {
  const missingClipId = await client.callTool({
    name: "clip_set_note_glide_follow",
    arguments: { noteId: randomUUID(), amount: 1 },
  });
  const missingNoteId = await client.callTool({
    name: "clip_set_note_glide_follow",
    arguments: { clipId: randomUUID(), amount: 1 },
  });
  const missingAmount = await client.callTool({
    name: "clip_set_note_glide_follow",
    arguments: { clipId: randomUUID(), noteId: randomUUID() },
  });
  for (const response of [missingClipId, missingNoteId, missingAmount]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((response as any).isError);
  }
  assert.equal(calls.length, 0);
});

test("clip_set_note_glide_follow's amount is UNCHECKED at the schema layer — an out-of-range value still reaches the bridge (the clamp is the app's job)", async () => {
  const clipId = randomUUID();
  const noteId = randomUUID();
  queuedResult = makeStubbedResponse();

  await client.callTool({ name: "clip_set_note_glide_follow", arguments: { clipId, noteId, amount: 42 } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.amount, 42);
});

test("clip_set_note_glide_follow is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const result = await client.callTool({
    name: "clip_set_note_glide_follow",
    arguments: { clipId: randomUUID(), noteId: randomUUID(), amount: 1, bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_note_glide_follow surfaces an app-side error (e.g. nothing to follow) as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "Note deadbeef meets no sung note on either side (there is a gap before it and after it), so there is nothing for it to follow. Nothing was changed. Name a slide that sits between two notes."
  );
  const result = await client.callTool({
    name: "clip_set_note_glide_follow",
    arguments: { clipId: randomUUID(), noteId: randomUUID(), amount: 1 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /nothing for it to follow/);
});

// --- clip_set_consonant_protection (NT-E2 landed, mix is live) ------------

test("clip_set_consonant_protection forwards {clipId, enabled} verbatim, response round-trips", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedResponse({
    keepConsonantsUntuned: true,
    consonantProtection: { active: false, inactiveReason: null },
    enabled: true,
  });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_set_consonant_protection",
    arguments: { clipId, enabled: true },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.setConsonantProtection");
  assert.deepEqual(calls[0]!.params, { clipId, enabled: true });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_set_consonant_protection requires clipId (UUID) and enabled (boolean) at the schema layer, zero bridge calls", async () => {
  const missingClipId = await client.callTool({
    name: "clip_set_consonant_protection",
    arguments: { enabled: true },
  });
  const missingEnabled = await client.callTool({
    name: "clip_set_consonant_protection",
    arguments: { clipId: randomUUID() },
  });
  const badClipId = await client.callTool({
    name: "clip_set_consonant_protection",
    arguments: { clipId: "not-a-uuid", enabled: true },
  });
  const badEnabled = await client.callTool({
    name: "clip_set_consonant_protection",
    arguments: { clipId: randomUUID(), enabled: "yes" },
  });
  for (const response of [missingClipId, missingEnabled, badClipId, badEnabled]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((response as any).isError, JSON.stringify(response));
  }
  assert.equal(calls.length, 0);
});

test("clip_set_consonant_protection is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const result = await client.callTool({
    name: "clip_set_consonant_protection",
    arguments: { clipId: randomUUID(), enabled: true, bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_set_consonant_protection surfaces the app's no-tuning refusal as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "This clip has no tuning yet, so there are no breaths or consonants to keep untouched. Tune it first (the note editor or `clip.autoCorrectPitch`); new tuning already keeps S, T and breath sounds at their own pitch."
  );
  const result = await client.callTool({
    name: "clip_set_consonant_protection",
    arguments: { clipId: randomUUID(), enabled: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /no breaths or consonants to keep untouched/);
});

test("clip_set_consonant_protection's own text is present-tense honest: the mix is live, not held on NT-E2", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_set_consonant_protection");
  assert.ok(tool, "clip_set_consonant_protection is registered");
  const description = tool!.description ?? "";
  assert.match(
    description,
    /Keeps breaths and consonants \(s, t, p, ch\) at the singer's original pitch when notes are moved/
  );
  assert.match(description, /10 ms blend at each note edge/);
  assert.match(description, /gap shorter than 64 ms stays tuned/);
  // ⭐ `active` never promises more than the render checks — the honest
  // present-tense replacement for the old forward-looking prediction.
  assert.match(description, /never promises more than the render does/);
  assert.doesNotMatch(description, /HELD ON NT-E2/);
  assert.doesNotMatch(description, /does not exist yet/i);
  assert.doesNotMatch(description, /changes NOTHING you hear today/);
  assert.doesNotMatch(description, /WILL engage once NT-E2 lands/);
  assert.doesNotMatch(description, /is ALWAYS false/i);
});

// --- Teaching-text additions ----------------------------------------------

test("clip_set_note_pitch's description carries the 3+ semitone formant teaching sentence", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_set_note_pitch");
  assert.ok(tool, "clip_set_note_pitch is registered");
  assert.match(
    tool!.description ?? "",
    /Moving a note 3\+ semitones\? Formants are kept natural by `formantCorrection`/
  );
  assert.match(tool!.description ?? "", /clip_set_note_formant/);
});

test("clip_set_stretch's formantPreserve field says it governs the WHOLE-CLIP transpose only", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_set_stretch");
  assert.ok(tool, "clip_set_stretch is registered");
  const schema = tool!.inputSchema as { properties?: Record<string, { description?: string }> };
  const description = schema.properties?.formantPreserve?.description ?? "";
  assert.match(description, /WHOLE-CLIP transpose only/);
  assert.match(description, /clip_set_formant_correction/);
});

test("clip_get_pitch_edits' description names every new natural-tuning field", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_get_pitch_edits");
  assert.ok(tool, "clip_get_pitch_edits is registered");
  const description = tool!.description ?? "";
  for (const field of [
    "formantCorrection",
    "transitionSlopeCentsPerSecond",
    "predatesNaturalTuning",
    "keepConsonantsUntuned",
    "consonantsOffByChoice",
    "consonantProtection",
    "transitionOutMs",
    "glideFollow",
    "joinToNext",
    "effectiveTransitionMs",
  ]) {
    assert.ok(description.includes(field), `clip_get_pitch_edits' description is missing '${field}'`);
  }
});

test("clip_auto_correct_pitch's formantOffsetSemitones text is no longer the stale 'always 0' claim", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_auto_correct_pitch");
  assert.ok(tool, "clip_auto_correct_pitch is registered");
  const description = tool!.description ?? "";
  assert.ok(
    !/formantOffsetSemitones\/.*unread by any renderer today, always 0/.test(description),
    "the stale claim must be gone now that NT-E1's formant render has landed"
  );
  assert.match(description, /formantOffsetSemitones \(this note's OWN voice-size offset/);
});

test("all six natural-tuning tools are registered exactly once, beginner-readable titles/descriptions (>= 40 chars)", async () => {
  const listed = await client.listTools();
  const names = [
    "clip_set_note_formant",
    "clip_set_formant_correction",
    "clip_set_note_transition",
    "clip_set_pitch_transition_smoothness",
    "clip_set_note_glide_follow",
    "clip_set_consonant_protection",
  ];
  for (const name of names) {
    const matches = listed.tools.filter((t) => t.name === name);
    assert.equal(matches.length, 1, `${name} must be registered exactly once`);
    assert.ok(matches[0]!.title && matches[0]!.title!.length > 0, `${name} needs a title`);
    assert.ok(
      (matches[0]!.description ?? "").length >= 40,
      `${name}'s description must be beginner-readable (>= 40 chars)`
    );
  }
});

// --- W7-WIRE2 (the wire round after W7-D2): consonantsOffByChoice, the D41
// no-op wording fix, and the two new natural-tuning text additions ---------

test("clip_get_pitch_edits says the first per-note edit THAT CHANGES A NOTE updates the vocal", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_get_pitch_edits");
  assert.ok(tool, "clip_get_pitch_edits is registered");
  const description = tool!.description ?? "";
  assert.match(description, /the first per-note edit THAT CHANGES A NOTE on such a vocal/);
  assert.match(description, /an edit that changes nothing leaves it exactly as it is/);
});

test("clip_get_pitch_edits' consonantsOffByChoice text names clip_set_consonant_protection and the preset re-run rule", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_get_pitch_edits");
  assert.ok(tool, "clip_get_pitch_edits is registered");
  const description = tool!.description ?? "";
  assert.match(
    description,
    /`consonantsOffByChoice` \(true when that protection was switched off on purpose with/
  );
  assert.match(description, /re-running clip_auto_correct_pitch keeps it off/);
  assert.match(description, /nobody chose, and a preset re-run switches it on/);
});

test("clip_set_consonant_protection says a switch-off is kept by a preset re-run", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_set_consonant_protection");
  assert.ok(tool, "clip_set_consonant_protection is registered");
  const description = tool!.description ?? "";
  assert.match(description, /Switching it off is remembered/);
  assert.match(description, /re-running clip_auto_correct_pitch, or the natural-tuning update, keeps it off/);
});
