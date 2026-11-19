import AIServices
import DAWCore
import Foundation

// p2-sing-f: the seams between the Sing screens and the functions the wire calls.
//
// DAWAppKit cannot see DAWControl, so it cannot name the wire's own spy protocols (`SingLyricsWriting`,
// `SongTransposing`, `SingJobSubmitting` in `SingWire.swift`). These mirror them, requirement for requirement, and
// the REAL conformers are the SAME objects the router is handed: the app's one `ProjectStore` and its one
// `SingJobCoordinator`. So the Sing sheet's [Sing it] writes lyrics through `ProjectStore.setClipLyrics`, moves the
// key through `ProjectStore.transposeProject` and submits through `SingJobCoordinator.submit`: exactly the methods
// `clip.setLyrics` / `sing.render {lyrics}`, `project.transpose` and `sing.render` call. There is no UI-only path.
// A test puts a spy in front of each (GenerationPresenceModelTests' sing section).

/// THE lyrics writes the sheet makes: the requirements ARE `ProjectStore.setClipLyrics(clipId:text:language:undoLabel:)`
/// and `ProjectStore.setNoteWord(clipId:noteId:word:dryRun:)`, what `clip.setLyrics {language}` and `clip.setNoteWord`
/// call (`SingWire.swift`'s `SingLyricsEditing`, mirrored requirement for requirement).
///
/// p2-sing-x8 (the orchestrator's W8-X3b ruling): the sheet ALWAYS writes the words through the LANGUAGE overload with
/// the picker's value, so clearing the box and typing again keeps the language. The text-only overload is
/// deliberately NOT a requirement: a UI write that dropped the language could not compile against this seam.
@MainActor
public protocol SingSheetLyricsWriting: AnyObject {
    @discardableResult
    func setClipLyrics(clipId: UUID, text: String, language: String?, undoLabel: String) throws -> Clip
    @discardableResult
    func setNoteWord(clipId: UUID, noteId: UUID, word: String, dryRun: Bool) throws -> LyricNoteWordResult
}

extension ProjectStore: SingSheetLyricsWriting {}

/// THE style write (design §5.1's Expression card). The requirement IS `ProjectStore.setSingStyle(clipId:edit:)`,
/// what `clip.setSingStyle` calls (`SingWire.swift`'s `SingStyleWriting`, mirrored).
@MainActor
public protocol SingSheetStyleWriting: AnyObject {
    @discardableResult
    func setSingStyle(clipId: UUID, edit: SingStyleEdit) throws -> SingStyleWriteResult
}

extension ProjectStore: SingSheetStyleWriting {}

/// THE key change. The requirement IS `ProjectStore.transposeProject(semitones:excludeTrackIds:dryRun:)`.
@MainActor
public protocol SingSheetTransposing: AnyObject {
    @discardableResult
    func transposeProject(semitones: Int, excludeTrackIds: Set<UUID>, dryRun: Bool) throws -> TransposeReport
}

extension ProjectStore: SingSheetTransposing {}

/// THE sing job. The requirements ARE `SingJobCoordinator`'s `submit`, `status` and `cancel` (what `sing.render`,
/// `sing.jobStatus` and `sing.cancelJob` call).
public protocol SingSheetJobs: Sendable {
    func submit(_ request: SingJobRequest) async throws -> SingJobStatus
    func status(jobID: String) async throws -> SingJobStatus
    func cancel(jobID: String) async throws -> SingJobStatus
}

extension SingJobCoordinator: SingSheetJobs {}

/// What the voice recorder needs from the audio engine: exactly `AudioEngineControlling`'s microphone permission
/// and input-only capture (p2-sing-e, W8-SCAP + W8-RTFIX), so a test can stand a fake in front of them. Never a
/// real microphone in a test.
@MainActor
public protocol SingVoiceCapturing: AnyObject {
    var recordPermission: RecordPermission { get }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void)
    func startInputOnlyCapture(to url: URL, maxSeconds: Double,
                               completion: @escaping @MainActor (InputOnlyCaptureOutcome) -> Void) throws
    @discardableResult func stopInputOnlyCapture() -> Bool
    @discardableResult func cancelInputOnlyCapture() -> Bool
    func inputOnlyCapturePeakDbfs() -> Double?
}

/// The app's engine, as the recorder sees it: a forwarder, nothing more.
@MainActor
public final class SingEngineCapture: SingVoiceCapturing {
    private let engine: any AudioEngineControlling

    public init(engine: any AudioEngineControlling) { self.engine = engine }

    public var recordPermission: RecordPermission { engine.recordPermission }
    public func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        engine.requestRecordPermission(completion)
    }
    public func startInputOnlyCapture(to url: URL, maxSeconds: Double,
                                      completion: @escaping @MainActor (InputOnlyCaptureOutcome) -> Void) throws {
        try engine.startInputOnlyCapture(to: url, maxSeconds: maxSeconds, completion: completion)
    }
    @discardableResult public func stopInputOnlyCapture() -> Bool { engine.stopInputOnlyCapture() }
    @discardableResult public func cancelInputOnlyCapture() -> Bool { engine.cancelInputOnlyCapture() }
    public func inputOnlyCapturePeakDbfs() -> Double? { engine.inputOnlyCapturePeakDbfs() }
}

/// What the recorder needs from the song: is it playing or recording, stop it, and which project is open (a
/// project swap must end a running capture: RT review F5, "the caller must own that").
@MainActor
public protocol SingRecorderTransport: AnyObject {
    var isTransportPlaying: Bool { get }
    var isTransportRecording: Bool { get }
    /// The SAME stop the transport's Stop and `transport.stop` use.
    func stopTransport()
    var projectGeneration: UInt64 { get }
    /// The song's own Record refuses with this while it is set (p2-sing-f2: `ProjectStore.voiceRecorderOpenReason`,
    /// checked first by `record()` and every layer take). The recorder writes its `projectRecordRefusal` here on
    /// every step change. A requirement with NO default on purpose: a do-nothing default would turn a renamed
    /// property into a silent hole, with Record allowed under an open recorder.
    var voiceRecorderOpenReason: String? { get set }
}

extension ProjectStore: SingRecorderTransport {
    public var isTransportPlaying: Bool { transport.isPlaying }
    public var isTransportRecording: Bool { transport.isRecording }
    public func stopTransport() { stop() }
}

/// Plays one file at a time for the recorder: a guide tune, or the recording back ([▶ Listen]). The app plays
/// it off the audio engine (the `SketchpadPreview` precedent); a test fakes it.
@MainActor
public protocol SingAudioPreviewing: AnyObject {
    /// Starts `url` (stopping anything playing). `onFinish` fires once when it ends by itself.
    func play(_ url: URL, onFinish: @escaping @MainActor () -> Void) throws
    func stop()
}

/// A voice the recorder saved: what the card and the sheet need from the saved `SingVoiceRecord`.
public struct SingSavedVoice: Equatable, Sendable {
    public var id: String
    public var name: String
    public var range: VoiceRange
    /// Route N's verdict was poor: the saved line adds `VoiceReferenceLabeler.poorAlignmentMessage` (the wire's rule).
    public var poorAlignment: Bool

    public init(id: String, name: String, range: VoiceRange, poorAlignment: Bool) {
        self.id = id
        self.name = name
        self.range = range
        self.poorAlignment = poorAlignment
    }

    public init(record: SingVoiceRecord) {
        self.init(id: record.id, name: record.name, range: record.range, poorAlignment: record.labels.verdict == .poor)
    }
}

/// What adding a voice does: `sing.addVoice`'s own `SingVoicePreparation.prepare` (design §6 row 8), and its
/// background word check. `check` runs it into a scratch library (nothing is saved) and answers the measured
/// range; `save` runs it into the user's library under the chosen name.
public protocol SingVoiceSaving: Sendable {
    func check(recording: URL, kind: SingVoiceRecord.Source) async throws -> VoiceRange
    func save(recording: URL, name: String, kind: SingVoiceRecord.Source) async throws -> SingSavedVoice
}

/// The real one, over the app's voice library and the SAME pitch, guide and transcribe closures the router's
/// `SingWireServices` carries.
public struct SingVoicePreparationSaver: SingVoiceSaving {
    public let library: SingVoiceLibrary
    public let detectPitch: @Sendable (URL, Double) async throws -> [ClipPitchFrame]
    public let guides: [SingGuideLine.Guide: RenderedAudio]?
    public let transcribe: @Sendable (URL) async throws -> String?
    /// Where the check's throwaway copies go (`check` deletes its own folder).
    public let scratchRoot: URL

    public init(library: SingVoiceLibrary, detectPitch: @escaping @Sendable (URL, Double) async throws -> [ClipPitchFrame],
                guides: [SingGuideLine.Guide: RenderedAudio]?,
                transcribe: @escaping @Sendable (URL) async throws -> String?,
                scratchRoot: URL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("DAWPro-voice-check", isDirectory: true)) {
        self.library = library
        self.detectPitch = detectPitch
        self.guides = guides
        self.transcribe = transcribe
        self.scratchRoot = scratchRoot
    }

    /// `SingVoicePreparation.prepare` into a library of its own: the same checks, the same refusals in the same
    /// words, and the same range, but the user's library is untouched until Save.
    public func check(recording: URL, kind: SingVoiceRecord.Source) async throws -> VoiceRange {
        let scratch = SingVoiceLibrary(root: scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
        defer { Self.removeScratch(scratch.root) }
        return try await SingVoicePreparation.prepare(
            source: recording, name: nil, kind: kind, sourceName: recording.lastPathComponent, library: scratch,
            detectPitch: detectPitch, guides: guides).range
    }

    /// The check's throwaway folder. A failure to delete it is logged, never shown: nothing of the person's is in it.
    private static func removeScratch(_ folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            FileHandle.standardError.write(Data("SingVoicePreparationSaver: could not delete \(folder.path): \(error)\n".utf8))
        }
    }

    /// `SingVoicePreparation.prepare` into the user's library, then the background word check `sing.addVoice`
    /// starts (`SingWireHandlers.startVoiceWordCheck`, mirrored here because it is private to the wire: the same
    /// three public calls, `transcribe` → `SingVoiceWordCheck.check` → `library.update`). Without it a voice saved
    /// here would read `wordCheckIsReliable == true` forever, unlike one added over the wire.
    public func save(recording: URL, name: String, kind: SingVoiceRecord.Source) async throws -> SingSavedVoice {
        let record = try await SingVoicePreparation.prepare(
            source: recording, name: name, kind: kind, sourceName: recording.lastPathComponent, library: library,
            detectPitch: detectPitch, guides: guides)
        let library = self.library
        let transcribe = self.transcribe
        let reference = library.referenceURL(for: record.id)
        Task.detached {
            let heard: String?
            do {
                heard = try await transcribe(reference)
            } catch {
                return   // the transcriber failed: leave the voice unchecked rather than guess (the wire's rule)
            }
            guard var current = try? library.record(id: record.id) else { return }
            current.wordCheck = SingVoiceWordCheck.check(heard: heard)
            try? library.update(current)   // the wire's rule: a word check that cannot be stored is left out
        }
        return SingSavedVoice(record: record)
    }
}
