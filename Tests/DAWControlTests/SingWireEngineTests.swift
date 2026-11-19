import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-e part 2: the engine verbs (design §6 rows 1–6, 10) through the router, and the two human acts:
/// `sing.installEngine` / `sing.uninstallEngine` from the wire ASK (user ruling `sing-consent` = "Ask me first") and
/// `sing.openVoiceRecorder` only opens a window that registered. A scripted engine and a counting install function
/// stand in for the sidecar and install.sh; nothing downloads, nothing outside a temp folder is touched.
@Suite("SingWire — the engine verbs, the consent seam and the recorder seam (p2-sing-e)")
struct SingWireEngineTests {

    struct Rig {
        let router: CommandRouter
        let services: SingWireServices
        let engine: SingWireFakeEngine
        let jobs: SingWireFakeJobs
        let probe: SingWireInstallProbe
        let root: URL
        let runtime: URL
    }

    private func rig(state: SingingSidecarState = .notInstalled, autoConsent: Bool = false,
                     freeDisk: Int64 = 1 << 50, port: UInt16? = nil) async throws -> Rig {
        let root = try SingWireFixture.tempDir("engine")
        let base = URL(string: "http://127.0.0.1:\(try port ?? SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let config = SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle)
        let engine = SingWireFakeEngine(config: config, state: state)
        let jobs = SingWireFakeJobs()
        let probe = SingWireInstallProbe()
        let trash = SingWireFixture.trash(into: root)
        return try await MainActor.run {
            let (store, _) = try SingWireFixture.store(root: root)
            let services = SingWireFixture.services(
                root: root, engine: engine, jobs: jobs, installFunction: probe.function, autoConsent: autoConsent,
                freeDiskBytes: { _ in freeDisk }, trash: trash)
            return Rig(router: CommandRouter(store: store, singServices: services), services: services,
                       engine: engine, jobs: jobs, probe: probe, root: root, runtime: config.runtimeDir!)
        }
    }

    private func call(_ rig: Rig, _ verb: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await rig.router.handle(SingWireFixture.request(verb, params))
    }

    // MARK: Without the services

    @Test("a router built without the singing services refuses the engine and voice verbs in words; the four store verbs still answer")
    func bareRouterRefusesEngineVerbs() async throws {
        let root = try SingWireFixture.tempDir("bare")
        let (router, clipID) = try await MainActor.run { () -> (CommandRouter, UUID) in
            let (store, clipID) = try SingWireFixture.store(root: root, lyrics: SingWireFixture.twoUnitLyrics)
            return (CommandRouter(store: store), clipID)
        }
        let status = await router.handle(SingWireFixture.request("sing.sidecarStatus"))
        #expect(status.error == "singNotConnected: sing.sidecarStatus needs the singing engine, which is not connected "
            + "in this control session. Start DAW Pro (or run `swift run DAWApp`) and send it to that app's control port.")
        let engineVerbs: [(String, [String: JSONValue])] = [
            ("sing.sidecarStart", [:]), ("sing.sidecarStop", [:]), ("sing.installEngine", [:]),
            ("sing.cancelInstall", [:]), ("sing.uninstallEngine", [:]), ("sing.listVoices", [:]),
            ("sing.addVoice", ["path": .string("/tmp/none.wav")]), ("sing.removeVoice", ["voiceId": .string("voice-x")]),
            ("sing.render", ["clipId": .string(clipID.uuidString)]), ("sing.jobStatus", [:]),
            ("sing.cancelJob", ["jobId": .string("sing-x")]),
        ]
        for (verb, params) in engineVerbs {
            let response = await router.handle(SingWireFixture.request(verb, params))
            #expect(response.error?.hasPrefix("singNotConnected: \(verb) needs the singing engine") == true,
                    "\(verb): \(response.error ?? "ok")")
        }
        for (verb, params) in [("clip.getLyrics", ["clipId": JSONValue.string(clipID.uuidString)]),
                               ("sing.proposeKey", ["clipId": .string(clipID.uuidString)]),
                               ("project.transpose", ["semitones": .number(0), "dryRun": .bool(true)]),
                               ("sing.render", ["clipId": .string(clipID.uuidString), "dryRun": .bool(true)])] {
            let response = await router.handle(SingWireFixture.request(verb, params))
            #expect(response.ok, "\(verb): \(response.error ?? "")")
        }
    }

    // MARK: Status and start, against the REAL manager's words

    @Test("against the real manager with nothing installed: status reads notInstalled and start refuses with its sentence")
    func realManagerNotInstalled() async throws {
        let root = try SingWireFixture.tempDir("real-notinstalled")
        let base = URL(string: "http://127.0.0.1:\(try SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let config = SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle)
        try FileManager.default.createDirectory(at: config.runtimeDir!, withIntermediateDirectories: true)
        let manager = SingingSidecarManager(configuration: config)
        let jobs = SingWireFakeJobs()
        let probe = SingWireInstallProbe()
        let router = try await MainActor.run { () -> CommandRouter in
            let (store, _) = try SingWireFixture.store(root: root)
            let services = SingWireFixture.services(root: root, engine: manager, jobs: jobs,
                                                    installFunction: probe.function,
                                                    trash: SingWireFixture.trash(into: root))
            return CommandRouter(store: store, singServices: services)
        }
        let sentence = "The singing engine is not installed. Call sing.installEngine to start the one-time download "
            + "(about 7 GB) \u{2014} it asks first; nothing downloads until you say yes."
        let status = await router.handle(SingWireFixture.request("sing.sidecarStatus"))
        #expect(status.ok, "\(status.error ?? "")")
        #expect(status.result?["state"]?.stringValue == "notInstalled")
        #expect(status.result?["message"]?.stringValue == sentence)
        #expect(status.result?["resident"]?.boolValue == false)
        let start = await router.handle(SingWireFixture.request("sing.sidecarStart"))
        #expect(start.error == "singEngineNotInstalled: \(sentence)")
    }

    @Test("start: needsUpdate and a failed boot read in words; a foreign listener on the port is refused BEFORE any start")
    func startRefusals() async throws {
        let update = try await self.rig(state: .needsUpdate)
        #expect(await call(update, "sing.sidecarStart").error == "singEngineNeedsUpdate: fake engine: needsUpdate")

        let failing = try await self.rig(state: .installedNotRunning)
        await failing.engine.failStart(with: SidecarError.launchFailed(
            "the singing engine's process exited during startup \u{2014} check /x/sing.log."))
        #expect(await call(failing, "sing.sidecarStart").error
            == "singStartFailed: The singing engine couldn't start: the singing engine's process exited during "
                + "startup \u{2014} check /x/sing.log. Call sing.sidecarStart to try again.")

        let loads = try await self.rig(state: .installedNotRunning)
        await loads.engine.startLeaves(.error)
        #expect(await call(loads, "sing.sidecarStart").error
            == "singStartFailed: The singing engine couldn't start: fake engine: error. Call sing.sidecarStart to try again.")

        // A real listening socket on the engine's port, owned by THIS process (so not the engine's pidfile pid).
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(listen(fd, 1) == 0)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let busyPort = UInt16(bigEndian: bound.sin_port)
        let busy = try await self.rig(state: .installedNotRunning, port: busyPort)
        let refused = await call(busy, "sing.sidecarStart")
        #expect(refused.error?.hasPrefix("singPortBusy: Port \(busyPort) is already in use by something that is not "
            + "the singing engine: pid \(getpid()) (") == true, "\(refused.error ?? "ok")")
        #expect(refused.error?.hasSuffix(". Stop it, or set SING_API_URL to point the singing engine at a different port.")
            == true)
        #expect(await busy.engine.startCount == 0, "a doomed start is refused before the engine is asked")

        let healthy = try await self.rig(state: .healthy)
        let already = await call(healthy, "sing.sidecarStart")
        #expect(already.result?["state"]?.stringValue == "ready")
        #expect(await healthy.engine.startCount == 0)
    }

    // MARK: The consent seam

    @Test("CONSENT: sing.installEngine from the wire ASKS — nothing installs until the window's click approves it")
    func installFromTheWireAsksFirst() async throws {
        let rig = try await self.rig()
        defer { rig.probe.release() }
        let posted = SingWireCallLog()
        await MainActor.run { rig.services.consent.onRequest = { posted.append($0.id) } }

        let first = await call(rig, "sing.installEngine")
        #expect(first.ok, "\(first.error ?? "")")
        #expect(first.result?["state"]?.stringValue == "awaitingUserConsent")
        #expect(first.result?["message"]?.stringValue == "DAW Pro is asking for permission to download the singing "
            + "engine (about 7 GB, one time). Nothing downloads until Install is clicked in DAW Pro's window. Poll "
            + "sing.sidecarStatus to see when it starts.")
        let requestID = try #require(first.result?["requestId"]?.stringValue)
        #expect(rig.probe.calls == 0, "NOTHING installs on the wire's word")
        #expect(await rig.services.install.status().state == .idle)

        let second = await call(rig, "sing.installEngine")
        #expect(second.result?["requestId"]?.stringValue == requestID, "one window, never a stack of them")
        #expect(posted.calls == [requestID])
        #expect(rig.probe.calls == 0)
        let pending = await MainActor.run { rig.services.consent.pending }
        #expect(pending.count == 1)
        #expect(pending.first?.fromAgent == true && pending.first?.action == .installEngine)
        #expect(pending.first?.message == "An AI agent wants to install the singing engine: about 7 GB, one time.")
        #expect(await call(rig, "sing.sidecarStatus").result?["state"]?.stringValue == "awaitingUserConsent")

        // The user's click.
        try await rig.services.consent.approve(id: requestID)
        #expect(await SingWireFixture.waitUntil(5) { rig.probe.calls == 1 })
        #expect(await rig.services.install.status().state == .installing)
        #expect(await call(rig, "sing.sidecarStatus").result?["state"]?.stringValue == "installing")
        #expect(await MainActor.run { rig.services.consent.pending.isEmpty })
        rig.probe.release()
        #expect(await SingWireFixture.waitUntil(5) { await rig.services.install.status().state == .succeeded })
    }

    @Test("CONSENT: \"Not now\" installs nothing; the staging flag (autoConsent) installs at once and posts nothing")
    func declineAndAutoConsent() async throws {
        let rig = try await self.rig()
        let asked = await call(rig, "sing.installEngine")
        let requestID = try #require(asked.result?["requestId"]?.stringValue)
        try await MainActor.run { try rig.services.consent.decline(id: requestID) }
        #expect(await MainActor.run { rig.services.consent.pending.isEmpty })
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.probe.calls == 0)
        await #expect(throws: SingConsentError.noSuchRequest(requestID)) {
            try await rig.services.consent.approve(id: requestID)
        }
        #expect(rig.probe.calls == 0)

        let auto = try await self.rig(autoConsent: true)
        defer { auto.probe.release() }
        let installing = await call(auto, "sing.installEngine")
        #expect(installing.result?["state"]?.stringValue == "installing", "\(installing.error ?? "")")
        #expect(await SingWireFixture.waitUntil(5) { auto.probe.calls == 1 })
        #expect(await MainActor.run { auto.services.consent.pending.isEmpty })
        let again = await call(auto, "sing.installEngine")
        #expect(again.error == "singInstallInProgress: Already installing the singing engine \u{2014} poll "
            + "sing.sidecarStatus and wait for it to reach a terminal state (succeeded, failed or cancelled) before "
            + "starting again. Only one singing-engine install runs at a time.")
    }

    @Test("cancelInstall withdraws a request still waiting; with nothing running it refuses in words")
    func cancelInstall() async throws {
        let rig = try await self.rig()
        let asked = await call(rig, "sing.installEngine")
        let requestID = try #require(asked.result?["requestId"]?.stringValue)
        let withdrawn = await call(rig, "sing.cancelInstall")
        #expect(withdrawn.result?["cancelRequested"]?.boolValue == true)
        #expect(withdrawn.result?["withdrewRequestId"]?.stringValue == requestID)
        #expect(await MainActor.run { rig.services.consent.pending.isEmpty })
        #expect(await call(rig, "sing.cancelInstall").error
            == "singNoInstallRunning: No singing-engine install is running, so there is nothing to cancel.")
        #expect(rig.probe.calls == 0)
    }

    @Test("install refuses with the measured free space, and answers alreadyInstalled for an engine that is there")
    func installDiskAndAlreadyInstalled() async throws {
        let full = try await self.rig(freeDisk: 1_000_000_000)
        #expect(await call(full, "sing.installEngine").error
            == "singDiskFull: Installing the singing engine needs 12.9 GB free on this Mac's disk, and only 1.0 GB "
                + "is free. Free up some space, then try again.")
        #expect(await MainActor.run { full.services.consent.pending.isEmpty }, "a refused install asks nothing")

        let installed = try await self.rig(state: .installedNotRunning)
        let reply = await call(installed, "sing.installEngine")
        #expect(reply.result?["state"]?.stringValue == "alreadyInstalled", "\(reply.error ?? "")")
        #expect(installed.probe.calls == 0)
    }

    @Test("CONSENT: uninstall from the wire asks; only the click deletes, and only the SingingEngine folder")
    func uninstallAsksFirst() async throws {
        let rig = try await self.rig(state: .installedNotRunning)
        let fm = FileManager.default
        try fm.createDirectory(at: rig.runtime.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data(count: 1_000_000).write(to: rig.runtime.appendingPathComponent("weights/model.pt"))
        let voices = rig.root.appendingPathComponent("voices", isDirectory: true)
        try fm.createDirectory(at: voices, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: voices.appendingPathComponent("keep.txt"))

        let dry = await call(rig, "sing.uninstallEngine", ["dryRun": .bool(true)])
        #expect(dry.ok, "\(dry.error ?? "")")
        #expect((dry.result?["wouldFreeBytes"]?.doubleValue ?? 0) >= 1_000_000)
        let asked = await call(rig, "sing.uninstallEngine")
        #expect(asked.result?["state"]?.stringValue == "awaitingUserConsent", "\(asked.error ?? "")")
        let requestID = try #require(asked.result?["requestId"]?.stringValue)
        #expect(fm.fileExists(atPath: rig.runtime.path), "NOTHING is deleted on the wire's word")
        #expect(await rig.engine.stopCount == 0)

        try await rig.services.consent.approve(id: requestID)
        #expect(!fm.fileExists(atPath: rig.runtime.path))
        #expect(await rig.engine.stopCount == 1, "the engine is stopped before its folder goes")
        #expect(fm.fileExists(atPath: voices.appendingPathComponent("keep.txt").path), "voices stay")

        let gone = await call(rig, "sing.uninstallEngine")
        #expect(gone.result?["installed"]?.boolValue == false)
    }

    @Test("uninstall and stop refuse while a take is being sung; stop with cancelJobs cancels it first")
    func jobsRunningRefusals() async throws {
        let rig = try await self.rig(state: .healthy)
        try FileManager.default.createDirectory(at: rig.runtime, withIntermediateDirectories: true)
        await rig.jobs.hold([SingWireFakeJobs.status(id: "sing-live", phase: .singing)])
        #expect(await call(rig, "sing.uninstallEngine").error
            == "singJobsRunning: A take is being sung right now. Wait for it to finish, or stop it with sing.cancelJob, "
                + "before removing the singing engine.")
        #expect(await call(rig, "sing.sidecarStop").error
            == "singJobsRunning: A take is being sung right now. Wait for it to finish (sing.jobStatus), or send "
                + "cancelJobs: true to stop it and the engine together.")
        #expect(await rig.engine.stopCount == 0)
        let stopped = await call(rig, "sing.sidecarStop", ["cancelJobs": .bool(true)])
        #expect(stopped.ok, "\(stopped.error ?? "")")
        #expect(await rig.jobs.cancelled == ["sing-live"])
        #expect(stopped.result?["cancelledJobs"]?.arrayValue == [.string("sing-live")])
        #expect(stopped.result?["stopped"]?.boolValue == true)
        #expect(stopped.result?["evidence"]?["portFree"]?.boolValue == true)
        #expect(await rig.engine.stopCount == 1)
    }

    @Test("status: an install with a marker but missing pieces reads error, naming them; verify hashes the weights")
    func statusPreflightAndVerify() async throws {
        let rig = try await self.rig(state: .installedNotRunning)
        let fm = FileManager.default
        try fm.createDirectory(at: rig.runtime.appendingPathComponent("weights"), withIntermediateDirectories: true)
        let weights = Data("weights".utf8)
        try weights.write(to: rig.runtime.appendingPathComponent("weights/model.pt"))
        let sha = SHA256Hex.of(weights)
        try JSONSerialization.data(withJSONObject: ["weightsSha256": sha, "installedBytes": 7])
            .write(to: rig.runtime.appendingPathComponent("install.json"))
        let status = await call(rig, "sing.sidecarStatus", ["verify": .bool(true)])
        #expect(status.result?["state"]?.stringValue == "error")
        #expect(status.result?["message"]?.stringValue == "The singing engine's install is incomplete: its Python "
            + "environment is missing; the built-in singer is missing. Call sing.installEngine to repair it.")
        #expect(status.result?["verify"]?["matches"]?.boolValue == true)
        #expect(status.result?["runtime"]?["installedBytes"]?.doubleValue == 7)

        try Data("tampered".utf8).write(to: rig.runtime.appendingPathComponent("weights/model.pt"))
        let tampered = await call(rig, "sing.sidecarStatus", ["verify": .bool(true)])
        #expect(tampered.result?["verify"]?["matches"]?.boolValue == false)
        let plain = await call(rig, "sing.sidecarStatus")
        #expect(plain.result?["verify"] == nil, "the hash runs only when asked")
    }

    // MARK: The recorder seam

    @Test("RECORDER: singNoWindow until a recorder registers; then it opens (fromAgent), and a released one is gone again")
    func openVoiceRecorderNeedsAWindow() async throws {
        let rig = try await self.rig()
        let none = "singNoWindow: No DAW Pro window can show the voice recorder right now. Open DAW Pro's main window "
            + "and try again, or add a recording you already have with sing.addVoice."
        #expect(await call(rig, "sing.openVoiceRecorder").error == none)
        var recorder: SingWireFakeRecorder? = await MainActor.run { SingWireFakeRecorder() }
        await MainActor.run { rig.router.singVoiceRecorder = recorder }
        let opened = await call(rig, "sing.openVoiceRecorder")
        #expect(opened.result?["opened"]?.boolValue == true, "\(opened.error ?? "")")
        #expect(await MainActor.run { recorder?.opened } == [true])
        recorder = nil
        #expect(await call(rig, "sing.openVoiceRecorder").error == none, "the router holds the window weakly")
    }
}

/// sha256 hex of some bytes (tests only).
enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
