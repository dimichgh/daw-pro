/**
 * timeline-ceiling.test.ts — m23-ap I5-F4 round 4: THE TIMELINE CEILING at the
 * MCP boundary.
 *
 * The app refuses, for every command, a beat position, length or offset, or a
 * bar number or number of bars, further than 2^20 = 1048576 from 0
 * (`TimelineLimits.maximumBeats` in DAWCore; `TimelineCeiling` in the wire).
 * The schemas refuse the same values first, so they never cost a bridge round
 * trip, and `tools/list` carries the bound as each field's `maximum`.
 *
 * COMPLETENESS, not a sample: the first test walks EVERY listed tool's input
 * schema and finds every property whose name is one of the app's checked names
 * (the same lists as TimelineCeiling.swift), at any depth (inside `notes`,
 * `points`, `segments`, ...), and requires a `maximum` no bigger than the
 * ceiling. A tool added later with an unbounded `atBeat` fails here.
 *
 * Behaviour, with the stub bridge of quantize-grid-floor.test.ts: a value one
 * past the ceiling (and Infinity, which `JSON.parse` makes of a JSON-RPC 1e400)
 * is refused with ZERO bridge calls; the ceiling itself reaches the bridge
 * verbatim (POSITIVE CONTROL).
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

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  return {};
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "timeline-ceiling-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
});

/** `TimelineLimits.maximumBeats` (DAWCore), 2^20. */
const CEILING = 1048576;

/** The names TimelineCeiling.swift checks everywhere, and the two it checks on one command each. */
const BEAT_KEYS = new Set([
  "atBeat", "lengthBeats", "startBeat", "endBeat", "toStartBeat", "fromBeat", "toBeat", "newStartBeat",
  "newLengthBeats", "beat", "beats", "inBeat", "outBeat", "byBeats", "firstCopyAtBeat", "periodBeats",
  "fadeInBeats", "fadeOutBeats", "timingBeats", "legatoOverlapBeats", "maxGapBeats", "scaleBeats",
  "revolutionBeats", "driftScaleBeats",
]);
const BAR_KEYS = new Set(["atBar", "fromBar", "bars", "countInBars"]);
const SCOPED: Record<string, Set<string>> = {
  arrange_insert_bars: new Set(["count"]),
  arrange_delete_bars: new Set(["count"]),
  looper_begin: new Set(["horizonCycles"]),
};

type Schema = {
  type?: string | string[];
  properties?: Record<string, Schema>;
  items?: Schema | Schema[];
  anyOf?: Schema[];
  allOf?: Schema[];
  oneOf?: Schema[];
  maximum?: number;
  exclusiveMaximum?: number | boolean;
  minimum?: number;
  exclusiveMinimum?: number | boolean;
};

/** Every (path, schema) under `schema` whose property name is checked, at any depth. */
function checkedFields(tool: string, schema: Schema, path = ""): Array<[string, string, Schema]> {
  const out: Array<[string, string, Schema]> = [];
  const visit = (s: Schema | undefined, p: string, top: boolean) => {
    if (!s || typeof s !== "object") return;
    for (const [key, child] of Object.entries(s.properties ?? {})) {
      const here = p ? `${p}.${key}` : key;
      if (BEAT_KEYS.has(key) || BAR_KEYS.has(key) || (top && SCOPED[tool]?.has(key))) {
        out.push([here, key, child]);
      }
      visit(child, here, false);
    }
    const items = Array.isArray(s.items) ? s.items : s.items ? [s.items] : [];
    for (const item of items) visit(item, `${p}[]`, false);
    for (const alt of [...(s.anyOf ?? []), ...(s.allOf ?? []), ...(s.oneOf ?? [])]) visit(alt, p, top);
  };
  visit(schema, path, true);
  return out;
}

/** The numeric branch of a field (a union like number|null keeps the bound on the number). */
function numberBranches(s: Schema): Schema[] {
  const alts = [...(s.anyOf ?? []), ...(s.oneOf ?? [])];
  if (alts.length) return alts.flatMap(numberBranches);
  const t = Array.isArray(s.type) ? s.type : [s.type];
  return t.includes("number") || t.includes("integer") ? [s] : [];
}

test("COMPLETENESS: every beat- or bar-named numeric field of every listed tool, at any depth, carries a maximum no bigger than 2^20 (and a signed one a matching minimum)", async () => {
  const { tools } = await client.listTools();
  let seen = 0;
  const missing: string[] = [];
  for (const tool of tools) {
    for (const [path, , field] of checkedFields(tool.name, tool.inputSchema as Schema)) {
      for (const branch of numberBranches(field)) {
        seen += 1;
        const max = typeof branch.exclusiveMaximum === "number" ? branch.exclusiveMaximum : branch.maximum;
        if (max === undefined || max > CEILING) missing.push(`${tool.name}.${path} (maximum ${max})`);
        const min = typeof branch.exclusiveMinimum === "number" ? branch.exclusiveMinimum : branch.minimum;
        if (min === undefined || min < -CEILING) missing.push(`${tool.name}.${path} (minimum ${min})`);
      }
    }
  }
  assert.deepEqual(missing, [], `fields past the timeline ceiling:\n${missing.join("\n")}`);
  // POSITIVE CONTROL: the walk found the fields (an empty walk passes vacuously).
  assert.ok(seen >= 70, `only ${seen} checked fields found`);
});

test("the listed schema shows the ceiling where a caller reads it: clip_add_midi atBeat, a note's startBeat, clip_move_many byBeats (both ways), arrange_insert_bars atBar and count", async () => {
  const { tools } = await client.listTools();
  const schema = (name: string) => tools.find((t) => t.name === name)?.inputSchema as Schema;
  const addMIDI = schema("clip_add_midi");
  assert.equal(addMIDI.properties?.atBeat?.maximum, CEILING);
  const note = (addMIDI.properties?.notes?.items as Schema).properties?.startBeat;
  assert.equal(note?.maximum, CEILING);
  const byBeats = schema("clip_move_many").properties?.byBeats;
  assert.equal(byBeats?.maximum, CEILING);
  assert.equal(byBeats?.minimum, -CEILING);
  const insert = schema("arrange_insert_bars");
  assert.equal(insert.properties?.atBar?.maximum, CEILING);
  assert.equal(insert.properties?.count?.maximum, CEILING);
  // clip_repeat_notes' count is a number of COPIES (its own 512 cap), not bars.
  assert.equal(schema("clip_repeat_notes").properties?.count?.maximum, 512);
  // gridBeats: the quantize floor and the timeline ceiling, on the slice grid too.
  for (const name of ["clip_quantize", "clip_quantize_audio", "groove_extract", "clip_slice_to_sampler"]) {
    const grid = schema(name).properties?.gridBeats;
    assert.equal(grid?.minimum, 1 / 1024, name);
    assert.equal(grid?.maximum, CEILING, name);
  }
});

const PAST = [CEILING + 1, 1e9, Infinity];

const CASES: Array<{ tool: string; command: string; args: (v: number) => Record<string, unknown> }> = [
  { tool: "transport_seek", command: "transport.seek", args: (v) => ({ beats: v }) },
  {
    tool: "clip_add_midi",
    command: "clip.addMIDI",
    args: (v) => ({ trackId: randomUUID(), atBeat: v, lengthBeats: 4 }),
  },
  {
    tool: "clip_add_midi",
    command: "clip.addMIDI",
    args: (v) => ({ trackId: randomUUID(), notes: [{ pitch: 60, startBeat: v, lengthBeats: 1 }] }),
  },
  {
    tool: "clip_move_many",
    command: "clip.moveMany",
    args: (v) => ({ ids: [randomUUID()], byBeats: -v }),
  },
  { tool: "arrange_insert_bars", command: "arrange.insertBars", args: (v) => ({ atBar: v, count: 1 }) },
  { tool: "marker_add", command: "marker.add", args: (v) => ({ name: "far", beat: v }) },
];

test("a value past the ceiling (one past it, 1e9, Infinity) is refused with ZERO bridge calls, on every kind of field: a top-level position, a note inside an array, a signed offset, a bar number, a marker", async () => {
  for (const c of CASES) {
    for (const v of PAST) {
      calls = [];
      const result = await client.callTool({ name: c.tool, arguments: c.args(v) });
      assert.equal(result.isError, true, `${c.tool} ${v} must be refused`);
      assert.equal(calls.length, 0, `${c.tool} ${v} reached the bridge`);
    }
  }
});

test("POSITIVE CONTROL: the ceiling itself reaches the bridge, verbatim", async () => {
  for (const c of CASES) {
    calls = [];
    const result = await client.callTool({ name: c.tool, arguments: c.args(CEILING) });
    assert.notEqual(result.isError, true, `${c.tool} at the ceiling was refused: ${JSON.stringify(result.content)}`);
    assert.equal(calls.length, 1, `${c.tool} at the ceiling did not reach the bridge`);
    assert.equal(calls[0]?.command, c.command);
  }
  assert.deepEqual(calls[0]?.params, { name: "far", beat: CEILING });
});
