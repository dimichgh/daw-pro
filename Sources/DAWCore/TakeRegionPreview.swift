import Foundation

/// The PROVISIONAL region drawn over the destination lane(s) while a take is
/// still rolling (m34-a-2) — what the arrange shows before a clip exists.
///
/// ⛔⛔ **THIS IS NOT A `Clip` AND MUST NEVER BECOME ONE.** It lives outside
/// `Track.clips`, so selection, the marquee, drag/trim, the clipboard, undo and
/// every wire verb that takes a clip id cannot see it *by construction* rather
/// than by a rule someone has to remember. A half-recorded clip the user can
/// drag is a data-loss shape and this tree has already shipped one of those
/// (m33-j: `clip.addAudio` silently deleting any clip it overlapped). The
/// weaker design — materialise a real clip at record start and grow it — was
/// refused for exactly that reason: it would put a mutable, undoable,
/// selectable object on the timeline in the middle of a performance.
public struct ProvisionalTakeRegion: Sendable, Equatable {
    /// The instrument tracks the take will land on — `PendingTake`'s SNAPSHOT,
    /// never the live `isArmed` flags. Arm toggles mid-take deliberately do not
    /// move where a take lands (`ProjectStore.record()`), so a region that
    /// tracked live arm state would slide to a lane the clip is not coming to.
    public var trackIDs: [UUID]
    /// Where the clip will land — `PendingTake.recordStartBeats`.
    public var startBeat: Double
    /// The clip length the take would have if it stopped NOW.
    public var lengthBeats: Double
    /// Notes captured so far. Always ≥ 1 (a region is not drawn below that);
    /// echoed so a gate can tell "the take is growing" from "the view is
    /// stuck", and so the block can show an honest count.
    public var noteCount: Int

    public init(trackIDs: [UUID], startBeat: Double, lengthBeats: Double, noteCount: Int) {
        self.trackIDs = trackIDs
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.noteCount = noteCount
    }
}

/// Everything about the take in flight that the preview needs and the engine
/// cannot know — the destinations and timing `ProjectStore` snapshotted at
/// record start.
public struct PendingTakeInfo: Sendable, Equatable {
    /// Instrument destinations (the MIDI side). Empty for an audio-only take.
    public var instrumentTrackIDs: [UUID]
    /// Audio destinations, for completeness of the echo; the preview does not
    /// draw for them (see `TakeRegionPreview`'s scope note).
    public var audioTrackIDs: [UUID]
    /// The beat the clip will land at.
    public var startBeat: Double
    public var takeNumber: Int
    /// True when this take is a LOOP-CYCLE take (m15-b). The preview refuses
    /// these — see `TakeRegionPreview`.
    public var isLoopTake: Bool

    public init(instrumentTrackIDs: [UUID], audioTrackIDs: [UUID],
                startBeat: Double, takeNumber: Int, isLoopTake: Bool) {
        self.instrumentTrackIDs = instrumentTrackIDs
        self.audioTrackIDs = audioTrackIDs
        self.startBeat = startBeat
        self.takeNumber = takeNumber
        self.isLoopTake = isLoopTake
    }
}

/// **The rule for the growing take region** (m34-a-2) — one pure function, so
/// the decision is headless-testable and the view is left with nothing to
/// decide.
///
/// The user's report was *"when I record playing using keys on instrument track
/// it would be good to automatically create and auto extend [the region] as
/// user plays"*. m34-a-1 shipped the horizontal half (the view follows the
/// playhead during a take); this is the half that makes there be something to
/// look at.
///
/// ── THE FOUR DECISIONS, EACH WITH ITS REASON ────────────────────────────────
///
/// ⭐⭐ **1. NOTHING IS DRAWN UNTIL A NOTE HAS ACTUALLY BEEN CAPTURED, AND THAT
/// IS THE ANSWER TO "WHAT HAPPENS ON A TAKE THAT CAPTURES NOTHING".**
/// `ProjectStore.finishTake` DISCARDS a take with zero notes — *"empty take
/// discarded — no MIDI notes received"*. A region drawn from record start would
/// therefore promise a clip on every take, and on a silent one it would vanish
/// at stop leaving nothing behind: a ghost. Gating on `noteCount > 0` makes the
/// region's presence mean exactly what `finishTake` will do. The cost, stated
/// rather than discovered: the region appears on the first note rather than at
/// record start, so a count-in and a hesitant player both show empty lanes —
/// which is honest, because at that moment there is genuinely no clip coming.
///
/// ⭐ **2. THE LENGTH IS `MIDICaptureSession.finish`'s FORMULA, SHARED.**
/// `max(1, ceil(stop − anchor))`, evaluated with the live playhead standing in
/// for the stop beat. The provisional region is therefore not an approximation
/// of the clip: it is the same arithmetic one tick early, so the swap at stop
/// lands pixel-exact instead of jumping. It also grows in WHOLE BEATS, which
/// looks like a deliberate step rather than a jitter — and is the truth about
/// what will be created.
///
/// ⭐ **3. THE END IS `max(playhead, latestEvent)`, NOT THE PLAYHEAD ALONE.**
/// They are normally the same to within a tick, but the playhead is a ~30 Hz
/// display value and the capture clock is the audio anchor: a note struck just
/// past a beat boundary can be captured before the display catches up. Taking
/// the max means the region can never be shorter than the notes inside it.
///
/// ⛔ **4. LOOP-CYCLE TAKES DRAW NOTHING (v1), STATED RATHER THAN BROKEN.**
/// Under a loop take `transport.positionBeats` is MODULAR while every capture
/// clock is LINEAR (`TakeResult.stopBeats` exists for precisely this reason),
/// and `finishTake` lands per-cycle take LANES inside the loop window — not one
/// growing clip. A region drawn from a modular playhead against a linear anchor
/// would shrink at every wrap and would claim ground the clip is not coming to.
/// The loop band already shows where a loop take will land. Layer takes
/// (m34-h `recordLayer`) are NOT excluded: they refuse the loop themselves, so
/// they are linear by construction and preview correctly.
public enum TakeRegionPreview {

    /// The region to draw right now, or nil for "draw nothing".
    ///
    /// - Parameters:
    ///   - pending: the take's snapshot, nil when none is in flight.
    ///   - extent: the engine's live capture extent, nil when the engine has no
    ///     MIDI take rolling (or cannot report one — the optional-capability
    ///     default, which is why "no extent" must always mean "draw nothing"
    ///     rather than "assume something").
    ///   - playheadBeat: `transport.positionBeats`.
    ///   - isRecording: `transport.isRecording`. Checked here rather than
    ///     assumed from `pending != nil`: `pendingTake` outlives the stop (the
    ///     writer finalizes asynchronously), so it is not the lifetime.
    public static func region(pending: PendingTakeInfo?,
                              extent: LiveTakeExtent?,
                              playheadBeat: Double,
                              isRecording: Bool) -> ProvisionalTakeRegion? {
        guard isRecording, let pending, let extent else { return nil }
        guard !pending.isLoopTake else { return nil }               // decision 4
        guard !pending.instrumentTrackIDs.isEmpty else { return nil }
        guard extent.noteCount > 0 else { return nil }              // decision 1
        let end = max(playheadBeat, extent.latestEventBeat ?? extent.anchorBeat)  // decision 3
        return ProvisionalTakeRegion(
            trackIDs: pending.instrumentTrackIDs,
            startBeat: pending.startBeat,
            lengthBeats: length(anchorBeat: extent.anchorBeat, endBeat: end),
            noteCount: extent.noteCount)
    }

    /// `MIDICaptureSession.finish`'s clip-length formula, in ONE place so the
    /// preview and the artifact cannot drift (decision 2). Kept as its own
    /// entry point so a test can assert the two agree by construction rather
    /// than by inspection.
    public static func length(anchorBeat: Double, endBeat: Double) -> Double {
        max(1, (endBeat - anchorBeat).rounded(.up))
    }
}
