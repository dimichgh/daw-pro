/**
 * clip-detect-pitch.test.ts — wiring coverage for clip_detect_pitch
 * (m23-ap-3, wiring m23-ap-2b's PitchTracker/SwiftF0PitchTracker seam onto
 * the MCP surface for the first time).
 *
 * The clip-analyze-audio.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards {clipId, fromSeconds, durationSeconds,
 *     confidenceThreshold, silenceFloorDbfs} to clip.detectPitch verbatim
 *   - the app's response (the ClipPitchDetection DTO) round-trips verbatim,
 *     INCLUDING an unvoiced frame that OMITS frequencyHz entirely (the
 *     honest-absence contract crossing the MCP boundary too — not just the
 *     wire's own JSON encoding)
 *   - clipId is required and must be a UUID (schema layer, zero bridge calls)
 *   - registered via the STRICT-SCHEMA wrapper despite being read-only (the
 *     audio_profile_file precedent: real windowing/tuning params worth
 *     typo-catching), so an unrecognized extra argument IS rejected, unlike
 *     clip_detect_transients/clip_analyze_audio's direct registration
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
  client = new Client({ name: "clip-detect-pitch-test-client", version: "0.0.0" });
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

/** A stub with BOTH a voiced and an unvoiced frame — an all-voiced stub
 * would let the honest-absence assertion below pass trivially. */
function makeStubbedDetection() {
  return {
    pitch: {
      frames: [
        { timeSeconds: 0.0, frequencyHz: 220.0, confidence: 0.97, levelDbfs: -12.0 },
        { timeSeconds: 0.016, confidence: 0.2, levelDbfs: -70.0, absence: "belowConfidence" },
      ],
      frameCount: 2,
      voicedFrameCount: 1,
      voicedFraction: 0.5,
      frameRateHz: 62.5,
      analysisSampleRateHz: 16000,
      sourceSampleRateHz: 44100,
      windowStartSeconds: 0,
      windowDurationSeconds: 0.032,
      confidenceThreshold: 0.9,
      silenceFloorDbfs: -75,
      minFrequencyHz: 46.875,
      maxFrequencyHz: 2093.75,
    },
    clipWindowDurationSeconds: 2.0,
    stretchRatio: 1.0,
    pitchShiftSemitones: 0.0,
  };
}

test("clip_detect_pitch forwards {clipId} (bare) to clip.detectPitch and returns the detection verbatim, honest absence included", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedDetection();
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_detect_pitch",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.detectPitch");
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.equal(calls[0]!.params["fromSeconds"], undefined, "an omitted param forwards as undefined, never a fabricated default");
  assert.equal(calls[0]!.params["durationSeconds"], undefined);
  assert.equal(calls[0]!.params["confidenceThreshold"], undefined);
  assert.equal(calls[0]!.params["silenceFloorDbfs"], undefined);

  const parsed = parseJSON(result as any);
  // Belt-and-braces on the honest-absence contract specifically, not just a
  // deepEqual of the whole object (which could pass even if BOTH sides
  // happened to encode a wrong sentinel identically) — checked BEFORE the
  // deepEqual below, which narrows `parsed`'s inferred type and would
  // otherwise make these accesses awkward under noUncheckedIndexedAccess.
  const unvoicedFrame = parsed.pitch.frames[1];
  assert.ok(!("frequencyHz" in unvoicedFrame),
    "an unvoiced frame must OMIT frequencyHz entirely across the MCP boundary too");
  assert.equal(unvoicedFrame.absence, "belowConfidence");
  assert.equal(unvoicedFrame.confidence, 0.2, "confidence is reported even for an unvoiced frame");

  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
});

test("clip_detect_pitch forwards every optional param explicitly", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedDetection();

  await client.callTool({
    name: "clip_detect_pitch",
    arguments: {
      clipId,
      fromSeconds: 0.5,
      durationSeconds: 1.0,
      confidenceThreshold: 0.6,
      silenceFloorDbfs: -50,
    },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    clipId,
    fromSeconds: 0.5,
    durationSeconds: 1.0,
    confidenceThreshold: 0.6,
    silenceFloorDbfs: -50,
  });
});

test("clip_detect_pitch requires a UUID clipId (rejected at the schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({ name: "clip_detect_pitch", arguments: {} })) as any;
  assert.ok(missing.isError, "a missing clipId must be rejected before the bridge call");

  const notAUuid = (await client.callTool({
    name: "clip_detect_pitch",
    arguments: { clipId: "not-a-uuid" },
  })) as any;
  assert.ok(notAUuid.isError, "a non-UUID clipId must be rejected before the bridge call");

  assert.equal(calls.length, 0);
});

test("clip_detect_pitch schema rejects out-of-range confidenceThreshold and non-positive durationSeconds at the schema layer", async () => {
  const clipId = randomUUID();

  const badConfidence = (await client.callTool({
    name: "clip_detect_pitch",
    arguments: { clipId, confidenceThreshold: 1.5 },
  })) as any;
  assert.ok(badConfidence.isError);

  const badDuration = (await client.callTool({
    name: "clip_detect_pitch",
    arguments: { clipId, durationSeconds: 0 },
  })) as any;
  assert.ok(badDuration.isError);

  assert.equal(calls.length, 0, "schema rejections never reach the bridge");
});

test("clip_detect_pitch is registered via the STRICT-SCHEMA wrapper (the audio_profile_file precedent, not clip_detect_transients'): an unrecognized argument IS rejected, even though the tool is read-only", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedDetection();

  const result = (await client.callTool({
    name: "clip_detect_pitch",
    arguments: { clipId, bogus: true },
  })) as any;

  assert.ok(result.isError, "the strict schema rejects an unrecognized key before the bridge call");
  assert.equal(calls.length, 0);
});

test("clip_detect_pitch surfaces an app-side error (e.g. the MIDI-clip rejection) as an MCP tool error, message verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    `clip ${clipId} is a MIDI clip — clip.detectPitch applies only to audio clips (MIDI notes already carry a definite pitch — read them directly)`
  );

  const result = await client.callTool({ name: "clip_detect_pitch", arguments: { clipId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.detectPitch");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /is a MIDI clip/, "the app's teaching message passes through verbatim");
});
