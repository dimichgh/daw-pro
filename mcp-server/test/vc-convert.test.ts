/**
 * vc-convert.test.ts — round-trip coverage for vc_convert_vocals /
 * vc_train_voice (m10-p-4).
 *
 * Same stub-bridge pattern as vc.test.ts (the m10-p-3 precedent, itself
 * following clip-time-range.test.ts): unlike integration.test.ts (real
 * spawned DAWApp + real control WebSocket), this suite monkeypatches
 * `DawBridge.prototype.send` before any tool call runs, so the REAL
 * `McpServer` from `src/server.ts` is driven over an in-memory transport
 * (the audit-tools.test.ts precedent) with no live app required. Asserts:
 *   - each tool forwards the matching `vc.convertVocals`/`vc.trainVoice`
 *     command with the right params, omitted optionals passing through as
 *     `undefined` (dropped by JSON.stringify at the real wire boundary,
 *     `bridge.ts`'s own doc) rather than a stray literal
 *   - a stubbed success result round-trips back through the tool unchanged
 *   - a stubbed app-side error (including the facade's teaching errors and
 *     the 501 trainingNotYetAvailable) surfaces as an MCP tool error
 *     (isError: true) carrying the app's own message verbatim
 *   - the exactly-one-of clipId/path law on vc_convert_vocals is NOT
 *     enforced at the zod schema layer (the transport_seek beats/marker
 *     precedent: validated in the DAWControl handler instead, so this
 *     suite proves both fields reach the bridge unfiltered) — that
 *     validation itself is Swift-side coverage
 *     (VoiceConversionConvertCommandTests.swift)
 *   - the m16-e strict-schema convention (an unrecognized key is rejected
 *     before the bridge call) and the HARD-REJECT-at-schema pitchSemitones/
 *     epochs range/type bounds (the ai_copilot_send maxRounds / clip_set_stretch
 *     precedent)
 *   - adding this pair never touched the sibling vc_sidecar_* / ai_sidecar_*
 *     tools
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

// ---------------------------------------------------------------------------
// Stub the bridge BEFORE any tool call runs.
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
  client = new Client({ name: "vc-convert-test-client", version: "0.0.0" });
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
// vc_convert_vocals
// ---------------------------------------------------------------------------

test("vc_convert_vocals (path form): forwards every supplied param and round-trips the result", async () => {
  const stubbedResult = {
    trackId: "11111111-1111-1111-1111-111111111111",
    clipId: "22222222-2222-2222-2222-222222222222",
    outputPath: "/tmp/converted.wav",
    realConversion: false,
    inputSeconds: 5.0,
    inferSeconds: 0.135,
    rtf: 37.13,
    sampleRate: 40000,
    note: "base is the untrained generic target",
  };
  queuedResult = stubbedResult;

  const result = await client.callTool({
    name: "vc_convert_vocals",
    arguments: {
      path: "/tmp/vocals.wav",
      voiceId: "base",
      pitchSemitones: -2,
      trackName: "My Vox",
      atBeat: 8,
    },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "vc.convertVocals");
  assert.deepEqual(calls[0]!.params, {
    clipId: undefined,
    path: "/tmp/vocals.wav",
    voiceId: "base",
    pitchSemitones: -2,
    trackName: "My Vox",
    atBeat: 8,
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedResult, "the app's response round-trips back verbatim");
});

test("vc_convert_vocals (clipId form): omitted optional params come through as undefined, not stray literals", async () => {
  queuedResult = { trackId: "t", clipId: "c", outputPath: "/tmp/out.wav", realConversion: true, sampleRate: 40000, inputSeconds: 1, inferSeconds: 0.1 };
  const clipId = "33333333-3333-3333-3333-333333333333";

  await client.callTool({ name: "vc_convert_vocals", arguments: { clipId, voiceId: "my-voice" } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "vc.convertVocals");
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.equal(calls[0]!.params["voiceId"], "my-voice");
  assert.equal(calls[0]!.params["path"], undefined);
  assert.equal(calls[0]!.params["pitchSemitones"], undefined);
  assert.equal(calls[0]!.params["trackName"], undefined);
  assert.equal(calls[0]!.params["atBeat"], undefined);
});

test("vc_convert_vocals: both clipId and path reach the bridge unfiltered (the exactly-one-of law lives in the DAW handler, not the schema)", async () => {
  queuedError = new Error(
    "vc.convertVocals: pass either 'clipId' or 'path', not both — they name the source audio two different ways"
  );

  const result = await client.callTool({
    name: "vc_convert_vocals",
    arguments: { clipId: "44444444-4444-4444-4444-444444444444", path: "/tmp/x.wav", voiceId: "base" },
  });

  assert.equal(calls.length, 1, "the schema does not reject this — the app does");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /not both/);
});

test("vc_convert_vocals: a facade teaching error (e.g. voiceNotReady) surfaces verbatim", async () => {
  queuedError = new Error("RVC voice-conversion sidecar request failed (HTTP 409): voiceNotReady: voice 'x' exists but has no MLX model (model.npz) yet");

  const result = await client.callTool({
    name: "vc_convert_vocals",
    arguments: { path: "/tmp/vocals.wav", voiceId: "x" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /model\.npz/);
});

test("vc_convert_vocals: requires voiceId (missing -> rejected at the MCP boundary)", async () => {
  const result = await client.callTool({ name: "vc_convert_vocals", arguments: { path: "/tmp/x.wav" } });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0, "a missing required field never reaches the bridge");
});

test("vc_convert_vocals: an empty voiceId is rejected at the schema layer", async () => {
  const result = await client.callTool({
    name: "vc_convert_vocals",
    arguments: { path: "/tmp/x.wav", voiceId: "" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

test("vc_convert_vocals: pitchSemitones is HARD-REJECTED outside -24..24 at the schema layer, zero bridge calls", async () => {
  for (const bad of [25, -25, 100, -1000]) {
    const result = await client.callTool({
      name: "vc_convert_vocals",
      arguments: { path: "/tmp/x.wav", voiceId: "base", pitchSemitones: bad },
    });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r = result as any;
    assert.ok(r.isError, `pitchSemitones ${bad} should have been rejected`);
  }
  assert.equal(calls.length, 0, "every out-of-range pitchSemitones is rejected before any bridge call");
});

test("vc_convert_vocals: pitchSemitones boundaries -24 and 24 are accepted at the schema layer", async () => {
  queuedResult = { trackId: "t", clipId: "c", outputPath: "/tmp/out.wav", realConversion: false, sampleRate: 40000, inputSeconds: 1, inferSeconds: 0.1 };
  for (const boundary of [-24, 24]) {
    calls = [];
    const result = await client.callTool({
      name: "vc_convert_vocals",
      arguments: { path: "/tmp/x.wav", voiceId: "base", pitchSemitones: boundary },
    });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok(!(result as any).isError, `pitchSemitones ${boundary} should have been accepted`);
    assert.equal(calls.length, 1);
    assert.equal(calls[0]!.params["pitchSemitones"], boundary);
  }
});

test("vc_convert_vocals: a non-integer pitchSemitones is rejected at the schema layer", async () => {
  const result = await client.callTool({
    name: "vc_convert_vocals",
    arguments: { path: "/tmp/x.wav", voiceId: "base", pitchSemitones: 2.5 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("vc_convert_vocals rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "vc_convert_vocals",
    arguments: { path: "/tmp/x.wav", voiceId: "base", bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an unrecognized key must be rejected before the bridge call");
  assert.equal(calls.length, 0, "the strict schema rejects before bridge.send is ever invoked");
});

// ---------------------------------------------------------------------------
// vc_train_voice
// ---------------------------------------------------------------------------

test("vc_train_voice: forwards every supplied param", async () => {
  queuedError = new Error(
    "RVC voice-conversion sidecar request failed (HTTP 501): trainingNotYetAvailable: contract reserved — training ships with the Voice panel (m10-p-5/p-6)"
  );

  const result = await client.callTool({
    name: "vc_train_voice",
    arguments: { name: "My Voice", datasetDir: "/tmp/dataset", voiceId: "custom", epochs: 50 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "vc.trainVoice");
  assert.deepEqual(calls[0]!.params, {
    name: "My Voice",
    datasetDir: "/tmp/dataset",
    voiceId: "custom",
    epochs: 50,
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "today the facade always answers 501 — this is not a success path");
  assert.match(r.content[0].text as string, /trainingNotYetAvailable/);
  assert.match(r.content[0].text as string, /m10-p-5\/p-6/);
});

test("vc_train_voice: omitted voiceId/epochs come through as undefined, never stray literals", async () => {
  queuedError = new Error("501 stub");
  await client.callTool({ name: "vc_train_voice", arguments: { name: "My Voice", datasetDir: "/tmp/dataset" } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["voiceId"], undefined);
  assert.equal(calls[0]!.params["epochs"], undefined);
});

test("vc_train_voice: a future 2xx success round-trips the app's response back unchanged", async () => {
  const stubbedResult = { voiceId: "custom", state: "queued" };
  queuedResult = stubbedResult;

  const result = await client.callTool({
    name: "vc_train_voice",
    arguments: { name: "My Voice", datasetDir: "/tmp/dataset" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.deepEqual(parseJSON(r), stubbedResult);
});

test("vc_train_voice: requires name and datasetDir (missing -> rejected at the MCP boundary)", async () => {
  const result = await client.callTool({ name: "vc_train_voice", arguments: { name: "x" } });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("vc_train_voice: epochs must be a positive integer, HARD-REJECTED at the schema layer", async () => {
  for (const bad of [0, -1, 2.5]) {
    const result = await client.callTool({
      name: "vc_train_voice",
      arguments: { name: "My Voice", datasetDir: "/tmp/dataset", epochs: bad },
    });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `epochs ${bad} should have been rejected`);
  }
  assert.equal(calls.length, 0);
});

test("vc_train_voice rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "vc_train_voice",
    arguments: { name: "x", datasetDir: "/tmp/x", bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an unrecognized key must be rejected before the bridge call");
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// Additive guarantee: the sibling vc_sidecar_*/ai_sidecar_* tools are unaffected.
// ---------------------------------------------------------------------------

test("vc_sidecar_status is still registered, unaffected, and forwards to vc.sidecarStatus unchanged", async () => {
  const stubbedStatus = { state: "healthy", message: "RVC voice-conversion sidecar is running and healthy." };
  queuedResult = stubbedStatus;

  const result = await client.callTool({ name: "vc_sidecar_status", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "vc.sidecarStatus");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.deepEqual(parseJSON(r), stubbedStatus);
});

test("ai_sidecar_status is still registered, unaffected, and forwards to ai.sidecarStatus unchanged", async () => {
  const stubbedStatus = { state: "healthy", message: "ACE-Step sidecar is running and healthy.", version: "1.0" };
  queuedResult = stubbedStatus;

  const result = await client.callTool({ name: "ai_sidecar_status", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "ai.sidecarStatus");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.deepEqual(parseJSON(r), stubbedStatus);
});
