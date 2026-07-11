import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for `ai.providerStatus` (M6). The command is a thin
/// passthrough over `providerStatuses`, injected here with an `InMemoryKeyStore`
/// and a fixed environment so the suite runs headless.
///
/// The load-bearing assertion is SECURITY: the response carries booleans + a
/// source enum ONLY. The suite feeds distinctive secret values into both the
/// environment and the store, then scans the ENTIRE serialized response to prove
/// no key material (and no length) rides along, and confirms there is no set-key
/// command on the canonical list.
@MainActor
@Suite("AI provider status — control protocol (M6)")
struct ProviderStatusCommandTests {
    private func makeRouter(
        store: APIKeyStoring,
        environment: [String: String]
    ) -> CommandRouter {
        CommandRouter(
            store: ProjectStore(),
            keyStore: store,
            keyEnvironment: environment
        )
    }

    @Test("ai.providerStatus is on the canonical command list")
    func isCanonical() {
        #expect(CommandRouter.allCommands.contains("ai.providerStatus"))
    }

    @Test("there is deliberately no set-key command on the wire")
    func noSetKeyCommand() {
        for command in CommandRouter.allCommands {
            #expect(!command.lowercased().contains("setkey"))
            #expect(!command.lowercased().contains("providerkey"))
            #expect(!command.lowercased().contains("apikey"))
        }
    }

    @Test("reports env / keychain / none per provider — booleans and source only")
    func reportsSourcePerProvider() async throws {
        let store = InMemoryKeyStore([.openai: "sk-openai-SECRET-9999"])
        let env = ["ANTHROPIC_API_KEY": "sk-ant-SECRET-1111"]
        let router = makeRouter(store: store, environment: env)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.providerStatus"))
        #expect(response.ok, "ai.providerStatus failed: \(response.error ?? "?")")

        let providers = response.result?["providers"]?.arrayValue ?? []
        #expect(providers.count == 3)
        let byId: [String: JSONValue] = providers.reduce(into: [:]) { acc, item in
            if let name = item["provider"]?.stringValue { acc[name] = item }
        }

        #expect(byId["anthropic"]?["configured"]?.boolValue == true)
        #expect(byId["anthropic"]?["source"]?.stringValue == "env")
        #expect(byId["openai"]?["configured"]?.boolValue == true)
        #expect(byId["openai"]?["source"]?.stringValue == "keychain")
        #expect(byId["suno"]?["configured"]?.boolValue == false)
        #expect(byId["suno"]?["source"]?.stringValue == "none")
        // ACE-Step is keyless and never appears.
        #expect(byId["ace-step"] == nil)
    }

    @Test("no key material or length ever appears in the response JSON")
    func responseCarriesNoKeyMaterial() async throws {
        let store = InMemoryKeyStore([.openai: "sk-openai-SECRET-9999"])
        let env = ["ANTHROPIC_API_KEY": "sk-ant-SECRET-1111"]
        let router = makeRouter(store: store, environment: env)

        let response = await router.handle(ControlRequest(id: "1", command: "ai.providerStatus"))
        let data = try JSONEncoder().encode(response)
        let json = String(data: data, encoding: .utf8)!

        #expect(!json.contains("sk-openai-SECRET-9999"))
        #expect(!json.contains("sk-ant-SECRET-1111"))
        #expect(!json.contains("SECRET"))
        // A length leak would surface the character count of a key; neither key's
        // length appears as a value in the payload.
        #expect(!json.contains("\"length\""))
        #expect(!json.contains("\"lastFour\""))
    }

    @Test("all-none when nothing is configured")
    func allNoneWhenEmpty() async throws {
        let router = makeRouter(store: InMemoryKeyStore(), environment: [:])
        let response = await router.handle(ControlRequest(id: "1", command: "ai.providerStatus"))
        #expect(response.ok)
        let providers = response.result?["providers"]?.arrayValue ?? []
        #expect(providers.count == 3)
        for item in providers {
            #expect(item["configured"]?.boolValue == false)
            #expect(item["source"]?.stringValue == "none")
        }
    }

    @Test("takes no params and ignores extras harmlessly")
    func ignoresExtras() async throws {
        let router = makeRouter(store: InMemoryKeyStore(), environment: [:])
        let response = await router.handle(
            ControlRequest(id: "1", command: "ai.providerStatus", params: ["unused": .bool(true)]))
        #expect(response.ok)
    }
}
