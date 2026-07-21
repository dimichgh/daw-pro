/**
 * clip-analyze-audio.test.ts — wiring coverage for clip_analyze_audio (m21-e,
 * design-clip-analyze-audio §6).
 *
 * The au-params.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `clip.analyzeAudio {clipId}`
 *   - the app's response (the ClipAudioAnalysisResult DTO) round-trips
 *     verbatim, including a `playback` block when present
 *   - clipId is required and must be a UUID (schema layer, zero bridge calls)
 *   - read-only ⇒ registered via `server.registerTool` directly (the
 *     fx_describe/clip_detect_transients precedent), so an unrecognized extra
 *     argument is silently stripped rather than rejected
 *   - an app-side error (e.g. the MIDI-clip rejection) surfaces as an MCP
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
  client = new Client({ name: "clip-analyze-audio-test-client", version: "0.0.0" });
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

test("clip_analyze_audio forwards {clipId} to clip.analyzeAudio and returns the analysis verbatim", async () => {
  const clipId = randomUUID();
  const stubbed = {
    analysis: {
      durationSeconds: 212.4,
      windowStartSeconds: 0,
      sampleRate: 44100,
      samplePeakDb: -0.3,
      rmsDb: -14.2,
      key: {
        tonic: "A",
        mode: "minor",
        confidence: 0.78,
        tonal: true,
        alternatives: [{ tonic: "C", mode: "major", score: 0.71 }],
      },
      tempo: {
        bpm: 128.2,
        confidence: 0.86,
        steady: true,
        beatOffsetSeconds: 0.113,
        alternates: [{ bpm: 64.1, score: 0.58 }],
      },
      spectral: {
        bands: Array.from({ length: 24 }, (_, i) => -40 + i),
        centroidHz: 1834.0,
        summary: {
          subDb: -38.1,
          bassDb: -20.3,
          lowMidDb: -18.9,
          midDb: -16.4,
          highMidDb: -22.0,
          airDb: -30.5,
        },
      },
      analyzerVersion: 1,
    },
    stretchRatio: 1.0,
    pitchShiftSemitones: 0.0,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_analyze_audio",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.analyzeAudio");
  assert.deepEqual(calls[0]!.params, { clipId });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response round-trips verbatim");
});

test("clip_analyze_audio: a non-identity clip's stubbed `playback` block round-trips too", async () => {
  const clipId = randomUUID();
  const stubbed = {
    analysis: {
      durationSeconds: 4.0,
      windowStartSeconds: 0,
      sampleRate: 48000,
      samplePeakDb: -1.0,
      rmsDb: -12.0,
      key: { tonic: "D", mode: "major", confidence: 0.6, tonal: true, alternatives: [] },
      tempo: { bpm: 100, confidence: 0.5, steady: true, beatOffsetSeconds: 0, alternates: [] },
      spectral: {
        bands: Array.from({ length: 24 }, () => -30),
        centroidHz: 1200,
        summary: { subDb: -30, bassDb: -30, lowMidDb: -30, midDb: -30, highMidDb: -30, airDb: -30 },
      },
      analyzerVersion: 1,
    },
    stretchRatio: 2.0,
    pitchShiftSemitones: 2,
    playback: { bpm: 50, keyTonic: "E", keyMode: "major" },
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "clip_analyze_audio", arguments: { clipId } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("clip_analyze_audio requires a UUID clipId (rejected at the schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({ name: "clip_analyze_audio", arguments: {} })) as any;
  assert.ok(missing.isError, "a missing clipId must be rejected before the bridge call");

  const notAUuid = (await client.callTool({
    name: "clip_analyze_audio",
    arguments: { clipId: "not-a-uuid" },
  })) as any;
  assert.ok(notAUuid.isError, "a non-UUID clipId must be rejected before the bridge call");

  assert.equal(calls.length, 0);
});

test("clip_analyze_audio is read-only (server.registerTool directly, the fx_describe/clip_detect_transients precedent): an unrecognized argument is silently stripped, not rejected", async () => {
  queuedResult = { analysis: {}, stretchRatio: 1, pitchShiftSemitones: 0 };
  const clipId = randomUUID();

  const result = await client.callTool({
    name: "clip_analyze_audio",
    arguments: { clipId, bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "read-only tools use a non-strict schema (m16-e scopes strictness to mutating tools)");
  assert.equal(calls.length, 1, "the call still reaches the bridge, with the unrecognized key stripped");
  assert.ok(!("bogus" in calls[0]!.params), "the stray key never reaches bridge.send");
});

test("clip_analyze_audio surfaces an app-side error (e.g. the MIDI-clip rejection) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    `clip ${clipId} is a MIDI clip — clip.analyzeAudio applies only to audio clips (read MIDI notes directly for key and timing)`
  );

  const result = await client.callTool({ name: "clip_analyze_audio", arguments: { clipId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.analyzeAudio");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /is a MIDI clip/, "the app's teaching message passes through verbatim");
});
