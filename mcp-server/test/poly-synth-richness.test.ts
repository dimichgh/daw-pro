/**
 * poly-synth-richness.test.ts — MCP coverage for the m39-f/m39-g close:
 * `instrument_describe_synth` (new tool, read-only, the direct mirror of
 * `instrument_describe_sampler` for the Poly Synth) and the fifteen m39-g
 * richness parameters added to `track_set_instrument`'s existing schema.
 *
 * The `pedal-hold-limit.test.ts` / `sampler-describe-and-edit.test.ts`
 * stub-bridge pattern verbatim: monkeypatch `DawBridge.prototype.send`
 * before importing the real `McpServer`, drive the tools over an in-memory
 * transport, and assert what reaches the wire — never what the tool
 * "should" have sent.
 *
 * ⚠️ WHERE EACH GUARD LIVES, the `pedal-hold-limit.test.ts` rule applied to
 * all fifteen richness params: every one of them is typed with its own
 * `.min()/.max()` (and `.int()` for the two integer ones) at the MCP schema
 * layer, so an out-of-range or fractional value dies at the SCHEMA and never
 * reaches the bridge (asserted with `calls.length === 0`). The APP-SIDE
 * refusal (REFUSED, not clamped — `Commands.swift`'s `optionalBoundedNumber`/
 * `optionalBoundedInteger`) is a SEPARATE, Swift-side guard pinned by
 * `Tests/DAWControlTests/PolySynthRichnessWireTests.swift` — not re-proven
 * here.
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
  client = new Client({ name: "poly-synth-richness-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  const listed = await client.listTools();
  tools = listed.tools;
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
// instrument_describe_synth — the new tool
// ---------------------------------------------------------------------------

test("instrument_describe_synth forwards {trackId} to instrument.describeSynth", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "polySynth", isActiveInstrument: true, parameterCount: 24 };

  const result = (await client.callTool({
    name: "instrument_describe_synth",
    arguments: { trackId },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.describeSynth");
  assert.deepEqual(calls[0]!.params, { trackId });
});

test("instrument_describe_synth's strict schema rejects an unknown key (e.g. offset) — it takes only trackId", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_describe_synth",
    arguments: { trackId, offset: 0 },
  })) as any;

  assert.ok(result.isError, "an unrecognized key must be rejected at the schema layer");
  assert.equal(calls.length, 0, "a schema rejection never reaches the bridge");
});

test("instrument_describe_synth's description teaches the 24-not-23 count and the two non-zero neutrals", () => {
  const tool = tools.find((t) => t.name === "instrument_describe_synth");
  assert.ok(tool, "instrument_describe_synth is registered");
  const description = (tool.description ?? "") as string;
  assert.match(description, /24 parameters, not 23/, "states the parameter count plainly");
  assert.match(description, /noiseColor/);
  assert.match(description, /0\.5/, "teaches noiseColor's non-zero neutral");
  assert.match(description, /subOctave/);
  assert.match(description, /-1/, "teaches subOctave's non-zero neutral");
  assert.match(description, /unlimited/, "teaches pedalHoldLimit's string neutral");
  assert.match(description, /PRESERVES/, "states the omit-preserves guarantee plainly");
});

// ---------------------------------------------------------------------------
// track_set_instrument — the fifteen richness params forward under their
// own wire keys
// ---------------------------------------------------------------------------

test("track_set_instrument forwards all fifteen richness params under their own wire keys", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "polySynth" };

  const richness = {
    unisonVoices: 4,
    unisonDetuneCents: 12.5,
    unisonStereoSpread: 0.6,
    subLevel: 0.4,
    subOctave: -2,
    subWaveform: "square",
    noiseLevel: 0.2,
    noiseColor: 0.9,
    drift: 0.1,
    resonanceBoost: 0.3,
    drive: 0.5,
    velocityToCutoff: 0.7,
    keyToCutoff: 0.8,
    voiceJitter: 0.15,
    envelopeCurve: -0.5,
  };

  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, ...richness },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
  for (const [key, value] of Object.entries(richness)) {
    assert.equal(calls[0]!.params[key], value, `${key} must forward unchanged`);
  }
});

test("omitting a richness param forwards it as undefined — a call touching only cutoffHz never fabricates the other fourteen", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "polySynth" };

  await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, cutoffHz: 5000 },
  });

  assert.equal(calls.length, 1);
  const params = calls[0]!.params;
  assert.equal(params["cutoffHz"], 5000, "control: the param that WAS sent still arrives");
  for (const key of [
    "unisonVoices",
    "unisonDetuneCents",
    "unisonStereoSpread",
    "subLevel",
    "subOctave",
    "subWaveform",
    "noiseLevel",
    "noiseColor",
    "drift",
    "resonanceBoost",
    "drive",
    "velocityToCutoff",
    "keyToCutoff",
    "voiceJitter",
    "envelopeCurve",
  ]) {
    assert.equal(params[key], undefined, `${key} must forward as undefined when omitted`);
  }
});

// ---------------------------------------------------------------------------
// Schema-layer refusals — the boundary and negative-domain cases the brief
// specifically calls out
// ---------------------------------------------------------------------------

test("subOctave: schema range is -2..-1 — 0 and 1 are refused, -1 and -2 are accepted (NOT a min:0 mistake)", async () => {
  const trackId = randomUUID();

  for (const bad of [0, 1, -3]) {
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, subOctave: bad },
    })) as any;
    assert.ok(result.isError, `subOctave ${bad} must be refused at the schema layer`);
  }
  assert.equal(calls.length, 0, "schema rejections never reach the bridge");

  queuedResult = { trackId, kind: "polySynth" };
  for (const legal of [-1, -2]) {
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, subOctave: legal },
    })) as any;
    assert.ok(!result.isError, `subOctave ${legal} must be accepted: ${JSON.stringify(result)}`);
  }
  assert.equal(calls.length, 2, "control: the two legal calls DID reach the bridge");
});

test("unisonVoices: fractional and out-of-range values are refused; 1 and 8 (the boundaries) are accepted", async () => {
  const trackId = randomUUID();

  for (const bad of [2.5, 0, 9]) {
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, unisonVoices: bad },
    })) as any;
    assert.ok(result.isError, `unisonVoices ${bad} must be refused at the schema layer`);
  }
  assert.equal(calls.length, 0);

  queuedResult = { trackId, kind: "polySynth" };
  for (const legal of [1, 8]) {
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, unisonVoices: legal },
    })) as any;
    assert.ok(!result.isError, `unisonVoices ${legal} must be accepted: ${JSON.stringify(result)}`);
  }
  assert.equal(calls.length, 2);
});

test("0-1 richness params (e.g. noiseLevel) refuse outside 0-1; envelopeCurve's -1..1 range refuses outside it", async () => {
  const trackId = randomUUID();

  const cases: Array<[string, Record<string, unknown>]> = [
    ["noiseLevel over 1", { trackId, noiseLevel: 1.5 }],
    ["noiseLevel negative", { trackId, noiseLevel: -0.1 }],
    ["envelopeCurve over 1", { trackId, envelopeCurve: 1.1 }],
    ["envelopeCurve under -1", { trackId, envelopeCurve: -1.1 }],
    ["unisonDetuneCents over 50", { trackId, unisonDetuneCents: 50.1 }],
  ];
  for (const [label, args] of cases) {
    const result = (await client.callTool({ name: "track_set_instrument", arguments: args })) as any;
    assert.ok(result.isError, `${label} must be refused at the schema layer`);
  }
  assert.equal(calls.length, 0);

  // POSITIVE CONTROL: the boundary values of the SAME ranges are accepted.
  queuedResult = { trackId, kind: "polySynth" };
  for (const legal of [
    { noiseLevel: 0 },
    { noiseLevel: 1 },
    { envelopeCurve: -1 },
    { envelopeCurve: 1 },
    { unisonDetuneCents: 50 },
  ]) {
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, ...legal },
    })) as any;
    assert.ok(!result.isError, `${JSON.stringify(legal)} is a legal boundary: ${JSON.stringify(result)}`);
  }
  assert.equal(calls.length, 5, "control: all five legal boundary calls DID reach the bridge");
});

test("subWaveform accepts only the four legal waveforms", async () => {
  const trackId = randomUUID();
  const bad = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, subWaveform: "sawtooth" },
  })) as any;
  assert.ok(bad.isError, "an unrecognized waveform name must be refused");
  assert.equal(calls.length, 0);

  queuedResult = { trackId, kind: "polySynth" };
  const ok = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, subWaveform: "sine" },
  })) as any;
  assert.ok(!ok.isError, JSON.stringify(ok));
  assert.equal(calls[0]!.params["subWaveform"], "sine");
});

// ---------------------------------------------------------------------------
// The schema IS the contract — assert the raw JSON schema, not just behavior
// ---------------------------------------------------------------------------

test("subOctave's JSON schema minimum is -2, never 0 — the exact mistake the brief warns against", () => {
  const tool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(tool, "track_set_instrument is registered");
  const subOctaveSchema = (tool.inputSchema as any).properties?.subOctave;
  assert.ok(subOctaveSchema, "track_set_instrument exposes subOctave");
  assert.equal(subOctaveSchema.minimum, -2, `subOctave's minimum must be -2, got ${subOctaveSchema.minimum}`);
  assert.equal(subOctaveSchema.maximum, -1, `subOctave's maximum must be -1, got ${subOctaveSchema.maximum}`);
});

test("track_set_instrument's descriptions state REFUSED-not-clamped for the richness params and the two non-zero neutrals", () => {
  const tool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(tool);
  const properties = (tool.inputSchema as any).properties ?? {};

  const mainDescription = (tool.description ?? "") as string;
  assert.match(mainDescription, /PRESERVES/, "the main description states the omit-preserves guarantee");
  assert.match(mainDescription, /REFUSED/, "the main description flags the clamp-vs-refuse split");

  const subOctaveDescription = (properties.subOctave?.description ?? "") as string;
  assert.match(subOctaveDescription, /-1/, "subOctave's own description states its non-zero neutral");
  assert.match(subOctaveDescription, /REFUSED \(not clamped\)/);

  const noiseColorDescription = (properties.noiseColor?.description ?? "") as string;
  assert.match(noiseColorDescription, /0\.5/, "noiseColor's own description states its non-zero neutral");
  assert.match(noiseColorDescription, /REFUSED \(not clamped\)/);

  for (const name of [
    "unisonVoices",
    "unisonDetuneCents",
    "unisonStereoSpread",
    "subLevel",
    "subWaveform",
    "noiseLevel",
    "drift",
    "resonanceBoost",
    "drive",
    "velocityToCutoff",
    "keyToCutoff",
    "voiceJitter",
    "envelopeCurve",
  ]) {
    const description = (properties[name]?.description ?? "") as string;
    assert.ok(description.length > 0, `${name} must have a non-empty description`);
  }
});
