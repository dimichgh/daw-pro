import Foundation
import Testing
@testable import DAWAppKit

/// m34-g — **THE TICK SOURCE FOR ON-THE-BEAT MODE.**
///
/// ⭐ m34-i shipped `ChordSequencePlayer.beat()` with nothing calling it and said
/// so in public. This suite pins the caller's musical decisions — one chord per
/// BAR, silence during count-in, one tick on a loop wrap — where a test can see
/// them, so the app half is left with nothing but plumbing to get wrong.
@Suite("Musical Typing beat driver (m34-g)")
struct MusicalTypingBeatDriverTests {

    @Test("the FIRST sample of a run emits nothing — the cue owns the bar it starts on")
    func firstSampleLatchesPhaseWithoutFiring() {
        var driver = MusicalTypingBeatDriver()
        #expect(driver.downbeats(atBeat: 0, beatsPerBar: 4, isRunning: true) == 0)
        #expect(driver.lastBarIndex == 0)
        // Mid-bar samples change nothing.
        #expect(driver.downbeats(atBeat: 1.5, beatsPerBar: 4, isRunning: true) == 0)
        #expect(driver.downbeats(atBeat: 3.99, beatsPerBar: 4, isRunning: true) == 0)
    }

    @Test("⭐ ONE tick per BAR, not per beat")
    func oneTickPerBar() {
        var driver = MusicalTypingBeatDriver()
        _ = driver.downbeats(atBeat: 0, beatsPerBar: 4, isRunning: true)
        var ticks = 0
        // Sample every half beat across four bars, the way a 30 Hz poll would.
        var beat = 0.0
        while beat < 16.0 {
            beat += 0.5
            ticks += driver.downbeats(atBeat: beat, beatsPerBar: 4, isRunning: true)
        }
        #expect(ticks == 4, "sixteen beats is four downbeats — not sixteen")
    }

    @Test("a 3/4 bar ticks every three beats")
    func meterIsRespected() {
        var driver = MusicalTypingBeatDriver()
        _ = driver.downbeats(atBeat: 0, beatsPerBar: 3, isRunning: true)
        #expect(driver.downbeats(atBeat: 2.9, beatsPerBar: 3, isRunning: true) == 0)
        #expect(driver.downbeats(atBeat: 3.0, beatsPerBar: 3, isRunning: true) == 1)
        #expect(driver.downbeats(atBeat: 6.0, beatsPerBar: 3, isRunning: true) == 1)
    }

    /// ⭐⭐ **COUNT-IN NEEDS NO SPECIAL CASE, AND THIS IS THE ASSERTION THAT SAYS
    /// SO.** `AudioEngine.startPlayers`' own doc records that the playhead *sits
    /// exactly at `beats` for the whole count-in* rather than reading negative
    /// motion. A frozen playhead never changes bar, so the lights wait for you
    /// instead of eating chords nobody could have played.
    @Test("⭐ a FROZEN playhead emits no ticks — which is what count-in looks like")
    func frozenPlayheadEmitsNoTicks() {
        var driver = MusicalTypingBeatDriver()
        _ = driver.downbeats(atBeat: 8.0, beatsPerBar: 4, isRunning: true)
        for _ in 0..<60 {
            #expect(driver.downbeats(atBeat: 8.0, beatsPerBar: 4, isRunning: true) == 0)
        }
        // …and it starts ticking the moment the playhead actually moves on.
        #expect(driver.downbeats(atBeat: 12.0, beatsPerBar: 4, isRunning: true) == 1)
    }

    /// ⭐ A loop wrap IS a downbeat crossing. Counting the negative delta would
    /// run the cue backwards; ignoring it would freeze the lights every time the
    /// loop came round — precisely when this mode is being used.
    @Test("⭐ a LOOP WRAP is exactly one tick")
    func loopWrapIsOneTick() {
        var driver = MusicalTypingBeatDriver()
        _ = driver.downbeats(atBeat: 0, beatsPerBar: 4, isRunning: true)
        #expect(driver.downbeats(atBeat: 12.0, beatsPerBar: 4, isRunning: true) == 3)
        #expect(driver.downbeats(atBeat: 0.0, beatsPerBar: 4, isRunning: true) == 1,
                "bar 4 → bar 1 moves the cue forward one chord, not back three")
    }

    @Test("a pathological forward jump STEPS rather than spins")
    func hugeJumpIsClamped() {
        var driver = MusicalTypingBeatDriver()
        _ = driver.downbeats(atBeat: 0, beatsPerBar: 4, isRunning: true)
        #expect(driver.downbeats(atBeat: 4000, beatsPerBar: 4, isRunning: true)
                == MusicalTypingBeatDriver.maxTicksPerSample)
    }

    @Test("stopping resets the phase, so the next take starts fresh")
    func stoppingResetsPhase() {
        var driver = MusicalTypingBeatDriver()
        _ = driver.downbeats(atBeat: 0, beatsPerBar: 4, isRunning: true)
        _ = driver.downbeats(atBeat: 8, beatsPerBar: 4, isRunning: true)
        #expect(driver.lastBarIndex == 2)
        #expect(driver.downbeats(atBeat: 8, beatsPerBar: 4, isRunning: false) == 0)
        #expect(driver.lastBarIndex == nil)
        // Re-running latches again without firing.
        #expect(driver.downbeats(atBeat: 8, beatsPerBar: 4, isRunning: true) == 0)
    }

    @Test("nonsense inputs are inert rather than fatal")
    func degenerateInputs() {
        var driver = MusicalTypingBeatDriver()
        #expect(driver.downbeats(atBeat: 0, beatsPerBar: 0, isRunning: true) == 0)
        #expect(driver.downbeats(atBeat: .nan, beatsPerBar: 4, isRunning: true) == 0)
        #expect(driver.downbeats(atBeat: .infinity, beatsPerBar: 4, isRunning: true) == 0)
        driver.reset()
        #expect(driver.lastBarIndex == nil)
    }
}
