/**
 * fx-dynamic-eq.test.ts — the m39-af dynamic EQ's MCP surface.
 *
 * NO NEW TOOL ships with m39-af, and that is a contract rather than an
 * omission (the `djFilter`/`clipper` precedent): a new effect KIND rides the
 * existing fx_add / fx_set_param / fx_describe / automation_add_lane surface,
 * so the wire command count (227) and the MCP tool count (232) must both be
 * UNCHANGED by this item — `scripts/gates/doc-count-drift.mjs` is the
 * independent pin for that, not this file. What CAN silently go missing when
 * a kind is added to shared schemas and shared prose is what this file pins:
 *
 *   1. `dynamicEQ` is accepted by `fxKindSchema` and forwarded VERBATIM. A
 *      kind missing from the enum is rejected at the MCP boundary with a
 *      schema error and never reaches the app — which reads to an agent as
 *      "the DAW does not have one".
 *   2. All 32 band-major params forward verbatim through `fx_add`'s `params`
 *      and `fx_set_param`, including a FRACTIONAL `bandNMode` — the MCP layer
 *      must not itself round or coerce it; the clamp-then-snap split is a
 *      Swift-side contract (`DynamicEQParamsTests` et al.), not this layer's
 *      job, so this file only proves the number reaches the bridge unchanged.
 *   3. ⭐ THE DESCRIPTIONS CARRY THE THREE THINGS AN AGENT CANNOT INFER: that
 *      this `Q` is measurably different from `eq`'s `Q`, that `bandNMode` is
 *      CLAMPED not SNAPPED (the `clipper.mode` precedent — NOT `phaser.stages`,
 *      which really does snap its stored value; that citation was wrong — do
 *      not "fix" it), and that one fully-automated instance is HALF of the
 *      strip's shared 64-slot automation/modulation budget. The tool/param
 *      descriptions are the only manual an agent gets, so that teaching is a
 *      shippable property.
 *   4. ⛔ It is offered on the MASTER chain and named by `fx_describe` and by
 *      `automation_add_lane`'s target schema — three separate surfaces a kind
 *      can land in one of and be missing from the others.
 *
 * ⚠️ Deliberately NOT pinned here: the full `masterChainBuiltInOnly` teaching
 * string. It is Swift-owned contract text (`MediaImporting.swift`, pinned
 * verbatim by `MasterChainCommandTests`/`MasterChainStoreTests`); no test in
 * this repository pinned it verbatim before this item either (checked: only
 * PREFIX regexes at fx-bit-crusher.test.ts / fx-dj-filter.test.ts, both of
 * which match a substring earlier than where `dynamicEQ` was appended and so
 * are unaffected by the append). Pinning the whole string here would just be
 * a second, this-time-JS copy of a Swift contract to forget to update.
 *
 * The stub-bridge pattern is fx-dj-filter.test.ts's, verbatim.
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
  client = new Client({ name: "fx-dynamic-eq-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { effectId: "deq-1", effects: [] };
});

async function describeTool(name: string): Promise<string> {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === name);
  assert.ok(tool, `${name} must be registered`);
  return tool.description ?? "";
}

/**
 * The description of ONE INPUT PARAMETER, as the MCP client receives it.
 * ⚠️ The per-kind teaching does NOT live in `fx_add`'s tool description — it
 * lives in `fxKindSchema`'s `.describe()`, which lands on
 * `inputSchema.properties.kind` (the finding fx-bit-crusher.test.ts records).
 */
async function describeParam(tool: string, param: string): Promise<string> {
  const { tools } = await client.listTools();
  const found = tools.find((t) => t.name === tool);
  assert.ok(found, `${tool} must be registered`);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const properties = (found.inputSchema as any).properties ?? {};
  assert.ok(properties[param], `${tool}.${param} must be in the input schema`);
  return JSON.stringify(properties[param]);
}

// The 32 wire names, band-major, in slot order — mirrors
// `DynamicEQParams.paramNames` (`Sources/DAWCore/Effects.swift`), the one
// home this test reads its expectations from rather than re-deriving them.
const DYNAMIC_EQ_PARAM_NAMES: string[] = [1, 2, 3, 4].flatMap((band) => [
  `band${band}Mode`,
  `band${band}Freq`,
  `band${band}Q`,
  `band${band}ThresholdDb`,
  `band${band}Ratio`,
  `band${band}RangeDb`,
  `band${band}AttackMs`,
  `band${band}ReleaseMs`,
]);

test("dynamicEQ has exactly 32 band-major param names, band1Mode first, band4ReleaseMs last", () => {
  assert.equal(DYNAMIC_EQ_PARAM_NAMES.length, 32);
  assert.equal(DYNAMIC_EQ_PARAM_NAMES[0], "band1Mode");
  assert.equal(DYNAMIC_EQ_PARAM_NAMES[31], "band4ReleaseMs");
});

test("fx_add accepts kind dynamicEQ and forwards it verbatim", async () => {
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "dynamicEQ" },
  });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.add");
  assert.equal(calls[0]!.params.kind, "dynamicEQ");
  assert.equal(calls[0]!.params.trackId, "track-1");
});

test("fx_add forwards all 32 dynamicEQ params, a FRACTIONAL bandNMode included", async () => {
  // ⭐ The fractional band1Mode is the point: this layer must pass 1.5 through
  // unchanged rather than rounding it itself — the clamp-then-snap split
  // (stored value clamped but not rounded; the snapped truth echoed back as
  // `band1ModeLabel`) is a Swift-side contract this test does not re-derive.
  const params: Record<string, number> = {};
  DYNAMIC_EQ_PARAM_NAMES.forEach((name, i) => {
    params[name] = name.endsWith("Mode") ? 1.5 : i + 0.25;
  });
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "dynamicEQ", params },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.params, params);
});

test("fx_set_param forwards a fractional band3Mode unmodified", async () => {
  await client.callTool({
    name: "fx_set_param",
    arguments: { trackId: "track-1", effectId: "deq-1", name: "band3Mode", value: 1.5 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.setParam");
  assert.equal(calls[0]!.params.name, "band3Mode");
  assert.equal(calls[0]!.params.value, 1.5, "not rounded/snapped at this layer");
});

test("fx_describe accepts dynamicEQ as a kind", async () => {
  queuedResult = { kinds: [] };
  await client.callTool({ name: "fx_describe", arguments: { kind: "dynamicEQ" } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.describe");
  assert.equal(calls[0]!.params.kind, "dynamicEQ");
});

test("an unknown or mis-cased effect kind is still rejected at the MCP boundary", async () => {
  // The positive control for the tests above: they would also pass if the enum
  // had been replaced by a free-form string. It has not.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const miscased: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "dynamiceq" },
  });
  assert.ok(miscased.isError, "a mis-cased kind must be rejected at the boundary");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const invented: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "multibandCompressor" },
  });
  assert.ok(invented.isError, "an invented kind must be rejected at the boundary");
  assert.equal(calls.length, 0, "nothing reached the bridge");
});

test("fx_add's kind schema teaches that this Q is NOT eq's Q, measured", async () => {
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /dynamicEQ/);
  assert.match(kind, /704 Hz/, "the dynamicEQ band width at 1 kHz Q 2 is stated");
  assert.match(kind, /498 Hz/, "the eq band width at the same setting is stated for contrast");
});

test("fx_add's kind schema teaches mode times the sign of rangeDb as four moves", async () => {
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /FOUR/i);
  assert.match(kind, /de-esses|de-ess/i);
});

test("fx_add's kind schema teaches bandNMode is CLAMPED not SNAPPED, and names the precedent", async () => {
  // ⚠️ This is the trap the brief called out explicitly: an agent must not
  // "fix" the clamp-not-snap behaviour. The precedent kinds are named so an
  // agent can cross-check against effects it already understands.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /DISCRETE/);
  assert.match(kind, /phaser\.stages/);
  assert.match(kind, /clipper\.mode/);
  assert.match(kind, /bandNModeLabel|band1ModeLabel/);
});

test("fx_add's kind schema states zero latency and no gain-reduction meter", async () => {
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /ZERO LATENCY|ZERO latency/i);
  assert.match(kind, /fx_spectrum/, "the alternative to a GR meter is named");
});

test("fx_add's kind schema warns about the shared 64-slot automation/modulation budget", async () => {
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /64-entry cap|64-slot budget/i);
  assert.match(kind, /mod_add_route/);
  assert.match(kind, /automation_add_lane/);
});

test("dynamicEQ is offered on the master chain and named by fx_describe", async () => {
  // The master-chain list is in the TOOL description, a different surface from
  // the kind schema above — a kind can be in one and missing from the other.
  // ⚠️ This pins only that `dynamicEQ` was appended AFTER `clipper` at the end
  // of the master-chain list — NOT the full verbatim teaching string, which is
  // Swift-owned contract text pinned elsewhere (see file header).
  const addTool = await describeTool("fx_add");
  assert.match(addTool, /freqShifter\|clipper\|dynamicEQ\)/);
  const describe = await describeTool("fx_describe");
  assert.match(describe, /dynamicEQ/);
});

test("automation_add_lane's target schema names dynamicEQ among built-in kinds that work today", async () => {
  const target = await describeParam("automation_add_lane", "target");
  assert.match(target, /dynamicEQ/);
});

test("automation_add_lane's target schema warns the budget check is ASYMMETRIC across the two tools", async () => {
  // ⛔ The actual trap: mod_add_route refuses past the cap, automation_add_lane
  // does not — an agent relying on "it returned success" alone will not learn
  // that a lane past 64 silently never reaches the render thread.
  const target = await describeParam("automation_add_lane", "target");
  assert.match(target, /dynamicEQ/);
  assert.match(target, /mod_add_route/);
  assert.match(target, /refuses/i);
  assert.match(target, /automation_add_lane.*NOT/is);
});
