import AppKit
import DAWAppKit
import DAWControl
import DAWCore
import SwiftUI

// m39-pads — THE PAD GRID's app tier: the model's injectors, the mouse funnels,
// the chop action, and the `debug.padGrid` staging seam.
//
// Kept OUT of `DAWProApp.swift` on the `MusicalTypingStaging` shape (that file is
// ~10.4k lines and agents have died to a liveness watchdog reading it). Exactly
// three things about this feature live over there — the `padGrid` property, its
// construction, and one `case` line in the debug table.
//
// ⚠️ **EVERYTHING IN THIS FILE IS COMPOSITION AND IS THEREFORE INVISIBLE TO
// `Tests/`** — `DAWApp` is an executable target with no test target. The
// DECIDABLE half lives in `DAWAppKit` (`PadGridGeometry`, `PadGridModel`,
// `MusicalTypingController`) and is unit-tested there; the WIRING half is pinned
// by `PadGridSiteTests`, which reads this source, and is DRIVEN by
// `debug.padGrid`, which injects below the mouse.

extension AppModel {

    // MARK: - Bootstrap

    /// Points the pad grid at the live app. Called from `init`, right after
    /// `installMusicalTyping()`.
    ///
    /// ⛔ **NOT OPTIONAL, AND ITS ABSENCE IS INVISIBLE.** An unbound model draws
    /// sixteen dim squares and reports `loadedCount: 0` — a perfectly
    /// self-consistent picture of an empty kit, over a sampler holding 53
    /// slices. `PadGridModel.isBound` exists so that state is nameable and
    /// `PadGridSiteTests` can pin this call rather than pinning a render.
    func installPadGrid() {
        // Replaced WHOLE, because the placeholder holds a throwaway controller
        // and the real grid must share the app's ONE `musicalTyping` — the
        // single pusher at the live-note sink.
        padGrid = PadGridModel(typing: musicalTyping, zones: { [] }, targetName: { nil })
        padGrid.rebind(
            // ⚠️ THE TRACK IS RESOLVED PER READ, THROUGH A CLOSURE — the
            // `installMusicalTyping` rule, and for the same reason:
            // `activeTrackID` MOVES while the surface is up. A captured UUID
            // would draw the pads of the track the user left.
            zones: { [unowned self] in self.padGridZones() },
            targetName: { [unowned self] in self.padGridTargetName() },
            targetIsAI: { [unowned self] in self.padGridTargetIsAI() },
            selectedClip: { [unowned self] in self.padGridChopSource() },
            // ⛔ BY ID, because the notice must name the track the pads LANDED
            // on and `activeTrackID` is still the SOURCE when the summary is
            // built — the app only clicks the new track afterwards.
            trackNameForID: { [weak store] id in
                store?.tracks.first { $0.id == id }?.name
            },
            oneShot: { [unowned self] in self.padGridOneShot() },
            setOneShot: { [unowned self] on in self.padGridSetOneShot(on) },
            setZones: { [unowned self] zones in self.padGridSetZones(zones) },
            chopAction: { [weak store] clipID, settings, mute in
                guard let store else { throw DebugError("project store unavailable") }
                return try await store.sliceClipToSampler(
                    clipId: clipID, settings: settings, muteSourceTrack: mute)
            })
    }

    // MARK: - Mouse funnels

    /// A PAD was struck with the mouse.
    ///
    /// ⛔ **THE SAME ONE-HOME RULE AS `musicalTypingPointerDown`, for the same
    /// measured reason.** `MusicalKeyboardStrip` takes this as `onPadPress` and
    /// `debug.padGrid {padDown:}` calls it directly, so a gate and a human run
    /// the same three lines. The refresh is not optional: a click on a pad can
    /// be the first thing that happens after the user changed tracks, and
    /// `pointerPress`'s gate reads `targetState`.
    func padGridDown(index: Int, normalizedY: Double) {
        refreshMusicalTypingTarget()
        padGrid.padDown(index: index, normalizedY: normalizedY)
    }

    func padGridUp() {
        padGrid.padUp()
    }

    /// Switches bank. THE one funnel — the chips, the `Z`/`X` keys (which go
    /// through the controller directly, one layer down) and `debug.padGrid`
    /// cannot disagree about what bank is showing.
    func padGridSetBank(_ bank: Int) {
        padGrid.setBank(bank)
    }

    // MARK: - The chop card

    func openChopToPads() {
        // ⚠️ Clear the previous run's notice on OPEN, not on close: a user who
        // chopped, read the notice, and came back to chop again should not have
        // last time's summary sitting over this time's controls.
        padGrid.dismissChopNotice()
        chopToPadsOpen = true
    }

    /// Opens the chop card on a clip named by the ARRANGE CONTEXT MENU.
    ///
    /// ⭐ **SELECTS THE CLIP FIRST, AND THAT IS THE WHOLE POINT.** The card
    /// resolves what it will chop through `padGridChopSource()`, which reads the
    /// app's SELECTION — so opening it straight from a right-click would offer
    /// to chop whatever happened to be selected BEFORE the right-click, or
    /// refuse with "click an audio clip first" while the user is staring at the
    /// menu they opened on one. Right-click does not select on macOS, so this
    /// makes the selection the menu already implied.
    func openChopToPads(clipID: UUID) {
        _ = clickClip(id: clipID, modifiers: .none)
        openChopToPads()
    }

    func closeChopToPads() {
        chopToPadsOpen = false
    }

    /// Runs the chop and closes the card on success.
    ///
    /// ⚠️ **CLOSES ONLY ON SUCCESS.** A refusal keeps the card up with the
    /// store's sentence on it — which names both numbers when the pad ceiling
    /// is what stopped it — beside the very control that fixes it. Closing on
    /// refusal would put the explanation and its remedy in different places.
    func runChopToPads() {
        Task { @MainActor in
            let ok = await padGrid.runChop()
            if ok {
                chopToPadsOpen = false
                // ⭐ A chop that landed is worth LOOKING at. Switch the strip to
                // the pad face and make sure the strip is up at all — otherwise
                // the one visible result of the action is a notice on a surface
                // the user cannot see.
                if !musicalTyping.isEnabled { setMusicalTypingEnabled(true) }
                setMusicalTypingPlayMode(.pads)
                // The chop may have CREATED the pad track; point the app at it
                // so the pads the user is now looking at are the ones the keys
                // will sound.
                if let landed = padGrid.lastChopTrackID {
                    clickTrack(id: landed, modifiers: .none)
                }
                refreshMusicalTypingTarget()
            }
        }
    }

    // MARK: - Injectors

    /// The zones on the pad target. ⚠️ Resolved through `activeTrackID` — the
    /// SAME resolution the live-note sink uses, so the pads that are DRAWN are
    /// always the pads the keys would SOUND. Two different resolutions here
    /// would produce a grid that lights squares on another instrument.
    func padGridZones() -> [SamplerZone] {
        guard let id = activeTrackID,
              let track = store.tracks.first(where: { $0.id == id }),
              track.kind == .instrument,
              let instrument = track.instrument,
              instrument.kind == .sampler else { return [] }
        return instrument.resolvedSampler.zones
    }

    func padGridTargetName() -> String? {
        guard let id = activeTrackID else { return nil }
        return store.tracks.first(where: { $0.id == id })?.name
    }

    /// **VIOLET = AI-TOUCHED, ALWAYS.** A pad goes violet when the material it
    /// holds came from a generator, and the question is asked of the SOURCE FILE
    /// each zone actually points at — not of the track, which a user can rename
    /// and re-kind freely.
    ///
    /// ⚠️ **HONEST WHEN IT CANNOT TELL.** If the store carries no provenance for
    /// the file, this returns false and the pad draws cyan. A grid that guessed
    /// violet from a filename would claim AI provenance it cannot support, which
    /// is a worse failure than missing a real one: the violet law exists so a
    /// user can TRUST that violet means generated.
    func padGridTargetIsAI() -> Bool {
        guard let id = activeTrackID,
              let track = store.tracks.first(where: { $0.id == id }) else { return false }
        return track.clips.contains { $0.isAIGenerated }
    }

    /// The pad target's global one-shot flag, or nil when the active track is
    /// not a built-in sampler.
    ///
    /// ⚠️ Resolved through `activeTrackID` and `resolvedSampler` — the SAME two
    /// steps `padGridZones()` takes, deliberately. A row that read the flag off
    /// a different track than the one whose pads are drawn would be a setting
    /// for an instrument the user is not looking at.
    func padGridOneShot() -> Bool? {
        padGridSampler()?.oneShot
    }

    /// Writes it. Returns the store's refusal, or nil on success.
    ///
    /// ⛔ **THROUGH `store.setInstrument(id:sampler:)` — the one home.** That is
    /// the exact method `track.setInstrument`'s sampler payload and the sampler
    /// editor card's `applySampler` both call, so the pad row, the card and the
    /// wire cannot end up with three different ideas of what one-shot means.
    /// It is a WHOLESALE apply (it re-validates every zone file), which is why
    /// the model guards against a redundant write before calling this.
    func padGridSetOneShot(_ on: Bool) -> String? {
        guard let id = activeTrackID, var params = padGridSampler() else {
            return "This track is not playing the built-in Sampler."
        }
        params.oneShot = on
        do {
            _ = try store.setInstrument(id: id, sampler: params)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Replaces the pad target's whole keymap. Returns the store's refusal, or
    /// nil on success. SIXTEEN LEVELS' one write.
    ///
    /// ⛔ Same one home as `padGridSetOneShot` — `store.setInstrument(id:sampler:)`
    /// — so a spread lands through the identical path a wire `track.setInstrument`
    /// takes, undo included.
    func padGridSetZones(_ zones: [SamplerZone]) -> String? {
        guard let id = activeTrackID, var params = padGridSampler() else {
            return "This track is not playing the built-in Sampler."
        }
        params.zones = zones
        do {
            _ = try store.setInstrument(id: id, sampler: params)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The active track's sampler params, or nil. ⚠️ ONE resolution, shared by
    /// the read and the write above: two copies of this guard chain could drift
    /// into reading one track and writing another.
    private func padGridSampler() -> SamplerParams? {
        guard let id = activeTrackID,
              let track = store.tracks.first(where: { $0.id == id }),
              track.kind == .instrument,
              let instrument = track.instrument,
              instrument.kind == .sampler else { return nil }
        return instrument.resolvedSampler
    }

    /// What the chop card would consume — the selected clip, described.
    func padGridChopSource() -> PadChopSource? {
        guard let clipID = selectedClipID else { return nil }
        for track in store.tracks {
            guard let clip = track.clips.first(where: { $0.id == clipID }) else { continue }
            return PadChopSource(
                clipId: clip.id,
                clipName: clip.name.isEmpty ? "Untitled clip" : clip.name,
                trackId: track.id,
                trackName: track.name,
                isMIDI: clip.isMIDI,
                otherClipsOnTrack: max(0, track.clips.count - 1))
        }
        return nil
    }

    // MARK: - The staging seam

    /// `debug.padGrid {padDown?, padY?, padUp?, bank?, baseNote?, openChop?,
    /// closeChop?, mode?, sensitivity?, divisions?, gridBeats?, maxSlices?,
    /// chopBaseNote?, includeHead?, muteSourceTrack?, triggerMode?, levels?,
    /// levelsFromPad?, exitLevels?, chop?}` — drives the SAME
    /// instances `debug.captureUI` renders, and reports what they hold.
    ///
    /// ⛔ **APP TIER. Deliberately OFF `allCommands` and off MCP**, the
    /// `debug.musicalTyping` / `debug.samplerEditor` precedent: a debug verb that
    /// joined the public table would move the wire count and hand an agent a
    /// second, view-shaped route to capabilities it already reaches properly
    /// (`clip.sliceToSampler` chops; `note.play` sounds a pad; every pad is a
    /// MIDI note and `instrument.describeSampler` already reports the zones).
    /// **This seam exists so a GATE can press a pad, not so an agent can.**
    ///
    /// ⚠️ **NO `padGrid.*` PUBLIC VERB WAS ADDED, AND THAT IS A DECISION.** The
    /// one genuinely new CAPABILITY here — muting the source in the same undo
    /// step as the chop — went onto the existing `clip.sliceToSampler` as an
    /// additive parameter, where an agent already looks. A parallel verb for the
    /// grid would be a second way to say something the wire can already say.
    func padGridDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let raw = params["baseNote"]?.doubleValue {
            musicalTyping.setPadBaseNote(Int(raw))
        }
        if let raw = params["bank"]?.doubleValue {
            padGridSetBank(Int(raw))
        }
        if let raw = params["mode"]?.stringValue {
            guard let mode = SliceBoundaryMode(rawValue: raw) else {
                throw DebugError("'\(raw)' is not a slice mode — one of "
                    + SliceBoundaryMode.allCases.map(\.rawValue).joined(separator: " "))
            }
            padGrid.chop.mode = mode
        }
        if let raw = params["sensitivity"]?.doubleValue { padGrid.chop.sensitivity = raw }
        if let raw = params["divisions"]?.doubleValue { padGrid.chop.divisions = Int(raw) }
        if let raw = params["gridBeats"]?.doubleValue { padGrid.chop.gridBeats = raw }
        if let raw = params["maxSlices"]?.doubleValue { padGrid.chop.maxSlices = Int(raw) }
        if let raw = params["chopBaseNote"]?.doubleValue { padGrid.chop.baseNote = Int(raw) }
        if let raw = params["includeHead"]?.boolValue { padGrid.chop.includeHead = raw }
        if let raw = params["muteSourceTrack"]?.boolValue { padGrid.muteSourceTrack = raw }
        if let raw = params["triggerMode"]?.stringValue {
            guard let value = PadTriggerMode(rawValue: raw) else {
                throw DebugError("'\(raw)' is not a pad trigger mode — one of "
                    + PadTriggerMode.allCases.map(\.rawValue).joined(separator: " "))
            }
            padGrid.setTriggerMode(value)
        }
        if params["openChop"]?.boolValue == true { openChopToPads() }
        if params["closeChop"]?.boolValue == true { closeChopToPads() }
        if let raw = params["padDown"]?.doubleValue {
            // ⚠️ THE MOUSE'S OWN FUNNEL, not `padGrid.padDown` — see
            // `padGridDown`. Driving the model directly would make this seam
            // green on a path no human takes.
            padGridDown(index: Int(raw),
                        normalizedY: params["padY"]?.doubleValue ?? 0.5)
        }
        if params["levels"]?.boolValue == true { padGrid.toggleLevels() }
        if let raw = params["levelsFromPad"]?.doubleValue {
            padGrid.enterLevels(fromPad: Int(raw))
        }
        if params["exitLevels"]?.boolValue == true { padGrid.exitLevels() }
        if params["padUp"]?.boolValue == true { padGridUp() }
        if params["chop"]?.boolValue == true { runChopToPads() }
        return padGridStateResponse()
    }

    func padGridStateResponse() -> JSONValue {
        let pads = padGrid.pads
        return .object([
            // The FACE, not just the mode: a gate asserting "the grid is on
            // screen" must not be satisfied by a mode flag set while the strip
            // is closed.
            "visible": .bool(musicalTyping.isEnabled && musicalTyping.playMode == .pads),
            "playMode": .string(musicalTyping.playMode.rawValue),
            "baseNote": .number(Double(padGrid.baseNote)),
            "bank": .number(Double(padGrid.bank)),
            "bankCount": .number(Double(padGrid.bankCount)),
            "loadedCount": .number(Double(padGrid.loadedCount)),
            "unreachableBelow": .number(Double(padGrid.unreachableBelowCount)),
            "velocity": .number(Double(musicalTyping.velocity)),
            "targetName": padGrid.targetName.map { JSONValue.string($0) } ?? .null,
            "chopOpen": .bool(chopToPadsOpen),
            "chopping": .bool(padGrid.isChopping),
            "blockedBy": padGrid.blockingRefusal.map { JSONValue.string($0.rawValue) } ?? .null,
            // VERBATIM, so a gate can assert the store's two numbers survived.
            "refusal": padGrid.lastRefusal.map { JSONValue.string($0) } ?? .null,
            "chopSource": padGrid.chopSource.map {
                JSONValue.object([
                    "clipId": .string($0.clipId.uuidString),
                    "clipName": .string($0.clipName),
                    "trackName": .string($0.trackName),
                    "isMIDI": .bool($0.isMIDI),
                    "otherClipsOnTrack": .number(Double($0.otherClipsOnTrack)),
                ])
            } ?? .null,
            "muteSourceTrack": .bool(padGrid.muteSourceTrack),
            // ⚠️ null is a REAL value here — "the target is not a sampler", not
            // "false". A gate reading a bool would green on a track with no
            // pads at all.
            "triggerMode": padGrid.triggerMode.map { JSONValue.string($0.rawValue) } ?? .null,
            "triggerModeError": padGrid.lastTriggerModeError.map { JSONValue.string($0) } ?? .null,
            "levelsArming": .bool(padGrid.levelsArming),
            "levels": padGrid.levels.map {
                JSONValue.object([
                    "sourceOrdinal": .number(Double($0.sourceOrdinal)),
                    "base": .number(Double($0.base)),
                    "homeBaseNote": .number(Double($0.homeBaseNote)),
                ])
            } ?? .null,
            "levelsError": padGrid.lastLevelsError.map { JSONValue.string($0) } ?? .null,
            "lastChop": padGrid.lastChop.map {
                JSONValue.object([
                    "sliceCount": .number(Double($0.sliceCount)),
                    "trackName": .string($0.trackName),
                    "createdTrack": .bool($0.createdTrack),
                    "mutedTrackName": $0.mutedTrackName.map { JSONValue.string($0) } ?? .null,
                    "warnings": .array($0.warnings.map { .string($0) }),
                ])
            } ?? .null,
            // ⭐ THE PADS THEMSELVES, as the SURFACE derives them — so a gate
            // reads the app's own projection instead of re-deriving pad→pitch
            // from a second copy of the arithmetic (the `keyLabels` rule, one
            // staging file over).
            "pads": .array(pads.map { pad in
                .object([
                    "index": .number(Double(pad.id)),
                    "pitch": pad.pitch.map { JSONValue.number(Double($0)) } ?? .null,
                    "noteName": .string(pad.noteName),
                    "keyLabel": pad.keyLabel.map { JSONValue.string($0) } ?? .null,
                    "loaded": .bool(pad.isLoaded),
                    "playing": .bool(pad.isPlaying),
                    "slice": pad.sliceOrdinal.map { JSONValue.number(Double($0)) } ?? .null,
                    "levelsSemitones":
                        pad.levelsSemitones.map { JSONValue.number(Double($0)) } ?? .null,
                    "ai": .bool(pad.isAITouched),
                ])
            }),
            "sounding": .array(musicalTyping.soundingPitches.map { .number(Double($0)) }),
            "reportSeq": .number(Double(padGrid.reportSeq)),
        ])
    }
}
