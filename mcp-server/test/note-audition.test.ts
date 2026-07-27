/**
 * note-audition.test.ts — wiring coverage for note_audition
 * (m23-d: sound notes NOW on an instrument track, outside the timeline).
 *
 * The clip-fit-to-content.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `note.audition {trackId, pitches, velocity, durationMs}`
 *   - the app's answer round-trips verbatim, INCLUDING an `audible:false` +
 *     `reason` reply, which is a real answer and must NOT become a tool error
 *   - the Zod bounds (1-8 pitches, 0-127, velocity 1-127, durationMs 10-5000)
 *     and the strict wrapper reject at the MCP boundary, never at the app
 *   - an app-side refusal (recording, wrong track kind) surfaces verbatim
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
  client = new Client({ name: "note-audition-test-client", version: "0.0.0" });
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
  assert.ok(
    first && first.type === "text",
    `expected a text content item, got: ${JSON.stringify(result.content)}`
  );
  return JSON.parse(first.text as string);
}

test("note_audition forwards a chord to note.audition and round-trips the answer", async () => {
  const trackId = randomUUID();
  const stubbed = {
    trackId,
    pitches: [60, 64, 67],
    velocity: 90,
    durationMs: 750,
    audible: true,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "note_audition",
    arguments: { trackId, pitches: [60, 64, 67], velocity: 90, durationMs: 750 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "note.audition");
  assert.deepEqual(calls[0]!.params, {
    trackId,
    pitches: [60, 64, 67],
    velocity: 90,
    durationMs: 750,
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("note_audition omits velocity/durationMs when the caller does (the app owns the defaults)", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, pitches: [60], velocity: 100, durationMs: 500, audible: true };

  await client.callTool({ name: "note_audition", arguments: { trackId, pitches: [60] } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    trackId,
    pitches: [60],
    velocity: undefined,
    durationMs: undefined,
  });
});

test("audible:false + reason is a REAL ANSWER, not a tool error", async () => {
  const trackId = randomUUID();
  const stubbed = {
    trackId,
    pitches: [60],
    velocity: 100,
    durationMs: 500,
    audible: false,
    reason: "instrumentNotReady",
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "note_audition",
    arguments: { trackId, pitches: [60] },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "an inaudible audition is a successful call with a reason");
  assert.deepEqual(parseJSON(r), stubbed);
});

test("the Zod bounds reject bad pitch sets at the MCP boundary (never reaching the bridge)", async () => {
  const trackId = randomUUID();
  const bad: Array<Record<string, unknown>> = [
    { trackId, pitches: [] }, // empty
    { trackId, pitches: [60, 61, 62, 63, 64, 65, 66, 67, 68] }, // 9 > max 8
    { trackId, pitches: [128] }, // above the MIDI range
    { trackId, pitches: [-1] }, // below it
    { trackId, pitches: [60.5] }, // not an integer
    { trackId, pitches: [60], velocity: 0 }, // velocity floor is 1
    { trackId, pitches: [60], velocity: 128 },
    { trackId, pitches: [60], durationMs: 9 },
    { trackId, pitches: [60], durationMs: 5001 },
    { trackId, pitch: 60 }, // the singular alias does NOT exist
    { trackId, pitches: [60], hold: true }, // unknown key
  ];

  for (const args of bad) {
    const result = await client.callTool({ name: "note_audition", arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `expected a boundary rejection for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("an app-side refusal surfaces as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("cannot audition while recording — stop the take first");

  const result = await client.callTool({
    name: "note_audition",
    arguments: { trackId: randomUUID(), pitches: [60] },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "note.audition");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side refusal must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /while recording/);
});
