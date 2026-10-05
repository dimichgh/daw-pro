import Foundation
import Testing
@testable import DAWCore

// m39-tpl-2 — `ProjectStore.applyTemplate(_:dryRun:)`, §8.6's table
// (docs/design/2026-09-27-multi-instrument-templates.md): one undo step, a
// refusal changes nothing, a dry run changes nothing, twice adds twice,
// existing tracks untouched, master/tempo/markers/loop untouched, recording.
//
// "Changes nothing" is asserted on BYTES: the whole project document, encoded
// with sorted keys (its `savedAt` stamp pinned, the only field that is a clock),
// plus `canUndo`, the undo stack's depth and the engine's calls.
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite `SongSkeletonTests`, not a
// new suite: the `MainActorOccupancySiteTests` cap on `@MainActor` suites
// (393 of 394 used, measured 2026-10-05). Helpers carry a `tpl2` prefix.

extension SongSkeletonTests {
    // MARK: - Helpers

    func tpl2Bytes(_ store: ProjectStore) throws -> Data {
        var document = store.buildAutosaveDocument(includeChats: false)
        document.savedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    func tpl2Encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// A song that already has things a template must not touch: a bus and an
    /// audio track (sending into it, with a compressor), a master limiter, a
    /// tempo, a marker and a loop. The bus is called "Drums", like the
    /// template's drums.
    func tpl2BusyStore(engine: FakeEngine? = nil) throws -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia()
        let bus = store.addTrack(name: "Drums", kind: .bus)
        let vocal = store.addTrack(name: "Vocal", kind: .audio)
        _ = try store.addSend(toTrack: vocal.id, busID: bus.id, level: 0.4)
        _ = try store.addEffect(toTrack: vocal.id, kind: .compressor)
        _ = try store.addMasterEffect(kind: .limiter)
        try store.setTempo(97)
        _ = store.addMarker(name: "Verse", beat: 8)
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 16)
        if let engine { store.engine = engine }
        return store
    }

    func tpl2LofiChill() throws -> TrackSetTemplate {
        try TemplateBuilderTests.lofiChill()
    }

    /// Two plain tracks, no routing: legal mid-take.
    func tpl2Plain() -> TrackSetTemplate {
        TemplateBuilderTests.template([TemplateBuilderTests.track("pad", .instrument),
                                       TemplateBuilderTests.track("fx")],
                                      name: "Plain Pair")
    }

    func tpl2Refusal(_ body: () throws -> Void) -> (any Error)? {
        do { try body(); return nil } catch { return error }
    }

    // MARK: - One undo step

    @Test("m39-tpl-2: apply is ONE undo step: undo restores the bytes before, redo the bytes after")
    func tpl2ApplyIsOneUndoStep() throws {
        let engine = FakeEngine()
        let store = try tpl2BusyStore(engine: engine)
        let template = try tpl2LofiChill()
        let before = try tpl2Bytes(store)
        let depth = store.journal.undoStack.count
        engine.clearCalls()

        let result = try store.applyTemplate(template)

        #expect(result.applied)
        #expect(result.undoLabel == "Add Template 'Lo-Fi Chill'")
        #expect(store.undoLabel == "Add Template 'Lo-Fi Chill'")
        #expect(store.journal.undoStack.count == depth + 1)
        #expect(store.tracks.count == 2 + 6)
        #expect(Array(store.tracks.suffix(6).map(\.id)) == result.tracks.compactMap(\.id))
        #expect(result.tracks.map(\.key) == ["drums", "bass", "keys", "vinyl", "duck", "room"])
        #expect(result.keyToTrackID["duck"] == store.tracks[2 + 4].id)
        // The engine is told once, inside the edit, with the whole song.
        #expect(engine.calls == [.tracksDidChange(count: 8)])
        let after = try tpl2Bytes(store)
        #expect(after != before)

        #expect(try store.undo() == "Add Template 'Lo-Fi Chill'")
        #expect(try tpl2Bytes(store) == before)
        #expect(store.journal.undoStack.count == depth)
        _ = try store.redo()
        #expect(try tpl2Bytes(store) == after)
    }

    // MARK: - A refusal changes nothing

    @Test("m39-tpl-2: every refusal kind leaves the bytes, canUndo, the undo depth and the engine untouched — and a dry run refuses the same")
    func tpl2RefusalChangesNothing() throws {
        typealias T = TemplateBuilderTests
        let missingBank = T.template([T.track("strings", .instrument) {
            $0.instrument = InstrumentDescriptor(
                kind: .soundBank,
                soundBank: SoundBankConfig(source: .file(path: "/nowhere/tpl2-missing.sf2"),
                                           program: 48))
        }], name: "Missing Bank")
        let missingSample = T.template([T.track("kit", .instrument) {
            $0.instrument = InstrumentDescriptor(kind: .sampler, sampler: SamplerParams(zones: [
                SamplerZone(audioFileURL: URL(fileURLWithPath: "/nowhere/tpl2-missing-kick.wav")),
            ]))
        }], name: "Missing Sample")
        let badReference = T.template([T.track("a") { $0.output = "verb" }], name: "Bad Reference")
        let rows: [(String, TrackSetTemplate, Bool, String)] = [
            ("a builder refusal", badReference, false, "tracks[0].output"),
            ("a missing sound-bank file", missingBank, false, "tracks[0].instrument.soundBank"),
            ("a missing sampler zone file", missingSample, false, "tracks[0].instrument.sampler"),
            ("routing while recording", try tpl2LofiChill(), true, ""),
        ]
        for (label, template, recording, path) in rows {
            for dryRun in [false, true] {
                let engine = FakeEngine()
                let busy = try tpl2BusyStore()
                var transport = busy.transport
                transport.isRecording = recording
                // A fresh store over the same song: canUndo starts FALSE, so an
                // undo entry left by a refusal would flip it.
                let store = ProjectStore(tracks: busy.tracks, transport: transport)
                store.media = FakeMedia()
                store.engine = engine
                let bytes = try tpl2Bytes(store)
                let canUndo = store.canUndo
                let depth = store.journal.undoStack.count
                let error = tpl2Refusal { _ = try store.applyTemplate(template, dryRun: dryRun) }
                let tag = "\(label)\(dryRun ? " (dry run)" : "")"
                #expect(error != nil, "\(tag): applied, but must be refused")
                if let refusal = error as? TemplateRefusal {
                    #expect(refusal.path == path, "\(tag): \(refusal)")
                } else if recording {
                    guard case ProjectError.transportBusy(let message)? = error as? ProjectError else {
                        Issue.record("\(tag): expected transportBusy, got \(String(describing: error))")
                        continue
                    }
                    #expect(message.contains("while recording"), "\(tag): \(message)")
                } else {
                    Issue.record("\(tag): expected a TemplateRefusal, got \(String(describing: error))")
                }
                #expect(try tpl2Bytes(store) == bytes, "\(tag): the project changed")
                #expect(store.canUndo == canUndo, "\(tag): canUndo moved")
                #expect(store.journal.undoStack.count == depth, "\(tag): an undo entry was recorded")
                #expect(engine.calls.isEmpty, "\(tag): the engine was told \(engine.calls)")
            }
        }
    }

    // MARK: - A dry run changes nothing

    @Test("m39-tpl-2: a dry run changes nothing and replies exactly what the apply then does, minus ids")
    func tpl2DryRunChangesNothing() throws {
        let engine = FakeEngine()
        let store = try tpl2BusyStore(engine: engine)
        let template = try tpl2LofiChill()
        let bytes = try tpl2Bytes(store)
        let canUndo = store.canUndo
        let depth = store.journal.undoStack.count
        engine.clearCalls()

        let dry = try store.applyTemplate(template, dryRun: true)

        #expect(dry.applied == false)
        #expect(dry.tracks.allSatisfy { $0.id == nil })
        #expect(dry.keyToTrackID.isEmpty)
        #expect(try tpl2Bytes(store) == bytes)
        #expect(store.canUndo == canUndo)
        #expect(store.journal.undoStack.count == depth)
        #expect(engine.calls.isEmpty)

        let real = try store.applyTemplate(template)
        var stripped = real
        stripped.applied = false
        stripped.tracks = real.tracks.map { .init(key: $0.key, id: nil, name: $0.name, kind: $0.kind) }
        #expect(dry == stripped)
        // Control: the comparison can fail — the real reply carries ids.
        #expect(dry != real)
    }

    // MARK: - Twice adds twice

    @Test("m39-tpl-2: applying twice adds the band twice: two undo steps, two disjoint id sets, names repeat")
    func tpl2TwiceAddsTwice() throws {
        let store = try tpl2BusyStore()
        let template = try tpl2LofiChill()
        let depth = store.journal.undoStack.count
        let first = try store.applyTemplate(template)
        let afterFirst = try tpl2Bytes(store)
        let second = try store.applyTemplate(template)   // well inside the 800 ms window

        #expect(store.journal.undoStack.count == depth + 2, "the two applies merged into one undo step")
        #expect(store.tracks.count == 2 + 6 + 6)
        let firstIDs = Set(first.tracks.compactMap(\.id))
        let secondIDs = Set(second.tracks.compactMap(\.id))
        #expect(firstIDs.count == 6 && secondIDs.count == 6)
        #expect(firstIDs.isDisjoint(with: secondIDs))
        for key in first.keyToTrackID.keys {
            #expect(first.keyToTrackID[key] != second.keyToTrackID[key], "\(key)")
        }
        // Every effect, send and modulation id is fresh too.
        let effectIDs = store.tracks.flatMap { $0.effects.map(\.id) }
        #expect(Set(effectIDs).count == effectIDs.count)
        // The second band is wired to ITS OWN buses, never the first band's.
        let secondKeys = store.tracks.first { $0.id == second.keyToTrackID["keys"] }
        #expect(secondKeys?.outputBusID == second.keyToTrackID["duck"])
        // Every name now repeats, and the reply says so.
        #expect(second.duplicateTrackNames == ["Drums", "Bass", "Keys", "Vinyl FX", "Keys Duck",
                                               "Tape Room"])
        // One undo takes away exactly the second band.
        _ = try store.undo()
        #expect(try tpl2Bytes(store) == afterFirst)
    }

    // MARK: - Existing tracks untouched

    @Test("m39-tpl-2: every track that was already in the song encodes byte-identically after the apply")
    func tpl2ExistingTracksUntouched() throws {
        let store = try tpl2BusyStore()
        // Give the existing audio track modulation too, so a stray write would show.
        let vocal = try #require(store.tracks.first { $0.name == "Vocal" })
        let (source, _) = try store.addModulationSource(on: .track(vocal.id), kind: .lfo)
        _ = try store.addModulationRoute(on: .track(vocal.id), sourceID: source.id,
                                         target: .volume, depth: 0.2)
        let before = try store.tracks.map { try tpl2Encoded($0) }
        let ids = store.tracks.map(\.id)

        _ = try store.applyTemplate(try tpl2LofiChill())

        #expect(Array(store.tracks.prefix(ids.count).map(\.id)) == ids)
        let after = try store.tracks.prefix(ids.count).map { try tpl2Encoded($0) }
        #expect(after == before)
    }

    // MARK: - Master, tempo, markers, loop untouched

    @Test("m39-tpl-2: the master chain, tempo, markers and loop are untouched")
    func tpl2MasterTempoMarkersLoopUntouched() throws {
        let store = try tpl2BusyStore()
        let master = try tpl2Encoded(store.masterEffects)
        let masterVolume = store.masterVolume
        let tempo = store.transport.tempoBPM
        let markers = try tpl2Encoded(store.markers)
        let loop = (store.transport.isLoopEnabled, store.transport.loopStartBeat,
                    store.transport.loopEndBeat)
        let masterModulation = try tpl2Encoded([store.masterModulationSources.count,
                                                store.masterModulationRoutes.count])

        _ = try store.applyTemplate(try tpl2LofiChill())

        #expect(try tpl2Encoded(store.masterEffects) == master)
        #expect(store.masterVolume == masterVolume)
        #expect(store.transport.tempoBPM == tempo)
        #expect(try tpl2Encoded(store.markers) == markers)
        #expect(store.transport.isLoopEnabled == loop.0)
        #expect(store.transport.loopStartBeat == loop.1)
        #expect(store.transport.loopEndBeat == loop.2)
        #expect(try tpl2Encoded([store.masterModulationSources.count,
                                 store.masterModulationRoutes.count]) == masterModulation)
        // Control: the busy song really has each of them, so "unchanged" means something.
        #expect(!store.masterEffects.isEmpty && !store.markers.isEmpty && tempo == 97 && loop.0)
    }

    // MARK: - Recording

    @Test("m39-tpl-2: while recording, a template with routing is refused and a plain one applies")
    func tpl2RecordingRefusesOnlyRouting() throws {
        var transport = TransportState()
        transport.isRecording = true
        let store = ProjectStore(tracks: try tpl2BusyStore().tracks, transport: transport)
        let bytes = try tpl2Bytes(store)
        let routed = try tpl2LofiChill()
        let error = tpl2Refusal { _ = try store.applyTemplate(routed) }
        guard case ProjectError.transportBusy(let message)? = error as? ProjectError else {
            Issue.record("expected transportBusy, got \(String(describing: error))")
            return
        }
        #expect(message.contains("while recording"))
        #expect(try tpl2Bytes(store) == bytes)
        #expect(store.canUndo == false)

        let plain = tpl2Plain()
        let result = try store.applyTemplate(plain)
        #expect(result.applied && result.hasRouting == false)
        #expect(store.tracks.count == 2 + 2)
        #expect(store.undoLabel == "Add Template 'Plain Pair'")
        #expect(store.transport.isRecording)
    }

    @Test("m39-tpl-2: the same rule on a real take (FakeEngine, an armed track, record())")
    func tpl2RecordingRealTakeLeg() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let take = store.addTrack(kind: .audio)
        try store.setTrackArm(id: take.id, armed: true)
        try store.record()
        try #require(store.transport.isRecording)
        let count = store.tracks.count
        engine.clearCalls()

        let routed = try tpl2LofiChill()
        let error = tpl2Refusal { _ = try store.applyTemplate(routed) }
        #expect(error is ProjectError, "\(String(describing: error))")
        #expect(store.tracks.count == count)
        #expect(engine.calls.isEmpty)

        _ = try store.applyTemplate(tpl2Plain())
        #expect(store.tracks.count == count + 2)
        #expect(engine.calls == [.tracksDidChange(count: count + 2)])
    }

    // MARK: - Names, plug-ins, the chain cap

    @Test("m39-tpl-2: a repeated name is reported, never renamed")
    func tpl2DuplicateNamesAreReportedNotRenamed() throws {
        let store = try tpl2BusyStore()   // already has a bus called "Drums"
        let result = try store.applyTemplate(try tpl2LofiChill())
        #expect(result.duplicateTrackNames == ["Drums"])
        #expect(store.tracks.filter { $0.name == "Drums" }.count == 2)
        let warning = result.warnings.first { $0.code == .duplicateTrackNames }
        #expect(warning?.path == "tracks[0].name")
        #expect(warning?.message.contains("2 tracks called 'Drums'") == true)
        // Control: a song without a "Drums" reports no duplicate.
        let empty = ProjectStore()
        #expect(try empty.applyTemplate(try tpl2LofiChill()).duplicateTrackNames.isEmpty)
    }

    @Test("m39-tpl-2: a plug-in this Mac does not have is a warning, never a refusal; the track keeps it")
    func tpl2MissingAudioUnitWarns() throws {
        let synth = AudioUnitConfig(component: AudioUnitComponentID(subType: "tpl2",
                                                                    manufacturer: "none"))
        let template = TemplateBuilderTests.template([TemplateBuilderTests.track("au", .instrument) {
            $0.instrument = InstrumentDescriptor(kind: .audioUnit, audioUnit: synth)
        }], name: "Missing Plug-in")
        let store = ProjectStore()
        let result = try store.applyTemplate(template)
        #expect(result.applied)
        #expect(result.warnings.map(\.code) == [.audioUnitMissing])
        #expect(result.warnings.first?.path == "tracks[0].instrument.audioUnit")
        #expect(store.tracks.first?.instrument?.audioUnit == synth)
    }

    @Test("m39-tpl-2: the builder's 16-effect cap IS the store's (the builder cannot read the main-actor constant)")
    func tpl2ChainCapIsTheStores() {
        #expect(TemplateBuilder.maxEffectsPerChain == ProjectStore.maxEffectsPerChain)
    }
}
