import Foundation

/// LIVE LOOPING (m34-h-1, route ⓐ) — the **loop deck**: the state and the pure
/// arithmetic behind "build a song by stacking layers in real time".
///
/// ⛔⛔ **READ THIS BEFORE ASSUMING THE TRANSPORT LOOPS. IT DOES NOT.**
/// A deck session runs the transport **LINEARLY**. The loop is not
/// `transport.setLoop` — it is a **repeating clip**, which is the roadmap's own
/// wording for route ⓐ. Each layer lands as ONE ordinary MIDI `Clip` whose
/// notes are folded into a single cycle and then **tiled forward** across the
/// deck's whole span, so the material genuinely repeats on the timeline and the
/// piece bounces, exports and edits like any other project.
///
/// That is not a workaround, it is what the two shipped refusals require.
/// `ProjectStore.recordLayer()` and `AudioEngine.startTakeInPlayback` BOTH
/// refuse while `transport.isLoopEnabled` — deliberately, with domain-arithmetic
/// reasons (the transport's beat is modular under a loop while every capture
/// clock in the engine is linear, and a loop merely *enabled* over a linear
/// schedule wraps through `restart(fromBeat:)`, which would replace the take's
/// anchor underneath it). A deck that enabled the transport loop would have to
/// reverse both. Composing with them instead costs nothing musically and no
/// engine work at all.
///
/// ⭐ **THE PLACEMENT LAW, AND IT IS THE WHOLE FEATURE:** a note's position in
/// the loop is `(absoluteBeat − originBeat) mod cycleBeats`. Placement is
/// therefore a function of *where in the music the note was played*, never of
/// *when the performer pressed the button*. Launch quantization exists on top of
/// that to make the session **comprehensible** (the light turns from queued to
/// recording on the bar line, so a performer knows what is live) — the folding
/// is what makes it **correct**.
///
/// ⚠️ **v1 IS MIDI/INSTRUMENT LAYERS ONLY.** An audio layer cannot be tiled
/// inside one clip — repeating a recorded waveform needs N clips windowing one
/// file, which is `finishLoopTake`'s machinery, not this one. Audio layers are
/// named follow-up work, not a hidden gap; `ProjectStore.armLoopLayer` refuses
/// an audio track with a teaching error rather than silently landing a
/// one-shot.
public enum LoopDeckMath {

    // MARK: Constants

    /// How far *before* a note's captured onset the capture window may reach at
    /// **capture open**, in beats. A performer anticipates a downbeat by
    /// 20–40 ms; at 120 BPM 0.125 beats is 62 ms, comfortably more than that
    /// and comfortably less than any subdivision anybody plays deliberately.
    ///
    /// ⭐⭐ **THIS EXISTS TO STOP AN ANTICIPATED FIRST DOWNBEAT FROM BEING
    /// FOLDED TO THE *END* OF THE LOOP.** Mid-take, an early note is an
    /// anticipation and folding it near `cycleBeats` is musically right — it
    /// keeps sounding just before every downbeat, which is where it was played.
    /// At capture open the intent is not ambiguous: that note is the layer
    /// STARTING. A naive `mod` would place it at `cycleBeats − ε`, an entire
    /// cycle early on every repeat — and an onset gate would print
    /// `L − ε` and might well be read as "close enough".
    public static let launchGraceBeats: Double = 0.125

    /// Cycles of material materialised ahead of the playhead. Deliberately
    /// LARGE, and the reason is a measured engine seam, not taste: a clip
    /// landing on a track flips `PlaybackGraph`'s per-track signature, which
    /// rides `AudioEngine.tracksDidChange` → `restart(cause: .continuation)` —
    /// a player-only restart of everything currently rolling. Materialising one
    /// cycle at a time would hit that seam every cycle; materialising sixteen
    /// hits it once per layer, which is the minimum possible.
    public static let defaultHorizonCycles: Int = 16

    /// Extend the runway when fewer than this many cycles remain ahead of the
    /// playhead. Two, so the extension always lands before the last tiled cycle
    /// is reached even if a tick is missed.
    public static let runwayMarginCycles: Int = 2

    /// Default loop length when `looper.begin` is given no bar count.
    public static let defaultBars: Int = 4

    // MARK: Grid arithmetic

    /// The first grid boundary at or after `beat`.
    ///
    /// The epsilon is load-bearing: a playhead sampled *exactly* on a boundary
    /// (which the headless ticker can produce, and floating-point division can
    /// fake) must return THAT boundary, not the next one — otherwise an arm
    /// pressed on the downbeat silently costs a whole bar.
    public static func boundary(atOrAfter beat: Double, origin: Double, grid: Double) -> Double {
        guard grid > 0, grid.isFinite, beat.isFinite, origin.isFinite else { return origin }
        let cycles = (beat - origin) / grid
        let k = max(0, ceil(cycles - 1e-9))
        return origin + k * grid
    }

    /// Which cycle index `beat` falls in, relative to the deck origin. Negative
    /// positions clamp to 0 — a playhead behind the origin is "not started yet",
    /// never a negative cycle.
    public static func cycleIndex(ofBeat beat: Double, origin: Double, cycleBeats: Double) -> Int {
        guard cycleBeats > 0, beat.isFinite, origin.isFinite else { return 0 }
        return max(0, Int(floor((beat - origin) / cycleBeats + 1e-9)))
    }

    /// The loop length chosen by a PRESS-TO-END first layer, in beats.
    ///
    /// ⭐ **ROUNDS TO THE NEAREST WHOLE BAR, MINIMUM ONE BAR — SO AN OFF-GRID
    /// LOOP IS UNREPRESENTABLE.** The research's §3.2 arithmetic is the reason:
    /// an off-grid loop length does not average out, it compounds on every
    /// repeat, and every later layer inherits it forever. Rounding to NEAREST
    /// (not up) is what makes a slightly-late press behave: press 0.1 beats
    /// after the bar line and you get the bar you meant, with the 0.1 beats of
    /// overshoot folding harmlessly onto the top of the loop.
    public static func pressToEndCycleBeats(capturedBeats: Double, beatsPerBar: Double) -> Double {
        guard beatsPerBar > 0, capturedBeats.isFinite else { return max(1, beatsPerBar) }
        let bars = max(1, (capturedBeats / beatsPerBar).rounded())
        return bars * beatsPerBar
    }

    // MARK: Folding — the placement law

    /// Folds a landed take's notes into ONE cycle of the deck's loop.
    ///
    /// - Parameters:
    ///   - notes: the take's notes, **clip-relative** (as `finishTake` receives
    ///     them).
    ///   - clipStartBeat: the absolute beat the take's clip would have landed
    ///     at — i.e. the beat capture actually began.
    ///   - captureOpenBeat: the absolute beat from which material counts. This
    ///     is the quantized launch boundary, NOT the arm press: anything played
    ///     during the pre-roll is the performer waiting, not the layer.
    ///   - originBeat: cycle 0's absolute beat.
    ///   - cycleBeats: the loop length.
    ///
    /// Returns notes in canonical order, each with `startBeat` in
    /// `[0, cycleBeats)` and a length clamped so nothing runs past the cycle end
    /// (a looper's buffer simply ends; a note is not wrapped into its own head).
    public static func fold(_ notes: [MIDINote],
                            clipStartBeat: Double,
                            captureOpenBeat: Double,
                            originBeat: Double,
                            cycleBeats: Double,
                            graceBeats: Double = launchGraceBeats) -> [MIDINote] {
        guard cycleBeats > 0 else { return [] }
        var folded: [MIDINote] = []
        folded.reserveCapacity(notes.count)
        for note in notes {
            let absolute = clipStartBeat + note.startBeat
            // Before the window and outside the grace: the performer had not
            // started yet. Dropped, not folded — folding it would put a stray
            // pre-roll note into the loop forever.
            if absolute < captureOpenBeat - graceBeats { continue }
            // Inside the grace: an anticipated downbeat. Snapped to the window
            // rather than folded — see `launchGraceBeats`.
            let effective = max(absolute, captureOpenBeat)
            var phase = (effective - originBeat).truncatingRemainder(dividingBy: cycleBeats)
            if phase < 0 { phase += cycleBeats }
            // Guards the exact-boundary case: `truncatingRemainder` on a value
            // one ULP under a multiple can return `cycleBeats` itself.
            if phase >= cycleBeats - 1e-9 { phase = 0 }
            let room = max(MIDINote.minLengthBeats, cycleBeats - phase)
            folded.append(MIDINote(pitch: note.pitch,
                                   velocity: note.velocity,
                                   startBeat: phase,
                                   lengthBeats: min(note.lengthBeats, room)))
        }
        return MIDINote.canonicallyOrdered(folded)
    }

    /// Tiles one cycle of folded notes across `cycles` repeats — this is what
    /// makes the layer a LOOP on a linear timeline. Each repeat gets fresh
    /// note ids, because two notes in one clip may not share an id.
    public static func tile(_ cycle: [MIDINote], cycles: Int, cycleBeats: Double) -> [MIDINote] {
        guard cycles > 0, cycleBeats > 0, !cycle.isEmpty else { return [] }
        var out: [MIDINote] = []
        out.reserveCapacity(cycle.count * cycles)
        for k in 0..<cycles {
            let offset = Double(k) * cycleBeats
            for note in cycle {
                out.append(MIDINote(pitch: note.pitch,
                                    velocity: note.velocity,
                                    startBeat: note.startBeat + offset,
                                    lengthBeats: note.lengthBeats))
            }
        }
        return MIDINote.canonicallyOrdered(out)
    }

    /// Merges an incoming folded cycle onto a layer's existing folded cycle.
    ///
    /// ⭐ **OVERDUB IS THE DEFAULT MEANING OF "RECORD AGAIN", AND REPLACE IS A
    /// VARIANT OF THE SAME GESTURE** — rule ③ of the Boss/Ableton/Loopy
    /// convergence. Both ends are one parameter on one verb, not two modes.
    public static func merge(existingCycle: [MIDINote],
                             incomingCycle: [MIDINote],
                             mode: LoopLayerMode) -> [MIDINote] {
        switch mode {
        case .replace: return MIDINote.canonicallyOrdered(incomingCycle)
        case .overdub: return MIDINote.canonicallyOrdered(existingCycle + incomingCycle)
        }
    }

    /// How many cycles the deck should be materialised to, given where the
    /// playhead is — or nil when the current span is already long enough.
    ///
    /// Only ever grows. Shrinking would delete material a performer recorded.
    public static func extendedSpan(spanCycles: Int,
                                    playheadCycle: Int,
                                    horizonCycles: Int = defaultHorizonCycles,
                                    marginCycles: Int = runwayMarginCycles) -> Int? {
        let wanted = playheadCycle + max(1, horizonCycles)
        guard spanCycles - playheadCycle <= marginCycles, wanted > spanCycles else { return nil }
        return wanted
    }
}

// MARK: - Model

/// What a "record again" press means on a layer that already has material.
public enum LoopLayerMode: String, Codable, Sendable, CaseIterable {
    /// Add to what is already there (the default, and what every looper does).
    case overdub
    /// Throw the layer's cycle away and keep only the new pass.
    case replace
}

/// The musical grid a layer's capture window opens on.
///
/// ⚠️ **`instant` IS OFFERED AND IS NOT THE DEFAULT.** It exists because the
/// roadmap asked for launch quantization to be selectable, and because a
/// performer who is already exactly on the beat can want the window now. It is
/// the one setting that can make a layer feel late; the folding still places
/// every note correctly, so what `instant` really costs is the first fraction
/// of a beat, which the anchor's own pre-roll would have covered.
public enum LoopLaunchQuantize: String, Codable, Sendable, CaseIterable {
    /// Wait for the next loop-cycle boundary. Default.
    case cycle
    /// Wait for the next bar line.
    case bar
    /// Open the window at the press.
    case instant
}

/// How the FIRST layer's length — and therefore the whole session's — is set.
public enum LoopLengthMode: String, Codable, Sendable, CaseIterable {
    /// Chosen in advance, in bars (RC-505 "Manual", Loopy Pro's Length
    /// Quantization). **The default**, and the research's explicit
    /// recommendation for this project's owner: you cannot pick a bad length,
    /// because you never pick a length at all, only a bar count.
    case fixedBars
    /// Set by when the first layer is finished (RC-505 "AUTO", Ableton free
    /// record), rounded to the nearest whole bar so an off-grid loop is
    /// unrepresentable.
    case pressToEnd
}

/// What one lamp on the deck strip is doing. ⛔ **THE PERFORMER READS THIS AS
/// LIGHT, NEVER AS TEXT** — rule ⑤ of the convergence, and the rule this tree
/// has already broken once (ten numeric badges, four reading "1").
public enum LoopLayerState: String, Codable, Sendable, CaseIterable {
    /// Assigned, waiting for its quantize boundary. Flashes.
    case queued
    /// Capturing right now. Pulses on the record colour.
    case recording
    /// The finish was requested and the window closes on the next boundary.
    case closing
    /// Has material and is sounding. Pulses on the play colour.
    case playing
    /// Has material and is deliberately silenced.
    case muted
}

/// One stacked layer: one instrument track, one repeating clip.
public struct LoopLayer: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let trackID: UUID
    /// The materialised repeating clip. nil only in the instant between a layer
    /// being created and its first take landing.
    public var clipID: UUID?
    /// 1-based, in the order layers were first recorded — the lamp order.
    public var ordinal: Int
    /// The layer's ONE cycle of folded notes. The clip's notes are this, tiled.
    /// Kept so an overdub can merge onto it and an undo can restore it without
    /// re-deriving anything from the tiled copy.
    public var cycle: [MIDINote]
    public var isMuted: Bool

    public init(id: UUID = UUID(), trackID: UUID, clipID: UUID? = nil, ordinal: Int,
                cycle: [MIDINote] = [], isMuted: Bool = false) {
        self.id = id
        self.trackID = trackID
        self.clipID = clipID
        self.ordinal = ordinal
        self.cycle = cycle
        self.isMuted = isMuted
    }
}

/// One landed pass, kept so it can be peeled off again.
///
/// ⭐⭐ **A STACK, NOT A SINGLE SLOT — "UNDO THE LAST LAYER" IS THE MOST-USED
/// CONTROL ON ANY LOOPER (rule ④), AND LOOPY PRO'S "PEEL" IS EXPLICITLY
/// MULTI-LEVEL.** One slot would let a performer take back one mistake; a stack
/// lets them take back the last three, which is what actually happens live.
///
/// ⛔ It is deliberately SEPARATE from the general `UndoJournal`. The journal is
/// refused mid-take, is shared with every other edit in the session, and would
/// make "peel that layer" mean "reverse whatever happened last" — including a
/// fader move. Rule ④ says this control is scoped to ONE layer.
public struct LoopPassRecord: Codable, Sendable, Equatable {
    public var layerID: UUID
    /// True when the pass CREATED the layer, so peeling it removes the layer
    /// outright rather than restoring an earlier cycle.
    public var createdLayer: Bool
    /// The layer's cycle as it stood before this pass. nil for a created layer.
    public var previousCycle: [MIDINote]?
    public var takeNumber: Int

    public init(layerID: UUID, createdLayer: Bool, previousCycle: [MIDINote]?, takeNumber: Int) {
        self.layerID = layerID
        self.createdLayer = createdLayer
        self.previousCycle = previousCycle
        self.takeNumber = takeNumber
    }
}

/// The layer currently queued or rolling. At most one at a time — a deck
/// records one layer at a time by construction, exactly like every hardware
/// looper, and `recordLayer()` refuses a second concurrent take anyway.
public struct LoopPendingLayer: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// Armed; the capture window has not opened.
        case queued
        /// `recordLayer()` has been fired; capture is live.
        case recording
        /// `finishLayer()` is due at `closeBeat`.
        case closing
    }
    public var trackID: UUID
    /// Identifies this pass. Stamped when the take actually starts, and carried
    /// on the take's frozen `DeckTakeWindow`, so a completion that arrives after
    /// the deck moved on can tell it is stale — the m34-h lesson that with
    /// layering several takes can be in flight at once.
    public var passID: UUID = UUID()
    /// The layer this pass belongs to — an existing one (overdub/replace) or a
    /// brand-new one created at arm time.
    public var layerID: UUID
    public var mode: LoopLayerMode
    /// Absolute beat the capture window opens on: the quantized launch boundary.
    public var launchBeat: Double
    /// Absolute beat at which `recordLayer()` must be fired, i.e.
    /// `launchBeat − preRoll`. May be in the past when the arm came late.
    public var armBeat: Double
    /// Absolute beat at which the window closes; nil while the layer is open.
    public var closeBeat: Double?
    public var phase: Phase
    /// True when this pass is the one that will DEFINE the loop length
    /// (press-to-end, first layer).
    public var definesLength: Bool
    /// True when the layer is brand new, so an undo removes it entirely rather
    /// than restoring a previous cycle.
    public var isNewLayer: Bool
}

/// A live-looping session. Value type, `Sendable`, no engine and no UI — the
/// whole decision surface is arithmetic over beats.
public struct LoopDeck: Codable, Sendable, Equatable {
    /// Cycle 0's absolute beat. Bar-aligned at `begin`.
    public var originBeat: Double
    /// The loop length. nil until the first press-to-end layer lands.
    public var cycleBeats: Double?
    public var beatsPerBar: Double
    public var lengthMode: LoopLengthMode
    public var quantize: LoopLaunchQuantize
    public var defaultMode: LoopLayerMode
    /// Cycles currently materialised on every layer's clip.
    public var spanCycles: Int
    public var horizonCycles: Int
    public var layers: [LoopLayer]
    public var pending: LoopPendingLayer?
    /// Landed passes, oldest first. `looper.undoLayer` pops the tail.
    public var passHistory: [LoopPassRecord]
    /// Set while deferred deck work (a launch, a close, a runway extension) is
    /// in flight on a hopped main-actor task, so a 30 Hz tick cannot fire the
    /// same action several times before the first one lands.
    ///
    /// ⚠️ **THE GATE IS THE STORE'S, NOT THE SCHEDULER'S.**
    /// `LoopDeckScheduler.actions` deliberately IGNORES this flag: it answers
    /// "what is due at this beat", which must stay a pure function of the beat
    /// so it can be tested arithmetically. Reading the flag there would make
    /// the function return `[]` when re-evaluated inside the very task the flag
    /// was set for.
    public var launchInFlight: Bool

    public init(originBeat: Double,
                cycleBeats: Double?,
                beatsPerBar: Double,
                lengthMode: LoopLengthMode,
                quantize: LoopLaunchQuantize = .cycle,
                defaultMode: LoopLayerMode = .overdub,
                spanCycles: Int = 0,
                horizonCycles: Int = LoopDeckMath.defaultHorizonCycles,
                layers: [LoopLayer] = [],
                pending: LoopPendingLayer? = nil,
                passHistory: [LoopPassRecord] = [],
                launchInFlight: Bool = false) {
        self.originBeat = originBeat
        self.cycleBeats = cycleBeats
        self.beatsPerBar = beatsPerBar
        self.lengthMode = lengthMode
        self.quantize = quantize
        self.defaultMode = defaultMode
        self.spanCycles = spanCycles
        self.horizonCycles = horizonCycles
        self.layers = layers
        self.pending = pending
        self.passHistory = passHistory
        self.launchInFlight = launchInFlight
    }

    /// The grid a launch quantizes to right now. Before the length is known
    /// (press-to-end, first layer) `cycle` degrades to the bar — there is no
    /// cycle yet to wait for, and waiting for a bar is what the performer sees.
    public var launchGrid: Double {
        switch quantize {
        case .instant: return 0
        case .bar: return beatsPerBar
        case .cycle: return cycleBeats ?? beatsPerBar
        }
    }

    /// The beat the materialised span currently ends at, or the origin when
    /// nothing has landed.
    public var spanEndBeat: Double {
        guard let cycleBeats else { return originBeat }
        return originBeat + Double(spanCycles) * cycleBeats
    }

    public func layer(id: UUID) -> LoopLayer? { layers.first { $0.id == id } }
    public func layer(onTrack trackID: UUID) -> LoopLayer? { layers.first { $0.trackID == trackID } }

    /// The lamp state of one layer — the ONE place the light language is
    /// decided, so the view has no opinion and cannot drift from the wire.
    public func state(of layer: LoopLayer) -> LoopLayerState {
        if let pending, pending.layerID == layer.id {
            switch pending.phase {
            case .queued: return .queued
            case .recording: return .recording
            case .closing: return .closing
            }
        }
        if layer.isMuted { return .muted }
        return .playing
    }
}

/// The deck's decision surface: a pure function from (deck, playhead) to what
/// the store should do next. No engine, no clock, no `Task` — every test is
/// arithmetic on fabricated beats, never a wall-clock sleep.
public enum LoopDeckScheduler {
    public enum Action: Equatable, Sendable {
        /// Fire `recordLayer()` — the capture window is about to open.
        case fireArm
        /// Fire `finishLayer()` — the window's close beat has arrived.
        case fireClose
        /// Tile every layer out to this many cycles: the playhead is running
        /// out of runway.
        case extendSpan(cycles: Int)
    }

    /// Everything due at this playhead position, in the order the store must
    /// apply it. Empty on the overwhelming majority of ticks.
    ///
    /// ⚠️ **DELIBERATELY IGNORES `deck.launchInFlight`** — see that property.
    /// This function answers "what is due at this beat" and nothing else, so
    /// every test of it is arithmetic on fabricated beats. The store owns the
    /// in-flight gate, because the store is what hops.
    public static func actions(deck: LoopDeck, playheadBeat: Double) -> [Action] {
        var out: [Action] = []
        if let pending = deck.pending {
            switch pending.phase {
            case .queued:
                if playheadBeat >= pending.armBeat - 1e-9 { out.append(.fireArm) }
            case .recording:
                break
            case .closing:
                if let close = pending.closeBeat, playheadBeat >= close - 1e-9 {
                    out.append(.fireClose)
                }
            }
        }
        if let cycleBeats = deck.cycleBeats, deck.spanCycles > 0 {
            let cycle = LoopDeckMath.cycleIndex(ofBeat: playheadBeat,
                                                origin: deck.originBeat,
                                                cycleBeats: cycleBeats)
            if let wanted = LoopDeckMath.extendedSpan(spanCycles: deck.spanCycles,
                                                      playheadCycle: cycle,
                                                      horizonCycles: deck.horizonCycles) {
                out.append(.extendSpan(cycles: wanted))
            }
        }
        return out
    }

    /// Where a launch pressed at `playheadBeat` actually opens, and when the arm
    /// must fire for the engine's capture anchor to be live by then.
    ///
    /// ⭐ **THE PRE-ROLL IS DERIVED FROM THE MUSIC, NOT HARDCODED IN
    /// MILLISECONDS.** One beat: at 120 BPM that is 500 ms, comfortably past the
    /// engine's ~70–300 ms pre-anchor drop window plus a 33 ms tick plus a
    /// main-actor hop, and it scales the right way when the tempo changes.
    /// A note played during the pre-roll is dropped by `fold`, so arming early
    /// costs nothing musically.
    ///
    /// ⭐⭐ **THE BOUNDARY IS SEARCHED FROM `playhead + preRoll`, NOT FROM
    /// `playhead` — AND THAT ONE TERM IS THE DIFFERENCE BETWEEN A LOOPER THAT
    /// KEEPS YOUR DOWNBEAT AND ONE THAT EATS IT.** Searching from the playhead
    /// lets a press that lands ON a boundary (or a few milliseconds before one)
    /// target a boundary that is already arriving, so the take's anchor — which
    /// the engine schedules ~70–300 ms AHEAD of the call — is still not live
    /// when the window opens, and the first chord of the layer is silently
    /// dropped. Guaranteeing the pre-roll makes that impossible by
    /// construction: `armBeat >= playheadBeat` always, so every layer's capture
    /// is provably rolling before its window opens.
    ///
    /// The stated cost, rather than a discovered one: a press within a beat of
    /// the boundary waits for the NEXT one. That is VISIBLE — the lamp keeps
    /// flashing `queued`, which the research names as the state that matters
    /// most — whereas a lost downbeat is invisible until playback.
    public static func plan(deck: LoopDeck,
                            playheadBeat: Double,
                            preRollBeats: Double = 1.0) -> (launchBeat: Double, armBeat: Double) {
        let grid = deck.launchGrid
        // `instant` has no grid and therefore no pre-roll: the window opens at
        // the press, and the first fraction of a beat may be lost to the
        // anchor. That is the honest cost of the setting, and is why it is not
        // the default.
        guard grid > 0 else { return (playheadBeat, playheadBeat) }
        let preRoll = max(0, preRollBeats)
        let launch = LoopDeckMath.boundary(atOrAfter: playheadBeat + preRoll,
                                           origin: deck.originBeat,
                                           grid: grid)
        return (launch, launch - preRoll)
    }
}
