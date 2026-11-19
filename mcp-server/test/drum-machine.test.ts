/**
 * drum-machine.test.ts — MCP coverage for m39-dm's MCP mirror: the four new
 * tools (`instrument_set_drum_param`, `instrument_describe_drum_kit`,
 * `instrument_list_drum_presets`, `instrument_load_drum_preset`) plus the
 * `drumSynth` kind / `drumKit` object added to `track_set_instrument`'s
 * existing schema.
 *
 * Ground truth for every name/range/unit/curve/default is
 * `DrumKitParams.paramSpecs` (Sources/DAWCore/DrumKit.swift); this suite does
 * NOT re-derive that table — it asserts what the MCP SCHEMA LAYER does
 * (forwarding shape, strict-schema rejection, the `chokeGroup`
 * null-vs-omitted distinction) and that the teaching text is present, the
 * `poly-synth-richness.test.ts` / `nested-strict-gap.test.ts` stub-bridge
 * pattern verbatim: monkeypatch `DawBridge.prototype.send` before importing
 * the real `McpServer`, drive the tools over an in-memory transport, and
 * assert what reaches the wire — never what the tool "should" have sent.
 *
 * ⚠️ CLAMP VS REFUSE: unlike the m39-g polySynth richness knobs (REFUSED
 * out-of-range), every drumKit leaf value CLAMPS on the wire
 * (`DrumKitParams.setValue`), so this schema carries no `.min()`/`.max()` on
 * those fields — there is nothing to assert-rejected there. The one thing
 * refused at the schema layer is a non-finite `value`
 * (`instrument_set_drum_param`) or a bad key shape (`.strict()` on both the
 * top-level `drumKit` object and each of its eight nested voice objects —
 * the m30-c nested-strict-gap class).
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
  client = new Client({ name: "drum-machine-test-client", version: "0.0.0" });
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
// instrument_set_drum_param
// ---------------------------------------------------------------------------

test("instrument_set_drum_param forwards {trackId, name, value} verbatim to instrument.setDrumParam", async () => {
  const trackId = randomUUID();
  queuedResult = {
    trackId,
    name: "kick.decay",
    value: 0.9,
    requested: 0.9,
    kind: "drumSynth",
    isActiveInstrument: true,
  };

  const result = (await client.callTool({
    name: "instrument_set_drum_param",
    arguments: { trackId, name: "kick.decay", value: 0.9 },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.setDrumParam");
  assert.deepEqual(calls[0]!.params, { trackId, name: "kick.decay", value: 0.9 });
});

test("instrument_set_drum_param requires trackId, name, and value — missing any one is rejected at the schema layer", async () => {
  const trackId = randomUUID();
  for (const args of [
    { name: "kick.decay", value: 0.9 },
    { trackId, value: 0.9 },
    { trackId, name: "kick.decay" },
  ]) {
    const result = (await client.callTool({ name: "instrument_set_drum_param", arguments: args })) as any;
    assert.ok(result.isError, `${JSON.stringify(args)} must be rejected`);
  }
  assert.equal(calls.length, 0, "a schema rejection never reaches the bridge");
});

test("instrument_set_drum_param rejects an unrecognized key (e.g. trackID typo) at the MCP boundary", async () => {
  const result = (await client.callTool({
    name: "instrument_set_drum_param",
    arguments: { trackId: randomUUID(), name: "kick.decay", value: 0.9, trackID: "oops" },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("instrument_set_drum_param's value must be finite: NaN and Infinity are refused at the schema layer", async () => {
  const trackId = randomUUID();
  for (const bad of [NaN, Infinity, -Infinity]) {
    const result = (await client.callTool({
      name: "instrument_set_drum_param",
      arguments: { trackId, name: "kick.decay", value: bad },
    })) as any;
    assert.ok(result.isError, `value=${bad} must be refused`);
  }
  assert.equal(calls.length, 0, "schema rejections never reach the bridge");

  // Control: an ordinary (even wildly out-of-range) finite number IS
  // forwarded — clamping happens app-side, not here.
  queuedResult = { trackId, name: "kick.decay", value: 3.0, requested: 999, kind: "drumSynth" };
  const ok = (await client.callTool({
    name: "instrument_set_drum_param",
    arguments: { trackId, name: "kick.decay", value: 999 },
  })) as any;
  assert.ok(!ok.isError, JSON.stringify(ok));
  assert.equal(calls[0]!.params["value"], 999, "an out-of-range but FINITE value is forwarded, not refused here");
});

test("instrument_set_drum_param's description states the clamp-vs-refuse split, the chokeGroup exclusion, and one-shot latching", () => {
  const tool = tools.find((t) => t.name === "instrument_set_drum_param");
  assert.ok(tool, "instrument_set_drum_param is registered");
  const description = (tool.description ?? "") as string;
  assert.match(description, /CLAMPED/);
  assert.match(description, /requested/);
  assert.match(description, /non-finite/i);
  assert.match(description, /chokeGroup.*NOT reachable/is);
  assert.match(description, /`level`.*`pan`/s);
});

// ---------------------------------------------------------------------------
// instrument_describe_drum_kit
// ---------------------------------------------------------------------------

test("instrument_describe_drum_kit forwards {trackId} to instrument.describeDrumKit", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "drumSynth", isActiveInstrument: true, parameterCount: 77 };

  const result = (await client.callTool({
    name: "instrument_describe_drum_kit",
    arguments: { trackId },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.describeDrumKit");
  assert.deepEqual(calls[0]!.params, { trackId });
});

test("instrument_describe_drum_kit's strict schema rejects an unknown key — it takes only trackId", async () => {
  const result = (await client.callTool({
    name: "instrument_describe_drum_kit",
    arguments: { trackId: randomUUID(), offset: 0 },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("instrument_describe_drum_kit's description teaches the 77/64 route budget, appliesAtNextNoteOn, and the level/pan exception", () => {
  const tool = tools.find((t) => t.name === "instrument_describe_drum_kit");
  assert.ok(tool);
  const description = (tool.description ?? "") as string;
  assert.match(description, /77/);
  assert.match(description, /64/);
  assert.match(description, /appliesAtNextNoteOn/);
  assert.match(description, /`level`\/`pan`/);
  assert.match(description, /warnings/);
});

// ---------------------------------------------------------------------------
// instrument_list_drum_presets
// ---------------------------------------------------------------------------

test("instrument_list_drum_presets takes no params and forwards to instrument.listDrumPresets with no arguments", async () => {
  queuedResult = { presets: [{ name: "808", summary: "The long boom." }], count: 5 };

  const result = (await client.callTool({ name: "instrument_list_drum_presets", arguments: {} })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.listDrumPresets");
});

test("instrument_list_drum_presets's description names all five presets and states there is no discrete/character parameter", () => {
  const tool = tools.find((t) => t.name === "instrument_list_drum_presets");
  assert.ok(tool, "instrument_list_drum_presets is registered");
  const description = (tool.description ?? "") as string;
  for (const name of ["808", "909", "acoustic", "lofi", "trap"]) {
    assert.match(description, new RegExp(`\`${name}\``), `names the ${name} preset`);
  }
  assert.match(description, /no `character` enum/i);
});

// ---------------------------------------------------------------------------
// instrument_load_drum_preset
// ---------------------------------------------------------------------------

test("instrument_load_drum_preset forwards {trackId, name} to instrument.loadDrumPreset", async () => {
  const trackId = randomUUID();
  queuedResult = {
    trackId,
    name: "trap",
    summary: "A very long sub kick.",
    replacedAllParameters: true,
    parameterCount: 77,
    kind: "drumSynth",
    isActiveInstrument: true,
  };

  const result = (await client.callTool({
    name: "instrument_load_drum_preset",
    arguments: { trackId, name: "trap" },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.loadDrumPreset");
  assert.deepEqual(calls[0]!.params, { trackId, name: "trap" });
});

test("instrument_load_drum_preset requires trackId and name — missing either is rejected at the schema layer", async () => {
  const trackId = randomUUID();
  for (const args of [{ name: "trap" }, { trackId }]) {
    const result = (await client.callTool({ name: "instrument_load_drum_preset", arguments: args })) as any;
    assert.ok(result.isError, `${JSON.stringify(args)} must be rejected`);
  }
  assert.equal(calls.length, 0);
});

test("instrument_load_drum_preset's description states WHOLESALE replacement, not an overlay", () => {
  const tool = tools.find((t) => t.name === "instrument_load_drum_preset");
  assert.ok(tool);
  const description = (tool.description ?? "") as string;
  assert.match(description, /WHOLESALE/);
  assert.match(description, /replacedAllParameters/);
  assert.match(description, /no `character` enum/i);
});

// ---------------------------------------------------------------------------
// track_set_instrument — the `drumSynth` kind and `drumKit` object
// ---------------------------------------------------------------------------

test("track_set_instrument accepts kind: drumSynth and refuses an unrecognized kind (e.g. drumMachine)", async () => {
  const trackId = randomUUID();
  const bad = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "drumMachine" },
  })) as any;
  assert.ok(bad.isError, "an unrecognized kind must be refused at the schema layer");
  assert.equal(calls.length, 0);

  queuedResult = { trackId, kind: "drumSynth" };
  const ok = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "drumSynth" },
  })) as any;
  assert.ok(!ok.isError, JSON.stringify(ok));
  assert.equal(calls[0]!.params["kind"], "drumSynth");
});

test("track_set_instrument forwards a partial drumKit overlay deep-equal, under the drumKit key", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "drumSynth" };

  const drumKit = {
    kick: { decay: 0.9, tune: 48 },
    closedHat: { chokeGroup: 3 },
    gain: 1.2,
    accentDepth: 0.4,
  };

  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, drumKit },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
  assert.deepEqual(calls[0]!.params["drumKit"], drumKit);
});

test("drumKit's kit-wide leaves (gain, velocityToTone, accentThreshold, accentDepth) are TOP-LEVEL keys, not nested under a kit object", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "drumSynth" };

  // The wrong shape a caller might copy from instrument_describe_drum_kit's
  // response (which DOES group these under a `kit` key) must be refused.
  const wrongShape = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, drumKit: { kit: { gain: 1.2 } } },
  })) as any;
  assert.ok(wrongShape.isError, "a nested `kit` object is not the write shape and must be refused");
  assert.equal(calls.length, 0);

  // The correct, top-level shape is accepted.
  const right = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, drumKit: { gain: 1.2 } },
  })) as any;
  assert.ok(!right.isError, JSON.stringify(right));
  assert.equal((calls[0]!.params["drumKit"] as any).gain, 1.2);
});

test("drumKit rejects a typo'd leaf name inside a voice object (nested .strict(), never reaches the bridge)", async () => {
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId: randomUUID(), drumKit: { kick: { decy: 0.5 } } },
  })) as any;
  assert.ok(result.isError, "a typo'd leaf name inside `kick` must be rejected");
  assert.equal(calls.length, 0, "a nested-strict rejection never reaches the bridge");
});

test("drumKit rejects an unrecognized top-level voice/leaf name (e.g. a typo'd voice)", async () => {
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId: randomUUID(), drumKit: { kik: { tune: 50 } } },
  })) as any;
  assert.ok(result.isError, "a typo'd voice name must be rejected");
  assert.equal(calls.length, 0);
});

test("drumKit rejects a leaf name that exists on a DIFFERENT voice's spec (e.g. kick.band, rim.spread do not exist)", async () => {
  for (const bad of [
    { kick: { band: 3000 } }, // band only exists on cymbal
    { rim: { spread: 0.01 } }, // spread only exists on clap
  ]) {
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId: randomUUID(), drumKit: bad },
    })) as any;
    assert.ok(result.isError, `${JSON.stringify(bad)} must be rejected — that leaf does not exist on that voice`);
  }
  assert.equal(calls.length, 0);
});

test("drumKit's chokeGroup: null forwards as literal null (clears); an omitted chokeGroup is genuinely ABSENT, not defaulted", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "drumSynth" };

  await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, drumKit: { closedHat: { chokeGroup: null } } },
  });
  assert.equal(calls.length, 1);
  const closedHatCleared = (calls[0]!.params["drumKit"] as any).closedHat;
  assert.equal(closedHatCleared.chokeGroup, null, "an explicit null must forward as null, not be dropped");

  calls = [];
  queuedResult = { trackId, kind: "drumSynth" };
  await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, drumKit: { closedHat: { tune: 1.5 } } },
  });
  assert.equal(calls.length, 1);
  const closedHatUntouched = (calls[0]!.params["drumKit"] as any).closedHat;
  assert.equal(
    "chokeGroup" in closedHatUntouched,
    false,
    "an omitted chokeGroup must be genuinely absent from the forwarded object, never defaulted to null or 0"
  );
});

test("drumKit's chokeGroup is refused as non-integer/out of the 0-63 domain's TYPE (a string), but the range itself clamps app-side", async () => {
  const badType = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId: randomUUID(), drumKit: { closedHat: { chokeGroup: "zero" } } },
  })) as any;
  assert.ok(badType.isError, "a string chokeGroup must be refused at the schema layer");
  assert.equal(calls.length, 0);

  const fractional = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId: randomUUID(), drumKit: { closedHat: { chokeGroup: 2.5 } } },
  })) as any;
  assert.ok(fractional.isError, "a fractional chokeGroup must be refused — it is typed .int()");
  assert.equal(calls.length, 0);
});

test("drumKit's note field is accepted (ignored on input) so a describe/loadPreset response can be fed straight back in", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "drumSynth" };

  // Shape mirrors what instrument_describe_drum_kit / instrument_load_drum_preset
  // echo back per voice: leaf values plus `note` (and `chokeGroup` when set).
  const roundTrip = {
    kick: { tune: 52, decay: 0.62, tone: 0.5, snap: 0.18, drive: 0.12, level: 0.9, pan: 0, velocity: 0.55, pitchAmount: 3.2, pitchDecay: 0.045, note: 36 },
    closedHat: { tune: 1, decay: 0.05, tone: 0.5, snap: 0.5, drive: 0, level: 0.7, pan: 0.1, velocity: 0.75, chokeGroup: 0, note: 38 },
  };

  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, drumKit: roundTrip },
  })) as any;
  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
});

test("track_set_instrument's kind description and main description mention drumSynth/drumKit", () => {
  const tool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(tool);
  const properties = (tool.inputSchema as any).properties ?? {};
  const kindDescription = (properties.kind?.description ?? "") as string;
  assert.match(kindDescription, /drumSynth/);
  const mainDescription = (tool.description ?? "") as string;
  assert.match(mainDescription, /drumKit/);
  assert.match(mainDescription, /WHOLESALE instrument config/);
});

// ---------------------------------------------------------------------------
// The schema IS the contract — JSON schema shape checks, not just behavior
// ---------------------------------------------------------------------------

test("track_set_instrument's drumKit schema exposes all eight voices and the six kit-wide leaves", () => {
  const tool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(tool);
  const drumKitProps = (tool.inputSchema as any).properties?.drumKit?.properties ?? {};
  for (const voice of ["kick", "snare", "closedHat", "openHat", "clap", "tom", "rim", "cymbal"]) {
    assert.ok(drumKitProps[voice], `drumKit exposes ${voice}`);
  }
  for (const kitLeaf of ["gain", "velocityToTone", "accentThreshold", "accentDepth", "hatsLevelDb", "cymbalsLevelDb"]) {
    assert.ok(drumKitProps[kitLeaf], `drumKit exposes top-level ${kitLeaf}`);
  }
  assert.ok(!drumKitProps["kit"], "there must be no nested `kit` sub-object on the write side");
});

test("drumKit's hatsLevelDb and cymbalsLevelDb are in the schema with their real ranges, unit and default", () => {
  const tool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(tool);
  const props = (tool.inputSchema as any).properties?.drumKit?.properties ?? {};
  const hats = props["hatsLevelDb"];
  const cymbals = props["cymbalsLevelDb"];
  assert.ok(hats, "drumKit exposes hatsLevelDb");
  assert.ok(cymbals, "drumKit exposes cymbalsLevelDb");
  assert.equal(hats.type, "number");
  assert.equal(cymbals.type, "number");
  // The range lives in the description (every drumKit value clamps app-side, so no JSON-schema min/max).
  assert.match(hats.description, /-24 to \+36/);
  assert.match(cymbals.description, /-24 to \+24/);
  // W9-DRUMDEF (the user's 2026-10-07 picks): the default is what a NEW drum machine starts at —
  // hats +23.4, cymbals +5.7 (`DrumKitParams.newKitHatsLevelDb`/`newKitCymbalsLevelDb`) — and
  // 0 survives as how a song saved before then still plays.
  assert.match(hats.description, /default 23\.4\b/);
  assert.match(cymbals.description, /default 5\.7\b/);
  for (const d of [hats.description, cymbals.description]) {
    assert.match(d, /dB/);
    assert.doesNotMatch(d, /default 0\b/);
    assert.match(d, /NEW drum machine/);
    assert.match(d, /saved/);
    assert.match(d, /next note-on/);
  }
  assert.equal(hats.minimum, undefined);
  assert.equal(hats.maximum, undefined);
  assert.equal(cymbals.minimum, undefined);
  assert.equal(cymbals.maximum, undefined);
  // The wire-side counts and names the descriptions teach.
  const main = ((tool.inputSchema as any).properties?.drumKit?.description ?? "") as string;
  assert.match(main, /SIX kit-wide leaves/);
  assert.match(main, /71 \+ 6 = the full 77/);
  const setParam = tools.find((t) => t.name === "instrument_set_drum_param");
  assert.ok(setParam);
  assert.match((setParam.description ?? "") as string, /kit\.hatsLevelDb/);
  assert.match((setParam.description ?? "") as string, /kit\.cymbalsLevelDb/);
  assert.doesNotMatch(main, /\b75\b/);
});

test("no drumKit leaf field carries a JSON-schema minimum/maximum — every value clamps app-side, never refused by range", () => {
  const tool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(tool);
  const kickProps = (tool.inputSchema as any).properties?.drumKit?.properties?.kick?.properties ?? {};
  assert.ok(kickProps["tune"], "sanity: kick.tune exists");
  for (const [name, schema] of Object.entries(kickProps) as [string, any][]) {
    if (name === "chokeGroup") continue; // structural, not a spec-table leaf; not addressed by this claim
    assert.equal(schema.minimum, undefined, `kick.${name} must carry no JSON-schema minimum`);
    assert.equal(schema.maximum, undefined, `kick.${name} must carry no JSON-schema maximum`);
  }
});

// ---------------------------------------------------------------------------
// `drumKit` does NOT imply `kind: drumSynth` — unlike `audioUnit`/`soundBank`,
// which genuinely do (ProjectStore.setInstrument's `kind ?? (audioUnit != nil
// ? .audioUnit : soundBank != nil ? .soundBank : current.kind)` never
// consults `drumKit`/`drumParam` at all; `drumKit` rides the same
// no-implication rule as `sampler`). A caller who sends only `drumKit` (or
// calls `instrument_load_drum_preset`) gets a stored-but-silent kit on a
// track whose kind is something else. This regression-pins the corrected
// wording after a review caught the schema teaching the OPPOSITE (false)
// claim in three places.
// ---------------------------------------------------------------------------

test("track_set_instrument's drumKit schema description does NOT claim drumKit implies kind: drumSynth", () => {
  const tool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(tool);
  const drumKitDescription = ((tool.inputSchema as any).properties?.drumKit?.description ?? "") as string;
  assert.doesNotMatch(drumKitDescription, /drumKit`?\s+implies\s+`?kind/i);
  assert.match(drumKitDescription, /does NOT imply/i);
  assert.match(drumKitDescription, /kind: "drumSynth"/);
});

test("track_set_instrument's main description does NOT claim drumKit implies kind, unlike its correct claim for audioUnit/soundBank", () => {
  const tool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(tool);
  const mainDescription = (tool.description ?? "") as string;
  // audioUnit/soundBank genuinely DO imply kind — that claim must survive.
  assert.match(mainDescription, /`audioUnit`[\s\S]{0,80}implies that kind/);
  assert.match(mainDescription, /`soundBank`[\s\S]{0,120}implies\s*\n?\s*"?\s*that kind/);
  // drumKit must NOT carry the same claim.
  assert.doesNotMatch(mainDescription, /`drumKit`[\s\S]{0,200}implies that kind/);
  assert.match(mainDescription, /UNLIKE `audioUnit`\/`soundBank`, it does NOT imply/);
});

test("instrument_load_drum_preset's description does NOT claim the preset load sets kind to drumSynth", () => {
  const tool = tools.find((t) => t.name === "instrument_load_drum_preset");
  assert.ok(tool);
  const description = (tool.description ?? "") as string;
  assert.doesNotMatch(description, /setting `?kind`? to `?drumSynth`?/i);
  assert.match(description, /DOES NOT\s*\n?\s*CHANGE `kind`/);
  assert.match(description, /isActiveInstrument/);
});

test("instrument_load_drum_preset forwards no kind param — the wire verb never receives one", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, name: "trap", kind: "polySynth", isActiveInstrument: false };
  const result = (await client.callTool({
    name: "instrument_load_drum_preset",
    arguments: { trackId, name: "trap" },
  })) as any;
  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, name: "trap" });
  assert.ok(!("kind" in calls[0]!.params), "loadDrumPreset must not smuggle a kind onto the wire");
});

// ---------------------------------------------------------------------------
// TPL-0 (m39-tpl-0): drumKit.noteLayout — which MIDI notes play which drum.
// A structural, additive key on the nested `.strict()` drumKit object (the
// m30-c law: a typo'd key is refused here and never reaches the bridge).
// ---------------------------------------------------------------------------

test("drumKit.noteLayout forwards `gm` and `pads` verbatim under the drumKit key", async () => {
  for (const layout of ["gm", "pads"]) {
    calls = [];
    const trackId = randomUUID();
    queuedResult = { trackId, kind: "drumSynth" };
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, drumKit: { noteLayout: layout, kick: { decay: 0.9 } } },
    })) as any;
    assert.ok(!result.isError, JSON.stringify(result));
    assert.equal(calls.length, 1);
    assert.equal(calls[0]!.command, "track.setInstrument");
    assert.deepEqual(calls[0]!.params["drumKit"], { noteLayout: layout, kick: { decay: 0.9 } });
  }
});

test("drumKit.noteLayout refuses anything but `pads`/`gm` at the MCP boundary (never reaches the bridge)", async () => {
  for (const bad of ["GM", "general", "", 1, null, true]) {
    calls = [];
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId: randomUUID(), drumKit: { noteLayout: bad } },
    })) as any;
    assert.ok(result.isError, `noteLayout ${JSON.stringify(bad)} was accepted`);
    assert.equal(calls.length, 0, `noteLayout ${JSON.stringify(bad)} reached the bridge`);
  }
});

test("drumKit's strict schema refuses a typo'd noteLayout key (m30-c: nested .strict())", async () => {
  for (const typo of ["notelayout", "noteLayouts", "layout", "note_layout"]) {
    calls = [];
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId: randomUUID(), drumKit: { [typo]: "gm" } },
    })) as any;
    assert.ok(result.isError, `the typo ${typo} was accepted`);
    assert.equal(calls.length, 0, `the typo ${typo} reached the bridge`);
  }
});

test("drumKit's noteLayout schema is exactly the enum [pads, gm] and teaches voiceNotes", () => {
  const tool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(tool);
  const noteLayout = (tool.inputSchema as any).properties?.drumKit?.properties?.noteLayout;
  assert.ok(noteLayout, "drumKit exposes noteLayout");
  assert.deepEqual([...(noteLayout.enum ?? [])].sort(), ["gm", "pads"]);
  const description = (noteLayout.description ?? "") as string;
  assert.match(description, /voiceNotes/);
  assert.match(description, /WRONG DRUMS/);
  assert.match(description, /REFUSES/);
  assert.match(description, /KEEPS/);
});

test("the drum tools' descriptions carry the note-layout facts", () => {
  const describe = tools.find((t) => t.name === "instrument_describe_drum_kit");
  const setParam = tools.find((t) => t.name === "instrument_set_drum_param");
  const loadPreset = tools.find((t) => t.name === "instrument_load_drum_preset");
  assert.ok(describe && setParam && loadPreset);
  const describeText = (describe.description ?? "") as string;
  assert.match(describeText, /voiceNotes/);
  assert.match(describeText, /silentGMNotes/);
  assert.match(describeText, /noteLayout/);
  assert.match(describeText, /READ `voiceNotes` BEFORE WRITING DRUM NOTES/);
  assert.match((setParam.description ?? "") as string, /noteLayout[\s\S]{0,200}REFUSED/);
  assert.match((loadPreset.description ?? "") as string, /KEEPS the kit's `noteLayout`/);
});

// W9-DRUMDEF (m39-hat-default + m39-dm-gm-default, the user's 2026-10-07 picks): a NEW drum
// machine starts on General MIDI notes with the hats at +23.4 dB and the cymbals at +5.7 dB.
// An agent that still believed "MIDI notes 36-43" would write every beat on the wrong drums.
test("a NEW drum machine's start (gm, +23.4, +5.7) is taught where an agent reads it", () => {
  const setInstrument = tools.find((t) => t.name === "track_set_instrument");
  const describe = tools.find((t) => t.name === "instrument_describe_drum_kit");
  const loadPreset = tools.find((t) => t.name === "instrument_load_drum_preset");
  assert.ok(setInstrument && describe && loadPreset);
  const props = (setInstrument.inputSchema as any).properties ?? {};
  const kindText = (props.kind?.description ?? "") as string;
  assert.match(kindText, /NEW one\s+plays General MIDI drum notes/);
  assert.match(kindText, /voiceNotes/);
  assert.doesNotMatch(kindText, /MIDI notes\s+36-43 —/, "the old fixed-pad-notes claim is back");
  const drumKit = props.drumKit ?? {};
  const main = (drumKit.description ?? "") as string;
  assert.match(main, /NEW drum machine[\s\S]{0,200}General MIDI notes[\s\S]{0,120}\+23\.4 dB[\s\S]{0,80}\+5\.7 dB/);
  assert.match(main, /saved\s+earlier keeps the kit it plays/);
  const layoutText = (drumKit.properties?.noteLayout?.description ?? "") as string;
  assert.match(layoutText, /`gm` \(what a NEW drum machine starts with\)/);
  assert.doesNotMatch(layoutText, /`pads` \(the default/, "pads is no longer the default");
  const describeText = (describe.description ?? "") as string;
  assert.match(describeText, /isConfigured[\s\S]{0,300}\+23\.4 dB[\s\S]{0,40}\+5\.7 dB/);
  const presetText = (loadPreset.description ?? "") as string;
  assert.match(presetText, /Every factory kit sets the hi-hats to \+23\.4 dB and the cymbals to \+5\.7 dB/);
});

// W9-HEAD (m39-dm-headroom): a NEW drum machine starts at kit gain 0.7 (headroom), so a plain beat on a
// new song stays under -1 dBTP, and every factory kit carries the same headroom (lofi and acoustic
// 0.63, a step below the others; acoustic's step is on the headroom alone, it played at 1.0 before); a drum
// machine in a song saved before keeps its own level. An agent told "default 1.0" would "restore" the
// default and put the clipping back.
test("a NEW drum machine's kit gain (0.7, headroom) is taught where an agent reads it", () => {
  const setInstrument = tools.find((t) => t.name === "track_set_instrument");
  const describe = tools.find((t) => t.name === "instrument_describe_drum_kit");
  const loadPreset = tools.find((t) => t.name === "instrument_load_drum_preset");
  assert.ok(setInstrument && describe && loadPreset);
  const drumKit = (setInstrument.inputSchema as any).properties?.drumKit ?? {};
  const gain = (drumKit.properties?.gain?.description ?? "") as string;
  assert.match(gain, /default 0\.7\b/);
  assert.doesNotMatch(gain, /default 1\.0\b/, "the old default is back");
  assert.match(gain, /NEW drum machine starts at 0\.7, and so does every factory kit/);
  assert.match(gain, /lofi and acoustic 0\.63/);
  assert.match(gain, /saved before then keeps its own\s+level/);
  assert.doesNotMatch(gain, /sets that kit's own gain/, "the option-A preset gain is back");
  const main = (drumKit.description ?? "") as string;
  assert.match(main, /NEW drum machine[\s\S]{0,500}`gain` at 0\.7/);
  const describeText = (describe.description ?? "") as string;
  assert.match(describeText, /isConfigured[\s\S]{0,400}kit gain 0\.7/);
  const presetText = (loadPreset.description ?? "") as string;
  assert.match(presetText, /sets the kit `gain` to 0\.7 \(lofi and acoustic 0\.63\)/);
  assert.match(presetText, /saved before then keeps its own level/);
  assert.doesNotMatch(presetText, /back to 0\.7|about 3 dB louder/, "the dropped preset-clipping advice is back");
});
