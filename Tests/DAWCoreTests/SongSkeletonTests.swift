import Foundation
import Testing
@testable import DAWCore

/// Headless coverage for M7 (macro-c) song skeletons: catalog integrity (unique
/// kebab genre ids, every mixer-preset reference resolves against
/// `MixerPresetCatalog.v1`, non-empty rosters + sections), apply-on-empty
/// (tempo, tracks, preset chains, contiguous guide clips, loop region),
/// additive apply on a non-empty project, custom tempo + custom sections
/// overriding defaults, validation rejections, the ONE-undo-step guarantee, and
/// result ids resolving to real model objects. Also the SECTION MARKERS the
/// scaffold drops: one per section at its start beat, named verbatim (repeats
/// NOT auto-numbered), additive over markers that already existed and merged
/// into the store's beat order, reverting in that same single undo step.
@MainActor
@Suite("Song skeleton — ProjectStore")
struct SongSkeletonTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func track(_ store: ProjectStore, _ id: UUID) -> Track? {
        store.tracks.first(where: { $0.id == id })
    }

    // MARK: Catalog integrity

    @Test("catalog has the five v1 genres with unique kebab-case ids")
    func catalogGenreIDsUniqueKebabCase() {
        let names = SongSkeletonCatalog.names
        #expect(names == ["pop", "house", "hip-hop", "rock", "ballad"])
        #expect(Set(names).count == names.count)
        let pattern = try! Regex("^[a-z0-9]+(-[a-z0-9]+)*$")
        for name in names {
            #expect((try? pattern.firstMatch(in: name)) != nil, "not kebab-case: \(name)")
        }
    }

    @Test("every genre has a display name, a roster, and sections — all well-formed")
    func genreMetadataWellFormed() {
        for genre in SongSkeletonCatalog.v1 {
            #expect(!genre.displayName.isEmpty, "\(genre.name) has an empty display name")
            #expect(TransportState.tempoRange.contains(genre.defaultTempoBPM),
                    "\(genre.name) default tempo out of range")
            #expect(!genre.tracks.isEmpty, "\(genre.name) has no tracks")
            #expect(!genre.defaultSections.isEmpty, "\(genre.name) has no sections")
            // v1 rosters use only instrument/audio — never a bus.
            for t in genre.tracks {
                #expect(!t.name.isEmpty, "\(genre.name) has an unnamed track")
                #expect(t.kind == .instrument || t.kind == .audio,
                        "\(genre.name)/\(t.name) is a \(t.kind.rawValue) — v1 rosters use only instrument/audio")
            }
            // Sections respect the same bounds the store validates.
            #expect((1...16).contains(genre.defaultSections.count))
            for s in genre.defaultSections {
                #expect(!s.name.isEmpty, "\(genre.name) has an unnamed section")
                #expect(s.name.count <= 40)
                #expect((1...64).contains(s.bars), "\(genre.name)/\(s.name) bars out of range")
            }
        }
    }

    @Test("every mixer-preset reference resolves against MixerPresetCatalog.v1")
    func everyPresetReferenceResolves() {
        for genre in SongSkeletonCatalog.v1 {
            for t in genre.tracks {
                guard let presetName = t.mixerPreset else { continue }
                #expect(MixerPresetCatalog.preset(named: presetName) != nil,
                        "\(genre.name)/\(t.name) references unknown preset '\(presetName)'")
            }
        }
    }

    // MARK: Apply on an empty project

    @Test("apply on an empty project scaffolds tempo, tracks, guide clips, and loop")
    func applyOnEmptyProject() throws {
        let store = ProjectStore()
        let genre = SongSkeletonCatalog.genre(named: "pop")!
        let result = try store.applySongSkeleton(genre: "pop")

        // Tempo is the genre default.
        #expect(store.transport.tempoBPM == genre.defaultTempoBPM)
        #expect(result.tempoBPM == genre.defaultTempoBPM)

        // Track count: the roster + the Arrangement guide track.
        #expect(store.tracks.count == genre.tracks.count + 1)

        // Roster tracks: names + kinds in order.
        for (spec, track) in zip(genre.tracks, store.tracks) {
            #expect(track.name == spec.name)
            #expect(track.kind == spec.kind)
        }

        // The Arrangement guide track is LAST, an instrument track.
        let arrangement = store.tracks.last!
        #expect(arrangement.name == "Arrangement")
        #expect(arrangement.kind == .instrument)
        #expect(arrangement.id == result.arrangementTrackID)

        // Preset chains landed where specified (kinds match the fresh chain).
        for spec in genre.tracks {
            let track = store.tracks.first(where: { $0.name == spec.name })!
            if let presetName = spec.mixerPreset {
                let preset = MixerPresetCatalog.preset(named: presetName)!
                #expect(track.effects.map(\.kind) == preset.chain.map(\.kind),
                        "\(spec.name) missing '\(presetName)' chain")
                // Fresh ids — never the template ids.
                #expect(Set(track.effects.map(\.id)).isDisjoint(with: Set(preset.chain.map(\.id))))
            } else {
                #expect(track.effects.isEmpty, "\(spec.name) should have no preset chain")
            }
        }

        // Contiguous empty MIDI guide clips: names, spans, and running starts.
        var cursor = 0.0
        #expect(arrangement.clips.count == genre.defaultSections.count)
        for (section, clip) in zip(genre.defaultSections, arrangement.clips) {
            #expect(clip.name == section.name)
            #expect(clip.startBeat == cursor)
            #expect(clip.lengthBeats == Double(section.bars) * 4)
            #expect(clip.isMIDI)              // MIDI clip …
            #expect(clip.notes == [])         // … with no notes.
            #expect(clip.audioFileURL == nil)
            cursor += Double(section.bars) * 4
        }

        // Loop region: enabled, 0 → total arrangement length (pop = 208 beats).
        #expect(cursor == 208)
        #expect(store.transport.isLoopEnabled)
        #expect(store.transport.loopStartBeat == 0)
        #expect(store.transport.loopEndBeat == cursor)
        #expect(result.loopStart == 0)
        #expect(result.loopEnd == cursor)

        // Undo label carries the display name.
        #expect(store.undoLabel == "Song Skeleton 'Pop'")
    }

    @Test("result ids resolve to real tracks and section clips")
    func resultIDsAreReal() throws {
        let store = ProjectStore()
        let result = try store.applySongSkeleton(genre: "house")

        // Every result track id resolves and its name matches.
        for ref in result.tracks {
            let track = self.track(store, ref.id)
            #expect(track != nil, "result track id \(ref.id) not found")
            #expect(track?.name == ref.name)
        }
        // The Arrangement id is the LAST result track and the store's last track.
        #expect(result.tracks.last?.id == result.arrangementTrackID)
        #expect(store.tracks.last?.id == result.arrangementTrackID)

        // Section clip refs match the arrangement track's clips exactly.
        let arrangement = track(store, result.arrangementTrackID)!
        #expect(arrangement.clips.count == result.sectionClips.count)
        for (clip, ref) in zip(arrangement.clips, result.sectionClips) {
            #expect(clip.name == ref.name)
            #expect(clip.startBeat == ref.startBeat)
            #expect(clip.lengthBeats == ref.lengthBeats)
        }
    }

    // MARK: Section markers

    @Test("a marker lands at every section start, named VERBATIM (default layout)")
    func markersAtEverySectionStart() throws {
        let store = ProjectStore()
        let genre = SongSkeletonCatalog.genre(named: "pop")!
        let result = try store.applySongSkeleton(genre: "pop")

        // One marker per section — not one per bar, and no extra "End" marker.
        #expect(store.markers.count == genre.defaultSections.count)

        // Names are the section names VERBATIM, in order, and the beats are the
        // running section starts (pop: 0, 16, 48, 80, 112, 144, 160, 192).
        var expectedBeats: [Double] = []
        var cursor = 0.0
        for section in genre.defaultSections {
            expectedBeats.append(cursor)
            cursor += Double(section.bars) * 4
        }
        #expect(store.markers.map(\.name) == genre.defaultSections.map(\.name))
        #expect(store.markers.map(\.beat) == expectedBeats)
        #expect(expectedBeats == [0, 16, 48, 80, 112, 144, 160, 192])

        // Repeated section names are NOT auto-numbered — the markers mirror the
        // guide clips exactly (pop repeats "Verse" twice and "Chorus" three
        // times). Disambiguation is by beat, not by a fabricated suffix.
        #expect(store.markers.filter { $0.name == "Verse" }.count == 2)
        #expect(store.markers.filter { $0.name == "Chorus" }.count == 3)
        #expect(!store.markers.contains { $0.name.contains("1") || $0.name.contains("2") })

        // Markers and guide clips agree, name-for-name and beat-for-startBeat.
        let arrangement = track(store, result.arrangementTrackID)!
        #expect(store.markers.map(\.name) == arrangement.clips.map(\.name))
        #expect(store.markers.map(\.beat) == arrangement.clips.map(\.startBeat))
    }

    @Test("custom sections drop markers at the CUSTOM section starts")
    func markersFollowCustomSections() throws {
        let store = ProjectStore()
        let sections = [
            SkeletonSection(name: "A", bars: 2),   // 8 beats  → marker at 0
            SkeletonSection(name: "B", bars: 3),   // 12 beats → marker at 8
            SkeletonSection(name: "A", bars: 1),   // 4 beats  → marker at 20 (repeat)
        ]
        let result = try store.applySongSkeleton(genre: "pop", sections: sections)

        #expect(store.markers.map(\.name) == ["A", "B", "A"])
        #expect(store.markers.map(\.beat) == [0, 8, 20])
        #expect(result.markers.map(\.name) == ["A", "B", "A"])
        #expect(result.markers.map(\.beat) == [0, 8, 20])
        // The genre default layout did NOT leak in (pop would be 8 markers).
        #expect(store.markers.count == 3)
    }

    @Test("the returned markers match what the store holds, ids included")
    func resultMarkersMatchStore() throws {
        let store = ProjectStore()
        let result = try store.applySongSkeleton(genre: "house")

        // On a fresh project the store's array IS the result set, element-wise.
        #expect(result.markers.count == store.markers.count)
        for (ref, marker) in zip(result.markers, store.markers) {
            #expect(ref.id == marker.id)
            #expect(ref.name == marker.name)
            #expect(ref.beat == marker.beat)
        }
        // Ids are real and distinct — each resolves to exactly one marker.
        #expect(Set(result.markers.map(\.id)).count == result.markers.count)
        for ref in result.markers {
            #expect(store.markers.filter { $0.id == ref.id }.count == 1,
                    "result marker id \(ref.id) does not resolve")
        }
        // The markers mirror the section clips 1:1 (same names, beat == start).
        #expect(result.markers.map(\.name) == result.sectionClips.map(\.name))
        #expect(result.markers.map(\.beat) == result.sectionClips.map(\.startBeat))
    }

    @Test("markers are ADDITIVE — pre-existing ones survive and the merge stays beat-sorted")
    func markersAreAdditiveAndSorted() throws {
        let store = ProjectStore()
        // Pre-existing markers: one BEFORE the whole scaffold's set and one in
        // the MIDDLE of it (pop section starts are 0,16,48,80,112,144,160,192,
        // so beat 100 lands between "Verse" @80 and "Chorus" @112). An
        // append-without-sort would leave beat 100 sitting after beat 192.
        let early = store.addMarker(name: "My Cue", beat: 4)
        let middle = store.addMarker(name: "Fix This Bit", beat: 100)
        let priorIDs = Set([early.id, middle.id])

        let result = try store.applySongSkeleton(genre: "pop")

        // Both pre-existing markers survive, unchanged.
        let survivingEarly = store.markers.first { $0.id == early.id }
        let survivingMiddle = store.markers.first { $0.id == middle.id }
        #expect(survivingEarly == early)
        #expect(survivingMiddle == middle)

        // Count is the merge: 2 pre-existing + 8 sections.
        #expect(store.markers.count == 2 + 8)
        #expect(result.markers.count == 8)
        #expect(Set(result.markers.map(\.id)).isDisjoint(with: priorIDs))

        // The MERGED array is in the store's canonical beat order.
        let beats = store.markers.map(\.beat)
        #expect(beats == beats.sorted())
        #expect(beats == [0, 4, 16, 48, 80, 100, 112, 144, 160, 192])
        // …and the pre-existing middle marker really is interleaved, not appended.
        let middleIndex = store.markers.firstIndex { $0.id == middle.id }
        #expect(middleIndex == 5)
        #expect(store.markers.last?.name == "Outro")

        // Every ref the result returned resolves in the merged array.
        for ref in result.markers {
            let stored = store.markers.first { $0.id == ref.id }
            #expect(stored?.name == ref.name)
            #expect(stored?.beat == ref.beat)
        }
    }

    @Test("a pre-existing marker exactly ON a section start is KEPT and sorts FIRST")
    func preExistingMarkerOnASectionStartTieBreaks() throws {
        let store = ProjectStore()
        // Beat 16 is pop's "Verse" section start — a genuine TIE with a marker
        // the scaffold is about to mint. This pins the documented rule: no
        // dedupe (both survive), and the merge order `markers + new` plus the
        // shared funnel's index tiebreak puts the INCUMBENT first.
        let incumbent = store.addMarker(name: "Take 3 starts here", beat: 16)

        let result = try store.applySongSkeleton(genre: "pop")

        let atSixteen = store.markers.filter { $0.beat == 16 }
        #expect(atSixteen.count == 2, "the tie must be KEPT, not deduped")
        #expect(atSixteen.first?.id == incumbent.id, "the pre-existing marker sorts FIRST")
        #expect(atSixteen.last?.name == "Verse")
        // The scaffold's own "Verse" @16 is the one the result reports.
        #expect(result.markers.contains { $0.id == atSixteen.last?.id })
        #expect(!result.markers.contains { $0.id == incumbent.id })
        // Still globally beat-sorted.
        #expect(store.markers.map(\.beat) == store.markers.map(\.beat).sorted())
    }

    @Test("calling the macro twice lands BOTH marker sets — names are not ids")
    func markersFromTwoCallsCoexist() throws {
        let store = ProjectStore()
        let first = try store.applySongSkeleton(genre: "ballad")
        let second = try store.applySongSkeleton(genre: "ballad")
        #expect(store.markers.count == first.markers.count + second.markers.count)
        #expect(Set(first.markers.map(\.id)).isDisjoint(with: Set(second.markers.map(\.id))))
        // Two markers now share each beat AND each name (the documented,
        // deliberate consequence of verbatim naming + additive apply).
        #expect(store.markers.filter { $0.beat == 0 }.count == 2)
        #expect(store.markers.map(\.beat) == store.markers.map(\.beat).sorted())
    }

    // MARK: Additive on a non-empty project

    @Test("apply is additive — existing tracks and clips are untouched")
    func applyIsAdditive() throws {
        let store = ProjectStore()
        let existing1 = store.addTrack(name: "My Guitar", kind: .audio)
        let existing2 = store.addTrack(name: "My Synth", kind: .instrument)
        let before1 = track(store, existing1.id)!
        let before2 = track(store, existing2.id)!
        let priorCount = store.tracks.count

        let result = try store.applySongSkeleton(genre: "rock")

        // Existing tracks are byte-identical and still at the front.
        #expect(track(store, existing1.id) == before1)
        #expect(track(store, existing2.id) == before2)
        #expect(store.tracks[0].id == existing1.id)
        #expect(store.tracks[1].id == existing2.id)

        // The skeleton's tracks were appended after them.
        let genre = SongSkeletonCatalog.genre(named: "rock")!
        #expect(store.tracks.count == priorCount + genre.tracks.count + 1)
        #expect(result.tracks.count == genre.tracks.count + 1)
    }

    @Test("apply twice adds a SECOND Arrangement track — names are not unique ids")
    func applyTwiceAddsSecondArrangement() throws {
        let store = ProjectStore()
        let first = try store.applySongSkeleton(genre: "ballad")
        let second = try store.applySongSkeleton(genre: "ballad")
        #expect(first.arrangementTrackID != second.arrangementTrackID)
        #expect(store.tracks.filter { $0.name == "Arrangement" }.count == 2)
    }

    // MARK: Overrides

    @Test("custom tempo overrides the genre default")
    func customTempoOverridesDefault() throws {
        let store = ProjectStore()
        let result = try store.applySongSkeleton(genre: "pop", tempoBPM: 100)
        #expect(store.transport.tempoBPM == 100)
        #expect(result.tempoBPM == 100)
    }

    @Test("custom sections override the genre default layout")
    func customSectionsOverrideDefault() throws {
        let store = ProjectStore()
        let sections = [
            SkeletonSection(name: "A", bars: 2),   // 8 beats
            SkeletonSection(name: "B", bars: 3),   // 12 beats
        ]
        let result = try store.applySongSkeleton(genre: "pop", sections: sections)

        let arrangement = track(store, result.arrangementTrackID)!
        #expect(arrangement.clips.map(\.name) == ["A", "B"])
        #expect(arrangement.clips.map(\.startBeat) == [0, 8])
        #expect(arrangement.clips.map(\.lengthBeats) == [8, 12])
        // Loop spans the custom arrangement (8 + 12 = 20 beats).
        #expect(store.transport.loopEndBeat == 20)
        #expect(result.loopEnd == 20)
        // The roster is still the pop roster (only the sections changed).
        let genre = SongSkeletonCatalog.genre(named: "pop")!
        #expect(store.tracks.count == genre.tracks.count + 1)
    }

    // MARK: Validation

    @Test("unknown genre throws, lists every valid name, and changes nothing")
    func unknownGenreListsNames() {
        let store = ProjectStore()
        let depth = store.journal.undoStack.count
        let error = projectError { _ = try store.applySongSkeleton(genre: "jazz") }
        guard case .songSkeletonGenreNotFound(let message) = error else {
            Issue.record("expected songSkeletonGenreNotFound, got \(String(describing: error))"); return
        }
        for name in SongSkeletonCatalog.names {
            #expect(message.contains(name), "error omits '\(name)': \(message)")
        }
        #expect(store.tracks.isEmpty)
        #expect(store.journal.undoStack.count == depth)
    }

    @Test("out-of-range tempo throws a field-named error and changes nothing")
    func badTempoRejected() {
        let store = ProjectStore()
        for badTempo in [10.0, 500.0] {
            let error = projectError { _ = try store.applySongSkeleton(genre: "pop", tempoBPM: badTempo) }
            guard case .invalidSongSkeleton(let message) = error else {
                Issue.record("expected invalidSongSkeleton for \(badTempo), got \(String(describing: error))"); return
            }
            #expect(message.contains("tempoBPM"))
        }
        #expect(store.tracks.isEmpty)
    }

    @Test("bad section bar count throws a field-named error")
    func badBarsRejected() {
        let store = ProjectStore()
        for badBars in [0, 65] {
            let error = projectError {
                _ = try store.applySongSkeleton(
                    genre: "pop",
                    sections: [SkeletonSection(name: "Intro", bars: 4),
                               SkeletonSection(name: "Bad", bars: badBars)])
            }
            guard case .invalidSongSkeleton(let message) = error else {
                Issue.record("expected invalidSongSkeleton for bars=\(badBars), got \(String(describing: error))"); return
            }
            #expect(message.contains("sections[1].bars"))
        }
        #expect(store.tracks.isEmpty)
    }

    @Test("empty section name throws a field-named error")
    func emptySectionNameRejected() {
        let store = ProjectStore()
        let error = projectError {
            _ = try store.applySongSkeleton(
                genre: "pop",
                sections: [SkeletonSection(name: "   ", bars: 4)])
        }
        guard case .invalidSongSkeleton(let message) = error else {
            Issue.record("expected invalidSongSkeleton, got \(String(describing: error))"); return
        }
        #expect(message.contains("sections[0].name"))
    }

    @Test("too many sections throws and changes nothing")
    func tooManySectionsRejected() {
        let store = ProjectStore()
        let seventeen = (0..<17).map { SkeletonSection(name: "S\($0)", bars: 1) }
        let error = projectError { _ = try store.applySongSkeleton(genre: "pop", sections: seventeen) }
        guard case .invalidSongSkeleton(let message) = error else {
            Issue.record("expected invalidSongSkeleton, got \(String(describing: error))"); return
        }
        #expect(message.contains("16"))
        #expect(store.tracks.isEmpty)
    }

    // MARK: One-undo-step guarantee

    @Test("the entire scaffold is ONE undo step that restores the prior project")
    func oneUndoStepRevertsEverything() throws {
        let store = ProjectStore()
        // Start from a non-trivial project so we prove a full revert, not just
        // back-to-empty.
        _ = store.addTrack(name: "Existing", kind: .audio)
        let tracksBefore = store.tracks
        let transportBefore = store.transport
        let depthBefore = store.journal.undoStack.count

        _ = try store.applySongSkeleton(genre: "hip-hop", tempoBPM: 88)

        // Exactly ONE new undo entry for the whole scaffold.
        #expect(store.journal.undoStack.count == depthBefore + 1)
        #expect(store.tracks.count > tracksBefore.count)
        #expect(store.transport.tempoBPM == 88)
        #expect(store.transport.isLoopEnabled)

        // A single undo reverts the ENTIRE scaffold at once.
        _ = try store.undo()
        #expect(store.tracks == tracksBefore)
        #expect(store.transport.tempoBPM == transportBefore.tempoBPM)
        #expect(store.transport.isLoopEnabled == transportBefore.isLoopEnabled)
        #expect(store.transport.loopStartBeat == transportBefore.loopStartBeat)
        #expect(store.transport.loopEndBeat == transportBefore.loopEndBeat)
        #expect(store.journal.undoStack.count == depthBefore)
    }

    @Test("the section markers revert in that SAME single undo step")
    func markersRevertInTheSameSingleUndoStep() throws {
        let store = ProjectStore()
        // A pre-existing marker so we prove a revert to the PRIOR beat map, not
        // just back-to-empty.
        let existing = store.addMarker(name: "My Cue", beat: 100)
        let markersBefore = store.markers
        let depthBefore = store.journal.undoStack.count

        _ = try store.applySongSkeleton(genre: "hip-hop", tempoBPM: 88)

        // The scaffold landed its markers, and the WHOLE scaffold is still ONE
        // undo entry — the per-marker `addMarker` (which journals its own edit)
        // is deliberately not used.
        #expect(store.markers.count == markersBefore.count + 6)   // hip-hop = 6 sections
        #expect(store.journal.undoStack.count == depthBefore + 1)

        // One undo takes the beat map back exactly, tracks and all.
        _ = try store.undo()
        #expect(store.markers == markersBefore)
        #expect(store.markers.map(\.id) == [existing.id])
        #expect(store.tracks.isEmpty)
        #expect(store.journal.undoStack.count == depthBefore)

        // …and redo brings the whole scaffold, markers included, back.
        _ = try store.redo()
        #expect(store.markers.count == markersBefore.count + 6)
        #expect(store.markers.map(\.beat) == store.markers.map(\.beat).sorted())
    }
}
