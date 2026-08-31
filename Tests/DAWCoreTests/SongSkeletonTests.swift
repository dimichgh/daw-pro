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
/// m26-p grew the catalog 5 → 14 and added the every-genre end-to-end scaffold
/// leg plus the distinctness pin (a genre that duplicates another's tempo AND
/// roster is one genre with two names).
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

    @Test("catalog has the fourteen v1 genres with unique kebab-case ids")
    func catalogGenreIDsUniqueKebabCase() {
        let names = SongSkeletonCatalog.names
        // ORDER IS WIRE-VISIBLE (the MCP enum mirrors it), so this pins the
        // ORIGINAL five FIRST and the m26-p nine APPENDED — an insertion in the
        // middle would fail here even though the set would still be right.
        #expect(names == ["pop", "house", "hip-hop", "rock", "ballad",
                          "blues", "jazz", "country", "r-and-b", "funk",
                          "metal", "folk", "reggae", "lo-fi"])
        #expect(Set(names).count == names.count)
        let pattern = try! Regex("^[a-z0-9]+(-[a-z0-9]+)*$")
        for name in names {
            #expect((try? pattern.firstMatch(in: name)) != nil, "not kebab-case: \(name)")
        }
    }

    /// m26-o (2026-08-17 field report, N4). Rock's "Rhythm Guitar" and "Lead
    /// Guitar" were the ONLY playable parts in the catalog typed `.audio`.
    /// Audio tracks cannot host an instrument, so an all-MIDI brief had to
    /// REMOVE and RE-ADD them — which changes their ids and silently staled
    /// every id `macro.songSkeleton` had just handed back to the caller.
    ///
    /// Pinned as the CONVENTION rather than as two track names, because the
    /// convention is the thing that was violated: `.audio` is for recorded
    /// material (Vocals, FX, Samples); everything playable is `.instrument`.
    @Test("only recorded-material strips are audio-typed; every playable part is an instrument")
    func playablePartsAreInstrumentTracks() {
        // The allowlist IS the convention, spelled out. m26-p added three names
        // to it (r-and-b's split vocal lanes, lo-fi's vinyl crackle) — every one
        // of them is something a microphone or a record captures, never
        // something a player performs into a MIDI clip.
        let recordedMaterial: Set<String> = [
            "Vocals", "FX", "Samples",
            "Lead Vocal", "Backing Vocals", "Vinyl FX",
        ]
        var audioNames: [String] = []
        for name in SongSkeletonCatalog.names {
            let genre = try! #require(SongSkeletonCatalog.genre(named: name))
            for strip in genre.tracks where strip.kind == .audio {
                audioNames.append(strip.name)
                #expect(recordedMaterial.contains(strip.name),
                        """
                        \(name)/\(strip.name) is audio-typed but is a playable \
                        part — it cannot host an instrument, so an all-MIDI \
                        brief would have to re-add it, staling the id the \
                        macro returned
                        """)
            }
        }
        // ANTI-VACUITY: a catalog with NO audio tracks would pass the loop
        // above without testing anything. Across the 14 genres there are 17
        // audio strips, so 15 is a real floor rather than a restatement.
        // ⚠️ NOT "every genre has one": `jazz` deliberately has ZERO (a combo is
        // played, not tracked), and asserting per-genre would be wrong.
        #expect(audioNames.count >= 15,
                "expected the audio-typed strips to still exist; saw \(audioNames)")
        // And the specific regression: rock's guitars host instruments.
        let rock = try! #require(SongSkeletonCatalog.genre(named: "rock"))
        for guitar in ["Rhythm Guitar", "Lead Guitar"] {
            #expect(rock.tracks.first { $0.name == guitar }?.kind == .instrument)
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

    // MARK: - m34-o: per-instrument defaults

    /// ⭐ THE USER'S RULE, PINNED: *"piano decays, organ sustains and so on
    /// depending on instrument."* Until m34-o a skeleton assigned NO instrument
    /// at all, so every generated part — the one named "Piano", the one named
    /// "Organ", the one named "Drums" — came out as the same saw poly synth.
    ///
    /// This asserts the ASSIGNMENT is coherent (name matches program), not that
    /// a note fades: the fading is measured on rendered audio in
    /// `SamplerGlobalEnvelopeTests` and live on the hosted path. What this
    /// catches is the drift a listening test never would — a roster entry
    /// silently pointing at the wrong program byte.
    @Test("m34-o every skeleton program is a real GM program whose name matches the part")
    func skeletonProgramsAreCoherent() {
        var assigned = 0
        for name in SongSkeletonCatalog.names {
            let genre = try! #require(SongSkeletonCatalog.genre(named: name))
            for strip in genre.tracks {
                guard let program = strip.program else { continue }
                assigned += 1
                // ⛔ A PROGRAM ONLY EVER LANDS ON AN INSTRUMENT TRACK. An audio
                // strip hosts no instrument, so a program on one could only be
                // silently dropped.
                #expect(strip.kind == .instrument,
                        "\(name)/\(strip.name) carries a program but is \(strip.kind.rawValue)-typed")
                #expect(SoundBankConfig.midiValueRange.contains(program.program))
                // The name must come FROM the catalog for that exact address —
                // this is what makes a mislabelled roster entry impossible.
                if program.bankMSB == GMProgramCatalog.melodicBankMSB {
                    #expect(program.name == GMProgramCatalog.name(forProgram: program.program),
                            "\(name)/\(strip.name): name \(program.name) is not GM program \(program.program)")
                } else {
                    #expect(program == GMProgramCatalog.standardDrumKit,
                            "\(name)/\(strip.name): the only non-melodic entry is the drum kit")
                }
            }
        }
        // ANTI-VACUITY: an empty `program` everywhere would satisfy every
        // assertion above without testing anything. 40 is a floor under the
        // 52 assignments the catalog carries, not a restatement of it.
        #expect(assigned >= 40, "expected the skeleton programs to still exist; saw \(assigned)")
    }

    /// ⛔⛔ THE CONTROL THAT KEEPS THE FIX HONEST. m34-o must not turn every
    /// part into something that fades — an organ, a pad and a string ensemble
    /// hold under the pedal and MUST keep holding. These four assignments are
    /// the shipped surface of "the instrument decides": two that fade, two that
    /// do not, pinned by address so a well-meaning retune cannot quietly make
    /// them all pianos.
    ///
    /// ⚠️ DRUMS ARE bankMSB 120, NOT 121. At MSB 121 program 0 is Acoustic
    /// Grand Piano — so a one-byte slip here turns every drum track in the
    /// catalog into a piano, which is exactly the kind of silent wrongness a
    /// name-only assertion would miss.
    @Test("m34-o the decaying parts and the SUSTAINING parts are both pinned")
    func skeletonInstrumentFamiliesArePinned() {
        func program(_ genre: String, _ track: String) -> SoundBankProgram? {
            SongSkeletonCatalog.genre(named: genre)?.tracks.first { $0.name == track }?.program
        }
        // DECAYING — a struck string. Measured live: falls to silence under a
        // held pedal within 15 s.
        #expect(program("ballad", "Piano") == GMProgramCatalog.melodic(0))
        #expect(program("pop", "Keys") == GMProgramCatalog.melodic(0))
        // SUSTAINING — driven/bowed. Measured live: dead flat across 15 s.
        // Holding forever is CORRECT here and breaking it would be a worse
        // defect than the one m34-o fixes.
        #expect(program("blues", "Organ") == GMProgramCatalog.melodic(16))
        #expect(program("reggae", "Organ") == GMProgramCatalog.melodic(16))
        #expect(program("ballad", "Strings") == GMProgramCatalog.melodic(48))
        #expect(program("r-and-b", "Pads") == GMProgramCatalog.melodic(89))
        // Percussion rides the PERCUSSION bank, not program 0 of the melodic one.
        #expect(program("pop", "Drums")?.bankMSB == GMProgramCatalog.percussionBankMSB)
        #expect(program("folk", "Percussion") == GMProgramCatalog.standardDrumKit)
        // And the deliberate nils: a synth part being the built-in synth is
        // instrument-appropriate, not an oversight.
        #expect(program("pop", "Lead") == nil)
        #expect(program("house", "Synth") == nil)
    }

    @Test("every mixer-preset reference resolves against MixerPresetCatalog.v1")
    func everyPresetReferenceResolves() {
        var references = 0
        for genre in SongSkeletonCatalog.v1 {
            for t in genre.tracks {
                guard let presetName = t.mixerPreset else { continue }
                references += 1
                #expect(MixerPresetCatalog.preset(named: presetName) != nil,
                        "\(genre.name)/\(t.name) references unknown preset '\(presetName)'")
            }
        }
        // ANTI-VACUITY: a catalog whose genres referenced NO presets at all
        // would pass the loop above without resolving a single name. 14 genres
        // carry well over 30 references between them.
        #expect(references >= 30,
                "expected the catalog to reference many presets; saw \(references)")
        // And the referenced set must actually SPAN the catalog — a catalog
        // where every genre pointed at one preset would clear the count above.
        var referenced: Set<String> = []
        for genre in SongSkeletonCatalog.v1 {
            for t in genre.tracks { if let p = t.mixerPreset { referenced.insert(p) } }
        }
        #expect(referenced.count >= 10,
                "expected most of the 12 presets to be reachable from a genre; saw \(referenced.sorted())")
    }

    /// m26-p. Every genre in the catalog — not just the handful with bespoke
    /// tests — must scaffold end to end through the STORE: the tempo it
    /// advertises, one track per roster entry plus the Arrangement guide track
    /// LAST, and a session marker at every section's start beat. A catalog entry
    /// that only ever gets read in a `for` loop over its own fields is not
    /// proven to work; this drives the real store method for all of them.
    @Test("every genre scaffolds end-to-end: tempo, roster + Arrangement last, markers at section starts")
    func everyGenreScaffoldsThroughTheStore() throws {
        // ANTI-VACUITY: a shrunken catalog cannot pass by iterating nothing.
        #expect(SongSkeletonCatalog.v1.count >= 14,
                "expected at least the 14 curated genres; saw \(SongSkeletonCatalog.v1.count)")

        for genre in SongSkeletonCatalog.v1 {
            let store = ProjectStore()
            let result = try store.applySongSkeleton(genre: genre.name)

            // Tempo: the genre's own default, in the model AND the result.
            #expect(store.transport.tempoBPM == genre.defaultTempoBPM,
                    "\(genre.name) tempo")
            #expect(result.tempoBPM == genre.defaultTempoBPM)

            // Roster + the guide track, in order, with kinds preserved.
            #expect(store.tracks.count == genre.tracks.count + 1, "\(genre.name) track count")
            for (spec, track) in zip(genre.tracks, store.tracks) {
                #expect(track.name == spec.name, "\(genre.name) roster order")
                #expect(track.kind == spec.kind, "\(genre.name)/\(spec.name) kind")
            }

            // The Arrangement track is LAST and carries the guide clips.
            let arrangement = try #require(store.tracks.last)
            #expect(arrangement.name == "Arrangement", "\(genre.name) guide track is last")
            #expect(arrangement.id == result.arrangementTrackID)
            #expect(arrangement.clips.count == genre.defaultSections.count)

            // Preset chains landed wherever the roster asked for one.
            for spec in genre.tracks {
                let track = try #require(store.tracks.first { $0.name == spec.name })
                guard let presetName = spec.mixerPreset else { continue }
                let preset = try #require(MixerPresetCatalog.preset(named: presetName))
                #expect(track.effects.map(\.kind) == preset.chain.map(\.kind),
                        "\(genre.name)/\(spec.name) missing '\(presetName)' chain")
            }

            // Markers: one per section, at that section's START beat (the
            // running sum), named verbatim — the beat map the macro exists for.
            var cursor = 0.0
            var expectedStarts: [Double] = []
            for section in genre.defaultSections {
                expectedStarts.append(cursor)
                cursor += Double(section.bars) * 4
            }
            #expect(store.markers.count == genre.defaultSections.count,
                    "\(genre.name) marker count")
            #expect(store.markers.map(\.beat) == expectedStarts, "\(genre.name) marker beats")
            #expect(store.markers.map(\.name) == genre.defaultSections.map(\.name),
                    "\(genre.name) marker names")

            // The loop spans the whole arrangement.
            #expect(store.transport.isLoopEnabled)
            #expect(result.loopEnd == cursor, "\(genre.name) loop end")

            // One undoable edit reverts the ENTIRE scaffold.
            #expect(store.undoLabel == "Song Skeleton '\(genre.displayName)'")
            try store.undo()
            #expect(store.tracks.isEmpty, "\(genre.name) did not revert in one undo")
            #expect(store.markers.isEmpty, "\(genre.name) left markers behind")
        }
    }

    /// m26-p. The nine new genres earn their slots by being DISTINCT — the whole
    /// argument for shipping curated defaults instead of telling every caller to
    /// pass a roster override. Two genres with the same tempo and the same
    /// roster are one genre with two names.
    @Test("the catalog's genres are musically distinct, not near-duplicates")
    func genresAreDistinct() throws {
        let genres = SongSkeletonCatalog.v1
        #expect(genres.count >= 14)

        // No two genres share BOTH a tempo and a roster shape.
        for i in genres.indices {
            for j in genres.indices where j > i {
                let a = genres[i], b = genres[j]
                let sameTempo = a.defaultTempoBPM == b.defaultTempoBPM
                let sameRoster = a.tracks.map(\.name) == b.tracks.map(\.name)
                #expect(!(sameTempo && sameRoster),
                        """
                        \(a.name) and \(b.name) share a tempo AND a roster — \
                        that is one genre with two names
                        """)
            }
        }

        // Display names are unique too (they are the undo-label body).
        let displayNames = genres.map(\.displayName)
        #expect(Set(displayNames).count == displayNames.count)

        // The specific shapes m26-p promised, spot-checked so a silent retune
        // of the headline cases fails here.
        let blues = try #require(SongSkeletonCatalog.genre(named: "blues"))
        #expect(blues.defaultTempoBPM == 84)
        // The twelve-bar form is the point of the blues entry: its body
        // sections are 12 bars, not the 8 a pop layout would hand back.
        #expect(blues.defaultSections.contains { $0.name == "Head" && $0.bars == 12 })
        #expect(blues.tracks.first { $0.name == "Bass" }?.mixerPreset == "bass-round",
                "blues must NOT inherit rock's bass-tight — that was the reported bug")

        // jazz is the one genre with no recorded-material strip at all.
        let jazz = try #require(SongSkeletonCatalog.genre(named: "jazz"))
        #expect(jazz.tracks.allSatisfy { $0.kind == .instrument })
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

    // MARK: Roster override (`tracks`)

    /// The `tracks` override replaces the GENRE ROSTER and nothing else. The
    /// guarantee that matters is the negative one: whatever a caller passes,
    /// the "Arrangement" guide track is still appended LAST, still carries one
    /// empty MIDI clip per section, and still drops a marker at every section
    /// start. Producing that beat map is the macro's entire reason to exist, so
    /// an override must not be able to suppress, reorder, or displace it.
    @Test("a custom roster replaces the genre's, in order, with the Arrangement track still last")
    func customRosterOverridesGenreRoster() throws {
        let store = ProjectStore()
        let genre = SongSkeletonCatalog.genre(named: "pop")!
        let roster = [
            SongSkeletonTrack(name: "Sitar", kind: .instrument),
            SongSkeletonTrack(name: "Tabla", kind: .instrument, mixerPreset: "drum-bus-glue"),
            SongSkeletonTrack(name: "Field Recording", kind: .audio),
        ]
        let result = try store.applySongSkeleton(genre: "pop", tracks: roster)

        // The roster is the CALLER'S, in order, and the guide track follows it.
        #expect(store.tracks.count == roster.count + 1)
        #expect(store.tracks.map(\.name) == ["Sitar", "Tabla", "Field Recording", "Arrangement"])
        #expect(store.tracks.map(\.kind) == [.instrument, .instrument, .audio, .instrument])
        // ANTI-VACUITY: pop's own strips are GONE, not merged in alongside.
        for strip in genre.tracks {
            #expect(!store.tracks.contains { $0.name == strip.name },
                    "genre strip '\(strip.name)' survived a roster override")
        }

        // A roster preset lands a real, FRESH chain; no preset means no chain.
        let tabla = try #require(store.tracks.first { $0.name == "Tabla" })
        let preset = try #require(MixerPresetCatalog.preset(named: "drum-bus-glue"))
        #expect(!preset.chain.isEmpty)
        #expect(tabla.effects.map(\.kind) == preset.chain.map(\.kind))
        #expect(Set(tabla.effects.map(\.id)).isDisjoint(with: Set(preset.chain.map(\.id))))
        #expect(store.tracks.first { $0.name == "Sitar" }?.effects.isEmpty == true)

        // The guide track is untouched by the override: last, instrument, one
        // empty MIDI clip per section, and a marker at every section start.
        let arrangement = try #require(store.tracks.last)
        #expect(arrangement.name == "Arrangement")
        #expect(arrangement.kind == .instrument)
        #expect(arrangement.id == result.arrangementTrackID)
        #expect(arrangement.clips.map(\.name) == genre.defaultSections.map(\.name))
        #expect(arrangement.clips.allSatisfy { $0.isMIDI && $0.notes == [] })
        #expect(store.markers.map(\.name) == genre.defaultSections.map(\.name))
        #expect(store.markers.map(\.beat) == arrangement.clips.map(\.startBeat))

        // The result's DOCUMENTED order still holds: roster first, guide last.
        #expect(result.tracks.map(\.name) == ["Sitar", "Tabla", "Field Recording", "Arrangement"])
        #expect(result.tracks.last?.id == result.arrangementTrackID)
        // And the genre still supplies what the caller did NOT override.
        #expect(result.tempoBPM == genre.defaultTempoBPM)
        #expect(store.transport.tempoBPM == genre.defaultTempoBPM)
    }

    /// A caller may name a roster track "Arrangement" — names are not ids, and
    /// this method already tolerates duplicates. It becomes an ordinary roster
    /// track; the REAL guide track is still appended after it.
    @Test("a roster track named Arrangement is allowed — the real guide track still lands last")
    func rosterMayContainATrackNamedArrangement() throws {
        let store = ProjectStore()
        let sections = [SkeletonSection(name: "A", bars: 2), SkeletonSection(name: "B", bars: 4)]
        let result = try store.applySongSkeleton(
            genre: "ballad",
            sections: sections,
            tracks: [SongSkeletonTrack(name: "Arrangement", kind: .audio),
                     SongSkeletonTrack(name: "Cello", kind: .instrument)])

        // BOTH exist — the name is not special-cased and not rejected.
        #expect(store.tracks.filter { $0.name == "Arrangement" }.count == 2)
        #expect(store.tracks.map(\.name) == ["Arrangement", "Cello", "Arrangement"])

        // The caller's is a plain ROSTER track: first, audio-kinded, no clips,
        // and NOT the id the result points at.
        let impostor = try #require(store.tracks.first)
        #expect(impostor.kind == .audio)
        #expect(impostor.clips.isEmpty)
        #expect(impostor.id != result.arrangementTrackID)

        // The real guide track is LAST and carries the whole beat map.
        let guide = try #require(store.tracks.last)
        #expect(guide.id == result.arrangementTrackID)
        #expect(guide.kind == .instrument)
        #expect(guide.clips.map(\.name) == ["A", "B"])
        #expect(guide.clips.map(\.startBeat) == [0, 8])
        #expect(guide.clips.map(\.lengthBeats) == [8, 16])
        #expect(store.markers.map(\.name) == ["A", "B"])
        #expect(store.markers.map(\.beat) == [0, 8])
    }

    @Test("roster + sections + tempo compose — each overrides its own dimension only")
    func rosterSectionsAndTempoCompose() throws {
        let store = ProjectStore()
        let roster = [
            SongSkeletonTrack(name: "Organ", kind: .instrument, mixerPreset: "warm-keys"),
            SongSkeletonTrack(name: "Harmonica", kind: .audio),
        ]
        let sections = [
            SkeletonSection(name: "Head", bars: 4),        // 16 beats
            SkeletonSection(name: "Solo", bars: 12),       // 48 beats
            SkeletonSection(name: "Head Out", bars: 4),    // 16 beats
        ]
        let result = try store.applySongSkeleton(
            genre: "rock", tempoBPM: 96, sections: sections, tracks: roster)

        // Tempo: the caller's, and demonstrably NOT rock's default.
        let rock = SongSkeletonCatalog.genre(named: "rock")!
        #expect(rock.defaultTempoBPM != 96)
        #expect(store.transport.tempoBPM == 96)
        #expect(result.tempoBPM == 96)
        // The genre id still rides the result even though none of rock's own
        // defaults survived all three overrides.
        #expect(result.genre == "rock")
        #expect(store.tracks.map(\.name) == ["Organ", "Harmonica", "Arrangement"])
        #expect(store.tracks.first?.effects.isEmpty == false)

        // Sections drive the guide clips, the markers, and the loop together.
        let arrangement = try #require(store.tracks.last)
        #expect(arrangement.clips.map(\.name) == ["Head", "Solo", "Head Out"])
        #expect(arrangement.clips.map(\.startBeat) == [0, 16, 64])
        #expect(arrangement.clips.map(\.lengthBeats) == [16, 48, 16])
        #expect(result.markers.map(\.beat) == [0, 16, 64])
        #expect(store.transport.loopEndBeat == 80)
        #expect(result.loopEnd == 80)

        // …and the whole composed scaffold is still ONE undo step.
        #expect(store.undoLabel == "Song Skeleton 'Rock'")
        _ = try store.undo()
        #expect(store.tracks.isEmpty)
        #expect(store.markers.isEmpty)
        #expect(store.transport.tempoBPM != 96)
    }

    // MARK: Roster validation

    @Test("a .bus roster track is rejected by field name, and nothing is created")
    func busKindInRosterRejected() throws {
        let store = ProjectStore()
        let depth = store.journal.undoStack.count
        let error = projectError {
            _ = try store.applySongSkeleton(
                genre: "pop", tempoBPM: 155,
                tracks: [SongSkeletonTrack(name: "Keys", kind: .instrument),
                         SongSkeletonTrack(name: "Reverb Bus", kind: .bus)])
        }
        guard case .invalidSongSkeleton(let message) = error else {
            Issue.record("expected invalidSongSkeleton, got \(String(describing: error))"); return
        }
        #expect(message.contains("tracks[1].kind"))
        #expect(message.contains("bus"))

        // The guard runs OUTSIDE the edit body: no tracks, no markers, no undo
        // entry — and the TEMPO did not move either, which is the leg that
        // proves nothing partial was published.
        #expect(store.tracks.isEmpty)
        #expect(store.markers.isEmpty)
        #expect(store.journal.undoStack.count == depth)
        #expect(store.transport.tempoBPM != 155,
                "the tempo moved despite a rejected roster — the guard ran inside the edit")

        // ANTI-VACUITY: the SAME roster with an instrument in that slot lands.
        // What was rejected is the KIND, not the roster.
        _ = try store.applySongSkeleton(
            genre: "pop", tempoBPM: 155,
            tracks: [SongSkeletonTrack(name: "Keys", kind: .instrument),
                     SongSkeletonTrack(name: "Reverb Bus", kind: .instrument)])
        #expect(store.tracks.map(\.name) == ["Keys", "Reverb Bus", "Arrangement"])
        #expect(store.transport.tempoBPM == 155)
    }

    @Test("an unknown roster mixerPreset is rejected with a message listing every valid preset")
    func unknownRosterPresetListsValidNames() throws {
        let store = ProjectStore()
        let error = projectError {
            _ = try store.applySongSkeleton(
                genre: "pop",
                tracks: [SongSkeletonTrack(name: "Lead", kind: .instrument),
                         SongSkeletonTrack(name: "Vox", kind: .audio,
                                           mixerPreset: "vocal-presense")])
        }
        guard case .invalidSongSkeleton(let message) = error else {
            Issue.record("expected invalidSongSkeleton, got \(String(describing: error))"); return
        }
        #expect(message.contains("tracks[1].mixerPreset"))
        #expect(message.contains("vocal-presense"))
        // One round trip teaches the WHOLE vocabulary (the genre-not-found
        // precedent), so a misspelling never costs a second call to discover.
        #expect(!MixerPresetCatalog.names.isEmpty)
        for name in MixerPresetCatalog.names {
            #expect(message.contains(name), "error omits preset '\(name)': \(message)")
        }
        #expect(store.tracks.isEmpty)

        // ANTI-VACUITY: the correctly spelled preset lands its chain, so the
        // rejection was the SPELLING and not the shape of the call.
        _ = try store.applySongSkeleton(
            genre: "pop",
            tracks: [SongSkeletonTrack(name: "Lead", kind: .instrument),
                     SongSkeletonTrack(name: "Vox", kind: .audio,
                                       mixerPreset: "vocal-presence")])
        let vox = try #require(store.tracks.first { $0.name == "Vox" })
        let preset = try #require(MixerPresetCatalog.preset(named: "vocal-presence"))
        #expect(!vox.effects.isEmpty)
        #expect(vox.effects.map(\.kind) == preset.chain.map(\.kind))
    }

    @Test("roster count and name bounds are enforced, and change nothing")
    func rosterCountAndNameBoundsEnforced() throws {
        let store = ProjectStore()

        // An empty roster is a rejection, not "use the genre's" — an explicit
        // empty array is a different statement from an omitted param.
        let empty = projectError { _ = try store.applySongSkeleton(genre: "pop", tracks: []) }
        guard case .invalidSongSkeleton(let emptyMessage) = empty else {
            Issue.record("expected invalidSongSkeleton, got \(String(describing: empty))"); return
        }
        #expect(emptyMessage.contains("tracks"))

        // 25 > the 1...24 ceiling.
        let tooMany = (0..<25).map { SongSkeletonTrack(name: "T\($0)", kind: .instrument) }
        let over = projectError { _ = try store.applySongSkeleton(genre: "pop", tracks: tooMany) }
        guard case .invalidSongSkeleton(let overMessage) = over else {
            Issue.record("expected invalidSongSkeleton, got \(String(describing: over))"); return
        }
        #expect(overMessage.contains("24"))

        // A blank name is rejected by index, like a blank section name.
        let blank = projectError {
            _ = try store.applySongSkeleton(
                genre: "pop",
                tracks: [SongSkeletonTrack(name: "Drums", kind: .instrument),
                         SongSkeletonTrack(name: "   ", kind: .audio)])
        }
        guard case .invalidSongSkeleton(let blankMessage) = blank else {
            Issue.record("expected invalidSongSkeleton, got \(String(describing: blank))"); return
        }
        #expect(blankMessage.contains("tracks[1].name"))
        #expect(store.tracks.isEmpty)

        // ANTI-VACUITY: exactly 24 — the ceiling itself — is accepted, so the
        // bound is a range and not a blanket refusal.
        let atCeiling = (0..<24).map { SongSkeletonTrack(name: "T\($0)", kind: .instrument) }
        _ = try store.applySongSkeleton(genre: "pop", tracks: atCeiling)
        #expect(store.tracks.count == 25)          // 24 roster + Arrangement
        #expect(store.tracks.last?.name == "Arrangement")
    }

    // MARK: Validation

    @Test("unknown genre throws, lists every valid name, and changes nothing")
    func unknownGenreListsNames() {
        let store = ProjectStore()
        let depth = store.journal.undoStack.count
        // ⚠️ THIS FIXTURE USED TO BE "jazz", WHICH m26-p MADE REAL — the test
        // then asserted a not-found for a genre that exists. A negative fixture
        // must be a string the catalog will never plausibly adopt, not merely
        // one it does not have YET.
        let error = projectError { _ = try store.applySongSkeleton(genre: "not-a-real-genre") }
        guard case .songSkeletonGenreNotFound(let message) = error else {
            Issue.record("expected songSkeletonGenreNotFound, got \(String(describing: error))"); return
        }
        #expect(message.contains("not-a-real-genre"))
        // The fixture is genuinely absent — the guard above proves the error
        // fired, this proves it fired for the right reason.
        #expect(SongSkeletonCatalog.genre(named: "not-a-real-genre") == nil)
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
