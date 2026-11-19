import Foundation
import Testing
@testable import AIServices

/// p2-sing-x7b: THE pre-consent seam (`SingInstallPreflight`) both install doors call — `sing.installEngine` and the
/// Sing sheet's install path (x8). Nonisolated. The host is injected, so the check is made to FAIL on this machine
/// (a positive control), and its sentences are the ones `sing.installEngine` has always sent (pinned in
/// `SingWireEngineTests.installDiskAndAlreadyInstalled`).
@Suite("SingInstallPreflight — the Mac and free-disk checks before an install is offered (p2-sing-x7b)")
struct SingInstallPreflightTests {

    static let good = SingInstallPreflight.Host(isAppleSilicon: true, isMacOS14OrLater: true)
    static let need: Int64 = SingEngineFiles.fallbackMinFreeKB * 1024

    @Test("a supported Mac with room passes; an unreadable free space does not refuse")
    func passes() {
        #expect(SingInstallPreflight.check(host: Self.good, needBytes: Self.need, freeBytes: Self.need) == nil)
        #expect(SingInstallPreflight.check(host: Self.good, needBytes: Self.need, freeBytes: nil) == nil)
    }

    @Test("an Intel Mac, or one before macOS 14, is refused first, word for word")
    func unsupportedMac() {
        let expected = SingInstallPreflight.Refusal(
            code: "singUnsupportedMac",
            sentence: "The singing engine needs a Mac with Apple silicon (an M-series chip) running macOS 14 or later, "
                + "so it can't be installed on this Mac.")
        for host in [SingInstallPreflight.Host(isAppleSilicon: false, isMacOS14OrLater: true),
                     SingInstallPreflight.Host(isAppleSilicon: true, isMacOS14OrLater: false)] {
            #expect(SingInstallPreflight.check(host: host, needBytes: Self.need, freeBytes: 1) == expected,
                    "the Mac is judged before the disk")
        }
    }

    @Test("too little free disk is refused with the measured numbers, word for word")
    func diskFull() {
        let refusal = SingInstallPreflight.check(host: Self.good, needBytes: Self.need, freeBytes: 1_000_000_000)
        #expect(refusal == SingInstallPreflight.Refusal(
            code: "singDiskFull",
            sentence: "Installing the singing engine needs 12.9 GB free on this Mac's disk, and only 1.0 GB is free. "
                + "Free up some space, then try again."))
        #expect(refusal?.errorDescription == refusal?.sentence)
    }

    @Test("from the engine's files: the floor from pins (fallback 12 GiB), the free space where the engine goes")
    func fromEngineFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("x7b-preflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("SingingEngine", isDirectory: true)
        let files = SingEngineFiles(runtimeDir: runtime, scriptsDir: nil)
        var asked: [URL] = []
        let low = SingInstallPreflight.check(engineFiles: files, runtimeDir: runtime,
                                             freeDiskBytes: { asked.append($0); return 2_000_000_000 },
                                             host: Self.good)
        #expect(low?.code == "singDiskFull")
        #expect(asked == [runtime], "the free space is read where the engine goes")
        #expect(SingInstallPreflight.check(engineFiles: files, runtimeDir: nil, freeDiskBytes: { _ in 0 },
                                           host: Self.good) == nil, "no folder: only the Mac is checked")
    }

    @Test("POSITIVE CONTROL: this Mac passes as itself, and the same call refuses once the host is made unsupported")
    func positiveControl() {
        #if arch(arm64)
        #expect(SingInstallPreflight.Host.current.isAppleSilicon)
        #expect(SingInstallPreflight.check(needBytes: 0, freeBytes: nil) == nil)
        #endif
        var host = SingInstallPreflight.Host.current
        host.isAppleSilicon = false
        #expect(SingInstallPreflight.check(host: host, needBytes: 0, freeBytes: nil)?.code == "singUnsupportedMac")
    }
}
