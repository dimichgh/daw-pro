import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

// m39-pads — PADS MODE on the controller, and the PAD GRID's model.
//
// ⛔⛔ **THESE ARE AN EXTENSION OF `MusicalTypingControllerTests`, NOT A NEW
// SUITE, AND THAT IS FORCED RATHER THAN CHOSEN.** The tree's `@MainActor`-suite
// cadence cap is 380 and the census measured EXACTLY 380 before this item — zero
// slack — so a new `@MainActor @Suite` was not available. Folding is the same
// remedy m26-i was forced into (and the fourth consecutive item to be; the fix
// is m23-aw-4, not more folding). It is also the honest home: pads mode IS a
// controller mode, and `PadGridModel` holds the controller and reads its state.
//
// Swift Testing discovers `@Test` methods declared in an extension of a suite
// type, so these run inside "Musical Typing controller (m23-ct)".
//
// ⚠️ The parent suite's spy sink and `press` helper are `private`, so this file
// carries its own. That is a deliberate second copy of six lines rather than
// widening the parent's access for a neighbour.
extension MusicalTypingControllerTests {

    // MARK: - Local harness

    /// Records every set handed across the seam — the ONLY instrument that can
    /// see whether a key actually reached the engine seam. See `padKeySoundsThePad`.
    fileprivate final class PadSpySink: LiveNoteSink {
        var sets: [[Int]] = []
        var velocities: [Int] = []
        var last: [Int] { sets.last ?? [] }
        func setHeldPitches(_ pitches: [Int], velocity: Int) {
            sets.append(pitches)
            velocities.append(velocity)
        }
    }

    fileprivate func makePadController() -> (MusicalTypingController, PadSpySink) {
        let sink = PadSpySink()
        let controller = MusicalTypingController(sink: sink)
        controller.targetState = .ready
        controller.setEnabled(true)
        controller.setPlayMode(.pads)
        return (controller, sink)
    }

    @discardableResult
    fileprivate func padPress(_ label: String, on controller: MusicalTypingController)
        -> MusicalTypingDecision {
        guard let cap = Self.padCap(label) else {
            Issue.record("'\(label)' is not a pads-mode key")
            return .passThrough(.unmapped)
        }
        return controller.handleKeyDown(keyCode: cap.keyCode, modifiers: [],
                                        isRepeat: false, responder: .none, window: .main)
    }

    @discardableResult
    fileprivate func padRelease(_ label: String, on controller: MusicalTypingController) -> Bool {
        guard let cap = Self.padCap(label) else { return false }
        return controller.releaseKey(keyCode: cap.keyCode)
    }

    /// ⚠️ PADS MODE'S OWN TABLE. `cap(forLabel:)` searches `allCaps`, which does
    /// not contain `Q R 1 2 3 4` at all — a helper that used it would silently
    /// report "not a layout key" for a third of the pad block.
    fileprivate static func padCap(_ label: String) -> MusicalTypingKeyCap? {
        MusicalTypingRouting.padAllCaps.first { $0.label == label }
    }

    /// Presses a key by its PHYSICAL position, whichever table owns it — the
    /// only way to ask "what does pads mode do with a key it does NOT claim?".
    @discardableResult
    fileprivate func anyKeyPress(_ label: String, on controller: MusicalTypingController)
        -> MusicalTypingDecision {
        guard let cap = MusicalTypingRouting.cap(forLabel: label)
                ?? Self.padCap(label) else {
            Issue.record("'\(label)' is on no layout at all")
            return .passThrough(.unmapped)
        }
        return controller.handleKeyDown(keyCode: cap.keyCode, modifiers: [],
                                        isRepeat: false, responder: .none, window: .main)
    }

    // MARK: - The keys drum the pads

    /// ⭐⭐⭐ **THE ANTI-INERT TEST.** m39-e shipped a whole modulation layer
    /// that did NOTHING with 24 tests green, because every test asked the model
    /// what it believed instead of asking the SEAM what it received. This asks
    /// the seam. A pads branch that computed a pitch and never called `sound`
    /// would leave `soundingPitches` empty here — and would pass any test that
    /// only checked `padPitch(index:)`.
    @Test("⭐ a pad key REACHES THE SINK with the pad's own pitch (anti-inert)")
    func padKeySoundsThePad() {
        let (controller, sink) = makePadController()
        padPress("Z", on: controller)          // BOTTOM-left = pad 1
        #expect(controller.soundingPitches == [36])
        // The second instrument: what actually crossed the seam.
        #expect(sink.last == [36])
        #expect(sink.sets.count >= 1)
    }

    @Test("⭐ pads mode computes PAD arithmetic, not OCTAVE arithmetic")
    func padPitchDiscriminatesFromNoteMode() {
        let (controller, _) = makePadController()
        // "W" is pad 10 (index 9) in the spatial block AND semitone 1 in the
        // piano row — one physical key with two meanings, which is what makes
        // the branch's existence observable.
        padPress("W", on: controller)
        // Pad arithmetic: base 36 + index 9 = 45.
        #expect(controller.soundingPitches == [45])
        controller.releaseAll()

        // The SAME key in notes mode, at the default octave, is 61. If the pads
        // branch were missing and the press fell through to the note path, the
        // test above would read 61.
        controller.setPlayMode(.notes)
        padPress("W", on: controller)
        #expect(controller.soundingPitches == [61])
        #expect(controller.soundingPitches != [45])
    }

    @Test("⛔ the PIANO ROW is not claimed in pads mode — it passes through")
    func pianoRowIsUnclaimedInPadsMode() {
        // ⭐ THE LAND-GRAB TEST, AND IT RUNS BOTH WAYS. Pads mode swaps the key
        // table wholesale: the spatial block is claimed and the piano keys that
        // are NOT part of it (`T G Y H U J ;`) stop being ours entirely, so a
        // stray `;` is passed to the app rather than silently swallowed.
        let (controller, sink) = makePadController()
        let pushesBefore = sink.sets.count
        #expect(anyKeyPress(";", on: controller) == .passThrough(.unmapped))
        #expect(anyKeyPress("T", on: controller) == .passThrough(.unmapped))
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.sets.count == pushesBefore)

        // Discriminating control: both are real notes in notes mode, so the
        // silence above is the mode's key table and not a broken one.
        controller.setPlayMode(.notes)
        anyKeyPress(";", on: controller)
        #expect(controller.soundingPitches == [76])
    }

    @Test("two pad keys held together both ring — finger drumming needs polyphony")
    func padsArePolyphonic() {
        let (controller, sink) = makePadController()
        padPress("Z", on: controller)          // pad 1  → 36
        padPress("C", on: controller)          // pad 3  → 38
        #expect(controller.soundingPitches == [36, 38])
        #expect(sink.last == [36, 38])
        padRelease("Z", on: controller)
        #expect(controller.soundingPitches == [38])
        padRelease("C", on: controller)
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.last.isEmpty)
    }

    // MARK: - Banks

    @Test("⭐ K/L move the BANK in pads mode, and Z/X are PADS there, not the octave")
    func bankKeysMoveOnlyTheBank() {
        let (controller, _) = makePadController()
        let octaveBefore = controller.baseOctave
        padPress("L", on: controller)
        #expect(controller.padBank == 1)
        // ⚠️ AND THE OCTAVE DID NOT MOVE — a branch that shifted BOTH would
        // leave notes mode transposed after a visit to the pads.
        #expect(controller.baseOctave == octaveBefore)
        padPress("K", on: controller)
        #expect(controller.padBank == 0)
        // Bank 0 is the floor; K again changes nothing.
        padPress("K", on: controller)
        #expect(controller.padBank == 0)

        // ⛔⛔ THE KEY THAT CHANGED MEANING. `Z` shifted the octave down before
        // pads mode existed; in pads mode it is PAD 1 and must not touch the
        // octave at all.
        controller.setPadBank(0)
        padPress("Z", on: controller)
        #expect(controller.soundingPitches == [36])
        #expect(controller.baseOctave == octaveBefore)
        #expect(controller.padBank == 0)
        controller.releaseAll()

        // The discriminating control: the same key IS the octave in notes mode.
        controller.setPlayMode(.notes)
        padPress("Z", on: controller)
        #expect(controller.baseOctave == octaveBefore - 1)
    }

    @Test("bank 2's pad 1 is 16 semitones up, not 12")
    func bankTwoStridesSixteen() {
        let (controller, _) = makePadController()
        controller.setPadBank(1)
        padPress("Z", on: controller)
        #expect(controller.soundingPitches == [52])
        #expect(controller.soundingPitches != [48])
    }

    @Test("a bank whose pad 1 would leave MIDI is refused, never clamped")
    func bankRefusesPastMIDI() {
        let (controller, _) = makePadController()
        controller.setPadBaseNote(112)
        #expect(controller.padBaseNote == 112)
        controller.setPadBank(0)
        // Bank 1 would need note 112 + 16 = 128. Refused outright, so no bank
        // is ever reachable that cannot sound its own first pad.
        #expect(PadGridGeometry.pitch(forPad: 0, baseNote: 112, bank: 1) == nil)
        controller.setPadBank(1)
        #expect(controller.padBank == 0)
        // And pad 1 of the bank that IS reachable still sounds.
        padPress("Z", on: controller)
        #expect(controller.soundingPitches == [112])
    }

    @Test("⛔ a held pad releases the pad it STRUCK, even after the bank moved")
    func heldPadSurvivesABankChange() {
        // The stuck-note case: `keyPitches` remembers what each key started, so
        // re-deriving on release would stop a pad that was never sounding and
        // strand the one that is.
        let (controller, _) = makePadController()
        padPress("Z", on: controller)
        #expect(controller.soundingPitches == [36])
        controller.setPadBank(1)
        padRelease("Z", on: controller)
        #expect(controller.soundingPitches.isEmpty)
    }

    // MARK: - Velocity

    @Test("setVelocity clamps into the audition range and never reaches 0")
    func velocityClamps() {
        let (controller, _) = makePadController()
        controller.setVelocity(200)
        #expect(controller.velocity == 127)
        controller.setVelocity(0)
        #expect(controller.velocity == 1)
        controller.setVelocity(-40)
        #expect(controller.velocity == 1)
    }

    @Test("a pad struck near the top pushes a LOUDER velocity across the seam")
    func strikePositionReachesTheSink() {
        let (controller, sink) = makePadController()
        let model = PadGridModel(typing: controller, zones: { [] }, targetName: { nil })
        model.padDown(index: 0, normalizedY: 0.95)
        let soft = sink.velocities.last ?? -1
        model.padUp()
        model.padDown(index: 0, normalizedY: 0.05)
        let loud = sink.velocities.last ?? -1
        #expect(soft < loud)
        #expect(soft >= 1)
        #expect(loud <= 127)
    }

    // MARK: - PadGridModel: loaded vs empty

    fileprivate func zone(_ pitch: Int, start: Int = 0) -> SamplerZone {
        SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/Loop.wav"),
                    rootPitch: pitch, minPitch: pitch, maxPitch: pitch,
                    startFrame: start, endFrame: start + 1000)
    }

    @Test("⭐ loaded and empty pads are DISTINGUISHABLE, and the ordinals span all banks")
    func padsReportLoadedState() {
        let controller = MusicalTypingController()
        let zones = (0..<20).map { zone(36 + $0, start: $0 * 1000) }
        let model = PadGridModel(typing: controller, zones: { zones },
                                 targetName: { "Vocal chops" })
        #expect(model.loadedCount == 20)
        #expect(model.bankCount == 2)

        let bank0 = model.pads
        #expect(bank0.count == 16)
        #expect(bank0.filter(\.isLoaded).count == 16)
        #expect(bank0[0].pitch == 36)
        // ⚠️⚠️ **"C2", AND THE MISMATCH WITH THE CHOPPER'S OWN COMMENT IS A
        // FINDING, NOT A BUG HERE.** `SliceToSamplerSettings.defaultBaseNote`
        // is documented as *"36 = C1, the MPC pad-1 note"* — the Yamaha/MPC
        // octave convention. This app's ONE note namer,
        // `Fundamental.noteName`, uses scientific pitch (MIDI 60 = C4), which
        // makes 36 "C2". The grid uses the APP's namer, because a pad grid that
        // invented a second octave convention would disagree with the piano
        // roll, the key gutter and the sampler card about the same note. The
        // chopper's comment is the thing that is out of step; it is prose, not
        // behaviour, and correcting it is not this item's business.
        #expect(bank0[0].noteName == Fundamental.noteName(midiNote: 36))
        #expect(bank0[0].noteName == "C2")
        // Pad 1's key is bottom-left on the keyboard, matching bottom-left on
        // the grid (m39-pads-2's spatial block).
        #expect(bank0[0].keyLabel == "Z")
        #expect(bank0[0].sliceOrdinal == 1)
        #expect(bank0[15].sliceOrdinal == 16)

        // ⭐ BANK 2's FIRST PAD READS "SLICE 17", NOT "SLICE 1" — the ordinal
        // is over the whole keymap. Numbering per bank would make four
        // different slices all call themselves slice 1.
        model.setBank(1)
        let bank1 = model.pads
        #expect(bank1[0].sliceOrdinal == 17)
        #expect(bank1[3].sliceOrdinal == 20)
        // And the rest of bank 2 is honestly EMPTY.
        #expect(bank1[4].isLoaded == false)
        #expect(bank1[4].sliceOrdinal == nil)
        #expect(bank1.filter(\.isLoaded).count == 4)
    }

    @Test("a pad is loaded when a zone's SPAN answers it, not only its root")
    func multiKeyZonesFillTheirWholeSpan() {
        // An imported drum kit maps one sample across several keys. A grid that
        // matched `rootPitch` only would draw such a kit almost entirely empty.
        let controller = MusicalTypingController()
        let wide = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/Kit.wav"),
                               rootPitch: 36, minPitch: 36, maxPitch: 40)
        let model = PadGridModel(typing: controller, zones: { [wide] },
                                 targetName: { nil })
        let pads = model.pads
        #expect(pads[0].isLoaded)
        #expect(pads[4].isLoaded)
        #expect(pads[5].isLoaded == false)
    }

    @Test("a pad lights from what is SOUNDING, never from what was clicked")
    func playingReadsTheSoundingSet() {
        let controller = MusicalTypingController()
        controller.targetState = .ready
        controller.setEnabled(true)
        controller.setPlayMode(.pads)
        let model = PadGridModel(typing: controller, zones: { [self.zone(36)] },
                                 targetName: { nil })
        #expect(model.pads[0].isPlaying == false)
        model.padDown(index: 0, normalizedY: 0.5)
        #expect(model.pads[0].isPlaying)
        #expect(model.pads[1].isPlaying == false)
        model.padUp()
        #expect(model.pads[0].isPlaying == false)
    }

    @Test("⛔ a pad struck on a track that cannot sound does NOT light")
    func silentTargetDoesNotLightAPad() {
        // The pixel-level version of the honesty light: a lit pad must always
        // mean audible sound.
        let controller = MusicalTypingController()
        controller.targetState = .notInstrument
        controller.setEnabled(true)
        controller.setPlayMode(.pads)
        let model = PadGridModel(typing: controller, zones: { [self.zone(36)] },
                                 targetName: { nil })
        model.padDown(index: 0, normalizedY: 0.5)
        #expect(model.pads[0].isPlaying == false)
        #expect(controller.soundingPitches.isEmpty)
    }

    @Test("slices below pad 1 are REPORTED, and one call re-bases onto them")
    func unreachableSlicesAreSurfaced() {
        let controller = MusicalTypingController()
        let zones = [zone(24), zone(25), zone(40)]
        let model = PadGridModel(typing: controller, zones: { zones },
                                 targetName: { nil })
        #expect(model.unreachableBelowCount == 2)
        #expect(model.lowestRootPitch == 24)
        model.baseOnLowestSlice()
        #expect(model.baseNote == 24)
        #expect(model.bank == 0)
        #expect(model.unreachableBelowCount == 0)
        #expect(model.pads[0].isLoaded)
    }

    // MARK: - PadGridModel: the chop

    @Test("the CHOP button is blocked, with a reason, when there is nothing to chop")
    func chopRefusalsAreNamed() {
        let controller = MusicalTypingController()
        let model = PadGridModel(typing: controller, zones: { [] }, targetName: { nil })
        #expect(model.blockingRefusal == .noClipSelected)

        let midi = PadChopSource(clipId: UUID(), clipName: "Bass", trackId: UUID(),
                                 trackName: "Bass", isMIDI: true, otherClipsOnTrack: 0)
        model.rebind(selectedClip: { midi })
        #expect(model.blockingRefusal == .clipIsMIDI)

        let audio = PadChopSource(clipId: UUID(), clipName: "Vox", trackId: UUID(),
                                  trackName: "Vox", isMIDI: false, otherClipsOnTrack: 0)
        model.rebind(selectedClip: { audio })
        #expect(model.blockingRefusal == nil)

        // ⚠️ NON-VACUITY: every refusal has real words, so a suite that only
        // proved "something was refused" cannot pass against a stub.
        for refusal in PadChopRefusal.allCases {
            #expect(refusal.message.count > 20)
        }
    }

    @Test("⭐⭐ the store's refusal survives VERBATIM — both numbers reach the panel")
    func storeRefusalIsVerbatim() async {
        let controller = MusicalTypingController()
        let clipID = UUID()
        let model = PadGridModel(
            typing: controller, zones: { [] }, targetName: { nil },
            selectedClip: {
                PadChopSource(clipId: clipID, clipName: "Vox", trackId: UUID(),
                              trackName: "Vox", isMIDI: false, otherClipsOnTrack: 0)
            },
            chopAction: { _, settings, _ in
                // The REAL validator, not a hand-written message — so this test
                // measures what a user would actually be shown.
                try SliceToSamplerPlan.validateSliceCount(
                    boundaryCount: 53, settings: settings, clipId: clipID)
                throw ProjectError.engineUnavailable
            })
        model.chop.maxSlices = 32
        let ok = await model.runChop()
        #expect(ok == false)
        let message = try! #require(model.lastRefusal)
        // BOTH numbers, by name. A "Chop failed" rewrite drops both.
        #expect(message.contains("53"))
        #expect(message.contains("32"))
        #expect(message.contains("maxSlices"))
        // And the way out.
        #expect(message.contains("96"))
    }

    @Test("⭐ a landed chop re-bases the grid on what the chop USED, not what was asked")
    func chopRebasesOnTheLandedPitch() async {
        let controller = MusicalTypingController()
        let model = makeChoppingModel(controller: controller, landedBase: 48,
                                      mutedTrackId: nil, sourceTrackMuted: false)
        model.chop.baseNote = 36
        let ok = await model.runChop()
        #expect(ok)
        // The chop reported pads from 48; a grid based on the REQUEST (36)
        // would draw twelve empty squares over a perfectly good chop.
        #expect(model.baseNote == 48)
        #expect(model.bank == 0)
    }

    @Test("⭐⭐ the notice reports the STORE's mute, never the card's request")
    func muteNoticeComesFromTheStore() async {
        let controller = MusicalTypingController()
        // The card ASKED to mute; the store SKIPPED it (same-track case).
        let skipped = makeChoppingModel(controller: controller, landedBase: 36,
                                        mutedTrackId: nil, sourceTrackMuted: false)
        skipped.muteSourceTrack = true
        #expect(await skipped.runChop())
        let a = try! #require(skipped.lastChop)
        #expect(a.mutedTrackName == nil)        // ⚠️ NOT "Vox" — nothing was muted
        #expect(a.sourceStillAudible)           // …so the original WILL be heard

        // The card asked, and the store DID it.
        let muted = makeChoppingModel(controller: controller, landedBase: 36,
                                      mutedTrackId: UUID(), sourceTrackMuted: true)
        muted.muteSourceTrack = true
        #expect(await muted.runChop())
        let b = try! #require(muted.lastChop)
        #expect(b.mutedTrackName == "Vox")
        #expect(b.sourceStillAudible == false)

        // ⭐ THE FOURTH COMBINATION, which a single boolean could not express:
        // the card did NOT ask, and the track was ALREADY muted. Nothing to
        // undo, and nothing will be heard underneath.
        let already = makeChoppingModel(controller: controller, landedBase: 36,
                                        mutedTrackId: nil, sourceTrackMuted: true)
        already.muteSourceTrack = false
        #expect(await already.runChop())
        let c = try! #require(already.lastChop)
        #expect(c.mutedTrackName == nil)
        #expect(c.sourceStillAudible == false)
    }

    @Test("the mute label NAMES the track and warns about its other clips")
    func muteLabelNamesTheTrack() {
        let controller = MusicalTypingController()
        let model = PadGridModel(typing: controller, zones: { [] }, targetName: { nil })
        model.rebind(selectedClip: {
            PadChopSource(clipId: UUID(), clipName: "Vox", trackId: UUID(),
                          trackName: "Lead Vocal", isMIDI: false, otherClipsOnTrack: 0)
        })
        #expect(model.muteLabel.contains("Lead Vocal"))
        #expect(model.muteLabel.contains("other") == false)

        model.rebind(selectedClip: {
            PadChopSource(clipId: UUID(), clipName: "Vox", trackId: UUID(),
                          trackName: "Lead Vocal", isMIDI: false, otherClipsOnTrack: 12)
        })
        #expect(model.muteLabel.contains("12"))
        #expect(model.muteLabel.contains("other"))
        // The explanation carries the MEASURED number, so the user is told how
        // much louder rather than "it may sound different".
        #expect(PadGridModel.muteExplanation.contains("6 LU"))
    }

    @Test("the UI defaults the mute ON while the wire defaults it OFF")
    func theTwoDefaultsDiverge() {
        // ⭐ THE SPLIT IS THE DESIGN: a shipped wire verb must keep its exact
        // meaning (additive-only), while the card can show the toggle first.
        #expect(PadChopSettings().muteSourceTrack)
        // The wire's own default, read from the function this card calls.
        let result = SliceToSamplerResult(
            trackId: UUID(), createdTrackId: nil, midiClipId: nil, sampleRate: 44_100,
            frameCount: 0, sliceCount: 0, headSeconds: 0, slices: [], warnings: [])
        #expect(result.mutedTrackId == nil)
        #expect(result.sourceTrackMuted == false)
    }

    @Test("an UNBOUND grid is a nameable state, not a plausible empty kit")
    func boundStateIsObservable() {
        let controller = MusicalTypingController()
        let model = PadGridModel(typing: controller, zones: { [] }, targetName: { nil })
        // Sixteen dim squares and loadedCount 0 — indistinguishable from a real
        // empty kit by every other reading, which is why `isBound` exists.
        #expect(model.isBound == false)
        #expect(model.loadedCount == 0)
        model.rebind(zones: { [self.zone(36)] })
        #expect(model.isBound)
        #expect(model.loadedCount == 1)
    }

    // MARK: - Chopping harness

    fileprivate func makeChoppingModel(controller: MusicalTypingController,
                                       landedBase: Int,
                                       mutedTrackId: UUID?,
                                       sourceTrackMuted: Bool) -> PadGridModel {
        let clipID = UUID()
        let trackID = UUID()
        return PadGridModel(
            typing: controller, zones: { [] }, targetName: { "Vox chops" },
            selectedClip: {
                PadChopSource(clipId: clipID, clipName: "Vox", trackId: trackID,
                              trackName: "Vox", isMIDI: false, otherClipsOnTrack: 0)
            },
            chopAction: { _, _, _ in
                SliceToSamplerResult(
                    trackId: trackID, createdTrackId: trackID, midiClipId: nil,
                    sampleRate: 44_100, frameCount: 44_100, sliceCount: 1,
                    headSeconds: 0,
                    slices: [SliceReport(index: 0, pitch: landedBase, startFrame: 0,
                                         endFrame: nil, sourceSeconds: 0, beat: 0,
                                         strength: nil, snapOffsetFrames: nil,
                                         residualAmplitude: nil)],
                    warnings: [], mutedTrackId: mutedTrackId,
                    sourceTrackMuted: sourceTrackMuted)
            })
    }

    @Test("⛔⛔ the notice names the track the pads LANDED on, not the selected one")
    func noticeNamesTheLandedTrack() async {
        // ⛔ REGRESSION, AND IT SHIPPED. Found by LOOKING at a capture: the
        // summary read the ACTIVE track's name, but the app switches the active
        // track only AFTER `runChop` returns. A clip on "Break" chopped onto a
        // new "loop chops" produced *"1 pad on “Break” (a new track)"* — naming
        // the track that had just been MUTED — while the header on the same
        // screen said "on loop chops".
        //
        // ⚠️ The harness that hid this returned a CONSTANT name for both
        // questions, so the two could not disagree. Here they deliberately do.
        let landedTrack = UUID()
        let controller = MusicalTypingController()
        let model = PadGridModel(
            typing: controller, zones: { [] },
            // The ACTIVE track at summary time is still the SOURCE.
            targetName: { "Break" },
            selectedClip: {
                PadChopSource(clipId: UUID(), clipName: "loop", trackId: UUID(),
                              trackName: "Break", isMIDI: false, otherClipsOnTrack: 1)
            },
            trackNameForID: { id in id == landedTrack ? "loop chops" : "Break" },
            chopAction: { _, _, _ in
                SliceToSamplerResult(
                    trackId: landedTrack, createdTrackId: landedTrack,
                    midiClipId: nil, sampleRate: 44_100, frameCount: 44_100,
                    sliceCount: 1, headSeconds: 0,
                    slices: [SliceReport(index: 0, pitch: 36, startFrame: 0,
                                         endFrame: nil, sourceSeconds: 0, beat: 0,
                                         strength: nil, snapOffsetFrames: nil,
                                         residualAmplitude: nil)],
                    warnings: [], mutedTrackId: UUID(), sourceTrackMuted: true)
            })
        #expect(await model.runChop())
        let notice = try! #require(model.lastChop)
        #expect(notice.trackName == "loop chops")
        // …and the MUTED track is still named separately, so one sentence can
        // never stand in for the other.
        #expect(notice.mutedTrackName == "Break")
    }

    @Test("⭐ the refusal a PERSON reads carries the numbers but not the UUID")
    func refusalIsHumanReadable() async {
        // Found by LOOKING: the store writes for an agent, so its sentence
        // opens with the clip's 36-char UUID. The card already names the clip.
        let clipID = UUID()
        let controller = MusicalTypingController()
        let model = PadGridModel(
            typing: controller, zones: { [] }, targetName: { "Break" },
            selectedClip: {
                PadChopSource(clipId: clipID, clipName: "loop", trackId: UUID(),
                              trackName: "Break", isMIDI: false, otherClipsOnTrack: 0)
            },
            chopAction: { _, _, _ in
                throw ProjectError.invalidClipEdit(
                    "chopping clip \(clipID.uuidString) would make 15 pads, over "
                    + "the maxSlices limit of 2 — nothing was changed")
            })
        #expect(await model.runChop() == false)
        let human = try! #require(model.lastRefusalForHumans)
        // ⛔ BOTH NUMBERS SURVIVE — that is the load-bearing guarantee.
        #expect(human.contains("15"))
        #expect(human.contains("2"))
        #expect(human.contains("“loop”"))
        #expect(!human.contains(clipID.uuidString))
        // …and the wire's copy is untouched.
        #expect(model.lastRefusal?.contains(clipID.uuidString) == true)
    }

    /// ⭐⭐ THE REMEDY MUST NAME A CONTROL THAT IS ON THE SCREEN.
    ///
    /// ⛔ **MEASURED ON A REAL USER, 2026-09-20.** They hit the pad ceiling and
    /// read *"over the maxSlices limit of 9 — Raise maxSlices, lower
    /// sensitivity, raise minSliceSeconds"* while looking at a panel whose
    /// sliders say "Most pads to make" and "How many hits to catch". Every
    /// number and every remedy was CORRECT; none of the words were theirs.
    /// That is a defect no gate in this tree could have seen — the sentence is
    /// accurate, the tests that pin it pass, and it is still unusable.
    ///
    /// ⚠️ The load-bearing half is the LAST expectation: the store's string is
    /// a WIRE CONTRACT that agents read and other tests pin byte-exact, so the
    /// translation must live in the view model and leave `lastRefusal` alone.
    /// Rewriting the store's sentence would fix a person's problem by breaking
    /// an agent's — the trade this test exists to forbid.
    @Test("⭐⭐ the remedy a PERSON reads names the SLIDER, not the API parameter")
    func refusalRemedySpeaksTheUIVocabulary() async {
        let clipID = UUID()
        let controller = MusicalTypingController()
        let model = PadGridModel(
            typing: controller, zones: { [] }, targetName: { "Break" },
            selectedClip: {
                PadChopSource(clipId: clipID, clipName: "test-voice", trackId: UUID(),
                              trackName: "Break", isMIDI: false, otherClipsOnTrack: 0)
            },
            chopAction: { _, _, _ in
                // The user's ACTUAL sentence, verbatim.
                throw ProjectError.invalidClipEdit(
                    "chopping clip \(clipID.uuidString) would make 90 pads, over the "
                    + "maxSlices limit of 9 — nothing was changed. Raise maxSlices "
                    + "(hard cap 96), lower sensitivity, raise minSliceSeconds, or trim "
                    + "the clip to a shorter passage")
            })
        #expect(await model.runChop() == false)
        let human = try! #require(model.lastRefusalForHumans)

        // The words that ARE on the panel.
        #expect(human.contains("“Most pads to make”"))
        #expect(human.contains("“How many hits to catch”"))
        // …and the words that are NOT.
        #expect(!human.contains("maxSlices"))
        #expect(!human.contains("sensitivity"))
        #expect(!human.contains("minSliceSeconds"))
        // ⛔ Every number and the escape hatch still survive the rewrite.
        #expect(human.contains("90"))
        #expect(human.contains("9"))
        #expect(human.contains("96"))
        #expect(human.contains("trim the clip"))
        #expect(human.contains("“test-voice”"))

        // ⛔⛔ THE WIRE TEXT IS UNCHANGED — the whole point of translating here.
        let wire = try! #require(model.lastRefusal)
        #expect(wire.contains("maxSlices"))
        #expect(wire.contains("minSliceSeconds"))
        #expect(wire.contains(clipID.uuidString))
    }

    // MARK: - m33-d: the chop NOTICE speaks to a person; the wire keeps its words

    /// A chop result carrying the REAL planner's head warning — built by the same
    /// `SliceToSamplerPlan.compute` the store runs, never a hand-copied string,
    /// so the day the wire sentence and the grid's recogniser part, this goes red.
    fileprivate func resultWithRealHeadWarning(extra: [String] = []) throws
        -> SliceToSamplerResult {
        let clip = Clip(name: "Loop", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/tmp/m33d-fixture.wav"),
                        startOffsetSeconds: 0)
        // Onsets at 0.5 / 1.0 / 1.5 s of a 2 s file: a 0.5 s head, dropped.
        let geometry = SliceBoundaryGeometry(
            sampleRate: 44_100, frameCount: 88_200, boundaryFrames: [22_050, 44_100, 66_150],
            snapOffsetFrames: [0, 0, 0], residualAmplitude: [0, 0, 0])
        let plan = try SliceToSamplerPlan.compute(
            clip: clip, geometry: geometry, strengths: [1, 1, 1],
            settings: SliceToSamplerSettings(mode: .transients),
            tempoMap: TempoMap(constantBPM: 120))
        let trackID = UUID()
        return SliceToSamplerResult(
            trackId: trackID, createdTrackId: trackID, midiClipId: nil,
            sampleRate: 44_100, frameCount: 88_200, sliceCount: plan.slices.count,
            headSeconds: plan.headSeconds, slices: plan.slices,
            warnings: plan.warnings + extra, mutedTrackId: nil, sourceTrackMuted: false)
    }

    /// ⛔ MEASURED 2026-09-24: the pad grid's notice showed *"…like an MPC or
    /// Recycle. Pass includeHead: true to keep it as pad 1 — worth doing if the
    /// detector missed the downbeat"* to a person, who has no control by that
    /// name and was never told where to click.
    @Test("⭐⭐ the chop notice a PERSON reads names the checkbox, not includeHead (m33-d)")
    func chopNoticeSpeaksToAPerson() async throws {
        let muted = "“Vox” was already muted, so nothing changed there"
        let result = try resultWithRealHeadWarning(extra: [muted])
        // FIXTURE CONTROL: the wire really does say it in API words.
        #expect(result.warnings.first?.contains("Pass includeHead: true") == true)

        let controller = MusicalTypingController()
        let model = PadGridModel(
            typing: controller, zones: { [] }, targetName: { "Loop chops" },
            selectedClip: {
                PadChopSource(clipId: UUID(), clipName: "Loop", trackId: UUID(),
                              trackName: "Loop", isMIDI: false, otherClipsOnTrack: 0)
            },
            chopAction: { _, _, _ in result })
        #expect(await model.runChop())
        let notice = try #require(model.lastChop)

        #expect(notice.warningsForHumans.count == notice.warnings.count)
        let human = try #require(notice.warningsForHumans.first)
        // What happened, and every click to undo it, in the words ON SCREEN.
        #expect(human.contains("0.50 s"))
        #expect(human.contains("Undo"))
        #expect(human.contains("CHOP A CLIP…"))
        #expect(human.contains("PRO"))
        #expect(human.contains("“\(PadChopSettings.leadInLabel)”"))
        // …and none of the wire's.
        for jargon in ["includeHead", "onset", "detector", "Recycle", "slice point", "Pass "] {
            #expect(!human.contains(jargon), "“\(jargon)” leaked into: \(human)")
        }
        // A sentence already written for people passes through untouched.
        #expect(notice.warningsForHumans.last == muted)
        // ⛔⛔ THE WIRE TEXT IS UNCHANGED — agents keep the precise parameter name.
        #expect(notice.warnings == result.warnings)
    }

    @Test("the lead-in toggle is live only where the DOMAIN reads it; dimmed + explained elsewhere")
    func leadInToggleFollowsTheDomainRule() {
        for mode in SliceBoundaryMode.allCases {
            var chop = PadChopSettings()
            chop.mode = mode
            // ONE rule: the card asks the domain, never re-derives it.
            #expect(chop.leadInIsEffective
                    == SliceToSamplerSettings(mode: mode).includeHeadIsEffective, "\(mode)")
            #expect((chop.leadInInertNote == nil) == chop.leadInIsEffective, "\(mode)")
            #expect((chop.leadInInertNote?.count ?? 0) <= 51, "\(mode)")
        }
        var chop = PadChopSettings()
        chop.mode = .transients
        #expect(chop.leadInIsEffective)
        chop.mode = .divisions
        #expect(!chop.leadInIsEffective)
        #expect(chop.leadInInertNote == "EQUAL PIECES always keeps the lead-in as pad 1.")
        chop.mode = .grid
        #expect(!chop.leadInIsEffective)
        #expect(chop.leadInInertNote?.hasPrefix("ON THE BEAT") == true)
        // Dimmed, NOT disabled: a box ticked in another mode is still sent, so
        // "tick it, then switch to Every hit" keeps working.
        chop.includeHead = true
        chop.mode = .transients
        #expect(chop.settings().includeHead)
        #expect(chop.settings().effectiveIncludeHead)
    }

    @Test("the chop card can never produce the snapWindowMs warning, so it needs no copy")
    func snapWarningIsUnreachableFromTheCard() {
        for mode in SliceBoundaryMode.allCases {
            var chop = PadChopSettings()
            chop.mode = mode
            let sent = chop.settings()
            #expect(sent.effectiveSnapWindowSeconds == sent.snapWindowSeconds, "\(mode)")
        }
        // POSITIVE CONTROL: the clamp is real — a minimum the card does not send trips it.
        let tight = SliceToSamplerSettings(minSliceSeconds: 0.004)
        #expect(tight.effectiveSnapWindowSeconds < tight.snapWindowSeconds)
    }

    @Test("the mute label's VERB agrees with its count, not just the noun")
    func muteLabelVerbAgrees() {
        // "its 1 other clip GO quiet too" shipped — the plural was handled on
        // the noun and forgotten on the verb, and every fixture used >1 clip.
        let controller = MusicalTypingController()
        let one = PadGridModel(
            typing: controller, zones: { [] }, targetName: { nil },
            selectedClip: {
                PadChopSource(clipId: UUID(), clipName: "loop", trackId: UUID(),
                              trackName: "Break", isMIDI: false, otherClipsOnTrack: 1)
            })
        #expect(one.muteLabel.contains("1 other clip goes quiet too"))
        let many = PadGridModel(
            typing: controller, zones: { [] }, targetName: { nil },
            selectedClip: {
                PadChopSource(clipId: UUID(), clipName: "loop", trackId: UUID(),
                              trackName: "Break", isMIDI: false, otherClipsOnTrack: 3)
            })
        #expect(many.muteLabel.contains("3 other clips go quiet too"))
    }

    // MARK: - What a pad does when you let go (m39-pads-2)

    /// ⭐⭐ **THE ANTI-INERT CHECK ON THE POINTER PATH, AND IT IS NOT DUPLICATION.**
    /// The key-driven cases above prove `soundingPitches` empties on key-up.
    /// This one drives `padDown`/`padUp` — the MOUSE funnel — because those are
    /// separate entry points and the pad grid has ALREADY shipped one of them
    /// inert once (m39-pads: a `padDown` that reached no sink, with every
    /// headless reading self-consistent and silent pads on screen). A gate that
    /// only ever exercised the keys would pass identically over that defect.
    /// ⚠️ **THE SPY SINK IS THE POINT, NOT `soundingPitches`.** That property is
    /// the controller's OWN ledger; an inert path can keep it perfectly correct
    /// while nothing reaches the engine, which is exactly the shape that shipped.
    /// `sets` is the only instrument that sees the seam.
    @Test("⭐ a pad struck with the POINTER reaches the SEAM, and lets go when the pointer does")
    func pointerPadGates() {
        let sink = MusicalTypingControllerTests.PadSpySink()
        let controller = MusicalTypingController(sink: sink)
        controller.targetState = .ready
        controller.setEnabled(true)
        controller.setPlayMode(.pads)
        let model = PadGridModel(typing: controller, zones: { [self.zone(36)] },
                                 targetName: { "Chop" })
        model.padDown(index: 0, normalizedY: 0.5)
        #expect(controller.soundingPitches == [36])
        #expect(sink.last == [36])
        model.padUp()
        // ⛔ THIS is the half the user asked about: in GATE mode the sound ends
        // when the hand does. A click — down and up inside one frame — is a
        // complete gate cycle, which is why one-shot exists at all.
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.last.isEmpty)
    }

    /// ⭐ The trigger mode is READ THROUGH, so an agent's
    /// `instrument.setSamplerParam {oneShot}` moves the row.
    @Test("⭐ the LET GO row reads the sampler live and writes back through it")
    func triggerModeRoundTrips() {
        let controller = MusicalTypingController()
        // The SAMPLER is the single source of truth — the model holds no copy.
        var sampler = SamplerParams(gain: 1)
        var writes = 0
        let model = PadGridModel(
            typing: controller, zones: { [] }, targetName: { "Chop" },
            oneShot: { sampler.oneShot },
            setOneShot: { on in
                writes += 1
                sampler.oneShot = on
                return nil
            })

        // A fresh chop inherits `SamplerParams().oneShot == false` — the pads
        // gate, which is what the user met.
        #expect(model.triggerMode == .gate)
        #expect(model.triggerModeUnavailableReason == nil)

        model.setTriggerMode(.oneShot)
        #expect(writes == 1)
        #expect(sampler.oneShot == true)
        #expect(model.triggerMode == .oneShot)

        // ⚠️ A redundant click must not pay for a wholesale sampler apply
        // (`setInstrument` re-validates every zone file).
        model.setTriggerMode(.oneShot)
        #expect(writes == 1)

        // ⭐ THE LIVE READ: the wire moves the sampler underneath the model and
        // the row follows, with no call into the model at all. A cached copy
        // would still say `.oneShot` here.
        sampler.oneShot = false
        #expect(model.triggerMode == .gate)
    }

    /// ⭐ nil is a REAL third state — "this track has no sampler" — and the row
    /// says so rather than drawing a default that claims a setting.
    @Test("⛔ over a non-sampler track the LET GO row is dead and NAMES the track")
    func triggerModeUnavailableNamesTheTrack() {
        let controller = MusicalTypingController()
        let model = PadGridModel(typing: controller, zones: { [] },
                                 targetName: { "Lead Vox" },
                                 oneShot: { nil })
        #expect(model.triggerMode == nil)
        let reason = try! #require(model.triggerModeUnavailableReason)
        #expect(reason.contains("“Lead Vox”"))

        // No track at all is a DIFFERENT sentence — "pick a track" is the
        // remedy there, and naming a track that does not exist would not be.
        let untargeted = PadGridModel(typing: controller, zones: { [] },
                                      targetName: { nil }, oneShot: { nil })
        #expect(untargeted.triggerModeUnavailableReason?.contains("Pick a track") == true)
    }

    /// ⛔ A sampler apply is WHOLESALE and can genuinely refuse (a slice whose
    /// source file moved). A chip that lit while the write bounced would be a
    /// switch claiming a state the engine is not in — this tree's
    /// characteristic failure wearing a toggle.
    @Test("⛔ a refused write SHOWS the store's refusal and does not fake the flip")
    func triggerModeSurfacesARefusal() {
        let controller = MusicalTypingController()
        let sampler = SamplerParams(gain: 1)
        let model = PadGridModel(
            typing: controller, zones: { [] }, targetName: { "Chop" },
            oneShot: { sampler.oneShot },
            setOneShot: { _ in "“slice-07.wav” is missing — the sampler was not changed." })
        model.setTriggerMode(.oneShot)
        #expect(model.lastTriggerModeError?.contains("slice-07.wav") == true)
        // The row still reads what the SAMPLER holds, not what was clicked.
        #expect(model.triggerMode == .gate)
    }

    // MARK: - Sixteen Levels (m39-levels)

    /// A pad grid over a live keymap the test can watch being written.
    private func levelsFixture(slices: Int = 9)
        -> (PadGridModel, MusicalTypingController, () -> [SamplerZone]) {
        let controller = MusicalTypingController()
        controller.targetState = .ready
        controller.setEnabled(true)
        controller.setPlayMode(.pads)
        // A box, so the model's reads see the model's own writes — the live
        // sampler, not a snapshot.
        final class Box: @unchecked Sendable { var zones: [SamplerZone] = [] }
        let box = Box()
        box.zones = (0..<slices).map { i in
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels-fixture.wav"),
                        rootPitch: 36 + i, minPitch: 36 + i, maxPitch: 36 + i,
                        startFrame: i * 1000, endFrame: i * 1000 + 900)
        }
        let model = PadGridModel(
            typing: controller, zones: { box.zones }, targetName: { "Chop" },
            setZones: { written in box.zones = written; return nil })
        return (model, controller, { box.zones })
    }

    /// ⛔⛔⛔ **THE LOAD-BEARING TEST OF THIS WHOLE FEATURE.** The two obvious
    /// builds of Sixteen Levels — widen the chosen slice in place, or swap the
    /// keymap for sixteen copies and remember the original in this object — both
    /// destroy the only home a chop has, and a "remembered" original in a view
    /// model is gone when the app quits. The user would open a saved project and
    /// find 90 hand-placed slices replaced by sixteen copies of slice 7. So:
    /// entering ADDS ONE ZONE and every original must come back byte-identical.
    @Test("⛔⛔ entering LEVELS adds ONE zone and leaves every slice byte-identical")
    func levelsNeverEditsTheChop() {
        let (model, _, zonesNow) = levelsFixture(slices: 9)
        let before = zonesNow()

        #expect(model.enterLevels(fromPad: 2))
        let after = zonesNow()
        #expect(after.count == before.count + 1)
        // ⭐ EVERY ORIGINAL, UNCHANGED — id, span, root, slice window, all of it.
        // `SamplerZone` is `Equatable`, so this compares the whole struct rather
        // than the two fields a hand-written check would have remembered.
        for original in before {
            #expect(after.contains(original), "slice at root \(original.rootPitch) was altered")
        }

        // ⛔⛔ m39-levels-2: AND FLIPPING THE LIVE SPREAD, BOTH WAYS, TWICE, EDITS
        // NONE OF THEM EITHER. The toggle's write is the whole keymap (a sampler
        // apply is wholesale), so "only the spread changed" has to be asserted
        // on every zone, after every flip — and the slices must also keep their
        // ORDER, because the reconstruction clip and the ordinals read it.
        let spreadID = try! #require(model.levels?.spreadZoneID)
        for direction in [SixteenLevels.Direction.centered, .up, .centered, .up] {
            model.setSpreadDirection(direction)
            let flipped = zonesNow()
            #expect(Array(flipped.prefix(before.count)) == before,
                    "flipping to \(direction) edited or reordered the chop")
            #expect(flipped.count == before.count + 1)
            let spread = try! #require(flipped.first { $0.id == spreadID })
            #expect(SixteenLevels.direction(of: spread) == direction)
            #expect(model.lastLevelsError == nil)
        }

        model.exitLevels()
        // ⛔ And leaving restores the keymap EXACTLY, not merely its count.
        #expect(zonesNow() == before)
    }

    // MARK: - Which way the spread runs (m39-levels-2)

    /// A levels fixture that also COUNTS the model's writes and can REFUSE
    /// them. The fifth element writes the sampler BEHIND the grid's back — an
    /// agent or the sampler card — without counting as one of the model's.
    private func countingLevelsFixture(refuseFrom writeNumber: Int? = nil)
        -> (PadGridModel, MusicalTypingController, () -> [SamplerZone], () -> Int,
            ([SamplerZone]) -> Void) {
        let controller = MusicalTypingController()
        controller.targetState = .ready
        controller.setEnabled(true)
        controller.setPlayMode(.pads)
        // A plain box: `PadGridModel`'s closures are `@escaping`, not
        // `@Sendable`, and everything here runs on the main actor.
        final class Box {
            var zones: [SamplerZone] = []
            var writes = 0
        }
        let box = Box()
        box.zones = (0..<9).map { i in
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels2-fixture.wav"),
                        rootPitch: 36 + i, minPitch: 36 + i, maxPitch: 36 + i,
                        startFrame: i * 1000, endFrame: i * 1000 + 900)
        }
        let model = PadGridModel(
            typing: controller, zones: { box.zones }, targetName: { "Chop" },
            setZones: { written in
                box.writes += 1
                if let refuseFrom = writeNumber, box.writes >= refuseFrom {
                    return "“take-3.wav” is missing — the sampler was not changed."
                }
                box.zones = written
                return nil
            })
        return (model, controller, { box.zones }, { box.writes }, { box.zones = $0 })
    }

    @Test("⭐ UP is the default: an untouched toggle spreads upward and the header is the shipped line")
    func levelsDefaultIsUp() {
        let (model, _, zonesNow, _, _) = countingLevelsFixture()
        #expect(model.preferredSpreadDirection == .up)
        #expect(model.spreadDirection == .up)
        #expect(model.enterLevels(fromPad: 2))
        let spread = try! #require(zonesNow().last)
        #expect(spread.rootPitch == spread.minPitch)
        #expect(model.pads[0].levelsSemitones == 0)
        #expect(model.pads[15].levelsSemitones == 15)
        // ⛔ BYTE-IDENTICAL to the line that shipped before the toggle existed —
        // nobody who never touches the toggle may see anything change.
        #expect(model.levelsStatus == "Sixteen Levels · slice 3 · pad 1 is the slice as "
                + "recorded, each pad up is a semitone higher")
    }

    /// ⭐⭐ THE CARD'S OWN SENTENCE, MEASURED: "pad 9 = as recorded, −8 to +7".
    @Test("⭐⭐ CENTRED: pad 9 plays the slice as recorded, pads 1–8 read −8…−1, pads 10–16 +1…+7")
    func levelsCentredMapping() {
        let (model, controller, zonesNow, _, _) = countingLevelsFixture()
        model.setSpreadDirection(.centered)
        #expect(model.preferredSpreadDirection == .centered)
        #expect(model.enterLevels(fromPad: 2))
        let base = try! #require(model.levels?.base)
        let spread = try! #require(zonesNow().last)
        #expect(spread.rootPitch == base + 8, "pad 9's key must be the root")
        #expect(model.pads.map(\.levelsSemitones)
                == [-8, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7])
        // Every pad is loaded (one zone answers all sixteen)…
        let loaded = model.pads.filter(\.isLoaded).count
        #expect(loaded == 16)
        // …and hitting pad 9 sounds the ROOT — the recording, unshifted.
        model.padDown(index: 8, normalizedY: 0.5)
        #expect(controller.soundingPitches == [spread.rootPitch])
        model.padUp()
        // Pad 1 sounds eight keys below it.
        model.padDown(index: 0, normalizedY: 0.5)
        #expect(controller.soundingPitches == [spread.rootPitch - 8])
        model.padUp()
        #expect(model.levelsStatus?.contains("pad 9, marked 0") == true)
        #expect(model.spreadDirection == .centered)
    }

    @Test("⭐ flipping a LIVE spread re-labels the pads and moves only its root")
    func levelsToggleFlipsTheLiveSpread() {
        let (model, _, zonesNow, _, _) = countingLevelsFixture()
        #expect(model.enterLevels(fromPad: 4))
        let base = try! #require(model.levels?.base)
        #expect(model.pads[8].levelsSemitones == 8)

        model.setSpreadDirection(.centered)
        #expect(model.pads[8].levelsSemitones == 0)
        #expect(model.pads[0].levelsSemitones == -8)
        #expect(zonesNow().last?.rootPitch == base + 8)
        #expect(model.spreadDirection == .centered)
        // The grid did not move: same base, same bank — only the numbers did.
        #expect(model.baseNote == base)
        #expect(model.levels?.base == base)

        model.setSpreadDirection(.up)
        #expect(model.pads[0].levelsSemitones == 0)
        #expect(zonesNow().last?.rootPitch == base)
    }

    @Test("a click on the direction a live spread already runs writes NOTHING")
    func levelsRedundantFlipWritesNothing() {
        let (model, _, _, writes, _) = countingLevelsFixture()
        #expect(model.enterLevels(fromPad: 1))
        let afterEnter = writes()
        model.setSpreadDirection(.up)
        #expect(writes() == afterEnter, "a redundant click paid for a wholesale sampler apply")
        // POSITIVE CONTROL: a real flip does write, exactly once.
        model.setSpreadDirection(.centered)
        #expect(writes() == afterEnter + 1)
        // And choosing a direction with NO spread up writes nothing at all.
        model.exitLevels()
        let afterExit = writes()
        model.setSpreadDirection(.up)
        #expect(writes() == afterExit)
    }

    /// ⛔ `triggerMode`'s rule: a toggle that lit while the write bounced would
    /// be a switch claiming a state the pads are not in.
    @Test("⛔ a REFUSED flip shows the refusal, and the toggle and pads keep telling the truth")
    func levelsRefusedFlipTellsTheTruth() {
        // Write 1 (entering) succeeds; write 2 (the flip) is refused.
        let (model, _, zonesNow, _, _) = countingLevelsFixture(refuseFrom: 2)
        #expect(model.enterLevels(fromPad: 3))
        let before = zonesNow()
        model.setSpreadDirection(.centered)
        #expect(zonesNow() == before, "the refused flip changed the keymap")
        #expect(model.lastLevelsError?.contains("take-3.wav") == true)
        // The toggle reads the ZONE, which is still UP…
        #expect(model.spreadDirection == .up)
        // …the pads say so…
        #expect(model.pads[0].levelsSemitones == 0)
        // …and the preference did not move either, so the NEXT spread cannot
        // silently run the way a failed click asked for.
        #expect(model.preferredSpreadDirection == .up)
    }

    /// ⚠️ A spread reshaped behind the grid's back (no longer sixteen keys wide)
    /// cannot be flipped by moving only its root — so the flip is REFUSED out
    /// loud rather than lighting the other chip over pads that did not change.
    @Test("⛔ a spread reshaped elsewhere refuses to flip, says why, and writes nothing")
    func levelsReshapedSpreadRefusesToFlip() {
        let (model, _, zonesNow, writes, behindTheGridsBack) = countingLevelsFixture()
        #expect(model.enterLevels(fromPad: 0))
        let id = try! #require(model.levels?.spreadZoneID)
        // Something else narrows the spread to eight keys — a write to the
        // sampler that does not go through the model, so it is not counted.
        var reshaped = zonesNow()
        let index = try! #require(reshaped.firstIndex { $0.id == id })
        reshaped[index].maxPitch = reshaped[index].minPitch + 7
        behindTheGridsBack(reshaped)
        let before = zonesNow()
        let writesBefore = writes()

        model.setSpreadDirection(.centered)
        #expect(zonesNow() == before, "the refused flip changed the keymap")
        #expect(writes() == writesBefore, "the refused flip still paid for a sampler apply")
        #expect(model.lastLevelsError?.contains("changed outside the pad grid") == true)
        // The toggle does NOT light CENTRED, and the next spread is still UP.
        #expect(model.spreadDirection == .up)
        #expect(model.preferredSpreadDirection == .up)
    }

    /// ⭐ THE LABELS FOLLOW THE ZONE, NOT THE TOGGLE. An agent (or anything
    /// else) that re-roots the spread behind the grid's back must be reported
    /// as it is — the reason the labels are read off the zone at all.
    @Test("⭐ labels and the toggle follow the LIVE zone when something else re-roots it")
    func levelsLabelsFollowTheZone() {
        let controller = MusicalTypingController()
        final class Box { var zones: [SamplerZone] = [] }
        let box = Box()
        box.zones = (0..<4).map { i in
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels2-agent.wav"),
                        rootPitch: 36 + i, minPitch: 36 + i, maxPitch: 36 + i)
        }
        let model = PadGridModel(typing: controller, zones: { box.zones },
                                 targetName: { "Chop" },
                                 setZones: { box.zones = $0; return nil })
        #expect(model.enterLevels(fromPad: 0))
        #expect(model.spreadDirection == .up)
        // Behind the grid's back: the spread's root moves to pad 9's key.
        let id = try! #require(model.levels?.spreadZoneID)
        box.zones = try! #require(SixteenLevels.keymap(box.zones, respreading: id, to: .centered))
        #expect(model.spreadDirection == .centered)
        #expect(model.pads[8].levelsSemitones == 0)
        #expect(model.pads[0].levelsSemitones == -8)
        // The preference was never touched — the toggle is reporting the zone.
        #expect(model.preferredSpreadDirection == .up)
    }

    @Test("the direction toggle is dead exactly when LEVELS is, with the same reason")
    func spreadDirectionAvailability() {
        let empty = PadGridModel(typing: MusicalTypingController(), zones: { [] },
                                 targetName: { "Chop" })
        #expect(empty.spreadDirectionUnavailableReason != nil)
        #expect(empty.spreadDirectionUnavailableReason == empty.levelsUnavailableReason)
        let (model, _, _, _, _) = countingLevelsFixture()
        #expect(model.spreadDirectionUnavailableReason == nil)
        #expect(model.enterLevels(fromPad: 0))
        #expect(model.spreadDirectionUnavailableReason == nil)
    }

    @Test("the two directions' words: the card's labels, and help a newcomer can act on")
    func spreadDirectionWords() {
        #expect(SixteenLevels.Direction.up.label == "UP")
        #expect(SixteenLevels.Direction.centered.label == "CENTRED")
        #expect(SixteenLevels.Direction.up.help.contains("pad 1"))
        #expect(SixteenLevels.Direction.centered.help.contains("pad 9"))
        #expect(SixteenLevels.Direction.centered.help.contains("-8"))
        #expect(SixteenLevels.Direction.centered.help.contains("+7"))
    }

    @Test("⭐ the spread lands below the chop and the grid moves onto it")
    func levelsMovesTheGrid() {
        let (model, controller, zonesNow) = levelsFixture(slices: 9)
        #expect(model.baseNote == 36)
        #expect(model.enterLevels(fromPad: 0))

        let live = try! #require(model.levels)
        #expect(live.base == 20)               // 16 keys directly below 36
        #expect(live.homeBaseNote == 36)
        #expect(controller.padBaseNote == 20)  // the grid actually moved
        #expect(model.isLevels)

        // The spread answers all sixteen pads…
        let loaded = model.pads.filter(\.isLoaded).count
        #expect(loaded == 16)
        // …and hitting pad 4 sounds note 23, which is the source +3 semitones.
        model.padDown(index: 3, normalizedY: 0.5)
        #expect(controller.soundingPitches == [23])
        model.padUp()

        model.exitLevels()
        #expect(controller.padBaseNote == 36)
        #expect(model.isLevels == false)
        #expect(zonesNow().count == 9)
    }

    /// ⭐ Sixteen squares that all read "slice 3" while each plays a different
    /// pitch would be true of the zone and false of the sound.
    @Test("⭐ in a spread the pads read INTERVALS, not sixteen copies of one slice number")
    func levelsPadsReadIntervals() {
        let (model, _, _) = levelsFixture(slices: 9)
        #expect(model.pads[2].sliceOrdinal == 3)
        #expect(model.pads[2].levelsSemitones == nil)

        #expect(model.enterLevels(fromPad: 2))
        #expect(model.pads[0].levelsSemitones == 0)
        #expect(model.pads[15].levelsSemitones == 15)
        // ⛔ The slice number is GONE, not merely overdrawn — a stale ordinal
        // left in the value would reach any other reader of `PadState`.
        let withOrdinals = model.pads.compactMap(\.sliceOrdinal)
        #expect(withOrdinals.isEmpty)
        #expect(model.levels?.sourceOrdinal == 3)
        #expect(model.levelsStatus?.contains("slice 3") == true)
    }

    @Test("LEVELS arms, and the next pad hit PICKS rather than plays")
    func levelsArmingSwallowsTheHit() {
        let (model, controller, _) = levelsFixture(slices: 9)
        model.toggleLevels()
        #expect(model.levelsArming)
        #expect(model.levelsStatus?.contains("Hit the pad") == true)

        model.padDown(index: 4, normalizedY: 0.5)
        // ⛔ It did NOT sound — the hit chose the slice.
        #expect(controller.soundingPitches.isEmpty)
        #expect(model.isLevels)
        #expect(model.levelsArming == false)
        #expect(model.levels?.sourceOrdinal == 5)
    }

    @Test("⛔ arming on an EMPTY pad refuses and says so, rather than spreading silence")
    func levelsRefusesAnEmptyPad() {
        let (model, _, zonesNow) = levelsFixture(slices: 4)
        model.toggleLevels()
        model.padDown(index: 9, normalizedY: 0.5)   // only pads 1–4 are loaded
        #expect(model.isLevels == false)
        #expect(model.lastLevelsError?.contains("empty") == true)
        #expect(zonesNow().count == 4)              // nothing was written
    }

    @Test("⛔ with no room on the keyboard the button is dead and NAMES the reason")
    func levelsUnavailableOverAFullKeymap() {
        let controller = MusicalTypingController()
        let full = (0...127).map {
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels-full.wav"),
                        rootPitch: $0, minPitch: $0, maxPitch: $0)
        }
        let model = PadGridModel(typing: controller, zones: { full },
                                 targetName: { "Chop" })
        let reason = try! #require(model.levelsUnavailableReason)
        #expect(reason.contains("no room"))
        // …and pressing it does not arm a mode that cannot be entered.
        model.toggleLevels()
        #expect(model.levelsArming == false)

        // An EMPTY kit gets its own sentence — "chop something first" and "the
        // keyboard is full" are different problems with different remedies.
        let empty = PadGridModel(typing: controller, zones: { [] }, targetName: { "Chop" })
        #expect(empty.levelsUnavailableReason?.contains("Chop something") == true)
    }

    /// ⚠️ The store can refuse a wholesale sampler apply. The spread must not be
    /// announced when the write bounced.
    @Test("⛔ a refused write leaves the grid on the chop and shows the refusal")
    func levelsSurfacesARefusal() {
        let controller = MusicalTypingController()
        let zones = [SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/m39levels-r.wav"),
                                 rootPitch: 36, minPitch: 36, maxPitch: 36)]
        let model = PadGridModel(
            typing: controller, zones: { zones }, targetName: { "Chop" },
            setZones: { _ in "“take-3.wav” is missing — the sampler was not changed." })
        #expect(model.enterLevels(fromPad: 0) == false)
        #expect(model.isLevels == false)
        #expect(controller.padBaseNote == 36)
        #expect(model.lastLevelsError?.contains("take-3.wav") == true)
    }

    /// The two chips carry the two labels, and the enum converts in ONE place.
    @Test("the LET GO chips finish the sentence, and map to the engine's flag")
    func triggerModeLabels() {
        #expect(PadTriggerMode.gate.label == "STOPS")
        #expect(PadTriggerMode.oneShot.label == "PLAYS ON")
        #expect(PadTriggerMode.gate.isOneShot == false)
        #expect(PadTriggerMode.oneShot.isOneShot == true)
        #expect(PadTriggerMode(oneShot: true) == .oneShot)
        #expect(PadTriggerMode(oneShot: false) == .gate)
        // rawValues are what `debug.padGrid {triggerMode:}` accepts.
        #expect(PadTriggerMode.allCases.map(\.rawValue) == ["gate", "oneShot"])
    }

    // MARK: - Sixteen Levels recognised by SHAPE, not by session (m39-levels-3)
    //
    // ⛔⛔ THREE MEASURED/PREDICTED DEFECTS, ONE ROOT CAUSE. The grid knew a
    // spread only through `levels.spreadZoneID` — session state that a relaunch
    // loses and that a spread made over the wire or by the store never had. The
    // spread zone was then numbered as an ordinary slice: it sits BELOW the
    // chop, so it became slice 1, every pad of it read "1", and every chop
    // slice shifted up one. And `loadedCount` was `zones.count`, so the header
    // counted the spread as a ninth slice.
    //
    // ⭐ These drive a REAL store through its REAL save → open (ProjectBundle →
    // `ProjectDocument` JSON on disk → a brand-new store), and a grid bound to
    // it with the app's own two injectors (`padGridZones` / `padGridSetZones`),
    // restated over one track id. A fresh grid AND a fresh controller after the
    // reopen is what a relaunch is: nothing of the session survives.

    /// Disk-free media stand-in: `setInstrument` and `openProject` validate
    /// every zone file through the media service. The FILE must still exist
    /// (DAWCore checks `fileExists` itself), hence the system sound below — the
    /// `PolySynthEditorModelTests.SamplerStubMedia` recipe, which is `private`.
    fileprivate struct LevelsStubMedia: MediaImporting {
        func audioFileInfo(at url: URL) throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: 2.0, sampleRate: 48_000, channelCount: 2)
        }
    }

    fileprivate static let levelsPing = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")

    /// A store holding one Sampler track with a `slices`-slice chop from note
    /// 36, one key wide each — `SliceToSampler`'s own shape.
    private func levelsStore(slices: Int = 8) throws -> (ProjectStore, UUID, [SamplerZone]) {
        let store = ProjectStore()
        store.media = LevelsStubMedia()
        let track = store.addTrack(name: "Chop", kind: .instrument)
        let zones = (0..<slices).map { i in
            SamplerZone(audioFileURL: Self.levelsPing, rootPitch: 36 + i, minPitch: 36 + i,
                        maxPitch: 36 + i, startFrame: i * 1_000, endFrame: i * 1_000 + 900)
        }
        try store.setInstrument(id: track.id, kind: .sampler, sampler: SamplerParams(zones: zones))
        return (store, track.id, zones)
    }

    /// A grid over `store`'s track — the app's `padGridZones()` read and its
    /// `padGridSetZones(_:)` write (`store.setInstrument(id:sampler:)`, the one
    /// home), with a fresh controller, as a relaunched app has.
    private func storeBoundGrid(_ store: ProjectStore, _ trackID: UUID) -> PadGridModel {
        let controller = MusicalTypingController()
        controller.targetState = .ready
        controller.setEnabled(true)
        controller.setPlayMode(.pads)
        let sampler: () -> SamplerParams? = {
            guard let track = store.tracks.first(where: { $0.id == trackID }),
                  track.kind == .instrument, let instrument = track.instrument,
                  instrument.kind == .sampler else { return nil }
            return instrument.resolvedSampler
        }
        return PadGridModel(
            typing: controller,
            zones: { sampler()?.zones ?? [] },
            targetName: { store.tracks.first { $0.id == trackID }?.name },
            setZones: { written in
                guard var params = sampler() else { return "not a sampler" }
                params.zones = written
                do {
                    _ = try store.setInstrument(id: trackID, sampler: params)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            })
    }

    /// What a person SEES on one bank: each pad's interval label and its slice
    /// number, in pad order. The two things the defects got wrong.
    fileprivate struct PadReading: Equatable, CustomStringConvertible {
        var levels: [Int?]
        var ordinals: [Int?]
        var description: String {
            "levels \(levels.map { $0.map(String.init) ?? "·" }) "
                + "slices \(ordinals.map { $0.map(String.init) ?? "·" })"
        }
    }

    /// Stands the grid at `base`/`bank` and reads it. ⚠️ Moves the controller —
    /// exactly what a user banking the grid does, and nothing else.
    private func reading(_ model: PadGridModel, base: Int, bank: Int) -> PadReading {
        model.typing.setPadBaseNote(base)
        model.typing.setPadBank(bank)
        let pads = model.pads
        return PadReading(levels: pads.map(\.levelsSemitones), ordinals: pads.map(\.sliceOrdinal))
    }

    private func levelsTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m39-levels-3-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The sixteen labels of an UP spread standing on the grid: 0 … +15.
    private static let upSpreadLabels: [Int?] = (0...15).map { Optional($0) }
    private static let sixteenBlanks: [Int?] = Array(repeating: nil, count: 16)
    /// An 8-slice chop from pad 1: slices 1…8, then eight empty pads.
    private static let eightSliceOrdinals: [Int?] = (1...8).map { Optional($0) }
        + Array(repeating: nil, count: 8)

    /// ⛔⛔ BUG 1 (measured by an earlier agent): after reopen the spread's
    /// sixteen pads read "1" and slice 1 reads 2. The readings a person sees —
    /// the spread's bank AND the chop's bank — must be the same after a
    /// save → relaunch → reopen as they were before the save.
    @Test("⛔⛔ a project saved while LEVELS is up reopens with the SAME pads (m39-levels-3 bug 1)")
    func levelsReopensWithTheSamePads() throws {
        let dir = levelsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, trackID, _) = try levelsStore(slices: 8)
        let before = storeBoundGrid(store, trackID)
        #expect(before.enterLevels(fromPad: 2), "LEVELS on slice 3, by hand")
        let base = try #require(before.levels?.base)
        #expect(base == 20, "8 slices from 36 → the spread sits on 20…35")
        let spreadBefore = reading(before, base: base, bank: 0)
        let chopBefore = reading(before, base: base, bank: 1)   // 36…51: the chop
        before.typing.setPadBank(0)
        let statusBefore = before.levelsStatus
        let countBefore = before.loadedCount

        let path = dir.appendingPathComponent("Levels Reopen").path
        _ = try store.saveProject(to: path)
        let reopened = ProjectStore()
        reopened.media = LevelsStubMedia()
        let warnings = try reopened.openProject(at: path)
        #expect(warnings.isEmpty, "unexpected load warnings: \(warnings)")
        // A RELAUNCH: a fresh grid and a fresh controller.
        let after = storeBoundGrid(reopened, trackID)
        let spreadAfter = reading(after, base: base, bank: 0)
        let chopAfter = reading(after, base: base, bank: 1)
        after.typing.setPadBank(0)

        // What a person sees is what they saw.
        #expect(spreadAfter == spreadBefore, "spread bank after reopen: \(spreadAfter)")
        #expect(chopAfter == chopBefore, "chop bank after reopen: \(chopAfter)")
        #expect(after.loadedCount == countBefore)
        #expect(after.levelsStatus == statusBefore,
                "header after reopen: \(String(describing: after.levelsStatus))")
        // …and what they saw is RIGHT — an equality between two wrong
        // readings would pass, so the values are pinned too.
        #expect(spreadBefore.levels == Self.upSpreadLabels, "spread bank before save: \(spreadBefore)")
        #expect(spreadAfter.levels == Self.upSpreadLabels)
        #expect(spreadAfter.ordinals == Self.sixteenBlanks)
        #expect(chopBefore.ordinals == Self.eightSliceOrdinals,
                "chop bank BEFORE save: \(chopBefore)")
        #expect(chopAfter.ordinals == Self.eightSliceOrdinals, "chop bank after reopen: \(chopAfter)")
        #expect(chopAfter.levels == Self.sixteenBlanks)
        // Standing on it, the reopened spread IS LEVELS, and the header is the
        // shipped line, byte for byte — not merely a line mentioning slice 3.
        #expect(after.isLevels)
        #expect(after.levelsStatus == Self.upLineSlice3)
    }

    /// ⛔ BUG 2 (measured): "9 slices loaded" for an 8-slice chop while a
    /// spread is up. The header counts SLICES; the spread is not one.
    @Test("⛔ the header counts SLICES — a spread is not a ninth one (m39-levels-3 bug 2)")
    func levelsSpreadIsNotCountedAsASlice() {
        let (model, _, zonesNow) = levelsFixture(slices: 8)
        #expect(model.loadedCount == 8, "control: before LEVELS")
        #expect(model.enterLevels(fromPad: 2))
        #expect(zonesNow().count == 9, "the keymap really does hold nine zones")
        #expect(model.loadedCount == 8, "the header counted the spread as a slice")
    }

    /// ⛔⛔ BUG 3 (predicted, unmeasured): a spread the grid never watched being
    /// made — here the store's own verb, the one `instrument.spreadSlice` calls
    /// in one line — reads exactly as a reopened one did.
    @Test("⛔⛔ a spread made WITHOUT the grid reads as a spread, not as slice 1 (m39-levels-3 bug 3)")
    func levelsRecognisesASpreadTheGridNeverSaw() throws {
        let (store, trackID, chop) = try levelsStore(slices: 8)
        let model = storeBoundGrid(store, trackID)
        // CONTROL: before any spread the chop reads 1…8 from pad 1.
        let plain = reading(model, base: 36, bank: 0)
        #expect(plain.ordinals == Self.eightSliceOrdinals, "control: \(plain)")

        let spread = try store.addSixteenLevelsSpread(trackID: trackID, sourceZoneID: chop[2].id)
        #expect(spread.minPitch == 20)
        let spreadBank = reading(model, base: spread.minPitch, bank: 0)
        let chopBank = reading(model, base: spread.minPitch, bank: 1)
        model.typing.setPadBank(0)

        #expect(spreadBank.levels == Self.upSpreadLabels, "spread bank: \(spreadBank)")
        #expect(spreadBank.ordinals == Self.sixteenBlanks, "spread bank: \(spreadBank)")
        #expect(chopBank.ordinals == plain.ordinals, "the chop's numbers moved: \(chopBank)")
        #expect(chopBank.levels == Self.sixteenBlanks)
        // Standing on it, it IS LEVELS: the header names its slice exactly as
        // for a hand-made spread. ⚠️ Exact, not `contains("slice 3")` — the
        // off-the-pads line ("slice 3 is spread on sixteen other pads") would
        // pass a substring check while LEVELS was not up at all.
        #expect(model.isLevels)
        #expect(model.levelsStatus == Self.upLineSlice3,
                "header: \(String(describing: model.levelsStatus))")
    }

    // MARK: - m39-levels-3 — the three decisions, each pinned

    /// The shipped UP line for slice 3 — what the header says while standing
    /// on an UP spread of slice 3, hand-made or not.
    private static let upLineSlice3 = "Sixteen Levels · slice 3 · pad 1 is the slice as "
        + "recorded, each pad up is a semitone higher"

    /// ⭐⭐ DECISION 1 — after a RELAUNCH the grid starts back on the chop (the
    /// pad position was never saved), with the chop numbered right, the count
    /// right, and a line saying where the spread is. LEVELS then goes to it,
    /// aligned, WITHOUT a write — and the header is the hand-made line, byte for
    /// byte. EXIT takes it off exactly as for a hand-made one.
    @Test("⭐⭐ after a relaunch LEVELS goes to the saved spread without writing, and EXIT removes it")
    func levelsGoesToTheReopenedSpread() throws {
        let dir = levelsTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, trackID, chop) = try levelsStore(slices: 8)
        let before = storeBoundGrid(store, trackID)
        #expect(before.enterLevels(fromPad: 2))
        let spreadID = try #require(before.levels?.spreadZoneID)
        let path = dir.appendingPathComponent("Levels Resume").path
        _ = try store.saveProject(to: path)
        let reopened = ProjectStore()
        reopened.media = LevelsStubMedia()
        _ = try reopened.openProject(at: path)
        #expect(reopened.isDirty == false)

        let grid = storeBoundGrid(reopened, trackID)
        // Where a relaunched grid stands: 36, on the chop.
        #expect(grid.baseNote == 36)
        #expect(grid.isLevels == false)
        #expect(grid.loadedCount == 8)
        #expect(grid.pads.map(\.sliceOrdinal) == Self.eightSliceOrdinals)
        #expect(grid.unreachableBelowCount == 0, "a spread is not a slice below pad 1")
        #expect(grid.waitingSpreads.map(\.id) == [spreadID])
        #expect(grid.levelsStatus == "Sixteen Levels · slice 3 is spread on sixteen other pads "
                + "— press LEVELS to go there")
        #expect(grid.levelsUnavailableReason == nil)

        grid.toggleLevels()
        #expect(grid.levelsArming == false, "it went to the spread instead of arming a second")
        #expect(grid.isLevels)
        #expect(grid.baseNote == 20)
        #expect(grid.bank == 0)
        #expect(grid.levels?.spreadZoneID == spreadID)
        #expect(grid.levels?.sourceOrdinal == 3)
        #expect(grid.levelsStatus == Self.upLineSlice3)
        #expect(grid.pads.map(\.levelsSemitones) == Self.upSpreadLabels)
        #expect(reopened.isDirty == false, "going to a spread wrote the sampler")

        grid.exitLevels()
        #expect(grid.isLevels == false)
        #expect(grid.baseNote == 36, "home is where the grid stood when LEVELS was pressed")
        #expect(grid.bank == 0)
        #expect(grid.levelsStatus == nil)
        let zonesAfter = reopened.tracks.first { $0.id == trackID }?.instrument?.sampler?.zones ?? []
        #expect(zonesAfter.map(\.id) == chop.map(\.id), "EXIT removed more, or less, than the spread")
        #expect(reopened.isDirty)
    }

    /// ⭐ DECISION 3 — a spread the grid never made, stood on BY HAND (no
    /// LEVELS press, so no session): it is LEVELS, it can be flipped, and EXIT
    /// removes it by id — the chop byte-identical — and goes to the chop.
    @Test("⭐ a wire-made spread stood on by hand is LEVELS: it flips one field, and EXIT removes only it")
    func levelsExitRemovesASpreadTheGridNeverMade() throws {
        let (store, trackID, chop) = try levelsStore(slices: 8)
        let grid = storeBoundGrid(store, trackID)
        let spread = try store.addSixteenLevelsSpread(trackID: trackID, sourceZoneID: chop[4].id)
        let zones = { store.tracks.first { $0.id == trackID }?.instrument?.sampler?.zones ?? [] }
        // Banked onto it by hand — pad 1 on its first key.
        grid.typing.setPadBaseNote(spread.minPitch)
        #expect(grid.isLevels)
        #expect(grid.levels?.sourceOrdinal == 5)
        #expect(grid.levels?.homeBaseNote == 36, "no session: home is the chop's lowest slice")

        grid.setSpreadDirection(.centered)
        #expect(Array(zones().prefix(chop.count)) == chop, "the flip edited the chop")
        #expect(zones().last?.id == spread.id)
        #expect(zones().last?.rootPitch == spread.minPitch + 8)
        #expect(grid.pads[8].levelsSemitones == 0)

        grid.exitLevels()
        #expect(zones() == chop, "EXIT must leave exactly the chop")
        #expect(grid.baseNote == 36)
        #expect(grid.isLevels == false)
    }

    /// ⭐ DECISION 2 — several spreads (the wire can make several). All stay
    /// out of the numbering and the count and label themselves; LEVELS goes to
    /// the LOWEST; EXIT removes only the live one; LEVELS then goes to the next.
    @Test("⭐ several spreads: none is a slice, LEVELS visits them lowest first, EXIT removes one at a time")
    func levelsManySpreads() throws {
        let (store, trackID, chop) = try levelsStore(slices: 8)
        let grid = storeBoundGrid(store, trackID)
        let zones = { store.tracks.first { $0.id == trackID }?.instrument?.sampler?.zones ?? [] }
        let up = try store.addSixteenLevelsSpread(trackID: trackID, sourceZoneID: chop[2].id)
        let centred = try store.addSixteenLevelsSpread(trackID: trackID, sourceZoneID: chop[5].id,
                                                       direction: .centered)
        #expect(up.minPitch == 20)
        #expect(centred.minPitch == 4)
        #expect(grid.loadedCount == 8)
        #expect(grid.pads.map(\.sliceOrdinal) == Self.eightSliceOrdinals)
        #expect(grid.waitingSpreads.map(\.id) == [centred.id, up.id])
        #expect(grid.levelsStatus == "Sixteen Levels · 2 spreads are on other pads — press "
                + "LEVELS to go to the first")

        grid.toggleLevels()
        #expect(grid.levels?.spreadZoneID == centred.id)
        #expect(grid.pads.map(\.levelsSemitones) == (-8...7).map { Optional($0) })
        #expect(grid.spreadDirection == .centered)
        #expect(grid.levelsStatus?.hasPrefix("Sixteen Levels · slice 6 · pad 9, marked 0") == true)
        // The other spread still labels its own pads, one bank up.
        grid.setBank(1)
        #expect(grid.pads.map(\.levelsSemitones) == Self.upSpreadLabels)
        grid.setBank(0)

        grid.exitLevels()
        #expect(zones().map(\.id) == chop.map(\.id) + [up.id], "EXIT removed the wrong spread")
        #expect(grid.waitingSpreads.map(\.id) == [up.id])
        grid.toggleLevels()
        #expect(grid.levels?.spreadZoneID == up.id)
        #expect(grid.levelsStatus == Self.upLineSlice3)
    }

    /// ⛔ A spread can now be under the hand while arming (it labels itself
    /// wherever the grid stands). Spreading it would copy a copy.
    @Test("⛔ arming and hitting a pad that plays a spread REFUSES, and writes nothing")
    func levelsRefusesASpreadOfASpread() throws {
        let (store, trackID, chop) = try levelsStore(slices: 8)
        let grid = storeBoundGrid(store, trackID)
        grid.toggleLevels()
        #expect(grid.levelsArming, "control: with no spread on the kit, LEVELS arms")
        // An agent spreads a slice while the grid is armed…
        _ = try store.addSixteenLevelsSpread(trackID: trackID, sourceZoneID: chop[0].id)
        // …and the grid straddles it: pads 1–8 are its top half.
        grid.typing.setPadBaseNote(28)
        #expect(grid.pads[0].levelsSemitones == 8)
        let before = store.tracks.first { $0.id == trackID }?.instrument?.sampler?.zones ?? []
        grid.padDown(index: 0, normalizedY: 0.5)
        #expect(grid.lastLevelsError?.contains("already plays a Sixteen Levels spread") == true)
        #expect(store.tracks.first { $0.id == trackID }?.instrument?.sampler?.zones == before)
        #expect(grid.isLevels == false)
    }

    /// ⚠️ The header never names a slice that is not the one being played.
    @Test("⚠️ a spread whose source slice is gone says so, rather than naming a neighbour")
    func levelsSourceGoneIsSaidHonestly() throws {
        let (store, trackID, chop) = try levelsStore(slices: 8)
        let grid = storeBoundGrid(store, trackID)
        let spread = try store.addSixteenLevelsSpread(trackID: trackID, sourceZoneID: chop[2].id)
        // Behind the grid's back, the source slice is deleted.
        var params = try #require(store.tracks.first { $0.id == trackID }?.instrument?.sampler)
        params.zones.removeAll { $0.id == chop[2].id }
        try store.setInstrument(id: trackID, sampler: params)

        #expect(grid.loadedCount == 7)
        #expect(grid.levelsStatus == "Sixteen Levels · a spread is on sixteen other pads — press "
                + "LEVELS to go there")
        grid.typing.setPadBaseNote(spread.minPitch)
        #expect(grid.levels?.sourceOrdinal == nil)
        #expect(grid.levelsStatus == "Sixteen Levels · from a slice no longer on the pads · pad 1 "
                + "is the slice as recorded, each pad up is a semitone higher")
        #expect(grid.pads.map(\.levelsSemitones) == Self.upSpreadLabels)
    }

    /// ⚠️ The CENTRED wrinkle: a centred spread's ROOT is its ninth key. Any
    /// "go to the lowest" that read roots would open pad 1 eight keys inside
    /// it — half spread, half chop.
    @Test("⚠️ a CENTRED spread is reached ALIGNED on its first key, and 'show them' never lands in it")
    func levelsCentredSpreadIsReachedAligned() throws {
        let (store, trackID, chop) = try levelsStore(slices: 8)
        let grid = storeBoundGrid(store, trackID)
        let spread = try store.addSixteenLevelsSpread(trackID: trackID, sourceZoneID: chop[1].id,
                                                      direction: .centered)
        #expect(spread.rootPitch == 28)
        #expect(grid.unreachableBelowCount == 0)
        #expect(grid.lowestRootPitch == 36, "the lowest SLICE, never the spread's root")
        grid.toggleLevels()
        #expect(grid.baseNote == 20, "pad 1 on the spread's first key, not its root")
        #expect(grid.pads.map(\.levelsSemitones) == (-8...7).map { Optional($0) })
        #expect(grid.spreadDirection == .centered)
    }

    /// ⭐ IDENTITY OUTRANKS SHAPE FOR THE GRID'S OWN ZONE. Something narrows the
    /// grid's live spread to eight keys: it is no longer spread-SHAPED, but the
    /// grid still holds it as LEVELS' zone (EXIT removes it; a flip refuses) —
    /// so it must still draw as a spread and still stay out of the numbering,
    /// or the chop shifts exactly as the bug did.
    @Test("⭐ the grid's own spread, reshaped elsewhere, stays out of the slice numbering and count")
    func levelsReshapedOwnSpreadIsStillNotASlice() {
        let (model, _, zonesNow, _, behindTheGridsBack) = countingLevelsFixture()
        #expect(model.enterLevels(fromPad: 0))
        let id = try! #require(model.levels?.spreadZoneID)
        var reshaped = zonesNow()
        let index = try! #require(reshaped.firstIndex { $0.id == id })
        reshaped[index].maxPitch = reshaped[index].minPitch + 7
        behindTheGridsBack(reshaped)
        #expect(SixteenLevels.isSpread(reshaped[index]) == false, "control: no longer spread-shaped")

        #expect(model.isLevels)
        #expect(model.loadedCount == 9)
        let spreadBank = reading(model, base: 20, bank: 0)
        #expect(spreadBank.levels == (0...7).map { Optional($0) } + Array(repeating: nil, count: 8))
        #expect(spreadBank.ordinals == Self.sixteenBlanks)
        let chopBank = reading(model, base: 20, bank: 1)
        #expect(chopBank.ordinals == (1...9).map { Optional($0) } + Array(repeating: nil, count: 7))
    }

    /// The grid's own memory is not trusted past the keymap: a spread deleted
    /// behind its back (an agent, the sampler card) ends LEVELS, instead of
    /// leaving a header and an EXIT button over a zone that is gone.
    @Test("a hand-made spread deleted behind the grid's back ends LEVELS; the chop reads as it did")
    func levelsStaleSessionIsNotConsulted() {
        let (model, _, zonesNow, _, behindTheGridsBack) = countingLevelsFixture()
        let chop = zonesNow()
        #expect(model.enterLevels(fromPad: 2))
        #expect(model.isLevels)
        behindTheGridsBack(chop)
        #expect(model.isLevels == false)
        #expect(model.levelsStatus == nil)
        #expect(model.loadedCount == 9)
        #expect(model.levelsUnavailableReason == nil, "LEVELS can be pressed again")
    }
}
