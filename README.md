# DAW Pro

A professional, AI-native digital audio workstation for macOS. Logic-class ambitions, a glass-cockpit interface a beginner can read, and **full AI control via MCP** — agents can compose, arrange, and mix through the same command surface the UI uses.

> Project vision: [docs/VISION.md](docs/VISION.md) · Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md) · User Guide: [docs/USER-GUIDE.md](docs/USER-GUIDE.md) · Features: [docs/FEATURES.md](docs/FEATURES.md)

## Status

**M0 — Foundation** (current): SwiftUI app shell with the glass-cockpit theme, working audio engine with live output metering and test tone, loopback WebSocket control plane, and a 15-tool MCP server. Multitrack playback is next (M1).

## Quickstart

Prerequisites: macOS 14+, Swift 6 toolchain, Node ≥ 22. Full Xcode is only needed later (AU hosting, signing).

```bash
# Run the app
swift run DAWApp

# Run tests
./scripts/test.sh

# Build the MCP server
cd mcp-server && npm install && npm run build
```

To let an AI agent drive the DAW: start the app, then connect any MCP client using [.mcp.json](.mcp.json) (Claude Code picks it up automatically from the repo root). Try: *"take a project snapshot, add a drum track at 96 BPM, and press play."*

AI features (lyrics, Suno song generation, GPT Image assets) need keys — copy `.env.example` to `.env` and fill in what you have.

## Layout

| Path | What |
|---|---|
| `Sources/DAWCore` | Headless domain model — tracks, clips, transport, the `ProjectStore` command surface |
| `Sources/DAWEngine` | Real-time audio (AVAudioEngine), metering, test tone; AU hosting to come |
| `Sources/DAWControl` | Loopback WebSocket control server — the protocol MCP and tests drive |
| `Sources/AIServices` | Anthropic / OpenAI / Suno clients behind provider protocols |
| `Sources/DAWApp` | SwiftUI app — glass-cockpit theme, transport, meters |
| `mcp-server/` | TypeScript MCP server ([its README](mcp-server/README.md)) |
| `.claude/agents/` | Specialized dev agents (architect, DSP, app, UI, MCP, research, QA, docs) |
| `.claude/skills/` | Dev workflows: `/dev-cycle`, `/research`, `/audio-verify`, `/mcp-verify`, `/design-audit`, `/generate-assets` |

## Autonomous development

This repo is built to be developed by AI agents under human direction. `CLAUDE.md` is the constitution; the agent fleet routes work by domain and model tier (fable for architecture/DSP, opus for app/UI, sonnet for integrations/QA/research, haiku for docs). One iteration:

```
/dev-cycle        # picks the next roadmap item, plans, implements, verifies
```

Run it under `/loop` for continuous autonomous progress.
