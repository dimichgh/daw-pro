import Foundation
import CryptoKit
// `SoundBankLibrary` / `SoundBankInfo` — the domain's sound-bank home. This
// file NEVER open-codes the library path; `AppDirectories.applicationSupport(.soundBanks)`
// reaches it through `SoundBankLibrary.defaultLibraryDirectory()` (m23-n1b).
import DAWCore

// MARK: - The catalog

/// One bank DAW Pro can fetch for the user in one click (m34-c).
///
/// ## Why this type carries a licence and an attribution string
///
/// The roadmap item's own words: *"LICENSING IS THE WHOLE ITEM, NOT A
/// FOOTNOTE"*. A downloadable bank whose licence lives only in a research
/// document is a bank nobody can audit at run time, so the terms travel WITH
/// the entry, go out on the wire (`instrument.listDownloadableSoundBanks`),
/// and are shown in the picker before anything is fetched.
///
/// ## Why `expectedBytes` and `sha256` are both here, and what each one proves
///
/// They answer DIFFERENT questions and conflating them is the trap this item
/// was written to avoid:
///   * `expectedBytes` is a **completeness** check. It defeats the failure this
///     item names by name — *"a half-downloaded bank that reports success"* —
///     and nothing else.
///   * `sha256` is an **integrity** check: these are the bytes we saw, not
///     bytes that rotted in transit or on disk.
/// ⛔ Neither is an **authenticity/provenance** check. No publisher-side
/// checksum exists for this file (see `docs/research/spike-soundfont-download.md`
/// — Debian publishes one for a DIFFERENT version and possibly a different
/// variant, and it must not be substituted). The hash below was computed by
/// this project from its own download; see `museScoreGeneral`'s note.
public struct DownloadableSoundBank: Sendable, Equatable, Codable, Identifiable {
    /// Stable wire id — what `instrument.downloadSoundBank` takes. Never
    /// localised, never derived from the filename.
    public let id: String
    /// Human name for the picker, e.g. "MuseScore General".
    public let name: String
    /// Where the bytes come from — the PRIMARY source, tried first.
    public let url: URL
    /// Sources tried, in order, if `url` fails. Empty is legal and means
    /// single-source.
    ///
    /// ⭐⭐ **THIS EXISTS BECAUSE WE BECAME THE PUBLISHER.** The user chose
    /// "mirror it ourselves, keep upstream as a fallback" (2026-08-30). Hosting
    /// it makes availability ours to guarantee; keeping upstream means **two
    /// independent hosts must both vanish** before the feature dies. The old
    /// single-source shape depended on a mirror MuseScore does not officially
    /// link to.
    ///
    /// ⛔ **EVERY SOURCE IS VERIFIED IDENTICALLY.** A fallback is a different
    /// HOST, never a different FILE — same `expectedBytes`, same `sha256`, same
    /// post-install sentinel. A fallback that relaxed any check would turn
    /// "the primary is down" into "you silently got something else".
    public let fallbackURLs: [URL]
    /// The name the file gets in the library. Also the collision key: an
    /// existing file with this name is a REFUSAL, never a silent second copy.
    public let fileName: String
    /// Exact expected length in bytes. A completeness check (see the type doc).
    public let expectedBytes: Int
    /// Lowercase hex SHA-256 of the exact bytes at `url`. An integrity check
    /// (see the type doc), self-computed — never a publisher guarantee.
    public let sha256: String
    /// SPDX-ish short name, e.g. "MIT".
    public let licence: String
    /// The copyright line to show in credits, verbatim from the licence file.
    public let attribution: String
    /// One beginner-readable sentence: what the user GETS. Shown in the picker
    /// and returned on the wire, so both surfaces say the same thing.
    public let summary: String
    /// The human size string — DERIVED from `expectedBytes`, never stored.
    ///
    /// This was a pinned literal for exactly one build, and it was WRONG in a
    /// way worth recording: it read "206 MB" (the mirror's directory listing
    /// prints MEBIbytes — 215,614,036 B = 205.63 MiB) while the picker's own
    /// progress line counted decimal megabytes toward "216 MB". Two different
    /// numbers for one file on one screen. There is now ONE arithmetic,
    /// `formattedMegabytes`, and the offer row, the progress line and every
    /// installer error all go through it, so they cannot disagree.
    ///
    /// Decimal MB is the right convention here because it is what macOS itself
    /// shows: a user who checks the downloaded file in Finder sees 215.6 MB.
    public var sizeDescription: String {
        Self.formattedMegabytes(Int64(expectedBytes))
    }

    /// Whole decimal megabytes, ROUNDED — THE size arithmetic. Rounded rather
    /// than truncated so a 215.6 MB file is not advertised as 215 MB.
    public static func formattedMegabytes(_ bytes: Int64) -> String {
        "\((bytes + 500_000) / 1_000_000) MB"
    }

    /// Every source in priority order — the primary followed by its fallbacks.
    /// ONE derivation, so the installer's loop and any test or echo that counts
    /// sources cannot disagree about how many there are.
    public var allSources: [URL] { [url] + fallbackURLs }

    /// The full licence + copyright notice, written beside the bank on install.
    ///
    /// ⛔⛔ **EMBEDDED AS TEXT, DELIBERATELY NOT FETCHED.** MIT requires the
    /// notice to travel with copies we distribute, and the upstream licence file
    /// adds *"The acknowledgements and copyright notices above must be included
    /// in any derivative work."* **A notice fetched over the network can fail;
    /// an obligation cannot.** Embedding it means the install either produces
    /// both files or neither, with no branch where the bank lands without its
    /// terms. It is 3 KB.
    public let licenceNotice: String?

    public init(id: String, name: String, url: URL, fallbackURLs: [URL] = [],
                fileName: String, expectedBytes: Int, sha256: String,
                licence: String, attribution: String, summary: String,
                licenceNotice: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.fallbackURLs = fallbackURLs
        self.fileName = fileName
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
        self.licence = licence
        self.attribution = attribution
        self.summary = summary
        self.licenceNotice = licenceNotice
    }

    /// ⚠️ **HAND-WRITTEN BECAUSE SYNTHESIZED `Codable` DOES NOT APPLY PROPERTY
    /// DEFAULTS TO MISSING KEYS.** Both fields below were added after this type
    /// was already `Codable`, so a payload encoded before they existed decodes
    /// only if they are optional at the decoding boundary. Encoding is unchanged
    /// and still writes them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(URL.self, forKey: .url)
        fallbackURLs = try c.decodeIfPresent([URL].self, forKey: .fallbackURLs) ?? []
        fileName = try c.decode(String.self, forKey: .fileName)
        expectedBytes = try c.decode(Int.self, forKey: .expectedBytes)
        sha256 = try c.decode(String.self, forKey: .sha256)
        licence = try c.decode(String.self, forKey: .licence)
        attribution = try c.decode(String.self, forKey: .attribution)
        summary = try c.decode(String.self, forKey: .summary)
        licenceNotice = try c.decodeIfPresent(String.self, forKey: .licenceNotice)
    }
}

/// The built-in list of downloadable banks. One entry today; the shape is a
/// list because the picker, the wire verb and the MCP tool all discover from
/// it rather than hard-coding an id.
public enum DownloadableSoundBankCatalog {

    /// **MuseScore General** — the m34-c pick, decided in
    /// `docs/research/spike-soundfont-download.md` after a licence audit of
    /// three candidates.
    ///
    /// ## Why THIS url and not the obvious one
    ///
    /// The MuseScore GitHub repo now ships `.sf3` (Vorbis-compressed) ONLY.
    /// DAW Pro can convert an `.sf3` (m31-h) but that decoder is MEASURED to
    /// fail on 17 of 1186 streams of a sibling file, silencing 15 mainstream GM
    /// presets. This osuosl mirror hosts the NATIVE `.sf2`, so the whole risk
    /// class stays out of a first-run download path. The mirror's files have
    /// been unchanged since 2020-07-10 (`Last-Modified` confirms it).
    ///
    /// ## The checksum's honest label
    ///
    /// ⚠️ **SELF-COMPUTED 2026-08-30, not published by anyone.** The file was
    /// downloaded once during implementation and hashed locally
    /// (`shasum -a 256`); `expectedBytes` independently matches the mirror's
    /// own `Content-Length: 215614036`. This pin is load-bearing against
    /// **corruption and truncation** and is NOT evidence of **authenticity or
    /// provenance** — nobody upstream signed these bytes. Do not substitute
    /// Debian's `0e481d40…` hash: the spike confirms it is for version 0.2.1
    /// and possibly the separate HQ variant.
    public static let museScoreGeneral = DownloadableSoundBank(
        id: "musescore-general",
        name: "MuseScore General",
        // PRIMARY: our own release asset. See `fallbackURLs` on the type for why
        // we host it. MEASURED 2026-08-30 with an unauthenticated request: the
        // repo is public, `github.com/.../releases/download/...` 302s to a
        // short-lived signed URL on `release-assets.githubusercontent.com`, and
        // `URLSession` follows it — a HEAD reports `expectedContentLength`
        // 215614036 from the FINAL response, so the pre-check is unaffected.
        // ⛔ **THE `github.com` URL IS THE STABLE ONE. Never pin the signed
        // redirect target** — it carries an `se=` expiry and is minted per
        // request.
        url: URL(string: "https://github.com/dimichgh/daw-pro/releases/download/"
                 + "soundbanks-v1/MuseScore_General.sf2")!,
        // FALLBACK: the upstream mirror this project used as primary until
        // 2026-08-30. Byte-identical — verified by hashing downloads from BOTH
        // hosts to the same `sha256` below.
        fallbackURLs: [
            URL(string: "https://ftp.osuosl.org/pub/musescore/soundfont/"
                + "MuseScore_General/MuseScore_General.sf2")!,
        ],
        fileName: "MuseScore_General.sf2",
        expectedBytes: 215_614_036,
        sha256: "ee51d2c4b1525e70f19a45909c4fd7a2e26d91d115fa89dbf5a6bc413d8b9bf3",
        licence: "MIT",
        // ⚠️⚠️ **CORRECTED 2026-08-30 AFTER RE-FETCHING THE LICENCE FILE ITSELF.**
        // This list previously named only Cowgill and Wen while its own comment
        // claimed to be "verbatim … not paraphrased, not extended" — the record
        // said one thing and the source said another, and nothing compared them.
        // `MuseScore_General_License.md` names **FIVE** contributors, and the
        // omitted one was **the author of THIS FILE**: Collins made the
        // MuseScore_General adaptation. (He also wrote GeneralUser GS, the
        // rejected runner-up — which is how the two got conflated. Both are his.)
        //
        // Verbatim contributor lines from that file, re-fetched and quoted:
        //   FluidR3 (original version) by Frank Wen Copyright (c) 2000-02
        //   Mono conversion (FluidR3Mono) by Michael Cowgill Copyright (c) 2014-17
        //   Adaptation for MuseScore_General.sf2 by S. Christian Collins Copyright (c) 2018-19
        //   Temple Blocks instrument provided by Ethan Winer Copyright (c) 2002
        //   Drumline Cymbals provided by Michael Schorsch Copyright (c) 2016
        //
        // ⚠️ The file's MIT block repeats Wen and Cowgill with slightly narrower
        // years ("2014-16"); the per-contributor block above is the fuller one
        // and is what we reproduce. **Do not trim this list to fit a layout** —
        // MIT's condition is that the notice travel with the work.
        attribution: "MIT licence. FluidR3 © 2000–2002, 2008 Frank Wen; "
            + "mono conversion © 2014–2017 Michael Cowgill; "
            + "MuseScore General adaptation © 2018–2019 S. Christian Collins; "
            + "Temple Blocks © 2002 Ethan Winer; "
            + "Drumline Cymbals © 2016 Michael Schorsch.",
        summary: "A full set of 128 instruments plus around fifteen drum kits — "
            + "including brushes, which the sounds built into your Mac don't have.",
        // Transcribed from `MuseScore_General_License.md` at the upstream mirror,
        // re-fetched 2026-08-30. The acknowledgement list is included because the
        // licence file asks for "the acknowledgements AND copyright notices" —
        // wider than MIT's own condition, and cheap to honour.
        licenceNotice: """
            MuseScore_General.sf2 — version 0.2, 13 May 2020
            Redistributed by DAW Pro under the MIT licence. Unmodified.

            Detailed per-preset sample sources are published upstream as
            MuseScore_General_Sample_Sources.csv. Instruments without specific
            attribution use samples from FluidR3Mono.

            COPYRIGHT
            ---------
            FluidR3 (original version) by Frank Wen                       (c) 2000-02
            Mono conversion (FluidR3Mono) by Michael Cowgill              (c) 2014-17
            Adaptation for MuseScore_General.sf2 by S. Christian Collins  (c) 2018-19
            Temple Blocks instrument provided by Ethan Winer              (c) 2002
            Drumline Cymbals provided by Michael Schorsch                 (c) 2016

            Mono version: Copyright (c) 2014-16 Michael Cowgill
            Copyright (c) 2000-2002, 2008 Frank Wen <getfrank@gmail.com>

            ACKNOWLEDGEMENTS (from the original FluidR3 README)
            ---------------------------------------------------
            Fluid was constructed in part from samples found in the public domain
            that Frank Wen edited/cleaned/remixed/programmed, and largely from his
            own recordings, in conjunction with: Suren M. Seron, Scott Hanan,
            Steve Aupperle, Chris Gillman, Alex Taubr, Chris Prola, Andrew Klenk,
            Winfried Hubbe, Dylan, Tim, Gort, Uros Katic, Ethan Winer.
            Thanks to Toby Smithe for helping to get Fluid included in Ubuntu.

            MIT LICENCE
            -----------
            Permission is hereby granted, free of charge, to any person
            obtaining a copy of this software and associated documentation
            files (the "Software"), to deal in the Software without
            restriction, including without limitation the rights to use,
            copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the
            Software is furnished to do so, subject to the following
            conditions:

            The above copyright notice and this permission notice shall be
            included in all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
            EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
            OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
            NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
            HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
            WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
            FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
            OTHER DEALINGS IN THE SOFTWARE.
            """)

    /// Every bank offerable today, in display order.
    public static let all: [DownloadableSoundBank] = [museScoreGeneral]

    /// Look one up by wire id. Nil is a caller error, not a fallback.
    public static func bank(id: String) -> DownloadableSoundBank? {
        all.first { $0.id == id }
    }
}

// MARK: - Progress

/// One progress tick from a bank download, in a form that crosses an isolation
/// boundary and goes on the wire.
///
/// **Phase-based, not one blended percentage** — the `WhisperModelInstallProgress`
/// decision, restated because the reasoning is identical: a single number
/// weighted across a 206 MB transfer and a sub-second rename would be a guess,
/// and *"a guessed percentage that stalls at 3% is worse than an honest phase
/// label"*.
public struct SoundBankDownloadProgress: Sendable, Equatable, Codable {
    /// What the installer is doing. Ordered as they occur.
    public enum Phase: String, Sendable, Codable, CaseIterable {
        /// Disk-space check + hidden staging directory.
        case preparing
        /// The transfer itself — the only phase with meaningful byte counts.
        case downloading
        /// Byte count then SHA-256, over the staged file. Reads the whole file,
        /// so on a 206 MB bank this is seconds, not instant.
        case verifying
        /// Rename into the library, then the post-install assertions.
        case installing
        /// Done; the bank is where `SoundBankLibrary.scan()` can see it.
        case finished
    }

    public var phase: Phase
    /// The catalog id being installed — identity, matching `DownloadableSoundBank.id`.
    public var bankID: String
    /// 0...1 **within `phase`**. Phases with no measurable sub-work report 1.
    public var phaseFraction: Double
    /// Bytes transferred so far during `.downloading`, else 0.
    public var completedBytes: Int64
    /// Expected total for `.downloading`, else 0.
    public var totalBytes: Int64

    public init(phase: Phase, bankID: String, phaseFraction: Double,
                completedBytes: Int64 = 0, totalBytes: Int64 = 0) {
        self.phase = phase
        self.bankID = bankID
        self.phaseFraction = phaseFraction
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

// MARK: - Errors

/// Teaching errors, the `WhisperModelInstallError` idiom: every case names what
/// it acted on and what to do next. Nothing here is a warning — a bank that
/// fails any check is never left where the library can see it.
public enum SoundBankInstallError: Error, LocalizedError, Equatable {
    /// No catalog entry with that id.
    case unknownBank(requested: String, known: [String])
    /// A file of the same name is already in the library. A REFUSAL rather
    /// than a uniquified second copy: silently landing a 206 MB
    /// "MuseScore_General 2.sf2" is not something anyone asked for.
    case alreadyInstalled(name: String, path: String)
    /// Not enough room, checked BEFORE a byte moves.
    case notEnoughDiskSpace(requiredBytes: Int, availableBytes: Int64, path: String)
    /// The server's advertised length disagrees with the pin — the mirror file
    /// changed. Caught in the first second, not after 206 MB.
    case serverSizeMismatch(expectedBytes: Int, serverBytes: Int64, url: String)
    /// The transfer itself failed (network, HTTP status, unwritable staging).
    case transferFailed(reason: String)
    /// The staged file is the wrong length. THE completeness check.
    case sizeMismatch(expectedBytes: Int, actualBytes: Int)
    /// The staged file hashes differently from the pin. THE integrity check.
    case checksumMismatch(expected: String, actual: String)
    /// Installed, but `SoundBankLibrary.programs(for:)` could not read real
    /// preset names out of it — the post-install sentinel. Rolled back.
    case installedButUnreadable(name: String, path: String)
    /// Installed somewhere `SoundBankLibrary.scan()` does not reach. Rolled back.
    case notVisibleToLibrary(name: String, path: String, libraryDirectory: String)
    /// The user cancelled. A terminal state, not a failure to apologise for.
    case cancelled(name: String)

    public var errorDescription: String? {
        switch self {
        case .unknownBank(let requested, let known):
            return "There's no downloadable sound bank called \"\(requested)\". "
                + "Available: \(known.joined(separator: ", "))."
        case .alreadyInstalled(let name, let path):
            return "\(name) is already in your sound-bank library at \(path). "
                + "Delete that file first if you want to download it again."
        case .notEnoughDiskSpace(let required, let available, let path):
            return "Not enough free space on the disk holding \(path): "
                + "\(Self.megabytes(Int64(required))) needed, "
                + "\(Self.megabytes(available)) free. "
                + "Free some space and try again — nothing was downloaded."
        case .serverSizeMismatch(let expected, let server, let url):
            return "The file at \(url) is \(Self.megabytes(server)), not the "
                + "\(Self.megabytes(Int64(expected))) DAW Pro expects. "
                + "It has changed since it was checked, so the download was not started. "
                + "This needs a new checksum in the app, not a retry."
        case .transferFailed(let reason):
            return "The download didn't finish: \(reason). "
                + "Nothing was added to your library — check your connection and try again."
        case .sizeMismatch(let expected, let actual):
            return "The download stopped early: got \(Self.megabytes(Int64(actual))) "
                + "of \(Self.megabytes(Int64(expected))). "
                + "The partial file was deleted; try again."
        case .checksumMismatch(let expected, let actual):
            return "The downloaded file doesn't match its expected fingerprint "
                + "(expected \(expected.prefix(12))…, got \(actual.prefix(12))…). "
                + "It was deleted rather than added — try again, and if it keeps "
                + "happening the file at the source has changed."
        case .installedButUnreadable(let name, let path):
            return "\(name) downloaded but DAW Pro couldn't read any instrument names "
                + "out of it, which means the file isn't a complete SoundFont. "
                + "It was removed from \(path) rather than left there looking usable. Try again."
        case .notVisibleToLibrary(let name, let path, let library):
            return "Put \(name) at \(path), which isn't inside \(library) where DAW Pro "
                + "looks for sound banks. Nothing was installed. "
                + "This is a bug in the installer, not something to retry."
        case .cancelled(let name):
            return "Download of \(name) was cancelled. Nothing was added to your library."
        }
    }

    /// THE size arithmetic, shared with the catalogue and the picker
    /// (`DownloadableSoundBank.formattedMegabytes`). Errors are read by
    /// humans; a raw byte count is not an answer, and a SECOND rounding
    /// convention is how a UI ends up showing two numbers for one file.
    private static func megabytes(_ bytes: Int64) -> String {
        DownloadableSoundBank.formattedMegabytes(bytes)
    }
}

// MARK: - The installer

/// Downloads a catalog bank into `SoundBankLibrary.libraryDirectory` and
/// proves it landed usable (m34-c).
///
/// ## The failure this type exists to prevent
///
/// The roadmap item names it: *"a half-downloaded bank that reports success is
/// this tree's characteristic defect wearing a new hat."* Four checks stand
/// between a transfer and a success, and they are deliberately layered so each
/// one can fail on its own:
///
/// | check | catches |
/// |---|---|
/// | server `Content-Length` vs. the pin | the source file changed — fails in the first second |
/// | staged byte count vs. `expectedBytes` | a truncated transfer |
/// | staged SHA-256 vs. `sha256` | corruption; bytes that are the right LENGTH but wrong |
/// | `programs(for:).namesParsed == true` | a file that is structurally not a readable SoundFont |
///
/// ⭐ The last one is the sentinel the spike argued for and it is not
/// redundant: an SF2's preset-header chunk (`phdr`) sits structurally AFTER the
/// sample data, and `SoundBankLibrary.programs(for:)` **falls back to a generic
/// "Program 0…127" list rather than throwing** when it cannot parse names — so
/// without this assertion a broken bank presents as a normal, blandly-named
/// one. `SoundBankInstallerTests` proves it fires by feeding a truncated
/// fixture whose OWN size and hash are pinned, so the two transfer checks pass
/// and only this one can catch it.
///
/// ## Staging
///
/// `<libraryDirectory>/.staging-<uuid>/`, the `WhisperModelInstaller` shape,
/// for its two reasons: **same volume** (so the install is a rename, not a
/// second 206 MB copy) and **invisible while it fills**. The second is
/// VERIFIED here rather than assumed by analogy — `SoundBankLibrary.scan()`
/// passes `.skipsHiddenFiles` (`SoundBanks.swift:251`), so a dot-prefixed
/// directory cannot surface as a half-downloaded bank. The staging directory
/// is removed on every exit path, success or failure.
///
/// ⛔ **Deliberately NOT `SoundBankLibrary.importBank(from:)`.** That method
/// COPIES its source (`SoundBanks.swift:314`) and uniquifies on collision —
/// both wrong here: a copy doubles a 206 MB write, and uniquifying turns "you
/// already have this" into a silent second copy.
public struct SoundBankInstaller: Sendable {

    /// Moves the bytes at `url` to `destination`, reporting
    /// `(completedBytes, totalBytes)` as it goes.
    ///
    /// Injected so the WHOLE install path — staging, both transfer checks, the
    /// rename, and the post-install sentinel — is exercised offline against a
    /// local fixture. The real network leg is a one-off, not something 7,500
    /// tests pay for. A fake that writes a short file is how the truncation
    /// control is built.
    public typealias TransferFunction = @Sendable (
        _ url: URL,
        _ destination: URL,
        _ expectedBytes: Int,
        _ progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Void

    /// Free space on the volume holding a path, in bytes. Injected because a
    /// disk-space refusal is otherwise untestable — you cannot fill a CI
    /// machine's disk to assert on it.
    public typealias CapacityFunction = @Sendable (URL) -> Int64?

    /// The library this installs INTO — the same value `ProjectStore` scans.
    /// Injected so tests never touch the real profile.
    public let library: SoundBankLibrary

    let transfer: TransferFunction
    let availableCapacity: CapacityFunction

    /// Headroom demanded on top of the bank's own size before starting.
    ///
    /// ⚠️ Deliberately a fixed margin, NOT a second copy of the file. The
    /// transfer's temporary file and the staged file are the SAME file after a
    /// same-volume rename, so peak usage is one copy; this margin exists so a
    /// download cannot take a volume to literally zero free bytes, which macOS
    /// handles badly.
    public static let diskHeadroomBytes = 100_000_000

    /// Staging directories are named `<prefix><uuid>`. The leading dot is what
    /// keeps them out of `scan()`.
    public static let stagingDirectoryPrefix = ".staging-"

    public init(library: SoundBankLibrary = SoundBankLibrary(),
                transfer: @escaping TransferFunction = SoundBankInstaller.liveTransfer,
                availableCapacity: @escaping CapacityFunction
                    = SoundBankInstaller.volumeAvailableCapacity) {
        self.library = library
        self.transfer = transfer
        self.availableCapacity = availableCapacity
    }

    // MARK: Public entry point

    /// Download `bank` and install it where `SoundBankLibrary.scan()` sees it.
    ///
    /// Cancellable at every phase boundary and throughout the transfer:
    /// cancelling removes the staging directory and throws
    /// `SoundBankInstallError.cancelled`, so a cancelled download leaves
    /// nothing behind.
    ///
    /// - Returns: The `SoundBankInfo` the library now resolves — an ordinary
    ///   `.file(path:)` bank, indistinguishable from a manual import, because
    ///   that is exactly what it is (no new `SoundBankSource` case exists or is
    ///   needed).
    @discardableResult
    public func install(
        bank: DownloadableSoundBank,
        progress: (@Sendable (SoundBankDownloadProgress) -> Void)? = nil
    ) async throws -> SoundBankInfo {
        let fm = FileManager.default
        progress?(SoundBankDownloadProgress(
            phase: .preparing, bankID: bank.id, phaseFraction: 0))

        // Refuse BEFORE the network: a bank already sitting in the library is
        // not something to quietly re-fetch 206 MB for.
        let destination = library.libraryDirectory.appendingPathComponent(bank.fileName)
        if fm.fileExists(atPath: destination.path) {
            throw SoundBankInstallError.alreadyInstalled(
                name: bank.name, path: destination.path)
        }
        try fm.createDirectory(at: library.libraryDirectory, withIntermediateDirectories: true)

        // Disk space, also BEFORE the network. A `nil` capacity reading means
        // the volume would not answer — that is not evidence of enough room,
        // but refusing on it would ground the feature on any filesystem that
        // does not report capacity, so it proceeds and lets the size check
        // downstream catch a short write. Stated rather than silent.
        let required = bank.expectedBytes + Self.diskHeadroomBytes
        if let free = availableCapacity(library.libraryDirectory), free < Int64(required) {
            throw SoundBankInstallError.notEnoughDiskSpace(
                requiredBytes: required, availableBytes: free,
                path: library.libraryDirectory.path)
        }

        try Self.checkCancellation(bank)
        let staging = try makeStagingDirectory()
        func cleanUpStaging() { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(bank.fileName)

        do {
            // 1. THE TRANSFER.
            progress?(SoundBankDownloadProgress(
                phase: .downloading, bankID: bank.id, phaseFraction: 0,
                completedBytes: 0, totalBytes: Int64(bank.expectedBytes)))
            //    Sources are tried in order. ⛔ **A CANCELLATION IS NOT A SOURCE
            //    FAILURE.** Retrying it would march the user's own Cancel through
            //    every mirror before honouring it — so cancellation rethrows at
            //    once and only a genuine transport failure advances the loop.
            //    ⚠️ A failed attempt can leave a partial file; the next source
            //    must start clean, or a short first attempt plus a good second
            //    one could append into a file that passes neither check for a
            //    reason nobody could read from the error.
            var lastError: Error?
            var transferred = false
            for source in bank.allSources {
                try Self.checkCancellation(bank)
                try? fm.removeItem(at: staged)
                do {
                    try await transfer(source, staged, bank.expectedBytes) { done, total in
                        let denominator = total > 0 ? total : Int64(bank.expectedBytes)
                        progress?(SoundBankDownloadProgress(
                            phase: .downloading, bankID: bank.id,
                            phaseFraction: denominator > 0
                                ? min(1, Double(done) / Double(denominator)) : 0,
                            completedBytes: done, totalBytes: denominator))
                    }
                    transferred = true
                    break
                } catch {
                    if Self.isCancellation(error) { throw error }
                    lastError = error
                }
            }
            //    ⚠️ The LAST error is reported, not the first: the primary being
            //    down is expected and uninteresting once a fallback also failed,
            //    and the final failure is the one closest to why the user has
            //    nothing. Every source was tried before this throws.
            if !transferred {
                throw lastError ?? SoundBankInstallError.transferFailed(
                    reason: "no download source could be reached")
            }
            try Self.checkCancellation(bank)

            // 2. COMPLETENESS, then INTEGRITY. Two checks, two questions —
            //    see `DownloadableSoundBank`'s doc for why they are not one.
            progress?(SoundBankDownloadProgress(
                phase: .verifying, bankID: bank.id, phaseFraction: 0))
            let actualBytes = Self.fileSize(at: staged)
            guard actualBytes == bank.expectedBytes else {
                throw SoundBankInstallError.sizeMismatch(
                    expectedBytes: bank.expectedBytes, actualBytes: actualBytes)
            }
            let digest = try Self.sha256Hex(ofFileAt: staged)
            guard digest == bank.sha256.lowercased() else {
                throw SoundBankInstallError.checksumMismatch(
                    expected: bank.sha256.lowercased(), actual: digest)
            }
            try Self.checkCancellation(bank)

            // 3. THE INSTALL — a rename, same volume by construction.
            progress?(SoundBankDownloadProgress(
                phase: .installing, bankID: bank.id, phaseFraction: 0))
            let info = try installStagedBank(bank: bank, staged: staged, destination: destination)

            cleanUpStaging()
            progress?(SoundBankDownloadProgress(
                phase: .finished, bankID: bank.id, phaseFraction: 1,
                completedBytes: Int64(bank.expectedBytes),
                totalBytes: Int64(bank.expectedBytes)))
            return info
        } catch {
            cleanUpStaging()
            if Self.isCancellation(error) {
                throw SoundBankInstallError.cancelled(name: bank.name)
            }
            throw error
        }
    }

    /// Is this error a cancellation, whatever shape it arrived in?
    ///
    /// ⚠️ MEASURED, not assumed. A cancelled `URLSession` download throws
    /// `URLError(.cancelled)` — NOT Swift's `CancellationError` — so an
    /// `error is CancellationError` check alone reported a user's own Cancel
    /// press as a FAILED download whose message was the bare word
    /// "cancelled". That shipped past every offline test in this suite,
    /// because the fakes throw what the fake author expected. It was caught by
    /// pressing Cancel on a real 216 MB transfer and reading the wire.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case SoundBankInstallError.cancelled = error { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: The install (network-free, and therefore the real gate)

    /// Rename a verified staged file into the library and PROVE it landed
    /// usable. Takes URLs rather than doing its own downloading, so the suite
    /// exercises this exact code against a fixture with no network at all.
    ///
    /// Rolls back — deletes the installed file — on either post-install
    /// assertion, so a bank that cannot be read is never left sitting in the
    /// library looking fine.
    @discardableResult
    func installStagedBank(bank: DownloadableSoundBank,
                           staged: URL,
                           destination: URL) throws -> SoundBankInfo {
        let fm = FileManager.default
        // Re-checked, not merely checked in `install`: the pre-network refusal
        // happens minutes earlier and a manual import could have landed the
        // same name in between. `moveItem` onto an existing file throws, so
        // without this the user would get a filesystem error instead of the
        // sentence that tells them what happened.
        if fm.fileExists(atPath: destination.path) {
            throw SoundBankInstallError.alreadyInstalled(
                name: bank.name, path: destination.path)
        }
        try fm.moveItem(at: staged, to: destination)

        func rollBack() { try? fm.removeItem(at: destination) }

        // ASSERTION 1 — the library's own SCAN reaches it. `scan()` walks the
        // immediate children of each scan directory, so this is what proves the
        // file went where the app actually looks rather than merely somewhere.
        let standardized = destination.standardizedFileURL.path
        guard let scanned = library.scan().first(where: { $0.path == standardized }) else {
            rollBack()
            throw SoundBankInstallError.notVisibleToLibrary(
                name: bank.name, path: destination.path,
                libraryDirectory: library.libraryDirectory.path)
        }

        // ASSERTION 2 — THE SENTINEL. `programs(for:)` never throws for a
        // resolvable file: it returns a generic "Program 0…127" list with
        // `namesParsed: false`. So a truncated SoundFont looks like a working
        // one to every other check in the app, and only this comparison
        // distinguishes them.
        let listing = try library.programs(for: scanned.source)
        guard listing.namesParsed else {
            rollBack()
            throw SoundBankInstallError.installedButUnreadable(
                name: bank.name, path: destination.path)
        }

        // THE NOTICE. MIT requires it to travel with copies we distribute, and
        // as of 2026-08-30 we host the primary copy ourselves — so this is an
        // obligation, not decoration.
        //
        // ⛔ **BOTH FILES OR NEITHER, and that is why a 3 KB write can roll back
        // a 216 MB one.** The type doc claims the install "either produces both
        // files or neither"; a best-effort `try?` here would have made that
        // sentence false while leaving it in place, which is precisely the
        // record-says-X-source-says-Y shape this tree keeps paying for.
        //
        // ⚠️ `.txt`, and named off `fileName` — so it cannot be mistaken for a
        // bank by `library.scan()` (which takes only `.sf2`/`.dls`/`.sf3`) and
        // cannot collide when a second bank is added to the catalogue.
        if let notice = bank.licenceNotice {
            let noticeURL = library.libraryDirectory
                .appendingPathComponent("\(bank.fileName).LICENSE.txt")
            do {
                try notice.write(to: noticeURL, atomically: true, encoding: .utf8)
            } catch {
                rollBack()
                throw error
            }
        }
        return scanned
    }

    // MARK: Staging

    /// A fresh `<libraryDirectory>/.staging-<uuid>/`.
    func makeStagingDirectory(uuid: UUID = UUID()) throws -> URL {
        let url = library.libraryDirectory.appendingPathComponent(
            "\(Self.stagingDirectoryPrefix)\(uuid.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every staging directory currently under the library — so a run killed
    /// mid-download (which never reaches its own cleanup) can be swept.
    public func orphanedStagingDirectories() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: library.libraryDirectory, includingPropertiesForKeys: nil, options: [])) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix(Self.stagingDirectoryPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Verification primitives

    /// Streaming SHA-256, lowercase hex. Chunked deliberately: `Data(contentsOf:)`
    /// on a 206 MB bank would put the whole file in memory to answer a question
    /// that only needs 1 MB at a time.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(at url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Free space for "important usage" on the volume holding `url` — the key
    /// that accounts for purgeable space, i.e. what a large download can
    /// actually use.
    public static let volumeAvailableCapacity: CapacityFunction = { url in
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Cancellation as a TEACHING error rather than a bare `CancellationError`,
    /// so the wire and the picker both show the user a sentence.
    private static func checkCancellation(_ bank: DownloadableSoundBank) throws {
        if Task.isCancelled { throw SoundBankInstallError.cancelled(name: bank.name) }
    }
}

// MARK: - The live transfer

extension SoundBankInstaller {

    /// The real network leg: HEAD the URL, refuse immediately if its advertised
    /// length disagrees with the pin, then stream to `destination` with
    /// progress.
    ///
    /// ## Why a download TASK and not `bytes(for:)`
    ///
    /// `URLSession.AsyncBytes` yields ONE BYTE per `await`. On a 215,614,036-byte
    /// bank that is 215 million suspension points — measurably the wrong tool.
    /// A download task writes straight to a file and reports progress through
    /// its delegate.
    ///
    /// ## ⚠️ Why a SESSION delegate and not `download(from:delegate:)`
    ///
    /// This used the async `download(from:delegate:)` convenience with the
    /// observer as the TASK delegate, and it looked right. It was not: on a
    /// real transfer `didWriteData` never fired, so `completedBytes` sat at 0
    /// for the whole download and the picker's progress bar never moved —
    /// MEASURED on the live wire, invisible to every offline test here because
    /// the fakes report progress themselves. A session-level delegate does
    /// receive `didWriteData` even when the completion-handler form is used
    /// (that form only displaces `didFinishDownloadingTo`).
    ///
    /// ## Cancellation
    ///
    /// `withTaskCancellationHandler` cancels the URL task, which completes with
    /// `URLError(.cancelled)` — NOT `CancellationError`; see
    /// `isCancellation`, which exists because that difference silently
    /// mislabelled a user's Cancel as a failure.
    ///
    /// ## The HEAD pre-check, and where it is skipped
    ///
    /// A `Content-Length` that disagrees with the pin means the source file
    /// changed — the SHA-256 would fail 206 MB later, so failing in the first
    /// second is strictly kinder. It is skipped for `file:` URLs, which have no
    /// server to ask; that path exists for the offline end-to-end run, and it
    /// is skipped honestly rather than faked.
    public static let liveTransfer: TransferFunction = { url, destination, expectedBytes, progress in
        if !url.isFileURL {
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            let (_, headResponse) = try await URLSession.shared.data(for: head)
            if let http = headResponse as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else {
                    throw SoundBankInstallError.transferFailed(
                        reason: "the server answered HTTP \(http.statusCode)")
                }
                let advertised = http.expectedContentLength
                if advertised > 0 && advertised != Int64(expectedBytes) {
                    throw SoundBankInstallError.serverSizeMismatch(
                        expectedBytes: expectedBytes, serverBytes: advertised,
                        url: url.absoluteString)
                }
            }
        }

        let observer = SoundBankTransferObserver(expectedBytes: Int64(expectedBytes),
                                                 destination: destination,
                                                 report: progress)
        let session = URLSession(configuration: .default, delegate: observer,
                                 delegateQueue: nil)
        // A delegate session retains its delegate until it is invalidated.
        defer { session.finishTasksAndInvalidate() }

        let handle = SoundBankTransferHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Attached BEFORE the task exists, so no callback can arrive
                // with nowhere to land.
                observer.attach(continuation)
                let task = session.downloadTask(with: url)
                handle.store(task)
                task.resume()
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

/// Holds the in-flight `URLSessionTask` so `withTaskCancellationHandler` can
/// reach it.
///
/// **`@unchecked Sendable` justification.** Two stored properties, both
/// mutable, both touched ONLY inside `lock`; no other state, no buffers, and
/// nothing escapes. The `cancelled` flag closes the one real race: cancellation
/// can arrive BEFORE the task has been stored, and without it a Cancel pressed
/// in that window would be silently ignored and the download would run to
/// completion.
private final class SoundBankTransferHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func store(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let alreadyCancelled = cancelled
        lock.unlock()
        // Cancelling a task that has not been resumed yet still completes it
        // with `URLError(.cancelled)`, so the continuation is resumed exactly
        // once either way.
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// The live transfer's whole delegate: progress ticks, the finished file, and
/// the completion that resumes the caller.
///
/// ## ⚠️ Why the completion-handler form is not used, measured
///
/// `downloadTask(with:completionHandler:)` is the obvious shape and it is the
/// wrong one. Apple's own contract: a completion handler *"bypasses calls to
/// delegate methods for response and data delivery"* — and `didWriteData` IS a
/// data-delivery method. A build that used it reported `completedBytes: 0` for
/// the entire duration of a real 216 MB download, so the picker's progress bar
/// never moved. That is precisely the "spinner and hope" this item forbids, it
/// passed every offline test in this suite (the fakes report their own
/// progress), and it was found only by starting a real transfer and reading
/// the wire. So: no completion handler, and the delegate does all three jobs.
///
/// **`@unchecked Sendable` justification.** Every mutable property
/// (`continuation`, `moveError`, `movedFile`) is read and written ONLY inside
/// `lock`; the rest are immutable `let`s of `Sendable` type. Nothing else is
/// stored and nothing escapes. It cannot be `Sendable` by inference because
/// `NSObject` is not `Sendable` and `URLSessionDownloadDelegate` requires an
/// `NSObject` subclass — the annotation stands in for a conformance the
/// compiler cannot synthesise, not for a threading argument it would reject.
private final class SoundBankTransferObserver: NSObject, URLSessionDownloadDelegate,
                                               @unchecked Sendable {
    private let expectedBytes: Int64
    private let destination: URL
    private let report: @Sendable (Int64, Int64) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var movedFile = false

    init(expectedBytes: Int64, destination: URL,
         report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.report = report
    }

    /// Hand over the caller's continuation. Called BEFORE the task is created,
    /// so no callback can fire with nowhere to land.
    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Resumes exactly once — the continuation is taken out under the lock, so
    /// a second call is a no-op rather than a crash.
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        switch result {
        case .success: pending.resume()
        case .failure(let error): pending.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // `totalBytesExpectedToWrite` is `NSURLSessionTransferSizeUnknown` (-1)
        // when the server sends no length; fall back to the pin rather than
        // reporting a negative denominator the UI would have to special-case.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        report(totalBytesWritten, total)
    }

    /// The move MUST happen here: `location` is deleted the moment this
    /// returns. Same volume in practice (the system temp directory and
    /// Application Support both sit on the Data volume), so it is a rename.
    /// The outcome is recorded and reported from `didCompleteWithError`, which
    /// always follows.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            lock.lock()
            moveError = SoundBankInstallError.transferFailed(
                reason: "the server answered HTTP \(http.statusCode)")
            lock.unlock()
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); movedFile = true; lock.unlock()
        } catch {
            lock.lock(); moveError = error; lock.unlock()
        }
    }

    /// Always called, success or failure — including a cancellation, which
    /// arrives as `URLError(.cancelled)`.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let recordedError = moveError
        let moved = movedFile
        lock.unlock()
        if let recordedError { finish(.failure(recordedError)); return }
        guard moved else {
            finish(.failure(SoundBankInstallError.transferFailed(
                reason: "the download finished but produced no file")))
            return
        }
        finish(.success(()))
    }
}
