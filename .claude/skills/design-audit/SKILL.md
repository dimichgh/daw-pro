---
name: design-audit
description: Audit the app UI against docs/DESIGN-LANGUAGE.md (glass cockpit rules) — semantic accent colors, SF Mono readouts, glow recipe, Simple/Pro modes, no stock-gray controls. Use before checking off UI roadmap items or after UI-heavy changes.
---

# Design Audit

1. Read `docs/DESIGN-LANGUAGE.md` (the contract) and enumerate its testable rules.
2. Spawn `ui-design-engineer` to sweep `Sources/DAWApp/` for violations. Mechanical checks to include:
   - Raw `Color(red:…)`/hex literals outside `Theme.swift` (all color goes through theme tokens)
   - Numeric readouts not using the theme's mono/digital text style
   - Accent misuse (cyan for non-playback, violet for non-AI, etc.)
   - Stock unstyled controls (`Button`/`Slider`/`Toggle` without theme styles) in main-window views
   - Per-frame allocation in Canvas/TimelineView drawing closures
3. If a display is available, `swift run DAWApp`, screenshot the main window (`screencapture -x`), and judge the result against the doc's intent — density, glow discipline, readability.
4. Output: file:line violation list with concrete fixes, ordered by visual impact. Apply mechanical fixes directly; leave judgment calls as a short proposal.
