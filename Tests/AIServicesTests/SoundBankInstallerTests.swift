import Foundation
import CryptoKit
import Testing
import DAWCore
@testable import AIServices

// MARK: - Fixture

/// Builds a real-shaped `.sf2` and a temp sound-bank library, with NO NETWORK
/// ANYWHERE.
///
/// ## Why the fixture puts a big `sdta` chunk BEFORE `pdta`
///
/// That is the layout of a real SoundFont: sample data first, preset headers
/// after it. It is the whole reason the `namesParsed` sentinel works — a
/// transfer that dies partway through the (much larger) sample data takes the
/// `phdr` chunk with it. A fixture with `pdta` first would still "fail to
/// parse" when truncated, but it would fail for a reason the real file does not
/// have, and the control would be theatre.
///
/// ⛔ Never points at `~/Library/Application Support/DAWPro/SoundBanks` — the
/// user's real library must not be reachable from a test run.
private struct BankFixture {
    let root: URL
    let libraryDirectory: URL
    /// A complete, parseable `.sf2` sitting outside the library — what a
    /// "server" hands over.
    let sourceFile: URL
    let sourceBytes: Data

    init(presets: [(name: String, preset: Int, bank: Int)] = [
        ("Test Grand", 0, 0), ("Test Brush Kit", 40, 128),
    ], sampleDataBytes: Int = 4096) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundbank-installer-\(UUID().uuidString)")
        libraryDirectory = root.appendingPathComponent("SoundBanks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sourceBytes = BankFixture.makeSF2(presets, sampleDataBytes: sampleDataBytes)
        sourceFile = root.appendingPathComponent("source.sf2")
        try sourceBytes.write(to: sourceFile)
    }

    func destroy() { try? FileManager.default.removeItem(at: root) }

    /// A library whose ONLY scan directory is the fixture's own — so `scan()`
    /// cannot see the machine's real banks and a test's assertions are about
    /// what this test put there.
    var library: SoundBankLibrary {
        SoundBankLibrary(libraryDirectory: libraryDirectory,
                         scanDirectories: [libraryDirectory])
    }

    /// What `scan()` found in the LIBRARY, with the built-in General MIDI
    /// entry dropped. ⚠️ `SoundBankLibrary.scan()` ALWAYS prepends the system
    /// GM bank (`SoundBanks.swift:243`) whatever `scanDirectories` says, so a
    /// bare `scan().isEmpty` assertion is false on every machine and a bare
    /// `count == 1` counts the wrong thing.
    func scannedFiles() -> [SoundBankInfo] {
        library.scan().filter { !$0.builtin }
    }

    /// A catalog entry describing arbitrary bytes: size and SHA-256 computed
    /// here, independently of the code under test (whole-file CryptoKit rather
    /// than `SoundBankInstaller`'s chunked reader), so a bug shared by both
    /// cannot make a test pass.
    func descriptor(for data: Data, fileName: String = "Fixture_Bank.sf2",
                    id: String = "fixture") -> DownloadableSoundBank {
        DownloadableSoundBank(
            id: id, name: "Fixture Bank",
            url: URL(string: "https://example.invalid/\(fileName)")!,
            fileName: fileName, expectedBytes: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            licence: "MIT", attribution: "Fixture", summary: "A fixture.")
    }

    /// The catalog entry for the intact fixture file.
    var goodDescriptor: DownloadableSoundBank { descriptor(for: sourceBytes) }

    /// A transfer that writes `data` to the destination — the seam that makes
    /// every install-path test offline.
    static func transfer(_ data: Data) -> SoundBankInstaller.TransferFunction {
        { _, destination, _, progress in
            progress(0, Int64(data.count))
            try data.write(to: destination)
            progress(Int64(data.count), Int64(data.count))
        }
    }

    // MARK: Minimal SF2 synthesis (the SoundFontPresetReaderTests idiom)

    private static func u16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func u32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func fourCC(_ tag: String) -> [UInt8] { Array(tag.utf8) }

    private static func nameField(_ name: String) -> [UInt8] {
        var bytes = Array(name.utf8.prefix(19))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 20 - bytes.count))
        return bytes
    }

    private static func phdrRecord(name: String, preset: Int, bank: Int) -> [UInt8] {
        nameField(name) + u16(preset) + u16(bank) + u16(0) + u32(0) + u32(0) + u32(0)
    }

    private static func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        fourCC(id) + u32(payload.count) + payload
    }

    /// `RIFF sfbk → LIST sdta (bulk) → LIST pdta → phdr`. The terminal EOP
    /// record is included, per the SF2 spec — the reader drops it.
    static func makeSF2(_ presets: [(name: String, preset: Int, bank: Int)],
                        sampleDataBytes: Int) -> Data {
        var phdr: [UInt8] = []
        for entry in presets {
            phdr += phdrRecord(name: entry.name, preset: entry.preset, bank: entry.bank)
        }
        phdr += phdrRecord(name: "EOP", preset: 0, bank: 0)

        // Sample data first — the real ordering, and what makes a truncation
        // control faithful.
        let smpl = chunk("smpl", (0..<sampleDataBytes).map { UInt8($0 % 251) })
        let sdta = chunk("LIST", fourCC("sdta") + smpl)
        let pdta = chunk("LIST", fourCC("pdta") + chunk("phdr", phdr))
        return Data(chunk("RIFF", fourCC("sfbk") + sdta + pdta))
    }
}

// MARK: - Tests

@Suite("Sound-bank download installer (m34-c)")
struct SoundBankInstallerTests {

    // MARK: The catalog pin

    @Test("the MuseScore General pin is exactly what was measured, with an honest label")
    func catalogPin() {
        let bank = DownloadableSoundBankCatalog.museScoreGeneral
        // ⚠️ SELF-COMPUTED 2026-08-30 by downloading the file once and running
        // `shasum -a 256`. It is an integrity pin (corruption/truncation), NOT
        // an authenticity one — nobody upstream publishes a hash for this file.
        // The byte count independently matches the mirror's own Content-Length.
        #expect(bank.expectedBytes == 215_614_036)
        #expect(bank.sha256 == "ee51d2c4b1525e70f19a45909c4fd7a2e26d91d115fa89dbf5a6bc413d8b9bf3")
        // ⚠️⚠️ **UPDATED 2026-08-30 — the primary MOVED, by the user's decision
        // to mirror the bank ourselves and keep upstream as a fallback.** This
        // assertion previously pinned the osuosl URL as the primary; that URL is
        // still pinned, now as `fallbackURLs.first`, in
        // `catalogMirrorsPrimaryWithUpstreamFallback`. **Nothing was weakened —
        // the same two facts are asserted, in their new roles.**
        //
        // ⛔⛔ **DO NOT "FIX" THIS BACK ON SEEING `github.com`.** The old comment
        // said "deliberately NOT the GitHub repo", and both things are now true
        // at once, which is exactly how a future reader gets this wrong:
        //   • REJECTED — `github.com/musescore/MuseScore`: upstream's own repo,
        //     which now ships `.sf3` ONLY (the Vorbis decoder is measured to fail
        //     on 17 of 1186 streams of a sibling file).
        //   • CHOSEN — `github.com/dimichgh/daw-pro/releases/...`: OUR release
        //     asset, holding a byte-identical copy of the NATIVE `.sf2`.
        // The host is the same; the file and the publisher are not.
        #expect(bank.url.absoluteString
            == "https://github.com/dimichgh/daw-pro/releases/download/"
            + "soundbanks-v1/MuseScore_General.sf2")
        // The rejected upstream repo must appear nowhere in the source list.
        for source in bank.allSources {
            #expect(!source.absoluteString.contains("musescore/MuseScore"),
                    "\(source) is the .sf3-only repo the spike rejected")
            #expect(source.absoluteString.hasSuffix(".sf2"),
                    "\(source) is not the native .sf2")
        }
        #expect(bank.fileName.hasSuffix(".sf2"))
        #expect(SoundBankLibrary.isSupportedExtension("sf2"))
        // Licensing is the whole item: the terms travel with the entry.
        #expect(bank.licence == "MIT")
        #expect(bank.attribution.contains("Cowgill"))
        #expect(bank.attribution.contains("Frank Wen"))
        // ⛔⛔ **ALL FIVE, AND THIS PIN EXISTS BECAUSE TWO OF THEM WERE MISSING.**
        // The first version named only Cowgill and Wen — under a comment claiming
        // to be "verbatim … not paraphrased, not extended" — and the two
        // assertions above passed happily, because a `contains` check on a
        // shrinking list can never fail. **The omitted Collins is the author of
        // THIS FILE** (the MuseScore_General adaptation); he also wrote
        // GeneralUser GS, the rejected runner-up, which is how they were
        // conflated. Re-fetched from `MuseScore_General_License.md` 2026-08-30.
        // MIT's condition is that the notice travels with the work, so a trim
        // for layout is a licence defect, not a formatting choice.
        for holder in ["Frank Wen", "Michael Cowgill", "S. Christian Collins",
                       "Ethan Winer", "Michael Schorsch"] {
            #expect(bank.attribution.contains(holder),
                    "the licence names \(holder); the shipped notice does not")
        }
        // NEGATIVE CONTROL: the assertion above must be capable of failing —
        // otherwise "contains every name" is vacuous however long the list gets.
        #expect(!bank.attribution.contains("S. Christian Collins Jr."),
                "control: a name NOT in the licence must not be found")
        #expect(DownloadableSoundBankCatalog.bank(id: "musescore-general") == bank)
        #expect(DownloadableSoundBankCatalog.bank(id: "nope") == nil)
    }

    // MARK: - We host it now (2026-08-30) — mirror primary, upstream fallback

    /// ⭐ The user chose "mirror it ourselves, keep upstream as a fallback".
    /// Hosting makes availability ours; the fallback means **two independent
    /// hosts must both die** before the feature does.
    @Test("the primary is our own mirror and upstream is kept as a fallback")
    func catalogMirrorsPrimaryWithUpstreamFallback() {
        let bank = DownloadableSoundBankCatalog.museScoreGeneral
        #expect(bank.url.host == "github.com",
                "primary should be our release asset, got \(bank.url.host ?? "nil")")
        #expect(bank.fallbackURLs.count == 1)
        #expect(bank.fallbackURLs.first?.host == "ftp.osuosl.org")
        // ⛔ Order matters: `allSources` IS the try order.
        #expect(bank.allSources == [bank.url] + bank.fallbackURLs)
        #expect(bank.allSources.count == 2)
        // ⚠️ The stable URL, never the signed redirect target — that one carries
        // an `se=` expiry and is minted per request.
        #expect(!bank.url.absoluteString.contains("release-assets."),
                "pinned the expiring signed URL instead of the durable one")
        // A fallback is a different HOST, never a different FILE.
        for source in bank.allSources {
            #expect(source.lastPathComponent == bank.fileName,
                    "\(source) does not serve \(bank.fileName)")
        }
    }

    /// ⛔⛔ We distribute it now, so MIT's notice condition attaches to us — and
    /// the licence file additionally asks that "the acknowledgements and
    /// copyright notices above must be included in any derivative work."
    @Test("the embedded notice carries every holder AND the permission notice")
    func licenceNoticeIsComplete() throws {
        let notice = try #require(DownloadableSoundBankCatalog.museScoreGeneral.licenceNotice)
        for holder in ["Frank Wen", "Michael Cowgill", "S. Christian Collins",
                       "Ethan Winer", "Michael Schorsch"] {
            #expect(notice.contains(holder), "notice omits \(holder)")
        }
        // The operative MIT sentence — the condition itself, not just the word.
        #expect(notice.contains(
            "included in all copies or substantial portions of the Software"))
        #expect(notice.contains("WITHOUT WARRANTY OF ANY KIND"))
        // NEGATIVE CONTROL: `contains` must be capable of returning false, or
        // every assertion above is vacuous.
        #expect(!notice.contains("Frank Wen Jr."),
                "control: a name absent from the licence must not be found")
    }

    /// ⭐ The whole point of a fallback, exercised rather than asserted.
    @Test("a dead primary falls through to the next source and still installs")
    func deadPrimaryFallsThroughToFallback() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let attempts = TransferCounter()
        let good = BankFixture.transfer(fixture.sourceBytes)
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: { url, destination, bytes, progress in
                attempts.bump()
                if url.host == "primary.invalid" {
                    throw SoundBankInstallError.transferFailed(reason: "simulated outage")
                }
                try await good(url, destination, bytes, progress)
            },
            availableCapacity: { _ in 100_000_000_000 })

        var bank = fixture.goodDescriptor
        bank = DownloadableSoundBank(
            id: bank.id, name: bank.name,
            url: URL(string: "https://primary.invalid/\(bank.fileName)")!,
            fallbackURLs: [URL(string: "https://fallback.invalid/\(bank.fileName)")!],
            fileName: bank.fileName, expectedBytes: bank.expectedBytes,
            sha256: bank.sha256, licence: bank.licence,
            attribution: bank.attribution, summary: bank.summary)

        let info = try await installer.install(bank: bank)
        #expect(info.supported)
        #expect(attempts.count() == 2, "both sources should have been tried, in order")
        #expect(FileManager.default.fileExists(
            atPath: fixture.libraryDirectory
                .appendingPathComponent(bank.fileName).path))
    }

    /// ⛔⛔ **A CANCELLATION IS NOT A SOURCE FAILURE.** Retrying it would march
    /// the user's own Cancel through every mirror before honouring it — and with
    /// a real 216 MB bank that is a very long way to ignore a button press.
    @Test("⛔ a cancellation is honoured at once, not retried against every mirror")
    func cancellationIsNotRetriedAcrossSources() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let attempts = TransferCounter()
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: { _, _, _, _ in
                attempts.bump()
                // MEASURED, not assumed: URLSession throws URLError(.cancelled),
                // NOT Swift's CancellationError (m34-c's own finding).
                throw URLError(.cancelled)
            },
            availableCapacity: { _ in 100_000_000_000 })

        var bank = fixture.goodDescriptor
        bank = DownloadableSoundBank(
            id: bank.id, name: bank.name,
            url: URL(string: "https://primary.invalid/\(bank.fileName)")!,
            fallbackURLs: [URL(string: "https://fallback.invalid/\(bank.fileName)")!],
            fileName: bank.fileName, expectedBytes: bank.expectedBytes,
            sha256: bank.sha256, licence: bank.licence,
            attribution: bank.attribution, summary: bank.summary)

        await #expect(throws: (any Error).self) {
            try await installer.install(bank: bank)
        }
        #expect(attempts.count() == 1,
                "cancel was retried against \(attempts.count()) sources; it must stop at 1")
    }

    /// The notice has to reach DISK, not just the catalogue — a constant nobody
    /// writes out satisfies nothing.
    @Test("the notice lands beside the bank, and is not itself scanned as a bank")
    func noticeIsWrittenBesideTheBank() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: BankFixture.transfer(fixture.sourceBytes),
            availableCapacity: { _ in 100_000_000_000 })

        var bank = fixture.goodDescriptor
        bank = DownloadableSoundBank(
            id: bank.id, name: bank.name, url: bank.url,
            fileName: bank.fileName, expectedBytes: bank.expectedBytes,
            sha256: bank.sha256, licence: bank.licence,
            attribution: bank.attribution, summary: bank.summary,
            licenceNotice: "Copyright (c) Someone. MIT.")

        _ = try await installer.install(bank: bank)
        let noticeURL = fixture.libraryDirectory
            .appendingPathComponent("\(bank.fileName).LICENSE.txt")
        #expect(FileManager.default.fileExists(atPath: noticeURL.path))
        #expect(try String(contentsOf: noticeURL, encoding: .utf8)
            .contains("Copyright (c) Someone"))
        // ⚠️ It must not be mistaken for an instrument.
        #expect(!fixture.library.scan().contains { $0.path == noticeURL.path },
                "the licence text was picked up as a sound bank")
    }

    /// CONTROL for the test above: a bank with no notice must leave no stray
    /// file — otherwise "the notice was written" could be true of every install
    /// regardless of the catalogue.
    @Test("a bank with no notice leaves no stray licence file")
    func noNoticeMeansNoFile() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: BankFixture.transfer(fixture.sourceBytes),
            availableCapacity: { _ in 100_000_000_000 })
        let bank = fixture.goodDescriptor
        #expect(bank.licenceNotice == nil, "fixture precondition")
        _ = try await installer.install(bank: bank)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.libraryDirectory
                .appendingPathComponent("\(bank.fileName).LICENSE.txt").path))
    }

    /// ⚠️ Synthesized `Codable` does NOT apply property defaults to missing
    /// keys, so both fields added on 2026-08-30 need a hand-written decoder.
    /// This pins that a payload written BEFORE they existed still decodes.
    @Test("⚠️ a payload predating fallbackURLs/licenceNotice still decodes")
    func decodesPayloadWithoutTheNewFields() throws {
        let legacy = """
            {"id":"x","name":"X","url":"https://example.invalid/x.sf2",
             "fileName":"x.sf2","expectedBytes":10,"sha256":"ab",
             "licence":"MIT","attribution":"A","summary":"S"}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DownloadableSoundBank.self, from: legacy)
        #expect(decoded.fallbackURLs.isEmpty)
        #expect(decoded.licenceNotice == nil)
        #expect(decoded.allSources == [decoded.url])
        // POSITIVE CONTROL: a payload WITH the fields round-trips them, so the
        // test above is about tolerance and not about the decoder ignoring them.
        let full = DownloadableSoundBankCatalog.museScoreGeneral
        let round = try JSONDecoder().decode(
            DownloadableSoundBank.self, from: try JSONEncoder().encode(full))
        #expect(round.fallbackURLs == full.fallbackURLs)
        #expect(round.licenceNotice == full.licenceNotice)
        #expect(round == full)
    }

    @Test("the chunked SHA-256 reader agrees with a published vector")
    func sha256Vector() throws {
        // The canonical SHA-256("abc"). A positive control on the hashing
        // primitive itself: every integrity assertion below is worthless if
        // this streaming reader hashes wrong.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha-vector-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SoundBankInstaller.sha256Hex(ofFileAt: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: The happy path

    @Test("a verified bank lands in the library and reads back with real preset names")
    func installsVerifiedBank() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: BankFixture.transfer(fixture.sourceBytes),
            availableCapacity: { _ in 100_000_000_000 })

        var ticks: [SoundBankDownloadProgress] = []
        let box = ProgressCollector()
        let info = try await installer.install(bank: fixture.goodDescriptor) { box.append($0) }
        ticks = box.all()

        let installed = fixture.libraryDirectory.appendingPathComponent("Fixture_Bank.sf2")
        #expect(FileManager.default.fileExists(atPath: installed.path))
        #expect(info.path == installed.standardizedFileURL.path)
        #expect(info.format == "sf2")
        #expect(info.supported)
        // The whole definition of "done": the library resolves it AND reads
        // real names out of it.
        let listing = try fixture.library.programs(for: info.source)
        #expect(listing.namesParsed)
        #expect(listing.programs.contains { $0.name == "Test Brush Kit" })
        // Every phase reported, in order, ending finished.
        #expect(ticks.map(\.phase).contains(.downloading))
        #expect(ticks.map(\.phase).contains(.verifying))
        #expect(ticks.map(\.phase).contains(.installing))
        #expect(ticks.last?.phase == .finished)
        // No staging left behind.
        #expect(installer.orphanedStagingDirectories().isEmpty)
    }

    // MARK: The three red controls — one per layer

    @Test("LAYER 1 CONTROL: a truncated transfer fails the size check and installs nothing")
    func truncatedTransferFailsSizeCheck() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let half = fixture.sourceBytes.prefix(fixture.sourceBytes.count / 2)
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: BankFixture.transfer(Data(half)),
            availableCapacity: { _ in 100_000_000_000 })

        await #expect(throws: SoundBankInstallError.sizeMismatch(
            expectedBytes: fixture.sourceBytes.count, actualBytes: half.count)) {
            try await installer.install(bank: fixture.goodDescriptor)
        }
        #expect(fixture.scannedFiles().isEmpty)
        #expect(installer.orphanedStagingDirectories().isEmpty)
    }

    @Test("LAYER 2 CONTROL: bytes of the RIGHT length but the wrong content fail the checksum")
    func corruptedTransferFailsChecksum() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        // One byte flipped, deep inside the sample data: the length is
        // IDENTICAL, so the size check cannot see this and only the hash can.
        var corrupted = fixture.sourceBytes
        let victim = corrupted.count / 2
        corrupted[victim] = corrupted[victim] &+ 1
        #expect(corrupted.count == fixture.sourceBytes.count)

        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: BankFixture.transfer(corrupted),
            availableCapacity: { _ in 100_000_000_000 })
        do {
            try await installer.install(bank: fixture.goodDescriptor)
            Issue.record("a corrupted file was accepted")
        } catch let error as SoundBankInstallError {
            guard case .checksumMismatch(let expected, let actual) = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(expected != actual)
        }
        #expect(fixture.scannedFiles().isEmpty)
        #expect(installer.orphanedStagingDirectories().isEmpty)
    }

    @Test("LAYER 3 CONTROL: the namesParsed sentinel catches a file BOTH transfer checks pass")
    func namesParsedSentinelFires() async throws {
        // ⭐ THE control this item turns on. The transferred bytes are a
        // truncated SoundFont — but the descriptor is minted FROM those exact
        // bytes, so its `expectedBytes` and `sha256` MATCH what arrives. Size
        // and checksum both pass. Only `programs(for:).namesParsed` can tell
        // that what landed is not a readable bank, and `programs(for:)`
        // deliberately does not throw for it: without the sentinel this file
        // would install and present as a normal bank named "Program 0…127".
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let truncated = Data(fixture.sourceBytes.prefix(fixture.sourceBytes.count / 2))
        let descriptor = fixture.descriptor(for: truncated)

        // Proof the trap is real: this file IS resolvable and DOES return a
        // program list — it just isn't a real one.
        let scratch = fixture.root.appendingPathComponent("probe.sf2")
        try truncated.write(to: scratch)
        let probe = try fixture.library.programs(for: .file(path: scratch.path))
        #expect(probe.namesParsed == false)
        #expect(probe.programs.count == 128)

        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: BankFixture.transfer(truncated),
            availableCapacity: { _ in 100_000_000_000 })
        await #expect(throws: SoundBankInstallError.installedButUnreadable(
            name: "Fixture Bank",
            path: fixture.libraryDirectory.appendingPathComponent("Fixture_Bank.sf2").path)) {
            try await installer.install(bank: descriptor)
        }
        // ROLLED BACK — not left in the library looking usable.
        #expect(!FileManager.default.fileExists(
            atPath: fixture.libraryDirectory.appendingPathComponent("Fixture_Bank.sf2").path))
        #expect(fixture.scannedFiles().isEmpty)
        #expect(installer.orphanedStagingDirectories().isEmpty)
    }

    // MARK: Pre-flight refusals

    @Test("a bank already in the library is refused, never re-fetched and never uniquified")
    func refusesAlreadyInstalled() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        try FileManager.default.createDirectory(
            at: fixture.libraryDirectory, withIntermediateDirectories: true)
        let existing = fixture.libraryDirectory.appendingPathComponent("Fixture_Bank.sf2")
        try fixture.sourceBytes.write(to: existing)

        let transferred = TransferCounter()
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: { url, destination, bytes, progress in
                transferred.bump()
                try await BankFixture.transfer(fixture.sourceBytes)(
                    url, destination, bytes, progress)
            },
            availableCapacity: { _ in 100_000_000_000 })
        await #expect(throws: SoundBankInstallError.alreadyInstalled(
            name: "Fixture Bank", path: existing.path)) {
            try await installer.install(bank: fixture.goodDescriptor)
        }
        // The refusal happens BEFORE the network — that is the point of it.
        #expect(transferred.count() == 0)
        // And no "Fixture_Bank 2.sf2" appeared.
        #expect(fixture.scannedFiles().count == 1)
    }

    @Test("too little disk space is refused before a byte moves, naming both numbers")
    func refusesWhenDiskIsFull() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let transferred = TransferCounter()
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: { url, destination, bytes, progress in
                transferred.bump()
                try await BankFixture.transfer(fixture.sourceBytes)(
                    url, destination, bytes, progress)
            },
            availableCapacity: { _ in 1_000 })
        do {
            try await installer.install(bank: fixture.goodDescriptor)
            Issue.record("installed with no disk space")
        } catch let error as SoundBankInstallError {
            guard case .notEnoughDiskSpace(let required, let available, _) = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(available == 1_000)
            #expect(required == fixture.sourceBytes.count + SoundBankInstaller.diskHeadroomBytes)
            #expect(error.errorDescription?.contains("Free some space") == true)
        }
        #expect(transferred.count() == 0)
    }

    @Test("a volume that will not report its capacity does not block the download")
    func unknownCapacityProceeds() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: BankFixture.transfer(fixture.sourceBytes),
            availableCapacity: { _ in nil })
        let info = try await installer.install(bank: fixture.goodDescriptor)
        #expect(info.name == "Fixture_Bank")
    }

    // MARK: Staging

    @Test("a half-written staging file is invisible to scan() while the transfer runs")
    func stagingIsInvisibleMidTransfer() async throws {
        // The reason staging is a DOT-prefixed directory inside the library
        // rather than a temp dir: `SoundBankLibrary.scan()` passes
        // `.skipsHiddenFiles` (SoundBanks.swift:251 — VERIFIED, not assumed by
        // analogy with WhisperModelCatalog).
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let library = fixture.library
        let seen = ScanRecorder()
        let installer = SoundBankInstaller(
            library: library,
            transfer: { _, destination, _, _ in
                // A partial file sitting in staging, exactly as a live transfer
                // would leave it mid-flight.
                try Data(fixture.sourceBytes.prefix(64)).write(to: destination)
                seen.record(library.scan())
                try fixture.sourceBytes.write(to: destination)
            },
            availableCapacity: { _ in 100_000_000_000 })
        _ = try await installer.install(bank: fixture.goodDescriptor)
        #expect(seen.value().filter { !$0.builtin }.isEmpty)
        // And afterwards it IS there — the negative above is not vacuous.
        #expect(library.scan().filter { !$0.builtin }.count == 1)
    }

    @Test("a failed transfer leaves no staging directory behind")
    func failedTransferCleansStaging() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: { _, _, _, _ in
                throw SoundBankInstallError.transferFailed(reason: "the network went away")
            },
            availableCapacity: { _ in 100_000_000_000 })
        await #expect(throws: SoundBankInstallError.transferFailed(
            reason: "the network went away")) {
            try await installer.install(bank: fixture.goodDescriptor)
        }
        #expect(installer.orphanedStagingDirectories().isEmpty)
        #expect(fixture.scannedFiles().isEmpty)
    }

    @Test("cancelling mid-transfer reports cancelled and leaves nothing on disk")
    func cancellationLeavesNothing() async throws {
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: { _, destination, _, _ in
                try Data(fixture.sourceBytes.prefix(64)).write(to: destination)
                // What a cancellation-aware URLSession transfer throws.
                throw CancellationError()
            },
            availableCapacity: { _ in 100_000_000_000 })
        await #expect(throws: SoundBankInstallError.cancelled(name: "Fixture Bank")) {
            try await installer.install(bank: fixture.goodDescriptor)
        }
        #expect(installer.orphanedStagingDirectories().isEmpty)
        #expect(fixture.scannedFiles().isEmpty)
    }

    @Test("a URLSession cancellation is a CANCEL, not a failure — the shape URLSession really throws")
    func urlSessionCancellationIsACancel() async throws {
        // ⚠️ REGRESSION PIN, and it cost a live run to find. `URLSession`
        // throws `URLError(.cancelled)` when its task is cancelled — NOT
        // Swift's `CancellationError`. The first version of this installer
        // matched only `CancellationError`, so pressing Cancel on a real
        // 216 MB download reported state "failed" with the bare word
        // "cancelled" as its message. Every offline test passed, because the
        // fakes threw what the fake author expected.
        let fixture = try BankFixture()
        defer { fixture.destroy() }
        let installer = SoundBankInstaller(
            library: fixture.library,
            transfer: { _, destination, _, _ in
                try Data(fixture.sourceBytes.prefix(64)).write(to: destination)
                throw URLError(.cancelled)
            },
            availableCapacity: { _ in 100_000_000_000 })
        await #expect(throws: SoundBankInstallError.cancelled(name: "Fixture Bank")) {
            try await installer.install(bank: fixture.goodDescriptor)
        }
        #expect(installer.orphanedStagingDirectories().isEmpty)
        #expect(fixture.scannedFiles().isEmpty)

        // Negative control: a DIFFERENT URLError is a real failure and must
        // NOT be laundered into a cancellation.
        let networkDown = SoundBankInstaller(
            library: fixture.library,
            transfer: { _, _, _, _ in throw URLError(.notConnectedToInternet) },
            availableCapacity: { _ in 100_000_000_000 })
        do {
            try await networkDown.install(bank: fixture.goodDescriptor)
            Issue.record("a network failure was accepted")
        } catch let error as SoundBankInstallError {
            Issue.record("a network failure was mislabelled as \(error)")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
        }
    }

    @Test("every error says what happened and what to do next")
    func errorsTeach() {
        let cases: [SoundBankInstallError] = [
            .unknownBank(requested: "x", known: ["musescore-general"]),
            .alreadyInstalled(name: "B", path: "/tmp/B.sf2"),
            .notEnoughDiskSpace(requiredBytes: 1, availableBytes: 0, path: "/tmp"),
            .serverSizeMismatch(expectedBytes: 1, serverBytes: 2, url: "https://x/y"),
            .transferFailed(reason: "r"),
            .sizeMismatch(expectedBytes: 2, actualBytes: 1),
            .checksumMismatch(expected: "aaaaaaaaaaaaaa", actual: "bbbbbbbbbbbbbb"),
            .installedButUnreadable(name: "B", path: "/tmp/B.sf2"),
            .notVisibleToLibrary(name: "B", path: "/a/B.sf2", libraryDirectory: "/b"),
            .cancelled(name: "B"),
        ]
        for error in cases {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty)
            // No bare Swift error dumps in front of a user.
            #expect(!text.contains("Optional("))
        }
    }
}

// MARK: - Small thread-safe test collectors

/// Progress ticks arrive on whatever thread the transfer runs on.
private final class ProgressCollector: @unchecked Sendable {
    // @unchecked Sendable justification: every access to `items` is inside
    // `lock`; the class has no other mutable state and escapes only into the
    // progress closure it was built for.
    private let lock = NSLock()
    private var items: [SoundBankDownloadProgress] = []
    func append(_ item: SoundBankDownloadProgress) {
        lock.lock(); items.append(item); lock.unlock()
    }
    func all() -> [SoundBankDownloadProgress] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

private final class TransferCounter: @unchecked Sendable {
    // @unchecked Sendable justification: as above — one Int behind one lock.
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class ScanRecorder: @unchecked Sendable {
    // @unchecked Sendable justification: as above — one array behind one lock.
    private let lock = NSLock()
    private var items: [SoundBankInfo] = []
    func record(_ items: [SoundBankInfo]) {
        lock.lock(); self.items = items; lock.unlock()
    }
    func value() -> [SoundBankInfo] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

// MARK: - The real-bytes leg (opt-in, never part of a normal run)

/// The one leg that uses the REAL `MuseScore_General.sf2` — 215,614,036 bytes.
///
/// ⚠️ **It does not run unless `DAWPRO_SF2_FIXTURE` points at a real copy**, and
/// that is deliberate: a 206 MB read has no business in a suite of 7,500 tests.
/// It is here rather than in a throwaway script so the exact assertions that
/// were run at implementation time are on the record and can be re-run:
///
///     DAWPRO_SF2_FIXTURE=/path/to/MuseScore_General.sf2 \
///       ./scripts/test.sh --filter RealSoundBankBytes
///
/// It drives the LIVE transfer function over a `file:` URL, so everything
/// except the network hop is the production path — including the staging
/// rename, both transfer checks against the shipped pin, and the `namesParsed`
/// sentinel. The library it installs into is a TEMP directory, never the
/// user's real `~/Library/Application Support/DAWPro/SoundBanks`.
@Suite("Real SoundBank bytes (opt-in)", .enabled(if: ProcessInfo.processInfo
    .environment["DAWPRO_SF2_FIXTURE"] != nil))
struct RealSoundBankBytesTests {

    private static var fixtureURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["DAWPRO_SF2_FIXTURE"] ?? "")
    }

    @Test("the shipped pin matches the real file, byte count and hash")
    func pinMatchesTheRealFile() throws {
        let bank = DownloadableSoundBankCatalog.museScoreGeneral
        let url = Self.fixtureURL
        #expect(SoundBankInstaller.fileSize(at: url) == bank.expectedBytes)
        #expect(try SoundBankInstaller.sha256Hex(ofFileAt: url) == bank.sha256)
    }

    @Test("the whole install path runs on the real bytes and yields a readable bank with brushes")
    func realInstallEndToEnd() async throws {
        let bank = DownloadableSoundBankCatalog.museScoreGeneral
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundbank-real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SoundBankLibrary(libraryDirectory: root, scanDirectories: [root])

        // The LIVE transfer, pointed at a file: URL — no network, everything
        // else production. `liveTransfer` skips its HEAD pre-check for file
        // URLs, which is stated in its own doc rather than faked.
        let installer = SoundBankInstaller(library: library,
                                           transfer: SoundBankInstaller.liveTransfer)
        let localBank = DownloadableSoundBank(
            id: bank.id, name: bank.name, url: Self.fixtureURL, fileName: bank.fileName,
            expectedBytes: bank.expectedBytes, sha256: bank.sha256, licence: bank.licence,
            attribution: bank.attribution, summary: bank.summary)

        let info = try await installer.install(bank: localBank)
        #expect(info.format == "sf2")
        #expect(info.sizeBytes == bank.expectedBytes)

        // THE definition of done, on the real file.
        let listing = try library.programs(for: info.source)
        #expect(listing.namesParsed)

        // And the item's stated pain point, measured rather than assumed: a
        // brief asking for brushes could not be honoured with the stock Mac's
        // single drum kit.
        let names = Set(listing.programs.map(\.name))
        #expect(names.contains("Brush"))
        #expect(names.contains("Brush 1"))
        #expect(names.contains("Brush 2"))
        // Negative control, so the membership checks above are evidence: a kit
        // this bank does not carry.
        #expect(!names.contains("Definitely Not A Real Kit"))
        let kits = listing.programs.filter { $0.bankMSB == GMProgramCatalog.percussionBankMSB }
        #expect(kits.count > 10, "expected the drum-kit families the spike enumerated, got \(kits.count)")
        #expect(installer.orphanedStagingDirectories().isEmpty)
    }
}

/// The HEAD pre-check's RED branch — the one layer that cannot be proven by a
/// fixture, because it is a claim about a live server.
///
/// ⚠️ Opt-in via `DAWPRO_ALLOW_NETWORK=1`: it makes ONE `HEAD` request (a few
/// hundred bytes, no download) and must never run in a normal suite pass.
///
///     DAWPRO_ALLOW_NETWORK=1 ./scripts/test.sh --filter ServerSizePrecheck
///
/// It exists because "a sentinel that has never gone red is not a sentinel":
/// the pre-check ran green on three live transfers and its failure branch had
/// executed exactly nowhere.
@Suite("Server size pre-check, red branch (opt-in, one HEAD request)",
       .enabled(if: ProcessInfo.processInfo.environment["DAWPRO_ALLOW_NETWORK"] == "1"))
struct ServerSizePrecheckTests {

    @Test("a URL whose advertised length disagrees with the pin fails in the first second")
    func mismatchedServerSizeIsRefused() async throws {
        let real = DownloadableSoundBankCatalog.museScoreGeneral
        // The licence file that sits BESIDE the bank at the same host: a real
        // 200 with a real, very different Content-Length. Pointing the pin at
        // it is exactly the shape of "the mirror file changed".
        let decoy = DownloadableSoundBank(
            id: real.id, name: real.name,
            url: URL(string: "https://ftp.osuosl.org/pub/musescore/soundfont/"
                     + "MuseScore_General/MuseScore_General_License.md")!,
            fileName: real.fileName, expectedBytes: real.expectedBytes,
            sha256: real.sha256, licence: real.licence,
            attribution: real.attribution, summary: real.summary)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("precheck-\(UUID().uuidString).sf2")
        defer { try? FileManager.default.removeItem(at: destination) }

        let started = Date()
        do {
            try await SoundBankInstaller.liveTransfer(
                decoy.url, destination, decoy.expectedBytes, { _, _ in })
            Issue.record("a mismatched server size was accepted")
        } catch let error as SoundBankInstallError {
            guard case .serverSizeMismatch(let expected, let server, _) = error else {
                Issue.record("wrong error: \(error)"); return
            }
            #expect(expected == 215_614_036)
            #expect(server != Int64(expected))
            #expect(error.errorDescription?.contains("needs a new checksum") == true)
        }
        // The whole point of a pre-check: it fails BEFORE the transfer, not
        // after 216 MB.
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(!FileManager.default.fileExists(atPath: destination.path),
                "nothing was written")
    }

    @Test("the SAME pre-check passes against the real file — the control that keeps the test above honest")
    func matchingServerSizePasses() async throws {
        // Without this, a broken HEAD (a typo'd host, a 404) would make the
        // red test above pass for the wrong reason.
        let bank = DownloadableSoundBankCatalog.museScoreGeneral
        var head = URLRequest(url: bank.url)
        head.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: head)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.expectedContentLength == Int64(bank.expectedBytes))
    }
}
