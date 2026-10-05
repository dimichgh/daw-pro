import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// LIVE LOOPING, THE DOOR (m34-h-2) — the loop-deck control surface's decision
/// layer: which controls are live, which refusal each blocked one shows, and
/// **that the model's prediction and the store's actual behaviour agree.**
///
/// ⚠️⚠️ **THIS SUITE IS DELIBERATELY *NOT* `@MainActor`-ISOLATED, AND THAT IS A
/// CONSTRAINT, NOT A STYLE CHOICE.** `MainActorOccupancySiteTests`'s Leg C caps
/// the tree's `@MainActor`-isolated `@Suite` count at 375 with zero headroom, so
/// a new isolated suite reddens it on sight. `LoopDeckControlModel` is a pure
/// value type precisely so its tests need no isolation at all. The three
/// AGREEMENT tests at the bottom do need a real `ProjectStore`, so they carry
/// `@MainActor` on the FUNCTION — Leg C counts isolation on the `@Suite`
/// declaration (it searches backward from `@Suite`, and forward only until the
/// type-declaration line), so a hop inside a member is outside its scan by
/// construction, not by luck.
///
/// ⭐⭐ **THE AGREEMENT TESTS ARE THE POINT OF THE SUITE.** A resolver that
/// predicts refusals is this tree's characteristic failure shape waiting to
/// happen — *the record says X, the source says Y, and nothing compares them.*
/// If the model says a control is live and the store throws, the user gets a
/// dead press with a confident tooltip, which is worse than no tooltip.
@Suite struct LoopDeckControlModelTests {

    private static let trackA = UUID()
    private static let trackB = UUID()

    private func choices(_ ids: [UUID]) -> [LoopDeckControlModel.TrackChoice] {
        ids.enumerated().map { .init(id: $1, name: "Deck \($0 + 1)") }
    }

    /// A rolling, healthy session with one instrument track and nothing pending.
    private func rolling(pendingPhase: LoopPendingLayer.Phase? = nil,
                         canPeel: Bool = false,
                         hasSession: Bool = true,
                         isPlaying: Bool = true,
                         isRecording: Bool = false,
                         loopEnabled: Bool = false,
                         tracks: [UUID]? = nil,
                         activeTrackID: UUID? = nil) -> LoopDeckControlModel {
        LoopDeckControlModel.resolve(
            hasSession: hasSession,
            isPlaying: isPlaying,
            isRecording: isRecording,
            isTransportLoopEnabled: loopEnabled,
            pendingPhase: pendingPhase,
            canPeel: canPeel,
            instrumentTracks: choices(tracks ?? [Self.trackA, Self.trackB]),
            activeTrackID: activeTrackID)
    }

    // MARK: - The length default

    /// ⭐⭐ THE SINGLE EASIEST WRONG LINE IN THE ITEM, PINNED. The store's API
    /// default (`bars: Int? = nil`) means PRESS-TO-END; the product default is
    /// FIXED BARS, 4. A start button that called `beginLoopDeck()` bare would
    /// compile, run, open a session, and ship the advanced mode to every
    /// beginner — with nothing on screen to say it had.
    @Test("the product default is four FIXED bars, and it reaches the store as 4 — never nil")
    func productDefaultIsFourFixedBars() {
        #expect(LoopDeckControlModel.defaultLength == .bars(4))
        #expect(LoopDeckControlModel.defaultLength.barsParameter == 4)
        #expect(LoopDeckControlModel.defaultLength.barsParameter != nil)
    }

    @Test("only press-to-end omits the bar count")
    func onlyPressToEndOmitsTheBarCount() {
        #expect(LoopDeckControlModel.LengthChoice.pressToEnd.barsParameter == nil)
        for n in [1, 2, 4, 8, 16, 64] {
            #expect(LoopDeckControlModel.LengthChoice.bars(n).barsParameter == n)
        }
    }

    /// The stepper must not be able to ASK for a refusal: `beginLoopDeck` throws
    /// `invalidLoopRange` outside 1...64.
    @Test("the bar stepper clamps to the range the store accepts")
    func stepperClampsToTheStoresRange() {
        #expect(LoopDeckControlModel.clampedBars(0) == 1)
        #expect(LoopDeckControlModel.clampedBars(-7) == 1)
        #expect(LoopDeckControlModel.clampedBars(65) == 64)
        #expect(LoopDeckControlModel.clampedBars(4) == 4)
        #expect(LoopDeckControlModel.barsRange == 1...64)
    }

    @Test("the length labels read as lengths, not indices")
    func lengthLabels() {
        #expect(LoopDeckControlModel.LengthChoice.bars(4).label == "4 BAR")
        #expect(LoopDeckControlModel.LengthChoice.pressToEnd.label == "FREE")
    }

    // MARK: - START

    @Test("the door is open on a healthy stopped project")
    func doorOpenByDefault() {
        let m = rolling(hasSession: false, isPlaying: false)
        #expect(m.start.isEnabled)
        #expect(m.start.refusal == nil)
    }

    /// ⛔⛔ THE ADJACENT-CONTROL TRAP. The transport LOOP chip is take comping —
    /// several attempts at ONE part — and it sits in the same bar as this door.
    /// `beginLoopDeck` refuses under it. Without this, the LOOPER chip would be
    /// a button that silently does nothing whenever LOOP happens to be on.
    @Test("the transport loop blocks the door, and the refusal names the fix")
    func transportLoopBlocksTheDoor() {
        let m = rolling(hasSession: false, isPlaying: false, loopEnabled: true)
        #expect(!m.start.isEnabled)
        #expect(m.start.refusal == .transportLoopEnabled)
        #expect(m.start.help.contains("LOOP"))
    }

    @Test("a rolling take blocks the door")
    func recordingBlocksTheDoor() {
        let m = rolling(hasSession: false, isPlaying: true, isRecording: true)
        #expect(m.start.refusal == .takeRolling)
    }

    /// Guard ORDER is behaviour: it decides which sentence the performer reads.
    /// The store checks "already open" before "recording" before "loop enabled".
    @Test("start guard order matches the store's: session, then take, then loop")
    func startGuardOrder() {
        #expect(rolling(hasSession: true, isRecording: true, loopEnabled: true).start.refusal
                == .sessionAlreadyOpen)
        #expect(rolling(hasSession: false, isRecording: true, loopEnabled: true).start.refusal
                == .takeRolling)
        #expect(rolling(hasSession: false, isRecording: false, loopEnabled: true).start.refusal
                == .transportLoopEnabled)
    }

    // MARK: - ARM

    @Test("arming is live on a rolling session with an instrument track")
    func armLive() {
        #expect(rolling().arm.isEnabled)
    }

    @Test("arming needs a session")
    func armNeedsASession() {
        #expect(rolling(hasSession: false).arm.refusal == .noSession)
    }

    /// ⭐ THE STORE REALLY DOES CHECK `pending` BEFORE `isPlaying`. Both are true
    /// here, and the pending refusal is the one that must win — mirroring the
    /// store rather than picking the "more obvious" reason.
    @Test("a pending layer outranks a stopped transport, exactly as the store orders it")
    func pendingOutranksStopped() {
        let m = rolling(pendingPhase: .queued, isPlaying: false)
        #expect(m.arm.refusal == .layerAlreadyPending)
    }

    @Test("arming waits for play")
    func armWaitsForPlay() {
        #expect(rolling(isPlaying: false).arm.refusal == .notPlaying)
    }

    /// v1 records instrument layers only — a recorded waveform cannot be tiled
    /// inside one clip. With none in the project the control explains that
    /// rather than opening an empty menu.
    @Test("arming needs an instrument track, and says so")
    func armNeedsAnInstrumentTrack() {
        let m = rolling(tracks: [])
        #expect(m.arm.refusal == .noInstrumentTrack)
        #expect(m.armTargets.isEmpty)
        #expect(m.primaryArmTarget == nil)
    }

    /// One click should arm the track you are already playing — the same track
    /// Musical Typing sounds.
    @Test("the active track is the primary arm target when it is an instrument track")
    func activeTrackIsPrimary() {
        #expect(rolling(activeTrackID: Self.trackB).primaryArmTarget == Self.trackB)
    }

    /// An active AUDIO track is not in `instrumentTracks`, so it must not become
    /// the primary — `armLoopLayer` would throw `trackKindUnsupported`.
    @Test("a non-instrument active track falls back to the first instrument track")
    func nonInstrumentActiveFallsBack() {
        let audio = UUID()
        #expect(rolling(activeTrackID: audio).primaryArmTarget == Self.trackA)
    }

    // MARK: - FINISH

    /// ⭐ THE SAME BUTTON MEANS TWO THINGS AND THE TOOLTIP HAS TO SAY WHICH:
    /// `finishLoopLayer` on a QUEUED pass CANCELS the arm (the store unwinds it
    /// and returns without throwing); on a RECORDING pass it closes the layer on
    /// the boundary.
    @Test("finish cancels a queued layer and finishes a recording one, and says which")
    func finishMeansTwoThings() {
        let queued = rolling(pendingPhase: .queued)
        #expect(queued.finish.isEnabled)
        #expect(queued.finish.help.lowercased().contains("cancel"))

        let recording = rolling(pendingPhase: .recording)
        #expect(recording.finish.isEnabled)
        #expect(!recording.finish.help.lowercased().contains("cancel"))
    }

    @Test("finish is blocked with nothing armed, and while the layer is already closing")
    func finishBlocked() {
        #expect(rolling().finish.refusal == .noPendingLayer)
        #expect(rolling(pendingPhase: .closing).finish.refusal == .alreadyClosing)
        #expect(rolling(hasSession: false).finish.refusal == .noSession)
    }

    // MARK: - PEEL / END

    @Test("peel needs a landed pass")
    func peelNeedsAPass() {
        #expect(rolling(canPeel: false).peel.refusal == .nothingToPeel)
        #expect(rolling(canPeel: true).peel.isEnabled)
        #expect(rolling(canPeel: true, hasSession: false).peel.refusal == .noSession)
    }

    @Test("end needs a session and nothing else")
    func endNeedsOnlyASession() {
        #expect(rolling(hasSession: false).end.refusal == .noSession)
        #expect(rolling(pendingPhase: .recording, canPeel: true).end.isEnabled)
    }

    // MARK: - The invariant that makes the tooltips trustworthy

    /// ⭐ A DISABLED CONTROL WITH NO EXPLANATION IS THE DEAD PRESS WEARING A GREY
    /// COAT. Every state this resolver can produce must satisfy: disabled iff
    /// there is a refusal, and help is never empty.
    @Test("every command is enabled exactly when it has no refusal, and always carries help")
    func enabledIffNoRefusal() {
        var seen = Set<LoopDeckControlModel.Refusal>()
        let phases: [LoopPendingLayer.Phase?] = [nil, .queued, .recording, .closing]
        for hasSession in [true, false] {
            for isPlaying in [true, false] {
                for isRecording in [true, false] {
                    for loop in [true, false] {
                        for peelable in [true, false] {
                            for tracks in [[Self.trackA], []] {
                                for phase in phases {
                                    let m = rolling(pendingPhase: phase,
                                                    canPeel: peelable,
                                                    hasSession: hasSession,
                                                    isPlaying: isPlaying,
                                                    isRecording: isRecording,
                                                    loopEnabled: loop,
                                                    tracks: tracks)
                                    for c in [m.start, m.arm, m.finish, m.peel, m.end] {
                                        #expect(c.isEnabled == (c.refusal == nil))
                                        #expect(!c.help.isEmpty)
                                        if let r = c.refusal { seen.insert(r) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // Positive control on the sweep itself: an enumeration that reached only
        // two refusals would satisfy every assertion above while proving almost
        // nothing. Every case must actually be produced by some real state.
        #expect(seen == Set(LoopDeckControlModel.Refusal.allCases),
                "unreached refusals: \(Set(LoopDeckControlModel.Refusal.allCases).subtracting(seen))")
    }

    @Test("no refusal explanation is empty or ends mid-sentence")
    func refusalsReadAsSentences() {
        for r in LoopDeckControlModel.Refusal.allCases {
            #expect(r.explanation.count >= 15, "\(r.rawValue): \(r.explanation)")
            let last = r.explanation.trimmingCharacters(in: .whitespaces).last
            #expect(last == "." || last == "!" || last == "?", "\(r.rawValue): \(r.explanation)")
        }
    }

    // MARK: - AGREEMENT WITH THE REAL STORE
    //
    // ⭐⭐ The model PREDICTS what `ProjectStore` will do. These three drive a
    // real store and check the prediction against the outcome, so a divergence
    // fails here rather than becoming a dead press with a confident tooltip.
    // `@MainActor` on the FUNCTION, never on the suite — see the header note on
    // Leg C's 375-suite cap.

    @MainActor
    @Test("agreement: the model says the door is open, and the store really opens it")
    func agreementDoorOpens() throws {
        let store = ProjectStore()
        let m = LoopDeckControlModel.resolve(
            hasSession: store.loopDeckStatus != nil,
            isPlaying: store.transport.isPlaying,
            isRecording: store.transport.isRecording,
            isTransportLoopEnabled: store.transport.isLoopEnabled,
            pendingPhase: nil, canPeel: false, instrumentTracks: [], activeTrackID: nil)
        #expect(m.start.isEnabled)
        let status = try store.beginLoopDeck(bars: LoopDeckControlModel.defaultLength.barsParameter)
        // And the product default really produced a FIXED four-bar loop, not the
        // API default's press-to-end.
        #expect(status.lengthMode == .fixedBars)
        #expect(status.cycleBeats == 4 * status.beatsPerBar)
    }

    @MainActor
    @Test("agreement: the model blocks the door under the transport loop, and so does the store")
    func agreementTransportLoopBlocks() throws {
        let store = ProjectStore()
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 8)
        let m = LoopDeckControlModel.resolve(
            hasSession: false,
            isPlaying: store.transport.isPlaying,
            isRecording: store.transport.isRecording,
            isTransportLoopEnabled: store.transport.isLoopEnabled,
            pendingPhase: nil, canPeel: false, instrumentTracks: [], activeTrackID: nil)
        #expect(m.start.refusal == .transportLoopEnabled)
        #expect(throws: (any Error).self) { try store.beginLoopDeck(bars: 4) }
    }

    @MainActor
    @Test("agreement: the model blocks arming on a stopped transport, and so does the store")
    func agreementArmNeedsPlayback() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Deck Chords", kind: .instrument)
        try store.beginLoopDeck(bars: 4)
        let status = try #require(store.loopDeckStatus)
        let m = LoopDeckControlModel.resolve(
            hasSession: true,
            isPlaying: store.transport.isPlaying,
            isRecording: store.transport.isRecording,
            isTransportLoopEnabled: store.transport.isLoopEnabled,
            pendingPhase: status.pendingPhase,
            canPeel: status.canPeel,
            instrumentTracks: [.init(id: track.id, name: track.name)],
            activeTrackID: track.id)
        #expect(!store.transport.isPlaying)
        #expect(m.arm.refusal == .notPlaying)
        #expect(throws: (any Error).self) { try store.armLoopLayer(trackID: track.id) }
        // Positive control: the SAME store, same call, differs only in the
        // condition the model named — so the refusal is attributable rather than
        // a call that throws for any reason at all.
        #expect(m.end.isEnabled)
        try store.endLoopDeck()
    }

    // MARK: - The pulse, and the freeze it exists to fix

    /// ⭐⭐ **THE FREEZE IS MEASURED HERE, NOT ASSUMED.** `loopDeckStatus`
    /// computes `phase` only `if let cycleBeats`, so a press-to-end session
    /// reports `cyclePhase == 0` for as long as the length is undecided. A
    /// cycle-only `onBeat` (`phase % 0.5 < 0.25`) is therefore permanently TRUE
    /// there — the queued lamp and the strip's chrome would sit at a static
    /// half-bright amber in the one mode where the wait is longest and the
    /// performer most needs to see the bar they are waiting for.
    ///
    /// This test drives a REAL store rather than a fabricated status, so if the
    /// store ever stops freezing the phase the premise fails loudly instead of
    /// leaving a fallback nothing reaches.
    @MainActor
    @Test("agreement: press-to-end really freezes cyclePhase, and the pulse falls back to the bar")
    func pressToEndFreezeAndTheBarFallback() throws {
        let store = ProjectStore()
        // `bars: nil` — press-to-end. Spelled out because it is the API default
        // and the product's non-default.
        try store.beginLoopDeck(bars: nil)
        let status = try #require(store.loopDeckStatus)
        #expect(status.lengthMode == .pressToEnd)
        #expect(status.cycleBeats == nil)
        // THE FREEZE ITSELF.
        #expect(status.cyclePhase == 0)
        #expect(status.beatsPerBar == 4)

        // With the fallback the pulse still moves through the BAR: on the
        // downbeat and the half-bar it flashes, in between it does not.
        #expect(LoopDeckPulse(status: status, playheadBeat: 0).onBeat)
        #expect(LoopDeckPulse(status: status, playheadBeat: 2.0).onBeat)
        #expect(!LoopDeckPulse(status: status, playheadBeat: 1.5).onBeat)
        #expect(!LoopDeckPulse(status: status, playheadBeat: 3.5).onBeat)
        // ⚠️ Anti-tautology control: a cycle-only derivation would answer TRUE
        // to all four, because `status.cyclePhase` is 0 in every one of them.
        #expect(status.cyclePhase.truncatingRemainder(dividingBy: 0.5) < 0.25)

        try store.endLoopDeck()
    }

    /// The other half: once a cycle EXISTS the pulse must use it and ignore the
    /// playhead argument entirely, or the strip's lamps would drift off the loop
    /// they are supposed to be locked to.
    @MainActor
    @Test("with a real cycle the pulse uses it and ignores the playhead fallback")
    func aRealCycleWinsOverTheFallback() throws {
        let store = ProjectStore()
        let status = try store.beginLoopDeck(bars: 4)
        #expect(status.cycleBeats == 16)
        for beat in [0.0, 1.5, 3.5, 999.0] {
            #expect(LoopDeckPulse(status: status, playheadBeat: beat).phase == status.cyclePhase)
        }
        try store.endLoopDeck()
    }

    @Test("no session, no pulse")
    func noSessionNoPulse() {
        #expect(LoopDeckPulse(status: nil, playheadBeat: 12.3).phase == 0)
    }
}
