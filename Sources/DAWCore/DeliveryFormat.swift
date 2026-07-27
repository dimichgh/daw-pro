import Foundation

/// The file container a delivery render is written into (m23-m2).
///
/// The raw value IS the canonical file extension — deliberately, because the
/// EXTENSION IS LOAD-BEARING: `AVAudioFile(forWriting:)` has no file-type
/// parameter and infers the container from the URL's path extension alone.
/// Ask for AIFF and hand it a `.wav` path and it writes a WAV; hand it an
/// extension it does not recognize (including an UPPERCASE `.WAV`) and it
/// writes a CAF. That is why container and extension live in ONE type: if they
/// could be computed in two places they would drift, and the drift ships a file
/// whose bytes disagree with its name.
public enum DeliveryContainer: String, Codable, Sendable, CaseIterable {
    case wav
    case aiff

    /// Path extensions (lowercase, no dot) that already denote this container
    /// to the AVFoundation writer — MEASURED, not assumed (m23-m2 probe):
    /// `.wav` → RIFF/WAVE; `.aiff`, `.aif`, `.aifc` → FORM/AIFC. Every other
    /// spelling, including `.wave` and any uppercase variant, falls through to
    /// CAF. Members other than `rawValue` are accepted where the caller already
    /// typed one, never generated.
    var acceptedExtensions: [String] {
        switch self {
        case .wav: return ["wav"]
        case .aiff: return ["aiff", "aif", "aifc"]
        }
    }

    /// The container's name as a person reads it — the export dialog's chip
    /// label (m23-m3). Lives HERE, next to the raw value and the accepted
    /// extensions, because a UI that spelled "WAV" itself would be a second
    /// home for a fact this type owns; the m23-m2 law is that container,
    /// extension and label are one value or they drift.
    public var label: String { rawValue.uppercased() }

    /// One beginner-readable line under the label — never parsed, never
    /// matched, purely derived presentation copy.
    public var detail: String {
        switch self {
        case .wav: return "Opens everywhere — the safe choice."
        case .aiff: return "Apple's format, read by every Mac audio app."
        }
    }
}

/// The resolved output format of a delivery render (m23-m2): bit depth,
/// container, AND the file extension that container requires — one value, so
/// the settings dictionary and the filename can never disagree.
///
/// `init` is fileprivate, so `DeliveryFormat.resolve` is the ONLY producer: an
/// unvalidated or self-inconsistent format is unrepresentable rather than
/// merely absent (the `ResolvedDropBeat` / `ResolvedRenderExclusion` law). The
/// type is deliberately engine-free — no AVFoundation import — so DAWCore stays
/// engine-free; the settings-dictionary mapping lives in DAWEngine and reads
/// this value (`OfflineRenderer.fileSettings(base:format:)`).
///
/// **What an integer depth costs, measured (m23-m2), stated so it is never a
/// bug report.** Float32 (the default) is lossless and keeps > 0 dBFS content
/// intact — the ii-e no-baked-headroom stance. Every integer depth CLAMPS at
/// full scale: a buffer peaking at +3.5 dBFS written at 24-bit lands as
/// 0.9999999 on disk (measured), and the loudness report describes the
/// PRE-quantization buffer, so it will still say +3.5. Normalize the bounce
/// (`lufsTarget` / `truePeakCeilingDb`) or keep the Float32 default if that
/// matters. Quantization itself is round-to-nearest with NO dither in v0 —
/// `ditherApplied: false` is reported rather than claiming a dither we do not
/// perform.
public struct DeliveryFormat: Sendable, Equatable {
    /// Integer bit depth (16 / 24 / 32), or nil for Float32 — today's default,
    /// byte-for-byte unchanged.
    public let bitDepth: Int?
    public let container: DeliveryContainer

    /// The canonical extension this format MUST be written under, without the
    /// dot. Same type as the depth by construction — see the type's doc.
    public var fileExtension: String { container.rawValue }

    /// True for the pre-m23-m2 format: Float32, WAV. The protocol's
    /// format-aware seams fall back to the legacy writer on exactly this value,
    /// so a `nil`/`nil` render is bit-identical to a pre-m23-m2 one.
    public var isDefault: Bool { bitDepth == nil && container == .wav }

    /// Human-readable, for error text and logs. Never parsed.
    public var label: String {
        "\(bitDepth.map { "\($0)-bit integer" } ?? "32-bit float") \(container.rawValue.uppercased())"
    }

    // MARK: - Wire echo (m23-m1 convention: OMITTED when it is the default)

    /// `bitDepth` for the response — nil (key omitted) for the Float32 default,
    /// so every pre-m23-m2 payload stays byte-identical.
    public var reportedBitDepth: Int? { bitDepth }
    /// `container` for the response — nil (key omitted) for the WAV default.
    /// Absence therefore means "the default", the same rule `bitDepth` follows.
    public var reportedContainer: String? {
        container == .wav ? nil : container.rawValue
    }
    /// `ditherApplied` for the response — present only where dithering could
    /// even apply (an integer depth), and always `false` in v0: we truncate to
    /// the grid honestly rather than claim a dither we do not perform.
    public var reportedDitherApplied: Bool? { bitDepth == nil ? nil : false }

    fileprivate init(bitDepth: Int?, container: DeliveryContainer) {
        self.bitDepth = bitDepth
        self.container = container
    }

    /// Float32 WAV — the pre-m23-m2 behaviour, unchanged.
    public static let `default` = DeliveryFormat(bitDepth: nil, container: .wav)

    // MARK: - The offerable vocabulary (m23-m3)

    /// The integer depths this type accepts — the validator's OWN list, so a
    /// picker built from it can never offer a depth `resolve` rejects (or miss
    /// one it accepts). Read by `resolve` below; do not duplicate the literals.
    public static let validIntegerBitDepths: [Int] = [16, 24, 32]

    /// Every depth a chooser may offer, DERIVED from the validator's list:
    /// `nil` (Float32, the default) first, then the integer depths ascending.
    /// The export dialog enumerates exactly this — the picker cannot drift
    /// from what `resolve` will accept because it is the same array.
    public static let selectableBitDepths: [Int?] =
        [nil] + validIntegerBitDepths.map { Optional($0) }

    /// The control label for a depth — beginner-readable, no wire spelling
    /// ("16-bit", never "PCM16"). A pure function of the depth, living on this
    /// type rather than in a view so the dialog, a preview and any later
    /// surface all read the same words.
    public static func depthLabel(_ bitDepth: Int?) -> String {
        switch bitDepth {
        case nil: return "32-bit float"
        case 32: return "32-bit integer"
        case let depth?: return "\(depth)-bit"
        }
    }

    /// The one dim line under a depth label — what picking it actually costs
    /// or buys, in plain language (the m23-m2 measurements, said once).
    public static func depthDetail(_ bitDepth: Int?) -> String {
        switch bitDepth {
        case nil:
            return "Best quality, and what the app works in. The only choice that keeps peaks above full scale."
        case 16:
            return "CD quality, and the smallest files."
        case 24:
            return "The usual depth for delivering a finished mix."
        case 32:
            return "Whole-number samples at the finest step. Rarely what you want."
        case let depth?:
            return "\(depth)-bit whole-number samples."
        }
    }

    /// The ONE producer. `bitDepth` nil → Float32; `container` nil → WAV.
    /// Anything else throws BEFORE a render starts, so an invalid format can
    /// never leave a half-written export behind (the `RenderExclusion.resolve`
    /// validate-first precedent).
    public static func resolve(bitDepth: Int?, container: String?) throws -> DeliveryFormat {
        if let bitDepth, !validIntegerBitDepths.contains(bitDepth) {
            throw ProjectError.invalidOutputFormat(
                "'bitDepth' must be 16, 24 or 32 (got \(bitDepth)) — omit it for the "
                + "32-bit float default, which is lossless and keeps > 0 dBFS peaks")
        }
        var resolvedContainer = DeliveryContainer.wav
        if let container {
            // Exact lowercase only — deliberately the SAME vocabulary the MCP
            // tool's enum accepts, so a value cannot be legal on one entry
            // point and rejected on the other.
            guard let match = DeliveryContainer(rawValue: container) else {
                throw ProjectError.invalidOutputFormat(
                    "'container' must be one of "
                    + DeliveryContainer.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
                    + " (got '\(container)') — omit it for 'wav'")
            }
            resolvedContainer = match
        }
        return DeliveryFormat(bitDepth: bitDepth, container: resolvedContainer)
    }

    // MARK: - The load-bearing extension

    /// Applies this format's extension to a caller-supplied path — the ONE home
    /// for the rule, shared by the bounce, mixdown and stem destinations so a
    /// response can never report a container the filename contradicts.
    ///
    /// - An extension that already denotes this container in the exact
    ///   lowercase spelling the writer recognizes is kept verbatim
    ///   (`mix.wav` → `mix.wav`, `mix.aif` → `mix.aif`).
    /// - One that denotes it in any other casing is CANONICALIZED
    ///   (`mix.WAV` → `mix.wav`). This is a fix, not a nicety: the writer's
    ///   extension matching is case-SENSITIVE, so `mix.WAV` used to land a
    ///   **CAF** file under a `.WAV` name (measured, m23-m2).
    /// - Anything else gets the canonical extension APPENDED, never replaced
    ///   (`mix.aiff` + wav → `mix.aiff.wav`; `mix.wav` + aiff →
    ///   `mix.wav.aiff`). Appending keeps every pre-m23-m2 default-format path
    ///   byte-identical and can never clobber a name the caller meant to keep;
    ///   the cost is an occasionally ugly double extension, which is strictly
    ///   better than silently writing over the wrong file.
    public func applyingExtension(to path: String) -> String {
        let existing = (path as NSString).pathExtension
        if container.acceptedExtensions.contains(existing) { return path }
        let lowered = existing.lowercased()
        if container.acceptedExtensions.contains(lowered) {
            return (path as NSString).deletingPathExtension + "." + lowered
        }
        return path + "." + fileExtension
    }

    /// `"<base>.<ext>"` for the generated names (temp-dir destinations, the
    /// stem files, `"00 Mixdown"`) — the same one home, so a hardcoded
    /// `"00 Mixdown.wav"` cannot survive next to an AIFF export.
    public func fileName(_ base: String) -> String { base + "." + fileExtension }
}
