/**
 * model-lifecycle.test.ts — round-trip coverage for m23-dl's two MCP tools,
 * `ai_model_residency` (the read) and `ai_model_unload` (the N-model verb).
 *
 * Same stub-bridge pattern as vc.test.ts: `DawBridge.prototype.send` is
 * monkeypatched before any tool call runs, so the REAL `McpServer` from
 * `src/server.ts` is driven over an in-memory transport with no live app — and,
 * critically, **no sidecar is ever started or stopped by this suite.**
 *
 * ⚠️ What this suite deliberately does NOT cover, because it does not exist: a
 * memory admission gate. The design specified one (refuse a boot that would not
 * fit, with `force: true` as the override); the user cut it on 2026-08-05
 * (*"let's not check for memory then, let it fail if this happens, but still
 * good to clean it up"*). So neither start tool grew a `force` parameter, and
 * `ai_model_unload` rejects one — asserted below, so a later reader can tell the
 * absence apart from an oversight.
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
  client = new Client({ name: "model-lifecycle-test-client", version: "0.0.0" });
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
// ai_model_residency
// ---------------------------------------------------------------------------

test("ai_model_residency forwards no params by default and round-trips the report", async () => {
  const stubbed = {
    generation: 42,
    sampledAt: "2026-08-05T12:00:00Z",
    memory: {
      physicalBytes: 137438953472,
      usedBytes: 72833204224,
      availableBytes: 64605749248,
      vmStatFreeBytes: 32521125888,
    },
    policy: { staleTicketSeconds: 120, jobLeaseSeconds: 3600, shutdownUnloadTimeoutSeconds: 10 },
    inFlight: null,
    models: [
      {
        modelID: "ace-step",
        displayName: "ACE-Step song generation",
        port: 8001,
        resident: true,
        holdBytes: 79993765888,
        holdConfidence: "measured",
        activeJobs: 0,
        idleUnloadSeconds: 600,
        idleUnloadAt: "2026-08-05T12:10:00Z",
        nextBootWouldUnload: [],
        nextBootProtectedByJobs: [],
      },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "ai_model_residency", arguments: {} });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "ai.modelResidency");
  assert.deepEqual(
    calls[0]!.params,
    {},
    "an omitted includeProcessDetail is NOT synthesized — the app owns the default"
  );
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's response round-trips verbatim");
});

test("ai_model_residency forwards includeProcessDetail when it is given", async () => {
  queuedResult = { generation: 1, models: [] };

  await client.callTool({
    name: "ai_model_residency",
    arguments: { includeProcessDetail: true },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { includeProcessDetail: true });
});

test("ai_model_residency is a pure READ: an unrecognized argument is stripped, not rejected", async () => {
  // The fx_describe/clip_analyze_audio precedent — the 34 read tools are
  // registered directly and are deliberately exempt from `.strict()`. The
  // control wire still rejects the stray key, so nothing is silently accepted
  // end to end.
  queuedResult = { generation: 1, models: [] };

  const result = await client.callTool({
    name: "ai_model_residency",
    arguments: { bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {}, "the stray key never reaches the bridge");
});

test("ai_model_residency surfaces an app-not-running error verbatim, never a silent success", async () => {
  queuedError = new Error("app not running — start DAW Pro or run `swift run DAWApp`");

  const result = await client.callTool({ name: "ai_model_residency", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a bridge-side failure must be a tool error");
  assert.match(r.content[0].text as string, /app not running/);
});

// ---------------------------------------------------------------------------
// ai_model_unload
// ---------------------------------------------------------------------------

test("ai_model_unload forwards {modelId} and round-trips the eviction evidence", async () => {
  const stubbed = {
    generation: 43,
    models: [
      {
        modelID: "ace-step",
        reason: "explicit",
        stopped: true,
        detail: "ACE-Step sidecar stopped.",
        evidence: {
          portFree: true,
          probeUnreachable: true,
          treePidsAliveAfter: [],
          availableBeforeBytes: 64605749248,
          availableAfterBytes: 144599515136,
          memoryReturnedBytes: 79993765888,
          memoryVerdict: "returned",
          expectedHoldBytes: 79993765888,
          generationBefore: 42,
          generationAfter: 43,
        },
      },
    ],
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "ai_model_unload",
    arguments: { modelId: "ace-step" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "ai.modelUnload");
  assert.deepEqual(calls[0]!.params, { modelId: "ace-step" }, "`all` is not synthesized");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("ai_model_unload forwards {all: true} on its own", async () => {
  queuedResult = { generation: 44, models: [] };

  await client.callTool({ name: "ai_model_unload", arguments: { all: true } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { all: true }, "`modelId` is not synthesized");
});

test("ai_model_unload sends BOTH through to the app, whose teaching error names the valid ids", async () => {
  // ⚠️ The exactly-one rule is enforced APP-SIDE, on purpose: neither a zod
  // schema nor the MCP tool surface can express "exactly one of these two"
  // without an either/or shape that reads worse than the error does, and the
  // app's message is the one that can list the ids it actually has registered.
  queuedError = new Error(
    "ai.modelUnload takes exactly one of 'modelId' or 'all', not both. " +
      "Send {\"all\": true} to unload every local model, or {\"modelId\": \"<id>\"} for one of: ace-step, rvc."
  );

  const result = await client.callTool({
    name: "ai_model_unload",
    arguments: { modelId: "ace-step", all: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /exactly one of 'modelId' or 'all'/);
  assert.match(r.content[0].text as string, /ace-step, rvc/, "the valid ids are taught, not guessed");
});

test("POSITIVE CONTROL — a stop that did not stop surfaces as an MCP tool ERROR", async () => {
  queuedError = new Error(
    "Unload FAILED for ace-step — port 8001 is still held by pid(s) 4242 " +
      "Poll ai.modelResidency (generation 45) to see what is still holding a port."
  );

  const result = await client.callTool({
    name: "ai_model_unload",
    arguments: { modelId: "ace-step" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  // A verb that cannot produce this is vacuous: reporting ok for a stop that
  // did not stop is the m23-bb / m23-ah defect family.
  assert.ok(r.isError, "a failed unload must never round-trip as a success");
  assert.match(r.content[0].text as string, /Unload FAILED/);
  assert.match(r.content[0].text as string, /still held by pid/);
});

test("ai_model_unload rejects an unrecognized argument at the MCP boundary", async () => {
  const result = await client.callTool({
    name: "ai_model_unload",
    arguments: { modelId: "ace-step", bogus: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "the strict schema rejects before bridge.send is ever invoked");
  assert.equal(calls.length, 0);
});

test("NO start tool grew a `force` flag — the memory gate was cut, not deferred", async () => {
  const { tools } = await client.listTools();
  const byName = new Map(tools.map((tool) => [tool.name, tool]));

  for (const name of ["ai_sidecar_start", "vc_sidecar_start"]) {
    const tool = byName.get(name);
    assert.ok(tool, `${name} must still be registered`);
    const properties = (tool!.inputSchema as { properties?: Record<string, unknown> }).properties ?? {};
    assert.ok(
      !("force" in properties),
      `${name} must NOT have a force parameter — there is no memory refusal for it to override, ` +
        "and adding it symmetrically to ai_sidecar_stop would collide with the wire-hardening " +
        "test that uses `force` as its stray-param probe against that verb"
    );
  }

  // ANTI-VACUITY: the two new tools ARE registered, so the loop above is not
  // passing because nothing exists.
  assert.ok(byName.has("ai_model_residency"));
  assert.ok(byName.has("ai_model_unload"));
});

test("both descriptions teach the honest lifecycle: no memory gate, but automatic cleanup", async () => {
  const { tools } = await client.listTools();
  const residency = tools.find((tool) => tool.name === "ai_model_residency");
  const unload = tools.find((tool) => tool.name === "ai_model_unload");
  assert.ok(residency && unload);

  const both = `${residency!.description ?? ""}\n${unload!.description ?? ""}`;
  // The three automatic behaviours an agent must know about before it writes a
  // policy around these tools.
  assert.match(both, /starting (one|the other) model unloads/i, "unload-before-load must be stated");
  assert.match(both, /ten idle minutes|idle minutes/i, "the idle unload must be stated");
  assert.match(both, /quit/i, "unload-on-quit must be stated");
  // And the guard that stops an agent unloading a model mid-render.
  assert.match(unload!.description ?? "", /activeJobs/, "the job guard must be discoverable");
  // ⚠️ The honest bit: an agent that reads a failed load must not go looking
  // for a memory override that does not exist.
  assert.match(
    residency!.description ?? "",
    /does not check memory/i,
    "the absence of a memory gate must be stated, not left to be discovered"
  );
});
