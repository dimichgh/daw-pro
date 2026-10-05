/**
 * note-play.test.ts — wiring coverage for note_play
 * (m23-ct: play notes live and HOLD them, the one note tool whose sound can be
 * RECORDED into a take).
 *
 * The note-audition.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `note.play {trackId, pitches, velocity}` and
 *     carries NO durationMs (this verb is HELD, never a one-shot)
 *   - an EMPTY pitches array is legal and reaches the bridge — that is the
 *     release, and it must never be rejected at the boundary
 *   - the app's answer round-trips verbatim, INCLUDING `recording:false`,
 *     which is the HONESTY LIGHT and a real answer rather than an error
 *   - the Zod bounds (0-8 pitches, 0-127, velocity 1-127) and the strict
 *     wrapper reject at the MCP boundary, never at the app
 *   - an app-side refusal surfaces verbatim
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
  client = new Client({ name: "note-play-test-client", version: "0.0.0" });
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

test("note_play forwards a chord to note.play and round-trips the answer", async () => {
  const trackId = randomUUID();
  const stubbed = {
    trackId,
    pitches: [60, 64, 67],
    velocity: 90,
    holding: true,
    audible: true,
    recording: true,
    capturedEdges: 3,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "note_play",
    arguments: { trackId, pitches: [60, 64, 67], velocity: 90 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "note.play");
  assert.deepEqual(calls[0]!.params, { trackId, pitches: [60, 64, 67], velocity: 90 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("an EMPTY pitches array is the RELEASE and must reach the bridge, never be rejected", async () => {
  const trackId = randomUUID();
  queuedResult = {
    trackId,
    pitches: [],
    velocity: 0,
    holding: false,
    audible: true,
    recording: true,
    capturedEdges: 1,
  };

  const result = await client.callTool({ name: "note_play", arguments: { trackId, pitches: [] } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError, "releasing is always legal");
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, pitches: [], velocity: undefined });
});

test("recording:false is the HONESTY LIGHT — a real answer, not a tool error", async () => {
  const trackId = randomUUID();
  const stubbed = {
    trackId,
    pitches: [60],
    velocity: 100,
    holding: true,
    audible: true,
    // Sounded, and went into NO take: not recording / not armed / no capture.
    recording: false,
    capturedEdges: 0,
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "note_play", arguments: { trackId, pitches: [60] } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "playing without recording is a successful call");
  assert.equal(parseJSON(r).recording, false);
});

test("audible:false + reason is a REAL ANSWER, not a tool error", async () => {
  const trackId = randomUUID();
  const stubbed = {
    trackId,
    pitches: [60],
    velocity: 100,
    holding: true,
    audible: false,
    recording: false,
    capturedEdges: 0,
    reason: "instrumentNotReady",
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "note_play", arguments: { trackId, pitches: [60] } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.deepEqual(parseJSON(r), stubbed);
});

test("note_play omits velocity when the caller does (the app owns the default)", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, pitches: [60], velocity: 100, holding: true, audible: true };

  await client.callTool({ name: "note_play", arguments: { trackId, pitches: [60] } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, pitches: [60], velocity: undefined });
});

test("the Zod bounds reject bad input at the MCP boundary (never reaching the bridge)", async () => {
  const trackId = randomUUID();
  const bad: Array<Record<string, unknown>> = [
    { trackId, pitches: [60, 61, 62, 63, 64, 65, 66, 67, 68] }, // 9 > max 8
    { trackId, pitches: [128] },
    { trackId, pitches: [-1] },
    { trackId, pitches: [60.5] },
    { trackId, pitches: [60], velocity: 0 },
    { trackId, pitches: [60], velocity: 128 },
    // note_play is HELD, never a one-shot: durationMs does not exist here.
    { trackId, pitches: [60], durationMs: 500 },
    { trackId, pitch: 60 }, // the singular alias does NOT exist
    { pitches: [60] }, // no trackId
  ];

  for (const args of bad) {
    const result = await client.callTool({ name: "note_play", arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `expected a boundary rejection for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("an app-side refusal surfaces as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("audition needs an instrument track — this one is audio");

  const result = await client.callTool({
    name: "note_play",
    arguments: { trackId: randomUUID(), pitches: [60] },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "note.play");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side refusal must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /instrument track/);
});

test("the description tells an agent the three things that lose a take", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "note_play");
  assert.ok(tool, "note_play is registered");
  const description = tool!.description ?? "";
  // 1. Always release. 2. Wait past the take anchor. 3. Read `recording`.
  assert.match(description, /pitches:\[\]/);
  assert.match(description, /300 ms/);
  assert.match(description, /recording/);
  // And the one property that distinguishes it from note_audition.
  assert.match(description, /RECORDED/);
});
