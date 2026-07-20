---
name: arrange
description: Build or rework a DAW Pro song's arrangement from a structure description (e.g. "intro, verse, chorus, verse, chorus, bridge, chorus, outro" or "add an 8-bar build before the drop"). Use when the user describes a section layout change, not new musical content.
---

# /arrange — build or rework the arrangement

This skill delegates structural work to the **arranger** agent (see
`agents/arranger.md` and the shared `daw-wire-reference` skill for the
tools and units it uses). Use it when the ask is about SHAPE (sections,
bar counts, transitions, take comping) rather than new notes, sounds, or
mix balance.

## Steps

1. **Orient.** Have `arranger` call `project_overview` and `marker_list`/
   `tempo_map` to see the current structure before changing anything. If
   the project has no markers yet and the user described a structure from
   scratch, place markers for every named section first (`marker_add`) so
   the rest of the work — and any later agent — can navigate by name.

2. **Reconcile the requested structure against what exists.**
   - A brand-new layout on an empty/near-empty project: consider whether
     `producer`'s `macro_song_skeleton` (a different agent/tool) would be a
     faster starting point than hand-building bar-by-bar — if so, suggest
     routing back through `/new-song` or delegating that one step to
     `producer` first.
   - Growing/shrinking a section on an EXISTING arrangement with real
     content: use `arrange_insert_bars`/`arrange_delete_bars` at the right
     bar (found via `marker_list`), never by hand-moving every clip.
   - Reordering/duplicating a section (e.g. "repeat the chorus once more"):
     `clip_duplicate` each of that section's clips into the new slot, then
     `marker_add` a matching marker if it's a genuinely new section
     instance.

3. **Smooth the joins.** Wherever a structural edit creates a new adjacency
   between audio clips, use `clip_crossfade` (or `clip_set_fades` on a
   single clip's edge) so nothing clicks or bumps in volume.

4. **Confirm the shift didn't break anything.** Re-read `project_overview`
   after a bar insert/delete — clips, markers, and the tempo/meter map
   should all have shifted together. `arrange_delete_bars` refuses a cut
   that would leave a meter change off its barline; if it does, delete
   within one meter region instead of across the boundary.

5. **Report** the new section layout (names + beat ranges) back to the
   user, and to `producer`/other agents if this was part of a larger
   delegated task.

Confirm with the user before any bar DELETE that would remove real musical
content — `edit_undo` reverts the whole operation in one step if needed,
but check first rather than relying on undo as the safety net.
