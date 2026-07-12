import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for `app.connectionInfo` (beta m10-l): the read-only
/// endpoint-introspection command an agent uses to learn the URL/port it reached
/// the app on and whether an operator has customized it. The port is threaded into
/// the router at construction (the server owns the router), so these tests inject a
/// known `ControlConnectionInfo` and pin the wire shape. Port WRITING stays UI-only
/// (config that can sever the agent's own connection is a human decision — the
/// API-key-entry split precedent), so there's deliberately no write command to test.
@MainActor
@Suite("Connection info — control protocol (beta m10-l)")
struct ConnectionInfoCommandTests {

    @Test("allCommands advertises app.connectionInfo")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("app.connectionInfo"))
    }

    @Test("a bare router answers with the built-in default endpoint")
    func defaultShape() async throws {
        let router = CommandRouter(store: ProjectStore())
        let response = await router.handle(ControlRequest(id: "1", command: "app.connectionInfo"))
        #expect(response.ok)
        #expect(response.result?["url"]?.stringValue == "ws://127.0.0.1:17600")
        #expect(response.result?["port"]?.doubleValue == 17600)
        #expect(response.result?["source"]?.stringValue == "default")
        #expect(response.result?["defaultPort"]?.doubleValue == 17600)
    }

    @Test("the injected connection info drives the response (custom port + source)")
    func customShape() async throws {
        let router = CommandRouter(
            store: ProjectStore(),
            connectionInfo: ControlConnectionInfo(port: 9090, source: "settings", defaultPort: 17600))
        let response = await router.handle(ControlRequest(id: "1", command: "app.connectionInfo"))
        #expect(response.ok)
        #expect(response.result?["url"]?.stringValue == "ws://127.0.0.1:9090")
        #expect(response.result?["port"]?.doubleValue == 9090)
        #expect(response.result?["source"]?.stringValue == "settings")
        #expect(response.result?["defaultPort"]?.doubleValue == 17600)
    }

    @Test("an env-sourced endpoint reports source \"environment\" (staging harness honesty)")
    func environmentSource() async throws {
        // The staging harness binds DAW_CONTROL_PORT=17695; the command must report
        // that provenance so a client (and the Settings note) is honest about it.
        let router = CommandRouter(
            store: ProjectStore(),
            connectionInfo: ControlConnectionInfo(port: 17695, source: "environment", defaultPort: 17600))
        let response = await router.handle(ControlRequest(id: "1", command: "app.connectionInfo"))
        #expect(response.ok)
        #expect(response.result?["source"]?.stringValue == "environment")
        #expect(response.result?["port"]?.doubleValue == 17695)
    }

    @Test("unknown extra params are ignored (house style)")
    func paramTolerance() async throws {
        let router = CommandRouter(store: ProjectStore())
        let response = await router.handle(ControlRequest(
            id: "1", command: "app.connectionInfo", params: ["bogus": .number(7)]))
        #expect(response.ok)
        #expect(response.result?["port"]?.doubleValue == 17600)
    }

    @Test("the response never carries key material")
    func noKeyMaterial() async throws {
        let router = CommandRouter(store: ProjectStore())
        let response = await router.handle(ControlRequest(id: "1", command: "app.connectionInfo"))
        let keys = response.result?.objectValue?.keys.sorted()
        #expect(keys == ["defaultPort", "port", "source", "url"])
    }
}
