/**
 * output-devices.test.ts — wiring coverage for output_list_devices /
 * output_set_device (m20-j: pick where playback comes OUT, mirroring the
 * input_list_devices / input_set_device pair).
 *
 * The clip-fit-to-content.test.ts / clip-time-range.test.ts pattern
 * verbatim: monkeypatch `DawBridge.prototype.send` before importing the
 * real `McpServer`, drive the tools over an in-memory transport, and
 * assert:
 *   - output_list_devices forwards `output.listDevices` with no params and
 *     round-trips the app's device list verbatim
 *   - output_set_device forwards `output.setDevice {uid}`, with an omitted
 *     `uid` argument forwarded as explicit `null` (the F5 "omit =
 *     destructive default" shape shared with input_set_device and
 *     track_set_output — a typo'd key must not silently reset the pin)
 *   - the strict wrapper on output_set_device rejects unknown arguments at
 *     the MCP boundary, never reaching the bridge
 *   - an app-side error surfaces as an MCP tool error, message verbatim
 *
 * NOTE (m20-j, filed 2026-08-02): this suite stubs the bridge because the
 * Swift-side `output.listDevices`/`output.setDevice` control commands do not
 * exist in this tree yet (parallel work, tracked separately) — there is
 * nothing here that depends on Sources/DAWControl/Commands.swift. Until
 * those commands land, audit-tools.test.ts is EXPECTED to report these two
 * tools as strays with no backing command (by design — see that file's own
 * assertions); that is not a bug in this file.
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
  client = new Client({ name: "output-devices-test-client", version: "0.0.0" });
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

test("output_list_devices forwards output.listDevices with no params and round-trips the device list verbatim", async () => {
  const stubbed = {
    devices: [
      { uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", sampleRate: 48000, channelCount: 2, isDefault: true },
      { uid: "AudioInterfaceUID123", name: "Scarlett 2i2", sampleRate: 48000, channelCount: 2, isDefault: false },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "output_list_devices", arguments: {} });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "output.listDevices");
  assert.deepEqual(calls[0]!.params, {});

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's device list round-trips verbatim");
});

test("output_set_device forwards {uid} to output.setDevice and returns the reflected device list", async () => {
  const uid = "AudioInterfaceUID123";
  const stubbed = {
    devices: [
      { uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", sampleRate: 48000, channelCount: 2, isDefault: true },
      { uid, name: "Scarlett 2i2", sampleRate: 48000, channelCount: 2, isDefault: false },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "output_set_device", arguments: { uid } });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "output.setDevice");
  assert.deepEqual(calls[0]!.params, { uid });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the reflected device list round-trips verbatim");
});

test("output_set_device with an omitted uid forwards explicit null (never a dropped key)", async () => {
  queuedResult = { devices: [] };

  const result = await client.callTool({ name: "output_set_device", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "output.setDevice");
  assert.deepEqual(calls[0]!.params, { uid: null }, "omitted uid must forward as explicit null, matching input_set_device's shape");
  assert.ok(!(result as any).isError);
});

test("output_set_device rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "output_set_device",
    arguments: { uid: randomUUID(), makeDefault: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the strict wrapper must reject unknown keys");
  assert.equal(calls.length, 0, "a rejected call never reaches the bridge");
});

test("output_set_device surfaces an app-side error as an MCP tool error, message verbatim", async () => {
  // VERBATIM from the app — `MediaImporting.swift:321`. It was previously a
  // paraphrase ending "call output_list_devices to see what's available",
  // which the app never emits, and the assertion below matched the MCP TOOL
  // name against it. That passed only because the stub fabricated the very
  // string the regex looked for: the app teaches the WIRE verb
  // (`output.listDevices`), not the MCP tool name, so the old test asserted a
  // contract that did not exist. If this string drifts from the Swift side the
  // fix is to re-copy it, never to loosen the pattern.
  queuedError = new Error("no output device with uid 'missing-uid' — use output.listDevices");

  const result = await client.callTool({ name: "output_set_device", arguments: { uid: "missing-uid" } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "output.setDevice");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /output\.listDevices/, "the app's teaching message passes through verbatim");
});

test("output_list_devices surfaces an app-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("app not running — start DAW Pro or run `swift run DAWApp`");

  const result = await client.callTool({ name: "output_list_devices", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "output.listDevices");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /app not running/, "the app's teaching message passes through verbatim");
});
