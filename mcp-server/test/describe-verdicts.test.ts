/**
 * describe-verdicts.test.ts — m39-f-3: `fx_describe`'s MCP description must
 * mirror the wire's new `modulatable` field truthfully. m39-f-2:
 * `instrument_describe_synth`'s MCP description must mirror the wire's new
 * `curve` field (and the envelope-knob disagreement note) the same way.
 *
 * Spins up the REAL McpServer (imported from `src/server.ts`, never
 * `src/index.ts`) on an in-memory transport pair and lists its tools via a
 * real SDK `Client` — the `audit-tools.test.ts` idiom. `tools/list` only,
 * never `tools/call`: no network, no stdio, no DAW app required.
 *
 * This is deliberately a description-CONTENT check, not a wire-shape check —
 * the wire shape itself (that `fx.describe`'s `paramObj` actually carries
 * `modulatable` and `instrument.describeSynth`'s `parameters` actually carry
 * `curve`, each equal to what a real `mod.addRoute` does) is pinned
 * Swift-side by `Tests/DAWControlTests/DescribeVerdictsCommandTests.swift`.
 * This file's job is narrower: an agent reading ONLY the MCP tool description
 * (never the Swift source) must be told the field exists and what it means,
 * or the same "record says X, source says Y" gap these items fixed on the
 * wire reappears one layer up, in prose this time.
 */

import { test, before, after } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { server } from "../src/server.js";

interface ListedTool {
  name: string;
  title?: string;
  description?: string;
}

let client: Client;
let tools: ListedTool[];

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "describe-verdicts-test-client", version: "0.0.0" });

  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

  const result = await client.listTools();
  tools = result.tools as unknown as ListedTool[];
});

after(async () => {
  await client?.close();
});

function tool(name: string): ListedTool {
  const found = tools.find((t) => t.name === name);
  assert.ok(found, `tool "${name}" not found in tools/list`);
  return found;
}

test("fx_describe's description documents the modulatable field and its wire shape", () => {
  const description = tool("fx_describe").description ?? "";
  assert.match(
    description,
    /\{name, min, max, default, unit, curve, modulatable\}/,
    "the shape line must list modulatable alongside curve — the field this test exists to catch " +
      "going undocumented again"
  );
});

test("fx_describe's description names all three modulatable verdicts and what each means", () => {
  const description = tool("fx_describe").description ?? "";
  // Each verdict word, and enough surrounding context that this isn't just a
  // coincidental substring match (e.g. "yes"/"no" appearing in unrelated
  // prose elsewhere in this very long description).
  assert.match(description, /`yes`\s+modulates cleanly/);
  assert.match(description, /`warned`\s+is permitted/);
  assert.match(description, /`refused`\s+means mod_add_route throws/);
});

test("fx_describe's description points an agent at mod_add_route, the verb the verdict predicts", () => {
  const description = tool("fx_describe").description ?? "";
  assert.match(description, /mod_add_route/);
});

test("fx_describe's description still documents curve (m39-a) — the modulatable addition is additive, not a rewrite", () => {
  const description = tool("fx_describe").description ?? "";
  assert.match(description, /logarithmic/);
  assert.match(description, /OCTAVES/);
});

test("instrument_describe_synth's description documents curve, which params carry it, and which don't", () => {
  const description = tool("instrument_describe_synth").description ?? "";
  assert.match(description, /`curve`/);
  assert.match(description, /cutoffHz/);
  // The 7-vs-17 split, so an agent doesn't assume every parameter has one.
  assert.match(description, /omitted/i);
});

test("instrument_describe_synth's description says the envelope knob disagrees with modulation today, without pre-empting m39-a-2", () => {
  const description = tool("instrument_describe_synth").description ?? "";
  assert.match(description, /attack.*decay.*release|attack\/decay\/release/i);
  assert.match(description, /knob/i);
  assert.match(description, /logarithmic/);
});
