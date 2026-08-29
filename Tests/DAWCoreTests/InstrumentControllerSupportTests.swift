import DAWCore
import Foundation
import Testing

// m27-b gates — the instrument-change warning that removes the
// "previously-dead controller data goes live with no warning anywhere" defect
// (a FINISHED, VERIFIED mix regressed 1.25 LU).
//
// TWO things are pinned here, and they fail for different reasons:
//  · the HONOURED-SET accessors on `MIDIControllerRouting` — `honors`,
//    `honoredCCs`, `forwardsAllControllers` — which read DAWCore's ONE routing
//    table. Their behavioural half (does the ENGINE agree?) lives in
//    DAWEngineTests/InstrumentControllerHonorPinTests.
//  · the PREDICATE (`InstrumentControllerChangeWarnings.warnings`) — wrong in
//    EITHER direction. Silence on the real regression is the reported bug;
//    a warning on every instrument change is noise, and noise gets ignored,
//    taking the one warning that mattered with it. Both directions are tested.
//
// ⭐ There is deliberately NO second table here. `MIDIControllerRouting`'s own
// header calls itself the ONE definition of "does this controller reach the
// sound?", and m27-b nearly shipped a parallel switch beside it — which is the
// exact drift this item exists to prevent.

private func lane(_ type: MIDIControllerType,
                  points: [MIDIControllerPoint] = [MIDIControllerPoint(beat: 0, value: 100)])
    -> MIDIControllerLane {
    MIDIControllerLane(type: type, points: points)
}

private func midiClip(_ lanes: [MIDIControllerLane]) -> Clip {
    Clip(name: "c", startBeat: 0, lengthBeats: 4,
         notes: [MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)],
         controllerLanes: lanes)
}

private let cc1 = MIDIControllerType.cc(controller: 1)
private let cc2 = MIDIControllerType.cc(controller: 2)
private let cc7 = MIDIControllerType.cc(controller: 7)
private let cc11 = MIDIControllerType.cc(controller: 11)
private let cc64 = MIDIControllerType.cc(controller: 64)
private let cc74 = MIDIControllerType.cc(controller: 74)

@Suite("Instrument controller support + change warnings (m27-b)")
struct InstrumentControllerSupportTests {

    // MARK: - The honoured set, per kind, through the ONE table

    @Test("polySynth honours CC64 and pitch bend ONLY — not CC11, not aftertouch")
    func polySynthHonoredSet() {
        let poly = InstrumentDescriptor(kind: .polySynth)
        #expect(MIDIControllerRouting.forwardsAllControllers(instrument: poly) == false)
        #expect(MIDIControllerRouting.honoredCCs(instrument: poly) == [64])
        #expect(MIDIControllerRouting.honors(cc64, instrument: poly))
        #expect(MIDIControllerRouting.honors(.pitchBend, instrument: poly))
        // THE DEFECT'S PRECONDITION: CC11 lanes authored here are inert data.
        #expect(MIDIControllerRouting.honors(cc11, instrument: poly) == false)
        #expect(MIDIControllerRouting.honors(cc1, instrument: poly) == false)
        #expect(MIDIControllerRouting.honors(cc7, instrument: poly) == false)
        #expect(MIDIControllerRouting.honors(.channelPressure, instrument: poly) == false)
    }

    @Test("testTone honours nothing at all — no controlChange or bend branch exists")
    func testToneHonoredSet() {
        let tone = InstrumentDescriptor(kind: .testTone)
        #expect(MIDIControllerRouting.forwardsAllControllers(instrument: tone) == false)
        #expect(MIDIControllerRouting.honoredCCs(instrument: tone).isEmpty)
        #expect(MIDIControllerRouting.honors(cc64, instrument: tone) == false)
        #expect(MIDIControllerRouting.honors(.pitchBend, instrument: tone) == false)
    }

    @Test("sampler honours CC11 + CC64 + bend unconditionally; CC1/CC2 only at depth > 0")
    func samplerHonoredSetDepthGated() {
        let plain = InstrumentDescriptor(kind: .sampler, sampler: SamplerParams())
        #expect(MIDIControllerRouting.honoredCCs(instrument: plain) == [11, 64])
        #expect(MIDIControllerRouting.honors(.pitchBend, instrument: plain))
        // ⭐ CC1/CC2 REACH the sampler but are INAUDIBLE at the default depth
        // of 0: the engine's `1 − depth × (1 − dynamics)` term is exactly 1.0
        // there, which the table models as `.routedButDisabled`. Reporting
        // "reaches the instrument" as "honoured" would warn about controllers
        // that provably cannot move a sample.
        #expect(MIDIControllerRouting.honors(cc1, instrument: plain) == false)
        #expect(MIDIControllerRouting.honors(cc2, instrument: plain) == false)

        let deep = InstrumentDescriptor(kind: .sampler,
                                        sampler: SamplerParams(expressionModDepth: 0.5))
        #expect(MIDIControllerRouting.honors(cc1, instrument: deep))
        #expect(MIDIControllerRouting.honors(cc2, instrument: deep))
        #expect(MIDIControllerRouting.honoredCCs(instrument: deep) == [1, 2, 11, 64])
    }

    // MARK: - The latent defect found while building m27-b

    @Test("sampler honours the brightness filter's CC while the filter is on")
    func samplerFilterControllerGated() {
        // ⛔ THIS SHIPPED WRONG. `samplerRoutedCCs` was treated as the whole
        // answer, so clip.setControllerLane told a user a CC74 lane "will not
        // sound" on a sampler whose filter really does sweep from CC74 — a
        // confidently wrong statement about what sounds, the same defect class
        // m27-b exists to remove, on the sibling verb.
        let off = InstrumentDescriptor(
            kind: .sampler,
            sampler: SamplerParams(expressionFilterDepth: 0, expressionFilterCC: 74))
        #expect(MIDIControllerRouting.honors(cc74, instrument: off) == false)
        #expect(MIDIControllerRouting.inertLaneWarning(for: cc74, instrument: off) != nil)

        let on = InstrumentDescriptor(
            kind: .sampler,
            sampler: SamplerParams(expressionFilterDepth: 0.6, expressionFilterCC: 74))
        #expect(MIDIControllerRouting.honors(cc74, instrument: on))
        #expect(MIDIControllerRouting.honoredCCs(instrument: on) == [11, 64, 74])
        // The shipped surface must stop lying, not merely the new one.
        #expect(MIDIControllerRouting.inertLaneWarning(for: cc74, instrument: on) == nil,
                "a filter-routed CC must not be reported as inert")
    }

    @Test("sampler honours a zone's CC-domain crossfade controller, not a bound-less one")
    func samplerCrossfadeController() {
        let url = URL(fileURLWithPath: "/tmp/m27b-fake.wav")
        let live = SamplerZone(
            audioFileURL: url, rootPitch: 60, minPitch: 0, maxPitch: 127, gain: 1,
            crossfade: SamplerCrossfade(controller: 20, ccInLo: 0, ccInHi: 64))
        let liveDescriptor = InstrumentDescriptor(kind: .sampler,
                                                  sampler: SamplerParams(zones: [live]))
        #expect(MIDIControllerRouting.honors(.cc(controller: 20), instrument: liveDescriptor))
        #expect(MIDIControllerRouting.inertLaneWarning(
            for: .cc(controller: 20), instrument: liveDescriptor) == nil)

        // Mirrors the engine's `hasCcXfade`: a controller with NO CC bound
        // cannot fade anything, so it is not honoured. (Velocity-only bounds
        // make the crossfade real but fix it at note-on — no CC involvement.)
        let velocityOnly = SamplerZone(
            audioFileURL: url, rootPitch: 60, minPitch: 0, maxPitch: 127, gain: 1,
            crossfade: SamplerCrossfade(controller: 21, velInLo: 0, velInHi: 64))
        let velDescriptor = InstrumentDescriptor(kind: .sampler,
                                                 sampler: SamplerParams(zones: [velocityOnly]))
        #expect(MIDIControllerRouting.honors(.cc(controller: 21),
                                             instrument: velDescriptor) == false)
    }

    @Test("a crossfade CC overrides the CC1/CC2 depth gate — it sounds at depth 0")
    func crossfadeControllerBeatsTheDepthGate() {
        // CC1 routed BOTH ways: the amplitude path (gated by
        // expressionModDepth) and a zone crossfade (not gated). The gate must
        // not veto a controller the crossfade really consumes.
        let zone = SamplerZone(
            audioFileURL: URL(fileURLWithPath: "/tmp/m27b-fake.wav"),
            rootPitch: 60, minPitch: 0, maxPitch: 127, gain: 1,
            crossfade: SamplerCrossfade(controller: 1, ccInLo: 0, ccInHi: 100))
        let descriptor = InstrumentDescriptor(kind: .sampler,
                                              sampler: SamplerParams(zones: [zone]))
        #expect(MIDIControllerRouting.honors(cc1, instrument: descriptor))
    }

    @Test("hosted kinds honour EVERY controller — .soundBank is a hosted AU too")
    func hostedKindsHonorEverything() {
        for kind in [InstrumentDescriptor.Kind.audioUnit, .soundBank] {
            let descriptor = InstrumentDescriptor(kind: kind)
            #expect(MIDIControllerRouting.forwardsAllControllers(instrument: descriptor),
                    "\(kind) must forward every CC")
            #expect(MIDIControllerRouting.honors(cc11, instrument: descriptor))
            #expect(MIDIControllerRouting.honors(cc7, instrument: descriptor))
            #expect(MIDIControllerRouting.honors(.cc(controller: 3), instrument: descriptor))
            #expect(MIDIControllerRouting.honors(.pitchBend, instrument: descriptor))
            #expect(MIDIControllerRouting.honors(.channelPressure, instrument: descriptor))
            // `all` makes enumeration meaningless — it must not pretend.
            #expect(MIDIControllerRouting.honoredCCs(instrument: descriptor).isEmpty)
        }
    }

    @Test("an instrument-less track honours nothing and enumerates nothing")
    func noInstrumentHonorsNothing() {
        #expect(MIDIControllerRouting.forwardsAllControllers(instrument: nil) == false)
        #expect(MIDIControllerRouting.honoredCCs(instrument: nil).isEmpty)
        #expect(MIDIControllerRouting.honors(cc11, instrument: nil) == false)
    }

    @Test("every kind answers — a new Kind case must decide its controller set")
    func everyKindProducesASupportSet() {
        for kind in InstrumentDescriptor.Kind.allCases {
            let descriptor = InstrumentDescriptor(kind: kind)
            let ccs = MIDIControllerRouting.honoredCCs(instrument: descriptor)
            #expect(MIDIControllerRouting.forwardsAllControllers(instrument: descriptor)
                    || ccs.count < 128, "\(kind) produced an incoherent set")
            #expect(ccs == ccs.sorted(), "\(kind) must enumerate ascending")
        }
        #expect(InstrumentDescriptor.Kind.allCases.count == 5)
    }

    // MARK: - Neutral defaults (the ⓒ teaching point's factual basis)

    @Test("neutral defaults: CC11 is 127, CC7 is 100, CC10 is 64, others 0")
    func neutralDefaults() {
        // ⚠️ The roadmap sentence said "CC11/CC7 default to 127". CC7 is 100.
        #expect(cc11.neutralDefault == 127)
        #expect(cc7.neutralDefault == 100)
        #expect(MIDIControllerType.cc(controller: 10).neutralDefault == 64)
        #expect(cc1.neutralDefault == 0)
        #expect(cc64.neutralDefault == 0)
        #expect(MIDIControllerType.pitchBend.neutralDefault == 8_192)
    }

    // MARK: - THE PREDICATE — must warn

    @Test("MUST WARN: the reported defect — CC11 lanes, polySynth → soundBank")
    func warnsWhenCC11GoesLiveOnSoundBank() throws {
        let clips = [midiClip([lane(cc11, points: [
            MIDIControllerPoint(beat: 0, value: 106),
            MIDIControllerPoint(beat: 2, value: 42),
        ])])]
        let warnings = InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .polySynth),
            to: InstrumentDescriptor(kind: .soundBank),
            carriedLaneTypes: InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips))

        #expect(warnings.count == 1)
        let warning = try #require(warnings.first)
        #expect(warning.type == cc11)
        #expect(warning.effect == .becameLive)
        // The message must carry the MECHANISM — full-scale neutral — because
        // that is what makes an innocuous-looking lane a broad attenuation.
        #expect(warning.message.contains("127"))
        #expect(warning.message.lowercased().contains("attenuat"))
        // ONE name for the controller across both halves of this feature.
        #expect(warning.message.contains(MIDIControllerRouting.describe(cc11)))
    }

    @Test("MUST WARN: within ONE kind — raising expressionModDepth makes CC2 lanes live")
    func warnsOnSameKindDepthFlip() {
        // No kind change at all: a kind-keyed comparison would miss this
        // entirely, which is why the question is asked of the DESCRIPTOR.
        let clips = [midiClip([lane(cc2)])]
        let warnings = InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .sampler, sampler: SamplerParams()),
            to: InstrumentDescriptor(kind: .sampler,
                                     sampler: SamplerParams(expressionModDepth: 0.7)),
            carriedLaneTypes: InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips))
        #expect(warnings.map(\.type) == [cc2])
        #expect(warnings.first?.effect == .becameLive)
    }

    @Test("MUST WARN: turning the brightness filter on makes a CC74 lane live")
    func warnsWhenFilterControllerGoesLive() {
        let clips = [midiClip([lane(cc74)])]
        let types = InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips)
        let warnings = InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(
                kind: .sampler, sampler: SamplerParams(expressionFilterCC: 74)),
            to: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(expressionFilterDepth: 0.5, expressionFilterCC: 74)),
            carriedLaneTypes: types)
        #expect(warnings.map(\.type) == [cc74])
        #expect(warnings.first?.effect == .becameLive)
    }

    @Test("MUST WARN (mirror): bend lanes go INERT moving polySynth → testTone")
    func warnsWhenBendGoesInert() {
        let clips = [midiClip([lane(.pitchBend, points: [
            MIDIControllerPoint(beat: 0, value: 8_192),
            MIDIControllerPoint(beat: 1, value: 12_288),
        ])])]
        let warnings = InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .polySynth),
            to: InstrumentDescriptor(kind: .testTone),
            carriedLaneTypes: InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips))
        #expect(warnings.map(\.type) == [.pitchBend])
        #expect(warnings.first?.effect == .becameInert)
    }

    @Test("MUST WARN: CC7 goes live, and the message says its neutral is 100")
    func warnsCC7WithItsOwnNeutral() throws {
        let clips = [midiClip([lane(cc7, points: [MIDIControllerPoint(beat: 0, value: 80)])])]
        let warnings = InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .polySynth),
            to: InstrumentDescriptor(kind: .soundBank),
            carriedLaneTypes: InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips))
        let warning = try #require(warnings.first(where: { $0.type == cc7 }))
        #expect(warning.message.contains("100"))
        #expect(warning.message.contains("127") == false, "CC7's neutral is 100, not 127")
    }

    @Test("warnings are ordered deterministically and cover every changed lane")
    func warnsForEveryChangedLaneInStableOrder() {
        let clips = [midiClip([lane(cc11), lane(cc1), lane(.pitchBend, points: [
            MIDIControllerPoint(beat: 0, value: 9_000),
        ])])]
        let warnings = InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .testTone),
            to: InstrumentDescriptor(kind: .soundBank),
            carriedLaneTypes: InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips))
        #expect(warnings.map(\.type) == [cc1, cc11, .pitchBend])
        #expect(warnings.allSatisfy { $0.effect == .becameLive })
    }

    // MARK: - THE PREDICATE — must NOT warn (the noise half)

    @Test("MUST NOT WARN: a track carrying NO controller lanes, however wild the change")
    func silentWithNoLanes() {
        // polySynth → soundBank changes the honoured answer for all 128 CCs.
        // With no authored data there is nothing whose meaning moved.
        #expect(InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .polySynth),
            to: InstrumentDescriptor(kind: .soundBank),
            carriedLaneTypes: []).isEmpty)

        let notesOnly = [midiClip([])]
        #expect(InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .polySynth),
            to: InstrumentDescriptor(kind: .soundBank),
            carriedLaneTypes: InstrumentControllerChangeWarnings
                .carriedLaneTypes(in: notesOnly)).isEmpty)
    }

    @Test("MUST NOT WARN: CC64-only lanes, polySynth → sampler (both honour CC64)")
    func silentWhenBothHonorTheCarriedLane() {
        let clips = [midiClip([lane(cc64, points: [MIDIControllerPoint(beat: 0, value: 127)])])]
        #expect(InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .polySynth),
            to: InstrumentDescriptor(kind: .sampler, sampler: SamplerParams()),
            carriedLaneTypes: InstrumentControllerChangeWarnings
                .carriedLaneTypes(in: clips)).isEmpty)
    }

    @Test("MUST NOT WARN: CC11 lanes, sampler → soundBank — both honour CC11")
    func silentWhenCC11StaysHonored() {
        // MEMBERSHIP is the contract, deliberately. "Honours it differently in
        // degree" is not decidable from here — a hosted AU's CC11 curve is the
        // plug-in's business — and guessing would reintroduce the false
        // confidence this item exists to remove.
        let clips = [midiClip([lane(cc11)])]
        #expect(InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .sampler, sampler: SamplerParams()),
            to: InstrumentDescriptor(kind: .soundBank),
            carriedLaneTypes: InstrumentControllerChangeWarnings
                .carriedLaneTypes(in: clips)).isEmpty)
    }

    @Test("MUST NOT WARN: tweaking an unrelated parameter on the same kind")
    func silentOnUnrelatedParameterEdit() {
        let clips = [midiClip([lane(cc11), lane(cc64)])]
        let types = InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips)
        #expect(InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .sampler,
                                               sampler: SamplerParams(attack: 0.01)),
            to: InstrumentDescriptor(kind: .sampler,
                                     sampler: SamplerParams(attack: 0.4)),
            carriedLaneTypes: types).isEmpty)
    }

    @Test("MUST NOT WARN: an EMPTY lane — it cannot change any sound")
    func silentOnPointlessLane() {
        let clips = [midiClip([MIDIControllerLane(type: cc11, points: [])])]
        let types = InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips)
        #expect(types.isEmpty, "a lane with no points carries no data")
        #expect(InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .polySynth),
            to: InstrumentDescriptor(kind: .soundBank),
            carriedLaneTypes: types).isEmpty)
    }

    @Test("MUST NOT WARN: an identical descriptor, whatever lanes exist")
    func silentOnNoChange() {
        let clips = [midiClip([lane(cc11), lane(cc1), lane(cc64), lane(.pitchBend)])]
        let types = InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips)
        for kind in InstrumentDescriptor.Kind.allCases {
            let descriptor = InstrumentDescriptor(kind: kind, sampler: SamplerParams())
            #expect(InstrumentControllerChangeWarnings.warnings(
                changingFrom: descriptor, to: descriptor,
                carriedLaneTypes: types).isEmpty, "\(kind) warned about itself")
        }
    }

    @Test("a nil outgoing descriptor resolves to .default (polySynth), not to silence")
    func nilOldDescriptorResolvesToDefault() {
        // `PlaybackGraph.instrumentFactory` renders a track with no descriptor
        // as `.default`; the warning must compare against the same thing.
        let clips = [midiClip([lane(cc11), lane(cc64)])]
        let types = InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips)
        let warnings = InstrumentControllerChangeWarnings.warnings(
            changingFrom: nil, to: InstrumentDescriptor(kind: .soundBank),
            carriedLaneTypes: types)
        // CC11 was inert under the default polySynth → warns. CC64 was already
        // honoured there → must not.
        #expect(warnings.map(\.type) == [cc11])
    }

    @Test("the warning never touches the user's data — it only describes")
    func warningsAreNonDestructive() {
        // ⛔ Silently neutralising correct-but-newly-live lanes would be a
        // WORSE bug than the one being fixed. The API takes value types and
        // returns descriptions; this pins that there is no mutating path.
        let original = midiClip([lane(cc11, points: [
            MIDIControllerPoint(beat: 0, value: 106),
            MIDIControllerPoint(beat: 2, value: 42),
        ])])
        let clips = [original]
        _ = InstrumentControllerChangeWarnings.warnings(
            changingFrom: InstrumentDescriptor(kind: .polySynth),
            to: InstrumentDescriptor(kind: .soundBank),
            carriedLaneTypes: InstrumentControllerChangeWarnings.carriedLaneTypes(in: clips))
        #expect(clips == [original])
        #expect(clips[0].controllerLanes.first?.points.map(\.value) == [106, 42])
    }
}
