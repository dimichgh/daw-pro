/**
 * pedal-hold-limit.test.ts — m34-q's MCP surface: `pedalHoldLimit` on
 * `track_set_instrument` (top level = poly synth, nested `sampler` object =
 * sampler) and as a twelfth `instrument_set_sampler_param` global.
 *
 * The `sampler-describe-and-edit.test.ts` stub-bridge pattern verbatim:
 * monkeypatch `DawBridge.prototype.send` before importing the real
 * `McpServer`, drive the tools over an in-memory transport, and assert what
 * reaches the wire — never what the tool "should" have sent.
 *
 * ⚠️ WHERE EACH GUARD LIVES, because the two boundaries refuse DIFFERENT
 * things and a test that confuses them proves nothing:
 *   - `track_set_instrument` types `pedalHoldLimit` as `.int().min(1).max(128)`
 *     at BOTH levels, so a fractional or out-of-range value there dies at the
 *     SCHEMA and never reaches the bridge (asserted with `calls.length === 0`).
 *   - `instrument_set_sampler_param`'s `value` is a deliberately wide
 *     `number | boolean | string` union shared by all twelve params, so range
 *     is enforced APP-SIDE by `Commands.swift`'s `optionalBoundedInteger`.
 *     The tests below therefore assert that an out-of-range value REACHES the
 *     bridge intact (that is the contract) — the refusal itself is pinned in
 *     Swift by `Tests/DAWControlTests/PedalHoldLimitWireTests.swift` (whose
 *     tests live in an EXTENSION on `CommandRouterTests`, not a suite of their
 *     own — see that file's header for why). Claiming a schema refusal here
 *     would be a green test for a guard that does not exist.
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
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let tools: any[];

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "pedal-hold-limit-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  const listed = await client.listTools();
  tools = listed.tools;
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = undefined;
  queuedError = undefined;
});

// ---------------------------------------------------------------------------
// track_set_instrument — the sampler's cap (nested, .strict() object)
// ---------------------------------------------------------------------------

test("track_set_instrument forwards sampler.pedalHoldLimit through the strict nested schema", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler", sampler: { pedalHoldLimit: 6 } };

  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "sampler", sampler: { pedalHoldLimit: 6 } },
  })) as any;

  assert.ok(!result.isError, `a legitimate cap must be accepted: ${JSON.stringify(result)}`);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
  assert.deepEqual(calls[0]!.params["sampler"], { pedalHoldLimit: 6 });
});

test("an omitted sampler.pedalHoldLimit forwards as undefined — never a fabricated 'unlimited' number", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler" };

  await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "sampler", sampler: { release: 0.4 } },
  });

  assert.equal(calls.length, 1);
  const sampler = calls[0]!.params["sampler"] as Record<string, unknown>;
  assert.equal(sampler["pedalHoldLimit"], undefined);
  assert.ok(
    !Object.prototype.hasOwnProperty.call(sampler, "pedalHoldLimit"),
    "the key must not appear at all — an unlimited sampler has to keep its pre-m34-q wire shape"
  );
});

// ---------------------------------------------------------------------------
// track_set_instrument — the poly synth's cap (top level)
// ---------------------------------------------------------------------------

test("track_set_instrument forwards a top-level pedalHoldLimit for the poly synth", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "polySynth", polySynth: { pedalHoldLimit: 4 } };

  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "polySynth", pedalHoldLimit: 4 },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
  assert.equal(calls[0]!.params["pedalHoldLimit"], 4);
});

test("an omitted top-level pedalHoldLimit forwards as undefined", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "polySynth" };

  await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "polySynth", release: 0.3 },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["pedalHoldLimit"], undefined);
  assert.equal(calls[0]!.params["release"], 0.3, "control: a param that WAS sent still arrives");
});

// ---------------------------------------------------------------------------
// Schema-layer refusals on track_set_instrument (both levels)
// ---------------------------------------------------------------------------

test("track_set_instrument refuses a fractional or out-of-range pedalHoldLimit at BOTH levels, zero bridge calls", async () => {
  const trackId = randomUUID();

  const cases: Array<[string, Record<string, unknown>]> = [
    ["top-level fractional", { trackId, pedalHoldLimit: 4.5 }],
    ["top-level zero", { trackId, pedalHoldLimit: 0 }],
    ["top-level negative", { trackId, pedalHoldLimit: -3 }],
    ["top-level over 128", { trackId, pedalHoldLimit: 129 }],
    ["sampler fractional", { trackId, sampler: { pedalHoldLimit: 2.5 } }],
    ["sampler zero", { trackId, sampler: { pedalHoldLimit: 0 } }],
    ["sampler over 128", { trackId, sampler: { pedalHoldLimit: 300 } }],
    ["sampler string", { trackId, sampler: { pedalHoldLimit: "four" } }],
  ];

  for (const [label, args] of cases) {
    const result = (await client.callTool({ name: "track_set_instrument", arguments: args })) as any;
    assert.ok(result.isError, `${label} must be refused at the schema layer`);
  }

  assert.equal(calls.length, 0, "schema rejections never reach the bridge");

  // POSITIVE CONTROL: the boundary values of the SAME range are accepted, so
  // the refusals above are a range check and not a blanket rejection.
  queuedResult = { trackId, kind: "sampler" };
  for (const legal of [1, 128]) {
    const ok = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, sampler: { pedalHoldLimit: legal } },
    })) as any;
    assert.ok(!ok.isError, `${legal} is inside 1-128 and must be accepted: ${JSON.stringify(ok)}`);
  }
  assert.equal(calls.length, 2, "control: the two legal calls DID reach the bridge");
});

// ---------------------------------------------------------------------------
// instrument_set_sampler_param — the twelfth global
// ---------------------------------------------------------------------------

test("instrument_set_sampler_param accepts pedalHoldLimit and wraps it as {sampler:{pedalHoldLimit}}", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler", sampler: { pedalHoldLimit: 8 } };

  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "pedalHoldLimit", value: 8 },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
  assert.deepEqual(calls[0]!.params, { trackId, sampler: { pedalHoldLimit: 8 } });
});

test("instrument_set_sampler_param refuses a STRING for pedalHoldLimit — the voiceMode re-narrow guard still holds", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "pedalHoldLimit", value: "eight" },
  })) as any;

  assert.ok(result.isError, "only voiceMode takes a string");
  assert.match(result.content?.[0]?.text ?? "", /does not take a string/);
  assert.equal(calls.length, 0);

  // CONTROL: the guard is param-specific, not a blanket string ban — the one
  // string param still works.
  queuedResult = { trackId, kind: "sampler" };
  const mono = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "voiceMode", value: "mono" },
  })) as any;
  assert.ok(!mono.isError, JSON.stringify(mono));
  assert.equal(calls.length, 1);
});

test("instrument_set_sampler_param passes an OUT-OF-RANGE cap to the app, which owns that refusal", async () => {
  const trackId = randomUUID();
  // The shared `value` union carries no range; the app refuses. Pinning that
  // here as a bridge call — rather than pretending the schema catches it —
  // is what keeps this test honest about where the guard lives.
  queuedError = new Error(
    "sampler.pedalHoldLimit must be a whole number between 1 and 128 — how many notes the " +
      "sustain pedal (CC 64) keeps ringing"
  );
  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "pedalHoldLimit", value: 500 },
  })) as any;

  assert.ok(result.isError);
  assert.equal(calls.length, 1, "the value reaches the app — the app is the guard for this tool");
  assert.deepEqual(calls[0]!.params["sampler"], { pedalHoldLimit: 500 });
  assert.match(result.content?.[0]?.text ?? "", /between 1 and 128/);
});

test("instrument_set_sampler_param still rejects an unknown param name (the enum did not go loose)", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "pedalHoldLimitt", value: 4 },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// The schema and the descriptions ARE the contract
// ---------------------------------------------------------------------------

test("pedalHoldLimit is in instrument_set_sampler_param's param enum, and the enum is the documented fourteen", () => {
  const tool = tools.find((t) => t.name === "instrument_set_sampler_param");
  assert.ok(tool, "instrument_set_sampler_param is registered");
  const paramSchema = (tool.inputSchema as any).properties?.param;
  assert.ok(paramSchema, "the tool exposes a `param` property");
  const values: string[] = paramSchema.enum ?? paramSchema.anyOf?.flatMap((a: any) => a.enum ?? []) ?? [];
  assert.ok(values.includes("pedalHoldLimit"), `enum must list pedalHoldLimit, got ${JSON.stringify(values)}`);
  // The description CLAIMS a field count. A claimed count that stops matching
  // the enum is exactly the "the record says X, the source says Y" shape this
  // tree keeps paying for, so pin them to each other rather than to a literal.
  // m34-t added `glideTime` — the thirteenth; m34-w added `glideMode` — the
  // fourteenth. This pin is why neither could be added without also updating
  // the prose count.
  assert.equal(values.length, 14, `the enum holds fourteen globals, got ${values.length}`);
  assert.match(
    paramSchema.description as string,
    /fourteen fields/,
    "the prose count must match the enum length"
  );
});

test("descriptions teach the two load-bearing facts: RELEASED not cut, and a held key is never taken", () => {
  const setParam = tools.find((t) => t.name === "instrument_set_sampler_param");
  const setInstrument = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(setParam && setInstrument);

  const paramDescription = ((setParam.inputSchema as any).properties?.param?.description ?? "") as string;
  assert.match(paramDescription, /RELEASED/, "the eviction fades through `release`; it does not cut");
  assert.match(paramDescription, /never/i);
  assert.match(paramDescription, /still holding/i, "a key under the player's finger is never reclaimed");

  const samplerCap = ((setInstrument.inputSchema as any).properties?.sampler?.properties?.pedalHoldLimit
    ?.description ?? "") as string;
  assert.ok(samplerCap.length > 0, "the nested sampler schema exposes pedalHoldLimit");
  assert.match(samplerCap, /unlimited/i, "omitted means unlimited — today's behaviour, stated");
  assert.match(samplerCap, /RELEASED/);
  assert.match(samplerCap, /STILL HOLDING DOWN/);
  assert.match(samplerCap, /64-voice pool/, "says which pool makes a large cap meaningless");

  const polyCap = ((setInstrument.inputSchema as any).properties?.pedalHoldLimit?.description ?? "") as string;
  assert.ok(polyCap.length > 0, "the top-level poly-synth cap is exposed");
  assert.match(polyCap, /polySynth/, "distinguishes itself from the sampler's own cap");
  assert.match(polyCap, /16-voice pool/);
  assert.match(polyCap, /RELEASED/);
});

test("instrument_set_sampler_param's title names the new global", () => {
  const tool = tools.find((t) => t.name === "instrument_set_sampler_param");
  assert.match(tool.title as string, /pedal hold limit/i);
  assert.match(tool.description as string, /pedalHoldLimit/);
});
