import AVFAudio

/// A software instrument pulled by an instrument track's source node.
/// `render()`/`reset()` run ON THE AUDIO RENDER THREAD: no allocation, no
/// locks, no ObjC dispatch, no actor hops. `prepare()` runs on the main actor
/// before the node ever renders — allocate there.
///
/// This is deliberately the AUv3-shaped seam: for M3 (vi) a hosting wrapper
/// implements the same delivery by converting the per-quantum slice to an
/// `AURenderEvent` linked list (`eventSampleTime = quantumBase +
/// max(0, e.sampleTime − renderStart)`, status 0x90/0x80) ahead of the AU's
/// renderBlock call.
protocol InstrumentRendering: AnyObject {
    /// Main-actor setup before the node renders; allocate everything here.
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int)

    /// One render quantum. `events` is the schedule slice whose sampleTime
    /// falls in [renderStart, renderStart + frameCount), sorted, PLUS possibly
    /// a few late events (sampleTime < renderStart, only after a skipped or
    /// overloaded quantum) — clamp those to offset 0. In-quantum offset for
    /// event e:
    ///     max(0, Int(e.sampleTime - renderStart))
    /// Write exactly `frameCount` frames to every channel of `output`
    /// (zeros when idle).
    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                renderStart: Int64,
                frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer)

    /// All-notes-off NOW. Render-thread-safe by contract. After reset() the
    /// instrument MUST output silence until the next noteOn.
    func reset()

    /// m39-e P1 — the instrument's modulation delivery slot. MAIN ACTOR:
    /// `nil` unpublishes; the instrument stores the snapshot in its own atomic
    /// slot and evaluates it INSIDE the per-frame loop it already runs, at
    /// `renderStart + frame`.
    ///
    /// ⭐ This is the whole of the instrument delivery path, and it is why
    /// m39-b and m39-e are one change rather than two: `AutomationRenderer`
    /// has no path to `track.instrument` at all, so "add the enum case" would
    /// have unblocked ADDRESSING and delivered nothing (design §10 H3).
    ///
    /// `render(events:renderStart:frameCount:output:)` is UNTOUCHED —
    /// `renderStart` is already the position-absolute anchor this needs.
    @MainActor func publishModulation(_ snapshot: ModulationSnapshot?)
}

extension InstrumentRendering {
    /// Default-inert, exactly as `EffectRendering.storeAutomatedParam` is: an
    /// instrument that does not participate needs ZERO edits. Sampler,
    /// TestTone and EventCapture are all covered by this line in v1.
    @MainActor func publishModulation(_ snapshot: ModulationSnapshot?) {}
}
