/**
 * m27-k: `audio_profile_file` takes an OPT-IN `loudness` flag, the way to
 * check a bounce's loudness without `reference_import` copying the file into
 * the References library. These tests pin the MCP leg: the flag forwards to
 * `audio.profileFile` only when given (an omitted flag never reaches the
 * wire, so the app's no-flag reply stays byte-identical), a non-boolean is
 * refused by the strict schema before the bridge is called, the reply's
 * `loudness` object passes through verbatim, and the description tells an
 * agent this is the no-copy loudness check.
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

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  return queuedResult;
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "audio-profile-loudness-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = undefined;
});

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: any): any {
  const first = result.content[0];
  assert.ok(first && first.type === "text", `expected a text content item, got: ${JSON.stringify(result.content)}`);
  return JSON.parse(first.text as string);
}

test("m27-k: without `loudness`, the flag never reaches the wire (the JSON the bridge sends has no loudness key)", async () => {
  queuedResult = { durationSeconds: 1, sampleRateHz: 48000, channelCount: 2, windows: [] };
  await client.callTool({
    name: "audio_profile_file",
    arguments: { path: "/tmp/bounce.wav", windowSeconds: 1 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "audio.profileFile");
  assert.equal(calls[0]!.params["loudness"], undefined);
  // The bridge serializes with JSON.stringify, which drops undefined.
  assert.equal("loudness" in JSON.parse(JSON.stringify(calls[0]!.params)), false);
});

test("m27-k: `loudness: true` forwards verbatim and the reply's `loudness` object passes through", async () => {
  const reading = { integratedLufs: -14.2, truePeakDbtp: -1.1, loudnessRangeLu: 5.5 };
  queuedResult = {
    durationSeconds: 180,
    sampleRateHz: 48000,
    channelCount: 2,
    windows: [{ startSeconds: 0, durationSeconds: 180, peakDb: -1.3, rmsDb: -12 }],
    loudness: reading,
  };
  const result = await client.callTool({
    name: "audio_profile_file",
    arguments: { path: "/tmp/bounce.wav", windowSeconds: 180, loudness: true },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["loudness"], true);
  assert.equal(calls[0]!.params["path"], "/tmp/bounce.wav");
  assert.deepEqual(parseJSON(result).loudness, reading);
});

test("m27-k: `loudness: false` forwards as false (the app reads it as no flag)", async () => {
  queuedResult = { durationSeconds: 1, sampleRateHz: 48000, channelCount: 2, windows: [] };
  await client.callTool({
    name: "audio_profile_file",
    arguments: { path: "/tmp/bounce.wav", windowSeconds: 1, loudness: false },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["loudness"], false);
});

test("m27-k: a non-boolean `loudness` is refused before the bridge is called", async () => {
  let refused = false;
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result: any = await client.callTool({
      name: "audio_profile_file",
      arguments: { path: "/tmp/bounce.wav", windowSeconds: 1, loudness: "yes" },
    });
    refused = result.isError === true;
  } catch {
    refused = true;
  }
  assert.equal(refused, true, "a string loudness must be refused");
  assert.equal(calls.length, 0, "the bridge must never be called with a wrong-typed flag");
});

test("m27-k: the schema lists `loudness` as an optional boolean and the description names the no-copy loudness check", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "audio_profile_file");
  assert.ok(tool, "audio_profile_file is registered");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const schema = tool!.inputSchema as any;
  assert.equal(schema.properties?.loudness?.type, "boolean");
  assert.equal((schema.required ?? []).includes("loudness"), false);
  assert.match(tool!.description ?? "", /CHECK A BOUNCE'S LOUDNESS WITHOUT IMPORTING/);
  assert.match(tool!.description ?? "", /reference_import/);
});
