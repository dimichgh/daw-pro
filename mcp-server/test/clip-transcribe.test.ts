/**
 * clip-transcribe.test.ts — wiring coverage for clip_transcribe (m23-n2b:
 * on-device WhisperKit speech-to-text, word/segment timings mapped onto the
 * clip's project beats).
 *
 * The clip-fit-to-content.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `clip.transcribe {clipId, language}`
 *   - an omitted `language` reaches the bridge as `undefined`, not a stray key
 *   - the app's response (text/segments/words, both seconds and beats) round-trips verbatim
 *   - the strict wrapper rejects unknown arguments at the MCP boundary (never reaching the bridge)
 *   - a non-uuid clipId is rejected at the schema layer (never reaching the bridge)
 *   - app-side teaching errors (MIDI clip, stretched clip, unknown clip, no model installed)
 *     surface as MCP tool errors, message verbatim
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
  client = new Client({ name: "clip-transcribe-test-client", version: "0.0.0" });
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

test("clip_transcribe forwards {clipId, language} to clip.transcribe and returns the transcription verbatim", async () => {
  const clipId = randomUUID();
  const stubbed = {
    text: "Hello world.",
    language: "en",
    modelVariantDirectoryName: "openai_whisper-large-v3-v20240930_turbo",
    rangeStartSeconds: 0,
    anchorBeat: 4,
    segments: [
      {
        text: "Hello world.",
        startSeconds: 0,
        endSeconds: 1.2,
        startBeat: 4,
        endBeat: 6.4,
        words: [
          { text: " Hello", startSeconds: 0, endSeconds: 0.5, startBeat: 4, endBeat: 5, confidence: 0.95 },
          { text: " world.", startSeconds: 0.5, endSeconds: 1.2, startBeat: 5, endBeat: 6.4, confidence: 0.91 },
        ],
      },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_transcribe",
    arguments: { clipId, language: "en" },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.transcribe");
  assert.deepEqual(calls[0]!.params, { clipId, language: "en" });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's transcription round-trips verbatim");
});

test("clip_transcribe: omitted language reaches the bridge as undefined, not a stray key", async () => {
  const clipId = randomUUID();
  queuedResult = {
    text: "", language: "", modelVariantDirectoryName: "test", rangeStartSeconds: 0, anchorBeat: 0, segments: [],
  };

  await client.callTool({ name: "clip_transcribe", arguments: { clipId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.transcribe");
  assert.equal(calls[0]!.params["clipId"], clipId);
  assert.equal(calls[0]!.params["language"], undefined);
});

test("clip_transcribe requires clipId (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({ name: "clip_transcribe", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "a missing required clipId must be rejected");
  assert.equal(calls.length, 0);
});

test("clip_transcribe rejects a non-uuid clipId at the schema layer, zero bridge calls", async () => {
  const result = await client.callTool({ name: "clip_transcribe", arguments: { clipId: "not-a-uuid" } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "a malformed clipId must be rejected before the bridge");
  assert.equal(calls.length, 0);
});

test("clip_transcribe rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "clip_transcribe",
    arguments: { clipId: randomUUID(), sensitivity: 0.5 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the strict wrapper must reject unknown keys");
  assert.equal(calls.length, 0, "a rejected call never reaches the bridge");
});

test("clip_transcribe surfaces the MIDI-clip teaching error verbatim", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    `clip ${clipId} is a MIDI clip — clip.transcribe applies only to audio clips (read MIDI notes directly for lyrics and timing)`
  );

  const result = await client.callTool({ name: "clip_transcribe", arguments: { clipId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.transcribe");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /MIDI clip/, "the app's teaching message passes through verbatim");
});

test("clip_transcribe surfaces the stretched-clip teaching error verbatim, naming the ratio", async () => {
  const clipId = randomUUID();
  queuedError = new Error(
    `clip ${clipId} has a non-identity time-stretch (ratio 1.500) — un-stretch it (clip.setStretch ratio 1) ` +
      "first; clip.transcribe maps word timings assuming one source second equals one timeline second, which " +
      "only holds at ratio 1 (stretch-aware transcription lands in a future version)"
  );

  const result = await client.callTool({ name: "clip_transcribe", arguments: { clipId } });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a stretched clip must surface as a tool error, never silently mis-mapped");
  assert.match(r.content[0].text as string, /non-identity time-stretch/, "names the stretch hazard verbatim");
  assert.match(r.content[0].text as string, /ratio 1\.500/, "names the offending ratio verbatim");
});

test("clip_transcribe surfaces the unknown-clip teaching error verbatim", async () => {
  queuedError = new Error("no clip with id 11111111-1111-1111-1111-111111111111 — use project.snapshot to list clips");

  const result = await client.callTool({ name: "clip_transcribe", arguments: { clipId: randomUUID() } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /no clip with id/);
});

test("clip_transcribe surfaces a no-model-installed teaching error verbatim", async () => {
  queuedError = new Error(
    "no Whisper speech model found under /Users/x/Library/Application Support/DAWPro/Models — install one first"
  );

  const result = await client.callTool({ name: "clip_transcribe", arguments: { clipId: randomUUID() } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /Models/);
});
