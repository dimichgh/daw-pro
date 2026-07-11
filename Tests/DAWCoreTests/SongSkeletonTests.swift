import Foundation
import Testing
@testable import DAWCore

/// Headless coverage for M7 (macro-c) song skeletons: catalog integrity (unique
/// kebab genre ids, every mixer-preset reference resolves against
/// `MixerPresetCatalog.v1`, non-empty rosters + sections), apply-on-empty
/// (tempo, tracks, preset chains, contiguous guide clips, loop region),
/// additive apply on a non-empty project, custom tempo + custom sections
/// overriding defaults, validation rejections, the ONE-undo-step guarantee, and
/// result ids resolving to real model objects.
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
}
