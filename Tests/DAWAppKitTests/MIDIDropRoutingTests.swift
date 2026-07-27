import Foundation
import Testing
import UniformTypeIdentifiers
import DAWCore
@testable import DAWAppKit

/// m23-k4b — the headless half of "a `.mid` reaches the app through the SAME
/// affordances audio does".
///
/// The item is a ROUTING SPLIT INSIDE AN ALREADY-ACCEPTING PATH, not a second
/// path beside one: `public.midi-audio` conforms to `public.audio`, so both the
/// arrange drop (`hasItemsConforming(to: [.audio])`) and ⌘I
/// (`allowedContentTypes`) already said yes to a `.mid` and then rejected it
/// downstream with "isn't a supported audio file". These tests pin that premise
/// (it is OS behaviour, so it needs a fixture, not a comment), the split, and the
/// ONE routing predicate the hover preview and the execution now share.
@Suite("MIDI drop + import routing (m23-k4b)")
struct MIDIDropRoutingTests {
    private let audioTrackID = UUID()

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    private func beat(_ value: Double) -> ResolvedDropBeat {
        ArrangeDropSnap.resolve(rawBeat: value, snap: .off,
                                meterMap: MeterMap(constant: TimeSignature()),
                                pixelsPerBeat: 80)
    }

    private func context(target: UUID? = nil, kind: TrackKind? = nil,
                         atBeat: Double = 0) -> AudioImportContext {
        AudioImportContext(targetTrackID: target, targetTrackKind: kind,
                           startBeat: beat(atBeat))
    }

    // MARK: The premise this whole item rests on

    @Test("PREMISE: a .mid IS an audio UTI — so the old accept paths already said yes")
    func midConformsToAudio() {
        guard let midType = UTType(filenameExtension: "mid") else {
            Issue.record("the OS resolved no type for \"mid\""); return
        }
        #expect(midType.identifier == "public.midi-audio")
        // The fact that makes `[.audio]` too wide for an AUDIO panel, and the
        // reason `validateDrop` needed no change at all. If this ever flips, the
        // ⌘I narrowing below becomes unnecessary and the drop's accept predicate
        // becomes WRONG — one fixture guards both.
        #expect(midType.conforms(to: .audio))
        #expect(midType.conforms(to: .midi))
    }

    // MARK: Panel content types (the ⌘I narrowing)

    @Test("Import Audio…'s panel types no longer enable a .mid")
    func audioPanelTypesExcludeMIDI() {
        let types = AudioImportPlan.audioContentTypes
        #expect(!types.isEmpty)
        // NSOpenPanel enables a file when the FILE's type conforms to an allowed
        // type — so this is the direction that decides selectability. Asserting
        // `$0.conforms(to: .midi)` instead would pass vacuously even with plain
        // `.audio` in the list, i.e. it would not notice the bug being fixed.
        #expect(!types.contains { UTType.midi.conforms(to: $0) },
                "a .mid must be greyed out in Import Audio…")
        // Negative control on the same relation: real audio still selectable.
        for ext in ["wav", "aiff", "mp3", "m4a", "caf"] {
            guard let type = UTType(filenameExtension: ext) else { continue }
            #expect(types.contains { type.conforms(to: $0) },
                    "\(ext) must stay selectable in Import Audio…")
        }
        // A `dyn.*` placeholder enables nothing; it would only make the list lie.
        #expect(!types.contains { $0.isDynamic })
    }

    @Test("Import/Export MIDI…'s panel types accept .mid and .midi, and only those")
    func midiPanelTypes() {
        let types = AudioImportPlan.midiContentTypes
        #expect(!types.isEmpty)
        for ext in Array(ProjectStore.midiFileExtensions) {
            guard let type = UTType(filenameExtension: ext) else {
                Issue.record("the OS resolved no type for \"\(ext)\""); continue
            }
            #expect(types.contains { type.conforms(to: $0) })
        }
        // `mid` and `midi` resolve to the SAME type — the list is de-duplicated.
        #expect(types.count == Set(types).count)
        if let wav = UTType(filenameExtension: "wav") {
            #expect(!types.contains { wav.conforms(to: $0) })
        }
    }

    // MARK: The file gate

    @Test("isMIDIFile reads the store's own extension set, case-insensitively")
    func midiTypeGate() {
        #expect(AudioImportPlan.isMIDIFile(url("song.mid")))
        #expect(AudioImportPlan.isMIDIFile(url("Song.MIDI")))
        #expect(!AudioImportPlan.isMIDIFile(url("kick.wav")))
        #expect(!AudioImportPlan.isMIDIFile(url("notes.txt")))
        #expect(!AudioImportPlan.isMIDIFile(url("noext")))
        // No second spelling of "is this a MIDI file" may exist: the plan gates
        // on exactly what `ProjectStore.importMIDIFile` accepts, or a routed file
        // would come back refused as "not a MIDI file".
        for ext in ProjectStore.midiFileExtensions {
            #expect(AudioImportPlan.isMIDIFile(url("x.\(ext)")))
        }
        // …and the two sets stay disjoint, so classification is unambiguous.
        #expect(AudioImportPlan.audioExtensions
            .isDisjoint(with: ProjectStore.midiFileExtensions))
    }

    // MARK: The split

    @Test("a MIDI-only import routes the file, and rejects nothing")
    func midiOnlyImport() {
        // The headline case, and the one that takes the plan's `audioURLs.isEmpty`
        // early return — the path where a carelessly placed `return` drops the
        // MIDI on the floor and reports success.
        let plan = AudioImportPlan(urls: [url("song.mid")], context: context(atBeat: 12))
        #expect(plan.actions.isEmpty)
        #expect(plan.rejected.isEmpty, "a .mid is ROUTED, never rejected as non-audio")
        #expect(plan.midiImports == [MIDIImportAction(url: url("song.mid"), startBeat: 12)])
    }

    @Test("a MIDI-only import onto an audio lane still creates its own tracks")
    func midiOnlyOntoAudioLane() {
        let plan = AudioImportPlan(urls: [url("song.mid")],
                                   context: context(target: audioTrackID, kind: .audio, atBeat: 4))
        #expect(plan.actions.isEmpty, "a .mid never becomes a clip on the hovered audio lane")
        #expect(plan.midiImports.count == 1)
        #expect(plan.midiImports[0].startBeat == 4)
    }

    @Test("non-audio, non-MIDI files are still rejected verbatim")
    func unsupportedStillRejected() {
        let plan = AudioImportPlan(urls: [url("notes.txt"), url("song.mid")],
                                   context: context())
        #expect(plan.rejected.count == 1)
        #expect(plan.rejected[0].url == url("notes.txt"))
        #expect(plan.rejected[0].reason.contains("isn't a supported audio file"))
        #expect(plan.midiImports.count == 1)
    }

    @Test("several MIDI files keep input order")
    func midiOrderPreserved() {
        let plan = AudioImportPlan(urls: [url("b.mid"), url("a.midi"), url("c.mid")],
                                   context: context())
        #expect(plan.midiImports.map(\.url.lastPathComponent) == ["b.mid", "a.midi", "c.mid"])
    }

    // MARK: Mixed drops (decided: both import, one landing)

    @Test("a mixed .wav + .mid drop imports BOTH, at the SAME landing beat")
    func mixedDropImportsBoth() {
        let plan = AudioImportPlan(urls: [url("kick.wav"), url("song.mid")],
                                   context: context(atBeat: 8))
        #expect(plan.actions.count == 1)
        #expect(plan.midiImports.count == 1)
        #expect(plan.rejected.isEmpty)
        guard case .newTrack(_, let audioBeat, _) = plan.actions[0] else {
            Issue.record("expected newTrack, got \(plan.actions[0])"); return
        }
        #expect(audioBeat == plan.midiImports[0].startBeat,
                "one drop, one landing — the audio clip and the MIDI import share it")
        #expect(audioBeat == 8)
    }

    @Test("a MAGNETISED landing survives into both halves of a mixed drop")
    func mixedDropMagnetisedLanding() {
        // The m23-f invariant, extended to MIDI: the beat the drop LINE was drawn
        // at is the beat everything lands on. An off-grid magnet target is the
        // case a second computation downstream would visibly destroy.
        let landing = ArrangeDropSnap.resolve(
            rawBeat: 7.45, snap: .bar, meterMap: MeterMap(constant: TimeSignature()),
            pixelsPerBeat: 80, clipEdgeBeats: [7.4])
        #expect(landing.beat == 7.4)
        #expect(landing.source == .magnetClipEdge)
        let plan = AudioImportPlan(
            urls: [url("kick.wav"), url("song.mid")],
            context: AudioImportContext(targetTrackID: audioTrackID, targetTrackKind: .audio,
                                        startBeat: landing))
        #expect(plan.midiImports[0].startBeat == 7.4,
                "a re-snap downstream would have pulled this to 8")
        guard case .newTrack(_, let audioBeat, _) = plan.actions[0] else {
            Issue.record("expected newTrack, got \(plan.actions[0])"); return
        }
        #expect(audioBeat == 7.4)
    }

    @Test("a mixed drop's AUDIO member does not silently take the hovered lane")
    func mixedDropDoesNotClaimHoveredLane() {
        // The preview/execution agreement that motivates the new predicate input.
        // The hover sees fileCount 2 (no highlight); after the MIDI is split out
        // the plan sees ONE audio file over an audio lane, which would have routed
        // straight onto it — a landing the drop line never promised.
        let plan = AudioImportPlan(urls: [url("kick.wav"), url("song.mid")],
                                   context: context(target: audioTrackID, kind: .audio))
        guard case .newTrack = plan.actions[0] else {
            Issue.record("""
                a MIDI-carrying drag must not route audio onto the hovered lane — \
                got \(plan.actions[0])
                """)
            return
        }
    }

    @Test("without MIDI in the drag, a lone audio file still lands on the hovered lane")
    func pureAudioUnchanged() {
        // The negative control for the case above: same shape, no `.mid`, and the
        // shipped m10-k routing must be untouched.
        let plan = AudioImportPlan(urls: [url("kick.wav")],
                                   context: context(target: audioTrackID, kind: .audio))
        guard case .existingTrack(let id, _, _) = plan.actions[0] else {
            Issue.record("expected existingTrack, got \(plan.actions[0])"); return
        }
        #expect(id == audioTrackID)
    }

    // MARK: The ONE routing predicate

    @Test("routesToExistingAudioTrack: a MIDI-carrying drag never claims the lane")
    func routingRuleWithMIDI() {
        // The preview calls this with `carriesMIDI` off the drag's UTIs; the plan
        // calls it with the same answer off the URLs. One function, so the lane
        // highlight cannot promise a landing the import will not honour.
        #expect(!AudioImportPlan.routesToExistingAudioTrack(
            fileCount: 1, targetKind: .audio, dragCarriesMIDI: true))
        #expect(AudioImportPlan.routesToExistingAudioTrack(
            fileCount: 1, targetKind: .audio, dragCarriesMIDI: false))
        // The default keeps every pure-audio caller — and the shipped m10-k
        // routing table — reading exactly as before.
        #expect(AudioImportPlan.routesToExistingAudioTrack(fileCount: 1, targetKind: .audio))
        // MIDI does not RESCUE a routing the old rule already refused.
        #expect(!AudioImportPlan.routesToExistingAudioTrack(
            fileCount: 2, targetKind: .audio, dragCarriesMIDI: true))
        #expect(!AudioImportPlan.routesToExistingAudioTrack(
            fileCount: 1, targetKind: .instrument, dragCarriesMIDI: true))
        #expect(!AudioImportPlan.routesToExistingAudioTrack(
            fileCount: 1, targetKind: nil, dragCarriesMIDI: true))
    }

    // MARK: What a drag carries

    @Test("ArrangeDragContents.of classifies a resolved url set")
    func dragContentsOfURLs() {
        #expect(ArrangeDragContents.of(urls: [url("kick.wav")])
            == ArrangeDragContents(fileCount: 1, carriesMIDI: false))
        #expect(ArrangeDragContents.of(urls: [url("song.mid")])
            == ArrangeDragContents(fileCount: 1, carriesMIDI: true))
        #expect(ArrangeDragContents.of(urls: [url("kick.wav"), url("song.MIDI")])
            == ArrangeDragContents(fileCount: 2, carriesMIDI: true))
        // A file the drag carries that is neither still counts toward fileCount:
        // the routing rule asks "how many files", not "how many usable ones".
        #expect(ArrangeDragContents.of(urls: [url("notes.txt")])
            == ArrangeDragContents(fileCount: 1, carriesMIDI: false))
        #expect(ArrangeDragContents.of(urls: []) == ArrangeDragContents(fileCount: 0,
                                                                        carriesMIDI: false))
    }
}
