/**
 * render-output-format.test.ts — wiring coverage for the m23-m2 output-format
 * params: `bitDepth` / `container` on render_bounce, render_mixdown and
 * render_stems.
 *
 * The render-export-set.test.ts pattern verbatim (m23-m1): monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tools over an in-memory transport, and assert on the JSON ROUND-TRIP of the
 * forwarded params, because that is what the app actually receives — an
 * omitted optional must not become a wire key.
 *
 * What these tests can and cannot prove: this layer only carries the request.
 * Whether 24-bit AIFF actually lands on disk is asserted against the REAL
 * engine in DeliveryFormatWriteTests / DeliveryFormatRenderTests (Swift); a
 * green suite here with a broken writer is expected and is why those exist.
 *
 * m23-m2 adds PARAMS, never verbs — no tool is added or renamed, so the
 * bijection audit in audit-tools.test.ts is untouched by design.
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
  client = new Client({ name: "render-output-format-test-client", version: "0.0.0" });
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

/** What the app actually receives — JSON.stringify DROPS undefined keys. */
function wireParams(call: RecordedCall): Record<string, unknown> {
  return JSON.parse(JSON.stringify(call.params)) as Record<string, unknown>;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: any): any {
  const first = result.content[0];
  assert.ok(
    first && first.type === "text",
    `expected a text content item, got: ${JSON.stringify(result.content)}`
  );
  return JSON.parse(first.text as string);
}

const VERBS: Record<string, string> = {
  render_bounce: "render.bounce",
  render_mixdown: "render.mixdown",
  render_stems: "render.stems",
};

for (const [tool, verb] of Object.entries(VERBS)) {
  test(`${tool} forwards bitDepth + container under their exact wire names`, async () => {
    queuedResult = { ok: true };
    await client.callTool({
      name: tool,
      arguments: { durationSeconds: 2, bitDepth: 24, container: "aiff" },
    });

    assert.equal(calls.length, 1, "exactly one bridge call");
    assert.equal(calls[0]!.command, verb);
    const params = wireParams(calls[0]!);
    assert.equal(params.bitDepth, 24);
    assert.equal(params.container, "aiff");
  });

  test(`${tool}'s default call is UNCHANGED on the wire — no format keys appear`, async () => {
    queuedResult = { ok: true };
    await client.callTool({ name: tool, arguments: { durationSeconds: 2 } });

    assert.equal(calls.length, 1);
    const params = wireParams(calls[0]!);
    assert.ok(!("bitDepth" in params), `bitDepth must not appear: ${JSON.stringify(params)}`);
    assert.ok(!("container" in params), `container must not appear: ${JSON.stringify(params)}`);
  });

  test(`${tool} rejects an off-list bitDepth at the MCP boundary`, async () => {
    for (const bad of [8, 20, 64, 24.5]) {
      const result = await client.callTool({
        name: tool,
        arguments: { bitDepth: bad },
      });
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      assert.ok((result as any).isError, `bitDepth ${bad} must be refused`);
    }
    assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
  });

  test(`${tool} rejects an unknown container at the MCP boundary`, async () => {
    for (const bad of ["mp3", "flac", "caf", "WAV"]) {
      const result = await client.callTool({
        name: tool,
        arguments: { container: bad },
      });
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      assert.ok((result as any).isError, `container '${bad}' must be refused`);
    }
    assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
  });

  test(`${tool} surfaces the app's format refusal verbatim`, async () => {
    queuedError = new Error(
      "'bitDepth' must be 16, 24 or 32 (got 20) — omit it for the 32-bit float default"
    );
    const result = await client.callTool({ name: tool, arguments: { bitDepth: 32 } });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const failed = result as any;
    assert.ok(failed.isError);
    assert.match(failed.content[0].text as string, /must be 16, 24 or 32/);
  });

  test(`${tool}'s bitDepth description warns about clipping and dither`, async () => {
    const tools = await client.listTools();
    const found = tools.tools.find((t) => t.name === tool);
    assert.ok(found, `${tool} must be registered`);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const schema = (found!.inputSchema as any).properties;
    const bitDepth = (schema?.bitDepth?.description ?? "") as string;
    // The three facts a caller cannot discover by trying it once.
    assert.match(bitDepth, /float/i);
    assert.match(bitDepth, /clamp|clip/i);
    assert.match(bitDepth, /dither/i);
    const container = (schema?.container?.description ?? "") as string;
    assert.match(container, /aiff/i);
  });
}

test("render_bounce carries the format alongside the m23-m1 params without disturbing them", async () => {
  queuedResult = { path: "/tmp/mix.aiff", bitDepth: 24, container: "aiff", ditherApplied: false };
  const result = await client.callTool({
    name: "render_bounce",
    arguments: {
      path: "/tmp/mix",
      durationSeconds: 3,
      lufsTarget: -14,
      bitDepth: 24,
      container: "aiff",
    },
  });

  assert.deepEqual(wireParams(calls[0]!), {
    path: "/tmp/mix",
    fromBeat: 0,
    durationSeconds: 3,
    lufsTarget: -14,
    bitDepth: 24,
    container: "aiff",
  });
  // The response's echo passes through untouched — including the honest
  // `ditherApplied: false` (v0 truncates rather than claiming a dither).
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const payload = parseJSON(result as any);
  assert.equal(payload.container, "aiff");
  assert.equal(payload.bitDepth, 24);
  assert.equal(payload.ditherApplied, false);
  // The RETURNED path is the one that matters — the request said "/tmp/mix".
  assert.equal(payload.path, "/tmp/mix.aiff");
});
