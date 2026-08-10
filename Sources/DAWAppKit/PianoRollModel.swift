import CoreGraphics
import Foundation
import Observation
import DAWCore

/// Grid snap resolution for the piano roll, in beats. Values are named
/// musically relative to the quarter-note beat: `bar` = 4 beats, `beat` = 1,
/// `eighth` = 1/2 beat, `sixteenth` = 1/4 beat, down to `sixtyFourth` = 1/16
/// beat, with triplet variants interleaved coarsest→finest (m21-c — the
/// `QuantizeModel.grids` ordering, so the two pickers read the same way):
/// `eighthTriplet` = 1/3 beat, `sixteenthTriplet` = 1/6 beat. `off` disables
/// snapping. Labels are beginner-first ("Bar"/"Beat") for the low resolutions,
/// musical fractions for the fine ones (docs/DESIGN-LANGUAGE.md rule 6); the
/// "T" suffix marks a triplet feel. Raw values name the cases for any future
/// wire/persistence use — additive only, never renamed.
public enum SnapResolution: String, CaseIterable, Sendable {
    case off
    case bar
    case beat
    case eighth
    case eighthTriplet
    case sixteenth
    case sixteenthTriplet
    case thirtySecond
    case sixtyFourth

    /// Grid size in beats, or nil when snapping is off. Triplets are the
    /// 2/3-scaled values (three even notes in the straight pair's span —
    /// the `QuantizeSettings.gridBeats` convention).
    public var beats: Double? {
        switch self {
        case .off: nil
        case .bar: 4
        case .beat: 1
        case .eighth: 0.5
        case .eighthTriplet: 1.0 / 3.0
        case .sixteenth: 0.25
        case .sixteenthTriplet: 1.0 / 6.0
        case .thirtySecond: 0.125
        case .sixtyFourth: 0.0625
        }
    }

    /// Chip / menu label.
    public var label: String {
        switch self {
        case .off: "Off"
        case .bar: "Bar"
        case .beat: "Beat"
        case .eighth: "1/8"
        case .eighthTriplet: "1/8T"
        case .sixteenth: "1/16"
        case .sixteenthTriplet: "1/16T"
        case .thirtySecond: "1/32"
        case .sixtyFourth: "1/64"
        }
    }
}

/// Where inside a note a point landed — used to route a drag to move vs resize.
public enum NoteZone: Sendable, Equatable {
    case body
    case resizeHandle
}

/// All piano-roll geometry and edit logic, kept UI-free so it unit-tests
/// headless (Sources/DAWAppKit) while the SwiftUI views (PianoRollView,
/// KeyboardSidebar, VelocityLane) stay thin over it. Edits mutate a local
/// `draft` array; the view submits `buildSubmission()` through
/// `ProjectStore.setClipNotes` on gesture END only — never per drag tick.
///
/// Coordinate space (content coordinates, before scrolling):
///  - x grows right with beats: `x = beat * pixelsPerBeat`.
///  - y grows down as pitch FALLS: row 0 (top) is pitch 127, so a piano-roll
///    reads high-notes-up like a keyboard on its side.
@MainActor
@Observable
public final class PianoRollModel {
    // MARK: Layout constants

    /// Default horizontal scale — the roll's historical fixed 32 pt/beat. The
    /// LIVE scale is zoomable (m21-c): the view feeds `pixelsPerBeat` from the
    /// persisted `PanelLayoutStore.pianoRollPPB` slot, clamped by
    /// `PianoRollZoom` (the `ArrangeZoom` sibling — and the nonisolated home
    /// of this constant).
    public static let defaultPixelsPerBeat: CGFloat = PianoRollZoom.defaultPixelsPerBeat
    /// One semitone row's height.
    public static let defaultRowHeight: CGFloat = 14
    /// MIDI pitches 0...127 → 128 rows. `nonisolated` so the pitch↔y affine mapping
    /// can be reproduced inside `@Sendable` Canvas renderers (m16-a) — it is a
    /// compile-time constant, never actor state.
    public nonisolated static let pitchCount = 128
    /// Grab zone on a note's right edge that means "resize" not "move".
    public static let resizeHandleWidth: CGFloat = 8

    public var pixelsPerBeat: CGFloat
    public var rowHeight: CGFloat

    // MARK: Edit state

    /// The working note list. Every interaction mutates this; the view reads it
    /// to draw and submits it on gesture end.
    public var draft: [MIDINote]
    /// Currently selected note ids.
    public var selection: Set<UUID> = []
    /// Clip length in beats — defines the grid's drawn width.
    public var clipLengthBeats: Double

    /// Per-note snapshot captured at the start of a move drag so each tick maps
    /// the raw translation off the original position (no accumulated drift).
    @ObservationIgnored private var moveBaseline: [UUID: (pitch: Int, startBeat: Double)] = [:]
    /// The note the pointer grabbed — the gesture's ANCHOR (m23-ek-2). Its
    /// absolute start is the ONE thing that snaps; everything else in the
    /// selection translates by the delta that produced it. Captured by
    /// `beginMove(anchorID:)`, read by `moveSelection`.
    @ObservationIgnored private var moveAnchorID: UUID?

    public init(
        notes: [MIDINote] = [],
        clipLengthBeats: Double = 4,
        pixelsPerBeat: CGFloat = PianoRollModel.defaultPixelsPerBeat,
        rowHeight: CGFloat = PianoRollModel.defaultRowHeight
    ) {
        self.draft = notes
        self.clipLengthBeats = max(0, clipLengthBeats)
        self.pixelsPerBeat = pixelsPerBeat
        self.rowHeight = rowHeight
    }

    /// Replaces the draft with a clip's notes and clears selection. Called when
    /// the panel switches to a different clip (never mid-gesture).
    public func load(notes: [MIDINote], clipLengthBeats: Double) {
        self.draft = notes
        self.clipLengthBeats = max(0, clipLengthBeats)
        self.selection = []
        self.moveBaseline = [:]
        self.moveAnchorID = nil
    }

    // MARK: - External-mutation reseed seam (m18-i)

    /// True when an incoming clip VALUE no longer matches what this model
    /// represents — the observation seam for wire/arrange-side geometry
    /// mutations (`clip.trim`/`move`/`split`, arrange bar ops, undo/redo of
    /// any) landing while the editor is open on the SAME clip identity
    /// (m18-i; `.id(clip.id)` only recreates the view on an identity switch).
    /// Compares content + geometry, never identity: notes compare in the
    /// store's canonical order (`MIDINote.canonicallyOrdered` — every draft
    /// note already passed the clamping `MIDINote.init`, so the store's
    /// re-clamp is a no-op) and the clip length through the same `max(0,·)`
    /// the seed applies. The IDEMPOTENCE GUARD falls out: the editor's own
    /// commit echoes back through `setClipNotes` re-ordered but content-equal,
    /// reads EQUAL here, and triggers no reseed — a double reseed would
    /// clobber selection and any in-flight gesture for nothing.
    public func needsReseed(notes: [MIDINote], clipLengthBeats: Double) -> Bool {
        if self.clipLengthBeats != max(0, clipLengthBeats) { return true }
        return MIDINote.canonicallyOrdered(draft) != MIDINote.canonicallyOrdered(notes)
    }

    /// Re-reads the model from an EXTERNALLY mutated clip — call only when
    /// `needsReseed` says so. Same re-read as `load`, except the selection
    /// keeps the notes that SURVIVED the mutation (an agent trimming over the
    /// wire must not strip a human's selection of untouched notes; dropped
    /// ids fall away so the selection never dangles). In-flight interaction
    /// resolves as CANCEL-THEN-RESEED (m18-i): the move baseline clears, so a
    /// mid-flight move drag becomes a no-op over the new content — the view
    /// additionally parks its gesture routing in a cancelled state so a
    /// resize can't reapply either. Never a half-dragged ghost on new truth.
    public func reseed(notes: [MIDINote], clipLengthBeats: Double) {
        let survivors = selection.intersection(notes.map(\.id))
        load(notes: notes, clipLengthBeats: clipLengthBeats)
        selection = survivors
    }

    // MARK: - Geometry

    public func x(forBeat beat: Double) -> CGFloat { CGFloat(beat) * pixelsPerBeat }

    public func beat(forX x: CGFloat) -> Double { Double(x / pixelsPerBeat) }

    /// Top y of a pitch's row. Row 0 (y = 0) is the highest pitch (127).
    public func y(forPitch pitch: Int) -> CGFloat {
        CGFloat(Self.pitchCount - 1 - pitch) * rowHeight
    }

    /// Pitch whose row contains `y`, clamped to 0...127.
    public func pitch(forY y: CGFloat) -> Int {
        let row = Int((y / rowHeight).rounded(.down))
        return (Self.pitchCount - 1 - row).clamped(to: MIDINote.pitchRange)
    }

    /// Full pitch-stack height (all 128 rows).
    public var contentHeight: CGFloat { CGFloat(Self.pitchCount) * rowHeight }

    /// Drawn grid width — the clip length, but never less than the furthest
    /// note end (out-of-clip notes stay visible; the model never trims them).
    public var contentWidth: CGFloat {
        let maxNoteEnd = draft.map(\.endBeat).max() ?? 0
        return CGFloat(max(clipLengthBeats, maxNoteEnd, 1)) * pixelsPerBeat
    }

    /// Width a horizontal editor band actually DRAWS at (m18-f — DESIGN-LANGUAGE
    /// "Wide windows"): the band's content width, extended to fill the editor
    /// viewport when the viewport is wider, so the grid always reaches the
    /// panel's right edge instead of leaving dead glass at wide windows. ONE
    /// definition shared by all three bands (note grid, velocity lane, and the
    /// controller canvas via its own model's content width). Honesty is
    /// preserved by the out-of-clip shade: the extension is shaded latent
    /// space — the playable window still ends at the clip end — and a note
    /// created there is the same legal-but-latent data the m18-e ghost rule
    /// recorded (store-legal, engine-windowed by strict `<`).
    public nonisolated static func drawnWidth(content: CGFloat, viewport: CGFloat) -> CGFloat {
        max(content, max(0, viewport))
    }

    /// The clip-relative beat where a note's AUDIBLE span ends under the
    /// engine's schedule rule, or nil when the note never sounds — THE ONE
    /// boundary definition for the m19-g note-pill ghost treatment, the
    /// note-grid sibling of `ControllerStripModel.playableCount`
    /// (DESIGN-LANGUAGE "Controller strips"). Engine truth
    /// (`MIDISchedule.buildEvents`): a note sounds iff its onset is strictly
    /// inside `[0, clipLengthBeats)` — strict `<`, an onset exactly AT the end
    /// is latent — and its note-off lands at `min(endBeat, clipLengthBeats)`,
    /// so a tail past the clip end is TRUNCATED, never sounded. Reading the
    /// result: `nil` = whole pill (and its VEL stem) ghosts; `< endBeat` =
    /// lit body to the boundary, ghost tail past it; `== endBeat` = fully
    /// lit. The Canvas draw sites call this — never re-derived beat math in a
    /// draw closure. `nonisolated` so `@Sendable` renderers can call it (pure
    /// value math, never actor state).
    public nonisolated static func playableEndBeat(
        of note: MIDINote, clipLengthBeats: Double
    ) -> Double? {
        guard note.startBeat < clipLengthBeats else { return nil }
        return Swift.min(note.endBeat, clipLengthBeats)
    }

    /// ⭐ THE ONE PRODUCER of a note's rectangle in content coordinates — the
    /// rect a CLICK hit-tests against, the rect a RUBBER BAND intersects, and
    /// (inset) the pill the Canvas draws.
    ///
    /// `max(3, …)` is a minimum HIT width, not a drawing flourish: it is what
    /// keeps a very short note clickable. At the default 32 px/beat a 1/64 note
    /// is 2 px wide and floors to 3, so ANY second spelling of this arithmetic
    /// disagrees with the click over a 1 px column — a note you can click but
    /// cannot band-select, or the reverse. That is why this is one `static` with
    /// three callers rather than three expressions that agree by luck (the m23-f
    /// finding; `ArrangeGroupDrag.swift:21-29` legislates the same rule one
    /// surface over).
    ///
    /// `nonisolated` is required, not stylistic: the `@Sendable` Canvas renderer
    /// (`PianoRollGrid.drawNotes`) needs this arithmetic and may not touch the
    /// model, exactly as `pitchCount` / `drawnWidth` / `playableEndBeat` already
    /// are for the same reason. It is pure value math, never actor state.
    public nonisolated static func noteRect(
        _ note: MIDINote, rowHeight: CGFloat, pixelsPerBeat: CGFloat
    ) -> CGRect {
        CGRect(
            x: CGFloat(note.startBeat) * pixelsPerBeat,
            y: CGFloat(pitchCount - 1 - note.pitch) * rowHeight,
            width: Swift.max(3, CGFloat(note.lengthBeats) * pixelsPerBeat),
            height: rowHeight
        )
    }

    /// A note's rectangle at THIS model's live scales — a one-line forwarder to
    /// `noteRect`, kept because it is what every call site inside the model
    /// reads naturally.
    public func rect(for note: MIDINote) -> CGRect {
        Self.noteRect(note, rowHeight: rowHeight, pixelsPerBeat: pixelsPerBeat)
    }

    /// Every drafted note's id paired with its HIT rect, in draft order — the
    /// input `PianoRollMarquee.hits` takes.
    ///
    /// The band gets its rects from HERE rather than being handed `draft` +
    /// `rowHeight` + `pixelsPerBeat`, and that is a deliberate constraint on the
    /// geometry type's signature: a `hits(band:notes:rowHeight:ppb:)` would
    /// FORCE the marquee to re-spell `max(3, …)` and `(127 - pitch) · rowHeight`
    /// inline, i.e. would make breaking the one-producer rule the path of least
    /// resistance. A rule cannot be enforced by a signature that rewards
    /// ignoring it.
    public func noteRects() -> [(id: UUID, rect: CGRect)] {
        draft.map { ($0.id, rect(for: $0)) }
    }

    // MARK: - Snap

    /// Snaps `beat` to the nearest grid line (>= 0). `off` passes the value
    /// through (still floored at 0).
    public func snap(beat: Double, resolution: SnapResolution) -> Double {
        guard let grid = resolution.beats, grid > 0 else { return max(0, beat) }
        return max(0, (beat / grid).rounded() * grid)
    }

    /// Length a freshly-added note gets: one grid cell, or 1 beat when snapping
    /// is off. This is the ADD default only — the resize floor is
    /// `minResizeLength` (m21-c untangled the two: the old shared value made a
    /// snap-off resize bottom out at a full beat, so an AI-authored 1/64 note
    /// was viewable but not editable).
    public func defaultLength(for resolution: SnapResolution) -> Double {
        resolution.beats ?? 1.0
    }

    /// The floor a resize can't go below: ONE grid step of the current snap, or
    /// the store's own `MIDINote.minLengthBeats` when snapping is off — the
    /// honest floor (m21-c): the store accepts far shorter notes than the old
    /// `defaultLength` floor implied, so short AI-authored notes must stay
    /// resizable, not merely viewable.
    public func minResizeLength(for resolution: SnapResolution) -> Double {
        resolution.beats ?? MIDINote.minLengthBeats
    }

    // MARK: - Hit testing

    /// Topmost note under `point` and which zone was hit, or nil for empty grid.
    /// The right `resizeHandleWidth` of a note (when it's wide enough to have a
    /// distinct body) is the resize handle; everything else is the body.
    public func hitTest(_ point: CGPoint) -> (id: UUID, zone: NoteZone)? {
        // Reverse so a later-drawn (visually on top) note wins an overlap.
        for note in draft.reversed() {
            let r = rect(for: note)
            guard r.contains(point) else { continue }
            if r.width > Self.resizeHandleWidth * 1.5,
               point.x >= r.maxX - Self.resizeHandleWidth {
                return (note.id, .resizeHandle)
            }
            return (note.id, .body)
        }
        return nil
    }

    // MARK: - Draft edits

    /// Adds a note at a snapped position with a one-grid-cell length and default
    /// velocity 100. Returns the new note (already in the draft).
    @discardableResult
    public func addNote(atBeat beat: Double, pitch: Int, resolution: SnapResolution) -> MIDINote {
        let note = MIDINote(
            pitch: pitch.clamped(to: MIDINote.pitchRange),
            velocity: 100,
            startBeat: snap(beat: beat, resolution: resolution),
            lengthBeats: defaultLength(for: resolution)
        )
        draft.append(note)
        return note
    }

    /// Replaces the WHOLE draft, dropping any selection id the new array no
    /// longer carries (m23-cq-1 — the step sequencer's write path).
    ///
    /// The sequencer is a second VIEW over this one draft, not a second store:
    /// `StepSequencerEdit.toggle` is a pure function from `[MIDINote]` to
    /// `[MIDINote]`, and this is how its answer lands here before the roll's own
    /// `commit()` submits it. That is what keeps ONE note store and ONE commit
    /// funnel behind both editors.
    ///
    /// **The selection prune is not tidiness.** The step grid draws no
    /// selection, so a note it removes could otherwise leave a dangling id in
    /// `selection` — and `selection` is what `PianoRollNoteSelectionBridge`
    /// publishes, i.e. what Edit ▸ Delete and the arrange's arrow-key nudge
    /// decide on. A selection naming notes that no longer exist would keep
    /// claiming keystrokes for content the user cannot see.
    public func replaceDraft(_ notes: [MIDINote]) {
        draft = notes
        selection = selection.intersection(notes.map(\.id))
    }

    /// Snapshots the selected notes' positions for a move drag, and fixes the
    /// gesture's ANCHOR. Call once at drag start, then `moveSelection` each tick.
    ///
    /// - Parameter anchorID: the note under the pointer. Defaults to nil, which
    ///   resolves to the earliest note in the selection (`startBeat`, then
    ///   `pitch`, then `id` — a TOTAL order, never `Set` iteration order, which
    ///   is unstable run to run). The default exists so a caller that has no
    ///   pointer (a test, a future menu-driven nudge) still gets a deterministic
    ///   rigid drag rather than a deformed one.
    public func beginMove(anchorID: UUID? = nil) {
        moveBaseline = [:]
        for note in draft where selection.contains(note.id) {
            moveBaseline[note.id] = (note.pitch, note.startBeat)
        }
        if let anchorID, moveBaseline[anchorID] != nil {
            moveAnchorID = anchorID
        } else {
            moveAnchorID = draft
                .filter { moveBaseline[$0.id] != nil }
                .min { a, b in
                    (a.startBeat, a.pitch, a.id.uuidString)
                        < (b.startBeat, b.pitch, b.id.uuidString)
                }?.id
        }
    }

    /// Moves every note in the move baseline by a raw (unsnapped) beat/pitch
    /// delta off its captured position — **RIGIDLY**. Length and velocity are
    /// preserved.
    ///
    /// ⭐ THE RULE (m23-ek-2), and it is `ArrangeGroupDrag`'s, applied to notes:
    /// **snapping and clamping are properties of the GESTURE, not of each note.**
    /// The note under the pointer is the ANCHOR; its absolute start snaps ONCE;
    /// the resulting delta translates every selected note. Clamps are computed
    /// ONCE over the whole selection and applied uniformly.
    ///
    /// ⚠️ WHAT THIS REPLACED, because it shipped and was wrong at scale. The
    /// pre-ek-2 body applied three PER-NOTE operations —
    /// `(base.pitch + deltaPitch).clamped(to:)`, `max(0, base.startBeat + delta)`
    /// and `snap(…)` on each note's own base — each of which is the m23-g2
    /// welding defect on a different axis:
    ///   1. per-note pitch clamp: drag a chord up into 127 and the top note
    ///      stops while the rest keep rising — INTERVALS COLLAPSE, a chord
    ///      becomes a cluster;
    ///   2. per-note beat floor: drag left past 0 and the notes pile up on 0 —
    ///      the rhythm is destroyed;
    ///   3. per-note snap: two notes at beats 0 and 0.5 under `.beat`, dragged
    ///      +0.1, land on 0 and 1 — the 0.5-beat gap becomes 1.0, silently.
    /// It was invisible because a selection was only reachable one shift-click
    /// at a time; the m23-ek-1 rubber band makes 40-note selections one gesture.
    ///
    /// ⭐ SINGLE-NOTE DRAGS ARE BYTE-IDENTICAL, which is what makes the fix
    /// cheap, and it is algebra rather than hope: with one note the anchor IS
    /// the note and IS the min and IS the max, so
    /// `base + max(d, -base)` = `max(base + d, 0)`; `snap` of that is exactly
    /// the old expression, and the post-snap re-clamp is a no-op because `snap`
    /// already floors at 0. The pitch range `(-minPitch)...(127 - maxPitch)`
    /// likewise collapses to `clamped(to: 0...127)` when min == max.
    /// `PianoRollModelTests` pins this across the whole snap ladder — and pins
    /// it through the SIX pre-existing single-note call sites that were
    /// deliberately NOT rewritten.
    ///
    /// ⚠️ WHY NOT `ArrangeGroupDrag.plan(…)` DIRECTLY: it snaps through
    /// `ClipEdit.movedStartBeat`, whose vocabulary is `ClipSnap` + `MeterMap`
    /// (bar/beat against a meter map). The roll snaps with `SnapResolution`,
    /// which carries 1/32, 1/64 and triplets that `ClipSnap` cannot express. A
    /// reuse would have to re-derive the grid on the way in — the duplicate
    /// computation that type's own doc forbids. The RULE is shared; the snap
    /// home is not.
    public func moveSelection(deltaBeats: Double, deltaPitch: Int, resolution: SnapResolution) {
        guard !moveBaseline.isEmpty else { return }
        let bases = moveBaseline.values
        // ── PITCH: one clamp for the whole group, so the shape survives the wall.
        let minPitch = bases.map(\.pitch).min() ?? 0
        let maxPitch = bases.map(\.pitch).max() ?? 0
        let pitchDelta = deltaPitch.clamped(to: (-minPitch)...(MIDINote.pitchRange.upperBound - maxPitch))
        // ── BEAT: floor the ASK once against the group, snap the ANCHOR once,
        // then re-clamp the RESULT uniformly.
        //
        // ⚠️ BOTH CLAMPS ARE LOAD-BEARING and neither subsumes the other. The
        // first keeps the anchor's snap decision measured against travel the
        // group can actually make. The second exists because a snap can round
        // the anchor DOWN past the floor that was just applied: notes at 0.2
        // (min) and 2.4 (anchor) under `.beat` with a raw −0.1 floor to −0.1,
        // put the anchor at 2.3, which snaps to 2 — an applied −0.4 that would
        // land the min note at −0.2. Re-clamping uniformly stops the GROUP at
        // the wall (min note exactly on 0) with the anchor left off-grid, which
        // is what "stops as a unit" means.
        let minStart = bases.map(\.startBeat).min() ?? 0
        let anchorBase = moveAnchorID.flatMap { moveBaseline[$0]?.startBeat } ?? minStart
        let askedDelta = max(deltaBeats, -minStart)
        let snappedAnchor = snap(beat: max(0, anchorBase + askedDelta), resolution: resolution)
        // ONE note's landing is computed EXACTLY and everything else translates
        // off it — never `base + (landing - base)`, which is not reliably
        // `landing` in binary floating point (0.2 + (2.2 − 2.4) is 2.8e-16, not
        // 0). A drag has to be byte-exact where the user can see it: on the note
        // that decided the gesture.
        //
        //  • normally that is the ANCHOR, landing on its snapped start — which
        //    is what makes a single-note drag byte-identical to the pre-ek-2
        //    expression, since one note is its own anchor;
        //  • when the WALL binds it is the EARLIEST note, landing exactly on
        //    beat 0. The wall binds when the anchor's snap rounds it DOWN past
        //    the floor already applied to `askedDelta` — notes at 0.25 and 2.5
        //    (anchor) under `.beat` with a raw −0.125 floor to −0.125, put the
        //    anchor on 2.375, which snaps to 2: an applied −0.5 that would land
        //    the earliest note at −0.25. Re-anchoring on the wall stops the
        //    GROUP there rigidly, with the anchor left off-grid, which is what
        //    "stops as a unit" means.
        let (referenceBase, referenceLanding): (Double, Double) =
            snappedAnchor < anchorBase - minStart
                ? (minStart, 0)
                : (anchorBase, snappedAnchor)
        let appliedDelta = referenceLanding - referenceBase
        for (id, base) in moveBaseline {
            guard let index = draft.firstIndex(where: { $0.id == id }) else { continue }
            let note = draft[index]
            draft[index] = MIDINote(
                id: id, pitch: base.pitch + pitchDelta, velocity: note.velocity,
                // Every note at the reference start takes the exact landing —
                // they are indistinguishable by construction, so there is no
                // choice to make between them.
                startBeat: base.startBeat == referenceBase
                    ? referenceLanding : base.startBeat + appliedDelta,
                lengthBeats: note.lengthBeats
            )
        }
    }

    // MARK: - Rubber band (m23-ek-1)

    /// Apply a rubber band's outcome to the selection: REPLACE with what the
    /// band touched, or UNION it onto the selection frozen when the band armed.
    ///
    /// The base is a parameter rather than model state because a marquee
    /// re-decides the WHOLE selection on every pointer update — growing the band
    /// adds notes and shrinking it gives them back — which is only possible
    /// against a frozen base. Reading the live selection instead would make each
    /// update compound the last, and an additive band could never give anything
    /// back (the `TimelineLanesView.updateMarquee` rule, one surface over).
    public func applyMarquee(hits: Set<UUID>, base: Set<UUID>, additive: Bool) {
        selection = additive ? base.union(hits) : hits
    }

    /// Resizes a note's right edge to a snapped end beat. Length can't fall
    /// below one grid step of the current snap (`minResizeLength` — with snap
    /// off, the store's `MIDINote.minLengthBeats`); the start is untouched.
    public func resizeNote(id: UUID, toEndBeat endBeat: Double, resolution: SnapResolution) {
        guard let index = draft.firstIndex(where: { $0.id == id }) else { return }
        let note = draft[index]
        let snappedEnd = snap(beat: endBeat, resolution: resolution)
        let minLength = minResizeLength(for: resolution)
        let length = max(minLength, snappedEnd - note.startBeat)
        draft[index] = MIDINote(
            id: id, pitch: note.pitch, velocity: note.velocity,
            startBeat: note.startBeat, lengthBeats: length
        )
    }

    /// Sets a note's velocity (clamped to 1...127 by `MIDINote`).
    public func setVelocity(id: UUID, velocity: Int) {
        guard let index = draft.firstIndex(where: { $0.id == id }) else { return }
        let note = draft[index]
        draft[index] = MIDINote(
            id: id, pitch: note.pitch, velocity: velocity,
            startBeat: note.startBeat, lengthBeats: note.lengthBeats
        )
    }

    /// Removes the selected notes and clears the selection.
    public func deleteSelection() {
        guard !selection.isEmpty else { return }
        draft.removeAll { selection.contains($0.id) }
        selection = []
    }

    // MARK: - Selection

    public func isSelected(_ id: UUID) -> Bool { selection.contains(id) }

    /// Selects exactly `id`, clearing any other selection.
    public func selectOnly(_ id: UUID) { selection = [id] }

    /// Adds/removes `id` from the selection (shift-click).
    public func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    public func clearSelection() { selection = [] }

    // MARK: - Submission

    /// The draft to hand to `ProjectStore.setClipNotes` on gesture end. The
    /// store re-clamps and canonically orders, so the model returns as-is.
    public func buildSubmission() -> [MIDINote] { draft }
}
