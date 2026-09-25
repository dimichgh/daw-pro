import Foundation

// m34-g — PLAYBOX: the domain half of "the AI shows you what to play".
//
// ═══ WHAT THIS FILE IS FOR, AND WHY IT IS IN `DAWCore` ═══
//
// The user's words: *"it would be nice to have a playbox mode where AI would
// pre-generate next series of lights to play and record (activate with mode
// switch)."*
//
// ⭐⭐⭐ **THE POINT IS NOT TECHNICAL. IT INVERTS THE USUAL AI-MUSIC
// RELATIONSHIP: the AI does not produce the performance — it produces the
// INVITATION, and the human produces the performance.** The take is genuinely
// played, on the keys, through the same live capture path as any other take.
// Nothing in this file, and nothing downstream of it, ever writes a note on the
// user's behalf. For a non-musician with no MIDI hardware that is the whole
// difference between owning the music and receiving it.
//
// Two things live here rather than in the app:
//
//   1. **The VALIDATOR.** A language model's answer is untrusted input. It is
//      sanitised into scale degrees before anything lights up.
//   2. **The LOCAL VARIATION PATH — the answer to "what happens with no API key
//      configured".** A feature that is dead without a key is dead for anyone
//      who has not set one up, and this app ships `ChordProgressionLibrary`
//      already. So Playbox ALWAYS produces something; what changes is the
//      PROVENANCE, and the surface states it.
//
// ⛔⛔ **"THE AI WROTE THIS" AND "WE PICKED A STOCK PROGRESSION" ARE DIFFERENT
// CLAIMS AND ONLY ONE OF THEM IS TRUE AT A TIME.** `PlayboxProvenance` is
// therefore returned by every path, is not optional, and the strip paints an
// AI-authored sequence violet (*"violet always means AI-generated"*,
// docs/DESIGN-LANGUAGE.md) and a local one in the neutral hierarchy.
//
// ⚠️ **CHORDS, NOT MELODY — SAID PLAINLY RATHER THAN HALF-DONE.** A melody needs
// a different light grammar (one key at a time) and the 17-key span becomes a
// real constraint rather than a comfortable one. Out of scope for m34-g.

/// Which of the two generators produced a Playbox sequence.
public enum PlayboxProvenanceKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// A configured Anthropic/OpenAI model answered.
    case ai
    /// The local, deterministic variation over `ChordProgressionLibrary` — used
    /// when no provider is configured, and when a provider answered with
    /// something that did not survive `PlayboxProgression.validate`.
    case local
}

/// **WHERE THE LIGHTS CAME FROM.** Carried with every generated sequence and
/// shown in the strip's chrome, because the two claims are not interchangeable.
public struct PlayboxProvenance: Sendable, Codable, Equatable {
    public let kind: PlayboxProvenanceKind
    /// For `.ai`, the provider id that answered (`"anthropic"` / `"openai"`) —
    /// **never key material, and never a model's raw text.** For `.local`, the
    /// library progression the variation was derived from.
    public let detail: String
    /// Why the local path was taken, when it was — `nil` for `.ai`. Shown as a
    /// tooltip so the user can tell "you have no key" from "the model's answer
    /// was unusable" without reading a log.
    public let reason: String?

    public init(kind: PlayboxProvenanceKind, detail: String, reason: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.reason = reason
    }

    public var isAI: Bool { kind == .ai }

    /// One short line for the strip. Beginner-readable (Rule 6): it names the
    /// author, not the mechanism.
    ///
    /// ⚠️⚠️ **THE `.local` LINE MUST SAY "VARIATION", AND THAT IS NOT A WORDING
    /// PREFERENCE — IT WAS A MEASURED HONESTY DEFECT.** `localVariation` ROTATES
    /// the library progression and substitutes one relative (V↔iii, I↔vi, IV↔ii),
    /// so the lights are genuinely NOT the named preset. The first version read
    /// *"From the built-in library (12-Bar Blues)"* while lighting a **iii** —
    /// a degree 12-bar blues does not contain — **directly beside a `12-Bar
    /// Blues` PRESET CHIP that lights something different under the same name.**
    /// Two different things wearing one label is this tree's characteristic
    /// failure mode, and here it was on screen. `detail` deliberately stays the
    /// BARE source name (`minorRequestStaysMinor` checks the source's mode
    /// through it); the relationship is stated here instead.
    public var summary: String {
        switch kind {
        case .ai: return "Written by AI (\(detail))"
        case .local: return "Built-in library — a variation on \(detail)"
        }
    }
}

/// What Playbox is being asked for: the project's own musical facts plus a
/// length.
///
/// ⚠️ **KEY, MODE AND TEMPO ARE INPUTS, NOT DECORATION.** `macro_song_skeleton`
/// establishes all three for a project, and a Playbox sequence that ignored them
/// would fight the arrangement the user already has.
public struct PlayboxRequest: Sendable, Equatable {
    /// Tonic as a pitch class, 0 = C. Carried so a prompt can NAME the key; the
    /// degrees themselves are key-agnostic.
    public var keyTonic: Int
    /// Major or natural minor. **The generated sequence is constrained to
    /// this** — see `PlayboxProgression.plan` for why that is load-bearing.
    public var keyMode: KeyMode
    /// Project tempo, if the caller has one.
    public var tempoBPM: Double?
    /// The section the playhead sits in (`"Chorus"`), if the project has markers.
    public var sectionName: String?
    /// How many chords to produce — one per bar.
    public var bars: Int
    /// Optional free-text style hint (`"dreamy indie"`).
    public var style: String?

    public init(keyTonic: Int = 0, keyMode: KeyMode = .major, tempoBPM: Double? = nil,
                sectionName: String? = nil, bars: Int = 4, style: String? = nil) {
        self.keyTonic = keyTonic
        self.keyMode = keyMode
        self.tempoBPM = tempoBPM
        self.sectionName = sectionName
        self.bars = bars
        self.style = style
    }
}

/// A finished Playbox sequence: the degrees to light, a name, and who wrote it.
public struct PlayboxPlan: Sendable, Codable, Equatable {
    /// 1-based scale degrees, in playing order — exactly `ChordProgressionPreset
    /// .degrees`' vocabulary, so the existing lit-key surface consumes it
    /// unchanged.
    public let degrees: [Int]
    /// A short human name for the sequence, shown on the Playbox chip.
    public let name: String
    public let provenance: PlayboxProvenance

    public init(degrees: [Int], name: String, provenance: PlayboxProvenance) {
        self.degrees = degrees
        self.name = name
        self.provenance = provenance
    }
}

public enum PlayboxProgression {

    /// How many chords a Playbox sequence may contain. Two is the shortest thing
    /// that is a progression at all; sixteen is four four-bar phrases, past which
    /// a look-ahead queue stops being a look-ahead.
    public static let barsRange: ClosedRange<Int> = 2...16

    /// Diatonic scale degrees. Playbox is diatonic by construction — the chord
    /// row has exactly seven degrees and every one of them is playable, so a
    /// borrowed chord would light a key that cannot sound it.
    public static let degreeRange: ClosedRange<Int> = 1...7

    /// Clamp a requested length into `barsRange`.
    public static func clampBars(_ bars: Int) -> Int {
        min(max(bars, barsRange.lowerBound), barsRange.upperBound)
    }

    // MARK: - The validator

    /// **SANITISE UNTRUSTED OUTPUT BEFORE ANYTHING LIGHTS UP.**
    ///
    /// ⛔⛔ **A LANGUAGE MODEL'S ANSWER IS INPUT, NOT DATA.** It can be empty, can
    /// contain `0` or `8` or `-1`, can be one chord long or two hundred. Every
    /// one of those would either crash a modulo, paint nothing, or light a key
    /// that does not exist. This returns `nil` for anything it cannot vouch for
    /// and the caller falls back to the local path — the same treatment a missing
    /// key gets, because from the user's chair they are the same event: *"the AI
    /// did not write this one."*
    ///
    /// - Returns: the degrees, truncated to `barsRange.upperBound`, or `nil` if
    ///   the input is not a usable diatonic progression.
    public static func validate(degrees: [Int]) -> [Int]? {
        guard degrees.count >= barsRange.lowerBound else { return nil }
        guard degrees.allSatisfy({ degreeRange.contains($0) }) else { return nil }
        // ⚠️ A sequence of ONE repeated degree is arithmetically valid and
        // musically nothing — it would cue the same chord forever and make the
        // look-ahead queue a single cell. Rejected so the fallback runs.
        guard Set(degrees).count >= 2 else { return nil }
        return Array(degrees.prefix(barsRange.upperBound))
    }

    /// Parses degrees out of a model's free text: accepts a bare JSON array
    /// (`[1,5,6,4]`), a JSON object with a `degrees` key, or a loose comma/space
    /// separated run of integers. Roman numerals are deliberately NOT parsed —
    /// the prompt asks for integers, and a numeral parser would be a second,
    /// silently-diverging opinion about what `vi` means in a minor key.
    ///
    /// - Returns: validated degrees, or `nil`.
    public static func parseDegrees(fromModelText text: String) -> [Int]? {
        if let data = text.data(using: .utf8) {
            if let array = try? JSONSerialization.jsonObject(with: data) as? [Int] {
                if let ok = validate(degrees: array) { return ok }
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let array = object["degrees"] as? [Int],
               let ok = validate(degrees: array) {
                return ok
            }
        }
        // The loose path: pull the first bracketed run out of prose, else every
        // integer in the text. Bounded to the first 200 numbers so a pathological
        // answer cannot make this expensive.
        let source: String
        if let open = text.firstIndex(of: "["), let close = text[open...].firstIndex(of: "]") {
            source = String(text[text.index(after: open)..<close])
        } else {
            source = text
        }
        let numbers = source
            .split(whereSeparator: { !$0.isNumber })
            .prefix(200)
            .compactMap { Int($0) }
        return validate(degrees: Array(numbers))
    }

    // MARK: - The local variation path

    /// **THE FALLBACK, AND IT IS A REAL GENERATOR RATHER THAN A CONSTANT.**
    ///
    /// Deterministic in `seed`, so the same seed gives the same lights (a
    /// generator a test cannot pin is a generator nobody can debug), and varied
    /// enough that pressing the button twice is not a do-nothing control:
    ///
    ///   1. Pick a library progression **in the requested mode**.
    ///   2. **Rotate it.** This is not a trick — the file next door records that
    ///      Four Chords, Doo-Wop and Pop-Punk are literally rotations of the same
    ///      four chords, and each is famous in its own right.
    ///   3. **Substitute one chord for its diatonic relative** (I↔vi, IV↔ii,
    ///      V↔iii — the textbook relative pairs), which keeps every chord inside
    ///      the seven the row can play.
    ///   4. Loop or truncate to the requested length.
    ///
    /// ⚠️ **ALWAYS exactly `clampBars(request.bars)` chords, all on the row, at
    /// least two of them different** — a fallback that can fail is not a
    /// fallback. Step 3's guard sees the WHOLE sequence, but only the first
    /// `bars` chords light, and at two bars a swap beside its own relative
    /// collapses them (Doo-Wop `[1, 6, …]` → `[6, 6]`). A cut `validate` refuses
    /// falls back to the same rotation without the swap, then to I–V–vi–IV, each
    /// cut to length — never the bare four-chord constant, which once answered
    /// a two-bar request with four.
    public static func localVariation(request: PlayboxRequest, seed: UInt64) -> PlayboxPlan {
        var rng = SplitMix64(seed: seed)
        let candidates = ChordProgressionLibrary.all.filter { $0.mode == request.keyMode }
        // ⚠️ NOT `!.isEmpty ? … : ChordProgressionLibrary.all[0]` — if a future
        // mode ever has no library entry this must still produce a progression,
        // and the tonic-anchored default below is one.
        let pool = candidates.isEmpty ? ChordProgressionLibrary.all : candidates
        let base: [Int]
        let sourceName: String
        if pool.isEmpty {
            base = [1, 5, 6, 4]
            sourceName = "I–V–vi–IV"
        } else {
            let preset = pool[Int(rng.next(upperBound: UInt64(pool.count)))]
            base = preset.degrees
            sourceName = preset.name
        }

        var degrees = base
        if degrees.count > 1 {
            let rotation = Int(rng.next(upperBound: UInt64(degrees.count)))
            degrees = Array(degrees[rotation...] + degrees[..<rotation])
        }
        // Kept for the fallback below: the swap can collapse a short cut.
        let rotated = degrees

        // The relative substitution, at one seeded index.
        let relatives: [Int: Int] = [1: 6, 6: 1, 4: 2, 2: 4, 5: 3, 3: 5]
        if degrees.count > 1 {
            let index = Int(rng.next(upperBound: UInt64(degrees.count)))
            if let swapped = relatives[degrees[index]] {
                var trial = degrees
                trial[index] = swapped
                if Set(trial).count >= 2 { degrees = trial }
            }
        }

        let bars = clampBars(request.bars)

        // `validate` is applied to the LOCAL path too, deliberately: one gate for
        // "is this a usable progression", not one for the model and a different,
        // more trusting one for ourselves.
        let final = validate(degrees: fit(degrees, to: bars))
            ?? validate(degrees: fit(rotated, to: bars))
            ?? fit([1, 5, 6, 4], to: bars)
        return PlayboxPlan(
            degrees: final,
            name: "\(sourceName) variation",
            provenance: PlayboxProvenance(kind: .local, detail: sourceName))
    }

    /// Step 4: loop or truncate `sequence` to exactly `bars` chords.
    private static func fit(_ sequence: [Int], to bars: Int) -> [Int] {
        var out: [Int] = []
        while out.count < bars { out.append(sequence[out.count % sequence.count]) }
        return out
    }

    // MARK: - The prompt

    /// The system prompt for the AI path. Lives here, next to the validator, so
    /// **what we ask for and what we accept are written in one place** — the
    /// record-says-X-source-says-Y shape this tree keeps closing.
    public static func systemPrompt() -> String {
        """
        You are a music-theory assistant inside a DAW. The user is a BEGINNER \
        with no MIDI keyboard who is about to PLAY the chords you choose, one \
        per bar, on a computer keyboard. Choose a chord progression that is \
        idiomatic, singable, and easy to play.

        Answer with a JSON array of integers and NOTHING else — no prose, no \
        code fence, no Roman numerals. Each integer is a 1-based DIATONIC SCALE \
        DEGREE from 1 to 7 in the key the user names (1 = tonic). Example for \
        I-V-vi-IV: [1,5,6,4]

        Rules: stay strictly diatonic (1-7 only). Use at least two different \
        degrees. Return exactly the number of chords requested.
        """
    }

    /// The user prompt: the project's real key, mode, tempo and section, so the
    /// answer fits the arrangement rather than an imaginary one.
    public static func userPrompt(_ request: PlayboxRequest) -> String {
        var lines = ["Key: \(keyName(request)) (\(request.keyMode.displayName))"]
        if let tempo = request.tempoBPM {
            lines.append("Tempo: \(Int(tempo.rounded())) BPM")
        }
        if let section = request.sectionName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !section.isEmpty {
            lines.append("Section: \(section)")
        }
        if let style = request.style?.trimmingCharacters(in: .whitespacesAndNewlines),
           !style.isEmpty {
            lines.append("Style: \(style)")
        }
        lines.append("Chords wanted: \(clampBars(request.bars))")
        return lines.joined(separator: "\n")
    }

    /// The tonic's name. Reads the repo's SOLE pitch-class table rather than
    /// carrying a second copy of it.
    public static func keyName(_ request: PlayboxRequest) -> String {
        let names = KeyEstimate.pitchClassesSharp
        let index = ((request.keyTonic % names.count) + names.count) % names.count
        return names[index]
    }
}

/// A tiny deterministic PRNG so the local path is reproducible in a test.
///
/// ⚠️ **NOT `SystemRandomNumberGenerator`, and not `Int.random`.** A fallback
/// whose output cannot be pinned is a fallback whose regressions are invisible;
/// this is the standard SplitMix64 finaliser, twelve lines, no dependency.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform-enough in `0..<upperBound`; `0` for an empty range.
    mutating func next(upperBound: UInt64) -> UInt64 {
        guard upperBound > 0 else { return 0 }
        return next() % upperBound
    }
}
