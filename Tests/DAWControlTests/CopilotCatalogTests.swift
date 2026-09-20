import DAWCore
import Foundation
import Testing
@testable import DAWControl

/// Exhaustiveness checks for the Copilot's tool catalog (M6 rail-c; design
/// §3/§7): every entry must be a real, non-denylisted control-protocol
/// command, the "."<->"_" wire-name mapping must round-trip, and every
/// schema must be a well-formed JSON object schema.
@MainActor
@Suite("Copilot tool catalog")
struct CopilotCatalogTests {
    @Test("every catalog command is a real control-protocol command")
    func catalogCommandsAreReal() {
        let known = Set(CommandRouter.allCommands)
        for tool in CopilotToolCatalog.v1 {
            #expect(known.contains(tool.command), "\(tool.command) is not in CommandRouter.allCommands")
        }
    }

    @Test("catalog and neverInclude are disjoint")
    func catalogExcludesDenylist() {
        let catalogCommands = Set(CopilotToolCatalog.allCommands)
        #expect(catalogCommands.isDisjoint(with: CopilotToolCatalog.neverInclude))
    }

    @Test("neverInclude carries exactly the designed denylist")
    func denylistIsExact() {
        #expect(CopilotToolCatalog.neverInclude == [
            "project.new", "project.open", "project.save", "track.remove",
            "ai.copilotSend", "ai.copilotState", "ai.copilotReset",
            // M10-p-6: the copilot's own model-selection plumbing — same
            // recursion-prevention rationale as the other ai.copilot* trio.
            "ai.copilotGetModel", "ai.copilotSetModel",
            // Chat-persist design (2026-07-19 Phase C): the copilot's own
            // session-history plumbing — same recursion-prevention rationale.
            "ai.copilotChats", "ai.copilotResumeChat",
            "ai.copilotDeleteChat", "ai.copilotRenameChat",
        ])
    }

    @Test("no duplicate commands in the catalog")
    func noDuplicateCommands() {
        let commands = CopilotToolCatalog.allCommands
        #expect(Set(commands).count == commands.count)
    }

    @Test("catalog carries the m22-g reference verbs; count now 65")
    func catalogCountPin() {
        // m12-g seeded the fx section with fx.setSidechain alone (47). m13-d
        // added fx.add / fx.remove / fx.setParam / fx.setBypass — each teaching
        // the trackId:"master" sentinel + built-ins-only on master — taking the
        // surface 47 → 51. m13-e's clip.setGainEnvelope took it 51 → 52. m15-d's
        // clip.duplicate + arrange.insertBars + arrange.deleteBars took it
        // 52 → 55. m16-b2's clip.setControllerLane took it 55 → 56 (the paired
        // clip.removeControllerLane is wire+MCP only, not a Copilot catalog row).
        // au.describeParams/au.setParam took it 56 → 58. m21-d's
        // clip.fitToContent took it 58 → 59. m21-e's clip.analyzeAudio took it
        // 59 → 60. m22-c's mixer.liveLoudness (the m21-b2 law: new
        // capabilities must be visible to the in-app copilot) took it 60 → 61.
        // m22-g P3's reference workflow took it 61 → 65: the CURATED FOUR
        // (import/status/setMonitor/compare) per the orchestrator's §12
        // decision 3 — NOT all eight. reference.remove / reference.analyze /
        // reference.setOffset / reference.setTrim are deliberately absent from
        // the catalog and taught inside the four entries' descriptions instead
        // (asserted below, so a future edit can't quietly drop the teaching).
        // A silent add/drop fails here. m23-d's note.audition took it 65 -> 66.
        // m23-h's track.reorder — the ONE track-ordering verb, and the m21-b2
        // law that a new user-facing capability must be visible to the in-app
        // copilot — took it 66 -> 67. m23-r4's fx.spectrum took it 67 -> 68.
        // m23-o1's frequency.reference took it 68 -> 69. m23-w's
        // clip.removeMany/clip.moveMany — the wire half of m23-g1/m23-g2's
        // group delete/move, and strictly better undo atomicity for a
        // capability (clip.remove/clip.move) already IN the catalog — took it
        // 69 -> 71.
        #expect(CopilotToolCatalog.v1.count == 81)   // 81 at m23-cw (au.listPresets/au.loadPreset — the m21-b2 law: a new user-facing capability must be visible to the in-app copilot, and "give me a cathedral reverb" is exactly the request the copilot could not previously serve, because starting from the right PRESET is how a plugin's sound space is actually reached). 72 at m23-af (transport.panic) -> 74 at m23-aj-2 (moveManyByTracks/moveManyToTrack) -> 75 at m25-d (transport.setStopAtContentEnd) -> 76 at m27 leg D (clip.applyBreathContour) -> 77 at breath pad P1 (clip.applyEffortShape) -> 78 at m31-c (clip.repeatNotes — the in-app copilot composes music too, and this is the exact "author one bar, repeat it" efficiency verb an autonomous agent wants; siblings clip.setNotes/clip.addMIDI are both already in the catalog) -> 79 at m26-a/m27-n (clip.patchNotes — the most obvious autonomous-agent framing of any verb in this file: it exists BECAUSE an agent doing "raise the velocity of 48 shaker notes out of 907" should not have to round-trip the other 859)
        #expect(CopilotToolCatalog.tool(command: "clip.repeatNotes") != nil,
                "clip.repeatNotes missing from the catalog — m21-b2 requires a new user-facing\n                 capability to be visible to the in-app copilot, and this verb exists\n                 specifically to save an authoring agent from generating repeated material")
        #expect(CopilotToolCatalog.tool(command: "clip.patchNotes") != nil,
                "clip.patchNotes missing from the catalog — m21-b2: a new user-facing capability\n                 must be visible to the in-app copilot, and this verb's whole reason to exist\n                 is an authoring agent's own workflow")
        #expect(CopilotToolCatalog.tool(command: "clip.applyBreathContour") != nil,
                "clip.applyBreathContour missing from the catalog — the copilot is exactly\n                 the caller that should reach for a breath contour, and m21-b2 requires a\n                 new user-facing capability to be visible to it")
        #expect(CopilotToolCatalog.tool(command: "transport.setStopAtContentEnd") != nil,
                "transport.setStopAtContentEnd missing from the catalog — m21-b2: a new\n                 user-facing capability must be visible to the in-app copilot")
        #expect(CopilotToolCatalog.tool(command: "clip.removeMany") != nil,
                "clip.removeMany missing from the catalog")
        #expect(CopilotToolCatalog.tool(command: "clip.moveMany") != nil,
                "clip.moveMany missing from the catalog")
        #expect(CopilotToolCatalog.tool(command: "clip.moveManyByTracks") != nil,
                "clip.moveManyByTracks missing from the catalog")
        #expect(CopilotToolCatalog.tool(command: "clip.moveManyToTrack") != nil,
                "clip.moveManyToTrack missing from the catalog")
        #expect(CopilotToolCatalog.tool(command: "track.reorder") != nil,
                "track.reorder missing from the catalog")
        #expect(CopilotToolCatalog.tool(command: "mixer.liveLoudness") != nil,
                "mixer.liveLoudness missing from the catalog")
        for command in ["reference.import", "reference.status",
                        "reference.setMonitor", "reference.compare"] {
            #expect(CopilotToolCatalog.tool(command: command) != nil,
                    "\(command) missing from the catalog")
        }
        // The curated-four decision, pinned from BOTH sides.
        for command in ["reference.remove", "reference.analyze",
                        "reference.setOffset", "reference.setTrim"] {
            #expect(CopilotToolCatalog.tool(command: command) == nil,
                    "\(command) joined the catalog — the m22-g decision was a curated four")
        }
        // …and each absent verb is TAUGHT somewhere in the curated four, so an
        // agent still knows it exists.
        let referenceCopy = CopilotToolCatalog.v1
            .filter { $0.command.hasPrefix("reference.") }
            .map(\.description).joined(separator: " ")
        for taught in ["reference.remove", "reference.analyze",
                       "reference.setOffset", "reference.setTrim"] {
            #expect(referenceCopy.contains(taught),
                    "\(taught) is neither a catalog entry nor taught inside one")
        }
        #expect(CopilotToolCatalog.tool(command: "clip.analyzeAudio") != nil,
                "clip.analyzeAudio missing from the catalog")
        #expect(CopilotToolCatalog.tool(command: "clip.fitToContent") != nil,
                "clip.fitToContent missing from the catalog")
        for command in ["fx.add", "fx.remove", "fx.setParam", "fx.setBypass", "fx.setSidechain"] {
            #expect(CopilotToolCatalog.tool(command: command) != nil, "\(command) missing from the catalog")
        }
        #expect(CopilotToolCatalog.tool(command: "clip.setGainEnvelope") != nil,
                "clip.setGainEnvelope missing from the catalog")
        #expect(CopilotToolCatalog.tool(command: "clip.setControllerLane") != nil,
                "clip.setControllerLane missing from the catalog")
        for command in ["clip.duplicate", "arrange.insertBars", "arrange.deleteBars"] {
            #expect(CopilotToolCatalog.tool(command: command) != nil, "\(command) missing from the catalog")
        }
    }

    /// ⭐ m39-m — THE CATALOG'S `fx.add` KIND ENUM IS A HAND-MAINTAINED LIST
    /// AND WAS UNPINNED UNTIL NOW. Design §11.0.1 rules that "a new effect KIND
    /// updates `CopilotCatalog.swift`", but nothing compared that list to the
    /// enum, so a kind added to `EffectDescriptor.Kind` and forgotten here is
    /// simply never suggested by the in-app copilot — the capability ships and
    /// is undiscoverable, which is the exact failure `effect-kind-surface.mjs`
    /// was built for on the OTHER four surfaces.
    ///
    /// Derived from `Kind.allCases`, so it cannot go stale: it fails the day a
    /// kind is added without touching the catalog, and needs no edit when one
    /// is added correctly. `.audioUnit` is excluded deliberately — it needs a
    /// component triple the copilot cannot supply, which is why the catalog's
    /// own list has never carried it.
    @Test("m39-m: fx.add's copilot kind enum is EVERY built-in kind, derived from the enum")
    func copilotFXKindEnumCoversEveryBuiltIn() throws {
        let tool = try #require(CopilotToolCatalog.tool(command: "fx.add"))
        let kindSchema = try #require(tool.schema["properties"]?["kind"])
        let offered = try #require(kindSchema["enum"]?.arrayValue?.compactMap { $0.stringValue })
        let builtIns = EffectDescriptor.Kind.allCases
            .filter { $0 != .audioUnit }
            .map { $0.rawValue }
        #expect(offered == builtIns,
                Comment(rawValue: "the copilot offers \(offered) but the built-in kinds are "
                    + "\(builtIns) — a kind the copilot cannot name is a kind it will never suggest"))
        // NON-VACUITY, both directions: the list is not empty, and `audioUnit`
        // is genuinely absent rather than the filter above being a no-op.
        #expect(offered.count >= 13)
        #expect(!offered.contains("audioUnit"))
    }

    @Test("wire-name mapping round-trips bijectively")
    func wireNameMappingRoundTrips() {
        for tool in CopilotToolCatalog.v1 {
            #expect(!tool.command.contains("_"), "\(tool.command) contains an underscore — mapping would be ambiguous")
            let toolName = CopilotTool.toolName(fromCommand: tool.command)
            #expect(CopilotTool.command(fromToolName: toolName) == tool.command)
        }
        // No two commands may collide onto the same underscored tool name.
        let names = CopilotToolCatalog.v1.map { CopilotTool.toolName(fromCommand: $0.command) }
        #expect(Set(names).count == names.count)
    }

    @Test("every schema is a JSON object schema")
    func everySchemaIsObjectSchema() {
        for tool in CopilotToolCatalog.v1 {
            guard case .object(let fields) = tool.schema else {
                Issue.record("\(tool.command)'s schema is not a JSON object")
                continue
            }
            #expect(fields["type"] == .string("object"), "\(tool.command)'s schema is not type:object")
            #expect(fields["properties"] != nil, "\(tool.command)'s schema has no properties")
        }
    }

    @Test("no catalog command is a debug or copilot-recursive command")
    func noDebugOrRecursiveCommands() {
        for command in CopilotToolCatalog.allCommands {
            #expect(!command.hasPrefix("debug."))
            #expect(!command.hasPrefix("ai.copilot"))
        }
    }

    @Test("spec() derives the AIServices wire shape")
    func specDerivesWireShape() throws {
        let tool = try #require(CopilotToolCatalog.tool(command: "track.setVolume"))
        let spec = tool.spec()
        #expect(spec.name == "track_setVolume")
        #expect(spec.description == tool.description)
        let decodedSchema = try JSONDecoder().decode(JSONValue.self, from: spec.inputSchemaJSON)
        #expect(decodedSchema == tool.schema)
    }

    @Test("lookup helpers resolve both directions")
    func lookupHelpers() throws {
        let byCommand = try #require(CopilotToolCatalog.tool(command: "clip.setNotes"))
        #expect(byCommand.command == "clip.setNotes")
        let byToolName = try #require(CopilotToolCatalog.tool(toolName: "clip_setNotes"))
        #expect(byToolName.command == "clip.setNotes")
        #expect(CopilotToolCatalog.tool(command: "track.remove") == nil)
        #expect(CopilotToolCatalog.tool(toolName: "ai_copilotSend") == nil)
    }

    // MARK: - Catalog PARAM-KEY parity with the wire (breath pad P5)

    /// ⛔⛔ **THE CATALOG IS HAND-WRITTEN AND ITS PARAM KEYS WERE UNGATED.**
    /// Every other test in this suite pins command NAMES, schema SHAPE, and
    /// entry COUNT — none of them looks at a single property key. A key
    /// mistyped here (`tremorRateHZ` for `tremorRateHz`) therefore advertised a
    /// parameter to the in-app Copilot that `Commands.swift` would REJECT, and
    /// nothing anywhere went red. MEASURED, not supposed: that exact typo was
    /// planted while building P5 and the whole `Copilot`-filtered run — 238
    /// tests, 20 suites — stayed green.
    ///
    /// This is the hazard the P5 brief named ("a key the DESCRIPTION advertises
    /// but the SCHEMA omits") arriving through the third surface, and it is
    /// this tree's characteristic failure mode: the Copilot would emit the
    /// advertised key, the wire would refuse the whole call, and the only
    /// symptom is a plausible-looking error blamed on the model.
    ///
    /// Direction is deliberate: **catalog ⊆ wire**. The catalog is allowed to
    /// be a curated subset (most entries are — that is the point of a curated
    /// tool surface), but it may never advertise a key the wire will not take.
    @Test("every param key the Copilot catalog advertises is a key Commands.swift actually accepts — the direction that matters, since a curated subset is legal and a typo is not")
    func catalogParamKeysAreAcceptedByTheWire() throws {
        let allowedByVerb = try Self.allowedKeysByVerbInSource()
        #expect(!allowedByVerb.isEmpty,
                "the source scan itself must find something, or this test is vacuously green")

        // POSITIVE CONTROL on the scrape: the P5 verb must be one of the verbs
        // the scrape actually resolved, and its key set must contain a key we
        // can see with our own eyes. Without this, a regex that silently
        // stopped matching would turn every assertion below into a no-op and
        // the test would still pass — a tool that never looked and a tool that
        // looked and found nothing produce the same green.
        let effortKeys = try #require(allowedByVerb["clip.applyEffortShape"],
                                      "the scrape lost clip.applyEffortShape entirely")
        #expect(effortKeys.contains("tremorRateHz"))
        #expect(effortKeys.contains("driftDepth"))
        #expect(effortKeys.contains("clipId"))

        var checked = 0
        for tool in CopilotToolCatalog.v1 {
            guard let allowed = allowedByVerb[tool.command] else { continue }
            guard case .object(let fields) = tool.schema,
                  case .object(let properties)? = fields["properties"] else { continue }
            checked += 1
            for key in properties.keys.sorted() {
                #expect(allowed.contains(key),
                        "\(tool.command): the catalog advertises '\(key)', which Commands.swift does not accept — the Copilot would emit it and the wire would refuse the whole call")
            }
        }
        // Second vacuity guard: the LOOP must have had work to do. `checked`
        // counts catalog entries whose verb the scrape resolved AND whose
        // schema exposed properties; if a refactor breaks either half, this
        // number collapses and says so instead of passing quietly.
        print("[measured] catalog param-key parity: \(checked) of \(CopilotToolCatalog.v1.count) "
              + "catalog entries compared against \(allowedByVerb.count) scraped wire key sets")
        #expect(checked >= 50,
                "only \(checked) catalog entries were actually compared — the gate has lost its reach")
    }

    /// The allowed-key set for every verb whose `rejectUnknownKeys` call site
    /// writes its set as an ARRAY LITERAL. Same scrape family as
    /// `ZeroParamVerbRejectionTests`, but it keeps the KEYS rather than
    /// discarding them for the verb name.
    private static func allowedKeysByVerbInSource() throws -> [String: Set<String>] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        var source: URL?
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources/DAWControl/Commands.swift")
            if fm.fileExists(atPath: candidate.path) { source = candidate; break }
            dir = dir.deletingLastPathComponent()
        }
        guard let source else {
            Issue.record("Could not locate Sources/DAWControl/Commands.swift from \(#filePath)")
            return [:]
        }
        let text = try String(contentsOf: source, encoding: .utf8)
        // `[^\]]` spans newlines under NSRegularExpression, which is what lets
        // this reach the multi-line literals (clip.applyEffortShape's is 17
        // lines long). Capture 1 is the literal's body, capture 2 the verb.
        let pattern = #"rejectUnknownKeys\(\s*\[([^\]]*)\]\s*,\s*verb:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let quoted = try NSRegularExpression(pattern: #""([^"]+)""#)
        var found: [String: Set<String>] = [:]
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match, match.numberOfRanges > 2,
                  let bodyRange = Range(match.range(at: 1), in: text),
                  let verbRange = Range(match.range(at: 2), in: text) else { return }
            let body = String(text[bodyRange])
            var keys: Set<String> = []
            quoted.enumerateMatches(in: body, range: NSRange(body.startIndex..., in: body)) { m, _, _ in
                guard let m, m.numberOfRanges > 1,
                      let r = Range(m.range(at: 1), in: body) else { return }
                keys.insert(String(body[r]))
            }
            found[String(text[verbRange])] = keys
        }
        return found
    }
}
