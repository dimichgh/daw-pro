/**
 * agent-allowlist-grants.test.ts — m27-g, m27-i, m27-p (wave 8).
 *
 * Agent `tools:` allowlists are HAND-MAINTAINED; regenerating the plugin
 * bundle does not reach them, and nothing else reads them. A granted name that
 * is misspelled, or no longer a registered tool, is silently useless: the agent
 * simply lacks the tool. This pins:
 *   - arranger holds the read-only `clip_get_notes` and says to read before cutting (m27-g);
 *   - finisher holds `reference_remove` and says to tidy the slot it imported (m27-i);
 *   - the /new-song skill says sound-designer MAY run alongside composer and names
 *     the `warnings` array of `track_set_instrument` as the safety condition (m27-p);
 *   - every `mcp__plugin_daw-pro-music-team_daw-pro__*` name in EVERY agent's
 *     allowlist is a tool the server registers (a typo anywhere reds here).
 *
 * ⚠️ It pins PROSE and names, not behaviour. `PXS_PLUGIN_DIR` exists ONLY to
 * positive-control this test against edited COPIES, never the tree.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

function findMcpServerRoot(startDir: string): string {
  let dir = startDir;
  for (let i = 0; i < 8; i++) {
    if (existsSync(join(dir, "package.json")) && existsSync(join(dir, "src", "server.ts"))) return dir;
    dir = dirname(dir);
  }
  throw new Error(`Could not locate mcp-server/ by walking up from ${startDir}`);
}

const ROOT = findMcpServerRoot(dirname(fileURLToPath(import.meta.url)));
const PLUGIN_DIR = process.env.PXS_PLUGIN_DIR || join(ROOT, "..", "claude-plugin");
const AGENT_DIR = join(PLUGIN_DIR, "agents");
const SERVER_SRC = readFileSync(join(ROOT, "src", "server.ts"), "utf8");
const NAME_RE = /mcp__plugin_daw-pro-music-team_daw-pro__([A-Za-z0-9_]+)/g;

function split(agent: string): { tools: Set<string>; body: string } {
  const text = readFileSync(join(AGENT_DIR, `${agent}.md`), "utf8");
  const m = text.match(/^---\n([\s\S]*?)\n---\n/);
  assert.ok(m, `${agent}.md has no YAML frontmatter`);
  const tools = new Set([...(m[1] ?? "").matchAll(NAME_RE)].map((x) => x[1] ?? ""));
  assert.ok(tools.size >= 10, `only ${tools.size} tools parsed from ${agent}'s allowlist: the parser is broken, not the doc`);
  return { tools, body: text.slice(m[0].length) };
}

test("arranger can read notes before it cuts (m27-g)", () => {
  const { tools, body } = split("arranger");
  assert.ok(tools.has("clip_get_notes"), "arranger's allowlist does not grant clip_get_notes");
  assert.ok(!tools.has("clip_set_notes"), "arranger must stay read-only on note content");
  assert.match(body, /clip_get_notes[\s\S]{0,300}before you trim, fit or split/, "arranger no longer says to read notes before trimming/fitting/splitting");
});

test("finisher can remove the reference slot it imported (m27-i)", () => {
  const { tools, body } = split("finisher");
  assert.ok(tools.has("reference_import"), "finisher lost reference_import");
  assert.ok(tools.has("reference_remove"), "finisher's allowlist does not grant reference_remove");
  assert.match(body, /reference_remove[\s\S]{0,200}you\s+imported/, "finisher no longer says to remove the slot it imported");
});

test("new-song says sound-designer may run beside composer, and names the safety warning (m27-p)", () => {
  const text = readFileSync(join(PLUGIN_DIR, "skills", "new-song", "SKILL.md"), "utf8");
  assert.match(text, /Sound-designer MAY run at the same time as composer/);
  assert.match(text, /`warnings` array that `track_set_instrument` returns/);
  assert.doesNotMatch(text, /Sound-designer works AFTER composer/, "the old serial rule is back");
});

test("every tool in every agent's allowlist is a registered tool", () => {
  const agents = readdirSync(AGENT_DIR).filter((f) => f.endsWith(".md"));
  assert.ok(agents.length >= 5, `only ${agents.length} agent files found: wrong directory?`);
  const missing: string[] = [];
  for (const f of agents) {
    for (const t of split(f.replace(/\.md$/, "")).tools) {
      if (!SERVER_SRC.includes(`"${t}"`)) missing.push(`${f}: ${t}`);
    }
  }
  assert.deepEqual(missing, [], `allowlist names the server does not register: ${missing.join(", ")}`);
});
