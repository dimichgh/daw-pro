# DAW Pro Music Team

A Claude Code plugin: a team of six specialized agents plus five workflow
skills that drive [DAW Pro](../README.md) — an AI-native macOS DAW — for
real song creation and management. It rides DAW Pro's existing MCP server
(`mcp-server/`) unmodified in behavior; this plugin bundles a self-contained,
generated copy of that server's compiled output (`server/index.mjs`, built
by `esbuild` from `mcp-server/src/`, see "Developing this plugin" below) plus
the agents/skills that drive it. **The plugin ships fully standalone** — it
does not shell out to a sibling `mcp-server/` checkout at runtime, so a
plain marketplace install (which copies only the plugin directory, not its
siblings) works exactly like a local `--plugin-dir` install. This plugin
does not change the MCP server's *source*, the control-protocol wire, or
anything under `Sources/` — the bundle is a build artifact of the unmodified
source, regenerated on demand (see below).

## Prerequisites

1. **DAW Pro must be running.** Launch the app, or from the repo root run
   `swift run DAWApp`. The control server listens on `ws://127.0.0.1:17600`
   by default.
2. **(Optional) AI provider keys**, only if you want lyric writing or cloud
   song generation: `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `SUNO_API_KEY`
   in your shell environment before launching Claude Code (or set them in
   the app's own Settings panel, ⌘,). The local ACE-Step song-generation
   sidecar and every other DAW-control tool need no key at all.

That's it — end users do **not** need to run `npm install`/`npm run build`
in `mcp-server/`; the plugin already carries a built, self-contained copy of
the server (`server/index.mjs`). That step is only for developers who edit
`mcp-server/src/` and need to regenerate the bundle (see below).

## Install

**Via a marketplace** (this repo doubles as its own marketplace — see the
root `.claude-plugin/marketplace.json`) — now fully supported, since the
plugin no longer depends on a sibling directory at runtime:

```
/plugin marketplace add /absolute/path/to/daw-pro
/plugin install daw-pro-music-team@daw-pro
```

**Local development (this repo), for the duration of one session:**

```sh
claude --plugin-dir ./claude-plugin
```

Run that from the repo root, or `cd` into the repo first. Both install
paths behave identically now — pick whichever fits your workflow.

## What's in it

### Agents (`agents/`)

Each agent is scoped to exactly the
`mcp__plugin_daw-pro-music-team_daw-pro__*` tools its role needs (the
callable name Claude Code gives tools from this plugin's bundled MCP
server) — see each agent file for its full list and etiquette. All six
read the shared `daw-wire-reference` skill (id-capture rules,
beats-vs-seconds units, safety policy) preloaded into their context.

| Agent | Role | Model |
|---|---|---|
| `producer` | Coordinator: plans a song from a brief, delegates by domain, keeps the arrangement coherent. Also owns project lifecycle (save/open/new), transport, `macro_song_skeleton`, and lyric writing. | inherit |
| `composer` | Melody/harmony/rhythm: tracks, instruments (creation), MIDI clips, notes, quantize/humanize/groove, and the local AI song-generation pipeline. | sonnet |
| `arranger` | Song structure: markers, tempo/meter map, bar insert/delete, clip layout across the timeline, take comping. | sonnet |
| `sound-designer` | Instrument selection/tuning, sound banks, sample libraries, effect chains and their parameters. | sonnet |
| `mix-engineer` | Levels/pans/sends/buses, sidechain, automation lanes, the master chain, loudness analysis. | sonnet |
| `finisher` | Renders: mixdown, stems, bounce-in-place, loudness measurement/verification. | sonnet |

### Skills (`skills/`)

| Skill | What it does |
|---|---|
| `/daw-pro-music-team:daw-status` | First-run diagnostic: is the app reachable, which AI providers are configured, what's already in the project. Run this first. |
| `/daw-pro-music-team:new-song` | Full song from a brief: plan → tracks/instruments → parts per section → mix pass → loudness check. Orchestrates every agent above. |
| `/daw-pro-music-team:arrange` | Build or rework the arrangement from a structure description, via `arranger`. |
| `/daw-pro-music-team:mix-check` | Read the mix state, analyze balance/tone/loudness, report issues, apply agreed fixes via `mix-engineer`. |
| `/daw-pro-music-team:bounce` | Render a mixdown and/or stems with a loudness-verification gate, via `finisher`. |
| `daw-wire-reference` | Not a runnable command — the shared reference every agent/skill above preloads: tool naming, id-capture rules, units, etiquette, and safety policy. Read `skills/daw-wire-reference/SKILL.md` directly if you want the full rules. |

## How a user installs and runs `/new-song`

```
$ claude --plugin-dir ./claude-plugin
> /daw-pro-music-team:daw-status
  [confirms the app is reachable, reports provider status and current project state]
> /daw-pro-music-team:new-song write me an upbeat 3-minute pop song about
  starting over, roughly 120 BPM, with a big anthemic chorus
  [producer plans structure and scaffolds the session, delegates composing to
   composer, sound design to sound-designer, structure touch-ups to arranger,
   balance to mix-engineer, and the final bounce + loudness check to finisher]
```

## Port override

If DAW Pro's control server is running on a non-default port (set in the
app's Settings panel), export `DAW_CONTROL_PORT` before launching Claude
Code:

```sh
export DAW_CONTROL_PORT=17601
claude --plugin-dir ./claude-plugin
```

Every agent's `app_connection_info` tool call reports which port and
source (`environment` / `settings` / `default`) it's actually using, so
`/daw-pro-music-team:daw-status` is the fastest way to confirm the override
took effect.

## Troubleshooting

- **"connection refused" / any tool call fails immediately** — DAW Pro
  isn't running, or is running on a different port than this session
  expects. Launch the app (or `swift run DAWApp`), or set
  `DAW_CONTROL_PORT` to match. Run `/daw-pro-music-team:daw-status` to
  confirm.
- **A `generate_*`/`ai_write_lyrics`/`generate_song_suno` call errors about
  a missing provider** — that provider's API key isn't set. Set it in the
  app's Settings panel (⌘,) or as an environment variable
  (`ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`SUNO_API_KEY`) before restarting
  the MCP server (it reads `process.env` once, at startup — a key set
  after Claude Code is already running won't take effect until you
  reconnect). No agent in this plugin will ever ask you to paste a key
  into chat.
- **`ai_sidecar_*` / local song generation reports `notInstalled`** — run
  `scripts/ace-step/install.sh` from the repo (a one-time large download);
  this is unrelated to any API key.
- **A tool call in an agent's transcript names an id you don't recognize**
  — every id is minted by the app and returned from a prior call
  (`track_add`, `clip_add_midi`, `fx_add`, etc.) or discoverable via
  `project_overview`/`project_snapshot`; no agent should ever be guessing
  one. If you see a guessed id, that's a bug — file it.
- **You edited `mcp-server/src/` and the plugin's behavior didn't change**
  — `server/index.mjs` is a generated snapshot, not a live link to
  `mcp-server/src/`. Regenerate it (see "Developing this plugin" below)
  after every `mcp-server/` change, or the plugin keeps running the old
  bundle.

## Developing this plugin

`claude-plugin/server/index.mjs` is a **generated artifact** — a single
self-contained ES module produced by bundling `mcp-server/src/index.ts` (and
everything it imports, including `@modelcontextprotocol/sdk`,
`@anthropic-ai/sdk`, `openai`, and `zod`) with [esbuild](https://esbuild.github.io/).
Its first line carries a banner saying as much; don't hand-edit it.

After changing anything in `mcp-server/src/`, regenerate the bundle:

```sh
cd mcp-server
npm install         # once, or after dependency changes — installs esbuild etc.
npm run bundle:plugin
```

This runs `esbuild src/index.ts --bundle --platform=node --format=esm
--target=node22 --outfile=../claude-plugin/server/index.mjs`, producing one
~1.7 MB standalone `.mjs` file with no `node_modules` dependency at runtime.
ESM (not CommonJS) is deliberate: the source uses `import.meta.url` (for
`generate_image`'s asset-path resolution), which only survives bundling
correctly in ESM output — a CJS bundle silently empties it out. Commit the
regenerated `server/index.mjs` alongside your `mcp-server/src/` change so
the plugin and the source it was built from never drift apart.

The plugin's own `mcp-server/package.json` changes are limited to this: an
additive `esbuild` devDependency and the `bundle:plugin` script (plus the
`package-lock.json` update from `npm install`) — no `src/` changes, and the
normal `npm run build`/`npm test` workflow for the MCP server itself is
untouched.

## What this plugin does not do

It does not modify `mcp-server/src/`, `Sources/`, `Tests/`, `docs/`, or the
app's control-protocol wire — it is packaging and prompts, plus a generated
build artifact of the unmodified source. If a DAW Pro command needs a new
MCP tool, that change belongs in `mcp-server/src/` (see the repo's own
`CLAUDE.md` and `docs/AI-INTEGRATIONS.md`), followed by a
`npm run bundle:plugin` regeneration here — not a direct edit to
`server/index.mjs`.
