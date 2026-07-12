/**
 * copilot.test.ts — round-trip coverage for ai_copilot_send / ai_copilot_state
 * (M6 rail-c, extended by m10-m's optional `maxRounds` override + `limits`
 * introspection).
 *
 * Same stub-bridge pattern as connection-info.test.ts / clip-time-range.test.ts
 * (the m10-h/m10-l precedent): unlike integration.test.ts (real spawned DAWApp
 * + real control WebSocket), this suite monkeypatches `DawBridge.prototype.send`
 * before any tool call runs, so the REAL `McpServer` from `src/server.ts` is
 * driven over an in-memory transport (the audit-tools.test.ts precedent) with
 * no live app required. Asserts:
 *   - ai_copilot_send forwards `message` and, when supplied, `maxRounds`
 *     verbatim to `ai.copilotSend`
 *   - an omitted `maxRounds` never reaches the bridge as a real value (the
 *     wire drops it — see below for why the assertion is per-field, not a
 *     whole-object deepEqual)
 *   - a `maxRounds` outside 1-32 is rejected at the MCP schema layer itself
 *     (an `isError` tool result, zero bridge calls) — matching this server's
 *     existing fixed-range-numeric house style (mixer_set_master_volume,
 *     clip_set_stretch's ratio/semitones, clip_quantize's swing all reject
 *     out-of-range at the zod schema rather than forwarding for the app to
 *     clamp); the app-side CLAMP-not-error behavior documented in
 *     `Sources/DAWCore/CopilotLimits.swift` still holds for any OTHER caller
 *     of the raw control-protocol wire, just not for values that never make
 *     it past this tool's schema
 *   - a stubbed success result (including the additive `limits` object) round-
 *     trips back through ai_copilot_send / ai_copilot_state unchanged — this
 *     server never allow-lists response fields (see `textResult` in
 *     src/server.ts), so `limits` needs no code change to pass through, only
 *     this regression test
 *   - a stubbed app-side error surfaces as an MCP tool error (isError: true)
 *     carrying the app's own message verbatim, never swallowed
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

// ---------------------------------------------------------------------------
// Stub the bridge BEFORE any tool call runs (see clip-time-range.test.ts for
// why patching the prototype here is safe and server-wide).
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
  client = new Client({ name: "copilot-test-client", version: "0.0.0" });
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
// ai_copilot_send
// ---------------------------------------------------------------------------

test("ai_copilot_send forwards message only (no maxRounds) when maxRounds is omitted", async () => {
  queuedResult = { turnId: "turn-1", status: "running" };

  const result = await client.callTool({
    name: "ai_copilot_send",
    arguments: { message: "add a bassline on the Bass track" },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "ai.copilotSend");
  assert.equal(calls[0]!.params["message"], "add a bassline on the Bass track");
  // The literal object the tool builds always destructures `maxRounds` (the
  // house style — see clip_set_stretch's ratio/semitones forwarding), so the
  // key may be PRESENT with value `undefined`; either way it is absent once
  // `bridge.send` JSON.stringifies the wire frame (JSON.stringify drops
  // undefined-valued properties), which is the behavior that actually matters.
  assert.equal(calls[0]!.params["maxRounds"], undefined, "an omitted maxRounds never reaches the app as a value");
  assert.equal(
    JSON.stringify(calls[0]!.params)?.includes("maxRounds"),
    false,
    "an omitted maxRounds does not appear in the JSON wire frame at all"
  );

  assert.deepEqual(parseJSON(result as any), queuedResult);
});

test("ai_copilot_send forwards a supplied maxRounds verbatim to ai.copilotSend", async () => {
  queuedResult = { turnId: "turn-2", status: "running" };

  const result = await client.callTool({
    name: "ai_copilot_send",
    arguments: { message: "program a 2-bar house beat", maxRounds: 3 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "ai.copilotSend");
  assert.equal(calls[0]!.params["message"], "program a 2-bar house beat");
  assert.equal(calls[0]!.params["maxRounds"], 3, "maxRounds forwarded verbatim, unmodified");

  assert.deepEqual(parseJSON(result as any), queuedResult);
});

for (const boundary of [1, 32] as const) {
  test(`ai_copilot_send accepts maxRounds at the ${boundary} boundary`, async () => {
    queuedResult = { turnId: `turn-${boundary}`, status: "running" };

    const result = await client.callTool({
      name: "ai_copilot_send",
      arguments: { message: "quick ask", maxRounds: boundary },
    });

    assert.equal(calls.length, 1);
    assert.equal(calls[0]!.params["maxRounds"], boundary);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok(!(result as any).isError);
  });
}

for (const outOfRange of [0, 33, -5, 1.5] as const) {
  test(`ai_copilot_send rejects an out-of-range maxRounds (${outOfRange}) at the schema layer, never reaching the bridge`, async () => {
    const result = await client.callTool({
      name: "ai_copilot_send",
      arguments: { message: "quick ask", maxRounds: outOfRange },
    });

    assert.equal(calls.length, 0, "invalid arguments never reach bridge.send");
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r = result as any;
    assert.ok(r.isError, "an out-of-range maxRounds is a tool-call error, not a silent pass-through");
  });
}

test("ai_copilot_send surfaces a bridge-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("a copilot turn is already running — poll ai_copilot_state or call ai_copilot_reset");

  const result = await client.callTool({
    name: "ai_copilot_send",
    arguments: { message: "add a bassline" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /already running/);
});

// ---------------------------------------------------------------------------
// ai_copilot_state
// ---------------------------------------------------------------------------

test("ai_copilot_state forwards turnId and round-trips the response verbatim, including the additive limits object", async () => {
  const stubbedState = {
    status: "running",
    currentTurnId: "turn-3",
    transcript: [{ id: "e1", turnId: "turn-3", kind: "user", text: "add a bassline" }],
    limits: { maxRounds: 8, defaultMaxRounds: 8, validMin: 1, validMax: 32 },
  };
  queuedResult = stubbedState;

  const result = await client.callTool({ name: "ai_copilot_state", arguments: { turnId: "turn-3" } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "ai.copilotState");
  assert.equal(calls[0]!.params["turnId"], "turn-3");

  assert.deepEqual(
    parseJSON(result as any),
    stubbedState,
    "limits (and every other field) passes through unmodified — this server never allow-lists response fields"
  );
});

test("ai_copilot_state round-trips a limits object reflecting a per-turn maxRounds override", async () => {
  const stubbedState = {
    status: "done",
    transcript: [],
    limits: { maxRounds: 3, defaultMaxRounds: 8, validMin: 1, validMax: 32 },
  };
  queuedResult = stubbedState;

  const result = await client.callTool({ name: "ai_copilot_state", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "ai.copilotState");
  assert.equal(calls[0]!.params["turnId"], undefined, "omitted turnId forwards as no value");

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed.limits, { maxRounds: 3, defaultMaxRounds: 8, validMin: 1, validMax: 32 });
});

test("ai_copilot_state surfaces a bridge-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("copilot engine not wired — app startup incomplete");

  const result = await client.callTool({ name: "ai_copilot_state", arguments: {} });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /not wired/);
});
