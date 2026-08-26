/**
 * nested-strict-gap.test.ts — m30-c: closes the REMAINING nested-`.strict()`
 * gap after 2026-08-23's sampler pass. `registerTool`'s wrapper (server.ts's
 * `registerTool` function) only applies `.strict()` at the TOP level of a
 * tool's own `inputSchema`; any nested `z.object(...)` (an array element
 * shape, or a shared sub-schema used inside one) falls through to zod's
 * default STRIP mode — a typo'd field inside it is silently discarded and
 * the call still reports success, having done one fewer thing than asked.
 *
 * Same stub-bridge / InMemoryTransport pattern as
 * sampler-describe-and-edit.test.ts. Every test below asserts BOTH:
 *   - `isError` (the call was rejected)
 *   - `calls.length === 0` (the bridge was never reached — proves the
 *     rejection happened at the MCP schema boundary, not app-side)
 * and is paired with a "still accepts a legitimate call" test to rule out
 * the strict-schema-broke-a-real-caller regression.
 *
 * Sites closed here (enumerated by grepping every `z.object(` in
 * server.ts and checking which lacked `.strict()`):
 *   - tempo_set_map: `segments[]`, `meterChanges[]` (inline array elements)
 *   - midi_set_control_map: `bindings[]` (inline array element)
 *   - clip_add_midi / clip_set_notes: shared `noteSchema`
 *   - clip_set_gain_envelope: `points[]` (inline array element)
 *   - clip_set_controller_lane: shared `controllerPointSchema`
 *   - take_set_comp: shared `compSegmentSchema`
 *   - automation_add_lane: shared `automationTargetSchema` (each
 *     discriminated-union member)
 *   - automation_set_points: shared `automationPointSchema`
 *   - track_set_instrument: `audioUnit` (`audioUnitSchema`), `soundBank`
 *     (`soundBankSchema`) — the two gaps named on 2026-08-23 and
 *     deliberately left for this pass
 *   - lego_generate: `tracks[]` (inline array element)
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
  client = new Client({ name: "nested-strict-gap-test-client", version: "0.0.0" });
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

// ---------------------------------------------------------------------------
// tempo_set_map — segments[] / meterChanges[]
// ---------------------------------------------------------------------------

test("tempo_set_map rejects an unrecognized key inside one `segments` element (never reaches the bridge)", async () => {
  const result = (await client.callTool({
    name: "tempo_set_map",
    arguments: { segments: [{ startBeat: 0, bpm: 120, bmp: 999 }] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("tempo_set_map rejects an unrecognized key inside one `meterChanges` element (never reaches the bridge)", async () => {
  const result = (await client.callTool({
    name: "tempo_set_map",
    arguments: {
      segments: [{ startBeat: 0, bpm: 120 }],
      meterChanges: [{ startBeat: 0, beatsPerBar: 4, beatUnit: 4, beatsPerBer: 3 }],
    },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("tempo_set_map still accepts a legitimate call (no regression)", async () => {
  queuedResult = { segments: [{ startBeat: 0, bpm: 120 }] };
  const result = (await client.callTool({
    name: "tempo_set_map",
    arguments: {
      segments: [{ startBeat: 0, bpm: 120 }],
      meterChanges: [{ startBeat: 0, beatsPerBar: 4, beatUnit: 4 }],
    },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "tempo.setMap");
});

// ---------------------------------------------------------------------------
// midi_set_control_map — bindings[]
// ---------------------------------------------------------------------------

test("midi_set_control_map rejects an unrecognized key inside one `bindings` element (never reaches the bridge)", async () => {
  const result = (await client.callTool({
    name: "midi_set_control_map",
    arguments: { bindings: [{ target: "breathPadAngle", controller: 1, contoller: 2 }] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("midi_set_control_map still accepts a legitimate binding (no regression)", async () => {
  queuedResult = { bindings: [] };
  const result = (await client.callTool({
    name: "midi_set_control_map",
    arguments: { bindings: [{ target: "breathPadAngle", controller: 1, channel: 0, inverted: false }] },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});

// ---------------------------------------------------------------------------
// clip_add_midi / clip_set_notes — shared noteSchema
// ---------------------------------------------------------------------------

test("clip_add_midi rejects an unrecognized key inside one note (never reaches the bridge)", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "clip_add_midi",
    arguments: { trackId, notes: [{ pitch: 60, velocty: 100, startBeat: 0 }] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_set_notes rejects an unrecognized key inside one note (never reaches the bridge)", async () => {
  const clipId = randomUUID();
  const result = (await client.callTool({
    name: "clip_set_notes",
    arguments: { clipId, notes: [{ pitch: 60, startBeat: 0, lengthBeats: 1, lengthBeat: 1 }] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_add_midi still accepts a legitimate note (no regression)", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, clipId: randomUUID(), notes: [] };
  const result = (await client.callTool({
    name: "clip_add_midi",
    arguments: { trackId, notes: [{ pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1 }] },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});

// ---------------------------------------------------------------------------
// clip_set_gain_envelope — points[]
// ---------------------------------------------------------------------------

test("clip_set_gain_envelope rejects an unrecognized key inside one point (never reaches the bridge)", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  const result = (await client.callTool({
    name: "clip_set_gain_envelope",
    arguments: { trackId, clipId, points: [{ beat: 0, gainDb: 0, gainDB: 3 }] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_set_gain_envelope still accepts a legitimate point (no regression)", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  queuedResult = { trackId, clipId };
  const result = (await client.callTool({
    name: "clip_set_gain_envelope",
    arguments: { trackId, clipId, points: [{ beat: 0, gainDb: 0 }] },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});

// ---------------------------------------------------------------------------
// clip_set_controller_lane — shared controllerPointSchema
// ---------------------------------------------------------------------------

test("clip_set_controller_lane rejects an unrecognized key inside one point (never reaches the bridge)", async () => {
  const clipId = randomUUID();
  const result = (await client.callTool({
    name: "clip_set_controller_lane",
    arguments: {
      clipId,
      type: "cc",
      controller: 1,
      points: [{ beat: 0, value: 64, vlaue: 100 }],
    },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("clip_set_controller_lane still accepts a legitimate point (no regression)", async () => {
  const clipId = randomUUID();
  queuedResult = { clipId };
  const result = (await client.callTool({
    name: "clip_set_controller_lane",
    arguments: { clipId, type: "cc", controller: 1, points: [{ beat: 0, value: 64 }] },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});

// ---------------------------------------------------------------------------
// take_set_comp — shared compSegmentSchema
// ---------------------------------------------------------------------------

test("take_set_comp rejects an unrecognized key inside one segment (never reaches the bridge)", async () => {
  const trackId = randomUUID();
  const groupId = randomUUID();
  const laneId = randomUUID();
  const result = (await client.callTool({
    name: "take_set_comp",
    arguments: { trackId, groupId, segments: [{ laneId, startBeat: 0, endBeat: 4, laneld: laneId }] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("take_set_comp still accepts a legitimate segment (no regression)", async () => {
  const trackId = randomUUID();
  const groupId = randomUUID();
  const laneId = randomUUID();
  queuedResult = { groupId };
  const result = (await client.callTool({
    name: "take_set_comp",
    arguments: { trackId, groupId, segments: [{ laneId, startBeat: 0, endBeat: 4 }] },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});

// ---------------------------------------------------------------------------
// automation_add_lane — shared automationTargetSchema (discriminated union)
// ---------------------------------------------------------------------------

test("automation_add_lane rejects an unrecognized key inside `target` (never reaches the bridge)", async () => {
  const trackId = randomUUID();
  const sendId = randomUUID();
  const result = (await client.callTool({
    name: "automation_add_lane",
    arguments: { trackId, target: { type: "sendLevel", sendId, sendld: sendId } },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("automation_add_lane still accepts a legitimate `target` (no regression)", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, laneId: randomUUID() };
  const result = (await client.callTool({
    name: "automation_add_lane",
    arguments: { trackId, target: { type: "volume" } },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});

// ---------------------------------------------------------------------------
// automation_set_points — shared automationPointSchema
// ---------------------------------------------------------------------------

test("automation_set_points rejects an unrecognized key inside one point (never reaches the bridge)", async () => {
  const trackId = randomUUID();
  const laneId = randomUUID();
  const result = (await client.callTool({
    name: "automation_set_points",
    arguments: { trackId, laneId, points: [{ beat: 0, value: 1, vlaue: 2 }] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("automation_set_points still accepts a legitimate point (no regression)", async () => {
  const trackId = randomUUID();
  const laneId = randomUUID();
  queuedResult = { laneId };
  const result = (await client.callTool({
    name: "automation_set_points",
    arguments: { trackId, laneId, points: [{ beat: 0, value: 1, curve: "linear" }] },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});

// ---------------------------------------------------------------------------
// track_set_instrument — audioUnitSchema / soundBankSchema
// ---------------------------------------------------------------------------

test("track_set_instrument rejects an unrecognized key inside `audioUnit` (never reaches the bridge)", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: {
      trackId,
      audioUnit: { subType: "dls ", manufacturer: "appl", subTyp: "dls " },
    },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("track_set_instrument rejects an unrecognized key inside `soundBank` (never reaches the bridge)", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, soundBank: { source: "gm", program: 56, progam: 56 } },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("track_set_instrument still accepts a legitimate `audioUnit` (no regression)", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "audioUnit" };
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, audioUnit: { subType: "dls ", manufacturer: "appl" } },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});

test("track_set_instrument still accepts a legitimate `soundBank` (no regression)", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "soundBank" };
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, soundBank: { source: "gm", program: 56 } },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});

// ---------------------------------------------------------------------------
// lego_generate — tracks[]
// ---------------------------------------------------------------------------

test("lego_generate rejects an unrecognized key inside one `tracks` element (never reaches the bridge)", async () => {
  const result = (await client.callTool({
    name: "lego_generate",
    arguments: {
      sourceAudioPath: "/tmp/source.wav",
      globalCaption: "warm lofi hip-hop",
      tracks: [{ trackName: "bass", trackNam: "bass" }],
    },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("lego_generate still accepts a legitimate `tracks` element (no regression)", async () => {
  queuedResult = { jobId: "job-1", state: "pending", trackNames: ["bass"] };
  const result = (await client.callTool({
    name: "lego_generate",
    arguments: {
      sourceAudioPath: "/tmp/source.wav",
      globalCaption: "warm lofi hip-hop",
      tracks: [{ trackName: "bass", prompt: "round sub bass" }],
    },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
});
