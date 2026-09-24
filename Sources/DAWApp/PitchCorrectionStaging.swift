import DAWAppKit
import DAWControl
import DAWCore
import Foundation

// m23-ap Phase 2 — THE PRESET DOOR's app tier: the two funnels the arrange
// clip context menu calls. Since C-F3 it also holds the confirm card's two
// answers (the preset funnel asks before it erases hand edits) and the
// `debug.tuneVocal` staging seam that drives them.
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
    ///
    /// ⛔⛔ **C-F3 (F22): IT ASKS BEFORE IT ERASES HAND EDITS, AND ONLY THEN.**
    /// A preset REPLACES the clip's whole note table, so on a clip whose notes
    /// were moved or split by hand, one click used to throw that work away and
    /// say nothing. The gate answers from ONE signal,
    /// `PitchEditSet.hasHandEditsSinceAutoCorrect`, read here synchronously at
    /// the click:
    ///  * `.applyNow`: the clip holds exactly what the last preset wrote (or
    ///    nothing). Compare Gentle → Natural → Tight as fast as you can click,
    ///    with no dialog. That is the preset-comparison workflow, and it must
    ///    never be nagged.
    ///  * `.askFirst`: the card is up (`ContentView` mounts it on
    ///    `pitchPresetReplaceGate.pending`). The store is called only from
    ///    `confirmPresetReplace()`, which is the person's own "Replace my edits".
    ///
    /// BOTH preset doors reach this funnel (the clip menu and the note editor's
    /// chips), so both ask. "Remove Tuning" deliberately does NOT: its label
    /// names the loss. See `clearClipTuningFromContextMenu`.
    ///
    /// ⚠️ **A KNOWN WINDOW THIS DOES NOT CLOSE.** The question is asked at the
    /// click, and `autoCorrectClipPitch` then awaits detection (seconds on a long
    /// take) before it writes. A note dragged in the editor during that wait is
    /// overwritten without a question. Only a check inside the store, after the
    /// await, can close that. See the TODO on `tuneVocalDebug`: the wire's
    /// `replaceExisting` check exists but runs before the await.
    func tuneVocalFromContextMenu(clipID: UUID, preset: PitchCorrectionPreset) {
        let clip = liveClip(clipID)
        switch pitchPresetReplaceGate.request(preset, clipID: clipID,
                                              clipName: clip?.name ?? "",
                                              current: clip?.pitchEdits) {
        case .applyNow:
            applyTuningPreset(clipID: clipID, preset: preset)
        case .askFirst:
            // Held. Nothing reaches the store until the person answers.
            break
        }
    }

    /// The confirm card's **Replace my edits**: applies the preset the card
    /// was showing, exactly once (the gate hands it back once and forgets it).
    func confirmPresetReplace() {
        guard let held = pitchPresetReplaceGate.confirm() else { return }
        applyTuningPreset(clipID: held.clipID, preset: held.preset)
    }

    /// The confirm card's **Cancel** (and Esc). Nothing is applied and nothing
    /// is changed. The hand edits stay exactly as they were.
    func cancelPresetReplace() {
        pitchPresetReplaceGate.cancel()
    }

    /// THE ONE STORE CALL both preset doors reach, only after the gate said
    /// "apply now" or the person said "Replace my edits". Everything above
    /// about refusals and the silent zero-note success happens here.
    private func applyTuningPreset(clipID: UUID, preset: PitchCorrectionPreset) {
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

    /// The pitch editor committed ONE note edit (m23-ap Increment C).
    ///
    /// ⭐ **ONE CALL PER GESTURE, NOT PER POINTER TICK** (design §8.2 / §11
    /// P7b). The cadence is enforced in `PitchEditorModel`, which is the only
    /// thing that calls this, and `PitchEditorModelTests.aDragTickNeverCommits`
    /// is what proves it — a source-shape gate over a `DragGesture` closure
    /// could not. Per-tick writes would re-key `ClipKey.pitchEditSetHash` at
    /// pointer rate, the offline render would never be ready, and
    /// `StretchResolution.pending` SKIPS the clip: the vocal would go silent for
    /// the whole drag.
    ///
    /// ⛔⛔ **THE WRITE IS READ BACK, AND THAT IS NOT BELT-AND-BRACES.** "The
    /// call returned" is this tree's characteristic failure shape — an operation
    /// that accepts input, returns something that looks like a valid answer, and
    /// changes nothing. The store CLAMPS the offset to
    /// `NoteSegment.pitchOffsetCentsRange`, so the expectation compared against
    /// is the CLAMPED one; anything else would make a legitimate clamp look like
    /// a lost write and put a refusal on screen for a correct result.
    ///
    /// A refusal is SHOWN, never swallowed — `tuneVocalFromContextMenu`'s rule.
    /// A comp-lane member, a clip deleted mid-gesture, a MIDI clip reached by a
    /// stale pane and a cut too near a note's edge all throw, and a `try?` here
    /// would turn each into a drag that does nothing and says nothing.
    func commitPitchNoteEdit(clipID: UUID, commit: PitchEditorCommit) {
        do {
            switch commit.kind {
            case .notePitch(let segmentID, let offsetCents):
                let clip = try store.setClipNotePitchOffset(
                    clipId: clipID, segmentId: segmentID,
                    offsetCents: offsetCents, seedIfAbsent: commit.seedIfAbsent)
                let expected = offsetCents.clamped(to: NoteSegment.pitchOffsetCentsRange)
                let stored = clip.pitchEdits?.segments
                    .first(where: { $0.id == segmentID })?.pitchOffsetCents
                guard let stored, stored == expected else {
                    presentArrangeSplitRefusal(PitchNoteEditDidNotTake(), clipID: clipID)
                    return
                }
            case .splitNote(let segmentID, let atSourceSecond):
                let clip = try store.splitClipNoteSegment(
                    clipId: clipID, segmentId: segmentID,
                    atSourceSecond: atSourceSecond, seedIfAbsent: commit.seedIfAbsent)
                // The parent keeps its id and becomes the LEFT half, so the cut
                // is visible in the stored table as that segment's new end. A
                // count check alone would pass against a split that put the cut
                // somewhere else entirely.
                let left = clip.pitchEdits?.segments.first(where: { $0.id == segmentID })
                guard let left, left.endSeconds == atSourceSecond else {
                    presentArrangeSplitRefusal(PitchNoteEditDidNotTake(), clipID: clipID)
                    return
                }
            }
        } catch {
            presentArrangeSplitRefusal(error, clipID: clipID)
        }
    }

    /// A clip's context-menu **Tune Vocal ▸ Remove Tuning** fired. Synchronous —
    /// clearing needs no detection — and routed to the SAME
    /// `ProjectStore.clearClipPitchEdits` the wire's `clip.clearPitchEdits`
    /// calls, which writes `nil` (never an empty set) so a cleared clip renders
    /// byte-identically to one that was never tuned.
    ///
    /// ⭐ **C-F3: THIS DOES NOT ASK, AND THAT IS A DECISION.** It erases hand
    /// edits just as a preset does, but its label NAMES the loss. "Remove
    /// Tuning" says what goes, and a moved note IS tuning (the store's own undo
    /// label for a note drag is "Tune Note"). A preset asks because its erasure
    /// is a side effect its label does not name: "Natural" says nothing about
    /// your edits, and people click it to compare. The rule, in
    /// `docs/DESIGN-LANGUAGE.md`: confirm when the loss is a side effect the
    /// label does not name, and never when the state is the machine's own
    /// output. Undo (⌘Z) reverses it in one step either way.
    func clearClipTuningFromContextMenu(clipID: UUID) {
        do {
            _ = try store.clearClipPitchEdits(clipId: clipID)
        } catch {
            presentArrangeSplitRefusal(error, clipID: clipID)
        }
    }

    /// `debug.tuneVocal`: the preset door, driven the way the menu drives it,
    /// so a gate can press Tune Vocal ▸ <preset>, answer the card, and
    /// photograph what a person sees in between.
    ///
    /// ⛔ **APP TIER, deliberately OFF `allCommands` and off MCP** (the
    /// `debug.padGrid` precedent). An agent tunes through
    /// `clip.autoCorrectPitch`, and this confirm's wire half is that verb's
    /// `replaceExisting` flag.
    ///
    /// TODO(mcp-integration-engineer, C-F3 wire half): (1) `clip.autoCorrectPitch`
    /// `replaceExisting:false` now refuses on
    /// `PitchEditSet.hasHandEditsSinceAutoCorrect` (adopted 2026-09-24), but it
    /// asks BEFORE the detection await, so the mid-detection window named at
    /// `tuneVocalFromContextMenu` is still open. Closing it needs the same
    /// question asked again after the await, just before the write (the stamp
    /// costs about 1 ms at 450 notes, measured). Once that exists, this funnel's
    /// `.applyNow` path should pass `replaceExisting: false`. MCP tool
    /// `clip_auto_correct_pitch`. (2) Echo the same Bool as
    /// `handEditedSinceAutoCorrect` in `clip.getPitchEdits`, MCP tool
    /// `clip_get_pitch_edits`, so an agent can ask before it replaces.
    ///
    /// params (all optional, applied in this order):
    ///  * `clipId` + `preset`: the menu's OWN funnel, `tuneVocalFromContextMenu`.
    ///    It is never the store directly, because a seam that skipped the gate
    ///    would photograph a door no person walks through.
    ///  * `answer`: `"replace"` | `"cancel"`, the card's two buttons.
    /// Unknown keys are REFUSED, not ignored: a typo'd key that did nothing
    /// would photograph a state nobody asked for (the `debug.padGrid` lesson).
    ///
    /// Echo: `pending` (the held request plus the card's exact words, or null)
    /// and, when `clipId` is given, that clip's signal. The preset itself
    /// applies asynchronously (detection), so read `clip.getPitchEdits` for the
    /// result.
    func tuneVocalDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        let known: Set<String> = ["clipId", "preset", "answer"]
        if let unknown = params.keys.sorted().first(where: { !known.contains($0) }) {
            throw DebugError("debug.tuneVocal: unknown key '\(unknown)'. Known: clipId, preset, answer")
        }
        var clipID: UUID?
        if let raw = params["clipId"]?.stringValue {
            guard let id = UUID(uuidString: raw) else {
                throw DebugError("debug.tuneVocal: 'clipId' is not a UUID: \(raw)")
            }
            clipID = id
        }
        if let raw = params["preset"]?.stringValue {
            guard let preset = PitchCorrectionPreset(rawValue: raw) else {
                throw DebugError("debug.tuneVocal: '\(raw)' is not a preset. One of "
                    + PitchCorrectionPreset.offeredInUI.map(\.rawValue).joined(separator: " "))
            }
            guard let clipID else { throw DebugError("debug.tuneVocal: 'preset' needs a 'clipId'") }
            tuneVocalFromContextMenu(clipID: clipID, preset: preset)
        }
        if let raw = params["answer"]?.stringValue {
            switch raw {
            case "replace": confirmPresetReplace()
            case "cancel": cancelPresetReplace()
            default:
                throw DebugError("debug.tuneVocal: 'answer' must be replace or cancel, got '\(raw)'")
            }
        }

        var echo: [String: JSONValue] = [:]
        if let held = pitchPresetReplaceGate.pending {
            let copy = PitchPresetReplaceCopy(held)
            echo["pending"] = .object([
                "clipId": .string(held.clipID.uuidString),
                "clipName": .string(held.clipName),
                "preset": .string(held.preset.rawValue),
                "title": .string(copy.title),
                "body": .string(copy.body),
                "undoNote": .string(copy.undoNote),
                "confirmLabel": .string(copy.confirmLabel),
                "cancelLabel": .string(copy.cancelLabel),
            ])
        } else {
            echo["pending"] = .null
        }
        if let clipID, let clip = liveClip(clipID) {
            let edits = clip.pitchEdits
            echo["clip"] = .object([
                "clipId": .string(clipID.uuidString),
                "hasPitchEdits": .bool(edits != nil),
                "segmentCount": .number(Double(edits?.segments.count ?? 0)),
                "handEditedSinceAutoCorrect": .bool(edits?.hasHandEditsSinceAutoCorrect ?? false),
                "autoCorrectStamp": edits?.autoCorrectStamp.map { JSONValue.string($0) } ?? .null,
                "contentStamp": edits?.contentStamp.map { JSONValue.string($0) } ?? .null,
            ])
        }
        return .object(echo)
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

/// The read-back failed: the store accepted a note edit and the clip does not
/// carry it.
///
/// ⚠️ **NOBODY HAS EVER SEEN THIS, AND IT IS STILL NOT DEAD CODE.** It is the
/// only thing standing between "a drag that reports success and writes nothing"
/// and a user who watches a blob spring back with no explanation. If it ever
/// fires, the sentence a person needs is "your change did not stick", not a
/// stack frame.
private struct PitchNoteEditDidNotTake: LocalizedError {
    var errorDescription: String? {
        "That change did not stick. The note is back where it was — nothing else "
            + "was altered. Try again, and if it keeps happening the clip may have "
            + "moved or been re-recorded since the editor opened."
    }
}
