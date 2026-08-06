# Generating the Codex plugin from `claude-plugin/` (m23-da)

**Status:** spec only — nothing built. Filed 2026-08-04.
**Origin:** the user's proposal — *"we may also produce codex formatted version format team
in addition to claude one, that would eliminate issue when codex does it."*

## 1. The problem this replaces

`claude-plugin/` is the source. The Codex plugin at
`~/.codex/plugins/cache/daw-pro-local/daw-pro-music-team/0.1.0/` is a conversion into the
format Codex requires, and today the user re-syncs it **by asking Codex to update its own
copy**. That step is manual, model-performed, and unverified — and it is measurably lossy.

Measured 2026-08-04:

| File | Ours | Codex | Δ |
|---|---:|---:|---|
| `skills/daw-wire-reference/SKILL.md` | 10,060 | 4,041 | **−60 %** |
| `skills/new-song/SKILL.md` | 3,784 | 2,665 | −30 % |
| `skills/daw-status/SKILL.md` | 2,784 | 1,974 | −29 % |
| `skills/mix-check/SKILL.md` | 2,618 | 2,091 | −20 % |
| `skills/bounce/SKILL.md` | 2,498 | 1,955 | −22 % |
| `skills/arrange/SKILL.md` | 2,785 | 2,763 | −1 % |
| **skills total** | **24,529** | **15,489** | **−37 %** |
| `server/index.mjs` | 1,899,212 | 1,899,212 | **byte-identical** |

The split is the whole finding: **the mechanical half of the sync is perfect, the authored
half is lossy.** A file copy loses nothing; a model re-authoring loses 37 %.

Proven consequences, not inferred:

- `fromBeat` and `durationSeconds` are documented in our wire reference at lines 74 and 83
  and return **zero** hits in the Codex copy. That is why the reporting session did repeated
  full 5:36 renders and filed *"no fast excerpt rendering"* as a missing feature. It is not
  missing; it was translated away.
- `atBeat` (our line 73) is likewise **zero** in the Codex copy. That is the `clip.addMIDI`
  trap — `atBeat` is accepted, `startBeat` is rejected — which has bitten this project
  repeatedly. A converted rulebook missing it produces wire errors that get blamed on the wire.

Generating the Codex tree removes the lossy step instead of checking after it.

## 2. Format delta — complete, and entirely mechanical

| Aspect | Claude (`claude-plugin/`) | Codex |
|---|---|---|
| Manifest path | `.claude-plugin/plugin.json` | `.codex-plugin/plugin.json` |
| Manifest schema | `$schema`, `displayName` | no `$schema`; adds `skills`, `mcpServers`, `interface{}` |
| MCP root variable | `${CLAUDE_PLUGIN_ROOT}` | `${PLUGIN_ROOT}` |
| MCP env | implicit | explicit `env_vars` **name** allowlist — **we emit `DAW_CONTROL_PORT` only** (§8) |
| Agents | top-level `agents/*.md` (6 files) | **`.toml` role files, PROJECT-level `.codex/agents/` — a plugin cannot ship them** (§4) |
| Skill invocation | skill name / Task-tool delegation | `$skill-name` sigil |
| Skill chip UI | none | per-skill `agents/openai.yaml` — **UI metadata, not an agent** (§3.2) |
| Server | `server/index.mjs` | identical file |

Nothing here requires judgement about *content*. Rewriting prose was never part of the
conversion — it was an artifact of a model doing the job.

## 3. Manifest + skill-chip metadata

⚠️ **Corrected 2026-08-04 against the Codex source docs (Context7, `/openai/codex`).** An
earlier draft of this spec called all of this "irreplaceable" and called `openai.yaml` an
agent descriptor. **Both were wrong** — see §3.2. The top-level `interface{}` block is still
hand-authored and worth keeping; the per-skill `openai.yaml` is *derived* and regenerable.

### 3.1 Top-level `interface{}` (from `.codex-plugin/plugin.json`)

```json
"interface": {
  "displayName": "DAW Pro Music Team",
  "shortDescription": "Compose, arrange, mix, and render in DAW Pro",
  "longDescription": "Control DAW Pro through a bundled local MCP server and use focused Codex workflows for diagnostics, songwriting, arranging, mix review, and verified rendering.",
  "developerName": "dsemenov",
  "category": "Creative",
  "capabilities": ["Read", "Write"],
  "websiteURL": "https://github.com/dimichgh/daw-pro",
  "defaultPrompt": [
    "Check whether DAW Pro is ready and summarize the project.",
    "Build a complete song in DAW Pro from my brief.",
    "Review this mix and suggest fixes before rendering."
  ]
}
```

Codex `description` also differs from ours and is worth keeping as authored:
`"Specialist music-production workflows and a bundled MCP bridge for controlling DAW Pro from Codex."`

The full manifest schema (from `codex-rs/skills/src/assets/samples/plugin-creator/references/plugin-json-spec.md`)
also supports `license`, `homepage`, `hooks`, `apps`, and interface extras we do not use:
`privacyPolicyURL`, `termsOfServiceURL`, `brandColor`, `composerIcon`, `logo`, `logoDark`,
`screenshots`. Note the spec's sample uses `capabilities: ["Interactive", "Write"]`; our copy
says `["Read", "Write"]` — worth a look when generating, not load-bearing.

### 3.2 Per-skill `agents/openai.yaml` — **UI metadata, not an agent**

⚠️ **This is the misreading that shaped the earlier draft.** Despite living in a directory
called `agents/`, `openai.yaml` has nothing to do with agents. Codex's own skill-creator
sample documents it as *"UI-facing metadata for skill lists and chips"* — the display name and
prompt shown on a skill chip.

Full field set per `codex-rs/skills/src/assets/samples/skill-creator/references/openai_yaml.md`:

```yaml
interface:
  display_name: "Optional user-facing name"
  short_description: "Optional user-facing description"
  icon_small: "./assets/small-400px.png"
  icon_large: "./assets/large-logo.svg"
  brand_color: "#3B82F6"
  default_prompt: "Optional surrounding prompt to use the skill with"
dependencies:
  tools:
    - type: "mcp"
      value: "github"
      description: "GitHub MCP server"
      transport: "streamable_http"
      url: "https://api.githubcopilot.com/mcp/"
policy:
  allow_implicit_invocation: true
```

⭐ **And Codex ships a deterministic generator for it** —
`scripts/generate_openai_yaml.py --interface key=value` (also `scripts/init_skill.py`), with
the standing instruction: *"On updates: validate `agents/openai.yaml` still matches SKILL.md;
regenerate if stale."* So these values are **derived from the skill, not authored beside it**.
Our generator should either call that script or reproduce its output shape — and regenerating
from our `SKILL.md` is *more* correct than preserving the cache copy, since each cached chip
was derived from its own already-lossy converted skill (−20 % to −30 %; `daw-wire-reference`
worst at −60 %, `arrange` essentially untouched at −1 %).

⚠️ **But `--interface key=value` covers the `interface` block ONLY.** `dependencies.tools`
(the `daw-pro` MCP declaration, present in all six) and `policy.allow_implicit_invocation:
false` (unique to `daw-wire-reference`) are **not** interface fields. A generator that "just
calls the script" silently drops exactly the semantic bit flagged as deliberate below. Split
it: **regenerate `interface`, template `dependencies` and `policy` from our side.**

The captured values below are therefore a **starting point and a diff target**, not an
irreplaceable artifact.

Every one shares an identical `dependencies` block:

```yaml
dependencies:
  tools:
    - type: "mcp"
      value: "daw-pro"
      description: "Local DAW Pro control server"
```

Only the `interface` varies:

| Skill | `display_name` | `short_description` | `default_prompt` |
|---|---|---|---|
| `arrange` | DAW Pro Arrange | Build and reshape song arrangements | `Use $arrange to restructure this DAW Pro song.` |
| `bounce` | DAW Pro Bounce | Render and verify final DAW deliverables | `Use $bounce to render and verify this DAW Pro project.` |
| `daw-status` | DAW Pro Status | Check DAW connection, providers, and project | `Use $daw-status to check whether DAW Pro is ready.` |
| `daw-wire-reference` | DAW Pro Wire Reference | Apply DAW tool IDs, units, and safety rules | `Use $daw-wire-reference before controlling DAW Pro.` |
| `mix-check` | DAW Pro Mix Check | Analyze mix balance, tone, and loudness | `Use $mix-check to review this DAW Pro mix.` |
| `new-song` | DAW Pro New Song | Build a complete song with specialist agents | `Use $new-song to build a complete song from my brief.` |

⚠️ **`daw-wire-reference` alone carries an extra semantic block — do not drop it:**

```yaml
policy:
  allow_implicit_invocation: false
```

That is deliberate: the wire reference is a rulebook other skills defer to, not something
Codex should invoke on its own initiative.

### 3.3 Where this metadata should live

In `claude-plugin/`, beside its skill — a per-skill `codex.yaml` sidecar (or one generator
config). It is authored data, so it belongs in the source tree under version control, not in
an install cache. Harvest first, generate second.

## 4. Agents — Codex has a real format, and plugins cannot ship it

⚠️⚠️ **An earlier draft of this spec proposed emitting each agent as its own Codex skill,
inferred from the hand-conversion. That was WRONG on both halves and is corrected here from
the Codex source.** Recorded rather than deleted so it is not re-derived.

### 4.1 The native format is TOML, and it is richer than ours

Per `codex-rs/core/src/config/agent_roles.rs`, agent role files are `.toml` in an `agents/`
directory, supporting `name`, `description`, `nickname_candidates`, `developer_instructions`,
`model`, `model_reasoning_effort`, `sandbox_mode`, and — via `#[serde(flatten)]` on
`config: ConfigToml` — **any valid config field as an override**. `developer_instructions` is
**required and must be non-blank** for standalone files in `agents/`.

The user already has six hand-authored ones at `/Users/dsemenov/Views/daw-pro-test/.codex/agents/`:
`producer.toml`, `composer.toml`, `arranger.toml`, `sound_designer.toml`, `mix_engineer.toml`,
`finisher.toml`. They carry the agent prose in `developer_instructions` **plus a per-agent MCP
tool allowlist** our Claude agents have no equivalent for:

```toml
[plugins."daw-pro-music-team".mcp_servers."daw-pro"]
enabled = true
enabled_tools = ["project_overview", "track_add", "clip_set_notes", ...]
```

⚠️⚠️ **CORRECTION — an earlier draft of this section called those `enabled_tools` lists "the
genuinely irreplaceable artifact… no upstream in our tree" and said to harvest them. THAT WAS
WRONG, and measuring it took one script.** All six of our agents already carry a `tools:`
frontmatter allowlist (`claude-plugin/agents/*.md:7`), namespaced
`mcp__plugin_daw-pro-music-team_daw-pro__<tool>`. Compared set-wise against the Codex
`enabled_tools`, after stripping that prefix:

| Agent | ours | codex | identical | only-ours | only-codex |
|---|---:|---:|---:|---:|---:|
| `composer` | 40 | 40 | **40** | 0 | 0 |
| `arranger` | 44 | 44 | **44** | 0 | 0 |
| `finisher` | 15 | 15 | **15** | 0 | 0 |
| `mix-engineer` | 42 | 42 | **42** | 0 | 0 |
| `producer` | 32 | 32 | **32** | 0 | 0 |
| `sound-designer` | 25 | 25 | **25** | 0 | 0 |

**Exact match, all six, zero drift.** So `enabled_tools` is *mechanically derivable* — strip
the prefix from our `tools:` frontmatter. Nothing to harvest, and the generator gets simpler.

⚠️ **Method note, because the first run of this comparison reported ZERO overlap on all six
and looked like total divergence:** the tokenizer split on `-` inside
`mcp__plugin_daw-pro-music-team_daw-pro__`, so no name matched. A result where
`only-ours == ours` for every row is not a finding, it is a broken pattern — the same law this
repo keeps re-learning.

⭐⭐ **This sharpens the whole thesis. It is not "model conversion is lossy" — the structured
parts converted PERFECTLY (server byte-identical, all six allowlists exactly equal). It is
specifically PROSE re-authoring that loses content.** Which is precisely the part a generator
removes, and precisely why generating is the right fix.

### 4.2 ⚠️ A plugin CANNOT bundle agents — they are project-level

From `codex-rs/core-plugins/src/store.rs`: install copies the plugin repo into
`{codex_home}/plugins/cache/{marketplace}/{plugin}/{version}`, and **"Nothing in the install
path copies a plugin's `.codex/agents` directory into a clean target project's `.codex/agents`;
the whole plugin tree is stored in the cache, so any `.codex/agents` folder would be copied
only into the cache entry, not into the user's project."**

Agents are discovered from `.codex/agents/*.toml`, `.agents/*.toml`, or `[agents.<role>]` in
`config.toml` — all **project-scoped**. This is why the converted `new-song` says *"use the
project custom agents when they are available"*: it is not a hedge, it is the actual contract.

**Consequence for the generator: two outputs, not one.**

1. `codex-plugin/` — skills, manifest, `.mcp.json`, `server/index.mjs`. Installable as a plugin.
2. `codex-agents/` — six `.toml` role files the user copies into any project's `.codex/agents/`
   where they want the team. **Not** part of the plugin, and no install step will place it there.

The generator should emit both and say plainly that step 2 is manual, because Codex gives us
no way to make it automatic.

## 5. Version — decide it, don't let it happen

Our manifest says `0.2.0`. The Codex manifest says `0.1.0`. **The version is in the install
path** (`.../daw-pro-music-team/0.1.0/`), so emitting `0.2.0` produces a plugin that installs
*beside* the live one rather than replacing it.

Either choice is fine — sync the version from our manifest and have the user reinstall, or
pin it. Doing the first silently is not.

## 6. Output location

Emit to `codex-plugin/` **in the repo**, not into `~/.codex/plugins/cache/`. The cache is
Codex's versioned install location; writing there directly is fragile (version in path) and
puts generated output outside version control. Installation stays a separate, explicit step.

## 7. The gate does not go away — it becomes the generator's test

The post-sync verification originally proposed for m23-da is repointed at the generator's
output. Same check, better placement: it now proves the generator didn't regress, and it
keeps catching drift later.

- **String survival** — assert these appear in the generated tree: `atBeat`, `startBeat`,
  `fromBeat`, `durationSeconds`, `discardChanges`, and the id-returning verbs.
- **Size-ratio floor** — per file, generated ÷ source. A mechanical conversion should sit near
  1.0; the −60 % that started this would fail loudly.
- ⚠️ **Positive control, mandatory.** A checker pointed at the wrong path, or with a broken
  pattern, reports exactly like a checker that found nothing wrong. Every run must prove it
  can fail — this repo has been burned by that specific shape more than once.

## 8. API keys — drop them from the manifest entirely

**User's call 2026-08-04:** *"given that ANTHROPIC_API_KEY, OPENAI_API_KEY, SUNO_API_KEY are
usually set in the app, then no need to set them using skills or even expose them."*

Verified, and the cost is near zero. The MCP server does read those three from `process.env`
(`mcp-server/src/ai.ts:207-208, 246, 294`), but **only three tools take that path** — the
server's own source says so at `server.ts:5928-5929`: *"Unlike generate_lyrics /
generate_song_suno / generate_image further down, ALL of these route through the DAW app's…"*

| Tool | Needs server key | Cost of dropping |
|---|---|---|
| `generate_lyrics` | ANTHROPIC or OPENAI | **None** — `ai_write_lyrics` bridges `ai.writeLyrics` to the app, which holds the keys (`server.ts:6347`). Same capability. |
| `generate_song_suno` | SUNO | **None** — Suno is dormant; ACE-Step is the live path. |
| `generate_image` | OPENAI | The only real loss. UI-asset generation — not a music-production tool, and out of scope for this plugin. |

Everything the music team actually uses bridges to the app: `generate_song` →
`ai.generateSong` (ACE local sidecar, no key), plus the whole copilot surface.

**So the generated `.mcp.json` declares `DAW_CONTROL_PORT` and nothing else.** Fewer secrets
in reach of a subprocess is strictly better, and no capability the team needs is lost.

⚠️ **Standing pin regardless of the above: the generator emits env-var NAMES only, never
values.** Assert it in the generator's own test. A template bug that interpolated the
environment would write live API keys into a generated, committed file — and the standing
constraint is that keys never reach the wire, logs, or a repo.

⭐ Worth a separate look, not decided here: the same argument applies to our own
`claude-plugin/.mcp.json`. If the app holds the keys and `ai_write_lyrics` works, the Claude
side may not need them declared either. Out of scope for this item.

## 9. What this does not change

The four app-side items filed from the same report — m23-cv (per-track meters on
`project.overview`), m23-cw (AU presets), m23-cy (genre coverage), m23-cz (track roles /
gain staging) — were all verified against Swift source and are untouched by any of this.
m23-cv remains the first thing to do.
