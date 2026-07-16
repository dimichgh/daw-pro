---
name: ui-polish-audit
description: Sweep the app window through multiple sizes and densities, capture every surface, and pixel-review for alignment/clipping/overlap defects. Use for user-reported "minor UI issues", before UI milestone close-outs, and after layout-affecting changes.
---

# UI Polish Audit

Systematic hunt for the layout-defect class individual feature gates miss: misalignment, clipping, overlap, and drift while the main window resizes. Motivated by user feedback 2026-07-15 ("a lot of minor issues in UI, element alignment during resizing of the main window").

## Procedure

1. **Build + launch staging** (never the dist bundle, never port 17600):
   `swift build`, then `env DAW_CONTROL_PORT=17695 nohup .build/debug/DAWApp > <session-scratchpad>/ui-audit/app.log 2>&1 &`. Wait for the port with an until-loop that contains `/bin/sleep 1`.
2. **Normalize state**: `project.new` first (foreign-content law — staging windows appear on the user's screen and may have been touched). Then load a representative project: COPY an era bundle to the scratchpad and open the COPY (era bundles are law anchors; never open originals interactively). Ensure enough tracks/clips that both columns scroll.
3. **Resize sweep** via AppleScript (`osascript -e 'tell application "System Events" to set size of front window of process "DAWApp" to {W, H}'`) through at least: 1200×760, 1440×900, 1728×1080, and the largest size the display allows. After EACH resize, `debug.captureUI` of ARRANGE and MIX, in BOTH Simple and Pro density. If a defect only shows *during* resize, capture between two half-steps.
4. **Pixel review — every frame, personally.** Look for: clipped/truncated labels; overlapping elements; pinned ruler block vs lanes losing horizontal beat alignment; mixer strips overflowing or with uneven gaps; transport-bar collisions at narrow widths; splitter/panel remnants; spacing that violates docs/DESIGN-LANGUAGE.md.
5. **File findings** as a numbered checklist: `view : symptom : capture path : suspected file`. Reproduce each finding in a capture BEFORE fixing — never fix blind.
6. **Fix + re-sweep**: repeat the identical sweep after fixes; every finding gets a before/after capture pair. For pinned regions, CoreGraphics band-hash (SHA of the band) catches drift the eye misses (m13-g G3 precedent).

## Laws

- Staging port 17695 only. Kill only via `PIDS=$(pgrep -x DAWApp); [ -n "$PIDS" ] && kill $PIDS` — never `pkill -f`, never the dist path.
- All captures under the SESSION scratchpad.
- An empty scan/capture result is UNPROVEN until stderr has been seen (rtk silent-empty trap family).
- Findings the cycle can't fix become explicit roadmap follow-ups — never silently dropped.
