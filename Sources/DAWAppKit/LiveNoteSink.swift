import Foundation
import DAWCore

// m23-ct — THE SEAM. One crossing between "a human is playing notes" and
// "something makes sound", so a second input surface never has to grow a second
// pipe.
//
// ═══ WHY THE CROSSING IS SET-SHAPED AND NOT EDGE-SHAPED ═══
//
// ⚠️⚠️ **THIS IS A CORRECTNESS ARGUMENT, NOT A STYLE PREFERENCE, and it reversed
// an earlier `noteOn`/`noteOff`/`releaseAll` design** (m23-ct architecture spike,
// 2026-08-29). The engine side runs a **500 ms liveness heartbeat** that
// re-asserts the currently-held set so a held note outruns the render side's 3 s
// watchdog (`LivePlayController.heartbeatMilliseconds` / `watchdogSeconds`, the
// same numbers `AuditionController` runs).
//
//   * **Set-shaped crossing**: the receiver diffs the incoming set against its
//     ledger, so an UNCHANGED set yields ZERO edges. The heartbeat is a no-op by
//     CONSTRUCTION.
//   * **Edge-shaped crossing**: every heartbeat pass looks like a fresh note-on
//     — and since the sink now feeds a rolling TAKE, that would **re-record the
//     note into the clip six times a second.**
//
// ⭐ **THAT HAZARD IS NO LONGER HYPOTHETICAL — THE SHAPE IS WHAT PREVENTS IT.**
// `LivePlayOutcome.capturedEdges` is documented to be *"0 on a heartbeat, and
// that is the point"*. The safety falls out of the SHAPE rather than out of a
// second piece of state that can disagree with the first.
//
// ⭐ **EDGE-SHAPED CONVENIENCE STILL EXISTS — ONE LAYER UP, ABOVE THE SEAM.**
// `MusicalTypingController` speaks press/release, owns the ordered held set, and
// pushes the RESULTING SET through here. That is the layering: edges where a
// human's fingers are, sets where the audio is.

/// THE one sink every live-note input surface targets (m23-ct): the computer
/// keyboard, the on-screen keyboard, and — when it is migrated — the piano roll's
/// keyboard gutter.
///
/// **SET SEMANTICS, deliberately**: the argument is "exactly these pitches should
/// be sounding now". `[]` releases everything. An UNCHANGED set is a no-op that
/// still refreshes the hold.
///
/// ⭐ **THE PROTOCOL EARNED ITS KEEP: THE IMPLEMENTATION BENEATH IT WAS SWAPPED
/// AND NOTHING ABOVE IT CHANGED.** v1 pushed at `ProjectStore.auditionPitches`,
/// which cannot record; the shipped one pushes at `ProjectStore.playLiveNotes`,
/// which can. `MusicalTypingController`, `MusicalKeyboardStrip` and the key
/// monitor were untouched by that swap — which is the whole reason a seam exists.
@MainActor
public protocol LiveNoteSink: AnyObject {
    /// Sound exactly these pitches, now, at this velocity. `[]` releases
    /// everything. Idempotent.
    func setHeldPitches(_ pitches: [Int], velocity: Int)
}

/// The shipped sink: pushes the held set at `ProjectStore.playLiveNotes` — the
/// live-play funnel, which **sounds the notes AND feeds the rolling take**.
///
/// ⭐⭐ **WHAT YOU TYPE IS RECORDED. THE OLD CEILING IS GONE — DO NOT RE-QUOTE
/// IT.** Until the engine half of m23-ct landed (2026-08-29) this class sat on
/// `auditionPitches`, which throws `ProjectError.transportBusy` mid-take by
/// design, and this comment said in bold that recording was *"not a deferral, it
/// is exclusion."* That was true of the audition path and is **false of this
/// one**: `playLiveNotes` is deliberately NOT refused while recording, because
/// its note edges are ingested by `MIDICaptureSession`. A stale "this cannot be
/// done" comment is the class that froze four roadmap items in this repo for
/// eight days, so the retraction is written here rather than the claim quietly
/// deleted.
///
/// ⭐ **THE HONESTY LIGHT IS READ BACK, NOT ASSUMED.** `playLiveNotes` returns a
/// `LivePlayResult` whose `isRecording` is true only when this call's edges
/// actually reached a live capture session — the engine narrows the app's
/// `isRecording && isArmed && kind == .instrument` verdict further and only it
/// can see the rest. The sink keeps that answer so the surface can show the
/// engine's truth beside the app's prediction. Two instruments on one question;
/// them disagreeing is the signal.
///
/// ⚠️ **THE TRACK IS RESOLVED PER CALL, THROUGH A CLOSURE, ON PURPOSE.** The
/// active track changes while the mode is on (the user clicks another header),
/// and a captured `UUID` would keep playing the track they left. The app hands in
/// `AppModel.activeTrackID` — `ArrangeActiveTrack`'s ONE resolution point, which
/// carries an explicit "do not add a second lookup beside this" warning.
@MainActor
public final class LivePlayNoteSink: LiveNoteSink {
    private let store: ProjectStore
    private let trackID: () -> UUID?

    /// Why the last push made no sound, or nil if it did (or if there was
    /// nothing to push). Diagnostics for `debug.musicalTyping` — a seam that
    /// could only say "I sent it" would agree with itself through a dead pipe,
    /// which is the m23-o2 `widthSource` failure in another medium.
    public private(set) var lastRefusal: String?
    /// The pitches most recently handed to the store — the sink's OWN record of
    /// what it asked for, so an echo can put it beside `store.livePlay.heldPitches`
    /// (what the store believes) and beside the controller's set (what the view
    /// draws). Three instruments; two of them disagreeing is the signal.
    public private(set) var lastRequestedPitches: [Int] = []
    /// ⭐ **THE ENGINE'S OWN ANSWER to "is this being kept?"**, straight off the
    /// last `LivePlayResult`. `nil` before anything has been pushed, or when the
    /// push never reached the store at all (no track / a refusal) — which is a
    /// third state and deliberately not folded into `false`.
    public private(set) var lastIsRecording: Bool?
    /// Note edges the last call put into the take. ⚠️ **Expected to be 0 on a
    /// heartbeat and on any unchanged set** — that is the set-shaped crossing
    /// working, not a failure. Non-zero on a genuine press or release.
    public private(set) var lastCapturedEdges: Int = 0

    public init(store: ProjectStore, trackID: @escaping () -> UUID?) {
        self.store = store
        self.trackID = trackID
    }

    public func setHeldPitches(_ pitches: [Int], velocity: Int) {
        lastRequestedPitches = pitches
        guard let trackID = trackID() else {
            // ⚠️ NOT AN EARLY RETURN WE CAN SKIP FOR AN EMPTY SET WITHOUT
            // THINKING: with no track there is nothing to release either, so
            // there is genuinely nothing to do. The controller's own state is
            // already cleared by the time it calls with [].
            lastRefusal = pitches.isEmpty ? nil : "no active track"
            lastIsRecording = nil
            lastCapturedEdges = 0
            return
        }
        do {
            let result = try store.playLiveNotes(trackID: trackID, pitches: pitches,
                                                 velocity: velocity)
            lastRefusal = nil
            lastIsRecording = result.isRecording
            lastCapturedEdges = result.capturedEdges
        } catch {
            // Swallowed rather than propagated, and the reason is kept: a
            // key-press handler inside an NSEvent monitor has nowhere to throw
            // TO, and the refusals that reach here are all states the indicator
            // already names (`TargetState`). Losing the string would make a
            // silent failure indistinguishable from a working one.
            //
            // ⚠️ The set of reachable refusals SHRANK when the sink was swapped:
            // `transportBusy` is no longer among them. What remains is
            // `validateAuditionTarget`'s — wrong track kind, out-of-range pitch
            // or velocity, too many voices — the same validation live play and
            // audition share.
            lastRefusal = "\(error)"
            lastIsRecording = nil
            lastCapturedEdges = 0
        }
    }
}
