import DAWCore
import Foundation

/// What singing can do on this Mac, for `sing.capabilities` (p2-sing-x7, design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §6.9). Works with the engine DOWN: nothing here starts, probes or
/// installs anything.
///
/// ## One home per fact
///
/// - **The languages** come from `LyricLanguage` (DAWCore), the ONE list of codes lyrics can be sung in: English
///   (`LyricLanguage.english`) plus `LyricLanguage.chinese`, each kept only while `LyricLanguage.isSupported` says so.
///   Never a parse of the facade's `langs.py` and never a third list. The facade's own list (its `/health`
///   `capabilities.languages`) is held equal to this one by `SingCapabilitiesTests`' drift gate against the stub.
/// - **The engine's version facts** come from `install.json` through `SingEngineFiles.runtimeFacts()` (the one
///   reader of that marker) and `pins.env`'s `SCRIPTS_VERSION` through `SingEngineFiles.pin(_:)`. They are REPORTED,
///   never compared here.
/// - **Whether the installed engine is too old** is the sidecar manager's one rule (`SingingSidecarManager`'s
///   `needsUpdate` state: the install's lock hash against the shipped lock). The caller passes that state in; a
///   language other than English then reads `needsEngineUpdate: true` (design §6.7 row 5, "This language needs a
///   newer singing engine"). English never does: the oldest engine sings it.
public struct SingCapabilities: Equatable, Sendable {

    /// One language lyrics can be sung in.
    public struct Language: Equatable, Sendable {
        /// The code `clip.setLyrics {language}` takes (`"en"` for English, which is stored as no code).
        public var code: String
        /// The picker's name (design §14 "Language").
        public var name: String
        /// `"supported"` or `"experimental"` (design §6.9). Every language this build offers is supported: Spanish,
        /// the one experimental language, is out of this build.
        public var status: String
        /// True when the installed engine must be updated before it can sing this language.
        public var needsEngineUpdate: Bool
    }

    /// The installed engine's version facts, as `install.json` and the shipped `pins.env` record them.
    public struct Engine: Equatable, Sendable {
        /// An install marker exists (an install that never finished writes none).
        public var installed: Bool
        /// The marker's `scriptsVersion`; nil when absent.
        public var scriptsVersion: Int?
        /// The `SCRIPTS_VERSION` this app ships (`pins.env`); nil when it cannot be read.
        public var shippedScriptsVersion: Int?
        /// The sidecar manager's verdict: the install is out of date (`sing.sidecarStatus` state `needsUpdate`).
        public var needsUpdate: Bool
    }

    public var languages: [Language]
    /// The singing-style choices `clip.setSingStyle` takes (design §5.6), in the Expression card's order.
    public var vibratoChoices: [String]
    public var airRange: ClosedRange<Double>
    /// The most harmony parts one take can carry (design §4.7 `parts` "max 3", §14 "You can add up to 3 harmony
    /// parts."). PROVISIONAL home: no constant existed in the tree when this was written; the render's `parts`
    /// (x7b) should read this one.
    public var maxParts: Int
    /// nil when this session has no singing engine wired in (a headless control session).
    public var engine: Engine?

    /// §14's part cap.
    public static let maxHarmonyParts = 3

    /// Every language this build can sing, in the picker's order, with no engine verdict (`needsEngineUpdate`
    /// false): the answer for a session with no engine wired in.
    public static func languages(engineNeedsUpdate: Bool) -> [Language] {
        ([LyricLanguage.english] + LyricLanguage.chinese).filter { LyricLanguage.isSupported($0) }.map { code in
            Language(code: code, name: displayName(code), status: "supported",
                     needsEngineUpdate: engineNeedsUpdate && code != LyricLanguage.english)
        }
    }

    /// The picker's names (design §14 "Language"). Unknown codes read as themselves: a name never adds or removes a
    /// language, `LyricLanguage` does.
    public static func displayName(_ code: String) -> String {
        switch code {
        case LyricLanguage.english: return "English"
        case LyricLanguage.mandarin: return "Chinese (Mandarin)"
        case LyricLanguage.cantonese: return "Chinese (Cantonese)"
        default: return code
        }
    }

    /// The capabilities for a session: `files` nil (no engine wired in) gives `engine: nil` and no update verdict.
    /// `engineNeedsUpdate` is the manager's own state (`.needsUpdate`), read by the caller.
    public static func read(files: SingEngineFiles?, engineNeedsUpdate: Bool) -> SingCapabilities {
        var engine: Engine?
        if let files {
            let facts = files.runtimeFacts()
            engine = Engine(installed: facts != nil, scriptsVersion: facts?.scriptsVersion,
                            shippedScriptsVersion: files.pin("SCRIPTS_VERSION").flatMap { Int($0) },
                            needsUpdate: engineNeedsUpdate)
        }
        return SingCapabilities(
            languages: languages(engineNeedsUpdate: engine != nil && engineNeedsUpdate),
            vibratoChoices: SingStyle.Vibrato.allCases.map(\.rawValue),
            airRange: SingStyle.airRange,
            maxParts: maxHarmonyParts,
            engine: engine)
    }
}
