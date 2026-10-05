/**
 * instrument-probe-liveness.test.ts — wiring coverage for m31-f ②'s
 * `instrument_probe_liveness` (render a velocity ladder, report whether the
 * TIMBRE moves with the velocity or only the volume).
 *
 * The sampler-describe-and-edit.test.ts stub-bridge pattern verbatim:
 * monkeypatch `DawBridge.prototype.send` before importing the real
 * `McpServer`, drive the tool over an in-memory transport, and assert
 *
 *   - it forwards to `instrument.probeLiveness` with the RIGHT shape, and an
 *     omitted optional forwards as UNDEFINED rather than a fabricated default
 *     (a default invented here would silently disagree with the store's)
 *   - it rides the STRICT-SCHEMA wrapper: an unrecognized top-level key is
 *     rejected at the boundary and never reaches the bridge
 *   - a one-rung ladder and an out-of-range velocity are refused at the
 *     schema layer, zero bridge calls
 *   - the app's self-check-failure error passes through VERBATIM — that
 *     message is the deliverable, not a generic failure
 *   - the description teaches the four things a caller must not get wrong:
 *     `silent` is not `static`, the thresholds are uncalibrated, a failed
 *     self-check errors instead of returning STATIC, and this measures
 *     liveliness and NOT quality
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
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let tools: any[];

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "probe-liveness-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  tools = (await client.listTools()).tools;
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
  assert.ok(first && first.type === "text");
  return JSON.parse(first.text as string);
}

/** The Apple DLS sax ground truth from the item brief, in wire shape. */
function staticVerdictPayload(trackId: string) {
  return {
    trackId,
    instrumentKind: "soundBank",
    instrumentDetail: "General MIDI program 65",
    pitch: 57,
    noteSeconds: 1,
    sampleRate: 48000,
    selfCheck: {
      passed: true,
      lowToneHz: 440,
      lowToneCentroidHz: 441.2,
      highToneHz: 1760,
      highToneCentroidHz: 1762.8,
      rule: "a 1760 Hz tone must read a centroid more than TWICE that of a 440 Hz tone",
    },
    ladder: [
      { velocity: 25, rmsDb: -51.6, centroidHz: 2100, timbreGroup: 1 },
      { velocity: 60, rmsDb: -36.4, centroidHz: 2099, timbreGroup: 1 },
      { velocity: 95, rmsDb: -28.4, centroidHz: 2100, timbreGroup: 1 },
      { velocity: 127, rmsDb: -23.3, centroidHz: 2099, timbreGroup: 1 },
    ],
    rmsSpreadDb: 28.3,
    centroidSpreadPercent: 0.05,
    distinctTimbreCount: 1,
    verdict: "static",
    summary: "STATIC — one timbre.",
    thresholds: {
      staticCentroidSpreadPercent: 5,
      minimumRMSSpreadDb: 6,
      timbreGroupTolerancePercent: 2,
      calibrated: false,
    },
    caveats: ["This measures LIVELINESS, not quality."],
  };
}

// ---------------------------------------------------------------------------
// Registration + forwarding
// ---------------------------------------------------------------------------

test("instrument_probe_liveness is registered exactly once", () => {
  const matches = tools.filter((t) => t.name === "instrument_probe_liveness");
  assert.equal(matches.length, 1);
});

test("forwards {trackId} bare — every omitted optional stays undefined, never a fabricated default", async () => {
  const trackId = randomUUID();
  const stubbed = staticVerdictPayload(trackId);
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_probe_liveness",
    arguments: { trackId },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.probeLiveness");
  assert.deepEqual(calls[0]!.params, { trackId });
  // The DEFAULTS live in the store (pitch 57, [25,60,95,127], 1.0 s). A copy
  // here would be a second home for them, free to drift.
  // (the exact-shape deepEqual above is what proves the three optionals are
  // ABSENT, not present-and-undefined — an `equal(..., undefined)` per key
  // cannot tell those two apart.)

  // The whole verdict round-trips, ladder and all: the evidence is the point.
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("forwards pitch/velocities/noteSeconds explicitly when given", async () => {
  const trackId = randomUUID();
  queuedResult = staticVerdictPayload(trackId);

  await client.callTool({
    name: "instrument_probe_liveness",
    arguments: { trackId, pitch: 60, velocities: [10, 40, 80, 110, 127], noteSeconds: 1.5 },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    trackId,
    pitch: 60,
    velocities: [10, 40, 80, 110, 127],
    noteSeconds: 1.5,
  });
});

// ---------------------------------------------------------------------------
// Schema refusals — all of these must cost ZERO bridge calls
// ---------------------------------------------------------------------------

test("requires trackId", async () => {
  const result = (await client.callTool({
    name: "instrument_probe_liveness",
    arguments: {},
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("rides the strict-schema wrapper: an unrecognized top-level key is rejected at the boundary", async () => {
  const result = (await client.callTool({
    name: "instrument_probe_liveness",
    arguments: { trackId: randomUUID(), fromBeat: 8 },
  })) as any;
  assert.ok(result.isError, "an unknown key must be refused, not silently stripped");
  assert.equal(calls.length, 0);
});

test("a one-rung ladder is refused at the schema layer — one rung cannot show whether the timbre moves", async () => {
  const result = (await client.callTool({
    name: "instrument_probe_liveness",
    arguments: { trackId: randomUUID(), velocities: [100] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("velocity 0 and velocity 128 are refused at the schema layer (MIDI 1-127)", async () => {
  for (const velocities of [[0, 100], [60, 128]]) {
    calls = [];
    const result = (await client.callTool({
      name: "instrument_probe_liveness",
      arguments: { trackId: randomUUID(), velocities },
    })) as any;
    assert.ok(result.isError, `velocities ${JSON.stringify(velocities)} should be refused`);
    assert.equal(calls.length, 0);
  }
});

test("a pitch outside 0-127 is refused at the schema layer", async () => {
  const result = (await client.callTool({
    name: "instrument_probe_liveness",
    arguments: { trackId: randomUUID(), pitch: 200 },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// The error that matters most
// ---------------------------------------------------------------------------

test("a failed meter self-check surfaces the app's error VERBATIM — never a static verdict", async () => {
  const message =
    "the spectral-centroid meter failed its own positive control (a 440 Hz tone read" +
    " 1201.3 Hz, a 1760 Hz tone read 1201.3 Hz; the high tone must read more than twice" +
    " the low one). No liveness verdict was produced: a flat centroid is exactly the shape" +
    " a BROKEN measurement makes, so a reading from a meter that cannot discriminate is not" +
    " evidence of anything.";
  queuedError = new Error(message);

  const result = (await client.callTool({
    name: "instrument_probe_liveness",
    arguments: { trackId: randomUUID() },
  })) as any;

  assert.ok(result.isError);
  const text = result.content.map((c: any) => c.text).join("\n");
  assert.ok(text.includes(message), `expected the app's message verbatim, got: ${text}`);
  // The refusal must not be dressed up as a finding.
  assert.ok(!/"verdict"\s*:\s*"static"/.test(text));
});

test("a track-kind refusal passes through verbatim", async () => {
  queuedError = new Error(
    "an instrument can only be set on an instrument track — this is an audio track."
  );
  const result = (await client.callTool({
    name: "instrument_probe_liveness",
    arguments: { trackId: randomUUID() },
  })) as any;
  assert.ok(result.isError);
  assert.ok(
    result.content.map((c: any) => c.text).join("\n").includes("instrument track")
  );
});

// ---------------------------------------------------------------------------
// The description carries the four facts a caller must not get wrong
// ---------------------------------------------------------------------------

test("the description distinguishes `silent` from `static`, disclaims calibration, states the self-check error contract, and refuses to be read as a quality judgement", () => {
  const tool = tools.find((t) => t.name === "instrument_probe_liveness");
  assert.ok(tool);
  const text = tool.description as string;

  // 1. never / ran-and-found-nothing must be distinguishable.
  assert.match(text, /`silent` IS NOT `static`/);
  // 2. the thresholds are a hypothesis, not a rule.
  assert.match(text, /calibrated: false/);
  assert.match(text, /HYPOTHESIS/);
  // 3. a failed self-check ERRORS; it never returns a verdict.
  assert.match(text, /THE TOOL ERRORS OUT AND RETURNS NO VERDICT/);
  // 4. liveliness, not quality.
  assert.match(text, /LIVELINESS, NOT QUALITY/);
  // and the layer count is named as the more informative number.
  assert.match(text, /distinctTimbreCount/);
  assert.match(text, /LOWER BOUND/);
});

test("the description says the probe is not an edit and renders dry", () => {
  const tool = tools.find((t) => t.name === "instrument_probe_liveness");
  const text = tool.description as string;
  assert.match(text, /NOT AN EDIT/);
  assert.match(text, /no undo step is created/);
  assert.match(text, /DRY/);
});
