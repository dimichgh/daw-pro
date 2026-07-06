# Vision

**DAW Pro**: a professional macOS DAW with Logic-class depth, an interface a beginner can read, and an AI agent as a first-class operator.

## Pillars

1. **Pro-grade core.** Real multitrack audio + MIDI, AudioUnit hosting, a serious built-in FX/instrument suite (EQ, compressor, reverb, delay, limiter, saturator, sampler, synth), automation, time-stretch, comping, stem export. No toy shortcuts in the audio path.
2. **AI-native, not AI-bolted-on.** Every operation the user can do, an agent can do through MCP. Compose, arrange, mix, master, and iterate conversationally. Lyrics via Anthropic/OpenAI; full generated tracks and sung vocals via a **local ACE-Step-1.5 engine** (MIT-licensed, runs on this Mac), imported as editable stems/tracks.
3. **The glass cockpit.** A dark, glass-and-glow design language: digital readouts, neon level meters, oscilloscope accents. Beautiful, but information-dense the way an aircraft cockpit is — everything glowing means something.
4. **Radically understandable.** Logic and Pro Tools are powerful and hostile to newcomers. We use plain-language labels, progressive disclosure (Simple ↔ Pro views per panel), and an "Explain this" affordance on every control (AI-powered).

## Novelty bets

- **Copilot rail**: a persistent AI sidebar that sees the session state (via the same control API MCP uses) and can act — "tighten the drums", "give me a darker pad on track 3", "master this for streaming loudness".
- **Generative sketchpad**: describe a song → the local ACE-Step engine generates candidates (no cloud, no cost per try) → one click imports as stems onto tracks, tempo-mapped, ready to edit. The DAW as an editor of generated material, not just recorded material.
- **Session vibe meter**: live spectral/loudness/energy visualization of the whole mix as a single glowing instrument — novel, useful, and a signature visual.
- **Every control is scriptable**: the control protocol is public; power users can drive the DAW from anything, not just our MCP server.

## Non-goals (for now)

- Windows/Linux ports.
- Training our own music/voice models (we run ACE-Step-1.5 locally for singing/song generation — see AI-INTEGRATIONS).
- VST hosting (AudioUnits cover the macOS ecosystem; revisit if demand appears).

## Success criteria

A musician can go from empty project to a mixed, mastered, partially AI-generated song without leaving the app — and an AI agent can do the same thing end-to-end over MCP with no human clicks.
