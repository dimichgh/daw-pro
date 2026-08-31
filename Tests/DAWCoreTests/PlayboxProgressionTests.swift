import Foundation
import Testing
@testable import DAWCore

/// m34-g — **PLAYBOX'S DOMAIN HALF: the validator and the local fallback.**
///
/// ⛔⛔ The validator is the only thing standing between a language model's free
/// text and a surface that lights physical keys. Every case below is an answer a
/// model can and does give.
@Suite("Playbox progression (m34-g)")
struct PlayboxProgressionTests {

    // MARK: - The validator

    @Test("a well-formed diatonic progression survives")
    func acceptsGoodInput() {
        #expect(PlayboxProgression.validate(degrees: [1, 5, 6, 4]) == [1, 5, 6, 4])
        #expect(PlayboxProgression.validate(degrees: [2, 5]) == [2, 5])
        #expect(PlayboxProgression.validate(degrees: [1, 7]) == [1, 7])
    }

    /// ⛔ Each of these would light a key that does not exist, paint nothing, or
    /// cue one chord forever.
    @Test("⛔ out-of-range, too-short and one-note answers are REFUSED")
    func rejectsBadInput() {
        #expect(PlayboxProgression.validate(degrees: []) == nil)
        #expect(PlayboxProgression.validate(degrees: [1]) == nil, "one chord is not a progression")
        #expect(PlayboxProgression.validate(degrees: [0, 1, 2]) == nil, "0 is not a degree")
        #expect(PlayboxProgression.validate(degrees: [1, 8]) == nil, "8 is off the row")
        #expect(PlayboxProgression.validate(degrees: [-1, 5]) == nil)
        #expect(PlayboxProgression.validate(degrees: [3, 3, 3, 3]) == nil,
                "one repeated degree cues the same chord forever")
    }

    @Test("an over-long answer is truncated, not refused")
    func truncatesLongInput() {
        let long = Array(repeating: [1, 5, 6, 4], count: 20).flatMap { $0 }
        let out = PlayboxProgression.validate(degrees: long)
        #expect(out?.count == PlayboxProgression.barsRange.upperBound)
        #expect(out?.prefix(4) == [1, 5, 6, 4])
    }

    // MARK: - Parsing a model's answer

    @Test("a bare JSON array parses — the format the prompt asks for")
    func parsesJSONArray() {
        #expect(PlayboxProgression.parseDegrees(fromModelText: "[1,5,6,4]") == [1, 5, 6, 4])
        #expect(PlayboxProgression.parseDegrees(fromModelText: " [1, 5, 6, 4] \n") == [1, 5, 6, 4])
    }

    @Test("a JSON object with a degrees key parses — models add envelopes unasked")
    func parsesJSONObject() {
        #expect(PlayboxProgression.parseDegrees(
            fromModelText: "{\"degrees\":[6,4,1,5]}") == [6, 4, 1, 5])
    }

    @Test("prose around the array still parses — models explain themselves unasked")
    func parsesProse() {
        #expect(PlayboxProgression.parseDegrees(
            fromModelText: "Sure! Here's a classic: [1, 6, 4, 5] — the doo-wop changes.")
                == [1, 6, 4, 5])
        #expect(PlayboxProgression.parseDegrees(fromModelText: "1, 5, 6, 4") == [1, 5, 6, 4])
    }

    /// ⛔ **THE CASES THAT MUST FALL BACK RATHER THAN LIGHT SOMETHING WRONG.**
    @Test("⛔ a refusal, a numeral answer and an empty answer all parse to NOTHING")
    func rejectsUnusableText() {
        #expect(PlayboxProgression.parseDegrees(fromModelText: "") == nil)
        #expect(PlayboxProgression.parseDegrees(
            fromModelText: "I can't help with that.") == nil)
        #expect(PlayboxProgression.parseDegrees(fromModelText: "I - V - vi - IV") == nil,
                "Roman numerals are NOT parsed — the prompt asks for integers")
        #expect(PlayboxProgression.parseDegrees(fromModelText: "[99, 100]") == nil)
    }

    // MARK: - The local fallback

    /// ⛔⛔ **A FEATURE THAT IS DEAD WITHOUT AN API KEY IS DEAD FOR ANYONE WHO HAS
    /// NOT SET ONE UP.** This is the path that runs instead, and it always
    /// produces something playable.
    @Test("⛔ the local path ALWAYS produces a valid progression, for every seed")
    func localAlwaysProducesSomethingPlayable() {
        for seed in UInt64(0)..<200 {
            for mode in KeyMode.allCases {
                let request = PlayboxRequest(keyMode: mode, bars: 4)
                let plan = PlayboxProgression.localVariation(request: request, seed: seed)
                #expect(PlayboxProgression.validate(degrees: plan.degrees) != nil,
                        "seed \(seed) / \(mode.rawValue) produced something unplayable")
                #expect(plan.degrees.count == 4)
                #expect(plan.provenance.kind == .local)
                #expect(plan.provenance.isAI == false)
            }
        }
    }

    @Test("the local path is DETERMINISTIC in its seed, and varies across seeds")
    func localIsSeeded() {
        let request = PlayboxRequest(bars: 4)
        let a = PlayboxProgression.localVariation(request: request, seed: 7)
        let b = PlayboxProgression.localVariation(request: request, seed: 7)
        #expect(a == b, "same seed, same lights — a generator a test cannot pin is undebuggable")
        // …and pressing the button again is not a do-nothing control.
        let outputs = Set((0..<40).map {
            PlayboxProgression.localVariation(request: request, seed: UInt64($0)).degrees
        })
        #expect(outputs.count > 3, "40 seeds produced \(outputs.count) distinct progressions")
    }

    @Test("the requested LENGTH is honoured and clamped")
    func lengthIsHonoured() {
        for bars in [2, 3, 4, 8, 16] {
            let plan = PlayboxProgression.localVariation(
                request: PlayboxRequest(bars: bars), seed: 3)
            #expect(plan.degrees.count == bars)
        }
        #expect(PlayboxProgression.clampBars(0) == 2)
        #expect(PlayboxProgression.clampBars(999) == 16)
        #expect(PlayboxProgression.localVariation(
            request: PlayboxRequest(bars: 999), seed: 3).degrees.count == 16)
    }

    /// ⚠️ A minor project asked for lights must not be handed a major
    /// progression — `setProgression` would then switch the user's scale.
    @Test("⚠️ a MINOR request draws on the minor library")
    func minorRequestStaysMinor() {
        let minorPresets = Set(ChordProgressionLibrary.all
            .filter { $0.mode == .minor }
            .map(\.name))
        #expect(!minorPresets.isEmpty, "positive control: the library HAS a minor entry")
        for seed in UInt64(0)..<50 {
            let plan = PlayboxProgression.localVariation(
                request: PlayboxRequest(keyMode: .minor, bars: 4), seed: seed)
            let source = plan.provenance.detail
            #expect(minorPresets.contains(source),
                    "seed \(seed) drew on '\(source)', which is not a minor progression")
        }
    }

    // MARK: - Provenance

    /// ⛔⛔ *"The AI wrote this"* and *"we picked a stock progression"* are
    /// different claims and only one of them is true at a time.
    @Test("⛔ provenance NAMES the author and distinguishes the two claims")
    func provenanceIsHonest() {
        let ai = PlayboxProvenance(kind: .ai, detail: "anthropic")
        let local = PlayboxProvenance(kind: .local, detail: "Four Chords")
        #expect(ai.isAI)
        #expect(!local.isAI)
        #expect(ai.summary != local.summary)
        #expect(ai.summary.contains("AI"))
        #expect(local.summary.lowercased().contains("built-in"))
        #expect(!local.summary.contains("AI"), "the fallback must never claim authorship")
    }

    /// ⛔⛔ **FOUND BY LOOKING AT THE STRIP, NOT BY ANY ASSERTION.** The local
    /// line read *"From the built-in library (12-Bar Blues)"* while the keys lit
    /// a **iii** — which 12-bar blues does not contain — **beside a `12-Bar
    /// Blues` preset chip lighting something else under the same name.**
    /// `localVariation` rotates and substitutes a relative, so the sequence is
    /// never the named preset; the line has to say so.
    @Test("⛔ the local line says VARIATION — the lights are not the named preset")
    func localProvenanceAdmitsItIsAVariation() {
        let local = PlayboxProvenance(kind: .local, detail: "12-Bar Blues")
        #expect(local.summary.lowercased().contains("variation"),
                "reads '\(local.summary)' — a user comparing it to the preset chip of the same name sees different lights")
        #expect(local.summary.contains("12-Bar Blues"),
                "the source progression must still be named")

        // POSITIVE CONTROL: the degrees really do diverge from the named source,
        // so this is a defect about the WORDING and not a complaint about a
        // string that happened to be accurate.
        let named = ChordProgressionLibrary.all.first { $0.name == "12-Bar Blues" }
        #expect(named != nil, "positive control: the library HAS the entry the label names")
        if let named {
            let diverged = (UInt64(0)..<200).contains { seed in
                let plan = PlayboxProgression.localVariation(
                    request: PlayboxRequest(bars: 4), seed: seed)
                return plan.provenance.detail == named.name
                    && Set(plan.degrees) != Set(named.degrees)
            }
            #expect(diverged,
                    "no seed produced degrees differing from the source it names — if this ever fails, the wording rule above is moot and should be revisited, not deleted")
        }
    }

    // MARK: - The prompt carries the project

    /// ⚠️ `macro_song_skeleton` establishes key, tempo and sections; a Playbox
    /// sequence that ignored them would fight the arrangement the user has.
    @Test("⚠️ the prompt states the project's KEY, MODE, TEMPO and SECTION")
    func promptCarriesProjectContext() {
        let request = PlayboxRequest(keyTonic: 7, keyMode: .minor, tempoBPM: 92,
                                     sectionName: "Chorus", bars: 8, style: "dreamy indie")
        let user = PlayboxProgression.userPrompt(request)
        #expect(user.contains("G"), "tonic 7 is G")
        #expect(user.contains("minor"))
        #expect(user.contains("92"))
        #expect(user.contains("Chorus"))
        #expect(user.contains("dreamy indie"))
        #expect(user.contains("8"))
        // A blank project contributes nothing rather than the word "nil".
        let bare = PlayboxProgression.userPrompt(PlayboxRequest())
        #expect(!bare.lowercased().contains("nil"))
        #expect(!bare.contains("Section"))
        #expect(!bare.contains("Tempo"))
    }

    @Test("the system prompt asks for integers and forbids prose")
    func systemPromptIsSpecific() {
        let system = PlayboxProgression.systemPrompt()
        #expect(system.contains("JSON array"))
        #expect(system.contains("1 to 7"))
        #expect(system.lowercased().contains("diatonic"))
    }
}
