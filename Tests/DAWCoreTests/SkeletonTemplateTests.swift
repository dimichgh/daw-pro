import Foundation
import Testing
@testable import DAWCore

// m39-tpl-3 — `applySongSkeleton(template:)` and its dry run, `planSongSkeleton`
// (docs/design/2026-09-27-multi-instrument-templates.md §5.5, §6.2).
//
// With a template, the roster IS the template's tracks and the form (tempo, sections, markers, the "Arrangement"
// track, the loop) is the genre's; `template` with `tracks` is refused; the template's files and the recording guard
// are checked before the edit, exactly as `applyTemplate` checks them. The dry run is the apply stopped before the
// edit: it changes nothing, and what it plans is what the apply then adds (compared on the tracks' whole encoded
// form with ids normalised, so a field the dry run forgot would show).
//
// Without a template the roster goes through the same builder; `SkeletonGoldenTests` pins that byte for byte.
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite `SongSkeletonTests`, not a new suite (the Leg C cap, 393 of
// 394). Helpers carry a `tpl3` prefix; `tpl2BusyStore`, `tpl2Bytes` and `tpl2LofiChill` are TPL-2's (one home).

extension SongSkeletonTests {
    // MARK: - Helpers

    /// The tracks as JSON with sorted keys, every UUID replaced by first appearance — so two runs that minted
    /// different ids compare equal exactly when everything else, the references between tracks included, is equal.
    func tpl3NormalisedTracks(_ tracks: [Track]) throws -> String {
        Self.tpl3Normalize(String(decoding: try tpl2Encoded(tracks), as: UTF8.self)).text
    }

    func tpl3Store(recording: Bool, engine: FakeEngine) throws -> ProjectStore {
        let busy = try tpl2BusyStore()
        var transport = busy.transport
        transport.isRecording = recording
        let store = ProjectStore(tracks: busy.tracks, transport: transport)
        store.media = FakeMedia()
        store.engine = engine
        return store
    }

    // MARK: - Refusals change nothing

    @Test("m39-tpl-3: a template with a tracks list, a missing template file, and a routed template while recording are each refused before anything changes — by the apply and by its dry run")
    func tpl3SkeletonTemplateRefusalsChangeNothing() throws {
        typealias T = TemplateBuilderTests
        let missingBank = T.template([T.track("strings", .instrument) {
            $0.instrument = InstrumentDescriptor(
                kind: .soundBank,
                soundBank: SoundBankConfig(source: .file(path: "/nowhere/tpl3-missing.sf2"), program: 48))
        }], name: "Missing Bank")
        let roster = [SongSkeletonTrack(name: "Guitar", kind: .instrument)]
        let rows: [(label: String, template: TrackSetTemplate, tracks: [SongSkeletonTrack]?, recording: Bool)] = [
            ("a template with a tracks list", try tpl2LofiChill(), roster, false),
            ("a missing sound-bank file", missingBank, nil, false),
            ("a routed template while recording", try tpl2LofiChill(), nil, true),
        ]
        for row in rows {
            for dryRun in [false, true] {
                let engine = FakeEngine()
                let store = try tpl3Store(recording: row.recording, engine: engine)
                let bytes = try tpl2Bytes(store)
                let canUndo = store.canUndo
                let depth = store.journal.undoStack.count
                let tag = "\(row.label)\(dryRun ? " (dry run)" : "")"
                let error = tpl2Refusal {
                    if dryRun {
                        _ = try store.planSongSkeleton(genre: "lo-fi", tracks: row.tracks,
                                                       template: row.template)
                    } else {
                        _ = try store.applySongSkeleton(genre: "lo-fi", tracks: row.tracks,
                                                        template: row.template)
                    }
                }
                switch row.label {
                case "a template with a tracks list":
                    guard case ProjectError.invalidSongSkeleton(let message)? = error as? ProjectError else {
                        Issue.record("\(tag): expected invalidSongSkeleton, got \(String(describing: error))")
                        continue
                    }
                    #expect(message == "Use either a template or your own track list, not both.", "\(tag)")
                case "a missing sound-bank file":
                    let refusal = error as? TemplateRefusal
                    #expect(refusal?.path == "tracks[0].instrument.soundBank",
                            "\(tag): \(String(describing: error))")
                default:
                    guard case ProjectError.transportBusy(let message)? = error as? ProjectError else {
                        Issue.record("\(tag): expected transportBusy, got \(String(describing: error))")
                        continue
                    }
                    #expect(message.contains("while recording"), "\(tag): \(message)")
                }
                #expect(try tpl2Bytes(store) == bytes, "\(tag): the project changed")
                #expect(store.canUndo == canUndo, "\(tag): canUndo moved")
                #expect(store.journal.undoStack.count == depth, "\(tag): an undo entry was recorded")
                #expect(engine.calls.isEmpty, "\(tag): the engine was told \(engine.calls)")
            }
        }
    }

    // MARK: - A template's tracks, the genre's form

    @Test("m39-tpl-3: with a template, the roster is the template's tracks, wired; the form is the genre's; one undo step called 'Song Skeleton '<Genre>' with '<Template>''")
    func tpl3SkeletonWithATemplate() throws {
        let engine = FakeEngine()
        let store = try tpl3Store(recording: false, engine: engine)
        let existing = store.tracks.count
        let before = try tpl2Bytes(store)
        let depth = store.journal.undoStack.count
        engine.clearCalls()
        let genre = try #require(SongSkeletonCatalog.genre(named: "lo-fi"))

        let result = try store.applySongSkeleton(genre: "lo-fi", template: try tpl2LofiChill())

        let added = Array(store.tracks.suffix(from: existing))
        #expect(added.map(\.name) == ["Drums", "Bass", "Keys", "Vinyl FX", "Keys Duck", "Tape Room",
                                      "Arrangement"])
        #expect(added.map(\.kind) == [.instrument, .instrument, .instrument, .audio, .bus, .bus, .instrument])
        #expect(result.tracks.map(\.id) == added.map(\.id))
        #expect(result.arrangementTrackID == added.last?.id)
        // The template's keys, each to the track it became.
        let keys = ["drums", "bass", "keys", "vinyl", "duck", "room"]
        #expect(Set(result.templateKeys.keys) == Set(keys))
        for (index, key) in keys.enumerated() {
            #expect(result.templateKeys[key] == added[index].id, "key \(key)")
        }
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        // The routing came with it: Keys plays into Keys Duck and sends to Tape Room; the duck's compressor
        // listens to Drums; Drums sends to Tape Room; the drum machine is in the General MIDI layout.
        let (drums, keysTrack, duck, room) = (added[0], added[2], added[4], added[5])
        #expect(keysTrack.outputBusID == duck.id)
        #expect(keysTrack.sends.map(\.destinationBusID) == [room.id])
        #expect(drums.sends.map(\.destinationBusID) == [room.id])
        #expect(duck.effects.first?.sidechainSourceTrackID == drums.id)
        #expect(drums.instrument?.drumKit?.noteLayout == .gm)
        #expect(keysTrack.modulationRoutes.count == 1)
        // The form is the genre's.
        #expect(result.tempoBPM == genre.defaultTempoBPM)
        #expect(store.transport.tempoBPM == genre.defaultTempoBPM)
        #expect(result.markers.map(\.name) == genre.defaultSections.map(\.name))
        #expect(added.last?.clips.map(\.name) == genre.defaultSections.map(\.name))
        #expect(store.transport.isLoopEnabled)
        #expect(result.loopEnd == Double(genre.defaultSections.reduce(0) { $0 + $1.bars }) * 4)
        // One edit, told to the engine once.
        #expect(store.undoLabel == "Song Skeleton 'Lo-Fi' with 'Lo-Fi Chill'")
        #expect(store.journal.undoStack.count == depth + 1)
        let trackCalls = engine.calls.filter { call in
            if case .tracksDidChange = call { return true }
            return false
        }
        #expect(trackCalls == [.tracksDidChange(count: existing + 7)])
        _ = try store.undo()
        #expect(try tpl2Bytes(store) == before, "one undo did not restore the song")
        // Without a template the label is unchanged.
        let plain = try store.planSongSkeleton(genre: "lo-fi")
        #expect(plain.undoLabel == "Song Skeleton 'Lo-Fi'")
        #expect(plain.templateKeys.isEmpty && plain.warnings.isEmpty && !plain.hasRouting)
    }

    // MARK: - The dry run is the apply, stopped before the edit

    @Test("m39-tpl-3: for every genre (and an override, and a template) the dry run changes nothing and plans exactly what the apply adds")
    func tpl3DryRunIsTheApplyStoppedBeforeTheEdit() throws {
        var rows: [(genre: String, tracks: [SongSkeletonTrack]?, template: TrackSetTemplate?)] =
            SongSkeletonCatalog.names.map { (genre: $0, tracks: nil, template: nil) }
        rows.append((genre: "pop", tracks: Self.tpl3OverrideRoster, template: nil))
        rows.append((genre: "lo-fi", tracks: nil, template: try tpl2LofiChill()))
        #expect(rows.count == 16)
        for row in rows {
            let tag = "\(row.genre)\(row.tracks == nil ? "" : " + tracks")\(row.template == nil ? "" : " + template")"
            // The dry run changes nothing.
            let engine = FakeEngine()
            let store = try tpl3Store(recording: false, engine: engine)
            let bytes = try tpl2Bytes(store)
            let depth = store.journal.undoStack.count
            let canUndo = store.canUndo
            let plan = try store.planSongSkeleton(genre: row.genre, tracks: row.tracks, template: row.template)
            #expect(try tpl2Bytes(store) == bytes, "\(tag): the dry run changed the project")
            #expect(store.journal.undoStack.count == depth && store.canUndo == canUndo, "\(tag): undo moved")
            #expect(engine.calls.isEmpty, "\(tag): the dry run told the engine \(engine.calls)")
            #expect(plan.arrangementTrack?.name == "Arrangement", "\(tag)")

            // The apply adds exactly what the dry run planned.
            let applied = try tpl3Store(recording: false, engine: FakeEngine())
            let existing = applied.tracks.count
            let result = try applied.applySongSkeleton(genre: row.genre, tracks: row.tracks,
                                                       template: row.template)
            let added = Array(applied.tracks.suffix(from: existing))
            #expect(try tpl3NormalisedTracks(added) == tpl3NormalisedTracks(plan.tracks),
                    "\(tag): the apply added something the dry run did not plan")
            #expect(plan.undoLabel == applied.undoLabel, "\(tag)")
            #expect(plan.tempoBPM == result.tempoBPM && plan.tempoBPM == applied.transport.tempoBPM, "\(tag)")
            #expect(plan.markers.map(\.name) == result.markers.map(\.name), "\(tag)")
            #expect(plan.markers.map(\.beat) == result.markers.map(\.beat), "\(tag)")
            #expect(plan.sectionClips == result.sectionClips, "\(tag)")
            #expect(plan.loopStart == result.loopStart && plan.loopEnd == result.loopEnd, "\(tag)")
            #expect(Set(plan.templateKeys.keys) == Set(result.templateKeys.keys), "\(tag)")
            #expect(plan.warnings == result.warnings, "\(tag)")
            #expect(plan.hasRouting == (row.template != nil), "\(tag)")
        }
    }

    // MARK: - D3: no drum or bass part plays the default synth

    /// D3 (design §5.5, a defect fix flagged for the CHANGELOG): rock's "Drums" and "Bass" were the only drum and
    /// bass parts in the catalog with no instrument, so they played the built-in Poly Synth — a saw wave where a
    /// drum kit belongs, and silent-looking drums in every render of a General MIDI beat. Every other band genre
    /// gives its drums the General MIDI kit and its bass a bass program. Pinned as the RULE, so a new genre cannot
    /// reintroduce it either.
    @Test("m39-tpl-3 D3: every drum part has the General MIDI kit and every bass part a bass program")
    func tpl3D3EveryDrumAndBassPartHasAnInstrument() {
        var checked = 0
        for genre in SongSkeletonCatalog.v1 {
            for strip in genre.tracks where strip.kind == .instrument {
                let name = strip.name.lowercased()
                if name.contains("drums") || name.contains("percussion") {
                    checked += 1
                    #expect(strip.program == GMProgramCatalog.standardDrumKit,
                            "\(genre.name)/\(strip.name) has no drum kit: it plays the Poly Synth")
                } else if name.contains("bass") {
                    checked += 1
                    // General MIDI's bass family is programs 32-39.
                    #expect(strip.program.map { (32...39).contains($0.program) } == true,
                            "\(genre.name)/\(strip.name) has no bass program: it plays the Poly Synth")
                }
            }
        }
        // ANTI-VACUITY: 13 genres have drums or percussion and all 14 have a bass part.
        #expect(checked >= 27, "expected the drum and bass parts to still exist; checked \(checked)")
    }
}

// MARK: - m39-tpl-f8: the skeleton's tempo change refuses exactly when `setTempo` does

// Design §5.5, finding F-8: the skeleton sets the tempo, so it refuses while recording and on a multi-segment tempo
// map, with `setTempo`'s OWN error (same case, same sentence). The reference is always `setTempo` itself, called on a
// twin of the store under test, so a test cannot pass by comparing the skeleton's sentence to a copy of it.
// Helpers carry a `tplf` prefix.
extension SongSkeletonTests {
    /// What `setTempo` throws on a twin of `store` (same tracks, same transport), or nil if it would succeed. The
    /// twin keeps `store` itself untouched when the call is allowed.
    func tplfSetTempoRefusal(_ store: ProjectStore) -> ProjectError? {
        let twin = ProjectStore(tracks: store.tracks, transport: store.transport)
        do { try twin.setTempo(100); return nil } catch { return error as? ProjectError }
    }

    /// The error's case, by name, so two errors can be compared without `ProjectError` being `Equatable`.
    static func tplfCase(_ error: (any Error)?) -> String {
        switch error as? ProjectError {
        case .transportBusy?: "transportBusy"
        case .tempoMapMultiSegment?: "tempoMapMultiSegment"
        case nil: error.map { "not a ProjectError: \($0)" } ?? "no error"
        case let other?: "other: \(other)"
        }
    }

    static func tplfTwoSegmentMap() throws -> TempoMap {
        try TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 8, bpm: 90)])
    }

    /// Runs the skeleton (or its dry run) and checks it refused with `setTempo`'s own error, changing nothing.
    func tplfExpectSetTempoRefusal(_ store: ProjectStore, engine: FakeEngine, template: TrackSetTemplate?,
                                   dryRun: Bool, expectedCase: String, tag: String) throws {
        let want = tplfSetTempoRefusal(store)
        // ANTI-VACUITY: `setTempo` really refuses here, with the case this row is about.
        #expect(Self.tplfCase(want) == expectedCase, "\(tag): setTempo itself: \(String(describing: want))")
        let bytes = try tpl2Bytes(store)
        let depth = store.journal.undoStack.count
        let canUndo = store.canUndo
        let got = tpl2Refusal {
            if dryRun {
                _ = try store.planSongSkeleton(genre: "pop", template: template)
            } else {
                _ = try store.applySongSkeleton(genre: "pop", template: template)
            }
        }
        #expect(Self.tplfCase(got) == expectedCase, "\(tag): \(String(describing: got))")
        #expect((got as? LocalizedError)?.errorDescription == want?.errorDescription,
                "\(tag): not setTempo's sentence: \(String(describing: got))")
        #expect(try tpl2Bytes(store) == bytes, "\(tag): the project changed")
        #expect(store.journal.undoStack.count == depth, "\(tag): an undo entry was recorded")
        #expect(store.canUndo == canUndo, "\(tag): canUndo moved")
        #expect(engine.calls.isEmpty, "\(tag): the engine was told \(engine.calls)")
    }

    @Test("m39-tpl-f8: mid-take, the skeleton refuses with setTempo's own sentence — with no template and with a plain one, by the apply and by its dry run — and nothing changes")
    func tplfSkeletonRefusedMidTake() throws {
        // The plain template has no routing, so the template's own recording guard does not fire: the refusal can
        // only come from the tempo guard.
        let plain = tpl2Plain()
        #expect(try TemplateBuilder.plan(plain).hasRouting == false)
        for (label, template) in [("no template", nil), ("a plain template", plain)] as [(String, TrackSetTemplate?)] {
            for dryRun in [false, true] {
                let engine = FakeEngine()
                let store = try tpl3Store(recording: true, engine: engine)
                #expect(store.transport.tempoMapOverride == nil, "the map must not be what refuses here")
                try tplfExpectSetTempoRefusal(store, engine: engine, template: template, dryRun: dryRun,
                                              expectedCase: "transportBusy",
                                              tag: "\(label)\(dryRun ? " (dry run)" : "")")
            }
        }
        // The sentence the user reads, once, so a change to it is a decision someone makes on purpose.
        let store = try tpl3Store(recording: true, engine: FakeEngine())
        #expect(tplfSetTempoRefusal(store)?.errorDescription == "cannot change tempo while recording — stop first")
    }

    @Test("m39-tpl-f8: on a multi-segment tempo map, the skeleton refuses with setTempo's own error — by the apply and by its dry run — and the map survives")
    func tplfSkeletonRefusedOnMultiSegmentMap() throws {
        let map = try Self.tplfTwoSegmentMap()
        for (label, template) in [("no template", nil), ("a plain template", tpl2Plain())] as [(String, TrackSetTemplate?)] {
            for dryRun in [false, true] {
                let store = ProjectStore()
                store.media = FakeMedia()
                try store.setTempoMap(map)
                let engine = FakeEngine()
                store.engine = engine
                #expect(!store.transport.isRecording, "recording must not be what refuses here")
                try tplfExpectSetTempoRefusal(store, engine: engine, template: template, dryRun: dryRun,
                                              expectedCase: "tempoMapMultiSegment",
                                              tag: "\(label)\(dryRun ? " (dry run)" : "")")
                #expect(store.transport.tempoMapOverride == map, "the authored map was touched")
                #expect(store.transport.tempoBPM == 120)
            }
        }
    }

    @Test("m39-tpl-f8: idle on a single-segment map the skeleton is NOT refused — a fresh song, a map that went multi and back, and a meter map with one tempo, all of which setTempo also allows")
    func tplfSkeletonAllowedOnSingleSegmentMap() throws {
        let pop = try #require(SongSkeletonCatalog.genre(named: "pop"))
        let rows: [(label: String, prepare: (ProjectStore) throws -> Void)] = [
            ("a fresh song", { _ in }),
            ("a map that went multi-segment and back", { store in
                try store.setTempoMap(try Self.tplfTwoSegmentMap())
                try store.setTempoMap(TempoMap(constantBPM: 132))
            }),
            ("one tempo with a multi-change meter map", { store in
                try store.setTempoMap(TempoMap(constantBPM: 132), meterMap: try MeterMap(changes: [
                    .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                    .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4),
                ]))
                #expect(store.transport.meterMapOverride != nil, "the meter row must really carry a meter map")
            }),
        ]
        for row in rows {
            for dryRun in [false, true] {
                let tag = "\(row.label)\(dryRun ? " (dry run)" : "")"
                let store = ProjectStore()
                store.media = FakeMedia()
                try row.prepare(store)
                #expect(store.transport.tempoMapOverride == nil, "\(tag): the tempo map is not single-segment")
                // ANTI-VACUITY: setTempo allows this state; the skeleton must too.
                #expect(tplfSetTempoRefusal(store) == nil, "\(tag): setTempo itself refuses here")
                if dryRun {
                    let plan = try store.planSongSkeleton(genre: "pop")
                    #expect(plan.tempoBPM == pop.defaultTempoBPM, "\(tag)")
                } else {
                    let result = try store.applySongSkeleton(genre: "pop")
                    #expect(result.tempoBPM == pop.defaultTempoBPM, "\(tag)")
                    #expect(store.transport.tempoBPM == pop.defaultTempoBPM, "\(tag): the tempo did not land")
                    #expect(store.undoLabel == "Song Skeleton 'Pop'", "\(tag)")
                }
            }
        }
    }
}
