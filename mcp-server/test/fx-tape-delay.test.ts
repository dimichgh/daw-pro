/**
 * fx-tape-delay.test.ts — the m39-n tape delay's MCP surface.
 *
 * NO NEW TOOL ships with m39-n, and that is a contract rather than an omission
 * (creative-effects design rule 6.0.11): a new effect KIND rides the existing
 * fx_add / fx_set_param / fx_describe / automation_add_lane surface, so the
 * wire command count and the MCP tool count must both be UNCHANGED by this
 * item. What CAN silently go missing when a kind is added to shared schemas
 * and shared prose is what this file pins:
 *
 *   1. `tapeDelay` is accepted by `fxKindSchema` and forwarded VERBATIM. A
 *      kind missing from the enum is rejected at the MCP boundary with a
 *      schema error and never reaches the app — which reads to an agent as
 *      "the DAW does not have one".
 *   2. All eight params forward verbatim through `fx_add`'s `params` and
 *      `fx_set_param`.
 *   3. ⭐⭐ THE DESCRIPTION CARRIES THE ONE THING AN AGENT CANNOT INFER AND
 *      WILL OTHERWISE GET WRONG: `delay` and `tapeDelay` are BOTH shipping,
 *      and the choice between them is decided by two facts, not by taste —
 *      only `delay` has tempo sync, and only `tapeDelay` can wow (`delay`
 *      reads its line at whole-sample offsets, so a sub-sample drift is
 *      unrepresentable there, not merely untuned). An agent that does not
 *      know this will either reach for `delay` when asked for "tape" and
 *      deliver a static echo, or reach for `tapeDelay` when asked for a
 *      dotted-eighth and find no `sync` param.
 *   4. ⚠️ And the honest ones: `timeMs` bends PITCH while repeats are
 *      sounding (a consequence, not the `delay` kind's click), and the tape
 *      stage is in the RECORD path so even the FIRST repeat is coloured.
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
  client = new Client({ name: "fx-tape-delay-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { effectId: "tape-1", effects: [] };
});

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

test("fx_add accepts kind tapeDelay and forwards it verbatim", async () => {
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "tapeDelay" },
  });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.add");
  assert.equal(calls[0]!.params.kind, "tapeDelay");
  assert.equal(calls[0]!.params.trackId, "track-1");
});

test("fx_add forwards all eight tapeDelay params unmodified", async () => {
  const params = {
    timeMs: 812.5,
    feedback: 0.72,
    mix: 0.55,
    wowDepthMs: 5.25,
    wowRateHz: 1.7,
    flutterDepthMs: 0.62,
    saturationDrive: 0.85,
    highCutHz: 3150,
  };
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "tapeDelay", params },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.params, params);
});

test("fx_set_param forwards a tapeDelay wow depth unmodified", async () => {
  await client.callTool({
    name: "fx_set_param",
    arguments: { trackId: "track-1", effectId: "tape-1", name: "wowDepthMs", value: 7.5 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.setParam");
  assert.equal(calls[0]!.params.name, "wowDepthMs");
  assert.equal(calls[0]!.params.value, 7.5);
});

test("fx_describe accepts tapeDelay as a kind", async () => {
  queuedResult = { kinds: [] };
  await client.callTool({ name: "fx_describe", arguments: { kind: "tapeDelay" } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.describe");
  assert.equal(calls[0]!.params.kind, "tapeDelay");
});

test("an unknown or mis-cased effect kind is still rejected at the MCP boundary", async () => {
  // The positive control for the tests above: they would also pass if the enum
  // had been replaced by a free-form string. It has not.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const miscased: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "tapedelay" },
  });
  assert.ok(miscased.isError, "a mis-cased kind must be rejected at the boundary");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const invented: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "echoplex" },
  });
  assert.ok(invented.isError, "an invented kind must be rejected at the boundary");
  assert.equal(calls.length, 0, "nothing reached the bridge");
});

test("the kind schema states BOTH facts that decide between `delay` and `tapeDelay`", async () => {
  // ⭐ The single most likely way an agent ships the wrong result here: treat
  // the two kinds as stylistic alternatives. They are not. Each fact is stated
  // with the consequence attached, because "no sync" and "cannot wow" are only
  // actionable once you know which request each one rules out.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /tapeDelay/, "the kind is named");
  assert.match(kind, /NO TEMPO SYNC/, "the missing-sync fact is stated");
  assert.match(kind, /use `delay`/, "and the kind to use instead is named");
  assert.match(kind, /CANNOT WOW/, "the delay kind's structural limit is stated");
  assert.match(kind, /WHOLE\s+" \+\s+"NUMBER OF SAMPLES|WHOLE NUMBER OF SAMPLES/,
    "and WHY it cannot — the mechanism, not just the verdict");
});

test("the kind schema points at the derived cents rather than leaving wow to guesswork", async () => {
  // ⚠️ `wowDepthMs: 2.5` means nothing to an agent asked for "a bit of wobble".
  // The unit a musician has is cents, and the server must say where to get it.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /wowCents/, "the derived readout is named");
  assert.match(kind, /flutterCents/);
  assert.match(kind, /1200\*log2/, "the arithmetic is given, not hand-waved");
  assert.match(kind, /10\.8 cents/, "the default is quantified");
  assert.match(kind, /MULTIPLY/, "depth x rate is stated as a product");
});

test("the kind schema names the RIGHT verb for the derived cents, and disclaims the wrong one", async () => {
  // ⭐⭐ THE DEFECT THIS PINS, CAUGHT IN REVIEW BEFORE IT SHIPPED. The derived
  // echoes are produced by `Commands.effectParamsJSON`, which feeds the
  // `effects[].params` object of `fx.add` / `fx.setParam` / `project.snapshot`.
  // `fx.describe` returns something else entirely — per-KIND schemas
  // (name/min/max/default/curve/note) with no instance and no values — so an
  // agent told to "call fx_describe for wowCents" gets a valid-looking
  // response with the key absent and concludes the feature does not exist.
  // The first draft said exactly that, copied from the flanger's
  // `firstNotchHzAtSweepFloor` sentence, which is pre-existing and wrong the
  // same way. This test is why a second copy did not ship.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /fx_add and fx_set_param RESULT/, "the verbs that DO carry it are named");
  assert.match(kind, /project_snapshot/, "and the poll path too");
  assert.match(kind, /NOT in fx_describe/, "and the one that does NOT is called out");
  assert.doesNotMatch(kind, /fx_describe echoes `wowCents`/,
    "the false claim must not come back");
});

test("the kind schema is HONEST about the two things that surprise a tape-delay user", async () => {
  const kind = await describeParam("fx_add", "kind");
  // (a) automating timeMs bends pitch — a consequence, not the `delay` click.
  assert.match(kind, /BENDS THE PITCH/);
  assert.match(kind, /DOPPLER GLIDE/);
  assert.match(kind, /NOT the `delay` kind's whole-sample stepping/);
  // (b) the tape stage is in the RECORD path, so repeat ONE is already coloured.
  assert.match(kind, /RECORD PATH/);
  assert.match(kind, /FIRST repeat is already rolled/);
  // (c) drive 0 is exactly linear, so "clean echo with wow" is reachable.
  assert.match(kind, /EXACTLY linear/);
});
