import Foundation
import DAWCore

// W7-NTU U1 — THE "SOUND LIKE THE SINGER" GROUP'S ONE WAY INTO THE STORE.
//
// Design: `docs/design/2026-09-25-natural-tuning.md` X9 (the group), X4 (ONE
// upgrade path), §1(f) / §2f / §4.f (each row's store door).
//
// ⭐ **WHY THIS IS HERE AND NOT IN THE APP LAYER** — `PitchEditorWobbleWrite`'s
// reason, unchanged: `PitchCorrectionStaging` (DAWApp) is the app's commit
// funnel and DAWApp has no test target. A test that mirrored its store calls
// would prove the MIRROR; a staging arm that called the wrong setter (a
// voice-size write on an old vocal, which would switch off D4-1's update for
// good) would pass it. So each write and its read-back live in ONE function,
// here, that the funnel calls and `PitchEditorModelTests` calls: a defect
// planted here turns the suite red.
//
// ⛔ **THE READ-BACK READS THE STORE, NEVER THE SETTER'S RETURN.** Each arm
// looks the clip up in `store.tracks` AFTER the write and compares it with an
// expectation computed from what was SENT (the one clamp, run here) — the
// "a setter's return is not proof it took" law, one step stricter than the
// wobble funnel, which reads the returned clip.

/// The header group's four commit kinds, written to the store and read back.
@MainActor
public enum PitchEditorSingerWrite {

    /// Writes `kind` if it is one of the group's commits and reads it back.
    ///
    /// - `.voiceSize`: `ProjectStore.setClipFormantCorrection` — "Keep Voice
    ///   Size", ONE undo step (`structuralKey`: the slider commits once, on
    ///   release). TOOK when the stored `formantCorrection` is the amount sent,
    ///   clamped to `formantCorrectionRange`.
    /// - `.naturalTuningUpdate`: `ProjectStore.upgradeToNaturalTuning` — "Update
    ///   Tuning", ONE undo step. TOOK when the stored set is the set it was
    ///   BEFORE the write, updated (`upgradedToNaturalTuning()`), with every
    ///   note unchanged: the update touches the three set-level fields only.
    /// - `.consonants`: `ProjectStore.setClipConsonantProtection` — "Keep
    ///   Consonants". TOOK when the stored ON/OFF reading
    ///   (`keepsConsonantsUntuned`) is the one sent: the setter's documented
    ///   contract, and deliberately NOT the stored choice's encoding, which
    ///   another lane (W7-D2) owns.
    /// - `.slideSmoothness`: `ProjectStore.setClipPitchTransitionSmoothness` —
    ///   "Slide Smoothness". TOOK when the stored smoothness is the one sent,
    ///   clamped to `transitionSlopeRange`.
    ///
    /// Returns `nil` for any other kind (not this function's), `true` when the
    /// write TOOK, `false` when the store accepted it and does not hold it.
    /// Throws the store's refusal, in its words.
    public static func commit(_ kind: PitchEditorCommit.Kind, clipID: UUID,
                              seedIfAbsent: PitchEditSet?, to store: ProjectStore) throws -> Bool? {
        switch kind {
        case .voiceSize(let amount):
            _ = try store.setClipFormantCorrection(clipId: clipID, amount: amount,
                                                   seedIfAbsent: seedIfAbsent)
            return tookVoiceSize(amount, stored: storedTable(clipID, in: store))
        case .naturalTuningUpdate:
            let before = storedTable(clipID, in: store)
            _ = try store.upgradeToNaturalTuning(clipId: clipID)
            return tookUpdate(before: before, stored: storedTable(clipID, in: store))
        case .consonants(let enabled):
            _ = try store.setClipConsonantProtection(clipId: clipID, enabled: enabled,
                                                     seedIfAbsent: seedIfAbsent)
            return storedTable(clipID, in: store)?.keepsConsonantsUntuned == enabled
        case .slideSmoothness(let centsPerSecond):
            _ = try store.setClipPitchTransitionSmoothness(clipId: clipID,
                                                           centsPerSecond: centsPerSecond,
                                                           seedIfAbsent: seedIfAbsent)
            return tookSlides(centsPerSecond, stored: storedTable(clipID, in: store))
        default:
            return nil
        }
    }

    /// The clip's STORED note table, looked up in the store's own tracks —
    /// never the setter's returned clip.
    public static func storedTable(_ clipID: UUID, in store: ProjectStore) -> PitchEditSet? {
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.id == clipID }) { return clip.pitchEdits }
        }
        return nil
    }

    /// ⛔ The voice-size read-back: the stored amount is the one SENT, through
    /// the one clamp. A non-finite amount is refused by the store before it
    /// writes, so it never reaches here as a success.
    public nonisolated static func tookVoiceSize(_ sent: Double, stored: PitchEditSet?) -> Bool {
        guard sent.isFinite, let stored else { return false }
        return stored.formantCorrection == sent.clamped(to: PitchEditSet.formantCorrectionRange)
    }

    /// ⛔ The update's read-back: what the store holds must be the table it
    /// held BEFORE, updated — the three set-level fields at their seed values
    /// (an explicit smoothness and a chosen consonant OFF kept, the
    /// transform's own rules) — and no note may have moved.
    public nonisolated static func tookUpdate(before: PitchEditSet?, stored: PitchEditSet?) -> Bool {
        guard let before, let stored else { return false }
        return stored == before.upgradedToNaturalTuning()
            && stored.segments == before.segments
            && !stored.predatesNaturalTuning
    }

    /// ⛔ The Slides read-back: the stored smoothness is the one SENT, through
    /// the one clamp. 0 is never a success: the store refuses it.
    public nonisolated static func tookSlides(_ sent: Double, stored: PitchEditSet?) -> Bool {
        guard sent.isFinite, sent > 0, let stored else { return false }
        return stored.transitionSlopeCentsPerSecond
            == sent.clamped(to: PitchEditSet.transitionSlopeRange)
    }
}
