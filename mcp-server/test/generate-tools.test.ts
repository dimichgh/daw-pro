/**
 * generate-tools.test.ts — unknown-key regression pin for the three Table-B
 * generation tools (m23-eh).
 *
 * `generate_lyrics` / `generate_song_suno` / `generate_image` call an AI
 * provider directly from the MCP server (src/ai.ts) rather than bridging to
 * the DAW app, so the wire-side `rejectUnknownKeys` guard that protects every
 * other command NEVER runs for them — before this fix they registered via
 * bare `server.registerTool`, whose default zod "strip" parse mode silently
 * DISCARDS unknown keys instead of rejecting the call. Concretely:
 * `generate_song_suno({ prompt, lyric: "…" })` (singular typo) used to parse
 * fine, zod would strip `lyric`, and a PAID generation would run with no
 * lyrics and no error. This suite pins that these three now route through
 * `registerTool` (server.ts:96-109, the wrapper function) and get the same
 * `.strict()` schema as every mutating tool.
 *
 * SAFETY, read carefully — this suite exists to catch exactly the bug where
 * unknown keys reach the provider, so a REGRESSION makes these calls reach
 * `src/ai.ts` for real:
 *
 * 1. `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `SUNO_API_KEY` are deleted from
 *    `process.env` at the very top of this file, before anything is
 *    imported, so that even if the fix regresses and a call reaches
 *    `src/ai.ts`, every provider path hits its own "Missing required API
 *    key(s)" guard and returns before any `fetch`. This is NOT the primary
 *    guard (see #2) — it is defense in depth for a dev machine that happens
 *    to export real keys directly (not just via `.env`, which this package
 *    never auto-loads — `grep -rn "dotenv" src/` returns nothing).
 * 2. The three behavioral tests below assert on the exact rejection reason,
 *    not merely `isError`. Zod's `unrecognized_keys` message text is the
 *    only fingerprint that proves the MCP SDK's schema validation rejected
 *    the call BEFORE `executeToolHandler` ran (see
 *    `validateToolInput`/`CallToolRequestSchema` in
 *    `@modelcontextprotocol/sdk/server/mcp.js`, which always runs the former
 *    before the latter). Asserting `isError` alone is NOT sufficient and was
 *    an earlier bug in this very file: with the fix reverted, the unknown
 *    key is silently stripped, the handler runs for real, and (with no
 *    provider key configured) throws its OWN "Missing required API key(s)"
 *    error — which also sets `isError: true` and would make a same-shaped
 *    "isError" assertion pass for the wrong reason, while a real
 *    generation would fire on a machine that does have keys configured. A
 *    JSON-schema inspection alternative was tried and also does not work:
 *    `tool.inputSchema.additionalProperties` is `false` for a `z.object()`
 *    with a non-empty shape whether or not `.strict()` was applied — this
 *    SDK's json-schema conversion does not surface the strict/strip
 *    distinction at all, only the emptiness of the shape (measured: an
 *    UNCHANGED bare-`server.registerTool` build still reports
 *    `additionalProperties: false` for all three tools here). So this suite
 *    pins the fix two ways instead: the exact rejection-reason text (proves
 *    RUNTIME behavior) and a source-level scrape of `src/server.ts` (proves
 *    the registration call site itself, independent of any SDK behavior —
 *    same technique `audit-tools.test.ts` uses on `Commands.swift` and
 *    `tempo-lint.test.ts` uses across `Sources/`).
 *
 * Mutation-tested by hand: reverting the three call sites to bare
 * `server.registerTool` makes the three behavioral tests below fail with
 * the handler's real "Missing required API key(s)" message (not a schema
 * error) and makes the source-scrape test fail; restoring the fix makes all
 * four pass.
 */

// Defense in depth (#1 above) — must run before ANY import that could reach
// src/ai.ts. Harmless when the keys were never set.
delete process.env["ANTHROPIC_API_KEY"];
delete process.env["OPENAI_API_KEY"];
delete process.env["SUNO_API_KEY"];

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

// Imported AFTER the env deletions above, matching the vc.test.ts precedent
// of ordering side effects before the module (and its `DawBridge`/provider
// wiring) is loaded.
const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "generate-tools-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

/**
 * Asserts the call was rejected AT THE SCHEMA LAYER specifically — see the
 * file-header SAFETY note for why `isError` alone is not sufficient.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function assertRejectedAtSchemaLayer(result: any, badKey: string): void {
  assert.equal(result?.isError, true, `expected an MCP tool error, got: ${JSON.stringify(result)}`);
  const text = result.content?.[0]?.text ?? "";
  assert.match(
    text,
    /unrecognized_keys/,
    `expected a zod "unrecognized_keys" schema-validation error (proving the handler never ran), got: ${text}`
  );
  assert.match(
    text,
    new RegExp(badKey),
    `expected the schema error to name the bad key "${badKey}", got: ${text}`
  );
}

test("generate_song_suno rejects the singular 'lyric' typo at the MCP boundary (never reaches the provider)", async () => {
  // The exact failure mode from the roadmap item: a typo'd key silently
  // dropped by zod's default strip mode, so the call would previously
  // succeed with lyrics discarded instead of failing loudly.
  const result = await client.callTool({
    name: "generate_song_suno",
    arguments: { prompt: "a slow piano ballad", lyric: "these words never reach the provider" },
  });
  assertRejectedAtSchemaLayer(result, "lyric");
});

test("generate_image rejects a 'dimensions' typo (the correct key is 'size') at the MCP boundary", async () => {
  const result = await client.callTool({
    name: "generate_image",
    arguments: { prompt: "a neon cassette tape", dimensions: "1024x1024" },
  });
  assertRejectedAtSchemaLayer(result, "dimensions");
});

test("generate_lyrics rejects an unrecognized argument at the MCP boundary", async () => {
  const result = await client.callTool({
    name: "generate_lyrics",
    arguments: { theme: "missing someone", genre: "90s pop-punk" }, // correct key is 'style', not 'genre'
  });
  assertRejectedAtSchemaLayer(result, "genre");
});

// ---------------------------------------------------------------------------
// Source-level pin: the JSON schema surfaced over `tools/list` cannot
// distinguish `registerTool` (strict) from bare `server.registerTool`
// (strip) — see the file-header SAFETY note — so this scrapes the actual
// registration call site in src/server.ts instead. Same walk-up-to-find-root
// technique as audit-tools.test.ts / tempo-lint.test.ts, so this also works
// against the compiled dist-test/ output the npm test script runs.
// ---------------------------------------------------------------------------

function findMcpServerRoot(startDir: string): string {
  let dir = startDir;
  for (let i = 0; i < 12; i++) {
    const candidate = join(dir, "package.json");
    if (existsSync(candidate)) {
      try {
        const pkg = JSON.parse(readFileSync(candidate, "utf8")) as { name?: string };
        if (pkg.name === "daw-pro-mcp") return dir;
      } catch {
        // Not JSON, or unreadable — keep walking up.
      }
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error(`Could not locate mcp-server/ by walking up from ${startDir}.`);
}

test("source pin: all three Table-B tools register via the strict registerTool wrapper, not bare server.registerTool", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const mcpServerRoot = findMcpServerRoot(here);
  const source = readFileSync(join(mcpServerRoot, "src", "server.ts"), "utf8");

  for (const name of ["generate_lyrics", "generate_song_suno", "generate_image"]) {
    // Plain string checks, not regex. `wrapped` is anchored on a leading
    // "\n" so it matches ONLY the column-0 `registerTool(` call, never the
    // "registerTool(" tail end of "server.registerTool(" (which has "r",
    // not a newline, immediately before it) — a genuine positive proof, not
    // just the mirror image of the negative check below.
    const wrapped = `\nregisterTool(\n  "${name}",`;
    const bare = `server.registerTool(\n  "${name}",`;
    assert.ok(
      source.includes(wrapped),
      `expected to find the column-0 wrapper call for "${name}" in src/server.ts — it must register via the strict registerTool(...) wrapper`
    );
    assert.ok(
      !source.includes(bare),
      `found "${bare.replace(/\n/g, "\\n")}" in src/server.ts — "${name}" must NOT register via bare server.registerTool(...) (that bypasses .strict())`
    );
  }
});
