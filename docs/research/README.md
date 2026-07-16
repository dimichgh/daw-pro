# Research

Output directory for `/research` sprints and the `research-analyst` agent.

Naming: `YYYY-MM-DD-topic.md`. Every doc ends with an **Actionable takeaways** section that feeds ROADMAP items or ARCHITECTURE decisions.

Standing questions (pick these up first):
- Competitive feature matrix: Logic Pro 11 / Ableton Live 12 / FL Studio / Cubase — what "pro suite" means in 2026, what beginners struggle with most.
- AU hosting details: AUv3 out-of-process hosting, entitlements, plugin UI embedding in SwiftUI.
- Time-stretch library options and licensing (élastique / RubberBand / signalsmith).
- Sample-accurate sequencing patterns on AVAudioEngine vs custom render callback.
- ACE-Step-1.5 ops: measured generation speed + peak memory on this M5 Max, packaging/auto-start UX for the sidecar, model download flow.

Answered:
- ~~Suno official API~~ — none exists publicly (2026-07-05); pivoted to local ACE-Step-1.5 → `2026-07-05-ace-step-local-song-generation.md`.
- ~~DiffSinger-class local singing synthesis~~ — superseded: ACE-Step-1.5 sings, locally.
- ~~SFZ / DecentSampler `.dspreset` import feasibility (m18-h)~~ — DONE both halves: format research
  (opcode census, `.dspreset` survey, licensing) → `2026-07-16-spike-sfz-dspreset-formats.md`;
  mapping design + estimate → `2026-07-16-spike-sfz-dspreset-design.md` (**GO**, 10–11 days across
  four proposed items: selection dimension, per-zone scalars/ADSR, SFZ importer, `.dspreset` importer).
