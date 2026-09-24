import DAWAppKit
import DAWCore
import Foundation

// m23-ap Phase 2 — THE PRESET DOOR's app tier: the two funnels the arrange
// clip context menu calls, and nothing else.
//
// Kept OUT of `DAWProApp.swift` on the `PadGridStaging` / `MusicalTypingStaging`
// shape (that file is ~13k lines and agents have died to a liveness watchdog
// reading it).
//
// ⚠️ **EVERYTHING IN THIS FILE IS COMPOSITION AND IS THEREFORE INVISIBLE TO
// `Tests/`** — `DAWApp` is an executable target with no test target. The
// DECIDABLE half lives in `DAWCore` (`PitchCorrectionPreset`,
// `ProjectStore.autoCorrectClipPitch`) and is unit-tested there; the WIRING half
// is pinned by `PitchTuneDoorSiteTests`, which reads this source.

extension AppModel {

    /// A clip's context-menu **Tune Vocal ▸ <preset>** fired.
    ///
    /// ⭐ **THE SAME STORE METHOD THE WIRE CALLS, WITH THE SAME OPTIONS.**
    /// `clip.autoCorrectPitch` with a `preset` and no key builds
    /// `preset.options(scale: .chromatic)` — which is exactly `preset.options()`,
    /// since `PitchCorrectionPreset.options(scale:)` defaults the scale to
    /// chromatic. So this door resolves NO policy of its own: no second
    /// strength, no second retune time, no second scale. Design §6.2: "all
    /// three doors call ONE store method."
    ///
    /// ⚠️ Design §6.3 item 3 describes a store-side improvement — default the
    /// scale to the clip's DETECTED KEY and say so in the UI — that the shipped
    /// `autoCorrectClipPitch(clipId:options:)` does not have. It is deliberately
    /// NOT implemented here: resolving a key in the view would put a second
    /// scale policy in the one place the design says must not have one. When it
    /// lands it belongs in the store, where all three doors inherit it at once.
    ///
    /// Deliberately does NOT touch `arrangeSelection` — the
    /// `convertClipsFromContextMenu` law: right-clicking a clip the user had not
    /// selected tunes that clip alone and leaves their selection theirs. (The
    /// `openChopToPads(clipID:)` precedent selects first, but it must: that card
    /// resolves its target THROUGH the selection. This call names its clip.)
    ///
    /// ⛔ **A REFUSAL IS SHOWN, NEVER SWALLOWED.** The menu hides itself on MIDI
    /// and on a clip with no file, but `engineUnavailable`, a file that has gone
    /// missing since the clip was made, a comp-lane member and a clip deleted
    /// during detection all still throw — and a `try?` here would turn each of
    /// them into a click that does nothing and says nothing.
    ///
    /// ⚠️ **ONE CASE IS GENUINELY OFFERED-THEN-ERRORED, AND IT IS NAMED HERE
    /// RATHER THAN LEFT FOR SOMEONE TO FIND: A TAKE-GROUP COMP MEMBER.** The
    /// menu's gate is `!clip.isMIDI, clip.audioFileURL != nil`, which a comp
    /// member on the main lane satisfies — and `autoCorrectClipPitch` then
    /// refuses it through `requireNotCompMember` (`ProjectStore.swift:5286`:
    /// any clip with a non-nil `takeGroupID` throws `clipInTakeGroup`). So that
    /// clip is offered a tuning it cannot have. Three things about it:
    ///
    ///  1. **The refusal is SHOWN, verbatim, on the clip** — this is not the
    ///     m25-c-2 defect, where Humanize/Quantize offered Apply on a comp
    ///     member, the store threw, and a `try?` ate it.
    ///  2. **"Chop to Pads…" shares this exact gate and this exact hole**, so
    ///     tightening one without the other would make the two entries disagree
    ///     about a rule they currently share.
    ///  3. **The ask-form already exists** — `ProjectStore.compEditRefusal(clipID:)`
    ///     (m25-c-2, "for surfaces that must refuse before the press") — and is the
    ///     right fix — but hiding or disabling an entry for take members is a
    ///     policy that reaches Chop to Pads too, and is not this item's to make.
    ///     ⚠️ `takeMenuLanes.isEmpty` is NOT a sound proxy for it either: a clip
    ///     whose `takeGroupID` names a group the track no longer holds draws an
    ///     EMPTY take menu and is still refused.
    ///
    /// ⛔ **AND SO IS A SILENT SUCCESS.** `autoCorrectClipPitch` stores `nil` and
    /// returns normally when the detector found no voiced runs at all (an
    /// instrumental, a take below the silence floor, a contour it could not
    /// voice). That is a success with no result — exactly the shape this tree
    /// keeps paying for — so it gets the same amber bubble a refusal would, in a
    /// sentence written for a person rather than for an agent. The wire says the
    /// same thing to agents in `clip.autoCorrectPitch`'s `warnings`.
    func tuneVocalFromContextMenu(clipID: UUID, preset: PitchCorrectionPreset) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let clip = try await self.store.autoCorrectClipPitch(
                    clipId: clipID, options: preset.options())
                if clip.pitchEdits == nil {
                    self.presentArrangeSplitRefusal(
                        PitchTuningFoundNothing(presetName: preset.displayName),
                        clipID: clipID)
                }
            } catch {
                self.presentArrangeSplitRefusal(error, clipID: clipID)
            }
        }
    }

    /// A clip's context-menu **Tune Vocal ▸ Remove Tuning** fired. Synchronous —
    /// clearing needs no detection — and routed to the SAME
    /// `ProjectStore.clearClipPitchEdits` the wire's `clip.clearPitchEdits`
    /// calls, which writes `nil` (never an empty set) so a cleared clip renders
    /// byte-identically to one that was never tuned.
    func clearClipTuningFromContextMenu(clipID: UUID) {
        do {
            _ = try store.clearClipPitchEdits(clipId: clipID)
        } catch {
            presentArrangeSplitRefusal(error, clipID: clipID)
        }
    }
}

/// The novice-facing twin of `clip.autoCorrectPitch`'s zero-voiced-run warning.
///
/// ⚠️ **DELIBERATELY A DIFFERENT SENTENCE FROM THE WIRE'S, FOR A DIFFERENT
/// READER.** The wire's warning tells an agent to check `clip.detectPitch`'s
/// `voicedFraction`; neither of those names means anything to the person who
/// just clicked "Natural". Both say the same fact — nothing was found to tune,
/// and here is the likely reason — and neither is a policy, so this is a second
/// SENTENCE, not a second behaviour.
private struct PitchTuningFoundNothing: LocalizedError {
    let presetName: String
    var errorDescription: String? {
        "\(presetName) found no singing to tune here. Tuning moves sung notes, "
            + "so a clip that is instrumental, very quiet, or silent has nothing "
            + "for it to move."
    }
}
