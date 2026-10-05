import DAWCore
import Foundation
import Testing

/// m39-af — **THE MIXER'S "+" MENU LISTS EVERY BUILT-IN KIND.**
///
/// ⚠️⚠️ `Sources/DAWApp` has no test target, and `addableEffectKinds`
/// (`Sources/DAWApp/Mixer/MixerStripView.swift`) is a HAND-MAINTAINED array. Its
/// own comment says what happens when it drifts: *"a new built-in kind is
/// INVISIBLE in the '+' menu until it is appended here (the compiler cannot
/// catch the omission)"*. A kind can therefore ship completely — render path,
/// persistence, wire surface, MCP — and be unreachable for a human, with every
/// test green.
///
/// ⛔⛔ **THIS TEST EXISTS TO CLOSE THE CLASS, NOT THE INSTANCE.** Adding
/// `.dynamicEQ` to the array by hand fixes one kind; comparing the array to
/// `Kind.allCases` fixes every kind that will ever be added. It is the
/// `MusicalTypingSiteTests`/`PadGridSiteTests` shape, verbatim — including the
/// rule that matters most: assertions run against **comment-stripped** source,
/// because the file documents its own list in prose that would satisfy a naive
/// grep.
///
/// ⚠️ **A SOURCE-SHAPE TEST IS THE WEAKER INSTRUMENT AND IT IS WHAT IS
/// AVAILABLE.** `scripts/gates/effect-kind-surface.mjs` covers the same file,
/// but only with a WHOLE-FILE PRESENCE check — a kind mentioned anywhere in
/// `MixerStripView.swift`, including in a comment, satisfies it. This parses the
/// array itself and demands exact set equality, so it is strictly stronger about
/// this one surface while the gate stays broader about the others.
@Suite("m39-af — the mixer + menu is the complete built-in roster")
struct AddableEffectKindsSiteTests {

    // MARK: - Source access

    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func code(_ relativePath: String) -> String {
        guard let content = rawCode(relativePath) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// The same read WITHOUT the `Issue.record` — the negative control needs a
    /// missing file to come back nil rather than to redden the suite it is
    /// controlling.
    private static func rawCode(_ relativePath: String) -> String? {
        try? String(contentsOf: sourcesDir().appendingPathComponent(relativePath),
                    encoding: .utf8)
    }

    private static let source = "DAWApp/Mixer/MixerStripView.swift"

    /// Pulls the kinds out of the `addableEffectKinds` literal, so a kind named
    /// in a nearby comment or in a different list cannot satisfy the census.
    ///
    /// ⚠️ **THE `=` IS LOAD-BEARING.** The declaration reads
    /// `let addableEffectKinds: [EffectDescriptor.Kind] = [.gain, …]`, so the
    /// FIRST `[` after the name belongs to the TYPE ANNOTATION. The first draft
    /// of this parser took it and cheerfully reported a one-element list
    /// containing "EffectDescriptor.Kind" — a parse that found nothing while
    /// looking like it had found something, which is this tree's
    /// characteristic failure and the reason the positive control below exists.
    private static func parsedAddableKinds() -> [String] {
        let stripped = code(source)
        guard let declaration = stripped.range(of: "addableEffectKinds") else { return [] }
        let afterName = stripped[declaration.upperBound...]
        guard let assign = afterName.firstIndex(of: "=") else { return [] }
        let rest = afterName[afterName.index(after: assign)...]
        guard let open = rest.firstIndex(of: "["), let close = rest.firstIndex(of: "]") else {
            return []
        }
        return String(rest[rest.index(after: open)..<close])
            .split(whereSeparator: { ",\n \t".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\n")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - ⭐ The positive control, first

    /// Every assertion below is a parse over stripped source. A path typo, a
    /// broken stripper or a changed declaration would each make the parse return
    /// nothing — and "the list is empty" must never read as "nothing is missing".
    @Test("⭐ the source reader reaches real code and the parse finds a real list")
    func readerAndParserWork() {
        let stripped = Self.code(Self.source)
        #expect(stripped.isEmpty == false)
        #expect(stripped.count > 2_000, "read \(stripped.count) bytes — that is not this file")
        #expect(stripped.contains("struct MixerChannelStrip"))
        // …and it really does strip: this phrase exists ONLY in the comment
        // above the array.
        #expect(stripped.contains("the compiler cannot catch the omission") == false)
        // A NEGATIVE CONTROL on the path: a file that does not exist must come
        // back nil, so "empty" can never be mistaken for "read and found
        // nothing". (Through `rawCode`, which does not record an issue — the
        // control must not redden the suite it controls.)
        #expect(Self.rawCode("DAWApp/Mixer/NoSuchFile.swift") == nil)
        #expect(Self.rawCode(Self.source) != nil)

        let parsed = Self.parsedAddableKinds()
        #expect(parsed.count > 10, "parsed \(parsed.count) kinds: \(parsed)")
        // ⛔ AND IT IS NOT THE TYPE ANNOTATION. This is the exact wrong answer
        // the first draft produced, pinned so the parser cannot regress into it.
        #expect(parsed.contains("EffectDescriptor.Kind") == false,
                "the parser took the type annotation's brackets, not the literal's")
        // Two sentinels that are unambiguous in this domain — `gate`, `delay`,
        // `reverb` and `chorus` are all ordinary English in a DAW and would let
        // the parse pass by accident.
        #expect(parsed.contains("saturator"))
        #expect(parsed.contains("bitCrusher"))
    }

    // MARK: - ⛔ The census

    @Test("⛔ addableEffectKinds IS the built-in roster — no kind is invisible in the + menu")
    func theMenuListsEveryBuiltInKind() {
        let parsed = Set(Self.parsedAddableKinds())
        let builtIns = Set(EffectDescriptor.Kind.allCases
            .filter { $0 != .audioUnit }
            .map(\.rawValue))
        #expect(builtIns.count >= 22, "the kind roster went vacuous: \(builtIns.sorted())")

        let missing = builtIns.subtracting(parsed).sorted()
        #expect(missing.isEmpty, """
            \(missing) ship(s) but is/are INVISIBLE in the mixer's + menu. Append to \
            `addableEffectKinds` in \(Self.source). The compiler cannot catch this and no \
            other test in the tree looks at that array.
            """)

        // The other direction: a kind in the menu that is not a built-in would
        // not compile, but a HOSTED one there would be a real bug — the menu
        // deliberately excludes `.audioUnit`, which needs a component picker.
        let extra = parsed.subtracting(builtIns).sorted()
        #expect(extra.isEmpty, "the + menu offers \(extra), which are not built-in kinds")
        #expect(parsed.contains("audioUnit") == false,
                "hosted Audio Units need a component picker and are added over the wire")

        // ⭐ AND THE NEW KIND BY NAME, so a regression reads as the bug it is
        // rather than as an anonymous census failure.
        #expect(parsed.contains("dynamicEQ"))
    }

    /// The census above compares SETS. This pins that the list is also the right
    /// LENGTH, so a duplicated entry (which a set comparison cannot see) is
    /// caught too.
    @Test("the list has no duplicates and is exactly as long as the roster")
    func theListHasNoDuplicates() {
        let parsed = Self.parsedAddableKinds()
        let builtInCount = EffectDescriptor.Kind.allCases.count - 1  // minus .audioUnit
        #expect(parsed.count == builtInCount,
                Comment(rawValue: "the + menu lists \(parsed.count) entries for "
                    + "\(builtInCount) built-in kinds: \(parsed)"))
        #expect(Set(parsed).count == parsed.count, "duplicate entries: \(parsed)")
    }
}
