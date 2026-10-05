import DAWAppKit
import DAWControl
import DAWCore
import SwiftUI

// Tune to Melody, M3 (W7-TTM3) — THE CARD'S APP TIER: the funnels the clip menu and the card
// call, the card's mount, and the `debug.tuneVocal {melody: …}` staging block.
//
// Kept OUT of `DAWProApp.swift` on the `PadGridStaging` / `PitchCorrectionStaging` shape.
// Exactly two things about this feature live over there: the `tuneToMelodyDoor` property and
// its term in `isModalPresented` (⌫ must not reach the vocal under the card).
//
// ⚠️ **COMPOSITION ONLY, AND THEREFORE INVISIBLE TO `Tests/`** (`DAWApp` has no test target).
// Every decision is DAWAppKit's `TuneToMelodyDoor` / `TuneToMelodyCard`, driven by
// `TuneToMelodyDoorTests` against a real store; this wiring is pinned by
// `TuneToMelodySiteTests`, which reads this source.

extension AppModel {

    /// The clip menu's **Tune Vocal ▸ Tune to Melody…** fired: the card opens on that clip with
    /// the melodies under it, read from the project as it is now. Like the preset door, it does
    /// not touch the arrange selection: the menu named its clip.
    func openTuneToMelody(clipID: UUID) {
        tuneToMelodyDoor.open(vocalClipID: clipID, tracks: store.tracks,
                              tempoMap: store.transport.tempoMap)
    }

    /// The card's **Apply**. The door asks the preset doors' replace gate (no second guard):
    /// a vocal with no hand edits runs now; one with hand edits raises "Replace your hand
    /// edits?", whose answer comes back through `confirmPresetReplace` /
    /// `cancelPresetReplace` (`PitchCorrectionStaging.swift`).
    func applyTuneToMelodyFromCard() {
        if let run = tuneToMelodyDoor.apply(gate: pitchPresetReplaceGate, store: store) {
            performTuneToMelody(run)
        }
    }

    /// The ONE store call, awaited off the click (detection takes seconds); the result, or
    /// the store's refusal in its own words, lands on the card.
    func performTuneToMelody(_ run: TuneToMelodyRun) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.tuneToMelodyDoor.perform(run, store: self.store)
        }
    }

    /// The card's ✕. Refused by the door while a run is in flight or the replace card is up.
    func closeTuneToMelody() {
        tuneToMelodyDoor.close()
    }

    /// `debug.tuneVocal`'s `melody` block: the card driven the way a person drives it, so a
    /// gate can open it, pick, press Apply and photograph what a person sees. Every action goes
    /// through the funnels above (never the store). Keys, applied in this order:
    /// `open` (Bool, needs the seam's `clipId`), `pick` (a row id, or its index as a number),
    /// `preset` (a preset's raw value), `matchOctave` (Bool), `apply` (Bool), `close` (Bool).
    /// Unknown keys are REFUSED (the `debug.padGrid` lesson).
    func tuneToMelodyDebug(_ params: [String: JSONValue], clipID: UUID?) throws {
        let known: Set<String> = ["open", "pick", "preset", "matchOctave", "apply", "close"]
        if let unknown = params.keys.sorted().first(where: { !known.contains($0) }) {
            throw DebugError("debug.tuneVocal melody: unknown key '\(unknown)'. Known: "
                + known.sorted().joined(separator: ", "))
        }
        if params["open"]?.boolValue == true {
            guard let clipID else { throw DebugError("debug.tuneVocal melody.open needs a 'clipId'") }
            openTuneToMelody(clipID: clipID)
        }
        if let pick = params["pick"] {
            let rows = tuneToMelodyDoor.card?.choices ?? []
            if let id = pick.stringValue {
                guard rows.contains(where: { $0.id == id }) else {
                    throw DebugError("debug.tuneVocal melody.pick: no row '\(id)'")
                }
                tuneToMelodyDoor.select(id)
            } else if let index = pick.doubleValue.map({ Int($0) }) {
                guard rows.indices.contains(index) else {
                    throw DebugError("debug.tuneVocal melody.pick: no row \(index) of \(rows.count)")
                }
                tuneToMelodyDoor.select(rows[index].id)
            }
        }
        if let raw = params["preset"]?.stringValue {
            guard let preset = PitchCorrectionPreset(rawValue: raw),
                  TuneToMelodyCard.presets.contains(preset) else {
                throw DebugError("debug.tuneVocal melody.preset: '\(raw)' is not a chip. One of "
                    + TuneToMelodyCard.presets.map(\.rawValue).joined(separator: " "))
            }
            tuneToMelodyDoor.choosePreset(preset)
        }
        if let on = params["matchOctave"]?.boolValue {
            tuneToMelodyDoor.setMatchOctave(on)
        }
        if params["apply"]?.boolValue == true {
            applyTuneToMelodyFromCard()
        }
        if params["close"]?.boolValue == true {
            closeTuneToMelody()
        }
    }

    /// What the card shows, word for word, and what the menu item would say for `clipID`.
    func tuneToMelodyEcho(clipID: UUID?) -> [String: JSONValue] {
        var echo: [String: JSONValue] = [:]
        if let card = tuneToMelodyDoor.card {
            typealias C = TuneToMelodyCopy
            let phase: String
            var result: [String: JSONValue] = [:]
            switch card.phase {
            case .choosing: phase = "choosing"
            case .waitingForAnswer: phase = "waitingForAnswer"
            case .tuning: phase = "tuning"
            case .finished(let outcome):
                phase = "finished"
                result = [
                    "summary": .string(C.summary(outcome)),
                    "farMoveNote": C.farMoveNote(outcome).map { .string($0) } ?? .null,
                    "tunedNotes": .number(Double(outcome.tunedNotes)),
                    "untouchedNotes": .number(Double(outcome.untouchedNotes)),
                    "farMoves": .number(Double(outcome.farMoves)),
                    "foundSinging": .bool(outcome.foundSinging),
                ]
            case .refused(let message):
                phase = "refused"
                result = ["refusal": .string(message)]
            }
            echo["melodyCard"] = .object([
                "vocalClipId": .string(card.vocalClipID.uuidString),
                "source": .string(C.sourceLine(vocalName: card.vocalName,
                                               trackName: card.vocalTrackName)),
                "choices": .array(card.choices.map { choice in
                    .object([
                        "id": .string(choice.id),
                        "name": .string(C.choiceName(choice)),
                        "detail": .string(C.choiceDetail(choice)),
                        "isClip": .bool(choice.isClip),
                        "notesUnderVocal": .number(Double(choice.notesUnderVocal)),
                    ])
                }),
                "selected": card.selectedID.map { .string($0) } ?? .null,
                "preset": .string(card.preset.rawValue),
                "presetLine": .string(C.presetLine(card.preset)),
                "matchOctave": .bool(card.matchOctave),
                "octaveLine": .string(card.matchOctave ? C.octaveOnLine : C.octaveOffLine),
                "phase": .string(phase),
                "canApply": .bool(card.canApply),
                "canClose": .bool(card.canClose),
                "result": .object(result),
            ])
        } else {
            echo["melodyCard"] = .null
        }
        if let clipID, let vocal = liveClip(clipID), !vocal.isMIDI {
            let item = TuneToMelodyMenu.availability(vocal: vocal, tracks: store.tracks,
                                                     tempoMap: store.transport.tempoMap)
            echo["melodyMenu"] = .object([
                "title": .string(TuneToMelodyCopy.menuTitle),
                "enabled": .bool(item.isEnabled),
                "help": .string(item.help),
            ])
        }
        return echo
    }
}

/// The card, mounted on the door: drawn while `tuneToMelodyDoor.card` is non-nil, every answer
/// routed to the funnels above. `ContentView` places it in `pickerOverlays`, which it mounts
/// BEFORE `.presetReplaceConfirmOverlay(model)`, so the "Replace your hand edits?" card that
/// Apply can raise draws ON TOP of this one.
struct TuneToMelodyCardMount: View {
    let model: AppModel

    var body: some View {
        if let card = model.tuneToMelodyDoor.card {
            TuneToMelodyCardView(
                card: card,
                onSelect: { model.tuneToMelodyDoor.select($0) },
                onPreset: { model.tuneToMelodyDoor.choosePreset($0) },
                onMatchOctave: { model.tuneToMelodyDoor.setMatchOctave($0) },
                onApply: { model.applyTuneToMelodyFromCard() },
                onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeTuneToMelody() } }
            )
        }
    }
}
