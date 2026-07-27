import Foundation

/// Which master input a stem represents (M5 iv-c, spec §2): a direct-to-master
/// track's dry post-fader signal, or a bus (carrying everything routed into it
/// AND every send contribution, through the bus chain and fader).
public enum StemKind: String, Codable, Sendable { case track, bus }

/// One planned stem: a master input plus the sanitized, collision-free file
/// name it will be written under ("NN Name.wav", 1-based partition order).
public struct StemDescriptor: Identifiable, Sendable, Equatable {
    /// The master input's id — a direct track's or a bus track's UUID.
    public let id: UUID
    public let kind: StemKind
    /// Raw track name, unsanitized (display / wire identity).
    public let name: String
    /// "NN Name.wav" — sanitized, collision-suffixed (spec §2/§4).
    public let fileName: String

    public init(id: UUID, kind: StemKind, name: String, fileName: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.fileName = fileName
    }
}

/// One written stem file in a `StemExportResult` (spec §4.2). Codable = the
/// `render.stems` wire shape (iv-d) — wire-never-drifts. Stems are NEVER
/// normalized (spec §4.1): `measurement` is the honest report of exactly what
/// hit disk, including > 0 dBFS true peaks (Float32 end-to-end, the ii-e
/// no-baked-headroom stance).
public struct StemFile: Codable, Sendable, Equatable {
    public var trackId: UUID
    public var name: String
    public var kind: StemKind
    public var path: String
    public var measurement: LoudnessMeasurement

    public init(trackId: UUID, name: String, kind: StemKind, path: String,
                measurement: LoudnessMeasurement) {
        self.trackId = trackId
        self.name = name
        self.kind = kind
        self.path = path
        self.measurement = measurement
    }
}

/// The optional `includeMixdown` reference file ("00 Mixdown.wav") — the
/// null-check anchor: Σ stems ≡ this file, ≤ 1e-4 residual peak (spec §1).
public struct MixdownFile: Codable, Sendable, Equatable {
    public var path: String
    public var measurement: LoudnessMeasurement

    public init(path: String, measurement: LoudnessMeasurement) {
        self.path = path
        self.measurement = measurement
    }
}

/// The optional `includeMasteredMixdown` sibling file ("00 Mastered Mix.wav",
/// m23-m1) — the real MASTERED mix, rendered exactly the way `render.bounce`
/// renders: full session, real master chain, real master automation lane, real
/// master volume, optionally loudness-normalized.
///
/// It is a SIBLING of the stems, never a transformation of them, and this is
/// the whole point of the shape (research §4.3): for a nonlinear master chain
/// `M`, `Σᵢ M(sᵢ) ≠ M(Σᵢ sᵢ)`, so printing the shared chain onto each stem
/// would NOT add back up to this file. The stems stay chain-EXCLUDED (S-3′) and
/// keep nulling against `MixdownFile`; this file is what a listener hears.
/// Carries the same `BounceLoudnessReport` `render.bounce` returns — no
/// parallel report type — so an agent reads loudness/true-peak off the mastered
/// deliverable the same way everywhere.
public struct MasteredMixdownFile: Codable, Sendable, Equatable {
    public var path: String
    /// Input/output loudness, applied gain, target echo, ceiling-clamp flag —
    /// `output` is RE-MEASURED from the buffer that hit disk.
    public var report: BounceLoudnessReport

    public init(path: String, report: BounceLoudnessReport) {
        self.path = path
        self.report = report
    }
}

/// Result of `ProjectStore.renderStems` (spec §4.2). Every file shares one
/// duration/rate/channel shape — summation requires it, so the window is
/// computed once per call.
public struct StemExportResult: Codable, Sendable, Equatable {
    public var directory: String
    public var sampleRate: Double
    public var durationSeconds: Double
    public var channels: Int
    public var stems: [StemFile]
    public var mixdown: MixdownFile?
    /// Honesty field (m13-d, design §2): `"excluded"` when — and ONLY when —
    /// the project carries a non-empty master insert chain, so an agent can
    /// never mistake stems (pre-master material, S-3′) for mastered
    /// deliverables. nil (key omitted on the wire) for a chain-free project,
    /// keeping pre-m13-d results byte-identical.
    public var masterChain: String?
    /// The optional `includeMasteredMixdown` sibling (m23-m1) — nil (key
    /// omitted) unless it was asked for, so every pre-m23-m1 response stays
    /// byte-identical. Independent of `mixdown`: the two are different files
    /// with different, non-overlapping meanings (chain-EXCLUDED null anchor vs
    /// the real mastered deliverable) and both may be requested at once. Never
    /// a shared flag with a "which chain" switch — that shape is the Ableton
    /// footgun research §4.3 rejects.
    public var masteredMixdown: MasteredMixdownFile?
    /// Output format echo (m23-m2): the INTEGER bit depth written, or nil (key
    /// omitted) for the Float32 default — absence means "the default", so every
    /// pre-m23-m2 payload stays byte-identical.
    public var bitDepth: Int?
    /// Output format echo (m23-m2): `"aiff"`, or nil (key omitted) for the WAV
    /// default. Same absence rule as `bitDepth`.
    public var container: String?
    /// Present only where dithering could apply (an integer depth), and always
    /// `false` in v0 (m23-m2): the quantizer is undithered, and saying so is
    /// better than implying a noise-shaped dither we do not perform.
    public var ditherApplied: Bool?

    public init(directory: String, sampleRate: Double, durationSeconds: Double,
                channels: Int, stems: [StemFile], mixdown: MixdownFile? = nil,
                masterChain: String? = nil,
                masteredMixdown: MasteredMixdownFile? = nil,
                bitDepth: Int? = nil, container: String? = nil,
                ditherApplied: Bool? = nil) {
        self.directory = directory
        self.sampleRate = sampleRate
        self.durationSeconds = durationSeconds
        self.channels = channels
        self.stems = stems
        self.mixdown = mixdown
        self.masterChain = masterChain
        self.masteredMixdown = masteredMixdown
        self.bitDepth = bitDepth
        self.container = container
        self.ditherApplied = ditherApplied
    }
}

/// The stem plan (M5 iv-c, spec §2) — a PURE track-list transform, zero engine
/// knowledge, headless-testable.
///
/// Stems are the MASTER-INPUT PARTITION: one per signal the main mixer sums —
/// (a) every audio/instrument track routed direct to master
/// (`outputBusID == nil`) and (b) every bus track. A track's send contribution
/// lives in the DESTINATION bus's stem (the only partition where nonlinear bus
/// FX stay correct); the source track's stem is its dry post-fader signal.
/// Tracks routed INTO a bus have no stem of their own.
///
/// The normative invariant this plan exists to uphold:
/// Σ stems ≡ the mixdown, null residual peak ≤ 1e-4 — which additionally
/// requires every pass to run under the FULL-SESSION PDC plan
/// (`ProjectStore.renderStems` forces it; a subset auto-plan combs).
public enum StemPlan {

    /// The master-input partition in track-list order. `ids == nil` → all
    /// master inputs. Throws `ProjectError.trackNotFound` for an unknown id,
    /// or `.stemNotMasterInput` for a bus-routed source track id (its signal
    /// is part of the destination bus's stem — the message says so verbatim).
    public static func descriptors(tracks: [Track],
                                   including ids: [UUID]?,
                                   format: DeliveryFormat = .default) throws -> [StemDescriptor] {
        // Validate the request BEFORE filtering, so a bus-routed id rejects
        // readably instead of silently vanishing from the export.
        if let ids {
            for id in ids {
                guard let track = tracks.first(where: { $0.id == id }) else {
                    throw ProjectError.trackNotFound(id)
                }
                // `Track.isMasterInput` (m23-m3c) — the SAME predicate the
                // filter below uses, so the refusal and the selection can never
                // answer differently for one track. `outputBusID` cannot be nil
                // inside this branch by construction (a nil one IS a master
                // input), so the bind is a read, not a second condition.
                if !track.isMasterInput, let busID = track.outputBusID {
                    let busName = tracks.first(where: { $0.id == busID })?.name
                        ?? busID.uuidString
                    throw ProjectError.stemNotMasterInput(
                        "'\(track.name)' is routed to bus '\(busName)' — its signal is part of that bus's stem"
                    )
                }
            }
        }
        let requested = ids.map(Set.init)
        let selected = tracks.filter { track in
            // `Track.isMasterInput` (m23-m3c): the ONE home for the rule, shared
            // with the refusal above and with the arrange row's "Bounce in
            // Place" item.
            guard track.isMasterInput else { return false }
            return requested?.contains(track.id) ?? true
        }
        var taken = Set<String>()
        return selected.enumerated().map { index, track in
            let kind: StemKind = track.kind == .bus ? .bus : .track
            return StemDescriptor(
                id: track.id, kind: kind, name: track.name,
                fileName: fileName(index: index + 1, name: track.name,
                                   kind: kind, taken: &taken, format: format)
            )
        }
    }

    // MARK: - The two sibling files (m23-m3c)

    /// Base name of the optional `includeMixdown` reference file — the
    /// chain-EXCLUDED null anchor Σ stems compares against.
    ///
    /// A CONSTANT, not a literal at the write site, because m23-m3c gave the
    /// export dialog a preview of the planned set: the name now has a reader as
    /// well as a writer, and two spellings of it would let the dialog promise a
    /// file the render does not write. Carries no extension — the container is
    /// `DeliveryFormat`'s to decide (m23-m2), so every use goes through
    /// `format.fileName(...)`.
    public static let mixdownBaseName = "00 Mixdown"

    /// Base name of the optional `includeMasteredMixdown` sibling (m23-m1) — the
    /// real mastered deliverable, rendered the way `render.bounce` renders. Same
    /// one-home reasoning and the same no-extension rule as `mixdownBaseName`.
    public static let masteredMixdownBaseName = "00 Mastered Mix"

    /// Every file a `renderStems` call will write, in the order the set reads
    /// on disk (m23-m3c) — the ONE producer of the planned set.
    ///
    /// **The export dialog's stems preview renders exactly this**, and a test
    /// asserts it equals what `renderStems` ACTUALLY wrote. That equality is the
    /// point: a preview that mirrored the numbering, the sanitizing or the
    /// collision suffixes would be a second implementation, and the day one of
    /// them changed the dialog would start naming files nobody gets.
    ///
    /// Order: the two optional siblings first (both are `00 …`, mixdown before
    /// mastered — the order `renderStems` writes them), then the partition in
    /// track-list order. Throws exactly what `descriptors` throws, so an
    /// explicit id list is validated the same way in the preview as in the
    /// render; `including: nil` (every master input — what the dialog asks for)
    /// cannot throw.
    public static func fileSet(tracks: [Track],
                               including ids: [UUID]? = nil,
                               includeMixdown: Bool = false,
                               includeMasteredMixdown: Bool = false,
                               format: DeliveryFormat = .default) throws -> [String] {
        let stems = try descriptors(tracks: tracks, including: ids, format: format)
        // An empty partition writes NOTHING — not even the siblings.
        // `renderStems` guards `descriptors.isEmpty` with `nothingToRender`
        // BEFORE it creates the directory, so a set of two "00 …" files here
        // would promise an export that throws instead of writing them.
        guard !stems.isEmpty else { return [] }
        var names: [String] = []
        if includeMixdown { names.append(format.fileName(mixdownBaseName)) }
        if includeMasteredMixdown { names.append(format.fileName(masteredMixdownBaseName)) }
        return names + stems.map(\.fileName)
    }

    /// The solo transform: the subset track list whose master input is EXACTLY
    /// this stem's signal, given the full session track list.
    ///
    /// - `.track` stem T → `[T with sends = []]`. Removing sends cannot change
    ///   the direct signal — sends are post-fader FAN-OUT; the direct path is
    ///   untouched.
    /// - `.bus` stem B → every contributing source track (routed into B, or
    ///   with any send targeting B) with its sends filtered to ONLY those
    ///   targeting B and its direct out rewritten to a fresh SILENT DUMMY BUS
    ///   unless it already is B; plus bus track B unchanged; plus the dummy
    ///   (kind .bus, volume 0, no effects) exactly when some direct out was
    ///   rerouted. The dummy exists because a source track's direct out must
    ///   keep running (post-fader sends tap the strip output) yet must not
    ///   reach master — and the graph's missing-bus fallback IS master, so
    ///   "point at a missing bus" would leak the dry signal into the stem.
    ///
    /// Automation, clip gain/fades, stretch, comp members all ride along —
    /// tracks pass whole.
    public static func passTracks(for stem: StemDescriptor,
                                  session: [Track]) -> [Track] {
        switch stem.kind {
        case .track:
            guard var track = session.first(where: { $0.id == stem.id }) else {
                return []
            }
            track.sends = []
            let dummy = Track(name: "Stem Dummy", kind: .bus, volume: 0)
            var needsDummy = false
            var pass = [track]
            appendKeySources(to: &pass, session: session,
                             dummy: dummy, needsDummy: &needsDummy)
            if needsDummy { pass.append(dummy) }
            return pass

        case .bus:
            let dummy = Track(name: "Stem Dummy", kind: .bus, volume: 0)
            var needsDummy = false
            var pass: [Track] = []
            for track in session {
                if track.id == stem.id {
                    pass.append(track)  // The bus itself, untouched.
                    continue
                }
                guard track.kind != .bus else { continue }  // Foreign buses out.
                let routesIn = track.outputBusID == stem.id
                let sendsIn = track.sends.contains { $0.destinationBusID == stem.id }
                guard routesIn || sendsIn else { continue }
                var contributor = track
                contributor.sends = track.sends.filter { $0.destinationBusID == stem.id }
                if contributor.outputBusID != stem.id {
                    contributor.outputBusID = dummy.id
                    needsDummy = true
                }
                pass.append(contributor)
            }
            appendKeySources(to: &pass, session: session,
                             dummy: dummy, needsDummy: &needsDummy)
            if needsDummy { pass.append(dummy) }
            return pass
        }
    }

    /// Sidechain key-source closure (m12-f, design-m11f-sidechain §4-A):
    /// every pass whose strips host a keyed effect must ALSO carry the key
    /// source track — routed to the SILENT dummy bus so its signal exists to
    /// key the detector yet adds nothing to the stem's audio — or the pass
    /// would render a different gain-reduction curve than the mixdown and
    /// break Σ stems ≡ mixdown. Transitive (a key source's own keyed effect
    /// pulls ITS source in too — cycle-free by store validation, and the
    /// visited set makes even a hostile model terminate). Sends are dropped
    /// from added sources: sends are post-fader FAN-OUT (the direct signal
    /// is untouched), and by construction an added key source neither routes
    /// nor sends into the stem bus (it would already be a contributor).
    /// Sources that are buses or missing are SKIPPED — mirrors
    /// `SidechainGraph.keySourceTrackIDs` (no engine edge forms for them).
    /// No keyed effects anywhere → `pass` is untouched, bit-identical to the
    /// pre-sidechain transform.
    private static func appendKeySources(to pass: inout [Track], session: [Track],
                                         dummy: Track, needsDummy: inout Bool) {
        var included = Set(pass.map(\.id))
        var index = 0
        while index < pass.count {
            let effects = pass[index].effects
            index += 1
            for effect in effects {
                guard let sourceID = effect.sidechainSourceTrackID,
                      !included.contains(sourceID),
                      let source = session.first(where: { $0.id == sourceID }),
                      source.kind != .bus else { continue }
                var keySource = source
                keySource.sends = []
                keySource.outputBusID = dummy.id
                pass.append(keySource)
                included.insert(sourceID)
                needsDummy = true
            }
        }
    }

    /// "NN Name.<ext>" builder (spec §2): strip control characters and
    /// `/\:?%*|"<>`, trim whitespace/dots off the ends, empty → "Track"/"Bus";
    /// 2-digit 1-based index prefix in partition order; duplicate names get
    /// " 2", " 3"… suffixes (the media-copy collision precedent), compared
    /// case-insensitively because the default APFS volume is.
    ///
    /// The extension comes from `format` (m23-m2), never a literal: it selects
    /// the container the writer produces, so a hardcoded ".wav" here would ship
    /// AIFF stems under WAV names.
    static func fileName(index: Int, name: String, kind: StemKind,
                         taken: inout Set<String>,
                         format: DeliveryFormat = .default) -> String {
        let illegal = Set("/\\:?%*|\"<>")
        var sanitized = String(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !illegal.contains(Character($0))
        })
        let trimSet = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "."))
        sanitized = sanitized.trimmingCharacters(in: trimSet)
        if sanitized.isEmpty {
            sanitized = kind == .bus ? "Bus" : "Track"
        }
        var candidate = sanitized
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(sanitized) \(suffix)"
            suffix += 1
        }
        taken.insert(candidate.lowercased())
        return format.fileName(String(format: "%02d %@", index, candidate))
    }
}
