import Foundation

/// Where THIS PROCESS persists `UserDefaults` — the headless half of the
/// `debug.defaultsDomain` verb (m23-gf-f).
///
/// **Why the verb exists.** m23-gf-b moved every staging launch into its own
/// CFPreferences domain by launching the binary through a symlink named
/// `DAWProStaging`: a bundle-less executable's preferences domain is derived
/// from its executable path's last component, so renaming the process renames
/// the domain. Until now the gate corpus confirmed that isolation ONLY from the
/// outside, with `/bin/ps -o comm=`. That is an inference ABOUT the app, not a
/// statement BY it. This type is the app's own statement — the same upgrade
/// m23-ay gave profile roots.
///
/// ⛔ **THE HONESTY SPLIT THIS TYPE IS BUILT AROUND.** Two of the three answers
/// are OBSERVATIONS of the running process (`processName`, `bundleIdentifier`);
/// the third (`derivedDomain`) is a **DERIVATION** — it restates CFPreferences'
/// documented rule, it does not watch `cfprefsd` write bytes. The name says so
/// on purpose. `Probe` below is the measured half, and it is the only part of
/// this file that can DISAGREE with the derivation.
///
/// ⛔ **EVERYTHING HERE IS READ-ONLY.** A verb whose job is to prove the app is
/// not polluting a preferences domain must never write to one. There is no
/// `set`, no `removeObject`, no `synchronize`, no `setPersistentDomain`,
/// no `register(defaults:)` anywhere in this file or in its DAWApp handler —
/// and that claim is checked mechanically, not merely asserted here (see the
/// m23-gf-f close record; the check strips comment lines first, because a grep
/// that matches THIS sentence is a false positive).
public enum DefaultsDomainReport {

    // MARK: - The derivation

    /// The persistent domain a CFPreferences client resolves for a process:
    /// its bundle identifier when it has one, otherwise its process name.
    ///
    /// ⛔ **A DERIVATION, NOT A MEASUREMENT.** It encodes the rule; it does not
    /// observe the outcome. Callers that need evidence must pair it with
    /// `Probe`.
    ///
    /// The empty-string branch is a real decision, not defensive noise: an
    /// `Info.plist` carrying `CFBundleIdentifier = ""` yields a non-nil, empty
    /// `Bundle.main.bundleIdentifier`, and `""` is not a domain. Falling through
    /// to the process name keeps the answer a usable name in every launch shape
    /// instead of reporting a domain nothing could ever be read from.
    public static func derivedDomain(bundleIdentifier: String?, processName: String) -> String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
        return processName
    }

    // MARK: - The measurement

    /// One `UserDefaults` value, rendered for the wire AND fingerprinted for
    /// comparison — two different jobs that must not share one string.
    ///
    /// `display` is for a human reading a gate log. `fingerprint` is what
    /// equality is decided on, and it is TYPE-AWARE: the integer `1` and the
    /// string `"1"` display identically and must never compare equal, or the
    /// probe would report agreement between two different stores holding two
    /// different values. A binary property list is the canonical form
    /// `UserDefaults` values already live in, so it discriminates exactly the
    /// way the store itself does.
    public struct ProbeValue: Sendable, Equatable {
        /// Human-readable rendering. May be lossy — never compared.
        public let display: String
        /// Canonical, type-aware bytes (base64 binary plist). Equality of
        /// fingerprints IS equality of values.
        public let fingerprint: String

        public init(display: String, fingerprint: String) {
            self.display = display
            self.fingerprint = fingerprint
        }

        /// Fingerprints a value read out of a `UserDefaults` store.
        ///
        /// Returns `nil` for an absent value — ABSENCE IS ITS OWN ANSWER here
        /// and must never collapse into a sentinel value that could accidentally
        /// match another absence-sentinel on the far side.
        ///
        /// The `nonplist:` fallback is unreachable through `UserDefaults` (it
        /// stores property-list types only) and exists so a hostile or future
        /// value degrades to a stable string rather than trapping inside a
        /// diagnostic verb.
        public static func make(_ value: Any?) -> ProbeValue? {
            guard let value else { return nil }
            let display = String(describing: value)
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary),
                  let data = try? PropertyListSerialization.data(
                    fromPropertyList: [value], format: .binary, options: 0)
            else {
                return ProbeValue(display: display, fingerprint: "nonplist:\(display)")
            }
            return ProbeValue(display: display, fingerprint: data.base64EncodedString())
        }
    }

    /// The measured half: is a key the caller names visible BOTH through
    /// `UserDefaults.standard` and in the persistent domain we DERIVED, with the
    /// same value?
    ///
    /// ⚠️ **WHAT AGREEMENT PROVES, AND WHAT IT DOES NOT.**
    /// `UserDefaults.standard.object(forKey:)` searches the whole domain list
    /// (argument → volatile → persistent → registration), while
    /// `persistentDomain(forName:)` reads ONLY the persistent domain. So a key
    /// that arrived from registration defaults or from a `-key value` launch
    /// argument is legitimately present in the first and absent from the second
    /// on a perfectly correctly-derived domain. **Presence-and-match is positive
    /// evidence that the derivation is right; a mismatch is a reason to
    /// investigate, not a proof that it is wrong.** Name a key the app itself
    /// persisted (the gate uses `panelDensity.quantize`, which it drove over the
    /// wire moments earlier) and this ambiguity does not arise.
    public struct Probe: Sendable, Equatable {
        /// The key the caller asked about.
        public let key: String
        /// Its value via `UserDefaults.standard` — nil means absent.
        public let standardValue: ProbeValue?
        /// Its value inside the derived persistent domain — nil means absent.
        public let derivedDomainValue: ProbeValue?

        public init(key: String, standardValue: ProbeValue?, derivedDomainValue: ProbeValue?) {
            self.key = key
            self.standardValue = standardValue
            self.derivedDomainValue = derivedDomainValue
        }

        public var presentInStandard: Bool { standardValue != nil }
        public var presentInDerivedDomain: Bool { derivedDomainValue != nil }

        /// True when the key is absent on BOTH sides, so there was nothing to
        /// compare.
        ///
        /// ⭐⭐ **THE FLAG THAT KEEPS THIS PROBE FROM LYING.** `valuesMatch`
        /// alone is `nil == nil` → `true` for a key nobody ever wrote: a green
        /// answer that measured NOTHING. That is precisely the vacuity shape the
        /// m23gf gate's own POS1 comment block was rewritten to kill. Any caller
        /// asserting on this probe must assert `agrees`, which refuses to be
        /// true vacuously.
        public var vacuous: Bool { standardValue == nil && derivedDomainValue == nil }

        /// Fingerprint equality — deliberately `true` in the vacuous case, which
        /// is why it is NOT the field to assert on.
        public var valuesMatch: Bool {
            standardValue?.fingerprint == derivedDomainValue?.fingerprint
        }

        /// **The one field a caller should assert.** Both sides present, same
        /// value, nothing vacuous.
        public var agrees: Bool {
            !vacuous && presentInStandard && presentInDerivedDomain && valuesMatch
        }
    }

    // MARK: - The report

    /// What `debug.defaultsDomain` answers with.
    public struct Snapshot: Sendable, Equatable {
        /// OBSERVED: `ProcessInfo.processInfo.processName`.
        public let processName: String
        /// OBSERVED: `Bundle.main.bundleIdentifier`. **Explicitly nullable** —
        /// `nil` for the bare SwiftPM binary the gates launch, non-nil for the
        /// bundled `.app`. That difference is information; it is never papered
        /// over with a placeholder string.
        public let bundleIdentifier: String?
        /// DERIVED from the two above by `derivedDomain(bundleIdentifier:processName:)`.
        public let derivedDomain: String
        /// OBSERVED: how many keys the derived persistent domain currently
        /// holds; `nil` when that domain does not exist at all (which is what
        /// `persistentDomain(forName:)` answers for a never-written name — the
        /// negative control is in the tests).
        public let derivedDomainKeyCount: Int?
        /// OBSERVED, optional: the caller-requested agreement probe.
        public let probe: Probe?

        public init(processName: String,
                    bundleIdentifier: String?,
                    derivedDomain: String,
                    derivedDomainKeyCount: Int?,
                    probe: Probe?) {
            self.processName = processName
            self.bundleIdentifier = bundleIdentifier
            self.derivedDomain = derivedDomain
            self.derivedDomainKeyCount = derivedDomainKeyCount
            self.probe = probe
        }
    }

    /// Builds a snapshot from INJECTED process facts and INJECTED read closures,
    /// so every branch is unit-testable without swapping processes or touching
    /// the real preferences domain (the `TestEnvironment.isSwiftTestProcess`
    /// precedent: never read `ProcessInfo`/`Bundle` in here).
    ///
    /// Both closures are READS. There is no write seam in this signature, by
    /// construction — a caller cannot make this function mutate a domain even by
    /// accident.
    ///
    /// - Parameters:
    ///   - probeKey: nil (or empty) means "no probe" — the snapshot then carries
    ///     `probe == nil` rather than an empty probe that would read as a
    ///     vacuous pass.
    ///   - standardValue: reads the search-list value, i.e.
    ///     `UserDefaults.standard.object(forKey:)`.
    ///   - persistentDomain: reads a whole persistent domain by name, i.e.
    ///     `UserDefaults.standard.persistentDomain(forName:)`; `nil` when no
    ///     such domain exists.
    public static func snapshot(
        processName: String,
        bundleIdentifier: String?,
        probeKey: String?,
        standardValue: (String) -> Any?,
        persistentDomain: (String) -> [String: Any]?
    ) -> Snapshot {
        let domain = derivedDomain(bundleIdentifier: bundleIdentifier, processName: processName)
        let contents = persistentDomain(domain)
        var probe: Probe?
        if let probeKey, !probeKey.isEmpty {
            probe = Probe(key: probeKey,
                          standardValue: ProbeValue.make(standardValue(probeKey)),
                          derivedDomainValue: ProbeValue.make(contents?[probeKey]))
        }
        return Snapshot(processName: processName,
                        bundleIdentifier: bundleIdentifier,
                        derivedDomain: domain,
                        derivedDomainKeyCount: contents?.count,
                        probe: probe)
    }

    /// The real process's snapshot: the injection points above, wired to
    /// `ProcessInfo`, `Bundle.main` and `UserDefaults.standard`.
    ///
    /// This is the whole of the "live" layer on purpose — four reads and no
    /// logic — so that what the app reports and what the tests exercise cannot
    /// drift apart.
    public static func live(probeKey: String? = nil,
                            defaults: UserDefaults = .standard) -> Snapshot {
        snapshot(processName: ProcessInfo.processInfo.processName,
                 bundleIdentifier: Bundle.main.bundleIdentifier,
                 probeKey: probeKey,
                 standardValue: { defaults.object(forKey: $0) },
                 persistentDomain: { defaults.persistentDomain(forName: $0) })
    }
}
