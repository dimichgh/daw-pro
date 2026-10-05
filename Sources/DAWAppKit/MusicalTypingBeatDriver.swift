import Foundation

// m34-g — THE TICK SOURCE FOR ON-THE-BEAT MODE.
//
// ═══ WHY A VALUE TYPE AND NOT A TIMER ═══
//
// `ChordSequencePlayer.beat()` has existed since m34-i with nothing calling it —
// m34-i said so in public rather than hiding it. This is the caller, and it is
// deliberately split in two: a PURE sampler (this file, unit-testable, no clock,
// no store, no SwiftUI) and a thin app-side poll that feeds it
// `store.transport.positionBeats`. The app half can only get the plumbing wrong;
// every musical decision is here, where a test can see it.
//
// ⚠️ **AND IT IS NOT WRITTEN FROM INSIDE A `TimelineView` CLOSURE.**
// `DAWProApp.swift:3581` records the hazard by name: observed state written
// during a view update. The driver is polled from a `Timer` the app owns, on the
// main actor, exactly like `stretchPollTimer`.

/// Turns a moving playhead into **downbeat ticks**.
///
/// ⭐⭐ **ONE CHORD PER BAR, NOT PER BEAT — AND THAT IS THE DESIGN DECISION IN
/// THIS FILE.** `beat()` is the player's verb for "one advance tick"; the app
/// chooses the musical period. A chord per beat is a chord every 500 ms at
/// 120 BPM, which is punishing for the beginner this whole surface exists for,
/// and every progression the app ships (`ChordProgressionLibrary`) is written one
/// chord per bar. So the tick is the **downbeat**.
///
/// ⭐ **COUNT-IN NEEDS NO SPECIAL CASE, AND THAT IS MEASURED, NOT ASSUMED.**
/// `AudioEngine.startPlayers`' own doc: with `countInBars > 0` the clip anchor is
/// delayed and *"the playhead sits exactly at `beats` for the whole count-in
/// instead of reading negative motion"*. A frozen playhead never changes bar, so
/// this emits nothing while the click counts you in — the lights wait for you
/// rather than eating chords nobody could have played. `frozenPlayheadEmitsNoTicks`
/// pins it.
public struct MusicalTypingBeatDriver: Sendable, Equatable {

    /// The bar the last sample landed in. `nil` means "not running" — the state
    /// a stopped transport resets to, so the next take starts its phase fresh
    /// instead of inheriting where the last one stopped.
    public private(set) var lastBarIndex: Int?

    /// The most ticks one sample may emit.
    ///
    /// ⚠️ **A CLAMP, NOT A BUDGET.** The poll runs far faster than a bar, so the
    /// ordinary delta is 0 or 1; this only bounds a pathological jump (a seek to
    /// bar 400 mid-playback) so the cue steps rather than spins.
    public static let maxTicksPerSample = 4

    public init() {}

    /// Sample the transport. Call it as often as you like.
    ///
    /// - Parameters:
    ///   - beat: `TransportState.positionBeats`.
    ///   - beatsPerBar: the meter's numerator at that position.
    ///   - isRunning: whether the transport is playing (or recording).
    /// - Returns: how many times to call `beat()` — **0 on the first sample of a
    ///   run**, deliberately: the cue is already sitting on the chord you are
    ///   meant to start with, and firing on arrival would skip it before the bar
    ///   it belongs to had been played.
    public mutating func downbeats(atBeat beat: Double, beatsPerBar: Int,
                                   isRunning: Bool) -> Int {
        guard isRunning, beatsPerBar > 0, beat.isFinite else {
            lastBarIndex = nil
            return 0
        }
        let bar = Int((beat / Double(beatsPerBar)).rounded(.down))
        guard let last = lastBarIndex else {
            // First sample of the run: latch the phase, emit nothing.
            lastBarIndex = bar
            return 0
        }
        guard bar != last else { return 0 }
        lastBarIndex = bar
        if bar < last {
            // ⭐ **A BACKWARD JUMP IS EXACTLY ONE TICK, WHICH IS WHAT A LOOP
            // WRAP MUST BE.** Looping four bars under a four-chord progression,
            // bar 4 → bar 1 is a downbeat crossing like any other and the cue
            // has to move onto chord 1. Counting the negative delta would run
            // the cue backwards; ignoring it would freeze the lights every time
            // the loop came round, which is precisely when this mode is used.
            return 1
        }
        return min(bar - last, Self.maxTicksPerSample)
    }

    /// Forget the phase. The app calls this when chord mode or the advance mode
    /// changes, so a fresh on-the-beat run does not inherit a stale bar.
    public mutating func reset() { lastBarIndex = nil }
}
