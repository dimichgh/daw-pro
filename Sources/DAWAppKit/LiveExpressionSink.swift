import Foundation
import DAWCore

// m34-f step ② — THE SECOND SEAM. `LiveNoteSink` crosses between "a human is
// playing NOTES" and "something makes sound". This one crosses between "a human
// is SHAPING a sound" and "something makes sound", and it exists for exactly the
// reason its sibling does: so a second expression surface never has to grow a
// second pipe.
//
// ═══ WHY IT IS A SEPARATE PROTOCOL AND NOT A SECOND METHOD ON `LiveNoteSink` ═══
//
// A note surface and an expression surface are driven by different hands at the
// same time — that is the whole ergonomic idea behind this feature (one hand
// types the pitches, the other shapes them). Folding them into one protocol
// would force every conformer to answer both questions, and Musical Typing has
// no opinion about breath while the breath pad has none about pitch.
//
// ═══ WHY THE CROSSING IS PHASED AND NOT SET-SHAPED ═══
//
// ⚠️ **THIS IS A CORRECTNESS ARGUMENT, NOT A STYLE PREFERENCE, and it is the
// OPPOSITE of `LiveNoteSink`'s.** Notes cross as a SET because the receiver
// diffs against a ledger and an unchanged set must be a no-op — that is what
// keeps a 500 ms liveness heartbeat from re-recording a held note six times a
// second. A controller has no heartbeat and holds no voice, so there is nothing
// to re-assert; what it has instead is a GESTURE, and the gesture's boundaries
// are load-bearing:
//
//   * `.begin` opens streaming and always delivers, bypassing the rate cap.
//   * `.move` is rate-capped and change-filtered — dropping intermediate values
//     during a fast drag is correct, because a controller stream is lossy by
//     nature.
//   * `.end` ALWAYS delivers, and it delivers the controller's NEUTRAL default
//     rather than the last performed value. A CC is sticky and nothing takes it
//     back; parking the last value would leave the strip attenuated with nothing
//     on screen explaining it.
//
// ⭐ **A dropped intermediate value is fine; a stuck last value is not.** That
// asymmetry is why `begin`/`end` are exempt from the cap and `move` is not, and
// it lives in `PadPreviewController` (DAWCore) rather than here.

/// THE one sink every live-EXPRESSION input surface targets (m34-f step ②): the
/// breath pad's pointer drag today; ③'s dedicated modulation panel and ④'s grid
/// when they exist.
///
/// **PHASED SEMANTICS, deliberately**: the argument is "this is what the hand is
/// doing to this strip, at this point in one continuous gesture". A phase-less
/// "set the value" call could not express *"the pad NEVER streams while the
/// transport is simply rolling"* — the rule that keeps playback, replay and a
/// bounce agreeing sample-for-sample.
///
/// ⭐ **THE POINT OF THE PROTOCOL IS THAT THE IMPLEMENTATION BENEATH IT CAN BE
/// SWAPPED.** `LiveNoteSink` earned its keep exactly that way: v1 pushed at
/// `ProjectStore.auditionPitches`, which cannot record, and the shipped one
/// pushes at `playLiveNotes`, which can — with nothing above the seam changed.
/// This protocol starts where that one ended up, at a path that records.
@MainActor
public protocol LiveExpressionSink: AnyObject {
    /// Push one expression value (effort, 0…1) for `trackID` at this point in a
    /// gesture. Throws only what the domain refuses — a wrong track kind, a
    /// missing track, a `.move` with no `.begin` before it.
    @discardableResult
    func setExpression(trackID: UUID, effort: Double,
                       phase: PadPreviewPhase) throws -> PadPreviewResult
}

/// What one pedal push came back with (m34-l).
///
/// ⭐ **`down` IS THE STATE AFTER THE CALL, NOT AN ACK.** A setter's return is
/// not proof it took — unless the setter returns the state. A press onto a
/// track whose renderer has gone comes back `down: false`, and the lamp above
/// follows it down.
public struct LiveSustainReport: Equatable, Sendable {
    /// The pedal state the store holds now.
    public var down: Bool
    /// Why nothing sounded, or nil if it did. Diagnostics for
    /// `debug.musicalTyping` — a seam that could only say "I sent it" would
    /// agree with itself through a dead pipe.
    public var refusal: String?
    /// ⭐ The ENGINE's answer to "is this being kept?". `nil` before anything
    /// was pushed or when the push never reached the store — a third state,
    /// deliberately not folded into `false`.
    public var isRecording: Bool?
    /// Controller points this call put into the take. Expected to be 0 when the
    /// latch's state filter coalesced the call away — the machinery working.
    public var capturedPoints: Int

    public init(down: Bool, refusal: String? = nil, isRecording: Bool? = nil,
                capturedPoints: Int = 0) {
        self.down = down
        self.refusal = refusal
        self.isRecording = isRecording
        self.capturedPoints = capturedPoints
    }
}

/// THE one sink every live SUSTAIN-PEDAL surface targets (m34-l): Musical
/// Typing's Tab key today; a hardware pedal's app-tier mirror, or an on-screen
/// pedal button, when they exist.
///
/// ═══ WHY A THIRD PROTOCOL AND NOT A THIRD METHOD ON EITHER SIBLING ═══
///
/// ⚠️ **THE SHAPES GENUINELY DIFFER, and each sibling's shape is load-bearing
/// for a reason that does not apply here.**
///
///   * `LiveNoteSink` is **SET-shaped** ("exactly these pitches sound") because
///     a 500 ms liveness heartbeat re-asserts the held set, and only an
///     unchanged-set-is-a-no-op contract keeps that from re-recording a held
///     note six times a second. A pedal holds no voice and has no heartbeat.
///   * `LiveExpressionSink` is **PHASE-shaped** (`begin`/`move`/`end`) because a
///     drag is a gesture with boundaries, rate-capped in the middle and
///     released to neutral at the end. A latch has no middle.
///
/// A pedal is **EDGE-shaped**: one bit, two edges, sticky until the other edge.
/// Folding it into either would make every conformer answer a question its own
/// surface has no opinion about — the reason `LiveExpressionSink` gives for not
/// being a method on `LiveNoteSink`, one axis further along.
///
/// ⭐ **WHAT *IS* REUSED IS EVERYTHING BELOW THE SEAM, AND THAT IS THE POINT.**
/// The shipped conformer is `LivePlayExpressionSink` — the SAME CLASS the breath
/// pad pushes through — and beneath it `ProjectStore.playLiveSustain` reaches
/// `AudioEngine.setLiveExpression`, the one m34-f funnel that sounds a
/// controller AND feeds the rolling take. There is no second controller path;
/// there is a second SHAPE at the top of the same one.
@MainActor
public protocol LiveSustainSink: AnyObject {
    /// Press (`true`) or lift (`false`) the damper pedal on whatever track this
    /// sink resolves. Idempotent; never throws, because a key-event handler
    /// inside an `NSEvent` monitor has nowhere to throw to — the refusal comes
    /// back in the report instead, where the indicator can say it.
    @discardableResult
    func setSustain(down: Bool) -> LiveSustainReport
}

/// The shipped sink: pushes at `ProjectStore.playLiveExpression` — the
/// live-expression funnel, which **sounds the value AND feeds the rolling
/// take**.
///
/// ⭐⭐ **WHAT YOU SHAPE IS RECORDED, AND THAT IS NEW.** Until m34-f the pad's
/// only live path was `ProjectStore.previewEffort`, whose own documentation says
/// *"NOT AN EDIT, AND NOT THE RECORD"* and which throws `transportBusy` mid-take
/// by design. Both of those remain TRUE OF THAT METHOD and are deliberately
/// untouched: an agent auditioning a shape must not write expression the user
/// never performed. They are simply not true of this one, for the same reason
/// `playLiveNotes`' refusal-free contract is not `auditionPitches`'.
///
/// ⭐ **THE HONESTY LIGHT IS READ BACK, NOT ASSUMED.** `playLiveExpression`
/// returns a `PadPreviewResult` whose `recording` is true only when this call's
/// value actually reached a live capture session — the engine narrows the app's
/// `isRecording && isArmed && kind == .instrument` verdict further and only it
/// can see the rest. The sink keeps that answer so the pad can show the engine's
/// truth beside the app's prediction. Two instruments on one question; them
/// disagreeing is the signal.
///
/// ⭐ **AND IT IS THE SUSTAIN SINK TOO (m34-l) — ONE OBJECT, TWO SHAPES.** The
/// pedal is a live expression input like the pad is, so it belongs to the same
/// sink rather than to a parallel one; what differs is only the SHAPE of the
/// crossing (edge vs gesture — see `LiveSustainSink`). `trackID` is the
/// resolver that half needs: `LiveSustainSink.setSustain` takes no track,
/// because the key monitor calling it has no idea which track is active, in
/// exact mirror of `LivePlayNoteSink`.
@MainActor
public final class LivePlayExpressionSink: LiveExpressionSink, LiveSustainSink {
    private let store: ProjectStore
    /// ⚠️ **RESOLVED PER CALL, THROUGH A CLOSURE, ON PURPOSE** — the
    /// `LivePlayNoteSink` rule verbatim: the active track MOVES while Musical
    /// Typing is on (the user clicks another header), and a captured `UUID`
    /// would pedal the track they left. `nil` for a caller that only ever uses
    /// the `setExpression` half, which names its own track.
    private let trackID: (() -> UUID?)?

    /// Why the last push made no sound, or nil if it did. Diagnostics for
    /// `debug.breathPad` — a seam that could only say "I sent it" would agree
    /// with itself through a dead pipe.
    public private(set) var lastRefusal: String?
    /// ⭐ **THE ENGINE'S OWN ANSWER to "is this being kept?"**, straight off the
    /// last result. `nil` before anything has been pushed, or when the push
    /// threw — a third state, deliberately not folded into `false`.
    public private(set) var lastIsRecording: Bool?
    /// Controller points the last call put into the take. Expected to be 0 on a
    /// call the rate cap or the change filter coalesced away — that is the
    /// gesture machinery working, not a failure.
    public private(set) var lastCapturedPoints: Int = 0

    /// ⭐ **THE PEDAL'S OWN READ-BACK.** `nil` until a pedal edge is pushed.
    public private(set) var lastSustainDown: Bool?

    public init(store: ProjectStore, trackID: (() -> UUID?)? = nil) {
        self.store = store
        self.trackID = trackID
    }

    // MARK: - LiveSustainSink (m34-l)

    @discardableResult
    public func setSustain(down: Bool) -> LiveSustainReport {
        guard let resolved = trackID?() else {
            // ⚠️ NOT AN EARLY RETURN TO SKIP WITHOUT THINKING: with no active
            // track there is nothing to pedal AND nothing to lift, so the honest
            // answer is UP. Reporting `down` here would light a lamp over an
            // instrument that does not exist — the `LivePlayNoteSink` no-track
            // branch, one control over.
            lastSustainDown = false
            return LiveSustainReport(down: false,
                                     refusal: down ? "no active track" : nil)
        }
        do {
            let result = try store.playLiveSustain(trackID: resolved, down: down)
            lastSustainDown = result.down
            return LiveSustainReport(down: result.down, refusal: nil,
                                     isRecording: result.isRecording,
                                     capturedPoints: result.capturedPoints)
        } catch {
            // ⚠️ SWALLOWED, unlike `setExpression`'s rethrow, and the asymmetry
            // is the same one `LivePlayNoteSink` documents: this is called from
            // an `NSEvent` key monitor with nowhere to throw TO, while
            // `setExpression` is called from `BreathPadModel.stream`, which
            // already catches and displays the sentence. The message is not lost
            // — it comes back in the report, which the indicator reads.
            lastSustainDown = false
            let message = (error as? ProjectError)?.errorDescription
                ?? error.localizedDescription
            return LiveSustainReport(down: false, refusal: message)
        }
    }

    @discardableResult
    public func setExpression(trackID: UUID, effort: Double,
                              phase: PadPreviewPhase) throws -> PadPreviewResult {
        do {
            let result = try store.playLiveExpression(trackID: trackID, value: effort,
                                                      phase: phase)
            lastRefusal = nil
            lastIsRecording = result.recording
            lastCapturedPoints = result.capturedPoints
            return result
        } catch {
            // ⚠️ RETHROWN, unlike `LivePlayNoteSink`'s swallow, and the
            // difference is not an oversight: that sink lives inside an NSEvent
            // key monitor with nowhere to throw TO, while this one is called
            // from `BreathPadModel.stream`, which already catches and SURFACES
            // the sentence in `previewRefusal`. Swallowing here would delete a
            // message the panel is built to display.
            lastRefusal = (error as? ProjectError)?.errorDescription
                ?? error.localizedDescription
            lastIsRecording = nil
            lastCapturedPoints = 0
            throw error
        }
    }
}
