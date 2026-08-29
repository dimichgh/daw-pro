/**
 * sampler-describe-and-edit.test.ts — wiring coverage for the three m26-i
 * Sampler tools: `instrument_describe_sampler` (read-only, mirrors
 * `au_describe_params`), `instrument_set_sampler_param` (set ONE global,
 * wraps `track.setInstrument {sampler:{<param>:value}}`), and
 * `instrument_set_sampler_zones` (merge zones by id, wraps
 * `track.setInstrument {sampler:{zonePatches:[...]}}`).
 *
 * The clip-get-notes.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive
 * every tool over an in-memory transport, and assert:
 *   - each tool forwards to the RIGHT wire command with the RIGHT shape
 *   - all three are registered via the STRICT-SCHEMA wrapper (unrecognized
 *     top-level keys ARE rejected, even though describe is read-only)
 *   - `instrument_set_sampler_zones`'s PER-ZONE schema is independently
 *     strict too — an unrecognized key INSIDE one zone patch element is
 *     rejected, not silently stripped (the exact hazard a bare `.optional()`
 *     nested object would reintroduce)
 *   - app-side teaching errors (e.g. "no sampler configured", "names no
 *     zone on this track") pass through verbatim
 *   - the descriptions teach the four load-bearing facts the brief names:
 *     zones replaces wholesale vs zonePatches merges, `zones: []` is the
 *     only clear, a foreign zone id is re-minted and reported in
 *     `remintedZoneIDs`, and `displayName` is a non-unique file stem while
 *     `sourcePath` disambiguates
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
  client = new Client({ name: "sampler-describe-and-edit-test-client", version: "0.0.0" });
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: any): any {
  const first = result.content[0];
  assert.ok(first && first.type === "text", `expected a text content item, got: ${JSON.stringify(result.content)}`);
  return JSON.parse(first.text as string);
}

// ---------------------------------------------------------------------------
// instrument_describe_sampler
// ---------------------------------------------------------------------------

test("instrument_describe_sampler forwards {trackId} bare, offset/limit undefined, and round-trips the response", async () => {
  const trackId = randomUUID();
  const stubbed = {
    trackId,
    kind: "sampler",
    oneShot: false,
    attack: 0.001,
    release: 0.05,
    gain: 0.8,
    zoneSummary: { count: 0, groupCount: 0, distinctSampleFiles: 0 },
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "instrument_describe_sampler", arguments: { trackId } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.describeSampler");
  assert.equal(calls[0]!.params["trackId"], trackId);
  assert.equal(calls[0]!.params["offset"], undefined, "an omitted param forwards as undefined, never a fabricated default");
  assert.equal(calls[0]!.params["limit"], undefined);

  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("instrument_describe_sampler forwards offset/limit explicitly when given", async () => {
  const trackId = randomUUID();
  queuedResult = { trackId, kind: "sampler", oneShot: false, attack: 0.001, release: 0.05, gain: 0.8, zoneSummary: { count: 5 } };

  await client.callTool({ name: "instrument_describe_sampler", arguments: { trackId, offset: 2, limit: 10 } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, offset: 2, limit: 10 });
});

test("instrument_describe_sampler requires trackId (rejected at the schema layer, zero bridge calls)", async () => {
  const result = (await client.callTool({ name: "instrument_describe_sampler", arguments: {} })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("instrument_describe_sampler bounds offset/limit at the schema layer", async () => {
  const trackId = randomUUID();

  const negativeOffset = (await client.callTool({
    name: "instrument_describe_sampler",
    arguments: { trackId, offset: -1 },
  })) as any;
  assert.ok(negativeOffset.isError);

  const zeroLimit = (await client.callTool({
    name: "instrument_describe_sampler",
    arguments: { trackId, limit: 0 },
  })) as any;
  assert.ok(zeroLimit.isError);

  const tooBigLimit = (await client.callTool({
    name: "instrument_describe_sampler",
    arguments: { trackId, limit: 5001 },
  })) as any;
  assert.ok(tooBigLimit.isError);

  assert.equal(calls.length, 0, "schema rejections never reach the bridge");
});

test("instrument_describe_sampler is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_describe_sampler",
    arguments: { trackId, bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("instrument_describe_sampler surfaces an app-side refusal (e.g. no sampler configured) verbatim", async () => {
  const trackId = randomUUID();
  queuedError = new Error(
    `track '${trackId}' has no sampler configured yet — import a library with ` +
      `instrument.importSampleLibrary, or build one by hand with track.setInstrument ` +
      `{kind: "sampler", sampler: {zones: [...]}}`
  );

  const result = (await client.callTool({ name: "instrument_describe_sampler", arguments: { trackId } })) as any;
  assert.ok(result.isError);
  assert.match(result.content[0].text as string, /has no sampler configured yet/);
});

// ---------------------------------------------------------------------------
// instrument_set_sampler_param
// ---------------------------------------------------------------------------

test("instrument_set_sampler_param forwards each param under its own sampler key, to track.setInstrument", async () => {
  const trackId = randomUUID();
  queuedResult = { kind: "sampler", sampler: { oneShot: true, attack: 0.001, release: 0.05, gain: 0.8, zones: [] } };

  await client.callTool({ name: "instrument_set_sampler_param", arguments: { trackId, param: "oneShot", value: true } });
  assert.equal(calls[0]!.command, "track.setInstrument");
  assert.deepEqual(calls[0]!.params, { trackId, sampler: { oneShot: true } });

  await client.callTool({ name: "instrument_set_sampler_param", arguments: { trackId, param: "attack", value: 0.2 } });
  assert.deepEqual(calls[1]!.params, { trackId, sampler: { attack: 0.2 } });

  await client.callTool({ name: "instrument_set_sampler_param", arguments: { trackId, param: "release", value: 1.5 } });
  assert.deepEqual(calls[2]!.params, { trackId, sampler: { release: 1.5 } });

  await client.callTool({ name: "instrument_set_sampler_param", arguments: { trackId, param: "gain", value: 0.4 } });
  assert.deepEqual(calls[3]!.params, { trackId, sampler: { gain: 0.4 } });

  assert.equal(calls.length, 4, "each call touches exactly one global, never the others");
});

test("instrument_set_sampler_param requires trackId, param, and value (schema layer, zero bridge calls)", async () => {
  const trackId = randomUUID();

  const missingParam = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, value: 0.5 },
  })) as any;
  assert.ok(missingParam.isError);

  const missingValue = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "gain" },
  })) as any;
  assert.ok(missingValue.isError);

  const missingTrack = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { param: "gain", value: 0.5 },
  })) as any;
  assert.ok(missingTrack.isError);

  assert.equal(calls.length, 0);
});

test("instrument_set_sampler_param rejects a param not in the enum (schema layer)", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "sustain", value: 0.5 },
  })) as any;
  assert.ok(result.isError, "sustain is a polySynth field, not a sampler global — not a valid param here");
  assert.equal(calls.length, 0);
});

test("instrument_set_sampler_param rejects a non-number/non-boolean value at the schema layer", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "gain", value: "loud" },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("instrument_set_sampler_param is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "gain", value: 0.5, bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("instrument_set_sampler_param surfaces an app-side error (e.g. non-instrument track) verbatim", async () => {
  const trackId = randomUUID();
  queuedError = new Error(
    "track kind 'audio' cannot host an instrument — only instrument tracks carry an " +
      "instrument (add one with track.add kind=instrument)"
  );
  const result = (await client.callTool({
    name: "instrument_set_sampler_param",
    arguments: { trackId, param: "gain", value: 0.5 },
  })) as any;
  assert.ok(result.isError);
  assert.match(result.content[0].text as string, /cannot host an instrument/);
});

// ---------------------------------------------------------------------------
// instrument_set_sampler_zones
// ---------------------------------------------------------------------------

test("instrument_set_sampler_zones forwards {trackId, sampler:{zonePatches}} to track.setInstrument", async () => {
  const trackId = randomUUID();
  const zoneId = randomUUID();
  queuedResult = { kind: "sampler", sampler: { zones: [{ id: zoneId, path: "/x.wav", rootPitch: 60, minPitch: 0, maxPitch: 127, gain: 0.5 }] } };

  await client.callTool({
    name: "instrument_set_sampler_zones",
    arguments: { trackId, zones: [{ id: zoneId, gain: 0.5, tuneCents: -1200 }] },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
  assert.deepEqual(calls[0]!.params, {
    trackId,
    sampler: { zonePatches: [{ id: zoneId, gain: 0.5, tuneCents: -1200 }] },
  });
});

test("instrument_set_sampler_zones forwards a patch that swaps the sample file and several fields at once", async () => {
  const trackId = randomUUID();
  const zoneId = randomUUID();
  queuedResult = { kind: "sampler", sampler: { zones: [] } };

  await client.callTool({
    name: "instrument_set_sampler_zones",
    arguments: {
      trackId,
      zones: [
        {
          id: zoneId,
          path: "/Library/Samples/new.wav",
          minPitch: 24,
          maxPitch: 96,
          group: 2,
          pan: -0.5,
          ampVelTrack: 0.5,
        },
      ],
    },
  });

  assert.deepEqual(calls[0]!.params, {
    trackId,
    sampler: {
      zonePatches: [
        {
          id: zoneId,
          path: "/Library/Samples/new.wav",
          minPitch: 24,
          maxPitch: 96,
          group: 2,
          pan: -0.5,
          ampVelTrack: 0.5,
        },
      ],
    },
  });
});

test("instrument_set_sampler_zones accepts {id, release}/{id, attack}/{id, oneShot} — the exact fields the describeSampler inert-global note (Defect A) tells a reader to patch here", async () => {
  const trackId = randomUUID();
  queuedResult = { kind: "sampler", sampler: { zones: [] } };

  for (const patch of [
    { id: randomUUID(), release: 1.25 },
    { id: randomUUID(), attack: 0.2 },
    { id: randomUUID(), oneShot: true },
  ]) {
    calls = [];
    const result = (await client.callTool({
      name: "instrument_set_sampler_zones",
      arguments: { trackId, zones: [patch] },
    })) as any;
    assert.ok(!result.isError, `patching ${JSON.stringify(patch)} must be accepted: ${JSON.stringify(result)}`);
    assert.deepEqual(calls[0]!.params, { trackId, sampler: { zonePatches: [patch] } });
  }
});

// M32's new per-zone fields. `samplerZoneSchema` is `.strict()` and
// `samplerZonePatchSchema` reuses its `.shape`, so a field missing from the
// schema is REJECTED at the MCP boundary and never reaches the app — the
// Swift side can be perfectly wired and an agent still cannot use it. Each
// case carries its own positive control (a typo of the same field), because
// "the call succeeded" only means something if a near-miss fails.
test("M32 per-zone fields pass the strict zone schema and forward verbatim; a typo of each is rejected", async () => {
  const trackId = randomUUID();

  for (const [field, value] of [["reverse", true], ["chokeGroup", 3]] as const) {
    const zoneId = randomUUID();
    queuedResult = { kind: "sampler", sampler: { zones: [] } };
    calls = [];
    const accepted = (await client.callTool({
      name: "instrument_set_sampler_zones",
      arguments: { trackId, zones: [{ id: zoneId, [field]: value }] },
    })) as any;
    assert.ok(!accepted.isError, `${field} must reach the app: ${JSON.stringify(accepted)}`);
    assert.deepEqual(calls[0]!.params, {
      trackId,
      sampler: { zonePatches: [{ id: zoneId, [field]: value }] },
    });

    // Positive control: the same value under a misspelling must be refused,
    // which is what proves the acceptance above was the schema knowing the
    // field rather than the schema accepting anything.
    calls = [];
    const typo = (await client.callTool({
      name: "instrument_set_sampler_zones",
      arguments: { trackId, zones: [{ id: zoneId, [`${field}X`]: value }] },
    })) as any;
    assert.ok(typo.isError, `a typo of ${field} must be rejected, not silently dropped`);
    assert.equal(calls.length, 0);
  }
});

test("instrument_set_sampler_zones requires trackId and zones (schema layer, zero bridge calls)", async () => {
  const trackId = randomUUID();

  const missingZones = (await client.callTool({
    name: "instrument_set_sampler_zones",
    arguments: { trackId },
  })) as any;
  assert.ok(missingZones.isError);

  const missingTrack = (await client.callTool({
    name: "instrument_set_sampler_zones",
    arguments: { zones: [{ id: randomUUID(), gain: 0.5 }] },
  })) as any;
  assert.ok(missingTrack.isError);

  assert.equal(calls.length, 0);
});

test("instrument_set_sampler_zones requires `id` on every zone patch element (schema layer)", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_set_sampler_zones",
    arguments: { trackId, zones: [{ gain: 0.5 }] },
  })) as any;
  assert.ok(result.isError, "a patch with no id is meaningless — nothing to merge into");
  assert.equal(calls.length, 0);
});

test("instrument_set_sampler_zones rejects a non-UUID `id` at the schema layer", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_set_sampler_zones",
    arguments: { trackId, zones: [{ id: "not-a-uuid", gain: 0.5 }] },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("instrument_set_sampler_zones's PER-ZONE schema is independently strict: an unrecognized key INSIDE one patch element is rejected, not silently dropped", async () => {
  const trackId = randomUUID();
  const zoneId = randomUUID();

  // The exact hazard the mutation test proves: without a `.strict()` on the
  // per-element schema, a typo'd field (`maxPtich`) would be silently
  // stripped by zod's default parse mode and the call would still succeed,
  // landing a patch with one fewer field than intended.
  const result = (await client.callTool({
    name: "instrument_set_sampler_zones",
    arguments: { trackId, zones: [{ id: zoneId, maxPtich: 90 }] },
  })) as any;
  assert.ok(result.isError, "an unrecognized key inside a zone patch must be rejected, not stripped");
  assert.equal(calls.length, 0, "the typo'd call must never reach the bridge");
});

test("instrument_set_sampler_zones is registered via the STRICT-SCHEMA wrapper: an unrecognized TOP-LEVEL argument IS rejected", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "instrument_set_sampler_zones",
    arguments: { trackId, zones: [{ id: randomUUID(), gain: 0.5 }], bogus: true },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});

test("instrument_set_sampler_zones surfaces an app-side teaching error (e.g. an id naming no zone on this track) verbatim", async () => {
  const trackId = randomUUID();
  const stranger = randomUUID();
  queuedError = new Error(
    `sampler.zonePatches[0].id "${stranger}" names no zone on this track. Ids are per-track: ` +
      "omit 'id' on every zone to author a new map or to copy one onto a DIFFERENT track, or " +
      "re-read the current ids from project.snapshot's instrument.sampler.zones[].id."
  );
  const result = (await client.callTool({
    name: "instrument_set_sampler_zones",
    arguments: { trackId, zones: [{ id: stranger, gain: 0.5 }] },
  })) as any;
  assert.ok(result.isError);
  assert.match(result.content[0].text as string, /names no zone on this track/);
});

// ---------------------------------------------------------------------------
// track_set_instrument's `sampler` object — DEFECT B (sax-team, 2026-08-20)
//
// `registerTool`'s wrapper (server.ts:94-135) only applies `.strict()` at the
// TOP level of a tool's own inputSchema. `samplerSchema` (nested one level
// down, under `sampler`) fell through that net: an unrecognized key inside it
// — concretely `zonePatches`, a REAL key one layer further down at the raw
// control-protocol level (`sampler.zonePatches`, m26-g) but never one this
// schema exposed — was silently STRIPPED by zod's default parse mode, and
// `track_set_instrument` reported success having changed nothing. Fixed by
// giving `samplerSchema`, `samplerZoneSchema` (the wholesale `zones[]` path),
// and `samplerCrossfadeSchema` their own `.strict()`, matching the
// `samplerZonePatchSchema` precedent a few hundred lines below.
// ---------------------------------------------------------------------------

test("track_set_instrument rejects sampler.zonePatches at the MCP schema layer (Defect B) — it used to be silently stripped and report success", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, sampler: { zonePatches: [{ id: randomUUID(), release: 1.25 }] } },
  })) as any;
  assert.equal(result?.isError, true, `expected an MCP tool error, got: ${JSON.stringify(result)}`);
  const text = result.content?.[0]?.text ?? "";
  assert.match(
    text,
    /unrecognized_keys/,
    `expected a zod "unrecognized_keys" schema-validation error (proving the handler never ran), got: ${text}`
  );
  assert.match(text, /zonePatches/, `expected the schema error to name the dropped key, got: ${text}`);
  assert.equal(calls.length, 0, "the call must never reach the bridge — this is what made it a SILENT no-op before the fix");
});

test("track_set_instrument rejects an unrecognized key inside one element of the wholesale sampler.zones[] array", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "sampler", sampler: { zones: [{ path: "/x.wav", minPtich: 90 }] } },
  })) as any;
  assert.ok(result.isError, "a typo'd zone field must be rejected, not silently stripped");
  assert.match(result.content?.[0]?.text ?? "", /unrecognized_keys/);
  assert.equal(calls.length, 0);
});

test("track_set_instrument rejects an unrecognized key inside sampler.zones[].crossfade", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: {
      trackId,
      kind: "sampler",
      sampler: { zones: [{ path: "/x.wav", crossfade: { ccInL0: 1 } }] },
    },
  })) as any;
  assert.ok(result.isError, "a typo'd crossfade field must be rejected, not silently stripped");
  assert.match(result.content?.[0]?.text ?? "", /unrecognized_keys/);
  assert.equal(calls.length, 0);
});

test("track_set_instrument still accepts a legitimate sampler object (no regression from the new .strict() schemas)", async () => {
  const trackId = randomUUID();
  const zoneId = randomUUID();
  queuedResult = { kind: "sampler", sampler: { zones: [{ id: zoneId, path: "/x.wav", rootPitch: 60, minPitch: 0, maxPitch: 127, gain: 0.8 }] } };

  const result = (await client.callTool({
    name: "track_set_instrument",
    arguments: {
      trackId,
      kind: "sampler",
      sampler: {
        release: 0.4,
        zones: [
          {
            path: "/x.wav",
            minPitch: 0,
            maxPitch: 127,
            crossfade: { controller: 1, ccInLo: 0, ccInHi: 64 },
          },
        ],
      },
    },
  })) as any;
  assert.ok(!result.isError, `a fully legitimate sampler object must still be accepted: ${JSON.stringify(result)}`);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");
});

// ---------------------------------------------------------------------------
// Description assertions — the descriptions ARE the contract here
// ---------------------------------------------------------------------------

test("descriptions teach: track_set_instrument's zones REPLACES wholesale, zonePatches MERGES", () => {
  const zonesTool = tools.find((t) => t.name === "instrument_set_sampler_zones");
  assert.ok(zonesTool, "instrument_set_sampler_zones is registered");
  const description = zonesTool.description as string;
  assert.match(description, /REPLACES/, "names the wholesale-replace behavior of track_set_instrument's zones");
  assert.match(description, /MERGE/, "names its own merge-by-id behavior");
});

test("descriptions teach: `zones: []` is the only way to clear a sampler", () => {
  const zonesTool = tools.find((t) => t.name === "instrument_set_sampler_zones");
  const description = zonesTool.description as string;
  assert.match(description, /zones: \[\]/, "names the deliberate empty-array clear");
});

test("descriptions teach: a foreign zone id is re-minted and reported in remintedZoneIDs", () => {
  const zonesTool = tools.find((t) => t.name === "instrument_set_sampler_zones");
  const setInstrumentTool = tools.find((t) => t.name === "track_set_instrument");
  assert.ok(setInstrumentTool, "track_set_instrument is registered");
  assert.match(zonesTool.description as string, /remintedZoneIDs/);
  assert.match(
    setInstrumentTool.description as string,
    /remintedZoneIDs/,
    "track_set_instrument's OWN description must also teach re-minting, now that ids are honoured on its wholesale path"
  );
});

test("descriptions teach: displayName is a non-unique file stem, sourcePath disambiguates", () => {
  const describeTool = tools.find((t) => t.name === "instrument_describe_sampler");
  assert.ok(describeTool, "instrument_describe_sampler is registered");
  const description = describeTool.description as string;
  assert.match(description, /displayName/);
  assert.match(description, /NOT unique/i);
  assert.match(description, /sourcePath/);
});

test("descriptions teach: an inert global is NOT SFZ-specific (Defect C) — dspreset and hand-built samplers can hit it too", () => {
  const describeTool = tools.find((t) => t.name === "instrument_describe_sampler");
  const description = describeTool.description as string;
  assert.match(description, /ANY per-zone value/, "names the general cause, not just SFZ");
  assert.match(description, /dspreset/i);
  assert.match(description, /ampeg_release.*ONLY when.*sourcePath.*\.sfz/s, "gates the opcode mention on real .sfz provenance");
});

test("descriptions teach: top-level `warnings` (Defect D) restates the stored-vs-effective mismatch for a caller reading only the top level", () => {
  const describeTool = tools.find((t) => t.name === "instrument_describe_sampler");
  const description = describeTool.description as string;
  assert.match(description, /warnings/);
  assert.match(description, /impossible to miss/);
});

test("all three sampler tools have a non-empty title and pass the beginner-readable description bar", () => {
  for (const name of ["instrument_describe_sampler", "instrument_set_sampler_param", "instrument_set_sampler_zones"]) {
    const tool = tools.find((t) => t.name === name);
    assert.ok(tool, `${name} is registered`);
    assert.ok(tool.title && tool.title.trim().length > 0, `${name} has a title`);
    assert.ok((tool.description as string).trim().length >= 40, `${name}'s description clears the length bar`);
  }
});
