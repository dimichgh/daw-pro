/**
 * fx-stereo-width.test.ts — the m23-dj stereo widener's MCP surface.
 *
 * NO NEW TOOL ships with m23-dj, and that is a contract rather than an omission
 * (creative-effects design rule 6.0.11): a new effect KIND rides the existing
 * fx_add / fx_set_param / fx_describe / automation_add_lane surface, so the
 * wire command count and the MCP tool count must both be UNCHANGED by this
 * item. What CAN silently go missing when a kind is added to shared schemas
 * and shared prose is what this file pins:
 *
 *   1. `stereoWidth` is accepted by `fxKindSchema` and forwarded VERBATIM. A
 *      kind missing from the enum is rejected at the MCP boundary with a
 *      schema error and never reaches the app — which reads to an agent as
 *      "the DAW does not have one".
 *   2. All four params forward verbatim through `fx_add`'s `params` and
 *      `fx_set_param`.
 *   3. ⭐⭐ THE DESCRIPTION CARRIES THE TRAP AN AGENT CANNOT INFER AND WILL
 *      OTHERWISE SHIP AS SUCCESS: `width` is a gain on the stereo DIFFERENCE,
 *      so on a MONO source it does NOTHING — no error, no warning, a happy
 *      result object echoing `width: 2`. The control that widens a mono source
 *      is `spread`. This is the single most likely wrong outcome for the most
 *      likely request ("make my synth wide"), and it is silence-shaped.
 *   4. ⚠️ And the honest ones: `spread` costs a per-channel ripple whose two
 *      numbers ride in the RESULT and not in `fx_describe`; `bassMonoHz` is
 *      inert while `bassMonoAmount` is 0; there is NO `mix` on this kind; and
 *      a width change is close to inaudible on one speaker, which the agent
 *      has to pass on to the user rather than discover for them.
 *
 * The stub-bridge pattern is fx-tape-delay.test.ts's, verbatim.
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
  client = new Client({ name: "fx-stereo-width-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = { effectId: "width-1", effects: [] };
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

test("fx_add accepts kind stereoWidth and forwards it verbatim", async () => {
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "stereoWidth" },
  });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "fx.add");
  assert.equal(calls[0]!.params.kind, "stereoWidth");
  assert.equal(calls[0]!.params.trackId, "track-1");
});

test("fx_add forwards all four stereoWidth params unmodified", async () => {
  const params = {
    width: 1.63,
    spread: 0.71,
    bassMonoHz: 87.5,
    bassMonoAmount: 0.42,
  };
  await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "stereoWidth", params },
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params.params, params);
});

test("fx_set_param forwards a stereoWidth spread unmodified", async () => {
  await client.callTool({
    name: "fx_set_param",
    arguments: { trackId: "track-1", effectId: "width-1", name: "spread", value: 0.55 },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.setParam");
  assert.equal(calls[0]!.params.name, "spread");
  assert.equal(calls[0]!.params.value, 0.55);
});

test("fx_describe accepts stereoWidth as a kind", async () => {
  queuedResult = { kinds: [] };
  await client.callTool({ name: "fx_describe", arguments: { kind: "stereoWidth" } });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "fx.describe");
  assert.equal(calls[0]!.params.kind, "stereoWidth");
});

test("an unknown or mis-cased effect kind is still rejected at the MCP boundary", async () => {
  // The positive control for the tests above: they would also pass if the enum
  // had been replaced by a free-form string. It has not.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const miscased: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "stereowidth" },
  });
  assert.ok(miscased.isError, "a mis-cased kind must be rejected at the boundary");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const invented: any = await client.callTool({
    name: "fx_add",
    arguments: { trackId: "track-1", kind: "widener" },
  });
  assert.ok(invented.isError, "an invented kind must be rejected at the boundary");
  assert.equal(calls.length, 0, "nothing reached the bridge");
});

test("the kind schema names the SILENT NO-OP `width` has on a mono source, and the control that is not", async () => {
  // ⭐⭐ The single most likely way an agent ships a wrong result here: it is
  // asked to make a mono synth wide, reaches for `width` because that is the
  // word in the request, gets a success and an echoed `width: 2`, and reports
  // done. Not one sample changed. Both halves have to be in the text — the
  // trap AND the control that actually works — because naming the trap alone
  // leaves the agent with nothing to do next.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /stereoWidth/, "the kind is named");
  assert.match(kind, /DOES NOTHING ON A MONO SOURCE/,
    "the silent no-op is stated, in those terms");
  assert.match(kind, /that is what `spread` is/, "and the control to use instead is named");
  assert.match(kind, /ALREADY THERE/,
    "and WHY it does nothing — the mechanism, not just the verdict");
});

test("the kind schema REFUSES the `width: 0` mono-maker recipe that four docs once gave", async () => {
  // ⛔⛔ THIS TEST EXISTS BECAUSE THE PROSE WAS WRONG IN FOUR PLACES AT ONCE:
  // the `width` param note, this schema, the wire-reference skill's recipe
  // table and the MCP README all said "`width: 0` is a real mono-maker". The
  // side path is `side * width + decorrelated * spread` and `spread` DEFAULTS
  // TO 0.3, so `width: 0` on a fresh insert still emits a synthesized side
  // channel — and on a MONO source it emits one where there was none, i.e. it
  // does the OPPOSITE of the request. An agent asked to "make this mono" would
  // have followed the recipe verbatim, got `ok: true` with `width: 0` echoed
  // back, and reported done. DAWEngineTests' L2c measures the behaviour; this
  // asserts the text an agent actually reads.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /`width: 0` ALONE IS NOT A MONO-MAKER/,
    "the false recipe must be contradicted explicitly, not merely omitted");
  assert.match(kind, /`spread` defaults to 0\.3/,
    "and the mechanism that makes it false — the default the agent never set");
  assert.match(kind, /WIDER than it went in/,
    "including the sharpest case: the opposite of the request, on mono material");
  assert.match(kind, /`width: 0` AND\s+`spread: 0` TOGETHER/,
    "naming a trap without the corrected recipe leaves the agent stuck");
  // ⭐ POSITIVE CONTROL for the four assertions above: the same fetch finds a
  // phrase that has been in this text since it shipped, so a passing run
  // cannot be a schema that failed to load.
  assert.match(kind, /MID\/SIDE WIDENER AND A MONO-MAKER/,
    "control: the schema text really is the thing being matched against");
});

test("the kind schema states the mono-compatibility GUARANTEE and what it rules out", async () => {
  // ⭐ This kind's headline is not a sound, it is a promise, and the promise is
  // only useful to an agent if it also knows what the promise excludes: the
  // two tricks it must never ask for or emulate.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /ARITHMETICALLY the mono fold-down/, "the guarantee is stated");
  assert.match(kind, /only ever touches the SIDE channel/, "and the mechanism behind it");
  assert.match(kind, /Haas widener/, "the excluded trick is named");
  assert.match(kind, /polarity-flipped duplicate/, "and the other one");
});

test("the kind schema names the RIGHT verb for the derived ripple, and disclaims the wrong one", async () => {
  // ⚠️ `channelPeakDb`/`channelNotchDb` are produced by
  // `Commands.effectParamsJSON`, which feeds the `effects[].params` object of
  // `fx.add` / `fx.setParam` / `project.snapshot`. `fx.describe` returns
  // something else entirely — per-KIND schemas with no instance and no values —
  // so an agent told to "call fx_describe for channelPeakDb" gets a
  // valid-looking response with the key absent and concludes the feature does
  // not exist. This is the m39-n finding, applied before it could recur.
  const kind = await describeParam("fx_add", "kind");
  assert.match(kind, /channelPeakDb/, "the derived readout is named");
  assert.match(kind, /channelNotchDb/);
  assert.match(kind, /fx_add and fx_set_param RESULT/, "the verbs that DO carry it are named");
  assert.match(kind, /project_snapshot/, "and the poll path too");
  assert.match(kind, /NOT in fx_describe/, "and the one that does NOT is called out");
  assert.match(kind, /20\*log10\(1 \+ spread\)/, "the arithmetic is given, not hand-waved");
  assert.match(kind, /\+2\.3 \/ -3\.1 dB/, "and the default is quantified");
});

test("the kind schema is HONEST about the three things that surprise a widener user", async () => {
  const kind = await describeParam("fx_add", "kind");
  // (a) spread is not free, and the cost cancels in mono rather than vanishing.
  assert.match(kind, /CANCEL EXACTLY in the mono sum/);
  assert.match(kind, /theorem, not a limitation/,
    "the trade is arithmetic and must be presented as such");
  // (b) a frequency control that is inert until its amount is raised.
  assert.match(kind, /does NOTHING while `bassMonoAmount` is 0/);
  // (c) there is no mix, so an agent must not try to set one.
  assert.match(kind, /THERE IS NO `mix` PARAMETER/);
  assert.match(kind, /NEUTRAL position is `width: 1`/,
    "and the equivalent neutral position is given, spelled out");
  // (d) the audibility warning the user needs BEFORE they listen.
  assert.match(kind, /AUDIBILITY WARNING/);
  assert.match(kind, /headphones or two/, "with the actionable instruction");
});

test("fx_describe's own tool description carries the stereoWidth gloss too", async () => {
  // `fxKindSchema` is SHARED by fx_add and fx_describe, but fx_describe also
  // has its own per-kind gloss in its tool description, and a kind can reach
  // one and miss the other.
  const { tools } = await client.listTools();
  const describe = tools.find((t) => t.name === "fx_describe");
  assert.ok(describe, "fx_describe must be registered");
  const text = describe.description ?? "";
  assert.match(text, /stereoWidth/, "the kind is glossed in fx_describe's own description");
  assert.match(text, /MID\/SIDE WIDENER/);
  assert.match(text, /NO\s+`mix` on this kind/);
});
