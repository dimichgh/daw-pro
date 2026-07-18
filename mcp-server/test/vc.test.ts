/**
 * vc.test.ts — round-trip coverage for vc_sidecar_status/start/stop (m10-p-3).
 *
 * Same stub-bridge pattern as connection-info.test.ts (the m10-l precedent,
 * itself following clip-time-range.test.ts): unlike integration.test.ts
 * (real spawned DAWApp + real control WebSocket), this suite monkeypatches
 * `DawBridge.prototype.send` before any tool call runs, so the REAL
 * `McpServer` from `src/server.ts` is driven over an in-memory transport
 * (the audit-tools.test.ts precedent) with no live app required. Asserts:
 *   - each tool takes no params and forwards exactly the matching
 *     `vc.sidecarStatus`/`vc.sidecarStart`/`vc.sidecarStop` command with no
 *     arguments
 *   - a stubbed success result round-trips back through the tool unchanged
 *   - a stubbed app-side error surfaces as an MCP tool error (isError: true)
 *     carrying the app's own message verbatim, never swallowed
 *   - start/stop reject an unrecognized extra argument at the MCP boundary
 *     (the m16-e strict-schema convention every mutating tool gets)
 *   - adding this trio never touched the sibling ai_sidecar_* tools
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
  client = new Client({ name: "vc-test-client", version: "0.0.0" });
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
// vc_sidecar_status
// ---------------------------------------------------------------------------

test("vc_sidecar_status takes no params and forwards to vc.sidecarStatus with no arguments", async () => {
  const stubbedStatus = {
    state: "healthy",
    message: "RVC voice-conversion sidecar is running and healthy.",
    version: "0.1.0",
    engine: "Acelogic/Retrieval-based-Voice-Conversion-MLX",
    baseModelPresent: true,
    voiceCount: 0,
  };
  queuedResult = stubbedStatus;

  const result = await client.callTool({ name: "vc_sidecar_status", arguments: {} });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "vc.sidecarStatus");
  assert.deepEqual(calls[0]!.params, {}, "no arguments are forwarded — this command takes no params");

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedStatus, "the app's response round-trips back verbatim");
});

test("vc_sidecar_status surfaces a bridge-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("app not running — start DAW Pro or run `swift run DAWApp`");

  const result = await client.callTool({ name: "vc_sidecar_status", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "vc.sidecarStatus");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a bridge-side failure must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /app not running/, "the actionable error message passes through verbatim");
});

// ---------------------------------------------------------------------------
// vc_sidecar_start
// ---------------------------------------------------------------------------

test("vc_sidecar_start takes no params and forwards to vc.sidecarStart with no arguments", async () => {
  const stubbedStatus = { state: "starting", message: "RVC voice-conversion sidecar is starting (0s so far)." };
  queuedResult = stubbedStatus;

  const result = await client.callTool({ name: "vc_sidecar_start", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "vc.sidecarStart");
  assert.deepEqual(calls[0]!.params, {});
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.deepEqual(parseJSON(r), stubbedStatus);
});

test("vc_sidecar_start rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({ name: "vc_sidecar_start", arguments: { bogus: true } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an unrecognized key must be rejected before the bridge call");
  assert.equal(calls.length, 0, "the strict schema rejects before bridge.send is ever invoked");
});

test("vc_sidecar_start surfaces a notInstalled-style bridge error verbatim", async () => {
  queuedError = new Error("RVC voice-conversion sidecar directory could not be resolved — set DAWPRO_RVC_DIR");

  const result = await client.callTool({ name: "vc_sidecar_start", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /DAWPRO_RVC_DIR/);
});

// ---------------------------------------------------------------------------
// vc_sidecar_stop
// ---------------------------------------------------------------------------

test("vc_sidecar_stop takes no params and forwards to vc.sidecarStop with no arguments", async () => {
  const stubbedStatus = { state: "installedNotRunning", message: "RVC voice-conversion sidecar stopped." };
  queuedResult = stubbedStatus;

  const result = await client.callTool({ name: "vc_sidecar_stop", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "vc.sidecarStop");
  assert.deepEqual(calls[0]!.params, {});
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.deepEqual(parseJSON(r), stubbedStatus);
});

test("vc_sidecar_stop rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({ name: "vc_sidecar_stop", arguments: { force: true } });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// Additive guarantee: the sibling ai_sidecar_* tools are unaffected.
// ---------------------------------------------------------------------------

test("ai_sidecar_status is still registered, unaffected, and forwards to ai.sidecarStatus unchanged", async () => {
  const stubbedStatus = { state: "healthy", message: "ACE-Step sidecar is running and healthy.", version: "1.0" };
  queuedResult = stubbedStatus;

  const result = await client.callTool({ name: "ai_sidecar_status", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "ai.sidecarStatus");
  assert.deepEqual(calls[0]!.params, {});
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.deepEqual(parseJSON(r), stubbedStatus);
});
