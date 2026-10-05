import DAWCore
import Foundation
import Observation

// Tune to Melody, M3 (W7-TTM3) — THE CARD'S DOOR: the one object that opens the card, sends
// Apply through the preset doors' replace gate, makes the ONE store call and lands its result
// on the card. The `PitchEditorWobbleWrite` shape: the app tier (`TuneToMelodyStaging.swift`,
// `PitchCorrectionStaging.swift`) only wires it, and the tests drive this same code against a
// real `ProjectStore`.
//
// ⭐ **NO SECOND REPLACE GUARD.** Apply asks `PitchPresetReplaceGate`, the gate both preset doors
// ask, with the melody riding on the held request. A vocal holding only a preset's (or an
// earlier Tune to Melody's) own output applies at once; one with hand edits raises the same
// "Replace your hand edits?" card, and only its "Replace my edits" reaches the store
// (`confirmedRun`).
//
// ⭐ **ONE STORE CALL, ONE UNDO STEP.** `ProjectStore.autoCorrectClipPitchReport(…, melody:)` is
// the wire's own `clip.autoCorrectPitch` path, and the pass is ONE `performEdit` there. Nothing
// here journals anything.
//
// The decision (ask the gate, or run) is SYNCHRONOUS, so the instant after a press the card,
// the gate and `debug.tuneVocal`'s echo already agree on what happened; only the store's run
// (detection, seconds) is awaited.

/// One store call the door will make: the clip, the preset chip, the melody.
public struct TuneToMelodyRun: Sendable, Equatable {
    public let clipID: UUID
    public let preset: PitchCorrectionPreset
    public let melody: MelodyTuning
}

/// The Tune to Melody card's door. `AppModel` holds one (`tuneToMelodyDoor`); the card is up
/// exactly while `card` is non-nil.
@MainActor
@Observable
public final class TuneToMelodyDoor {

    /// The card on screen, or nil.
    public private(set) var card: TuneToMelodyCard?

    public init() {}

    /// Opens the card on the clip `vocalClipID`, listing the melodies under it. False (and no
    /// new card) when that clip is not an audio clip in `tracks`, or while a run is in flight.
    @discardableResult
    public func open(vocalClipID: UUID, tracks: [Track], tempoMap: TempoMap) -> Bool {
        if let card, !card.canClose { return false }
        for track in tracks {
            guard let vocal = track.clips.first(where: { $0.id == vocalClipID }) else { continue }
            guard !vocal.isMIDI else { return false }
            card = TuneToMelodyCard(vocal: vocal, vocalTrackName: track.name, tracks: tracks,
                                    tempoMap: tempoMap)
            return true
        }
        return false
    }

    /// Closes the card. Refused while a run is in flight or the replace card is asking: the
    /// answer must land somewhere the person can see it.
    @discardableResult
    public func close() -> Bool {
        guard let card else { return true }
        guard card.canClose else { return false }
        self.card = nil
        return true
    }

    public func select(_ choiceID: String) { card?.select(choiceID) }
    public func choosePreset(_ preset: PitchCorrectionPreset) { card?.choosePreset(preset) }
    public func setMatchOctave(_ on: Bool) { card?.setMatchOctave(on) }

    /// **Apply.** Asks the replace gate about the vocal's table as it is NOW. `.applyNow`: the
    /// card is tuning and the run is returned for `perform`. `.askFirst`: the request (melody
    /// on it) is held by the gate, the card waits for the person's answer, and nil comes back:
    /// nothing runs.
    public func apply(gate: PitchPresetReplaceGate, store: ProjectStore) -> TuneToMelodyRun? {
        guard let card, card.canApply, let melody = card.melodyTuning else { return nil }
        let current = store.tracks.lazy.flatMap(\.clips)
            .first { $0.id == card.vocalClipID }?.pitchEdits
        switch gate.request(card.preset, clipID: card.vocalClipID, clipName: card.vocalName,
                            current: current, melody: melody) {
        case .applyNow:
            self.card?.markTuning()
            return TuneToMelodyRun(clipID: card.vocalClipID, preset: card.preset, melody: melody)
        case .askFirst:
            self.card?.markWaitingForAnswer()
            return nil
        }
    }

    /// The replace card's **Replace my edits** on a request this door sent: exactly what was
    /// held (the gate hands it back once), for `perform`. nil for a request with no melody: a
    /// preset door's, not this one's.
    public func confirmedRun(_ held: PitchPresetReplaceRequest) -> TuneToMelodyRun? {
        guard let melody = held.melody else { return nil }
        if card?.vocalClipID == held.clipID { card?.markTuning() }
        return TuneToMelodyRun(clipID: held.clipID, preset: held.preset, melody: melody)
    }

    /// The replace card's **Cancel**: nothing ran; the card is back to picking.
    public func replaceDeclined() {
        card?.markDeclined()
    }

    /// THE ONE STORE CALL. A refusal comes back in the store's own words and is shown
    /// verbatim; a pass that found no singing says so (`TuneToMelodyCopy.foundNoSinging`).
    public func perform(_ run: TuneToMelodyRun, store: ProjectStore) async {
        let landing: (inout TuneToMelodyCard) -> Void
        do {
            let report = try await store.autoCorrectClipPitchReport(
                clipId: run.clipID, options: run.preset.options(), melody: run.melody)
            if let outcome = TuneToMelodyOutcome(report: report) {
                landing = { $0.finish(outcome) }
            } else {
                // The store answers a melody request with a melody block; a report without
                // one is a pass this card did not ask for, and saying "tuned" would be a guess.
                landing = { $0.refuse(TuneToMelodyCopy.noReport) }
            }
        } catch {
            let message = error.localizedDescription
            landing = { $0.refuse(message) }
        }
        // The card cannot close while it is tuning (`canClose`), so it is still this run's.
        if var shown = card, shown.vocalClipID == run.clipID {
            landing(&shown)
            card = shown
        }
    }
}
