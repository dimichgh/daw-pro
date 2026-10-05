import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWAppKit

/// The instrument picker's one-click SoundFont download surface (m34-c).
///
/// Everything here runs against injected closures — no coordinator, no
/// network, no filesystem. The point of the suite is the LANGUAGE and the
/// STATE MACHINE the user actually meets: what the row says at each phase,
/// when a progress bar is honest enough to draw, and that a refusal and a
/// failure are told apart.
@MainActor
@Suite("Instrument picker — downloadable sound banks (m34-c)")
struct InstrumentPickerDownloadTests {

    // MARK: - Fixtures

    private static let museScore = DownloadableSoundBankCatalog.museScoreGeneral

    private static func offering(installed: Bool = false) -> SoundBankOffering {
        SoundBankOffering(
            bank: museScore,
            installedPath: installed
                ? "/tmp/SoundBanks/MuseScore_General.sf2" : nil)
    }

    private static func info(_ name: String) -> SoundBankInfo {
        SoundBankInfo(source: .file(path: "/tmp/SoundBanks/\(name).sf2"), name: name,
                      path: "/tmp/SoundBanks/\(name).sf2", format: "sf2",
                      builtin: false, sizeBytes: 1)
    }

    /// A scripted status feed: each `status()` read pops the next entry, and
    /// the last one repeats. Lets a test walk the model through a whole
    /// download without a clock.
    private final class StatusScript: @unchecked Sendable {
        // @unchecked Sendable justification: one array and one index, both
        // only ever touched inside `lock`. No other state exists.
        private let lock = NSLock()
        private var queue: [SoundBankDownloadStatus]
        private(set) var reads = 0

        init(_ queue: [SoundBankDownloadStatus]) { self.queue = queue }

        func next() -> SoundBankDownloadStatus {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            if queue.count > 1 { return queue.removeFirst() }
            return queue.first ?? .idle
        }
    }

    private func makeModel(
        banks: [SoundBankInfo] = [],
        offerings: [SoundBankOffering] = [offering()],
        script: StatusScript = StatusScript([.idle]),
        startResult: @escaping @Sendable (String) async throws -> SoundBankDownloadStatus
            = { _ in SoundBankDownloadStatus(state: .downloading, bankID: "musescore-general",
                                             bankName: "MuseScore General") },
        cancelResult: @escaping @Sendable () async throws -> SoundBankDownloadStatus
            = { SoundBankDownloadStatus(state: .downloading, bankID: "musescore-general",
                                        bankName: "MuseScore General", cancelRequested: true) },
        withDownloadProviders: Bool = true
    ) -> InstrumentPickerModel {
        let banksBox = banks
        if !withDownloadProviders {
            return InstrumentPickerModel(
                soundBanks: { banksBox }, programs: { _ in ([], false) },
                audioUnits: { [] }, importer: { _ in Self.info("x") })
        }
        return InstrumentPickerModel(
            soundBanks: { banksBox }, programs: { _ in ([], false) },
            audioUnits: { [] }, importer: { _ in Self.info("x") },
            downloadableBanks: { offerings },
            startDownload: startResult,
            downloadStatus: { script.next() },
            cancelDownload: cancelResult)
    }

    /// Spins the main-actor run loop until `condition` holds or the attempts
    /// run out. The model's polling lives in an unstructured `Task`, so there
    /// is nothing to await directly.
    private func settle(attempts: Int = 200,
                        until condition: () -> Bool) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Availability

    @Test("a build with no download providers hides the affordance entirely")
    func noProvidersMeansNoAffordance() {
        let model = makeModel(withDownloadProviders: false)
        #expect(model.canDownloadBanks == false)
        #expect(model.downloadableBanks.isEmpty)
        #expect(model.downloadStatusLine == nil)
        // And nothing throws or hangs when the actions are called anyway.
        model.startDownload(id: "musescore-general")
        model.cancelDownload()
        model.beginWatchingDownloads()
        #expect(model.downloadRequestError == nil)
    }

    @Test("an already-installed bank is not offered again")
    func installedBankIsNotOffered() {
        let model = makeModel(offerings: [Self.offering(installed: true)])
        model.refreshDownloadableBanks()
        #expect(model.canDownloadBanks)
        // Positive control: the same model DOES offer it when it is absent.
        #expect(model.downloadableBanks.isEmpty)
        let fresh = makeModel(offerings: [Self.offering(installed: false)])
        fresh.refreshDownloadableBanks()
        #expect(fresh.downloadableBanks.count == 1)
        #expect(fresh.downloadableBanks.first?.bank.licence == "MIT")
        // ONE arithmetic: the offer row and the progress line below both go
        // through `DownloadableSoundBank.formattedMegabytes`, so they cannot
        // show two different numbers for one file (they briefly did — 206 vs
        // 215 — which is why the literal was replaced by a derivation).
        #expect(fresh.downloadableBanks.first?.bank.sizeDescription == "216 MB")
    }

    // MARK: - The words the user reads

    @Test("each phase gets a plain sentence, and the transfer one carries real megabytes")
    func statusLineSaysWhatIsHappening() async {
        let phases: [(SoundBankDownloadProgress.Phase, String)] = [
            (.preparing, "Getting ready…"),
            (.verifying, "Checking the download…"),
            (.installing, "Adding MuseScore General to your instruments…"),
            (.finished, "Finishing up…"),
        ]
        for (phase, expected) in phases {
            let model = makeModel(script: StatusScript([SoundBankDownloadStatus(
                state: .downloading, bankID: "musescore-general",
                bankName: "MuseScore General",
                progress: SoundBankDownloadProgress(
                    phase: phase, bankID: "musescore-general", phaseFraction: 0))]))
            model.beginWatchingDownloads()
            await settle { model.downloadStatusLine != nil }
            #expect(model.downloadStatusLine == expected)
        }

        // The transfer phase: bytes, in plain decimal MB, both sides.
        let transferring = makeModel(script: StatusScript([SoundBankDownloadStatus(
            state: .downloading, bankID: "musescore-general", bankName: "MuseScore General",
            progress: SoundBankDownloadProgress(
                phase: .downloading, bankID: "musescore-general", phaseFraction: 0.5,
                completedBytes: 88_000_000, totalBytes: 215_614_036))]))
        transferring.beginWatchingDownloads()
        await settle { transferring.downloadStatusLine != nil }
        #expect(transferring.downloadStatusLine == "Downloading 88 MB of 216 MB…")
        // ⭐ Not a bare percentage: a beginner is told what is being moved.
        #expect(transferring.downloadStatusLine?.contains("%") == false)
    }

    @Test("terminal states each say something different, and a failure relays the app's own words")
    func terminalStatusLines() async {
        let succeeded = makeModel(script: StatusScript([SoundBankDownloadStatus(
            state: .succeeded, bankID: "musescore-general", bankName: "MuseScore General",
            bank: Self.info("MuseScore_General"))]))
        succeeded.beginWatchingDownloads()
        await settle { succeeded.downloadStatusLine != nil }
        #expect(succeeded.downloadStatusLine == "MuseScore General is ready — pick a sound below.")

        let cancelled = makeModel(script: StatusScript([SoundBankDownloadStatus(
            state: .cancelled, bankID: "musescore-general", bankName: "MuseScore General",
            errorMessage: "Download of MuseScore General was cancelled.")]))
        cancelled.beginWatchingDownloads()
        await settle { cancelled.downloadStatusLine != nil }
        #expect(cancelled.downloadStatusLine == "Download stopped. Nothing was added.")

        let failed = makeModel(script: StatusScript([SoundBankDownloadStatus(
            state: .failed, bankID: "musescore-general", bankName: "MuseScore General",
            errorMessage: "The download stopped early: got 88 MB of 215 MB.")]))
        failed.beginWatchingDownloads()
        await settle { failed.downloadStatusLine != nil }
        // Relayed verbatim — the installer already wrote the sentence, and
        // paraphrasing it here would be a second, drifting copy.
        #expect(failed.downloadStatusLine == "The download stopped early: got 88 MB of 215 MB.")
    }

    @Test("a requested cancel reads Stopping… — never Cancelled — until the job actually stops")
    func cancellingSaysStopping() async {
        let model = makeModel(script: StatusScript([SoundBankDownloadStatus(
            state: .downloading, bankID: "musescore-general", bankName: "MuseScore General",
            cancelRequested: true,
            progress: SoundBankDownloadProgress(
                phase: .downloading, bankID: "musescore-general", phaseFraction: 0.5,
                completedBytes: 88_000_000, totalBytes: 215_614_036))]))
        model.beginWatchingDownloads()
        await settle { model.downloadStatusLine != nil }
        #expect(model.downloadStatusLine == "Stopping…")
        // The partial file is not gone yet, so claiming it stopped would be a
        // status racing the filesystem.
        #expect(model.downloadStatus?.state == .downloading)
    }

    // MARK: - The progress bar

    @Test("the bar is drawn ONLY for the transfer, because only the transfer has an honest fraction")
    func fractionOnlyDuringTransfer() async {
        let transferring = makeModel(script: StatusScript([SoundBankDownloadStatus(
            state: .downloading, bankID: "musescore-general", bankName: "MuseScore General",
            progress: SoundBankDownloadProgress(
                phase: .downloading, bankID: "musescore-general", phaseFraction: 0.5,
                completedBytes: 50, totalBytes: 200))]))
        transferring.beginWatchingDownloads()
        await settle { transferring.downloadFraction != nil }
        #expect(transferring.downloadFraction == 0.25)

        for phase: SoundBankDownloadProgress.Phase in [.preparing, .verifying, .installing] {
            let other = makeModel(script: StatusScript([SoundBankDownloadStatus(
                state: .downloading, bankID: "musescore-general", bankName: "MuseScore General",
                progress: SoundBankDownloadProgress(
                    phase: phase, bankID: "musescore-general", phaseFraction: 0.9,
                    completedBytes: 50, totalBytes: 200))]))
            other.beginWatchingDownloads()
            await settle { other.downloadStatus?.progress != nil }
            #expect(other.downloadFraction == nil, "\(phase) has no honest fraction to draw")
        }
    }

    // MARK: - Start / refuse / finish

    @Test("a finished download refreshes the bank list, so the new sounds actually appear")
    func successRefreshesTheBankList() async {
        // The provider returns nothing until the download "lands", then the
        // new bank — the same shape a real library scan has.
        let landed = LandedBanks()
        let script = StatusScript([
            SoundBankDownloadStatus(state: .downloading, bankID: "musescore-general",
                                    bankName: "MuseScore General"),
            SoundBankDownloadStatus(state: .succeeded, bankID: "musescore-general",
                                    bankName: "MuseScore General",
                                    bank: Self.info("MuseScore_General")),
        ])
        let model = InstrumentPickerModel(
            soundBanks: { landed.value() }, programs: { _ in ([], false) },
            audioUnits: { [] }, importer: { _ in Self.info("x") },
            downloadableBanks: { [Self.offering()] },
            startDownload: { _ in
                landed.land(Self.info("MuseScore_General"))
                return SoundBankDownloadStatus(state: .downloading, bankID: "musescore-general",
                                               bankName: "MuseScore General")
            },
            downloadStatus: { script.next() },
            cancelDownload: { .idle })

        #expect(model.banks.isEmpty)
        model.startDownload(id: "musescore-general")
        await settle { model.downloadStatus?.state == .succeeded }
        await settle { !model.banks.isEmpty }
        #expect(model.banks.map(\.name) == ["MuseScore_General"])
    }

    @Test("a REFUSED request is reported separately from a FAILED download")
    func refusalIsNotAFailure() async {
        let model = makeModel(startResult: { _ in
            throw SoundBankDownloadCoordinatorError.downloadAlreadyInFlight(
                requested: "MuseScore General", inFlight: "MuseScore General")
        })
        model.startDownload(id: "musescore-general")
        await settle { model.downloadRequestError != nil }
        #expect(model.downloadRequestError?.contains(
            "Only one sound-bank download runs at a time") == true)
        // The two channels are distinct: nothing ever started, so there is no
        // download status to show.
        #expect(model.downloadStatus == nil)
        model.clearDownloadRequestError()
        #expect(model.downloadRequestError == nil)
    }

    @Test("cancel forwards and reflects cancelRequested without claiming the job stopped")
    func cancelForwards() async {
        let model = makeModel()
        model.cancelDownload()
        await settle { model.downloadStatus?.cancelRequested == true }
        #expect(model.downloadStatus?.state == .downloading)
        #expect(model.downloadStatus?.cancelRequested == true)
    }

    @Test("a refused cancel surfaces its own sentence")
    func cancelRefusalReported() async {
        let model = makeModel(cancelResult: {
            throw SoundBankDownloadCoordinatorError.nothingInFlight
        })
        model.cancelDownload()
        await settle { model.downloadRequestError != nil }
        #expect(model.downloadRequestError?.contains("nothing to cancel") == true)
    }

    @Test("a download that STARTS while the picker is open becomes visible without reopening it")
    func watcherSeesADownloadStartedLater() async {
        // ⚠️ REGRESSION PIN. This was a ONE-SHOT read at `prepare`: it saw
        // `.idle`, stopped, and the picker went on showing an idle Download
        // button while a wire-started transfer streamed 28 MB in behind it.
        // Found by screenshotting a live download, not by any assertion.
        let script = StatusScript([
            .idle,
            SoundBankDownloadStatus(
                state: .downloading, bankID: "musescore-general",
                bankName: "MuseScore General",
                progress: SoundBankDownloadProgress(
                    phase: .downloading, bankID: "musescore-general", phaseFraction: 0.13,
                    completedBytes: 28_449_170, totalBytes: 215_614_036)),
        ])
        let model = makeModel(script: script)
        model.prepare(trackID: UUID(), descriptor: nil, status: nil)
        // First poll sees idle — the state the broken version stopped at.
        await settle { model.downloadStatus != nil }
        #expect(model.downloadStatus?.state == .idle)
        // The watcher keeps looking, so the LATER start is picked up.
        await settle { model.downloadStatus?.state == .downloading }
        #expect(model.downloadStatusLine == "Downloading 28 MB of 216 MB…")
        model.endWatchingDownloads()
    }

    @Test("a finished download seen by the watcher refreshes the bank list")
    func watcherRefreshesOnTerminalTransition() async {
        let landed = LandedBanks()
        let script = StatusScript([
            SoundBankDownloadStatus(state: .downloading, bankID: "musescore-general",
                                    bankName: "MuseScore General"),
            SoundBankDownloadStatus(state: .succeeded, bankID: "musescore-general",
                                    bankName: "MuseScore General",
                                    bank: Self.info("MuseScore_General")),
        ])
        let model = InstrumentPickerModel(
            soundBanks: { landed.value() }, programs: { _ in ([], false) },
            audioUnits: { [] }, importer: { _ in Self.info("x") },
            downloadableBanks: { [Self.offering()] },
            startDownload: { _ in .idle },
            downloadStatus: { script.next() },
            cancelDownload: { .idle })
        landed.land(Self.info("MuseScore_General"))
        model.beginWatchingDownloads()
        await settle { model.downloadStatus?.state == .succeeded }
        await settle { !model.banks.isEmpty }
        #expect(model.banks.map(\.name) == ["MuseScore_General"])
        model.endWatchingDownloads()
    }

    @Test("opening the picker adopts a download already running elsewhere")
    func adoptsRunningDownload() async {
        // The wire (or a previous visit) started one. The picker must show it
        // rather than offer a second that would be refused.
        let model = makeModel(script: StatusScript([SoundBankDownloadStatus(
            state: .downloading, bankID: "musescore-general", bankName: "MuseScore General",
            progress: SoundBankDownloadProgress(
                phase: .downloading, bankID: "musescore-general", phaseFraction: 0.1,
                completedBytes: 20_000_000, totalBytes: 215_614_036))]))
        model.prepare(trackID: UUID(), descriptor: nil, status: nil)
        await settle { model.downloadStatus?.state == .downloading }
        #expect(model.downloadStatusLine == "Downloading 20 MB of 216 MB…")
        #expect(model.downloadingBank?.bank.id == "musescore-general")
    }
}

/// A mutable bank list a provider closure can read — stands in for a library
/// scan that starts empty and finds a file after the download lands.
private final class LandedBanks: @unchecked Sendable {
    // @unchecked Sendable justification: one array behind one lock; nothing
    // else is stored.
    private let lock = NSLock()
    private var banks: [SoundBankInfo] = []
    func land(_ info: SoundBankInfo) { lock.lock(); banks.append(info); lock.unlock() }
    func value() -> [SoundBankInfo] { lock.lock(); defer { lock.unlock() }; return banks }
}
