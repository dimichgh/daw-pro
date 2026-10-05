# DAW Pro — Project Constitution

A professional, AI-native digital audio workstation for macOS. Goal: the feature depth of Logic Pro with a radically simpler, more intuitive experience, and **full AI control via MCP** so agents can compose, arrange, mix, and master.

## Stack

- **App**: Swift 6, SwiftUI, macOS 14+. Custom Canvas/Metal rendering for meters, waveforms, glowing indicators.
- **Audio**: `DAWEngine` wraps AVAudioEngine/CoreAudio behind `AudioEngineControlling` (`Sources/DAWCore/EngineProtocol.swift`). AudioUnit (AUv2/v3) hosting for instruments & effects. Real-time-safe code: no allocation, locks, or ObjC dispatch on the render thread.
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

## This machine (measured, not assumed)

Three quirks that have each produced a **confident wrong answer** here, not merely an error. They share one shape, and the shape matters more than the list: **a tool that never ran and a tool that ran and found nothing produce identical output.**

- **There is no `timeout(1)`.** It is GNU coreutils; this is macOS and `gtimeout` is not installed. `timeout 60 grep …` does not run a time-limited grep — it fails with `command not found`.
- **`scripts/video/` is ~66 GB, `scripts/ace-step/` ~56 GB, `scripts/rvc/` ~1.7 GB.** A bare `grep -r … scripts/` hangs. Always `--exclude-dir=video --exclude-dir=ace-step --exclude-dir=rvc --exclude-dir=node_modules`, or name the files. ⚠️⚠️ **THIS MITIGATION ITSELF ROTTED AND THE ROTTED FORM STILL HANGS.** It listed only ace-step/rvc/node_modules until 2026-09-19, when `scripts/video/` — the narrated-film output, which grew *after* the line was written and is now the LARGEST directory in the repo — made the documented-correct command hang anyway. I then mis-diagnosed that hang as macOS grep ignoring `--exclude-dir` after the operand, and was about to record that as a law; moving the flags before the path hung too, which is what killed the hypothesis. **A mitigation is a measurement with an expiry date: when the documented fix does not work, `du -sh */ | sort -rh` before theorising about the tool.**
- **`ffmpeg -v error` suppresses `ebur128`/`astats` summaries**, which log at INFO. Use `-hide_banner` when those numbers are the point.

⚠️ **The rule that covers all three: never pair `2>/dev/null` with a command whose EMPTINESS you intend to interpret.** The redirect turns a loud failure into a quiet, clean, wrong negative. Combined with `timeout` above, that pairing produced two false conclusions in a single session — including "this file has no writers" about a file with three.

⭐ **And when an absence CONFIRMS your hypothesis, that is exactly when to positive-control it** — run the same command shape against something you know exists, and show it can return non-zero. A negative result from a hand-built probe is the weakest evidence there is.

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
| Architecture, cross-module design, RT-safety review | `daw-architect` | opus |
| RT audio, DSP algorithms | `audio-dsp-engineer` | opus |
| App features, SwiftUI, custom controls/design | `swift-app-engineer`, `ui-design-engineer` | opus |
| MCP tools, AI-service clients, control protocol | `mcp-integration-engineer` | sonnet |
| Research, competitive analysis | `research-analyst` | sonnet |
| Tests, verification, regressions | `qa-test-engineer` | sonnet |
| Docs, changelog, README upkeep | `docs-scribe` | haiku |

Model tiers, current as of 2026-07: `opus` = Claude Opus 5 — the top tier for this project's work (deep reasoning, agentic and long-horizon coding, RT-safety review), at half Fable 5's price; every design and implementation agent runs here. `sonnet` = Claude Sonnet 5 — narrow, test-gated, well-specified lanes (MCP/wire plumbing, test authoring, research) where a weaker model fails loudly rather than silently. `haiku` = Claude Haiku 4.5 (there is no Haiku 5). No agent is pinned to `fable` (Claude Fable 5): it stays reachable per-call as a model override when one design decision is expensive enough to want a second, differently-shaped opinion.

**Delegation is the default, not the exception.** When a roadmap item names a route (`Route: audio-dsp-engineer`, etc.) that is an instruction — spawn the agent rather than doing it in the main context. Creating new agents (`.claude/agents/`), skills (`.claude/skills/`), or tools is authorised whenever the work calls for one that doesn't exist yet. This does **not** relax anything else: verify an agent's work independently rather than trusting its report, and brief each agent on the standing constraints its task can reach (commits only on the user's word, control port 17600 is the user's live app, no `git checkout/stash/restore/clean`, never touch user audio devices or `.env`).

Autonomous development: run the `/dev-cycle` skill (optionally under `/loop`) — it picks the next roadmap item, plans, delegates to the right agent, tests, and updates the roadmap.

**Pausing is not cancelling.** When the user interrupts, that is a **pause** — work already done stays and remains **authorised**. Never revert it, discard it, mark it "unauthorised", or mark items blocked on a ruling the user was never asked for. Run `/pause-till-continue` to hold cleanly: it cancels every scheduled job immediately so nothing self-resumes, **lets any running agent finish rather than killing it** (the pause isn't complete until it does), then releases staging and the ACE sidecar and records an exact resume point. `/pause-till-continue NOW` is the only form that aborts a running agent — and even then its partial work is kept and stays authorised. Only `/dev-cycle` or the user saying "continue" resumes the work. This rule exists because an interrupted delegation was once logged as cancelled, which froze four roadmap items — and a live user-facing bug — behind a question the user had never been asked.
