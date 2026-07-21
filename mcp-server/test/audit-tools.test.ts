/**
 * audit-tools.test.ts — MCP tool parity + schema-richness enforcement.
 *
 * Roadmap item (M7): "Every control command exposed as an MCP tool with
 * rich schemas" (docs/ROADMAP.md). This suite spins up the REAL McpServer
 * (imported from `src/server.ts`, never `src/index.ts` — see that file for
 * why the split exists) on an in-memory transport pair, lists its tools via
 * a real SDK `Client`, and cross-checks them against the control-protocol
 * command table in `Sources/DAWControl/Commands.swift`.
 *
 * No network, no stdio, no DAW app required: `tools/list` only, never
 * `tools/call`. `DawBridge` connects lazily on first `send()` (see
 * `src/bridge.ts`), so merely importing/constructing the server has no
 * side effects here.
 */

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { server } from "../src/server.js";

// ---------------------------------------------------------------------------
// Exception tables (kept in sync with docs/ARCHITECTURE.md's MCP section —
// update both places if either changes).
// ---------------------------------------------------------------------------

/**
 * Table A — commands whose MCP tool name the mechanical rule can't produce, so
 * an explicit override is pinned. The six generation commands historically DROP
 * the `ai_` prefix (live in user configs; do not rename). `plugin.listOpenUIs`
 * is the acronym-plural case: the mechanical rule splits the "UIs" run into
 * `plugin_list_open_u_is`, so the readable `plugin_list_open_uis` (design §5.4)
 * is pinned here instead.
 */
const EXCEPTION_TABLE_A: Readonly<Record<string, string>> = Object.freeze({
  "ai.generateSong": "generate_song",
  "ai.extractStems": "extract_stems",
  "ai.legoGenerate": "lego_generate",
  "ai.generationStatus": "generation_status",
  "ai.importGeneration": "import_generation",
  "ai.importGeneratedStems": "import_generated_stems",
  "plugin.listOpenUIs": "plugin_list_open_uis",
});

/**
 * Table B — MCP tools with no backing control-protocol command by design:
 * they call an AI provider's API directly from the MCP server rather than
 * bridging to the app.
 */
const EXCEPTION_TABLE_B: ReadonlySet<string> = new Set([
  "generate_image",
  "generate_lyrics",
  "generate_song_suno",
]);

/** Format-drift guard: if the Commands.swift parser yields fewer than this
 * many commands, the regex has almost certainly stopped matching the file
 * (e.g. the array literal moved or the source format changed) — fail loudly
 * rather than silently auditing zero commands. */
const MIN_EXPECTED_COMMANDS = 80;

/** Beginner-readable bar: tool descriptions must clear this length. */
const MIN_DESCRIPTION_LENGTH = 40;

// ---------------------------------------------------------------------------
// Command-name -> tool-name mapping rule
// ---------------------------------------------------------------------------

/** camelCase segment -> snake_case, collapsing uppercase runs (acronyms):
 * `addAudio` -> `add_audio`, `addMIDI` -> `add_midi`, `listAudioUnits` ->
 * `list_audio_units`. */
function camelSegmentToSnake(segment: string): string {
  return segment
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .toLowerCase();
}

/** Dotted control command -> expected MCP tool name, per the mechanical
 * rule ("." -> "_", camelCase -> snake_case) with exception table A applied
 * for the historical `ai_`-prefix-dropping generation tools. */
function commandToToolName(command: string): string {
  const exception = EXCEPTION_TABLE_A[command];
  if (exception) return exception;
  return command.split(".").map(camelSegmentToSnake).join("_");
}

// ---------------------------------------------------------------------------
// Commands.swift parsing
// ---------------------------------------------------------------------------

/** Walk up from `startDir` until a `package.json` named `daw-pro-mcp` is
 * found (i.e. the mcp-server/ package root). Robust to this test running
 * from its TS source location or from a compiled/nested build output
 * directory (e.g. `dist-test/test/`). */
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
  throw new Error(
    `Could not locate the mcp-server/ package root by walking up from ${startDir}. ` +
      "This test expects to live somewhere under mcp-server/ (source or compiled)."
  );
}

/** Parse the literal dotted-string array assigned to
 * `Command.allCommands` out of Commands.swift. Only quoted dotted
 * identifiers between the declaration and its closing `]` are collected —
 * this is a text scrape, not a Swift parser, by design (the brief). */
function parseAllCommands(commandsSwiftPath: string): string[] {
  const source = readFileSync(commandsSwiftPath, "utf8");
  const declIndex = source.indexOf("public static let allCommands");
  if (declIndex === -1) {
    throw new Error(
      `Could not find "public static let allCommands" in ${commandsSwiftPath}. ` +
        "Commands.swift's format may have changed — update the parser."
    );
  }
  // The declaration is `let allCommands: [String] = [`, i.e. it contains a
  // `]` (closing the `[String]` type annotation) BEFORE the array literal's
  // own opening `[` — a naive "first ']' after the declaration" search finds
  // that one, not the array's close. Find the literal's opening `[` (the one
  // in `= [`) and then depth-count brackets forward to find its true match.
  const openIndex = source.indexOf("[", source.indexOf("=", declIndex));
  if (openIndex === -1) {
    throw new Error(`Found "allCommands" but no "= [" array literal after it in ${commandsSwiftPath}.`);
  }
  let depth = 0;
  let closeIndex = -1;
  for (let i = openIndex; i < source.length; i++) {
    const ch = source[i];
    if (ch === "[") depth++;
    else if (ch === "]") {
      depth--;
      if (depth === 0) {
        closeIndex = i;
        break;
      }
    }
  }
  if (closeIndex === -1) {
    throw new Error(`Found "allCommands"'s opening "[" but no matching closing "]" in ${commandsSwiftPath}.`);
  }
  const arrayLiteral = source.slice(openIndex, closeIndex);
  const matches = arrayLiteral.match(/"[a-zA-Z][a-zA-Z0-9]*(?:\.[a-zA-Z][a-zA-Z0-9]*)+"/g) ?? [];
  const commands = matches.map((m) => m.slice(1, -1));

  if (commands.length < MIN_EXPECTED_COMMANDS) {
    throw new Error(
      `Parsed only ${commands.length} commands from ${commandsSwiftPath} (expected >= ` +
        `${MIN_EXPECTED_COMMANDS}). This almost certainly means the parser regex stopped ` +
        "matching the file's format, not that commands were removed — update the parser " +
        "in test/audit-tools.test.ts before trusting this audit."
    );
  }
  return commands;
}

// ---------------------------------------------------------------------------
// JSON-schema property-description walker
// ---------------------------------------------------------------------------

interface JsonSchemaNode {
  description?: unknown;
  properties?: Record<string, JsonSchemaNode>;
  items?: JsonSchemaNode | JsonSchemaNode[];
  anyOf?: JsonSchemaNode[];
  oneOf?: JsonSchemaNode[];
  allOf?: JsonSchemaNode[];
  [key: string]: unknown;
}

function hasNonEmptyDescription(node: JsonSchemaNode): boolean {
  return typeof node.description === "string" && node.description.trim().length > 0;
}

/** Recursively collect every property in `schema` (including nested
 * object properties and array `items`) that lacks a non-empty
 * `description`. `pathLabel` accumulates a human-readable path for the
 * failure message. */
function collectMissingDescriptions(schema: JsonSchemaNode, pathLabel: string, out: string[]): void {
  if (schema.properties) {
    for (const [key, propSchema] of Object.entries(schema.properties)) {
      const propPath = pathLabel ? `${pathLabel}.${key}` : key;
      if (!hasNonEmptyDescription(propSchema)) {
        out.push(propPath);
      }
      collectMissingDescriptions(propSchema, propPath, out);
    }
  }
  if (schema.items) {
    const itemSchemas = Array.isArray(schema.items) ? schema.items : [schema.items];
    for (const itemSchema of itemSchemas) {
      collectMissingDescriptions(itemSchema, `${pathLabel}[]`, out);
    }
  }
  for (const combinator of ["anyOf", "oneOf", "allOf"] as const) {
    const branch = schema[combinator];
    if (Array.isArray(branch)) {
      for (const sub of branch as JsonSchemaNode[]) {
        collectMissingDescriptions(sub, pathLabel, out);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Shared, memoized setup: connect the real server to a real client over an
// in-memory transport pair, exactly once for the whole suite.
// ---------------------------------------------------------------------------

interface ListedTool {
  name: string;
  title?: string;
  description?: string;
  inputSchema: JsonSchemaNode;
}

let client: Client;
let tools: ListedTool[];
let commands: string[];

before(async () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const mcpServerRoot = findMcpServerRoot(here);
  const commandsSwiftPath = join(mcpServerRoot, "..", "Sources", "DAWControl", "Commands.swift");
  commands = parseAllCommands(commandsSwiftPath);

  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "audit-tools-test-client", version: "0.0.0" });

  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);

  const result = await client.listTools();
  tools = result.tools as unknown as ListedTool[];
});

after(async () => {
  await client?.close();
});

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

test("Commands.swift parses to a plausible number of commands (format-drift guard)", () => {
  assert.ok(
    commands.length >= MIN_EXPECTED_COMMANDS,
    `expected >= ${MIN_EXPECTED_COMMANDS} commands, parsed ${commands.length}`
  );
});

test("every control command maps to exactly one listed MCP tool", () => {
  const toolNames = new Set(tools.map((t) => t.name));
  const missing: string[] = [];
  for (const command of commands) {
    const expected = commandToToolName(command);
    if (!toolNames.has(expected)) {
      missing.push(`${command} -> expected tool "${expected}" not found`);
    }
  }
  assert.deepEqual(missing, [], `commands with no matching tool:\n${missing.join("\n")}`);

  // "Exactly one": registerTool itself throws on duplicate names at
  // registration time, but double-check no two commands collide on the
  // same expected tool name (which would mask a missing tool above).
  const expectedNameCounts = new Map<string, string[]>();
  for (const command of commands) {
    const expected = commandToToolName(command);
    const list = expectedNameCounts.get(expected) ?? [];
    list.push(command);
    expectedNameCounts.set(expected, list);
  }
  const collisions = [...expectedNameCounts.entries()].filter(([, cmds]) => cmds.length > 1);
  assert.deepEqual(
    collisions,
    [],
    `multiple commands map to the same tool name: ${JSON.stringify(collisions)}`
  );
});

test("every listed MCP tool maps back to a command, or is in exception table B", () => {
  const expectedFromCommands = new Set(commands.map(commandToToolName));
  const strays: string[] = [];
  for (const tool of tools) {
    if (!expectedFromCommands.has(tool.name) && !EXCEPTION_TABLE_B.has(tool.name)) {
      strays.push(tool.name);
    }
  }
  assert.deepEqual(strays, [], `tools with no backing command and not in exception table B:\n${strays.join("\n")}`);
});

test("tool count is a bijection: commands + |exception table B|, no strays", () => {
  assert.equal(
    tools.length,
    commands.length + EXCEPTION_TABLE_B.size,
    `expected ${commands.length} commands + ${EXCEPTION_TABLE_B.size} exception-B tools = ` +
      `${commands.length + EXCEPTION_TABLE_B.size} tools, found ${tools.length}`
  );
});

test("every tool has a non-empty title and a beginner-readable description (>= 40 chars)", () => {
  const violations: string[] = [];
  for (const tool of tools) {
    if (!tool.title || tool.title.trim().length === 0) {
      violations.push(`${tool.name}: missing/empty title`);
    }
    if (!tool.description || tool.description.trim().length === 0) {
      violations.push(`${tool.name}: missing/empty description`);
    } else if (tool.description.trim().length < MIN_DESCRIPTION_LENGTH) {
      violations.push(
        `${tool.name}: description too short (${tool.description.trim().length} < ${MIN_DESCRIPTION_LENGTH} chars): "${tool.description}"`
      );
    }
  }
  assert.deepEqual(violations, [], violations.join("\n"));
});

test("every inputSchema property (recursively) has a non-empty description", () => {
  const violations: string[] = [];
  for (const tool of tools) {
    const missing: string[] = [];
    collectMissingDescriptions(tool.inputSchema, "", missing);
    for (const propPath of missing) {
      violations.push(`${tool.name}: property "${propPath}" has no description`);
    }
  }
  assert.deepEqual(violations, [], violations.join("\n"));
});

test("no tool name contains a capital letter or a dot", () => {
  const violations = tools.filter((t) => /[A-Z.]/.test(t.name)).map((t) => t.name);
  assert.deepEqual(violations, [], `tool names with capitals or dots: ${violations.join(", ")}`);
});

test("project_snapshot teaches the m22-e per-effect gainReductionDb meter (additive wire field)", () => {
  // m22-e rides an ADDITIVE field on the existing snapshot poll path instead
  // of a new command, so the bijection above can't see it — pin the teaching
  // here: the tool description is the agent's only manual for the field.
  const snapshot = tools.find((t) => t.name === "project_snapshot");
  assert.ok(snapshot, "project_snapshot tool exists");
  const description = snapshot!.description ?? "";
  assert.match(description, /gainReductionDb/, "teaches the gainReductionDb key");
  assert.match(description, /held-peak/i, "teaches the held-peak ballistics");
  assert.match(description, /-20 dB\/s|−20 dB\/s/, "pins the release convention");
  assert.match(
    description,
    /compressor, limiter,\s*gate|compressor\/limiter\/gate/i,
    "names the dynamics kinds that report it"
  );
  assert.match(description, /masterEffects/, "teaches that master inserts carry it too");
});
