# DAW Pro — Project Constitution

A professional, AI-native digital audio workstation for macOS. Goal: the feature depth of Logic Pro with a radically simpler, more intuitive experience, and **full AI control via MCP** so agents can compose, arrange, mix, and master.

## Stack

- **App**: Swift 6, SwiftUI, macOS 14+. Custom Canvas/Metal rendering for meters, waveforms, glowing indicators.
- **Audio**: `DAWEngine` wraps AVAudioEngine/CoreAudio behind the `AudioEngineProtocol`. AudioUnit (AUv2/v3) hosting for instruments & effects. Real-time-safe code: no allocation, locks, or ObjC dispatch on the render thread.
- **Control plane**: `DAWControl` runs a WebSocket JSON command server (default `ws://127.0.0.1:17600`). Every user-facing operation must be invokable through it — this is what makes the app AI-controllable and E2E-testable.
- **MCP**: `mcp-server/` (TypeScript, `@modelcontextprotocol/sdk`, stdio) exposes the DAW to AI agents; it bridges to the app over the control WebSocket and calls Anthropic/OpenAI/Suno APIs directly for generation tasks.
- **AI services**: Anthropic + OpenAI (lyrics, naming, music-theory reasoning), **ACE-Step-1.5 local sidecar** (full-song/sung-vocal generation, FastAPI on 127.0.0.1:8001; Suno is a dormant cloud fallback), GPT Image (UI asset generation). Keys via `.env` / environment — never hardcode, never commit.

## Layout

| Path | What |
|---|---|
| `Sources/DAWCore` | Pure domain model: project, tracks, clips, transport, mixer. No UI, no audio I/O. |
| `Sources/DAWEngine` | Real-time audio: graph, playback, metering, (later) AU hosting, rendering. |
| `Sources/DAWControl` | WebSocket control server + JSON command protocol. |
| `Sources/AIServices` | Anthropic / OpenAI / Suno clients behind provider protocols. |
| `Sources/DAWApp` | SwiftUI app shell, design system, views. |
| `Tests/` | Swift Testing (`import Testing`) suites. |
| `mcp-server/` | MCP server (TypeScript). |
| `docs/` | VISION, ARCHITECTURE, ROADMAP, AI-INTEGRATIONS, DESIGN-LANGUAGE, research/. |
| `scripts/` | Dev tooling (asset generation, etc.). |

## Commands

- Build: `swift build`
- Test: `./scripts/test.sh` (NOT bare `swift test` — the wrapper adds Testing.framework paths needed on machines with only Command Line Tools)
- Run app (dev): `swift run DAWApp`
- MCP server: `cd mcp-server && npm install && npm run build && node dist/index.js`

Full Xcode (not just Command Line Tools) is required for app bundling, code signing, and AUv3 hosting entitlements — check with `xcodebuild -version` before working on those areas.

## Conventions

- Swift 6 strict concurrency. UI + model mutation on `@MainActor`; the audio render path touches no actors.
- Domain logic goes in `DAWCore` and must stay UI-free and engine-free so it's testable headless.
- Every new user-facing capability ships with: a control-protocol command, an MCP tool exposing it, and a test.
- Design follows `docs/DESIGN-LANGUAGE.md` — dark glass cockpit, neon-glow indicators, generous spacing, beginner-readable labels. No stock AppKit-gray utility panels.
- Update `docs/ROADMAP.md` checkboxes when a milestone item lands.

## Agent routing (who does what)

Use the specialized agents in `.claude/agents/`. Route by domain and complexity to optimize cost:

| Work | Agent | Model |
|---|---|---|
| Architecture, RT audio, DSP algorithms | `daw-architect`, `audio-dsp-engineer` | fable |
| App features, SwiftUI, custom controls/design | `swift-app-engineer`, `ui-design-engineer` | opus |
| MCP tools, AI-service clients, control protocol | `mcp-integration-engineer` | sonnet |
| Research, competitive analysis | `research-analyst` | sonnet |
| Tests, verification, regressions | `qa-test-engineer` | sonnet |
| Docs, changelog, README upkeep | `docs-scribe` | haiku |

Autonomous development: run the `/dev-cycle` skill (optionally under `/loop`) — it picks the next roadmap item, plans, delegates to the right agent, tests, and updates the roadmap.
