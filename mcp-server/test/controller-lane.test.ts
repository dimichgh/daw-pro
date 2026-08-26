/**
 * controller-lane.test.ts — round-trip coverage for m16-b2:
 * `clip_set_controller_lane` / `clip_remove_controller_lane` (MIDI CC, pitch
 * bend, channel pressure lanes on a MIDI clip).
 *
 * Same stub-bridge pattern as clip-time-range.test.ts / arrange-ergonomics.test.ts:
 * unlike integration.test.ts (real spawned DAWApp + real control WebSocket), this
 * suite monkeypatches `DawBridge.prototype.send` before any tool call runs, so the
 * REAL `McpServer` from `src/server.ts` is driven over an in-memory transport with
 * no live app required. Asserts:
 *   - each tool forwards exactly the right command name + params (clipId-only, no
 *     trackId — the clip_quantize/clip_delete_time_range precedent)
 *   - the optional `controller` param forwards as no value at all (absent from the
 *     JSON wire frame) when omitted for a pitchBend/channelPressure lane (the
 *     clip_duplicate toStartBeat/toTrackId precedent)
 *   - a stubbed success round-trips back through each tool unchanged
 *   - a stubbed app-side error (bad type, cc-without-controller, empty points,
 *     value-domain, lane cap, unknown-lane listing) surfaces as an MCP tool error
 *     (isError: true) carrying the app's own message verbatim, never swallowed
 *   - a zod-schema-invalid call (empty points array, out-of-range controller,
 *     unknown type string) is rejected at the MCP schema layer itself — an
 *     isError result with ZERO bridge calls (the clip-time-range/arrange-
 *     ergonomics client-side-rejection precedent)
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

// ---------------------------------------------------------------------------
// Stub the bridge BEFORE any tool call runs (the clip-time-range.test.ts note:
// `new DawBridge()` at server.ts module scope does no networking, so patching
// the prototype here intercepts every server-wide call, DAW-app-free).
// ---------------------------------------------------------------------------

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
  client = new Client({ name: "controller-lane-test-client", version: "0.0.0" });
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

// ---------------------------------------------------------------------------
// clip_set_controller_lane
// ---------------------------------------------------------------------------

test("clip_set_controller_lane forwards clipId/type/controller/points to clip.setControllerLane and returns the updated clip", async () => {
  const clipId = randomUUID();
  const stubbedClip = {
    id: clipId,
    name: "Test Riff",
    startBeat: 0,
    lengthBeats: 4,
    controllerLanes: [
      {
        type: { type: "cc", controller: 1 },
        points: [
          { beat: 0, value: 0 },
          { beat: 2, value: 127 },
        ],
      },
    ],
  };
  queuedResult = stubbedClip;

  const points = [
    { beat: 0, value: 0 },
    { beat: 2, value: 127 },
  ];
  const result = await client.callTool({
    name: "clip_set_controller_lane",
    arguments: { clipId, type: "cc", controller: 1, points },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.setControllerLane");
  assert.deepEqual(calls[0]!.params, { clipId, type: "cc", controller: 1, points });

  assert.deepEqual(parseJSON(result as any), stubbedClip, "the app's response round-trips back verbatim");
});

test("clip_set_controller_lane omits controller from the wire frame when not supplied (pitchBend)", async () => {
  const clipId = randomUUID();
  const points = [
    { beat: 0, value: 8192 },
    { beat: 4, value: 16383 },
  ];
  queuedResult = { id: clipId, name: "Test Riff", startBeat: 0, lengthBeats: 4 };

  await client.callTool({
    name: "clip_set_controller_lane",
    arguments: { clipId, type: "pitchBend", points },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.equal(calls[0]!.params["type"], "pitchBend");
  assert.equal(calls[0]!.params["controller"], undefined, "an omitted controller never reaches the app as a value");
  const wire = JSON.stringify(calls[0]!.params);
  assert.equal(wire?.includes("controller"), false, "an omitted controller does not appear in the JSON wire frame");
});

test("clip_set_controller_lane surfaces an app-side teaching error (cc without controller) verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    "'controller' is required when type is \"cc\" — an integer 0-127 (1 = mod wheel, 64 = sustain)"
  );

  const result = await client.callTool({
    name: "clip_set_controller_lane",
    arguments: { clipId, type: "cc", points: [{ beat: 0, value: 1 }] },
  });

  assert.equal(calls.length, 1, "the schema accepts a cc lane with no controller; the app is what refuses it");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(
    r.content[0].text as string,
    /'controller' is required when type is "cc"/,
    "the app's actionable teaching error passes through verbatim"
  );
});

test("clip_set_controller_lane surfaces the lane-cap teaching error verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error("clip 'Test Riff' already has 16 controller lanes — remove one first");

  const result = await client.callTool({
    name: "clip_set_controller_lane",
    arguments: { clipId, type: "channelPressure", points: [{ beat: 0, value: 64 }] },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /already has 16 controller lanes/);
});

test("clip_set_controller_lane rejects an empty points array at the MCP schema layer, no bridge call", async () => {
  const clipId = randomUUID();

  const result = await client.callTool({
    name: "clip_set_controller_lane",
    arguments: { clipId, type: "pitchBend", points: [] },
  });

  assert.equal(calls.length, 0, "an empty points array never reaches the bridge");
  assert.ok((result as any).isError, "an empty points array is a client-side schema rejection");
});

test("clip_set_controller_lane rejects an out-of-range controller (128) at the MCP schema layer", async () => {
  const clipId = randomUUID();

  const result = await client.callTool({
    name: "clip_set_controller_lane",
    arguments: { clipId, type: "cc", controller: 128, points: [{ beat: 0, value: 1 }] },
  });

  assert.equal(calls.length, 0, "an out-of-range controller never reaches the bridge");
  assert.ok((result as any).isError, "controller 128 is a client-side schema rejection (0-127)");
});

test("clip_set_controller_lane rejects an unknown type string at the MCP schema layer", async () => {
  const clipId = randomUUID();

  const result = await client.callTool({
    name: "clip_set_controller_lane",
    arguments: { clipId, type: "mod", points: [{ beat: 0, value: 1 }] },
  });

  assert.equal(calls.length, 0, "an unrecognized type never reaches the bridge");
  assert.ok((result as any).isError, "an unknown type string is a client-side schema rejection (z.enum)");
});

test("clip_set_controller_lane rejects a non-integer point value at the MCP schema layer", async () => {
  const clipId = randomUUID();

  const result = await client.callTool({
    name: "clip_set_controller_lane",
    arguments: { clipId, type: "pitchBend", points: [{ beat: 0, value: 8192.5 }] },
  });

  assert.equal(calls.length, 0, "a fractional value never reaches the bridge");
  assert.ok((result as any).isError, "a non-integer point value is a client-side schema rejection");
});

// ---------------------------------------------------------------------------
// clip_remove_controller_lane
// ---------------------------------------------------------------------------

test("clip_remove_controller_lane forwards clipId/type/controller to clip.removeControllerLane and returns the updated clip", async () => {
  const clipId = randomUUID();
  const stubbedClip = { id: clipId, name: "Test Riff", startBeat: 0, lengthBeats: 4 };
  queuedResult = stubbedClip;

  const result = await client.callTool({
    name: "clip_remove_controller_lane",
    arguments: { clipId, type: "cc", controller: 64 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.removeControllerLane");
  assert.deepEqual(calls[0]!.params, { clipId, type: "cc", controller: 64 });

  assert.deepEqual(parseJSON(result as any), stubbedClip, "the app's response round-trips back verbatim");
});

test("clip_remove_controller_lane omits controller from the wire frame when not supplied (channelPressure)", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId, name: "Test Riff", startBeat: 0, lengthBeats: 4 };

  await client.callTool({
    name: "clip_remove_controller_lane",
    arguments: { clipId, type: "channelPressure" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["controller"], undefined, "an omitted controller never reaches the app as a value");
  const wire = JSON.stringify(calls[0]!.params);
  assert.equal(wire?.includes("controller"), false, "an omitted controller does not appear in the JSON wire frame");
});

test("clip_remove_controller_lane surfaces the unknown-lane teaching error, listing existing lanes, verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error("clip 'Test Riff' has no channelPressure controller lane — existing lanes: cc64");

  const result = await client.callTool({
    name: "clip_remove_controller_lane",
    arguments: { clipId, type: "channelPressure" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(
    r.content[0].text as string,
    /existing lanes: cc64/,
    "the app's actionable teaching error passes through verbatim"
  );
});

test("clip_remove_controller_lane rejects a non-uuid clipId at the MCP schema layer, no bridge call", async () => {
  const result = await client.callTool({
    name: "clip_remove_controller_lane",
    arguments: { clipId: "not-a-uuid", type: "pitchBend" },
  });

  assert.equal(calls.length, 0, "a schema-invalid clipId never reaches the bridge");
  assert.ok((result as any).isError, "a non-uuid clipId is a client-side schema rejection");
});

// ---------------------------------------------------------------------------
// clip_apply_breath_contour (m27 leg D)
//
// ⭐⭐ THE PARAMETER-REACHES-THE-MODEL GATE. The MCP SDK builds a CLOSED
// `z.object()` from `inputSchema`, so a key the tool DESCRIPTION advertises but
// the SCHEMA omits is stripped before the handler runs — the call succeeds and
// silently returns the default result. Three parameters shipped that way
// earlier in this round. The first test below therefore asserts that EVERY one
// of the sixteen documented inputs arrives in the bridge frame with the exact
// value that was sent, and the second asserts the SET of schema keys matches
// the set the handler forwards, so a future addition cannot land in one place
// and not the other.
// ---------------------------------------------------------------------------

/** Every settable input, with a value distinct from that field's default. */
const BREATH_ALL_PARAMS = {
  depth: 0.4,
  peakValue: 110,
  peakPosition: 0.5,
  attackSettleSeconds: 0.08,
  expressionCC: 2,
  expressionSpacingSeconds: 0.03,
  vibratoOnsetSeconds: 0.35,
  vibratoRateHz: 6.2,
  vibratoDepthCents: 18,
  vibratoBloomSeconds: 1.1,
  vibratoReleaseSeconds: 0.12,
  sharpenCents: 7,
  bendSpacingSeconds: 0.01,
  bendRangeSemitones: 12,
} as const;

test("clip_apply_breath_contour forwards EVERY documented parameter to the app, by value", async () => {
  const clipId = randomUUID();
  const noteIds = [randomUUID(), randomUUID()];
  queuedResult = {
    id: clipId,
    name: "Sax",
    notesTouched: 2,
    notesWithVibrato: 2,
    expressionPointCount: 120,
    pitchBendPointCount: 380,
    perNotePointBudget: 16384,
  };

  const args = { clipId, noteIds, ...BREATH_ALL_PARAMS };
  const result = await client.callTool({ name: "clip_apply_breath_contour", arguments: args });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.applyBreathContour");
  // deepEqual, not a spot check: a field dropped between the schema and the
  // handler's destructuring is invisible to any assertion that only samples.
  // Copied out first: node's strict `deepEqual` is a TYPE PREDICATE, so
  // asserting against `args` would narrow `calls[0].params` and make the
  // string-keyed loop below a compile error.
  const forwarded: Record<string, unknown> = { ...calls[0]!.params };
  assert.deepEqual(calls[0]!.params, args);

  // And every value survives the round trip with its own magnitude intact —
  // a field silently coerced to the default would still pass a key-presence
  // check but not this one.
  for (const [key, value] of Object.entries(BREATH_ALL_PARAMS)) {
    assert.equal(
      forwarded[key],
      value,
      `'${key}' did not reach the app with the value that was sent`
    );
  }
  assert.deepEqual(parseJSON(result as any), queuedResult, "the app's response round-trips verbatim");
});

test("clip_apply_breath_contour's schema and its handler agree on the parameter set", async () => {
  // The failure this catches: a parameter added to `inputSchema` but forgotten
  // in the handler's destructuring is accepted by `.strict()` and then dropped
  // — the call succeeds and the app never sees it.
  const tools = await client.listTools();
  const tool = tools.tools.find((t) => t.name === "clip_apply_breath_contour");
  assert.ok(tool, "clip_apply_breath_contour is registered");
  const schemaKeys = Object.keys(
    (tool!.inputSchema as { properties?: Record<string, unknown> }).properties ?? {}
  ).sort();

  const clipId = randomUUID();
  queuedResult = { id: clipId };
  await client.callTool({
    name: "clip_apply_breath_contour",
    arguments: { clipId, noteIds: [randomUUID()], ...BREATH_ALL_PARAMS },
  });
  const forwardedKeys = Object.keys(calls[0]!.params).sort();

  assert.deepEqual(
    forwardedKeys,
    schemaKeys,
    "every schema key must be forwarded and every forwarded key must be in the schema"
  );
  assert.equal(schemaKeys.length, 16, "clipId + noteIds + 14 contour options");
});

test("clip_apply_breath_contour omits every unsupplied option from the wire frame", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId, notesTouched: 3 };

  await client.callTool({ name: "clip_apply_breath_contour", arguments: { clipId } });

  assert.equal(calls.length, 1);
  // The handler always names every key; the ones that were not supplied hold
  // `undefined` and vanish at JSON.stringify — the clip_remove_controller_lane
  // precedent above. What matters is the frame that actually goes on the wire,
  // because an explicit `null` there would be REJECTED by the app's bounds
  // checks rather than treated as "use the default".
  for (const key of Object.keys(BREATH_ALL_PARAMS)) {
    assert.equal(calls[0]!.params[key], undefined, `unsupplied '${key}' has no value`);
  }
  assert.equal(calls[0]!.params["noteIds"], undefined, "unsupplied 'noteIds' has no value");
  const wire = JSON.stringify(calls[0]!.params);
  assert.equal(wire, JSON.stringify({ clipId }), "the JSON frame carries clipId alone");
});

test("clip_apply_breath_contour surfaces the app's half-success warnings, never swallowed", async () => {
  const clipId = randomUUID();
  queuedResult = {
    id: clipId,
    notesTouched: 4,
    notesWithVibrato: 0,
    warnings: [
      "the swell will change LOUDNESS but not BRIGHTNESS: this track's sampler has expressionFilterDepth off (0)",
      "no note got vibrato: every one of the 4 selected is shorter than the straight opening plus one vibrato cycle",
    ],
  };

  const result = await client.callTool({ name: "clip_apply_breath_contour", arguments: { clipId } });
  const parsed = parseJSON(result as any);
  assert.equal(parsed.warnings.length, 2, "both warnings reach the agent");
  assert.match(parsed.warnings[0] as string, /LOUDNESS but not BRIGHTNESS/);
  assert.equal(parsed.notesWithVibrato, 0, "and the honest count comes with them");
});

test("clip_apply_breath_contour passes the app's teaching errors through verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    "'vibratoRateHz' must be a number between 0.2 and 20.0 (default 5.5 — vibrato rate in Hz)"
  );

  const result = await client.callTool({
    name: "clip_apply_breath_contour",
    arguments: { clipId, vibratoRateHz: 19 },
  });

  const r = result as any;
  assert.ok(r.isError, "an app-side refusal must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /between 0\.2 and 20/);
});

test("clip_apply_breath_contour rejects out-of-range options at the MCP schema layer, no bridge call", async () => {
  for (const bad of [
    { vibratoRateHz: 40 },
    { depth: 2 },
    { peakValue: 200 },
    { peakPosition: 0.99 },
    { bendRangeSemitones: 0 },
    { peakValue: 100.5 },
    { noteIds: ["not-a-uuid"] },
  ]) {
    calls = [];
    const result = await client.callTool({
      name: "clip_apply_breath_contour",
      arguments: { clipId: randomUUID(), ...bad },
    });
    assert.equal(calls.length, 0, `${JSON.stringify(bad)} must never reach the bridge`);
    assert.ok((result as any).isError, `${JSON.stringify(bad)} is a client-side schema rejection`);
  }
});

test("clip_apply_breath_contour is STRICT: a misspelled option is rejected, not silently dropped", async () => {
  // The exact defect class this round exists to end — `vibratoRate` looks
  // plausible, and a permissive schema would strip it and return a perfectly
  // successful default-shaped contour.
  const result = await client.callTool({
    name: "clip_apply_breath_contour",
    arguments: { clipId: randomUUID(), vibratoRate: 5.5 },
  });
  assert.equal(calls.length, 0, "an unknown key never reaches the bridge");
  assert.ok((result as any).isError, "an unknown key is rejected at the MCP boundary");
});
