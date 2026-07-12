import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for `ControlPortConfig` + `ControlPortStore` (beta m10-l): the
/// control-server port resolver (env > persisted setting > default) and the in-app
/// setting field's validation. Pure functions, so the precedence matrix and the
/// validation edges are pinned without a running app — the same contract the
/// bootstrap (bind port) and the Settings → Agent Connection section depend on.
///
/// THE ENV OVERRIDE IS SACRED: the staging/test harness launches the app with
/// `DAW_CONTROL_PORT=17695`, so a persisted setting must NEVER outrank a parseable
/// env value. `envBeatsSettings` pins that directly.
@Suite("ControlPortConfig — port resolution + validation (beta m10-l)")
struct ControlPortConfigTests {

    // MARK: - Resolution precedence (env > settings > default)

    @Test("no env, no setting → the default 17600 (byte-identical to pre-m10-l)")
    func defaultFlows() {
        let r = ControlPortConfig.resolve(environment: [:], persisted: nil)
        #expect(r.port == 17600)
        #expect(r.source == .default)
        #expect(r.url == "ws://127.0.0.1:17600")
    }

    @Test("a persisted setting wins when there's no env override")
    func settingsBeatsDefault() {
        let r = ControlPortConfig.resolve(environment: [:], persisted: 9999)
        #expect(r.port == 9999)
        #expect(r.source == .settings)
        #expect(r.url == "ws://127.0.0.1:9999")
    }

    @Test("the env override outranks a persisted setting — the sacred rule")
    func envBeatsSettings() {
        // The staging harness pins 17695; a stored 9999 must not win.
        let r = ControlPortConfig.resolve(
            environment: ["DAW_CONTROL_PORT": "17695"], persisted: 9999)
        #expect(r.port == 17695)
        #expect(r.source == .environment)
    }

    @Test("the env override outranks even the default (no setting)")
    func envBeatsDefault() {
        let r = ControlPortConfig.resolve(
            environment: ["DAW_CONTROL_PORT": "8000"], persisted: nil)
        #expect(r.port == 8000)
        #expect(r.source == .environment)
    }

    @Test("env present but non-numeric falls through to the setting")
    func nonNumericEnvFallsThroughToSetting() {
        let r = ControlPortConfig.resolve(
            environment: ["DAW_CONTROL_PORT": "not-a-port"], persisted: 4242)
        #expect(r.port == 4242)
        #expect(r.source == .settings)
    }

    @Test("env present but non-numeric AND no setting falls through to the default")
    func nonNumericEnvFallsThroughToDefault() {
        let r = ControlPortConfig.resolve(
            environment: ["DAW_CONTROL_PORT": ""], persisted: nil)
        #expect(r.port == 17600)
        #expect(r.source == .default)
    }

    @Test("env that overflows UInt16 falls through (matches the old UInt16.init behavior)")
    func overflowingEnvFallsThrough() {
        let r = ControlPortConfig.resolve(
            environment: ["DAW_CONTROL_PORT": "70000"], persisted: nil)
        #expect(r.port == 17600)
        #expect(r.source == .default)
    }

    @Test("a low env value is NOT range-checked — env keeps its historical latitude")
    func envIsNotRangeChecked() {
        // The env branch deliberately keeps `UInt16.init` semantics: port 80 parses
        // and is honored (a shell can pin anything). Only the SETTINGS field is
        // range-gated (see validate).
        let r = ControlPortConfig.resolve(
            environment: ["DAW_CONTROL_PORT": "80"], persisted: nil)
        #expect(r.port == 80)
        #expect(r.source == .environment)
    }

    // MARK: - Validation edges (the settings field)

    @Test("validate accepts the in-range boundaries and rejects the neighbors")
    func validateBoundaries() {
        #expect(ControlPortConfig.validate("1023") == nil)   // just below floor
        #expect(ControlPortConfig.validate("1024") == 1024)  // floor
        #expect(ControlPortConfig.validate("65535") == 65535)// ceiling
        #expect(ControlPortConfig.validate("65536") == nil)  // just above ceiling (also UInt16 overflow)
        #expect(ControlPortConfig.validate("17600") == 17600)
    }

    @Test("validate rejects garbage, empty, and whitespace-only input")
    func validateJunk() {
        #expect(ControlPortConfig.validate("") == nil)
        #expect(ControlPortConfig.validate("   ") == nil)
        #expect(ControlPortConfig.validate("abc") == nil)
        #expect(ControlPortConfig.validate("80.5") == nil)
        #expect(ControlPortConfig.validate("-1") == nil)
        #expect(ControlPortConfig.validate("9999x") == nil)
    }

    @Test("validate trims surrounding whitespace before parsing")
    func validateTrims() {
        #expect(ControlPortConfig.validate("  9000  ") == 9000)
        #expect(ControlPortConfig.validate("\t2000\n") == 2000)
    }

    // MARK: - Store (round-trip + commit + resolution)

    @MainActor
    @Test("a never-set store has no configured port (default flows)")
    func storeDefaults() {
        let store = ControlPortStore(backing: InMemoryControlPortBacking())
        #expect(store.configuredPort == nil)
        #expect(store.resolution(environment: [:]).source == .default)
        #expect(store.resolution(environment: [:]).port == 17600)
    }

    @MainActor
    @Test("commit persists a valid port and rejects an invalid one (nothing changes)")
    func storeCommit() {
        let backing = SpyBacking()
        let store = ControlPortStore(backing: backing)

        #expect(store.commit("9090") == 9090)
        #expect(store.configuredPort == 9090)
        #expect(backing.writes == [9090])

        // Invalid input persists nothing and leaves the current setting intact.
        #expect(store.commit("80") == nil)          // below the floor
        #expect(store.commit("nope") == nil)        // garbage
        #expect(store.commit("") == nil)            // empty
        #expect(store.configuredPort == 9090)       // unchanged
        #expect(backing.writes == [9090])           // no extra writes
    }

    @MainActor
    @Test("a store loads its persisted port and resolves it as source .settings")
    func storeLoadsPersisted() {
        let store = ControlPortStore(backing: InMemoryControlPortBacking(4321))
        #expect(store.configuredPort == 4321)
        let r = store.resolution(environment: [:])
        #expect(r.port == 4321)
        #expect(r.source == .settings)
    }

    @MainActor
    @Test("a store with a persisted port STILL yields to the env override")
    func storeYieldsToEnv() {
        let store = ControlPortStore(backing: InMemoryControlPortBacking(4321))
        let r = store.resolution(environment: ["DAW_CONTROL_PORT": "17695"])
        #expect(r.port == 17695)
        #expect(r.source == .environment)
    }

    @MainActor
    @Test("a store treats an out-of-range persisted value as no setting")
    func storeIgnoresCorruptPersisted() {
        // 80 is below the valid floor — a stale/corrupt UserDefaults entry must not
        // bind a bad port; it reads as "no setting" so the default flows.
        let store = ControlPortStore(backing: InMemoryControlPortBacking(80))
        #expect(store.configuredPort == nil)
        #expect(store.resolution(environment: [:]).source == .default)
    }

    /// A spy backing that records writes, so the suite can prove commit persists
    /// only valid input (and only through the backing).
    @MainActor
    final class SpyBacking: ControlPortBacking {
        private(set) var writes: [UInt16] = []
        private var storage: UInt16?

        init(_ initial: UInt16? = nil) { self.storage = initial }

        func loadPort() -> UInt16? { storage }
        func storePort(_ port: UInt16) {
            writes.append(port)
            storage = port
        }
    }
}
