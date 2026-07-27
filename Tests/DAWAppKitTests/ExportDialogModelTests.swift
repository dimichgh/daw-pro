import Foundation
import Testing
@testable import DAWAppKit
@testable import DAWCore

/// The Export dialog's headless model (m23-m3).
///
/// Scope note, deliberately narrow: NOTHING here proves a file. Every leg that
/// matters for delivery — that the chosen depth and container actually reach
/// the bytes, and that a default export is byte-identical to today's bounce —
/// lives in `DAWEngineTests/ExportDialogRenderTests`, driven through the real
/// store and read back by a parser that did not write the file. A suite that
/// asserted "the picker offers AIFF" would pass on an implementation that
/// renders the control and never plumbs it, which is exactly the m23-m2 failure
/// wearing a UI costume. What IS provable here is the mapping: dialog state →
/// `ExportRequest`, and the refusals that keep an invalid format unrepresentable.
@MainActor
@Suite("Export dialog model (m23-m3)")
struct ExportDialogModelTests {

    /// Whole `Track` values since m23-m3c: the model plans the stems preview
    /// through `StemPlan`, which reads routing and kind, so ONE input type
    /// reaches the planner. The checkbox rows' `ExportTrackChoice` list is
    /// derived inside `prepare`.
    private func session() -> [Track] {
        [
            Track(name: "Drums", kind: .audio),
            Track(name: "Lead Vocal", kind: .audio),
            Track(name: "Synth", kind: .instrument),
        ]
    }

    // MARK: - The default is today's bounce

    @Test("a freshly opened dialog requests EXACTLY the shipped defaults")
    func defaultRequestIsTheShippedBounce() {
        let model = ExportDialogModel()
        model.prepare(tracks: session())
        let request = model.request()
        // Every one of these is `renderBounce`'s own default value, so opening
        // the dialog and changing nothing calls it as `renderBounce(toPath:)`.
        #expect(request.bitDepth == nil)
        #expect(request.container == nil)
        #expect(request.excludeTrackIds == nil)
        #expect(request.lufsTarget == nil)
        #expect(request.truePeakCeilingDb == -1.0)
        #expect(model.format == DeliveryFormat.default)
        #expect(model.format.isDefault)
    }

    @Test("an EMPTY exclusion encodes as nil, never as an empty array")
    func emptyExclusionIsNil() {
        let model = ExportDialogModel()
        let tracks = session()
        model.prepare(tracks: tracks)
        #expect(model.request().excludeTrackIds == nil)
        // Excluding then un-excluding must land back on nil, not [].
        model.toggleExcluded(tracks[0].id)
        #expect(model.request().excludeTrackIds?.count == 1)
        model.toggleExcluded(tracks[0].id)
        #expect(model.request().excludeTrackIds == nil,
                "[] is a DIFFERENT meaning on the wire — it makes excludedTracks present in the response")
    }

    // MARK: - Format (the ONE home stays the one home)

    @Test("the depth picker's options are DERIVED from the validator's own list")
    func selectableDepthsCannotDriftFromResolve() {
        #expect(DeliveryFormat.selectableBitDepths.first == .some(nil),
                "the Float32 default leads the list")
        #expect(DeliveryFormat.selectableBitDepths.compactMap { $0 }
                == DeliveryFormat.validIntegerBitDepths)
        // Every offered depth must survive `resolve` — a picker that offered one
        // it rejects would throw AFTER the save panel.
        for depth in DeliveryFormat.selectableBitDepths {
            #expect(throws: Never.self) {
                _ = try DeliveryFormat.resolve(bitDepth: depth, container: nil)
            }
        }
    }

    @Test("every depth and container reads back through the model's format, not a UI literal")
    func formatSettersPlumbThrough() {
        let model = ExportDialogModel()
        model.setBitDepth(24)
        model.setContainer(.aiff)
        #expect(model.format.bitDepth == 24)
        #expect(model.format.container == .aiff)
        // The extension is the load-bearing part (AVAudioFile picks the
        // container off it) and it comes from DeliveryFormat.
        #expect(model.format.fileExtension == "aiff")
        #expect(model.suggestedFileName(projectName: "Night Drive") == "Night Drive.aiff")
        let request = model.request()
        #expect(request.bitDepth == 24)
        #expect(request.container == "aiff")

        model.setContainer(.wav)
        #expect(model.suggestedFileName(projectName: "Night Drive") == "Night Drive.wav")
        #expect(model.request().container == nil, "WAV is the default — absence means the default")
    }

    @Test("an out-of-vocabulary depth is REFUSED — the previous format stands")
    func invalidDepthIsRefusedNotCoerced() {
        let model = ExportDialogModel()
        model.setBitDepth(24)
        model.setContainer(.aiff)
        for bogus in [8, 0, 12, 48, 64, -16] {
            model.setBitDepth(bogus)
            #expect(model.format.bitDepth == 24,
                    "\(bogus) must refuse, not corrupt — and must NOT silently fall back to the default either")
            #expect(model.format.container == .aiff)
        }
        // …and the valid vocabulary still applies afterwards.
        model.setBitDepth(nil)
        #expect(model.format.bitDepth == nil)
    }

    @Test("depth labels are beginner-readable and never collide at 32")
    func depthLabelsAreDistinct() {
        let labels = DeliveryFormat.selectableBitDepths.map { DeliveryFormat.depthLabel($0) }
        #expect(Set(labels).count == labels.count,
                "two depths reading the same would make the picker a lie: \(labels)")
        #expect(DeliveryFormat.depthLabel(nil) == "32-bit float")
        #expect(DeliveryFormat.depthLabel(32) == "32-bit integer")
        #expect(DeliveryFormat.depthLabel(16) == "16-bit")
        for label in labels {
            #expect(!label.uppercased().contains("PCM"), "wire spelling leaked into a label: \(label)")
            #expect(!DeliveryFormat.depthDetail(
                DeliveryFormat.selectableBitDepths.first(where: {
                    DeliveryFormat.depthLabel($0) == label })!).isEmpty)
        }
        #expect(DeliveryContainer.wav.label == "WAV")
        #expect(DeliveryContainer.aiff.label == "AIFF")
    }

    // MARK: - Leave tracks out

    @Test("exclusions emit in SESSION order, not set order")
    func exclusionsAreOrdered() {
        let model = ExportDialogModel()
        let tracks = session()
        model.prepare(tracks: tracks)
        // Toggled back-to-front on purpose.
        model.toggleExcluded(tracks[2].id)
        model.toggleExcluded(tracks[0].id)
        #expect(model.request().excludeTrackIds == [tracks[0].id, tracks[2].id])
        #expect(model.excludedNames == ["Drums", "Synth"])
    }

    @Test("an id that is not in the dialog's list can never be excluded")
    func unknownIdIsIgnored() {
        let model = ExportDialogModel()
        model.prepare(tracks: session())
        model.toggleExcluded(UUID())
        #expect(model.request().excludeTrackIds == nil,
                "an unknown id would throw trackNotFound mid-export, after the save panel")
    }

    @Test("re-opening PRUNES an exclusion whose track is gone")
    func prepareDropsStaleExclusions() {
        let model = ExportDialogModel()
        let tracks = session()
        model.prepare(tracks: tracks)
        model.toggleExcluded(tracks[1].id)
        #expect(model.request().excludeTrackIds?.count == 1)
        // The vocal track is deleted; the dialog re-opens.
        model.prepare(tracks: [tracks[0], tracks[2]])
        #expect(model.request().excludeTrackIds == nil)
        #expect(model.excludedNames.isEmpty)
    }

    @Test("re-opening KEEPS the format and normalization choices (they cannot go stale)")
    func prepareKeepsSettings() {
        let model = ExportDialogModel()
        model.prepare(tracks: session())
        model.setBitDepth(16)
        model.setContainer(.aiff)
        model.normalize = true
        model.lufsTarget = -16
        model.prepare(tracks: session())
        #expect(model.format.bitDepth == 16)
        #expect(model.format.container == .aiff)
        #expect(model.normalize)
        #expect(model.lufsTarget == -16)
    }

    // MARK: - Normalization

    @Test("normalization OFF emits no target AND the shipped ceiling, whatever was dialled")
    func ceilingIsInertWhileNormalizationIsOff() {
        let model = ExportDialogModel()
        model.lufsTarget = -9
        model.truePeakCeilingDb = -6
        let request = model.request()
        #expect(request.lufsTarget == nil)
        #expect(request.truePeakCeilingDb == -1.0,
                "the ceiling IS echoed into the report even when unread — a stale value there would describe a render that never happened")
    }

    @Test("normalization ON emits both values")
    func normalizationOnEmitsBoth() {
        let model = ExportDialogModel()
        model.normalize = true
        model.lufsTarget = -14
        model.truePeakCeilingDb = -1.5
        let request = model.request()
        #expect(request.lufsTarget == -14)
        #expect(request.truePeakCeilingDb == -1.5)
    }

    @Test("targets clamp to the store's own contract ranges")
    func targetsClamp() {
        let model = ExportDialogModel()
        model.lufsTarget = 12
        #expect(model.lufsTarget == 0)          // contract: [-70, 0]
        model.lufsTarget = -200
        #expect(model.lufsTarget == -70)
        model.truePeakCeilingDb = 5
        #expect(model.truePeakCeilingDb == 0)   // contract: [-20, 0]
        model.truePeakCeilingDb = -99
        #expect(model.truePeakCeilingDb == -20)
    }

    // MARK: - File name

    @Test("the suggested name never carries a hardcoded extension, and never an empty stem")
    func suggestedName() {
        let model = ExportDialogModel()
        #expect(model.suggestedFileName(projectName: "Song") == "Song.wav")
        #expect(model.suggestedFileName(projectName: "   ") == "Untitled.wav")
        model.setContainer(.aiff)
        #expect(model.suggestedFileName(projectName: "Song") == "Song.aiff")
    }

    // MARK: - Stems mode (m23-m3c)

    /// Keys direct to master, Bass routed INTO the "Verb" bus, and the bus
    /// itself — the fixture the whole eligibility rule turns on. Bass is NOT a
    /// master input, so it has no stem of its own and the bus takes index 02.
    private func routedSession() -> [Track] {
        let verb = Track(name: "Verb", kind: .bus)
        return [
            Track(name: "Keys", kind: .instrument),
            Track(name: "Bass", kind: .audio, outputBusID: verb.id),
            verb,
        ]
    }

    @Test("m23-m3c: the dialog opens in BOUNCE mode and stems mode requests renderStems' own defaults")
    func stemsDefaultRequestIsTheShippedCall() {
        let model = ExportDialogModel()
        #expect(model.mode == .bounce)
        model.prepare(tracks: routedSession())
        model.mode = .stems
        let request = model.stemRequest()
        // Every one of these is `renderStems`' own default, so switching mode
        // and changing nothing calls `renderStems(toDirectory:)` verbatim.
        #expect(request.trackIds == nil)
        #expect(request.includeMixdown == false)
        #expect(request.includeMasteredMixdown == false)
        #expect(request.masteredLufsTarget == nil)
        #expect(request.masteredTruePeakCeilingDb == -1.0)
        #expect(request.bitDepth == nil)
        #expect(request.container == nil)
    }

    @Test("m23-m3c: the two requests never leak into each other")
    func theTwoRequestsAreIndependent() {
        let model = ExportDialogModel()
        let tracks = routedSession()
        model.prepare(tracks: tracks)
        model.toggleExcluded(tracks[0].id)
        model.normalize = true
        model.lufsTarget = -18
        model.includeMixdown = true
        model.includeMasteredMixdown = true
        model.masteredNormalize = true
        model.masteredLufsTarget = -9

        // The stems call takes an INCLUSION list, so an exclusion must never
        // reach it — silently reading "exclude Keys" as "include Keys" would
        // export the one track the user took out.
        let stems = model.stemRequest()
        #expect(stems.trackIds == nil)
        #expect(stems.masteredLufsTarget == -9)
        // …and the bounce keeps its own normalization number, not the mastered
        // sibling's.
        let bounce = model.request()
        #expect(bounce.excludeTrackIds == [tracks[0].id])
        #expect(bounce.lufsTarget == -18)
    }

    @Test("m23-m3c: a mastered target is carried only when the mastered file is actually written")
    func masteredTargetRidesTheFileThatUsesIt() {
        let model = ExportDialogModel()
        model.prepare(tracks: routedSession())
        model.masteredNormalize = true
        model.masteredLufsTarget = -12
        model.masteredTruePeakCeilingDb = -2
        // The sibling is off, so the target would describe a file that is never
        // rendered.
        #expect(model.stemRequest().masteredLufsTarget == nil)
        #expect(model.stemRequest().masteredTruePeakCeilingDb == -1.0)

        model.includeMasteredMixdown = true
        #expect(model.stemRequest().masteredLufsTarget == -12)
        #expect(model.stemRequest().masteredTruePeakCeilingDb == -2)

        // The file is written but not normalized: no target, shipped ceiling.
        model.masteredNormalize = false
        #expect(model.stemRequest().masteredLufsTarget == nil)
        #expect(model.stemRequest().masteredTruePeakCeilingDb == -1.0)
    }

    @Test("m23-m3c: the mastered numbers clamp to the same contract ranges the bounce's do")
    func masteredTargetsClamp() {
        let model = ExportDialogModel()
        model.masteredLufsTarget = 12
        #expect(model.masteredLufsTarget == 0)          // contract: [-70, 0]
        model.masteredLufsTarget = -200
        #expect(model.masteredLufsTarget == -70)
        model.masteredTruePeakCeilingDb = 5
        #expect(model.masteredTruePeakCeilingDb == 0)   // contract: [-20, 0]
        model.masteredTruePeakCeilingDb = -99
        #expect(model.masteredTruePeakCeilingDb == -20)
    }

    // MARK: - The preview IS the plan

    @Test("m23-m3c: the preview is StemPlan.fileSet — the same producer the render names files with")
    func previewIsTheOneProducer() throws {
        let model = ExportDialogModel()
        let tracks = routedSession()
        model.prepare(tracks: tracks)
        model.mode = .stems
        // Not "looks like the plan" — IS the plan, for the request as it stands.
        #expect(model.plannedStemFiles == (try StemPlan.fileSet(tracks: tracks)))
        // Bass is routed into Verb, so it has no file of its own and the bus
        // takes index 02 — the renumbering a mirrored implementation gets wrong.
        #expect(model.plannedStemFiles == ["01 Keys.wav", "02 Verb.wav"])

        model.includeMixdown = true
        #expect(model.plannedStemFiles == ["00 Mixdown.wav", "01 Keys.wav", "02 Verb.wav"])
        model.includeMasteredMixdown = true
        #expect(model.plannedStemFiles
                == ["00 Mixdown.wav", "00 Mastered Mix.wav", "01 Keys.wav", "02 Verb.wav"],
                "the siblings lead, mixdown before mastered — the order renderStems writes them")
        model.includeMixdown = false
        #expect(model.plannedStemFiles == ["00 Mastered Mix.wav", "01 Keys.wav", "02 Verb.wav"])
    }

    @Test("m23-m3c: the shared format control reaches the previewed names")
    func previewCarriesTheChosenContainer() {
        let model = ExportDialogModel()
        model.prepare(tracks: routedSession())
        model.mode = .stems
        model.includeMixdown = true
        model.setContainer(.aiff)
        model.setBitDepth(16)
        #expect(model.plannedStemFiles
                == ["00 Mixdown.aiff", "01 Keys.aiff", "02 Verb.aiff"],
                "the extension selects the container (m23-m2) — a preview with a literal .wav would name files nobody gets")
    }

    @Test("m23-m3c: a session with no master input previews nothing rather than a bogus file")
    func previewIsEmptyWithoutMasterInputs() {
        let model = ExportDialogModel()
        let bus = Track(name: "Verb", kind: .bus)
        // Only a bus-routed track — and the bus is NOT in the session, which is
        // the shape a half-built project can genuinely have.
        model.prepare(tracks: [Track(name: "Bass", kind: .audio, outputBusID: bus.id)])
        model.mode = .stems
        #expect(model.plannedStemFiles.isEmpty)
        // …and the mixdown siblings do not conjure a set out of nothing: the
        // sheet disables EXPORT on an empty plan, so a set of two "00" files
        // with no stems would re-enable a call that throws `nothingToRender`.
        model.includeMixdown = true
        model.includeMasteredMixdown = true
        #expect(model.plannedStemFiles.isEmpty,
                "renderStems refuses an empty partition before it writes anything, siblings or not")
    }

    // MARK: - The session snapshot

    @Test("m23-m3c: the checkbox rows are DERIVED from the session snapshot")
    func rowsAreDerivedFromTheSnapshot() {
        let model = ExportDialogModel()
        let tracks = routedSession()
        model.prepare(tracks: tracks)
        #expect(model.sessionTracks.map(\.id) == tracks.map(\.id))
        #expect(model.tracks.map(\.id) == tracks.map(\.id))
        #expect(model.tracks.map(\.name) == ["Keys", "Bass", "Verb"])
        #expect(model.tracks.map(\.kind) == [.instrument, .audio, .bus])
        // The routing the preview plans on lives on the snapshot, not on the row
        // view — which is exactly why the planner reads the snapshot.
        #expect(model.sessionTracks[1].outputBusID == tracks[2].id)
        #expect(model.sessionTracks[1].isMasterInput == false)
    }

    @Test("m23-m3c: a mode switch changes nothing but the mode")
    func modeSwitchPreservesEverySetting() {
        let model = ExportDialogModel()
        let tracks = routedSession()
        model.prepare(tracks: tracks)
        model.setBitDepth(24)
        model.setContainer(.aiff)
        model.toggleExcluded(tracks[0].id)
        model.normalize = true
        model.includeMasteredMixdown = true

        model.mode = .stems
        model.mode = .bounce
        #expect(model.format.bitDepth == 24)
        #expect(model.format.container == .aiff)
        #expect(model.request().excludeTrackIds == [tracks[0].id])
        #expect(model.normalize)
        #expect(model.includeMasteredMixdown)

        // …and re-opening keeps the mode too: a second export in one session
        // almost always wants the first one's shape.
        model.mode = .stems
        model.prepare(tracks: tracks)
        #expect(model.mode == .stems)
        #expect(model.includeMasteredMixdown)
    }

    @Test("m23-m3c: the mode vocabulary is exactly two, and neither says \"mixdown\"")
    func modeVocabulary() {
        #expect(ExportMode.allCases == [.bounce, .stems])
        let labels = ExportMode.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
        for mode in ExportMode.allCases {
            #expect(!mode.label.isEmpty)
            #expect(!mode.detail.isEmpty)
            #expect(mode.title.hasPrefix("EXPORT"))
            // `includeMixdown` is a stems PARAMETER that writes a file inside
            // the folder — it is not a mode, and a chip named for it would put
            // one word on two different things.
            #expect(!mode.label.lowercased().contains("mixdown"))
        }
    }
}
