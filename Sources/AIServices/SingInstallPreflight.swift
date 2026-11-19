import Foundation

/// The checks the singing engine's install makes BEFORE anyone is asked to agree to it (design
/// `docs/design/2026-09-27-p2-sing-integration.md` §2.5 step 1 and §6 row 4): an Apple-silicon Mac on macOS 14 or
/// later, then enough free disk where the engine goes.
///
/// ⭐ ONE function for both doors (p2-sing-x7b, W8-SF's finding): `sing.installEngine` (the wire) and the Sing sheet's
/// install path (x8) call `check` before they ask for consent, so the window never offers a 7 GB download that
/// cannot fit or cannot run. It reads and decides; it asks, downloads and changes nothing.
public enum SingInstallPreflight {

    /// Why the install cannot start here: a stable code for the wire and the sentence a person reads.
    public struct Refusal: Error, Equatable, Sendable, LocalizedError {
        public var code: String
        public var sentence: String

        public init(code: String, sentence: String) {
            self.code = code
            self.sentence = sentence
        }

        public var errorDescription: String? { sentence }
    }

    /// The Mac the check judges. `current` reads this one; a test passes its own to make the check fail on purpose.
    public struct Host: Equatable, Sendable {
        public var isAppleSilicon: Bool
        public var isMacOS14OrLater: Bool

        public init(isAppleSilicon: Bool, isMacOS14OrLater: Bool) {
            self.isAppleSilicon = isAppleSilicon
            self.isMacOS14OrLater = isMacOS14OrLater
        }

        public static var current: Host {
            #if arch(arm64)
            let appleSilicon = true
            #else
            let appleSilicon = false
            #endif
            return Host(isAppleSilicon: appleSilicon,
                        isMacOS14OrLater: ProcessInfo.processInfo.isOperatingSystemAtLeast(
                            OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        }
    }

    /// nil = the install may be offered. The Mac first, then the disk: `needBytes` free is install.sh's own floor
    /// (`SingEngineFiles.minFreeBytes()`); `freeBytes` nil (the free space could not be read) does not refuse.
    public static func check(host: Host = .current, needBytes: Int64, freeBytes: Int64?) -> Refusal? {
        guard host.isAppleSilicon, host.isMacOS14OrLater else { return Copy.unsupportedMac }
        if let freeBytes, freeBytes < needBytes { return Copy.diskFull(need: needBytes, free: freeBytes) }
        return nil
    }

    /// The same check from the engine's files: the floor from `engineFiles`, the free space on the volume of
    /// `runtimeDir` (where the engine goes) as `freeDiskBytes` reads it. No `runtimeDir`: only the Mac is checked.
    public static func check(engineFiles: SingEngineFiles, runtimeDir: URL?,
                             freeDiskBytes: (URL) -> Int64? = { SingEngineFiles.freeBytes(near: $0) },
                             host: Host = .current) -> Refusal? {
        check(host: host, needBytes: engineFiles.minFreeBytes(), freeBytes: runtimeDir.flatMap(freeDiskBytes))
    }

    /// "12.9": bytes in decimal gigabytes, one decimal place.
    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }

    /// The two refusals, word for word as `sing.installEngine` has sent them since p2-sing-e (PROVISIONAL there:
    /// design §6 names the codes, not the sentences).
    public enum Copy {
        public static let unsupportedMac = Refusal(
            code: "singUnsupportedMac",
            sentence: "The singing engine needs a Mac with Apple silicon (an M-series chip) running macOS 14 or later, "
                + "so it can't be installed on this Mac.")

        public static func diskFull(need: Int64, free: Int64) -> Refusal {
            Refusal(code: "singDiskFull",
                    sentence: "Installing the singing engine needs \(gigabytes(need)) GB free on this Mac's disk, and "
                        + "only \(gigabytes(free)) GB is free. Free up some space, then try again.")
        }
    }
}
