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

    @Test("catalog carries the m22-c live-loudness verb; count now 61")
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
        // A silent add/drop fails here.
        #expect(CopilotToolCatalog.v1.count == 61)
        #expect(CopilotToolCatalog.tool(command: "mixer.liveLoudness") != nil,
                "mixer.liveLoudness missing from the catalog")
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
}
