import Foundation
import Testing
@testable import DAWCore

/// M5 iv-c stem plan (spec §2, §7): the master-input partition, the request
/// rejections, the solo transform shapes (dry track stems, bus stems with the
/// silent dummy), and the "NN Name.wav" sanitize/collision policy — all pure,
/// headless, engine-free.
@Suite("Stem plan — master-input partition (M5 iv-c)")
struct StemPlanTests {

    // MARK: - Fixtures

    private func session() -> (tracks: [Track], drums: Track, gtr: Track,
                               crunch: Track, keys: Track) {
        let crunch = Track(name: "Crunch", kind: .bus,
                           effects: [EffectDescriptor(kind: .saturator)])
        let drums = Track(name: "Drums", kind: .audio)
        let gtr = Track(name: "Gtr", kind: .audio, outputBusID: crunch.id)
        let keys = Track(name: "Keys", kind: .instrument)
        return ([drums, gtr, crunch, keys], drums, gtr, crunch, keys)
    }

    // MARK: - Partition

    @Test("Partition = direct tracks + buses, track-list order; bus-routed track absent")
    func partitionMembershipAndOrder() throws {
        let s = session()
        let plan = try StemPlan.descriptors(tracks: s.tracks, including: nil)

        #expect(plan.map(\.id) == [s.drums.id, s.crunch.id, s.keys.id])
        #expect(plan.map(\.kind) == [.track, .bus, .track])
        #expect(plan.map(\.name) == ["Drums", "Crunch", "Keys"])
        // NN prefix: 2-digit, 1-based, partition order.
        #expect(plan.map(\.fileName) == ["01 Drums.wav", "02 Crunch.wav", "03 Keys.wav"])
        // The bus-routed source track has no stem of its own.
        #expect(!plan.contains { $0.id == s.gtr.id })
    }

    @Test("trackIds filter selects a subset, still in partition order, 1-based over the selection")
    func trackIdsFilter() throws {
        let s = session()
        // Request out of partition order on purpose.
        let plan = try StemPlan.descriptors(tracks: s.tracks,
                                            including: [s.keys.id, s.crunch.id])
        #expect(plan.map(\.id) == [s.crunch.id, s.keys.id])
        #expect(plan.map(\.fileName) == ["01 Crunch.wav", "02 Keys.wav"])
    }

    @Test("Empty explicit selection → empty plan (store maps it to nothingToRender)")
    func emptySelection() throws {
        let s = session()
        let plan = try StemPlan.descriptors(tracks: s.tracks, including: [])
        #expect(plan.isEmpty)
    }

    // MARK: - Rejections

    @Test("Unknown id rejects trackNotFound")
    func unknownIdRejects() {
        let s = session()
        let stray = UUID()
        do {
            _ = try StemPlan.descriptors(tracks: s.tracks, including: [stray])
            Issue.record("expected trackNotFound")
        } catch let ProjectError.trackNotFound(id) {
            #expect(id == stray)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Bus-routed source track rejects stemNotMasterInput, message verbatim")
    func busRoutedTrackRejects() {
        let s = session()
        do {
            _ = try StemPlan.descriptors(tracks: s.tracks, including: [s.gtr.id])
            Issue.record("expected stemNotMasterInput")
        } catch let error as ProjectError {
            guard case .stemNotMasterInput = error else {
                Issue.record("unexpected ProjectError: \(error)")
                return
            }
            // Exact wording is contract (control protocol + MCP surface it
            // verbatim in iv-d).
            #expect(error.errorDescription ==
                "'Gtr' is routed to bus 'Crunch' — its signal is part of that bus's stem")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - The one home for the rule (m23-m3c)

    @Test("m23-m3c: isMasterInput is true for buses and direct tracks, false for a bus-routed one")
    func isMasterInputPerKindAndRouting() {
        // Every KIND, direct to master.
        #expect(Track(name: "Keys", kind: .instrument).isMasterInput)
        #expect(Track(name: "Vox", kind: .audio).isMasterInput)
        #expect(Track(name: "Verb", kind: .bus).isMasterInput,
                "A BUS IS A STEM — stems are not 'instrument tracks'")

        let verb = Track(name: "Verb", kind: .bus)
        // Routing is what decides it, not the kind.
        #expect(Track(name: "Bass", kind: .audio, outputBusID: verb.id).isMasterInput == false)
        #expect(Track(name: "Lead", kind: .instrument, outputBusID: verb.id).isMasterInput == false)
        // A bus stays a master input whatever `outputBusID` says: buses output
        // to master in v0, and the field is never meaningful on one.
        #expect(Track(name: "Verb 2", kind: .bus, outputBusID: verb.id).isMasterInput)

        // A send does NOT cost a track its own stem — its send contribution
        // lives in the destination bus's stem, its direct signal in its own.
        let sending = Track(name: "Keys", kind: .instrument,
                            sends: [Send(destinationBusID: verb.id, level: 0.5)])
        #expect(sending.isMasterInput)
    }

    @Test("m23-m3c: the plan's filter and its refusal answer with the SAME predicate")
    func partitionAgreesWithIsMasterInput() throws {
        let s = session()
        let plan = try StemPlan.descriptors(tracks: s.tracks, including: nil)
        let planned = Set(plan.map(\.id))
        for track in s.tracks {
            #expect(planned.contains(track.id) == track.isMasterInput,
                    "\(track.name) is planned=\(planned.contains(track.id)) but isMasterInput=\(track.isMasterInput)")
            // …and naming it explicitly must succeed or refuse by the same rule:
            // a track the filter drops silently must reject readably.
            if track.isMasterInput {
                #expect(throws: Never.self) {
                    _ = try StemPlan.descriptors(tracks: s.tracks, including: [track.id])
                }
            } else {
                #expect(throws: ProjectError.self) {
                    _ = try StemPlan.descriptors(tracks: s.tracks, including: [track.id])
                }
            }
        }
    }

    // MARK: - The planned file set (m23-m3c)

    @Test("m23-m3c: fileSet composes the siblings ahead of the partition, in write order")
    func fileSetOrderAndComposition() throws {
        let s = session()
        let stems = try StemPlan.descriptors(tracks: s.tracks, including: nil).map(\.fileName)
        #expect(try StemPlan.fileSet(tracks: s.tracks) == stems,
                "no siblings asked for → exactly the partition")
        #expect(try StemPlan.fileSet(tracks: s.tracks, includeMixdown: true)
                == ["00 Mixdown.wav"] + stems)
        #expect(try StemPlan.fileSet(tracks: s.tracks, includeMasteredMixdown: true)
                == ["00 Mastered Mix.wav"] + stems)
        // ORDER is contract, not incidental: the mixdown is written before the
        // mastered sibling, and both before nothing — set equality would not
        // pin the list the preview renders top to bottom.
        #expect(try StemPlan.fileSet(tracks: s.tracks, includeMixdown: true,
                                     includeMasteredMixdown: true)
                == ["00 Mixdown.wav", "00 Mastered Mix.wav"] + stems)
    }

    @Test("m23-m3c: the sibling names come from the constants the render writes with")
    func siblingNamesHaveOneHome() throws {
        let s = session()
        let set = try StemPlan.fileSet(tracks: s.tracks, includeMixdown: true,
                                       includeMasteredMixdown: true,
                                       format: .default)
        #expect(set[0] == DeliveryFormat.default.fileName(StemPlan.mixdownBaseName))
        #expect(set[1] == DeliveryFormat.default.fileName(StemPlan.masteredMixdownBaseName))
        // The extension is the format's, never a literal (m23-m2): these names
        // are what the dialog PROMISES, so a hardcoded ".wav" would promise WAV
        // files from an AIFF export.
        let aiff = try DeliveryFormat.resolve(bitDepth: 24, container: "aiff")
        let aiffSet = try StemPlan.fileSet(tracks: s.tracks, includeMixdown: true,
                                           includeMasteredMixdown: true, format: aiff)
        #expect(aiffSet == ["00 Mixdown.aiff", "00 Mastered Mix.aiff",
                            "01 Drums.aiff", "02 Crunch.aiff", "03 Keys.aiff"])
    }

    @Test("m23-m3c: an empty partition plans NOTHING — not even the siblings")
    func fileSetIsEmptyWhenNothingReachesMaster() throws {
        let verb = Track(name: "Verb", kind: .bus)
        // The destination bus is absent from the session, so nothing here is a
        // master input.
        let orphan = [Track(name: "Bass", kind: .audio, outputBusID: verb.id)]
        #expect(try StemPlan.fileSet(tracks: orphan, includeMixdown: true,
                                     includeMasteredMixdown: true).isEmpty,
                "renderStems throws nothingToRender before it writes anything, so promising two 00 files would be a lie")
        #expect(try StemPlan.fileSet(tracks: []).isEmpty)
    }

    @Test("m23-m3c: fileSet validates an explicit selection exactly as descriptors does")
    func fileSetInheritsTheRefusals() {
        let s = session()
        #expect(throws: ProjectError.self) {
            _ = try StemPlan.fileSet(tracks: s.tracks, including: [s.gtr.id])
        }
        #expect(throws: ProjectError.self) {
            _ = try StemPlan.fileSet(tracks: s.tracks, including: [UUID()])
        }
    }

    // MARK: - Solo transform: track stems

    @Test("Track stem pass = the track alone with sends stripped, all else whole")
    func trackStemTransform() throws {
        let bus = Track(name: "Verb", kind: .bus)
        var drums = Track(name: "Drums", kind: .audio,
                          volume: 0.8, pan: -0.25, isMuted: false,
                          clips: [Clip(name: "loop", startBeat: 0, lengthBeats: 8)],
                          sends: [Send(destinationBusID: bus.id, level: 0.5)],
                          effects: [EffectDescriptor(kind: .eq)])
        drums.automation = [AutomationLane(target: .volume)]
        let sessionTracks = [drums, bus]

        let plan = try StemPlan.descriptors(tracks: sessionTracks, including: [drums.id])
        let pass = StemPlan.passTracks(for: try #require(plan.first),
                                       session: sessionTracks)

        #expect(pass.count == 1)
        let solo = try #require(pass.first)
        #expect(solo.id == drums.id)
        // The ONLY change is sends = [] — dry post-fader path; automation,
        // clips, effects, fader, pan all ride along whole.
        #expect(solo.sends.isEmpty)
        var expected = drums
        expected.sends = []
        #expect(solo == expected)
    }

    // MARK: - Solo transform: bus stems + the silent dummy

    @Test("Bus stem pass: contributors kept, foreign sends dropped, direct outs → silent dummy")
    func busStemTransform() throws {
        let crunch = Track(name: "Crunch", kind: .bus,
                           effects: [EffectDescriptor(kind: .compressor)])
        let verb = Track(name: "Verb", kind: .bus)
        // Routed INTO Crunch, with a foreign send to Verb.
        let gtr = Track(name: "Gtr", kind: .audio, outputBusID: crunch.id,
                        sends: [Send(destinationBusID: verb.id, level: 0.4)])
        // Direct to master, sends into BOTH buses.
        let keys = Track(name: "Keys", kind: .instrument,
                         sends: [Send(destinationBusID: crunch.id, level: 0.7),
                                 Send(destinationBusID: verb.id, level: 0.2)])
        // No relation to Crunch at all.
        let vox = Track(name: "Vox", kind: .audio)
        let sessionTracks = [gtr, keys, vox, crunch, verb]

        let plan = try StemPlan.descriptors(tracks: sessionTracks, including: [crunch.id])
        let pass = StemPlan.passTracks(for: try #require(plan.first),
                                       session: sessionTracks)

        // Gtr' + Keys' + Crunch + dummy. Vox and Verb are gone.
        #expect(pass.count == 4)
        #expect(!pass.contains { $0.id == vox.id })
        #expect(!pass.contains { $0.id == verb.id })

        // The bus itself passes UNCHANGED (chain + fader intact).
        #expect(pass.first { $0.id == crunch.id } == crunch)

        // Gtr routes into Crunch already: direct out kept, foreign send dropped.
        let gtrPass = try #require(pass.first { $0.id == gtr.id })
        #expect(gtrPass.outputBusID == crunch.id)
        #expect(gtrPass.sends.isEmpty)

        // Keys is a send-only contributor: only the Crunch send survives, and
        // its direct out is rerouted to the silent dummy — NOT left at master
        // (would double-count) and NOT pointed at a missing bus (the graph's
        // missing-bus fallback IS master, which would leak the dry signal).
        let keysPass = try #require(pass.first { $0.id == keys.id })
        #expect(keysPass.sends == [Send(id: keys.sends[0].id,
                                        destinationBusID: crunch.id, level: 0.7)])
        let dummyID = try #require(keysPass.outputBusID)
        #expect(dummyID != crunch.id && dummyID != verb.id)

        // The dummy: present, a bus, dead silent, chainless, fresh identity.
        let dummy = try #require(pass.first { $0.id == dummyID })
        #expect(dummy.kind == .bus)
        #expect(dummy.volume == 0)
        #expect(dummy.effects.isEmpty)
        #expect(dummy.clips.isEmpty)
        #expect(!sessionTracks.contains { $0.id == dummy.id })
    }

    @Test("Dummy bus appears EXACTLY when a direct out was rerouted")
    func dummyOnlyWhenNeeded() throws {
        let bus = Track(name: "Drum Bus", kind: .bus)
        // Sole contributor routes INTO the bus and sends nowhere else — no
        // direct out needs parking, so no dummy.
        let kick = Track(name: "Kick", kind: .audio, outputBusID: bus.id)
        let sessionTracks = [kick, bus]

        let plan = try StemPlan.descriptors(tracks: sessionTracks, including: [bus.id])
        let pass = StemPlan.passTracks(for: try #require(plan.first),
                                       session: sessionTracks)

        #expect(pass.count == 2)
        #expect(Set(pass.map(\.id)) == [kick.id, bus.id])
        #expect(pass.allSatisfy { $0.kind != .bus || $0.id == bus.id })
    }

    // MARK: - File names

    @Test("Sanitize strips control/illegal chars, trims whitespace/dots, defaults empties")
    func fileNameSanitize() {
        var taken = Set<String>()
        #expect(StemPlan.fileName(index: 1, name: "  My/Mix: v2?*  ", kind: .track,
                                  taken: &taken) == "01 MyMix v2.wav")
        #expect(StemPlan.fileName(index: 2, name: "\u{01}Lead\u{7F}\tVox\n", kind: .track,
                                  taken: &taken) == "02 LeadVox.wav")
        #expect(StemPlan.fileName(index: 3, name: "..hidden..", kind: .track,
                                  taken: &taken) == "03 hidden.wav")
        // Fully-sanitized-away names fall back per kind.
        #expect(StemPlan.fileName(index: 4, name: "///", kind: .track,
                                  taken: &taken) == "04 Track.wav")
        #expect(StemPlan.fileName(index: 5, name: " . ", kind: .bus,
                                  taken: &taken) == "05 Bus.wav")
    }

    @Test("Duplicate names get ' 2', ' 3'… suffixes, case-insensitively")
    func fileNameCollisions() {
        var taken = Set<String>()
        #expect(StemPlan.fileName(index: 1, name: "Drums", kind: .track,
                                  taken: &taken) == "01 Drums.wav")
        #expect(StemPlan.fileName(index: 2, name: "Drums", kind: .track,
                                  taken: &taken) == "02 Drums 2.wav")
        #expect(StemPlan.fileName(index: 3, name: "drums", kind: .track,
                                  taken: &taken) == "03 drums 3.wav")
        // Distinct names sail through untouched.
        #expect(StemPlan.fileName(index: 4, name: "Bass", kind: .track,
                                  taken: &taken) == "04 Bass.wav")
    }

    @Test("Descriptor plan wires collisions through partition order end-to-end")
    func descriptorCollisionEndToEnd() throws {
        let a = Track(name: "Gtr", kind: .audio)
        let b = Track(name: "Gtr", kind: .audio)
        let bus = Track(name: "Gtr", kind: .bus)
        let plan = try StemPlan.descriptors(tracks: [a, b, bus], including: nil)
        #expect(plan.map(\.fileName) ==
                ["01 Gtr.wav", "02 Gtr 2.wav", "03 Gtr 3.wav"])
    }

    // MARK: - Wire shapes (Codable = wire, never drifts)

    @Test("StemExportResult round-trips through JSON with stable keys")
    func resultCodableRoundTrip() throws {
        let stem = StemFile(
            trackId: UUID(), name: "Drums", kind: .track,
            path: "/tmp/stems/01 Drums.wav",
            measurement: LoudnessMeasurement(integratedLufs: -18.2, truePeakDbtp: -3.1,
                                             maxMomentaryLufs: -15.0, maxShortTermLufs: -16.4))
        let result = StemExportResult(
            directory: "/tmp/stems", sampleRate: 48_000, durationSeconds: 12.5,
            channels: 2, stems: [stem],
            mixdown: MixdownFile(path: "/tmp/stems/00 Mixdown.wav",
                                 measurement: LoudnessMeasurement()))
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(StemExportResult.self, from: data)
        #expect(decoded == result)

        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"trackId\""))
        #expect(json.contains("\"kind\":\"track\""))
        #expect(json.contains("\"mixdown\""))
    }
}
