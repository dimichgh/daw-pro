/**
 * agent-drum-notes-rule.test.ts — m39-tpl-0's one agent rule, pinned.
 *
 * The drum machine's `noteLayout` decides which MIDI note plays which drum
 * (`pads`: 36-43 in pad order; `gm`: General MIDI drum notes). A beat written
 * for the wrong layout plays the WRONG drums with no error, so the composer
 * and the sound designer each carry ONE rule: read `voiceNotes` from
 * `instrument_describe_drum_kit` before writing drum notes.
 *
 * A rule that names a tool the agent's `tools:` allowlist does not grant is a
 * rule the agent cannot follow, and nothing else notices: the composer had no
 * drum read tool at all until TPL-0 added it. This pins the facts a later edit
 * could silently undo: the rule is there, it names the read tool and
 * `voiceNotes` together, and the agent's allowlist grants that tool.
 *
 * ⚠️ It pins PROSE, not behaviour. Nothing here can tell whether an agent
 * obeys the rule; only a run with a real agent can.
 *
 * `TPL0_AGENT_DIR` exists ONLY to positive-control this test against edited
 * COPIES of the agent docs, never the tree.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
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

const AGENT_DIR =
  process.env.TPL0_AGENT_DIR ||
  join(findMcpServerRoot(dirname(fileURLToPath(import.meta.url))), "..", "claude-plugin", "agents");
const PREFIX = "mcp__plugin_daw-pro-music-team_daw-pro__";
const READ_TOOL = "instrument_describe_drum_kit";

function split(agent: string): { tools: Set<string>; body: string } {
  const text = readFileSync(join(AGENT_DIR, `${agent}.md`), "utf8");
  const m = text.match(/^---\n([\s\S]*?)\n---\n/);
  assert.ok(m, `${agent}.md has no YAML frontmatter`);
  const frontmatter = m[1] ?? "";
  const tools = new Set([...frontmatter.matchAll(/mcp__plugin_daw-pro-music-team_daw-pro__([a-z0-9_]+)/g)].map((x) => x[1] ?? ""));
  // Self-control: a parser that reads nothing would let every check below pass vacuously.
  assert.ok(tools.size >= 10, `only ${tools.size} ${PREFIX}* tools parsed from ${agent}'s allowlist: the parser is broken, not the doc`);
  return { tools, body: text.slice(m[0].length) };
}

for (const agent of ["composer", "sound-designer"]) {
  test(`${agent}: the drum-notes rule is present and its read tool is granted`, () => {
    const { tools, body } = split(agent);
    assert.ok(tools.has(READ_TOOL), `${agent} is told to read voiceNotes but its allowlist does not grant ${READ_TOOL}`);
    assert.match(
      body,
      /voiceNotes[\s\S]{0,160}instrument_describe_drum_kit|instrument_describe_drum_kit[\s\S]{0,160}voiceNotes/,
      `${agent}'s rule no longer says to read voiceNotes from ${READ_TOOL}`
    );
    assert.match(body, /noteLayout/, `${agent} no longer names noteLayout`);
  });
}

test("sound-designer no longer states the pad map as a fixed fact", () => {
  const { body } = split("sound-designer");
  assert.doesNotMatch(body, /triggered by MIDI notes 36-43 in that order/);
});
