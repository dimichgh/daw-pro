import Foundation
import Testing
@testable import DAWCore

// `ProjectStore.transcriptionSource` (m23-n2b, ProjectStore+Transcription.swift):
// the `clip.transcribe` wire's ONLY producer of "which file, which source
// slice, which project beat" — proven here to be a re-labelling of
// `Clip.sourceWindowSeconds(tempoMap:)` (Model.swift's "single evaluator"),
// never a second computation, plus the m23-n2b stretch trap: a
// `stretchRatio != 1` clip is REFUSED rather than mapped, because
// `TranscriptionBeatMapper` (m23-n2a) maps elapsed SOURCE seconds straight
// onto the timeline, which is correct only at ratio 1. Mirrors the
// `ClipAudioAnalysisStoreTests` precedent (same clip → engine-input shape,
// same MIDI/unknown-id error taxonomy).

@MainActor
@Suite("ProjectStore — transcriptionSource (m23-n2b)")
struct ClipTranscriptionSourceTests {

    /// A tempo/anchor/offset combination where seconds != beats and the
    /// window start != 0, so a bug that swapped startSeconds/anchorBeat, or
    /// dropped startOffsetSeconds, could not pass by coincidence — the
    /// `analyzeClipAudio` discriminator precedent.
    @Test("identity clip: fields are a re-labelling of sourceWindowSeconds, not a second computation")
    func identityHappyPath() throws {
        let tempo = TransportState(tempoBPM: 100)
        let clip = Clip(
            name: "Vocal", startBeat: 4, lengthBeats: 10,
            audioFileURL: URL(fileURLWithPath: "/tmp/vocal.wav"),
            startOffsetSeconds: 1.25)
        let track = Track(name: "Vocals", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track], transport: tempo)

        let source = try store.transcriptionSource(clipId: clip.id)

        #expect(source.audioURL == clip.audioFileURL)
        #expect(source.anchorBeat == clip.startBeat)
        #expect(source.startSeconds == clip.startOffsetSeconds)
        #expect(source.tempoMap.bpm(atBeat: 0) == 100)

        // ONE HOME: calling the SAME evaluator the wire relies on.
        let expectedWindow = clip.sourceWindowSeconds(tempoMap: store.transport.tempoMap)
        #expect(abs(source.endSeconds - (clip.startOffsetSeconds + expectedWindow)) < 1e-9)

        // Hand-derived cross-check, independent of sourceWindowSeconds, so a
        // bug shared between the test and the implementation (both calling
        // the same wrong thing) cannot hide: 10 beats at 100 BPM = 6.0 s.
        #expect(abs(expectedWindow - 6.0) < 1e-9)
        #expect(abs(source.endSeconds - 7.25) < 1e-9)
    }

    @Test("MIDI clip throws transcriptionRequiresAudioClip")
    func midiClipRejected() throws {
        let clip = Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])
        let track = Track(name: "Synth", kind: .instrument, clips: [clip])
        let store = ProjectStore(tracks: [track])

        do {
            _ = try store.transcriptionSource(clipId: clip.id)
            Issue.record("expected transcriptionRequiresAudioClip")
        } catch let error as ProjectError {
            guard case .transcriptionRequiresAudioClip(let id) = error else {
                Issue.record("expected transcriptionRequiresAudioClip, got \(error)")
                return
            }
            #expect(id == clip.id)
            #expect(error.errorDescription?.contains("clip.transcribe applies only to audio clips") == true)
        }
    }

    @Test("unknown clip id throws clipNotFound")
    func unknownClipRejected() throws {
        let store = ProjectStore()
        let unknownID = UUID()

        do {
            _ = try store.transcriptionSource(clipId: unknownID)
            Issue.record("expected clipNotFound")
        } catch let error as ProjectError {
            guard case .clipNotFound(let id) = error else {
                Issue.record("expected clipNotFound, got \(error)")
                return
            }
            #expect(id == unknownID)
        }
    }

    // THE STRETCH TRAP (m23-n2b): word timings come back in SOURCE seconds;
    // TranscriptionBeatMapper maps elapsed SOURCE seconds straight onto the
    // timeline, correct only when stretchRatio == 1. A naive hand-off at any
    // other ratio would be wrong by exactly that factor — refused instead.
    @Test("a stretched clip (stretchRatio != 1) is refused, naming the ratio")
    func stretchedClipRejected() throws {
        let clip = Clip(
            name: "Vocal", startBeat: 0, lengthBeats: 8,
            audioFileURL: URL(fileURLWithPath: "/tmp/vocal.wav"),
            stretchRatio: 1.5)
        let track = Track(name: "Vocals", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])

        do {
            _ = try store.transcriptionSource(clipId: clip.id)
            Issue.record("expected transcriptionRequiresUnstretchedClip")
        } catch let error as ProjectError {
            guard case .transcriptionRequiresUnstretchedClip(let id, let ratio) = error else {
                Issue.record("expected transcriptionRequiresUnstretchedClip, got \(error)")
                return
            }
            #expect(id == clip.id)
            #expect(ratio == 1.5)
            #expect(error.errorDescription?.contains("non-identity time-stretch") == true)
            #expect(error.errorDescription?.contains("ratio 1.500") == true)
            #expect(error.errorDescription?.contains("clip.setStretch ratio 1") == true)
        }
    }

    /// The boundary: EXACTLY 1 (the default) must NOT be refused — proven by
    /// actually reaching the success path, not merely the absence of the
    /// stretch error.
    @Test("stretchRatio exactly 1 is NOT refused")
    func identityRatioNotRejected() throws {
        let clip = Clip(
            name: "Vocal", startBeat: 0, lengthBeats: 8,
            audioFileURL: URL(fileURLWithPath: "/tmp/vocal.wav"),
            stretchRatio: 1)
        let track = Track(name: "Vocals", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])

        let source = try store.transcriptionSource(clipId: clip.id)
        #expect(source.audioURL == clip.audioFileURL)
    }

    /// A ratio just off identity (the nearest representable neighbour, still
    /// inside `Clip.stretchRatioRange`) is STILL refused — pins the guard at
    /// exact equality, not a tolerance band that would silently accept a
    /// near-1 ratio and mis-map words by that (tiny but real) factor.
    @Test("stretchRatio infinitesimally off 1 is still refused")
    func nearIdentityRatioStillRejected() throws {
        let clip = Clip(
            name: "Vocal", startBeat: 0, lengthBeats: 8,
            audioFileURL: URL(fileURLWithPath: "/tmp/vocal.wav"),
            stretchRatio: 1.0001)
        let track = Track(name: "Vocals", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])

        do {
            _ = try store.transcriptionSource(clipId: clip.id)
            Issue.record("expected transcriptionRequiresUnstretchedClip")
        } catch let error as ProjectError {
            guard case .transcriptionRequiresUnstretchedClip(let id, let ratio) = error else {
                Issue.record("expected transcriptionRequiresUnstretchedClip, got \(error)")
                return
            }
            #expect(id == clip.id)
            #expect(abs(ratio - 1.0001) < 1e-9)
        }
    }

    /// THE DISCRIMINATOR: `Clip.isStretchIdentity` (`stretchRatio == 1 &&
    /// pitchShiftSemitones == 0`) is a real, live property right next to
    /// `stretchRatio` on `Clip` — a plausible wrong guard to have reached for.
    /// Pitch shift alone changes NO elapsed time (WhisperKit's word timings
    /// are a function of samples read, not of pitch), so a clip that is
    /// pitch-shifted but NOT time-stretched must reach the success path.
    /// Swap the guard to `isStretchIdentity` and this is the one test in this
    /// suite that reddens — every other test here (including
    /// `identityRatioNotRejected`, which only ever sets `pitchShiftSemitones`
    /// to its default of 0) stays green under that mutant.
    @Test("pitch-shifted but un-stretched clip (stretchRatio == 1) is NOT refused")
    func pitchShiftAloneNotRejected() throws {
        let clip = Clip(
            name: "Vocal", startBeat: 0, lengthBeats: 8,
            audioFileURL: URL(fileURLWithPath: "/tmp/vocal.wav"),
            stretchRatio: 1, pitchShiftSemitones: 5)
        #expect(!clip.isStretchIdentity) // sanity: the discriminator is live
        let track = Track(name: "Vocals", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])

        let source = try store.transcriptionSource(clipId: clip.id)
        #expect(source.audioURL == clip.audioFileURL)
    }
}
