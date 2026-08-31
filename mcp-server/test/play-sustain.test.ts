/**
 * play-sustain.test.ts — wiring coverage for play_sustain
 * (m34-l: the SUSTAIN/DAMPER pedal, CC 64 — the answer to the user's own
 * question about why a note stops the instant they lift the key).
 *
 * The note-play.test.ts pattern verbatim: monkeypatch `DawBridge.prototype.send`
 * before importing the real `McpServer`, drive the tool over an in-memory
 * transport, and assert:
 *   - the tool forwards exactly `play.sustain {trackId, down}` and nothing else
 *   - BOTH edges reach the bridge, and `down:false` is never rejected at the
 *     boundary — gate the ons, never gate the offs
 *   - the app's answer round-trips VERBATIM, including `down` (the state AFTER
 *     the call, not an echo of the request) and `recording:false` (the honesty
 *     light), both of which are real answers rather than errors
 *   - the strict wrapper rejects an unknown argument at the MCP boundary
 *   - the description carries the two things an agent MUST be told: lift it
 *     when you are done, and read `recording` before claiming you recorded
 *
 * ⛔ WHAT THIS FILE DOES NOT TEST, AND MUST NOT BE READ AS TESTING: whether any
 * instrument HONOURS CC 64. That is measured against real audio by
 * `scripts/gates/_m34l-sustain-pedal-smoke.mjs` (all three instrument paths)
 * and `Tests/DAWEngineTests/AuditionPedalSustainTests.swift`. A bridge stub
 * proves the byte left the tool, which is the "agrees with itself through a
 * dead pipe" failure if mistaken for anything more.
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
  client = new Client({ name: "play-sustain-test-client", version: "0.0.0" });
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

test("play_sustain forwards a PRESS to play.sustain and round-trips the answer", async () => {
  const trackId = randomUUID();
  const stubbed = {
    trackId,
    down: true,
    controller: 64,
    value: 127,
    pushed: true,
    audible: true,
    recording: true,
    capturedPoints: 1,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "play_sustain",
    arguments: { trackId, down: true },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "play.sustain");
  assert.deepEqual(calls[0]!.params, { trackId, down: true });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("the LIFT reaches the bridge and is never rejected at the boundary", async () => {
  const trackId = randomUUID();
  queuedResult = {
    trackId, down: false, controller: 64, value: 0,
    pushed: true, audible: true, recording: false, capturedPoints: 0,
  };

  const result = await client.callTool({
    name: "play_sustain",
    arguments: { trackId, down: false },
  });

  // ⛔ GATE THE ONS, NEVER GATE THE OFFS. A lift refused at the MCP boundary
  // would be a pedal an agent could press and never release — the one failure
  // mode a pedal has that nothing downstream could rescue.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError, "lifting is always legal");
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, down: false });
});

test("`down` in the reply is the STATE AFTER the call, not an echo of the request", async () => {
  const trackId = randomUUID();
  // The app refused to hold it: the instrument is not loaded, so the pedal came
  // back UP even though `true` was asked for. An agent that lit a lamp off its
  // own request would report a pedal that is not down.
  const stubbed = {
    trackId, down: false, controller: 64, value: 127,
    pushed: true, audible: false, reason: "engineRebuilding",
    recording: false, capturedPoints: 0,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "play_sustain",
    arguments: { trackId, down: true },
  });

  // A REAL ANSWER, not an error — the note_play / note_audition contract.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const parsed = parseJSON(result as any);
  assert.equal(parsed.down, false, "the reply must carry the STATE, not the request");
  assert.equal(parsed.reason, "engineRebuilding");
});

test("recording:false is the HONESTY LIGHT — a real answer, not a tool error", async () => {
  const trackId = randomUUID();
  const stubbed = {
    trackId, down: true, controller: 64, value: 127,
    pushed: true, audible: true,
    // The pedal moved and went into NO take: not recording / not armed.
    recording: false, capturedPoints: 0,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "play_sustain",
    arguments: { trackId, down: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError, "recording:false is a status, never an error");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal(parseJSON(result as any).recording, false);
});

test("pushed:false — an unchanged latch is an honest no-op, not a failure", async () => {
  const trackId = randomUUID();
  queuedResult = {
    trackId, down: true, controller: 64, value: 127,
    pushed: false, audible: true, recording: false, capturedPoints: 0,
  };

  const result = await client.callTool({
    name: "play_sustain",
    arguments: { trackId, down: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal(parseJSON(result as any).pushed, false);
});

test("an unknown argument is rejected at the MCP boundary and never reaches the bridge", async () => {
  const trackId = randomUUID();
  const result = await client.callTool({
    name: "play_sustain",
    // `pedal` is the plausible typo — and a request that silently ignored it
    // would send a pedal the caller did not describe.
    arguments: { trackId, down: true, pedal: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the strict wrapper must reject an unknown key");
  assert.equal(calls.length, 0, "nothing may reach the app");
});

test("an app-side refusal surfaces verbatim", async () => {
  queuedError = new Error("track is not an instrument track");
  const result = await client.callTool({
    name: "play_sustain",
    arguments: { trackId: randomUUID(), down: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.match(String((result as any).content[0].text), /not an instrument track/);
});

test("the description teaches the two things an agent must not get wrong", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find(t => t.name === "play_sustain");
  assert.ok(tool, "play_sustain is registered");
  const text = String(tool!.description ?? "");

  // 1. LIFT IT WHEN YOU ARE DONE. A pedal left down is a drone with no visible
  //    cause, and an agent is the caller most likely to forget.
  assert.match(text, /ALWAYS LIFT IT WHEN YOU ARE DONE/,
               "the description must tell an agent to lift the pedal");
  // 2. READ `recording`. Telling the user a performance was captured when it
  //    was not is the failure the honesty light exists to prevent.
  assert.match(text, /HONESTY LIGHT/,
               "the description must point at the recording flag");
  // 3. The measured support claim, so the doc drift filed as m34-m cannot be
  //    re-introduced here: this tool says what was MEASURED, not what an older
  //    doc string claims.
  assert.match(text, /built-in poly synth, the built-in sampler and\s+the hosted sound-bank/,
               "the description must name the instruments measured to honour CC 64");
  // 4. The human equivalent, so an agent can answer "how do I do this myself".
  assert.match(text, /Tab/, "the description must name the keyboard shortcut");
});
