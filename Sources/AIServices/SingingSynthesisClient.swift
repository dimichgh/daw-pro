import Foundation

/// Thin typed client for the singing sidecar's render call (item p2-sing-c — design
/// `docs/design/2026-09-27-p2-sing-integration.md` §2.4, port 8004). Coded directly against
/// `scripts/sing/singlib/schema.py` (the request) and `scripts/sing/singlib/refusals.py` (the
/// error table), not guessed.
///
/// Kept separate from `SingingSidecarManager` (process lifecycle: spawn, health, stop, the
/// watchdog) — the same split `ACEStepClient`/`SidecarManager` and
/// `VoiceConversionClient`/`VoiceConversionManager` already use. `POST /v1/sing/phrase` is the
/// only call this type makes; `GET /health` stays the manager's own concern (its `status()`
/// already needs richer boot-progress classification than a render client would ever use).
///
/// One request renders one phrase, synchronously — the facade holds one inference lock and the
/// app never sends two at once (design §2.4); this type does not queue or retry, that is
/// `SingJobCoordinator`'s job (item p2-sing-e).
public protocol SingingSynthesizing: Sendable {
    func renderPhrase(_ request: SingingPhraseRequest) async throws -> SingingRenderResult
}

// MARK: - The request (design §2.4's exact JSON shape)

/// One note in `phrase.notes` or a prompt window's `notes` — unit-relative or window-relative
/// seconds, per the field it is used in.
public struct SingingPhraseNote: Sendable, Equatable {
    public var startS: Double
    public var endS: Double
    /// MIDI note number, 1-127 (the facade's own range; 0 is never a valid sung pitch here).
    public var midi: Int

    public init(startS: Double, endS: Double, midi: Int) {
        self.startS = startS
        self.endS = endS
        self.midi = midi
    }

    var jsonObject: [String: Any] { ["startS": startS, "endS": endS, "midi": midi] }
}

/// One word in `phrase.words`, naming the (contiguous, ascending) notes it is sung on.
public struct SingingPhraseWord: Sendable, Equatable {
    public var text: String
    public var noteIndices: [Int]
    /// The language the facade sings this word in (facadeVersion 2's per-word `lang`, design
    /// `docs/design/2026-10-06-p2-sing-expansion.md` §7.2; `scripts/sing/singlib/langs.py`): `"zh"` (Mandarin) or
    /// `"yue"` (Cantonese), each word one Chinese character or one tonal pinyin/jyutping syllable. nil is English,
    /// the facade's default, and is never written: an English word's JSON is exactly the v1 word's.
    public var lang: String?

    public init(text: String, noteIndices: [Int]) {
        self.text = text
        self.noteIndices = noteIndices
    }

    /// A word sung in `lang` (nil: English). A separate init, so the old one's symbol stays (the tree's rule for
    /// additive fields, `SingWord.init(text:typed:noteIndices:language:)`).
    public init(text: String, noteIndices: [Int], lang: String?) {
        self.text = text
        self.noteIndices = noteIndices
        self.lang = lang
    }

    /// `lang` only when set: under facadeVersion 1 the facade refuses it as an unknown key.
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["text": text, "noteIndices": noteIndices]
        if let lang { object["lang"] = lang }
        return object
    }
}

/// One note of an OWN voice's prompt window (design §2.4's `voice.prompt.notes`) — Route N's
/// labels (`VoiceReferenceLabeler`, item p2-sing-d3), window-relative seconds.
public struct SingingPromptNote: Sendable, Equatable {
    public var startS: Double
    public var endS: Double
    public var midi: Int
    public var word: String
    /// True when this note is the tail of a word that started on an earlier note (a tie/melisma
    /// continuation) — schema.py's `continues`.
    public var continues: Bool

    public init(startS: Double, endS: Double, midi: Int, word: String, continues: Bool) {
        self.startS = startS
        self.endS = endS
        self.midi = midi
        self.word = word
        self.continues = continues
    }

    var jsonObject: [String: Any] {
        ["startS": startS, "endS": endS, "midi": midi, "word": word, "continues": continues]
    }
}

/// Which voice sings the phrase: the built-in voice by id, or an own voice with its reference
/// audio, integrity hash and Route N prompt labels (design §2.4).
public enum SingingVoiceReference: Sendable, Equatable {
    case builtin(id: String)
    case own(
        id: String, referencePath: String, referenceSha256: String,
        windowStartS: Double, windowEndS: Double, notes: [SingingPromptNote],
        promptLabelOffset: Int = 0
    )

    var jsonObject: [String: Any] {
        switch self {
        case .builtin(let id):
            return ["id": id]
        case .own(
            let id, let referencePath, let referenceSha256, let windowStartS, let windowEndS,
            let notes, let promptLabelOffset
        ):
            return [
                "id": id,
                "referencePath": referencePath,
                "referenceSha256": referenceSha256,
                "prompt": [
                    "windowStartS": windowStartS,
                    "windowEndS": windowEndS,
                    "notes": notes.map(\.jsonObject),
                ],
                "promptLabelOffset": promptLabelOffset,
            ]
        }
    }
}

/// One `POST /v1/sing/phrase` request, built to the facade's own schema (`schema.py`'s
/// `TOP_KEYS`) byte-for-byte: unknown keys are refused there exactly like the app's own
/// `rejectUnknownKeys`, so this type must never grow an extra field without the facade growing a
/// matching one first.
public struct SingingPhraseRequest: Sendable, Equatable {
    /// The version every request that uses nothing new sends, and what `/health` reports (`schema.py`'s
    /// `FACADE_VERSION`, unchanged by v2: design §7.5).
    public static let facadeVersion = 1
    /// The version a request needs once a word carries a `lang` (`schema.py`'s `FACADE_VERSIONS`, design §7.1).
    public static let languageFacadeVersion = 2

    /// The `facadeVersion` this body sends (design §7.1, "the client sends facadeVersion 2 ONLY when the request
    /// carries a v2 key"): 2 when at least one word has a `lang`, else 1. So an English phrase's body, and the
    /// phrase-cache key that hashes it, stay byte for byte what they were (§9.2 S5). `control` is never sent: v2
    /// makes it optional with today's "score" as its default.
    public var bodyFacadeVersion: Int {
        words.contains { $0.lang != nil } ? Self.languageFacadeVersion : Self.facadeVersion
    }

    public var voice: SingingVoiceReference
    public var notes: [SingingPhraseNote]
    public var words: [SingingPhraseWord]
    /// Silence before the first note and after the last, seconds (design §2.4: 0.24 s in
    /// production). 0...5 s at the facade (`schema.py`'s `MAX_GUARD_S`).
    public var leadS: Double
    public var trailS: Double
    /// Required, never defaulted (`scripts/sing`'s own deviation 10) — the facade refuses a
    /// request missing any of `seed`/`nSteps`/`cfg`.
    public var seed: UInt64
    public var nSteps: Int
    public var cfg: Double
    /// An absolute path under one of the facade's allowed roots, ending in `.wav`.
    public var outputPath: String
    public var outputSampleRate: Int

    public init(
        voice: SingingVoiceReference, notes: [SingingPhraseNote], words: [SingingPhraseWord],
        leadS: Double, trailS: Double, seed: UInt64, nSteps: Int, cfg: Double,
        outputPath: String, outputSampleRate: Int
    ) {
        self.voice = voice
        self.notes = notes
        self.words = words
        self.leadS = leadS
        self.trailS = trailS
        self.seed = seed
        self.nSteps = nSteps
        self.cfg = cfg
        self.outputPath = outputPath
        self.outputSampleRate = outputSampleRate
    }

    func jsonObject() -> [String: Any] {
        [
            "facadeVersion": bodyFacadeVersion,
            "voice": voice.jsonObject,
            "phrase": ["notes": notes.map(\.jsonObject), "words": words.map(\.jsonObject)],
            "leadS": leadS,
            "trailS": trailS,
            "seed": seed,
            "nSteps": nSteps,
            "cfg": cfg,
            "outputPath": outputPath,
            "outputSampleRate": outputSampleRate,
        ]
    }
}

// MARK: - The response

/// A render's facts, as `POST /v1/sing/phrase` returns them on success. Only the fields common to
/// BOTH the stub (`stub_server.py`) and the real facade (`singlib/engine.py`) are required; the
/// real facade's extras (`outputSha256`, `pcmSha256`, `inferSeconds`, `rtf`, …) are optional so
/// this type never fails to decode a stub response for want of a field only the real engine sends.
public struct SingingRenderResult: Sendable, Equatable {
    public var outputPath: String
    public var sampleRate: Int
    public var channels: Int
    public var frames: Int
    public var durationS: Double
    public var peak: Double
    public var rms: Double
    /// The facade's OWN NaN/Inf check on the written bytes. `false` on every successful response
    /// — a `true` here would be the facade contradicting its own guarantee (the L1 gate, design
    /// §7.1, re-checks the written WAV independently rather than trusting this field alone).
    public var nonFinite: Bool
    public var samples24k: Int?
    public var seed: UInt64?
    public var nSteps: Int?
    public var cfg: Double?
    /// Real-facade only.
    public var outputSha256: String?
    public var pcmSha256: String?
    public var inferSeconds: Double?
    public var rtf: Double?
    public var mpsDriverBytes: UInt64?

    init?(json: [String: Any]) {
        guard
            let outputPath = json["outputPath"] as? String,
            let sampleRate = (json["sampleRate"] as? NSNumber)?.intValue,
            let channels = (json["channels"] as? NSNumber)?.intValue,
            let frames = (json["frames"] as? NSNumber)?.intValue,
            let durationS = (json["durationS"] as? NSNumber)?.doubleValue,
            let peak = (json["peak"] as? NSNumber)?.doubleValue,
            let rms = (json["rms"] as? NSNumber)?.doubleValue,
            let nonFinite = json["nonFinite"] as? Bool
        else { return nil }
        self.outputPath = outputPath
        self.sampleRate = sampleRate
        self.channels = channels
        self.frames = frames
        self.durationS = durationS
        self.peak = peak
        self.rms = rms
        self.nonFinite = nonFinite
        self.samples24k = (json["samples24k"] as? NSNumber)?.intValue
        self.seed = (json["seed"] as? NSNumber)?.uint64Value
        self.nSteps = (json["nSteps"] as? NSNumber)?.intValue
        self.cfg = (json["cfg"] as? NSNumber)?.doubleValue
        self.outputSha256 = json["outputSha256"] as? String
        self.pcmSha256 = json["pcmSha256"] as? String
        self.inferSeconds = (json["inferSeconds"] as? NSNumber)?.doubleValue
        self.rtf = (json["rtf"] as? NSNumber)?.doubleValue
        self.mpsDriverBytes = (json["mpsDriverBytes"] as? NSNumber)?.uint64Value
    }
}

// MARK: - Errors (design §2.4's refusal table, verbatim)

/// One case per `singlib/refusals.py` code, plus the two routing answers and three transport-level
/// failures this client itself can hit. `message` is always the facade's own sentence, verbatim —
/// `scripts/sing`'s own messages already name the offending word/note/path, so re-wording them
/// here would only risk losing information a caller needs to act.
public enum SingingFacadeError: Error, LocalizedError, Sendable, Equatable {
    case badRequest(String)
    case phraseTooLong(String)
    case notesOverlap(String)
    case notesUnsorted(String)
    case wordsDoNotCoverNotes(String)
    case emptyWord(String)
    case unknownPhone(String)
    case pathNotAllowed(String)
    case voiceNotFound(String)
    case referenceChanged(String)
    case badReference(String)
    case loading(String)
    case nonFinite(String)
    case inferenceFailed(String)
    case notFound(String)
    case methodNotAllowed(String)
    /// The facade answered with a refusal shape this client does not recognise — a facade/client
    /// version skew, never silently swallowed as a generic failure.
    case unrecognizedRefusal(status: Int, code: String?, message: String)
    /// The request never reached the facade (connection refused, timeout, DNS, TLS, …) — most
    /// often "the sidecar is not running"; `SingingSidecarManager.status()` is the place to check
    /// why.
    case transport(String)
    /// A 2xx response whose body is not the expected JSON shape.
    case malformedResponse(String)

    static func map(code: String?, status: Int, message: String) -> SingingFacadeError {
        switch code {
        case "badRequest": return .badRequest(message)
        case "phraseTooLong": return .phraseTooLong(message)
        case "notesOverlap": return .notesOverlap(message)
        case "notesUnsorted": return .notesUnsorted(message)
        case "wordsDoNotCoverNotes": return .wordsDoNotCoverNotes(message)
        case "emptyWord": return .emptyWord(message)
        case "unknownPhone": return .unknownPhone(message)
        case "pathNotAllowed": return .pathNotAllowed(message)
        case "voiceNotFound": return .voiceNotFound(message)
        case "referenceChanged": return .referenceChanged(message)
        case "badReference": return .badReference(message)
        case "loading": return .loading(message)
        case "nonFinite": return .nonFinite(message)
        case "inferenceFailed": return .inferenceFailed(message)
        case "notFound": return .notFound(message)
        case "methodNotAllowed": return .methodNotAllowed(message)
        default: return .unrecognizedRefusal(status: status, code: code, message: message)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .badRequest(let m): return "The singing engine rejected the request: \(m)"
        case .phraseTooLong(let m): return "This phrase is too long for one render: \(m)"
        case .notesOverlap(let m): return "The notes overlap: \(m)"
        case .notesUnsorted(let m): return "The notes are not in order: \(m)"
        case .wordsDoNotCoverNotes(let m): return "The words don't line up with the notes: \(m)"
        case .emptyWord(let m): return "One of the words is empty: \(m)"
        case .unknownPhone(let m): return "One of the words can't be sung: \(m)"
        case .pathNotAllowed(let m): return "That file location isn't allowed: \(m)"
        case .voiceNotFound(let m): return "That singing voice wasn't found: \(m)"
        case .referenceChanged(let m): return "The voice recording changed since it was checked: \(m)"
        case .badReference(let m): return "The voice recording can't be used: \(m)"
        case .loading(let m): return "The singing engine is still starting up: \(m)"
        case .nonFinite(let m): return "The render came out corrupted: \(m)"
        case .inferenceFailed(let m): return "The singing engine failed to render: \(m)"
        case .notFound(let m): return "Unknown singing-engine endpoint: \(m)"
        case .methodNotAllowed(let m): return "Wrong request method for the singing engine: \(m)"
        case .unrecognizedRefusal(let status, let code, let m):
            return "The singing engine refused the request with an unrecognised code "
                + "(\(code ?? "none"), HTTP \(status)): \(m)"
        case .transport(let m):
            return "Could not reach the singing engine \u{2014} \(m). Check sing.sidecarStatus."
        case .malformedResponse(let m):
            return "The singing engine answered unexpectedly: \(m)"
        }
    }
}

// MARK: - The client

public struct SingingSynthesisClient: SingingSynthesizing {
    public var baseURL: URL
    public var timeoutSeconds: Double

    public init(baseURL: URL, timeoutSeconds: Double = 60) {
        self.baseURL = baseURL
        self.timeoutSeconds = timeoutSeconds
    }

    public func renderPhrase(_ request: SingingPhraseRequest) async throws -> SingingRenderResult {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/sing/phrase"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = timeoutSeconds
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: request.jsonObject())

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw SingingFacadeError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SingingFacadeError.transport("the response was not HTTP")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let body = parsed as? [String: Any] else {
            throw SingingFacadeError.malformedResponse(
                "HTTP \(http.statusCode) with a body that is not a JSON object")
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = body["error"] as? String
            let message = (body["message"] as? String) ?? "HTTP \(http.statusCode), no message"
            throw SingingFacadeError.map(code: code, status: http.statusCode, message: message)
        }
        guard let result = SingingRenderResult(json: body) else {
            throw SingingFacadeError.malformedResponse(
                "HTTP 200 body is missing one of the required fields (outputPath/sampleRate/"
                + "channels/frames/durationS/peak/rms/nonFinite)")
        }
        return result
    }
}
