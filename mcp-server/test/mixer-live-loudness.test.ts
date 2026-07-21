/**
 * mixer-live-loudness.test.ts — wiring coverage for mixer_live_loudness
 * (m22-c, the live master-bus loudness meter).
 *
 * The clip-analyze-audio.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `mixer.liveLoudness` with the reset flag
 *   - the app's response (the LiveLoudnessSnapshot DTO) round-trips
 *     verbatim, INCLUDING the omitted-nil warm-up shape (absence = no
 *     evidence, never zero)
 *   - reset is optional and boolean (schema layer)
 *   - read-only-poll ⇒ registered via `server.registerTool` directly (the
 *     mixer_master_analysis / engine_performance_stats precedent), so an
 *     unrecognized extra argument is silently stripped rather than rejected
 *   - an app-side error (headless engineUnavailable) surfaces as an MCP
 *     tool error, message verbatim
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

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
  client = new Client({ name: "mixer-live-loudness-test-client", version: "0.0.0" });
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

test("mixer_live_loudness forwards to mixer.liveLoudness and returns the full snapshot verbatim", async () => {
  const stubbed = {
    momentaryLufs: -18.5,
    shortTermLufs: -19.25,
    maxMomentaryLufs: -15.0,
    maxShortTermLufs: -16.5,
    integratedLufs: -20.125,
    loudnessRangeLu: 6.5,
    truePeakDbtp: -0.8,
    dcOffset: 0.001,
    crestFactorDb: 12.5,
    secondsAnalyzed: 42.5,
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "mixer_live_loudness", arguments: {} });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "mixer.liveLoudness");
  assert.ok(!("bogus" in calls[0]!.params));
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's snapshot round-trips verbatim");
});

test("mixer_live_loudness: the warm-up shape (omitted nils) round-trips — absence is the honest answer", async () => {
  // A just-started meter: only true peak + time exist; every LUFS field is
  // ABSENT (the wire omits nil — agents must treat absence as no evidence).
  const stubbed = { truePeakDbtp: -12.0, secondsAnalyzed: 0.3 };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "mixer_live_loudness", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed, stubbed);
  assert.ok(!("momentaryLufs" in parsed), "no fabricated momentary while warming up");
  assert.ok(!("integratedLufs" in parsed), "no fabricated integrated while warming up");
  assert.ok(!("loudnessRangeLu" in parsed), "no fabricated LRA while warming up");
});

test("mixer_live_loudness forwards reset:true (restart-then-read) verbatim", async () => {
  queuedResult = { secondsAnalyzed: 0 };

  const result = await client.callTool({
    name: "mixer_live_loudness",
    arguments: { reset: true },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "mixer.liveLoudness");
  assert.equal(calls[0]!.params.reset, true);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), { secondsAnalyzed: 0 });
});

test("mixer_live_loudness rejects a non-boolean reset at the schema layer (zero bridge calls)", async () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const bad = (await client.callTool({
    name: "mixer_live_loudness",
    arguments: { reset: "yes" },
  })) as any;
  assert.ok(bad.isError, "a non-boolean reset must be rejected before the bridge call");
  assert.equal(calls.length, 0);
});

test("mixer_live_loudness is a read-only poll (server.registerTool directly, the mixer_master_analysis precedent): an unrecognized argument is silently stripped, not rejected", async () => {
  queuedResult = { secondsAnalyzed: 1.0 };

  const result = await client.callTool({
    name: "mixer_live_loudness",
    arguments: { bogus: 1 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "read-only tools use a non-strict schema (m16-e scopes strictness to mutating tools)");
  assert.equal(calls.length, 1, "the call still reaches the bridge, with the unrecognized key stripped");
  assert.ok(!("bogus" in calls[0]!.params), "the stray key never reaches bridge.send");
});

test("mixer_live_loudness surfaces the headless engineUnavailable teaching error verbatim", async () => {
  queuedError = new Error("audio engine not available");

  const result = await client.callTool({ name: "mixer_live_loudness", arguments: {} });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /audio engine not available/);
});
