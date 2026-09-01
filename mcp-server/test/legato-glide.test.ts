/**
 * legato-glide.test.ts — m34-t's MCP surface: the third `voiceMode` case
 * `legato` and the new `glideTime` global, both on `track_set_instrument`'s
 * nested `sampler` object and as a thirteenth `instrument_set_sampler_param`.
 *
 * The `pedal-hold-limit.test.ts` stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tools over an in-memory transport, and assert what reaches the wire — never
 * what the tool "should" have sent.
 *
 * ⚠️ WHERE EACH GUARD LIVES, because the two boundaries refuse DIFFERENT things:
 *   - `track_set_instrument` types `voiceMode` as a zod ENUM and `glideTime` as
 *     `.min(0).max(4)`, so an unknown mode or an out-of-range glide dies at the
 *     SCHEMA and never reaches the bridge (asserted with `calls.length === 0`).
 *   - `instrument_set_sampler_param`'s `value` is the deliberately wide
 *     `number | boolean | string` union shared by all thirteen params, so the
 *     RANGE is enforced app-side by `Commands.swift`. The tests below therefore
 *     assert an out-of-range value REACHES the bridge intact (that IS the
 *     contract); the refusal is pinned in Swift by
 *     `Tests/DAWControlTests/LegatoGlideWireTests.swift`. Claiming a schema
 *     refusal here would be a green test for a guard that does not exist.
 *
 * ⭐ AND ONE DESCRIPTION TEST THAT IS NOT DECORATION. The wire reference and
 * this tool's own prose have BOTH previously over-claimed what mono does —
 * "the sampler can now really slur" was written about mono PRIORITY, which
 * still re-attacks. The assertions at the bottom pin the distinction in the
 * text an agent actually reads.
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

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  return queuedResult;
};

const { server } = await import("../src/server.js");

let client: Client;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let tools: any[];

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "legato-glide-test-client", version: "0.0.0" });
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
});

// ---------------------------------------------------------------------------
// track_set_instrument — the new voice mode
// ---------------------------------------------------------------------------

test("track_set_instrument forwards voiceMode 'legato' through the strict nested schema", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler", sampler: { voiceMode: "legato" } };

  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "sampler", sampler: { voiceMode: "legato" } },
  })) as any;

  assert.ok(!result.isError, `legato must be accepted: ${JSON.stringify(result)}`);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
  assert.deepEqual(calls[0]!.params["sampler"], { voiceMode: "legato" });
});

test("an unknown voiceMode dies at the SCHEMA and never reaches the bridge", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "sampler", sampler: { voiceMode: "portamento" } },
  })) as any;

  assert.ok(result.isError, "an unrecognised voice mode must be refused at the schema");
  assert.equal(calls.length, 0, "a schema-refused call must not reach the app");
});

test("the older two modes still pass — legato is ADDITIVE, not a replacement", async () => {
  const trackId = randomUUID();
  for (const mode of ["poly", "mono", "legato"]) {
    calls = [];
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, kind: "sampler", sampler: { voiceMode: mode } },
    })) as any;
    assert.ok(!result.isError, `${mode} must still be accepted: ${JSON.stringify(result)}`);
    assert.equal((calls[0]!.params["sampler"] as any)["voiceMode"], mode);
  }
});

// ---------------------------------------------------------------------------
// track_set_instrument — glideTime
// ---------------------------------------------------------------------------

test("track_set_instrument forwards sampler.glideTime through the strict nested schema", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler", sampler: { glideTime: 0.35 } };

  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: {
      trackId,
      kind: "sampler",
      sampler: { voiceMode: "legato", glideTime: 0.35 },
    },
  })) as any;

  assert.ok(!result.isError, `a legitimate glide must be accepted: ${JSON.stringify(result)}`);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params["sampler"], { voiceMode: "legato", glideTime: 0.35 });
});

test("an omitted glideTime forwards as undefined — never a fabricated 0", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler" };

  await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "sampler", sampler: { release: 0.4 } },
  });

  assert.equal(calls.length, 1);
  const sampler = calls[0]!.params["sampler"] as Record<string, unknown>;
  assert.equal(sampler["glideTime"], undefined);
  assert.ok(
    !Object.prototype.hasOwnProperty.call(sampler, "glideTime"),
    "the key must not appear at all — a sampler with no glide keeps its pre-m34-t wire shape"
  );
});

test("an out-of-range glideTime dies at the SCHEMA; the boundaries 0 and 4 do not", async () => {
  const trackId = randomUUID();
  for (const bad of [-0.1, 4.1, 30]) {
    calls = [];
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, kind: "sampler", sampler: { glideTime: bad } },
    })) as any;
    assert.ok(result.isError, `glideTime ${bad} must be refused, not clamped`);
    assert.equal(calls.length, 0, `glideTime ${bad} must not reach the app`);
  }
  // The positive control: a refusal test that rejected everything would pass
  // while the field was unusable.
  for (const good of [0, 4]) {
    calls = [];
    const result = (await client.callTool({
      name: "track_set_instrument",
      arguments: { trackId, kind: "sampler", sampler: { glideTime: good } },
    })) as any;
    assert.ok(!result.isError, `glideTime ${good} is in range: ${JSON.stringify(result)}`);
    assert.equal((calls[0]!.params["sampler"] as any)["glideTime"], good);
  }
});

// ---------------------------------------------------------------------------
// instrument_set_sampler_param — the narrower single-global tool
// ---------------------------------------------------------------------------

test("instrument_set_sampler_param forwards glideTime as a one-key sampler patch", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler", sampler: { glideTime: 0.2 } };

  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "glideTime", value: 0.2 },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
  assert.deepEqual(calls[0]!.params["sampler"], { glideTime: 0.2 });
});

test("instrument_set_sampler_param forwards voiceMode 'legato' as a string", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler", sampler: { voiceMode: "legato" } };

  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "voiceMode", value: "legato" },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result));
  assert.deepEqual(calls[0]!.params["sampler"], { voiceMode: "legato" });
});

test("an out-of-range glideTime REACHES the bridge here — the range is enforced app-side", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler" };

  await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "glideTime", value: 30 },
  });

  assert.equal(calls.length, 1, "the wide value union must forward it for the app to refuse");
  assert.deepEqual(calls[0]!.params["sampler"], { glideTime: 30 });
});

test("a STRING for glideTime is re-narrowed at this boundary, and the message names legato", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "glideTime", value: "fast" },
  })) as any;

  assert.ok(result.isError, "only voiceMode takes a string");
  assert.equal(calls.length, 0);
  const text = (result.content?.[0]?.text ?? "") as string;
  assert.match(text, /does not take a string/);
  assert.match(text, /legato/, `the narrowing message must list all three modes: ${text}`);
});

// ---------------------------------------------------------------------------
// The descriptions ARE the contract
// ---------------------------------------------------------------------------

test("the schema TEACHES the mono-vs-legato difference rather than calling both a slur", () => {
  const setInstrument = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(setInstrument);
  const voiceMode = ((setInstrument.inputSchema as any).properties?.sampler?.properties?.voiceMode
    ?.description ?? "") as string;

  // The distinction, in the text an agent actually reads. `mono` RE-ATTACKS;
  // `legato` CONTINUES. Calling both "a slur" is the over-claim this item was
  // filed to correct, and the wire reference has already made it once.
  assert.match(voiceMode, /legato/i, "the new mode must be described, not merely enumerated");
  assert.match(voiceMode, /RE-ATTACK|re-attack|fresh attack/i);
  assert.match(voiceMode, /CONTINUES|continues/i);
  assert.match(
    voiceMode,
    /no second attack|without.{0,20}attack|no.{0,10}re-tongue|not re-tongue/i,
    `the description must say legato does NOT re-attack: ${voiceMode}`
  );
  // …and the accepted limit is stated rather than discovered by ear.
  assert.match(voiceMode, /zone|sample/i);
});

test("the glideTime description states the poly restriction and the log-domain slide", () => {
  const setInstrument = tools.find((t) => t.name === "track_set_instrument");
  const glide = ((setInstrument.inputSchema as any).properties?.sampler?.properties?.glideTime
    ?.description ?? "") as string;
  assert.ok(glide.length > 0, "glideTime must be described, not merely typed");

  // The single most useful fact: it does nothing under poly. An agent that sets
  // it on a poly sampler gets silence and no error, which is precisely the
  // failure shape this tree keeps paying for.
  assert.match(glide, /IGNORED|ignored/, `must say it is ignored under poly: ${glide}`);
  assert.match(glide, /poly/);
  assert.match(glide, /glideEffective/, "must point at the read-back that reveals it");
  // And the two engine facts a caller cannot infer.
  assert.match(glide, /semitone/i, "the slide is even in semitones, not in Hz");
  assert.match(glide, /bend/i, "pitch bend composes on top");
});

test("instrument_describe_sampler advertises glideTime AND glideEffective", () => {
  const describe = tools.find((t) => t.name === "instrument_describe_sampler");
  assert.ok(describe);
  const text = (describe.description ?? "") as string;
  assert.match(text, /glideTime\?/, "the only-when-set global must be listed in the return shape");
  assert.match(text, /glideEffective/, "the derived boolean must be advertised too");
});
