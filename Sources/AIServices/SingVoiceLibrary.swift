import CryptoKit
import DAWCore
import Foundation

// MARK: - One saved voice

/// A singing voice the user added (p2-sing-e part 2, `sing.addVoice`; design §2.3 "The user's voices"): what
/// `<voices>/<voiceId>/voice.json` holds beside `reference.wav`. Everything a sing job needs to send the voice to
/// the facade (the reference's hash, the Route N prompt labels) and everything `sing.listVoices` and
/// `sing.proposeKey` report (the range, the check, the alignment verdict) comes from here, never re-measured.
public struct SingVoiceRecord: Codable, Sendable, Equatable {
    /// Where the recording came from: the in-app recorder (item f), a file, or an audio clip of the project.
    public enum Source: String, Codable, Sendable {
        case recorder, file, clip
    }

    /// The format of this file; bumped only by a change an old reader would misread.
    public static let currentVersion = 1
    /// The reference recording's file name inside the voice's folder (design §2.3).
    public static let referenceFileName = "reference.wav"
    public static let recordFileName = "voice.json"

    public var version: Int
    /// `voice-<uuid>`: also the folder name and the facade's `voice.id` (`schema.py` `ID_RE`).
    public var id: String
    public var name: String
    /// `SungVocalProvenance.VoiceKind.own`.
    public var kind: String
    public var createdAt: Date
    public var durationS: Double
    /// The reference's own rate (design §2.3: "Float32, mono, native rate").
    public var sampleRate: Int
    /// sha256 of `reference.wav`'s bytes: the facade refuses a recording that changed since it was checked
    /// (`schema.py` `resolve`, `referenceChanged`).
    public var referenceSha256: String
    public var source: Source
    /// The file's name or the clip's name, for the reader; never a path the app reads again.
    public var sourceName: String?
    public var range: VoiceRange
    public var labels: VoiceReferenceLabels
    public var check: VoiceClipCheckResult
    /// Design §2.4: whole semitones added to the prompt's labels. 0 until listening Round L says otherwise.
    public var promptLabelOffset: Int
    /// The background word check on the reference itself (design §7.3 "the instrument check, per own voice").
    /// nil until it has run.
    public var wordCheck: SungWordCheck?

    public init(id: String, name: String, createdAt: Date, durationS: Double, sampleRate: Int,
                referenceSha256: String, source: Source, sourceName: String?, range: VoiceRange,
                labels: VoiceReferenceLabels, check: VoiceClipCheckResult, promptLabelOffset: Int = 0,
                wordCheck: SungWordCheck? = nil) {
        self.version = Self.currentVersion
        self.id = id
        self.name = name
        self.kind = SungVocalProvenance.VoiceKind.own
        self.createdAt = createdAt
        self.durationS = durationS
        self.sampleRate = sampleRate
        self.referenceSha256 = referenceSha256
        self.source = source
        self.sourceName = sourceName
        self.range = range
        self.labels = labels
        self.check = check
        self.promptLabelOffset = promptLabelOffset
        self.wordCheck = wordCheck
    }

    /// Design §7.3: a voice whose OWN reference the transcriber heard with a WER over 0.20 makes every take's
    /// word check read "hard to judge" instead of amber. Unchecked (no speech model yet) counts as reliable:
    /// the take's own check is then skipped honestly anyway.
    public var wordCheckIsReliable: Bool {
        guard let wordCheck, wordCheck.state == SungWordCheck.State.checked, let wer = wordCheck.wer else {
            return true
        }
        return wer <= SingVoiceWordCheck.reliableMaxWER
    }
}

// MARK: - The library on disk

/// Why a voice could not be found, read, saved or removed.
public enum SingVoiceLibraryError: Error, Equatable, LocalizedError {
    case notFound(String)
    case builtIn(String)
    case unreadable(id: String, detail: String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "There is no voice \"\(id)\"."
        case .builtIn(let id): return "\"\(id)\" is the built-in singer."
        case .unreadable(let id, let detail): return "The voice \"\(id)\" could not be read: \(detail)"
        case .writeFailed(let detail): return "The voice could not be saved: \(detail)"
        }
    }
}

/// The user's singing voices, one folder each under `root` (`AppDirectories.singingVoices` in the app, which is
/// also one of the facade's allowed roots, `SingingSidecarManager.Configuration.voicesDir`). Tests pass their own
/// root: nothing here ever falls back to the user's real library.
public struct SingVoiceLibrary: Sendable {
    public let root: URL

    /// Design §3.5 "Built-in V1": upstream's metadata f0, p10 / median / p90 = MIDI 61.7 / 65.9 / 68.7 [M].
    public static let builtInRange = VoiceRange(p10Midi: 61.7, medianMidi: 65.9, p90Midi: 68.7)

    public init(root: URL) {
        self.root = root
    }

    /// A voice id this library could have written: `voice-` and up to 58 more lower-case letters, digits or
    /// hyphens. Checked before any path is built from an id, so `../x` can never name a folder.
    public static func isValidID(_ id: String) -> Bool {
        guard id.hasPrefix("voice-"), id.count <= 64, id.count > 6 else { return false }
        return id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    public static func newID() -> String { "voice-" + UUID().uuidString.lowercased() }

    public func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    public func referenceURL(for id: String) -> URL {
        folder(for: id).appendingPathComponent(SingVoiceRecord.referenceFileName)
    }

    /// Every saved voice, oldest first, and the ids of folders whose `voice.json` could not be read (reported,
    /// never silently skipped).
    public func list() -> (voices: [SingVoiceRecord], unreadable: [String]) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var voices: [SingVoiceRecord] = []
        var unreadable: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = entry.lastPathComponent
            guard Self.isValidID(id) else { continue }
            do {
                voices.append(try record(id: id))
            } catch {
                unreadable.append(id)
            }
        }
        voices.sort { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        return (voices, unreadable)
    }

    public func record(id: String) throws -> SingVoiceRecord {
        if id.hasPrefix("builtin-") { throw SingVoiceLibraryError.builtIn(id) }
        guard Self.isValidID(id) else { throw SingVoiceLibraryError.notFound(id) }
        let url = folder(for: id).appendingPathComponent(SingVoiceRecord.recordFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SingVoiceLibraryError.notFound(id) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(SingVoiceRecord.self, from: Data(contentsOf: url))
            guard record.id == id else {
                throw SingVoiceLibraryError.unreadable(id: id, detail: "its voice.json names \"\(record.id)\"")
            }
            return record
        } catch let error as SingVoiceLibraryError {
            throw error
        } catch {
            throw SingVoiceLibraryError.unreadable(id: id, detail: error.localizedDescription)
        }
    }

    /// The job's view of a saved voice (`SingJobVoice.own`), its measured `range` included: the ONE home both the Sing
    /// sheet and `sing.render` build it in, so a harmony part sung in this voice gets the same whole-octave fit from
    /// either (p2-sing-x7c; the wire used to patch the range on afterwards and the sheet did not).
    public func ownVoice(_ record: SingVoiceRecord) -> SingOwnVoice {
        SingOwnVoice(id: record.id, name: record.name, referencePath: referenceURL(for: record.id).path,
                     referenceSha256: record.referenceSha256,
                     windowStartS: record.labels.windowStartSeconds, windowEndS: record.labels.windowEndSeconds,
                     promptNotes: SingVoicePrompt.promptNotes(record.labels),
                     promptLabelOffset: record.promptLabelOffset,
                     wordCheckIsReliable: record.wordCheckIsReliable, range: record.range)
    }

    static func encode(_ record: SingVoiceRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }

    /// Writes `record` beside the reference already in `staging`, then moves the folder into place as
    /// `<root>/<id>` in one rename, so a half-written voice is never listed.
    func commit(staging: URL, record: SingVoiceRecord) throws {
        do {
            try Self.encode(record).write(to: staging.appendingPathComponent(SingVoiceRecord.recordFileName),
                                          options: .atomic)
            try FileManager.default.moveItem(at: staging, to: folder(for: record.id))
        } catch {
            throw SingVoiceLibraryError.writeFailed(error.localizedDescription)
        }
    }

    /// Rewrites one voice's `voice.json` (the background word check's result). The reference is never touched.
    public func update(_ record: SingVoiceRecord) throws {
        guard Self.isValidID(record.id),
              FileManager.default.fileExists(atPath: folder(for: record.id).path) else {
            throw SingVoiceLibraryError.notFound(record.id)
        }
        do {
            try Self.encode(record).write(
                to: folder(for: record.id).appendingPathComponent(SingVoiceRecord.recordFileName), options: .atomic)
        } catch {
            throw SingVoiceLibraryError.writeFailed(error.localizedDescription)
        }
    }

    /// Moves a voice's folder to the Trash through `trash` (the app passes `FileManager.trashItem`; tests pass
    /// their own) and returns where it went. Never deletes.
    /// A voice whose `voice.json` cannot be read can still be removed (that is how a broken one is cleaned up).
    public func remove(id: String, trash: (URL) throws -> URL) throws -> URL {
        if id.hasPrefix("builtin-") { throw SingVoiceLibraryError.builtIn(id) }
        var isFolder: ObjCBool = false
        guard Self.isValidID(id), FileManager.default.fileExists(atPath: folder(for: id).path, isDirectory: &isFolder),
              isFolder.boolValue else {
            throw SingVoiceLibraryError.notFound(id)
        }
        return try trash(folder(for: id))
    }

    /// The real Trash, for the app.
    public static func moveToTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }
}

// MARK: - The prompt labels the facade reads

/// Route N's labels as the facade's `voice.prompt.notes` (design §2.4; `schema.py`): window-relative seconds,
/// the sung MIDI value, the guide word each note sings, and `continues` for every note after a word's first
/// ("gently" is sung on two notes, so its second note continues it).
public enum SingVoicePrompt {
    public static func promptNotes(_ labels: VoiceReferenceLabels) -> [SingingPromptNote] {
        labels.notes.map { note in
            let word = SingGuideLine.words.first { $0.noteIndices.contains(note.index) }
            return SingingPromptNote(
                startS: max(0, note.startSeconds - labels.windowStartSeconds),
                endS: max(0, note.endSeconds - labels.windowStartSeconds),
                midi: note.midi,
                word: word?.text ?? note.syllable,
                continues: (word?.noteIndices.first).map { $0 != note.index } ?? false)
        }
    }
}

// MARK: - The background word check on a voice's own reference

public enum SingVoiceWordCheck {
    /// Design §7.3: over 0.20, the voice's takes read "hard to judge".
    public static let reliableMaxWER = 0.20

    /// What the transcriber heard in the reference against the guide line it was sung to. `heard` nil = no
    /// speech model is installed: the check is skipped, honestly.
    public static func check(heard: String?) -> SungWordCheck {
        guard let heard else { return SungWordCheck(state: SungWordCheck.State.skipped) }
        let result = WordErrorRate.measure(reference: SingGuideLine.text, hypothesis: heard)
        let wer = result.wer ?? 0
        let verdict = wer <= SingWordCheck.clearWER ? SingWordCheck.Verdict.clear
            : wer <= SingWordCheck.someUnclearWER ? SingWordCheck.Verdict.someUnclear : SingWordCheck.Verdict.unclear
        return SungWordCheck(state: SungWordCheck.State.checked, wer: result.wer, heard: heard, verdict: verdict)
    }
}

// MARK: - Adding a voice: the checks, in Swift (no engine needed)

/// Why `sing.addVoice` did not save a voice: a stable code for the wire and the sentence the user reads.
public struct SingVoiceAddRefusal: Error, Equatable, LocalizedError {
    public var code: String
    public var sentence: String

    public init(code: String, sentence: String) {
        self.code = code
        self.sentence = sentence
    }

    public var errorDescription: String? { sentence }

    /// PROVISIONAL codes (design §6 row 8 names "the 9 clip-check reasons" but no codes); the sentences are
    /// §5.7's, exactly (`VoiceClipCheck.sentence(for:durationSeconds:)`).
    public static func code(for reason: VoiceClipCheckResult.Reason) -> String {
        switch reason {
        case .tooShort: return "singVoiceTooShort"
        case .tooLong: return "singVoiceTooLong"
        case .noVoice: return "singVoiceNoVoice"
        case .cutStart: return "singVoiceCutStart"
        case .cutEnd: return "singVoiceCutEnd"
        case .tooLoud: return "singVoiceTooLoud"
        case .noGap: return "singVoiceNoGap"
        case .noisy: return "singVoiceNoisy"
        case .guideLeak: return "singVoiceGuideLeak"
        }
    }

    public static func check(_ reason: VoiceClipCheckResult.Reason, durationSeconds: Double) -> SingVoiceAddRefusal {
        SingVoiceAddRefusal(code: code(for: reason),
                            sentence: VoiceClipCheck.sentence(for: reason, durationSeconds: durationSeconds))
    }

    /// PROVISIONAL sentence (no §5.7 row).
    public static func unreadable(_ detail: String) -> SingVoiceAddRefusal {
        SingVoiceAddRefusal(code: "singVoiceFileUnreadable",
                            sentence: "I couldn't read that recording as audio (\(detail)). "
                                + "Please use a WAV, AIFF, M4A or MP3 file.")
    }
}

/// `sing.addVoice`'s whole job (design §6 row 8, §3.7, §3.8): read the recording, run the clip check, measure
/// the range, label it with Route N, and save it. Pure Swift over the engine's pitch frames: no singing engine
/// is involved, so a voice can be added before the engine is even installed.
public enum SingVoicePreparation {

    /// §5.4 "Name: [My voice]".
    public static let defaultName = "My voice"
    /// Longest name kept; a longer one is cut (PROVISIONAL).
    public static let maxNameLength = 80

    /// - Parameters:
    ///   - source: the file to read.
    ///   - startSeconds/windowSeconds: the part of it to use (a clip's window; nil = to the file's end).
    ///   - detectPitch: SwiftF0 frames over a file from 0 for the given seconds, confidence 0.9 (the engine's
    ///     `detectPitch(inFileAt:…)`). It reads the SAVED reference, so every time in the labels is the
    ///     reference's own.
    ///   - guides: the two guide tunes for the leak check; nil = the bundled ones.
    public static func prepare(source: URL, startSeconds: Double = 0, windowSeconds: Double? = nil,
                               name: String?, kind: SingVoiceRecord.Source, sourceName: String?,
                               library: SingVoiceLibrary,
                               detectPitch: @Sendable (URL, Double) async throws -> [ClipPitchFrame],
                               guides: [SingGuideLine.Guide: RenderedAudio]? = nil,
                               now: Date = Date()) async throws -> SingVoiceRecord {
        let fileSeconds: Double
        do {
            fileSeconds = try SingVoiceAudioDecoder.durationSeconds(of: source)
        } catch {
            throw SingVoiceAddRefusal.unreadable(error.localizedDescription)
        }
        let available = max(0, fileSeconds - max(0, startSeconds))
        let seconds = min(available, windowSeconds ?? available)
        // The duration check is the check's FIRST judged reason (design §3.8's order), so a file outside 3–12 s
        // gets its sentence without decoding a whole song first.
        if seconds < VoiceClipCheck.durMin { throw SingVoiceAddRefusal.check(.tooShort, durationSeconds: seconds) }
        if seconds > VoiceClipCheck.durMax { throw SingVoiceAddRefusal.check(.tooLong, durationSeconds: seconds) }

        let recording: RenderedAudio
        do {
            recording = try SingVoiceAudioDecoder.decode(source, startSeconds: startSeconds,
                                                         durationSeconds: seconds)
        } catch {
            throw SingVoiceAddRefusal.unreadable(error.localizedDescription)
        }
        let mono = SingVoiceAudioDecoder.mono(recording)
        let rate = Int(recording.sampleRate.rounded())
        let duration = Double(mono.count) / recording.sampleRate

        try FileManager.default.createDirectory(at: library.root, withIntermediateDirectories: true)
        let staging = library.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }

        let reference = staging.appendingPathComponent(SingVoiceRecord.referenceFileName)
        try SingWAV.writeFloat32Mono(mono, sampleRate: rate, to: reference)
        let frames = try await detectPitch(reference, duration)

        let check = VoiceClipCheck.run(recording: recording, pitchFrames: frames, guides: guides)
        guard check.passed else {
            throw SingVoiceAddRefusal.check(check.reason ?? .noVoice, durationSeconds: duration)
        }
        guard let range = VoiceRangeFit.measure(frames: frames, samples: mono, sampleRate: recording.sampleRate)
        else { throw SingVoiceAddRefusal.check(.noVoice, durationSeconds: duration) }
        let onsets = VoiceReferenceLabeler.onsetStrength(samples: mono, sampleRate: recording.sampleRate,
                                                         frameTimes: frames.map(\.timeSeconds))
        let labels = VoiceReferenceLabeler.label(frames: frames, onsetStrength: onsets, durationSeconds: duration,
                                                 registerCheck: range.octaveCheck)
        guard !labels.notes.isEmpty else { throw SingVoiceAddRefusal.check(.noVoice, durationSeconds: duration) }

        let sha = SHA256.hash(data: try Data(contentsOf: reference)).map { String(format: "%02x", $0) }.joined()
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let record = SingVoiceRecord(
            id: SingVoiceLibrary.newID(),
            name: trimmed.isEmpty ? defaultName : String(trimmed.prefix(maxNameLength)),
            createdAt: now, durationS: duration, sampleRate: rate, referenceSha256: sha, source: kind,
            sourceName: sourceName, range: range, labels: labels, check: check)
        try library.commit(staging: staging, record: record)
        committed = true
        return record
    }
}
