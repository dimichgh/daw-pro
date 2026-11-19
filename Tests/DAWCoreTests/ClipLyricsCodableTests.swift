import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d1: `ClipLyrics` and the `Clip.lyrics` field (design §3.1).
///
/// NOT `@MainActor`: value types and Codable only.
///
/// ⭐ The goldens below were CAPTURED FROM THE ENCODER BEFORE `Clip.lyrics`
/// EXISTED (W7-SD1's first run printed them, 2026-09-27) and must still match
/// after it: a clip without lyrics encodes byte for byte as it did. A render
/// byte gate cannot see a Codable default, which is why this pin exists
/// (design §3.1).
///
/// ⚠️ What this suite does NOT cover: the project FILE. It is written through
/// the `ClipDocument` mirror (`ProjectDocument.swift`), which does not carry
/// lyrics yet, so they do not survive a save; and the render keys, which live
/// in DAWEngine and DAWAppKit where this test target cannot reach (see
/// `notRenderMaterial`).
@Suite("Clip lyrics — storage, Codable, not render material (p2-sing-d1)")
struct ClipLyricsCodableTests {

    static let midiNotes = [
        MIDINote(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, pitch: 60, velocity: 100,
                 startBeat: 0, lengthBeats: 1),
        MIDINote(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, pitch: 62, velocity: 90,
                 startBeat: 1, lengthBeats: 0.5),
    ]

    static func midi(lyrics: ClipLyrics? = nil) -> Clip {
        Clip(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Lead", startBeat: 8,
             lengthBeats: 16, notes: midiNotes, lyrics: lyrics)
    }

    static func audio(lyrics: ClipLyrics? = nil) -> Clip {
        Clip(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, name: "Vox", startBeat: 4,
             lengthBeats: 8, audioFileURL: URL(fileURLWithPath: "/tmp/vox.wav"), gainDb: -3, fadeInBeats: 1,
             stretchRatio: 1.5, lyrics: lyrics)
    }

    static let midiClip = midi()
    static let audioClip = audio()

    static let midiGolden = #"{"id":"11111111-1111-1111-1111-111111111111","isAIGenerated":false,"lengthBeats":16,"name":"Lead","notes":[{"id":"22222222-2222-2222-2222-222222222222","lengthBeats":1,"pitch":60,"startBeat":0,"velocity":100},{"id":"33333333-3333-3333-3333-333333333333","lengthBeats":0.5,"pitch":62,"startBeat":1,"velocity":90}],"startBeat":8}"#

    static let audioGolden = #"{"audioFileURL":"file:\/\/\/tmp\/vox.wav","fadeInBeats":1,"gainDb":-3,"id":"44444444-4444-4444-4444-444444444444","isAIGenerated":false,"lengthBeats":8,"name":"Vox","startBeat":4,"stretchRatio":1.5}"#

    /// `midiGolden` with the one new key, in sorted place.
    static let midiWithLyricsGolden = #"{"id":"11111111-1111-1111-1111-111111111111","isAIGenerated":false,"lengthBeats":16,"lyrics":{"text":"twin-kle +\nlit-tle star"},"name":"Lead","notes":[{"id":"22222222-2222-2222-2222-222222222222","lengthBeats":1,"pitch":60,"startBeat":0,"velocity":100},{"id":"33333333-3333-3333-3333-333333333333","lengthBeats":0.5,"pitch":62,"startBeat":1,"velocity":90}],"startBeat":8}"#

    static func encodeSorted<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decodeClip(_ json: String) throws -> Clip {
        try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
    }

    /// `golden` with `"lyrics":<value>,` spliced in before `"name"`.
    static func withLyricsKey(_ golden: String, _ value: String) -> String {
        golden.replacingOccurrences(of: #","name":"#, with: #","lyrics":\#(value),"name":"#)
    }

    // MARK: Byte identity for clips without lyrics

    @Test("a clip without lyrics encodes byte-identically to the pre-lyrics golden")
    func goldenWithoutLyrics() throws {
        let midi = try Self.encodeSorted(Self.midiClip)
        let audio = try Self.encodeSorted(Self.audioClip)
        print("[golden] midi  \(midi)")
        print("[golden] audio \(audio)")
        #expect(midi == Self.midiGolden)
        #expect(audio == Self.audioGolden)
    }

    @Test("a clip saved before lyrics existed decodes with no lyrics, and otherwise unchanged")
    func oldClipDecodesWithoutLyrics() throws {
        let midi = try Self.decodeClip(Self.midiGolden)
        let audio = try Self.decodeClip(Self.audioGolden)
        #expect(midi.lyrics == nil)
        #expect(audio.lyrics == nil)
        #expect(midi == Self.midiClip)
        #expect(audio == Self.audioClip)
    }

    // MARK: Round trip

    @Test("a MIDI clip's lyrics round-trip exactly, under one new key and nowhere else")
    func roundTripWithLyrics() throws {
        let lyrics = ClipLyrics(text: "twin-kle +\nlit-tle star")
        let clip = Self.midi(lyrics: lyrics)
        #expect(clip.lyrics == lyrics)
        let json = try Self.encodeSorted(clip)
        print("[golden] midi+lyrics \(json)")
        #expect(json == Self.midiWithLyricsGolden)
        #expect(json == Self.withLyricsKey(Self.midiGolden, #"{"text":"twin-kle +\nlit-tle star"}"#),
                "control: the only difference from the pre-lyrics golden is the one key")
        let back = try Self.decodeClip(json)
        #expect(back == clip)
        #expect(back.lyrics?.text == "twin-kle +\nlit-tle star")
    }

    // MARK: ClipLyrics itself

    @Test("ClipLyrics round-trips its text verbatim, markup and line breaks included")
    func lyricsRoundTrip() throws {
        let lyrics = ClipLyrics(text: "Twin-kle, twin-kle ✨\nlit-tle star +~")
        let json = try Self.encodeSorted(lyrics)
        #expect(json == #"{"text":"Twin-kle, twin-kle ✨\nlit-tle star +~"}"#)
        #expect(try JSONDecoder().decode(ClipLyrics.self, from: Data(json.utf8)) == lyrics)
    }

    @Test("blank text is the one 'no lyrics' state; real text is kept exactly, never trimmed")
    func normalization() throws {
        #expect(ClipLyrics.normalized(nil) == nil)
        for blank in ["", " ", "\n\n", " \t\r\n "] {
            #expect(ClipLyrics.normalized(ClipLyrics(text: blank)) == nil, "\(blank.debugDescription)")
        }
        #expect(ClipLyrics.normalized(ClipLyrics(text: "  la \n")) == ClipLyrics(text: "  la \n"))
        // A damaged object with no text key decodes (as "") rather than failing the clip.
        let damaged = try JSONDecoder().decode(ClipLyrics.self, from: Data("{}".utf8))
        #expect(damaged.text == "" && ClipLyrics.normalized(damaged) == nil)
    }

    @Test("only the text is stored: the word-to-note assignment is derived, never saved (F16)")
    func onlyTextIsStored() {
        let labels = Mirror(reflecting: ClipLyrics(text: "a b")).children.map(\.label)
        // p2-sing-x3 (design 2026-10-06 §6.3) adds the clip's language: a property of the TEXT (nil is English),
        // never a word-to-note record. Still no assignment is stored.
        #expect(labels == ["text", "language"])
        #expect(ClipLyrics.maxTextLength == 4_000)
    }

    // MARK: Clip's rules for the field

    @Test("blank lyrics are no lyrics on a clip too: through init and through decode")
    func blankOnAClip() throws {
        let blank = Self.midi(lyrics: ClipLyrics(text: " \n\t"))
        #expect(blank.lyrics == nil)
        #expect(try Self.encodeSorted(blank) == Self.midiGolden)
        for value in [#"{"text":""}"#, #"{"text":"  \n"}"#, "{}", "null"] {
            let decoded = try Self.decodeClip(Self.withLyricsKey(Self.midiGolden, value))
            #expect(decoded.lyrics == nil, "lyrics \(value)")
            #expect(try Self.encodeSorted(decoded) == Self.midiGolden, "lyrics \(value)")
        }
        // Positive control: the splice really reaches the decoder.
        let kept = try Self.decodeClip(Self.withLyricsKey(Self.midiGolden, #"{"text":"la"}"#))
        #expect(kept.lyrics == ClipLyrics(text: "la"))
    }

    @Test("lyrics belong to MIDI clips: an audio clip drops them, at init and at decode")
    func midiOnly() throws {
        #expect(Self.audio(lyrics: ClipLyrics(text: "la la")).lyrics == nil)
        let decoded = try Self.decodeClip(Self.withLyricsKey(Self.audioGolden, #"{"text":"la la"}"#))
        #expect(decoded.lyrics == nil)
        #expect(try Self.encodeSorted(decoded) == Self.audioGolden)
        // Positive controls: a MIDI clip keeps them, and so does a MIDI clip
        // with no notes yet (words can be typed before the tune is drawn).
        #expect(Self.midi(lyrics: ClipLyrics(text: "la la")).lyrics == ClipLyrics(text: "la la"))
        let empty = Clip(name: "Empty", notes: [], lyrics: ClipLyrics(text: "la"))
        #expect(empty.isMIDI && empty.lyrics == ClipLyrics(text: "la"))
    }

    @Test("two clips that differ only in lyrics are not equal, so undo sees a lyrics edit")
    func equalitySeesLyrics() {
        let plain = Self.midiClip
        var sung = plain
        sung.lyrics = ClipLyrics(text: "la")
        #expect(sung != plain)
        var other = sung
        other.lyrics = ClipLyrics(text: "la la")
        #expect(other != sung)
        sung.lyrics = nil
        #expect(sung == plain)
    }

    // MARK: Not render material

    /// The key builders live in DAWEngine (`StretchRenderCache.Params(clip:)`,
    /// `renderKeys`) and DAWAppKit (`ClipRenderSignature`), which this target
    /// cannot import. This pins the model side of the same claim: every
    /// predicate and every input those builders read from a clip. The worst
    /// case is used: a clip that RENDERS, with lyrics forced on by direct
    /// assignment (`init` would have dropped them from an audio clip).
    @Test("lyrics change nothing the render reads from a clip: its predicates and its inputs")
    func notRenderMaterial() {
        let plain = Self.audioClip
        var sung = plain
        sung.lyrics = ClipLyrics(text: "twin-kle twin-kle\nlit-tle star")
        #expect(sung != plain, "control: the two clips differ")
        #expect(sung.rendersThroughStretchCache, "control: this clip renders")
        #expect(sung.rendersThroughStretchCache == plain.rendersThroughStretchCache)
        #expect(sung.isStretchIdentity == plain.isStretchIdentity)
        #expect(sung.hasPitchEdits == plain.hasPitchEdits)
        #expect(sung.hasTuningEdits == plain.hasTuningEdits)
        let map = TempoMap(constantBPM: 97)
        #expect(sung.sourceWindowSeconds(tempoMap: map) == plain.sourceWindowSeconds(tempoMap: map))
        for beat in stride(from: 0.0, through: 8, by: 0.25) {
            #expect(sung.envelopeGain(atBeat: beat) == plain.envelopeGain(atBeat: beat))
        }
        #expect(sung.audioFileURL == plain.audioFileURL)
        #expect(sung.stretchRatio.bitPattern == plain.stretchRatio.bitPattern)
        #expect(sung.pitchShiftSemitones.bitPattern == plain.pitchShiftSemitones.bitPattern)
        #expect(sung.formantPreserve == plain.formantPreserve)
        #expect(sung.pitchEdits == plain.pitchEdits)
        #expect(sung.startOffsetSeconds == plain.startOffsetSeconds)
        // Everything but the lyrics is the same clip.
        sung.lyrics = nil
        #expect(sung == plain)
    }
}
