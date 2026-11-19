import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m39-tpl-6 (design §6.1/§6.2, §8.2, §8.5 D2):
/// the WIRE half of multi-instrument templates — `template.list/describe/
/// apply/save/remove/import/export`, plus `macro.songSkeleton`'s `template`/
/// `dryRun`. DAWCore's own template machinery (`TemplateBuilder`,
/// `TemplateCapture`, `ProjectStore+Templates`/`+TemplateLibrary`) is proven
/// in `Tests/DAWCoreTests/Template*Tests.swift` (TPL-2/TPL-2B/TPL-3/TPL-5/
/// TPL-5B); this file proves the WIRE SHELL over it: param parsing, reply
/// shape, the D2 teaching refusal, and that a refusal here changes nothing.
///
/// `makeRouter()` below is this file's OWN helper: `MacroSkeletonCommandTests.
/// makeRouter()` is `private` (file-scoped), so it is not visible from this
/// extension even though both live in the same type. Extending an existing
/// `@MainActor` suite rather than declaring a new one keeps this file inside
/// the wave's "no new `@MainActor` suite" cap.
extension MacroSkeletonCommandTests {
    private func makeRouter2() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    // MARK: - template.list

    @Test("m39-tpl-6: template.list advertises every built-in and rejects an unknown key")
    func tpl6ListAdvertisesBuiltIns() async {
        let (router, _) = makeRouter2()
        let response = await router.handle(ControlRequest(id: "1", command: "template.list", params: [:]))
        #expect(response.ok)
        let templates = response.result?["templates"]?.arrayValue ?? []
        let ids = Set(templates.compactMap { $0["id"]?.stringValue })
        #expect(ids.isSuperset(of: BuiltInTemplateCatalog.ids),
                "template.list is missing built-ins: \(Set(BuiltInTemplateCatalog.ids).subtracting(ids))")
        #expect(response.result?["unreadable"]?.arrayValue != nil)

        let bad = await router.handle(ControlRequest(
            id: "2", command: "template.list", params: ["bogus": .bool(true)]))
        #expect(!bad.ok)
        #expect(bad.error == "template.list: unknown parameter 'bogus' — template.list takes no parameters")
    }

    // MARK: - template.describe

    @Test("m39-tpl-6: template.describe resolves a built-in id, an inline object, and rejects an unknown id/key")
    func tpl6DescribeResolvesIdAndInline() async throws {
        let (router, _) = makeRouter2()
        let byID = await router.handle(ControlRequest(
            id: "1", command: "template.describe", params: ["template": .string("lofi-chill")]))
        #expect(byID.ok)
        let template = try #require(byID.result?["template"])
        let tracks = try #require(template["tracks"]?.arrayValue)
        #expect(!tracks.isEmpty)
        let describedTracks = try #require(byID.result?["tracks"]?.arrayValue)
        #expect(describedTracks.count == tracks.count)
        for track in describedTracks {
            #expect(track["sound"]?.stringValue?.isEmpty == false)
        }
        #expect(byID.result?["slotsUsed"] != nil)
        #expect(byID.result?["hasRouting"]?.boolValue != nil)
        #expect(byID.result?["warnings"]?.arrayValue != nil)

        // Round-trip: describing the WHOLE object `template` just returned
        // (re-submitted inline) must succeed and describe the same tracks —
        // proves the `.object` branch of `decodeTemplateParam`, not just the
        // id branch above.
        let inline = await router.handle(ControlRequest(
            id: "2", command: "template.describe", params: ["template": template]))
        #expect(inline.ok)
        let inlineTracks = try #require(inline.result?["template"]?["tracks"]?.arrayValue)
        #expect(inlineTracks.count == tracks.count)

        let unknownID = await router.handle(ControlRequest(
            id: "3", command: "template.describe", params: ["template": .string("not-a-real-id")]))
        #expect(!unknownID.ok)
        #expect((unknownID.error ?? "").contains("not-a-real-id"))

        let unknownKey = await router.handle(ControlRequest(
            id: "4", command: "template.describe",
            params: ["template": .string("lofi-chill"), "templat": .string("x")]))
        #expect(!unknownKey.ok)
        #expect((unknownKey.error ?? "").contains("'templat'"))
    }

    // MARK: - template.apply

    @Test("m39-tpl-6: template.apply adds every track as ONE undo step, and dryRun changes nothing")
    func tpl6ApplyAddsTracksAsOneUndoStep() async throws {
        let (router, store) = makeRouter2()
        let before = store.tracks.count
        let beforeUndo = store.undoLabel

        let dryRun = await router.handle(ControlRequest(
            id: "1", command: "template.apply",
            params: ["template": .string("lofi-chill"), "dryRun": .bool(true)]))
        #expect(dryRun.ok)
        #expect(dryRun.result?["applied"]?.boolValue == false)
        #expect(store.tracks.count == before, "a dry run must not add tracks")
        #expect(store.undoLabel == beforeUndo, "a dry run must not record an undo step")
        let dryRunTracks = try #require(dryRun.result?["tracks"]?.arrayValue)
        for track in dryRunTracks {
            #expect(track["id"] == nil, "a dry run must not mint ids")
        }

        let real = await router.handle(ControlRequest(
            id: "2", command: "template.apply", params: ["template": .string("lofi-chill")]))
        #expect(real.ok)
        #expect(real.result?["applied"]?.boolValue == true)
        let realTracks = try #require(real.result?["tracks"]?.arrayValue)
        #expect(realTracks.count == dryRunTracks.count,
                "a dry run must predict exactly what the real apply then does")
        for track in realTracks {
            #expect(track["id"]?.stringValue != nil, "a real apply must mint an id for every track")
        }
        #expect(store.tracks.count == before + realTracks.count)
        #expect(store.canUndo)

        // Additive: applying a SECOND time adds a second full set, not a
        // dedupe/merge — the design's own word for this ("additive — twice
        // adds twice").
        let again = await router.handle(ControlRequest(
            id: "3", command: "template.apply", params: ["template": .string("lofi-chill")]))
        #expect(again.ok)
        #expect(store.tracks.count == before + 2 * realTracks.count)
    }

    @Test("m39-tpl-6: template.apply with an unknown id is refused and changes nothing")
    func tpl6ApplyUnknownIDChangesNothing() async {
        let (router, store) = makeRouter2()
        let beforeCount = store.tracks.count
        let beforeUndo = store.undoLabel
        let beforeCanUndo = store.canUndo

        let response = await router.handle(ControlRequest(
            id: "1", command: "template.apply", params: ["template": .string("does-not-exist")]))
        #expect(!response.ok)
        #expect((response.error ?? "").contains("does-not-exist"))
        #expect(store.tracks.count == beforeCount, "a refusal must not add tracks")
        #expect(store.undoLabel == beforeUndo, "a refusal must not record an undo step")
        #expect(store.canUndo == beforeCanUndo)
    }

    @Test("m39-tpl-6: template.apply rejects an unknown top-level key without touching the song")
    func tpl6ApplyUnknownKeyChangesNothing() async {
        let (router, store) = makeRouter2()
        let beforeCount = store.tracks.count
        let response = await router.handle(ControlRequest(
            id: "1", command: "template.apply",
            params: ["template": .string("lofi-chill"), "dryRnu": .bool(true)]))
        #expect(!response.ok)
        #expect((response.error ?? "").contains("'dryRnu'"))
        #expect(store.tracks.count == beforeCount)
    }

    // MARK: - template.save / remove / import / export

    @Test("m39-tpl-6: save, list, remove, export and import round-trip through the real library")
    func tpl6SaveRemoveExportImportRoundTrip() async throws {
        let (router, store) = makeRouter2()

        // A track to save — track.add is the real wire verb, so this is also
        // proof the save path reads a track this suite did not hand-build.
        let add = await router.handle(ControlRequest(
            id: "1", command: "track.add",
            params: ["name": .string("Lead"), "kind": .string("instrument")]))
        #expect(add.ok)
        let trackID = try #require(add.result?["id"]?.stringValue)
        let beforeUndoLabel = store.undoLabel

        let save = await router.handle(ControlRequest(
            id: "2", command: "template.save",
            params: ["name": .string("TPL-6 round trip"), "trackIds": .array([.string(trackID)])]))
        #expect(save.ok)
        #expect(store.undoLabel == beforeUndoLabel, "template.save must not record an undo step")
        let savedID = try #require(save.result?["id"]?.stringValue)
        #expect(save.result?["template"] != nil)
        #expect(save.result?["warnings"]?.arrayValue != nil)

        let listed = await router.handle(ControlRequest(id: "3", command: "template.list", params: [:]))
        let listedIDs = Set((listed.result?["templates"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        #expect(listedIDs.contains(savedID))

        // A non-array genres param (per the advisor's check #7): confirm the
        // actual sentence, not just "is an error" — `parseStringList`'s
        // `requirement: ""` must not leave a dangling clause.
        let badGenres = await router.handle(ControlRequest(
            id: "3b", command: "template.save",
            params: ["name": .string("Bad Genres"), "trackIds": .array([.string(trackID)]),
                     "genres": .string("not-an-array")]))
        #expect(!badGenres.ok)
        #expect(badGenres.error == "'genres' must be an array of strings",
                "the empty `requirement:` clause left something dangling: \(badGenres.error ?? "<nil>")")

        // Export to an absolute temp path, remove the saved entry, re-import
        // it, and confirm it is listed again (possibly under a fresh id —
        // the design's own "already taken" rule — so match by name).
        let exportPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl6-roundtrip-\(UUID().uuidString).dawtemplate").path
        let export = await router.handle(ControlRequest(
            id: "4", command: "template.export",
            params: ["id": .string(savedID), "path": .string(exportPath)]))
        #expect(export.ok)
        #expect(export.result?["path"]?.stringValue == exportPath)
        #expect((export.result?["bytes"]?.doubleValue ?? 0) > 0)
        #expect(FileManager.default.fileExists(atPath: exportPath))

        let nonAbsolute = await router.handle(ControlRequest(
            id: "4b", command: "template.export",
            params: ["id": .string(savedID), "path": .string("relative/path.dawtemplate")]))
        #expect(!nonAbsolute.ok)

        let remove = await router.handle(ControlRequest(
            id: "5", command: "template.remove", params: ["id": .string(savedID)]))
        #expect(remove.ok)
        #expect(remove.result?["removed"]?.stringValue == savedID)

        let removeBuiltIn = await router.handle(ControlRequest(
            id: "5b", command: "template.remove", params: ["id": .string("lofi-chill")]))
        #expect(!removeBuiltIn.ok)
        #expect((removeBuiltIn.error ?? "").lowercased().contains("built-in"))

        let listedAfterRemove = await router.handle(ControlRequest(id: "6", command: "template.list", params: [:]))
        let idsAfterRemove = Set((listedAfterRemove.result?["templates"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        #expect(!idsAfterRemove.contains(savedID))

        let imported = await router.handle(ControlRequest(
            id: "7", command: "template.import", params: ["path": .string(exportPath)]))
        #expect(imported.ok)
        #expect(imported.result?["name"]?.stringValue == "TPL-6 round trip")
        let listedAfterImport = await router.handle(ControlRequest(id: "8", command: "template.list", params: [:]))
        let namesAfterImport = (listedAfterImport.result?["templates"]?.arrayValue ?? [])
            .compactMap { $0["name"]?.stringValue }
        #expect(namesAfterImport.contains("TPL-6 round trip"))

        try? FileManager.default.removeItem(atPath: exportPath)
    }

    // MARK: - §8.2: describe's canonical composition equals apply's real tracks

    /// §8.2's gate, written to be a REAL discriminator against the predicted
    /// P1 plant (`TemplateBuilder.build` dropping a mixer preset's chain):
    /// `template.describe`'s `template` field is `TemplateCapture.
    /// canonicalJSON`, and `TemplateCapture.canonicalTrack` FLATTENS a mixer
    /// preset's chain into the canonical form's own `inserts` array itself
    /// (read in source before writing this test, not assumed: "the mixer
    /// preset's chain first, then the template's own inserts" — a preset
    /// name never survives into the canonical `tracks[i]`, which is why this
    /// test never reads a `mixerPreset` key back). That flattening is its
    /// OWN call to `MixerPresetCatalog.preset(named:).freshChain()`, entirely
    /// separate from `TemplateBuilder.build`'s identical-looking but
    /// INDEPENDENT call to the same catalog. `template.apply`'s resulting
    /// tracks, by contrast, ARE the real tracks `build` produced. So a plant
    /// that breaks only `build`'s own composition (dropping the chain, say)
    /// makes describe's canonical `inserts` (still correct — a different
    /// function) diverge from apply's real `effects` (now wrong) — where
    /// comparing describe's OWN reply fields against apply's OWN reply
    /// fields would NOT catch it: neither wire reply surfaces an insert-kind
    /// list on its own, and `template.describe` also calls `TemplateBuilder.
    /// plan` (which itself calls `build`) for its `slotsUsed`/`hasRouting`
    /// fields — so a reply-shape-only comparison would share the same bug on
    /// both sides. Matched by each track's stable `key`, not array order.
    @Test("m39-tpl-6 §8.2: for every built-in template, template.apply's real effect chains equal describe's canonical (mixer-preset-flattened) inserts")
    func tpl6DescribeEqualsApplyForEveryBuiltIn() async throws {
        var templatesWithEffects = 0
        for id in BuiltInTemplateCatalog.ids {
            let (router, store) = makeRouter2()
            let describe = await router.handle(ControlRequest(
                id: "d-\(id)", command: "template.describe", params: ["template": .string(id)]))
            #expect(describe.ok, "\(id): template.describe failed: \(describe.error ?? "")")
            let canonicalTracks = try #require(describe.result?["template"]?["tracks"]?.arrayValue, "\(id)")

            // MEASURED, not assumed: `TemplateCapture.canonicalTrack` RE-KEYS
            // every track (e.g. a file's own key "pad" came back "synth-pad"
            // in the canonical form — caught by this gate's first run, which
            // matched by `key` and failed every track with a real preset,
            // `expected` silently empty because the lookup key never
            // existed). `name` is untouched by canonicalization
            // (`TemplateTrack(key: key, name: track.name, ...)` in source),
            // and `template.apply`'s reply also carries `name` — matching on
            // it instead sidesteps the re-key entirely. Built-in templates
            // are asserted to have unique track names below so this map
            // cannot silently merge two tracks.
            var expectedByName: [String: [String]] = [:]
            for track in canonicalTracks {
                let name = try #require(track["name"]?.stringValue, "\(id)")
                #expect(expectedByName[name] == nil, "\(id): duplicate track name '\(name)' makes name-matching unsafe")
                #expect(track["mixerPreset"] == nil,
                        "\(id)/\(name): the canonical form is documented to flatten mixerPreset into inserts — this test's whole premise just broke")
                let inserts = track["inserts"]?.arrayValue ?? []
                let expected = inserts.compactMap { $0["kind"]?.stringValue }
                expectedByName[name] = expected
                if !expected.isEmpty { templatesWithEffects += 1 }
            }

            let apply = await router.handle(ControlRequest(
                id: "a-\(id)", command: "template.apply", params: ["template": .string(id)]))
            #expect(apply.ok, "\(id): template.apply failed: \(apply.error ?? "")")
            let appliedTracks = try #require(apply.result?["tracks"]?.arrayValue, "\(id)")
            #expect(appliedTracks.count == canonicalTracks.count,
                    "\(id): describe and apply disagree on how many tracks this template has")

            for appliedTrack in appliedTracks {
                let name = try #require(appliedTrack["name"]?.stringValue, "\(id)")
                guard let idString = appliedTrack["id"]?.stringValue, let trackID = UUID(uuidString: idString) else {
                    Issue.record("\(id)/\(name): template.apply did not mint an id")
                    continue
                }
                guard let actualTrack = store.tracks.first(where: { $0.id == trackID }) else {
                    Issue.record("\(id)/\(name): applied track id not found in the store")
                    continue
                }
                let actual = actualTrack.effects.map { $0.kind.rawValue }
                let expected = expectedByName[name] ?? []
                #expect(actual == expected,
                        "\(id)/\(name): describe implies \(expected) but apply built \(actual)")
            }
        }
        // Vacuity guard: at least one built-in must actually exercise a
        // mixer preset or an insert, or every comparison above is `[] == []`
        // and the gate has no teeth.
        #expect(templatesWithEffects > 0,
                "no built-in template has a mixer preset or an insert — this gate never compared anything real")
    }

    // MARK: - D2: a skeleton track list cannot pick sounds

    @Test("m39-tpl-6 D2: macro.songSkeleton's tracks[i].program is refused with the exact teaching sentence, and a generic unknown key is refused by path")
    func tpl6D2TrackProgramIsRefused() async {
        let (router, store) = makeRouter2()
        let beforeCount = store.tracks.count

        let withProgram = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: ["genre": .string("pop"),
                     "tracks": .array([.object([
                         "name": .string("Lead"), "kind": .string("instrument"),
                         "program": .number(5),
                     ])])]))
        #expect(!withProgram.ok)
        #expect(withProgram.error == "tracks[0].program: A track list can't pick sounds. To choose "
                + "instruments, pass a template.")
        #expect(store.tracks.count == beforeCount)

        let withOtherKey = await router.handle(ControlRequest(
            id: "2", command: "macro.songSkeleton",
            params: ["genre": .string("pop"),
                     "tracks": .array([.object([
                         "name": .string("Lead"), "kind": .string("instrument"),
                         "velocity": .number(100),
                     ])])]))
        #expect(!withOtherKey.ok)
        let message = withOtherKey.error ?? ""
        #expect(message.contains("tracks[0]"))
        #expect(message.contains("'velocity'"))
        #expect(!message.contains("pass a template"),
                "a non-program unknown key must get the generic refusal, not the program-specific one")
        #expect(store.tracks.count == beforeCount)
    }

    // MARK: - macro.songSkeleton: template + dryRun

    @Test("m39-tpl-6 §6.2: macro.songSkeleton accepts a template, a dryRun preview matches the real apply, and template+tracks together is refused")
    func tpl6SkeletonTemplateAndDryRun() async throws {
        let (router, store) = makeRouter2()

        let dryRun = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: ["genre": .string("pop"), "dryRun": .bool(true)]))
        #expect(dryRun.ok)
        #expect(dryRun.result?["applied"]?.boolValue == false)
        #expect(store.tracks.isEmpty, "a dry run must not add tracks")
        let dryRunTrackCount = dryRun.result?["tracks"]?.arrayValue?.count ?? -1
        #expect(dryRunTrackCount > 0)

        let real = await router.handle(ControlRequest(
            id: "2", command: "macro.songSkeleton", params: ["genre": .string("pop")]))
        #expect(real.ok)
        #expect(real.result?["templateKeys"] == nil, "no template was used, so templateKeys must be absent")
        #expect(real.result?["warnings"]?.arrayValue == [])
        #expect(store.tracks.count == dryRunTrackCount,
                "the dry run must predict exactly what the real call then creates")

        // template param: a real genre-free build driven entirely by a
        // built-in template, and the templateKeys field it is documented to
        // add.
        let (router2, store2) = makeRouter2()
        let withTemplate = await router2.handle(ControlRequest(
            id: "3", command: "macro.songSkeleton",
            params: ["genre": .string("pop"), "template": .string("lofi-chill")]))
        #expect(withTemplate.ok)
        let templateKeys = try #require(withTemplate.result?["templateKeys"]?.objectValue,
                                        "macro.songSkeleton with a template must reply with templateKeys")
        #expect(!templateKeys.isEmpty)
        // `SongSkeletonPlan.tracks` is `rosterTracks + [arrangementTrack]`
        // (SongSkeleton.swift) — the Arrangement guide track is ALWAYS
        // appended on top of the template's own tracks and carries no
        // `templateKeys` entry of its own, so the total is one more than
        // `templateKeys.count`, not equal to it (read in source, not
        // assumed — this exact miscount was caught before running).
        #expect(store2.tracks.count == templateKeys.count + 1)
        for (_, idValue) in templateKeys {
            guard let idString = idValue.stringValue, let id = UUID(uuidString: idString) else {
                Issue.record("templateKeys carries a non-UUID value: \(idValue)")
                continue
            }
            #expect(store2.tracks.contains { $0.id == id })
        }

        // template + tracks together — refused by DAWCore's own sentence
        // (`ProjectStore.songSkeletonTemplateAndTracksRefusal`, internal to
        // DAWCore and so not referenceable by name from this target; the
        // literal is copied from source, not guessed).
        let (router3, store3) = makeRouter2()
        let conflict = await router3.handle(ControlRequest(
            id: "4", command: "macro.songSkeleton",
            params: ["genre": .string("pop"), "template": .string("lofi-chill"),
                     "tracks": .array([.object(["name": .string("Lead"), "kind": .string("instrument")])])]))
        #expect(!conflict.ok)
        #expect((conflict.error ?? "").contains("Use either a template or your own track list, not both."))
        #expect(store3.tracks.isEmpty)
    }

    // MARK: - W8-T67R: dryRun == real for every genre; every refusal changes nothing

    /// The bytes a refusal must leave untouched: the whole project snapshot, encoded
    /// with sorted keys so equal state is equal bytes.
    private func tpl67ProjectBytes(_ store: ProjectStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(store.snapshot())
    }

    @Test("m39-tpl-6 §8.2: macro.songSkeleton dryRun predicts the real call field for field, for all 14 genres and for every built-in template")
    func tpl67SkeletonDryRunEqualsRealForEveryGenreAndTemplate() async throws {
        var cases: [(label: String, params: [String: JSONValue])] = SongSkeletonCatalog.names.map {
            ("genre \($0)", ["genre": .string($0)])
        }
        for id in BuiltInTemplateCatalog.ids {
            cases.append(("template \(id)", ["genre": .string("pop"), "template": .string(id)]))
        }
        #expect(SongSkeletonCatalog.names.count == 14, "the gate is documented for all 14 genres")
        var comparedEffectChains = 0
        for (label, params) in cases {
            let (router, store) = makeRouter2()
            var dryParams = params
            dryParams["dryRun"] = .bool(true)
            let beforeBytes = try tpl67ProjectBytes(store)
            let dry = await router.handle(ControlRequest(id: "d", command: "macro.songSkeleton", params: dryParams))
            #expect(dry.ok, "\(label): dryRun failed: \(dry.error ?? "")")
            #expect(dry.result?["applied"]?.boolValue == false, "\(label)")
            #expect(try tpl67ProjectBytes(store) == beforeBytes, "\(label): a dry run changed the project")
            #expect(!store.canUndo, "\(label): a dry run left an undo step")
            let dryTracks = try #require(dry.result?["tracks"]?.arrayValue, "\(label)")
            for track in dryTracks {
                #expect(track["id"] == nil, "\(label): a dry run must carry no ids")
            }

            let real = await router.handle(ControlRequest(id: "r", command: "macro.songSkeleton", params: params))
            #expect(real.ok, "\(label): real call failed: \(real.error ?? "")")

            #expect(dry.result?["genre"] == real.result?["genre"], "\(label)")
            #expect(dry.result?["tempoBPM"] == real.result?["tempoBPM"], "\(label)")
            #expect(dry.result?["sectionClips"] == real.result?["sectionClips"], "\(label)")
            #expect(dry.result?["loopStart"] == real.result?["loopStart"], "\(label)")
            #expect(dry.result?["loopEnd"] == real.result?["loopEnd"], "\(label)")
            #expect(dry.result?["warnings"] == real.result?["warnings"], "\(label)")
            #expect(dry.result?["undoLabel"]?.stringValue == store.undoLabel,
                    "\(label): the dry run's undoLabel must be the real step's label")
            // markers: the plan names and positions them, the real call also mints ids.
            let dryMarkers = (dry.result?["markers"]?.arrayValue ?? []).map { "\($0["name"]?.stringValue ?? "?")@\($0["beat"]?.doubleValue ?? -1)" }
            let realMarkers = (real.result?["markers"]?.arrayValue ?? []).map { "\($0["name"]?.stringValue ?? "?")@\($0["beat"]?.doubleValue ?? -1)" }
            #expect(dryMarkers == realMarkers, "\(label): markers differ")
            // tracks: names, kinds and the insert chain, read off the REAL store by the
            // ids the real reply returned.
            let realTracks = try #require(real.result?["tracks"]?.arrayValue, "\(label)")
            #expect(dryTracks.count == realTracks.count, "\(label): track count differs")
            for (dryTrack, realTrack) in zip(dryTracks, realTracks) {
                #expect(dryTrack["name"] == realTrack["name"], "\(label)")
                let id = try #require(realTrack["id"]?.stringValue.flatMap(UUID.init(uuidString:)), "\(label)")
                let built = try #require(store.tracks.first { $0.id == id }, "\(label)")
                #expect(dryTrack["kind"]?.stringValue == built.kind.rawValue, "\(label)/\(built.name): kind")
                let dryKinds = (dryTrack["inserts"]?.arrayValue ?? []).compactMap { $0["kind"]?.stringValue }
                #expect(dryKinds == built.effects.map { $0.kind.rawValue },
                        "\(label)/\(built.name): the dry run's insert chain differs from what was built")
                if !dryKinds.isEmpty { comparedEffectChains += 1 }
            }
        }
        #expect(comparedEffectChains > 0, "no case had an insert chain: the comparison had no teeth")
    }

    @Test("m39-tpl-6: every refusal on the template verbs and the skeleton leaves the project's bytes and its undo state unchanged")
    func tpl67EveryRefusalChangesNothing() async throws {
        let (router, store) = makeRouter2()
        // A non-trivial song, so "unchanged" is not "still empty".
        let seed = await router.handle(ControlRequest(
            id: "seed", command: "template.apply", params: ["template": .string("lofi-chill")]))
        #expect(seed.ok, "seed failed: \(seed.error ?? "")")
        let seededTrackID = try #require(
            seed.result?["tracks"]?.arrayValue?.first?["id"]?.stringValue, "seed carried no track id")
        let typo: JSONValue = .object([
            "formatVersion": .number(1), "name": .string("Typo"),
            "tracks": .array([.object([
                "key": .string("k"), "name": .string("K"), "kind": .string("instrument"),
                "instrumnet": .object(["kind": .string("polySynth")]),
            ])]),
        ])
        let refusals: [(String, String, [String: JSONValue])] = [
            ("apply: unknown id", "template.apply", ["template": .string("no-such-template")]),
            ("apply: typo'd inline key", "template.apply", ["template": typo]),
            ("apply: wrong type", "template.apply", ["template": .number(3)]),
            ("apply: missing template", "template.apply", [:]),
            ("apply: unknown top-level key", "template.apply",
             ["template": .string("lofi-chill"), "dryrun": .bool(true)]),
            ("describe: unknown id", "template.describe", ["template": .string("no-such-template")]),
            ("describe: typo'd inline key", "template.describe", ["template": typo]),
            ("save: unknown track id", "template.save",
             ["name": .string("X"), "trackIds": .array([.string(UUID().uuidString)])]),
            ("save: no tracks", "template.save", ["name": .string("X"), "trackIds": .array([])]),
            ("save: name too long", "template.save",
             ["name": .string(String(repeating: "x", count: 41)),
              "trackIds": .array([.string(seededTrackID)])]),
            ("remove: a built-in", "template.remove", ["id": .string("lofi-chill")]),
            ("remove: unknown id", "template.remove", ["id": .string("user-nope")]),
            ("import: relative path", "template.import", ["path": .string("relative/band.dawtemplate")]),
            ("export: relative path", "template.export",
             ["id": .string("lofi-chill"), "path": .string("relative/band.dawtemplate")]),
            ("skeleton: template and tracks", "macro.songSkeleton",
             ["genre": .string("pop"), "template": .string("lofi-chill"),
              "tracks": .array([.object(["name": .string("L"), "kind": .string("instrument")])])]),
            ("skeleton: unknown template id", "macro.songSkeleton",
             ["genre": .string("pop"), "template": .string("no-such-template")]),
            ("skeleton: unknown template id, dry run", "macro.songSkeleton",
             ["genre": .string("pop"), "template": .string("no-such-template"), "dryRun": .bool(true)]),
            ("skeleton: tracks[0].program", "macro.songSkeleton",
             ["genre": .string("pop"), "tracks": .array([.object([
                 "name": .string("L"), "kind": .string("instrument"), "program": .number(5)])])]),
            ("skeleton: tracks[0] unknown key", "macro.songSkeleton",
             ["genre": .string("pop"), "tracks": .array([.object([
                 "name": .string("L"), "kind": .string("instrument"), "velocity": .number(9)])])]),
            ("skeleton: unknown top-level key", "macro.songSkeleton",
             ["genre": .string("pop"), "dryrun": .bool(true)]),
        ]
        let bytes = try tpl67ProjectBytes(store)
        let canUndo = store.canUndo
        let undoLabel = store.undoLabel
        #expect(canUndo, "the seed must have left an undo step, or the comparison has no teeth")
        for (label, command, params) in refusals {
            let response = await router.handle(ControlRequest(id: label, command: command, params: params))
            #expect(!response.ok, "\(label): expected a refusal")
            #expect(!(response.error ?? "").isEmpty, "\(label): a refusal must say why")
            #expect(try tpl67ProjectBytes(store) == bytes, "\(label): the refusal changed the project")
            #expect(store.canUndo == canUndo, "\(label): the refusal changed canUndo")
            #expect(store.undoLabel == undoLabel, "\(label): the refusal changed the undo label")
        }
    }

    @Test("m39-tpl-6 §6.2: a warning from resolving the template shows on the dry run exactly as on the real call")
    func tpl67SkeletonDryRunShowsTemplateResolutionWarnings() async throws {
        // A template written by a NEWER format version with a key this build does not know:
        // the codec skips the key with `unknownKeySkipped` (a warning, not a refusal).
        let newer: JSONValue = .object([
            "formatVersion": .number(Double(TrackSetTemplate.currentFormatVersion + 1)),
            "name": .string("Newer band"),
            "futureKey": .string("from the future"),
            "tracks": .array([.object([
                "key": .string("keys"), "name": .string("Keys"), "kind": .string("instrument"),
            ])]),
        ])
        let (router, store) = makeRouter2()
        let dry = await router.handle(ControlRequest(
            id: "d", command: "macro.songSkeleton",
            params: ["genre": .string("pop"), "template": newer, "dryRun": .bool(true)]))
        #expect(dry.ok, "dry run failed: \(dry.error ?? "")")
        let dryWarnings = try #require(dry.result?["warnings"]?.arrayValue)
        #expect(dryWarnings.contains { $0["code"]?.stringValue == "unknownKeySkipped" },
                "the dry run hid the template's own resolution warning: \(dryWarnings)")
        #expect(store.tracks.isEmpty)
        let real = await router.handle(ControlRequest(
            id: "r", command: "macro.songSkeleton",
            params: ["genre": .string("pop"), "template": newer]))
        #expect(real.ok, "real call failed: \(real.error ?? "")")
        #expect(dry.result?["warnings"] == real.result?["warnings"],
                "the dry run's warnings must equal the real call's")
        // Same on template.apply, both paths (the shape this fix mirrors).
        let (router2, _) = makeRouter2()
        let applyDry = await router2.handle(ControlRequest(
            id: "ad", command: "template.apply", params: ["template": newer, "dryRun": .bool(true)]))
        let applyReal = await router2.handle(ControlRequest(
            id: "ar", command: "template.apply", params: ["template": newer]))
        #expect(applyDry.result?["warnings"] == applyReal.result?["warnings"])
        #expect((applyReal.result?["warnings"]?.arrayValue ?? []).isEmpty == false)
    }

    // MARK: - Tail placement (P2's prediction)

    @Test("m39-tpl-6: the 7 template verbs are registered right after playbox.generate, NOT at the tail")
    func tpl6VerbsPlacedAfterPlaybox() {
        let all = CommandRouter.allCommands
        guard let playboxIndex = all.firstIndex(of: "playbox.generate") else {
            Issue.record("playbox.generate missing from allCommands")
            return
        }
        let expected = ["template.list", "template.describe", "template.apply", "template.save",
                        "template.remove", "template.import", "template.export"]
        let actual = Array(all[(playboxIndex + 1)..<(playboxIndex + 1 + expected.count)])
        #expect(actual == expected)
        #expect(all.last != "template.export", "a tail append would break every dropLast(N) pin in this file")
        #expect(all.count == 288)   // 286 -> 288 at m39-w4-10 (pattern.list + clip.addDrumPattern, W9-PAT, placed right after clip.addMIDI, NOT at the tail)  <- 285 -> 286 at m27-f (fx.getParams, W8-M27F)  <- 280 at p2-sing-e (+17 singing verbs: the sing.* family, clip.setLyrics/getLyrics and project.transpose, placed right after template.export, NOT at the tail) <- 263 at m39-tpl-6 -> 285 at p2-sing-x7 part A (+5 verbs: clip.setNoteWord, clip.setSingStyle, clip.getSingStyle, sing.proposeHarmony, sing.capabilities, placed right after project.transpose at the end of the singing block, NOT at the tail)
    }
}
