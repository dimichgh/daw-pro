import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for `DefaultsDomainReport` (m23-gf-f) — the model behind
/// `debug.defaultsDomain`, the verb that lets the APP state which `UserDefaults`
/// domain it persists under instead of the gate harness inferring it from the
/// outside with `/bin/ps -o comm=`.
///
/// ⚠️ **NOTHING HERE ASSERTS A HARDCODED PROCESS NAME.** `processName` is
/// `DAWApp` for the shipped binary, `DAWProStaging` under the m23-gf-b staging
/// alias, and `swiftpm-testing-helper` inside this very test runner — a test
/// pinning any one of them would be asserting the launch shape it happens to run
/// in, and would go red under exactly the alias this feature exists to report.
/// The live tests assert RELATIONSHIPS (non-empty, stable, one-of) and the rest
/// inject their process facts.
@Suite("DefaultsDomainReport — the app's own defaults-domain statement (m23-gf-f)")
struct DefaultsDomainReportTests {

    // MARK: - The derivation

    @Test("a bundled app derives its domain from the bundle identifier; a bare binary from the process name")
    func derivationTable() {
        // Bundled: the identifier wins, even though a process name also exists.
        #expect(DefaultsDomainReport.derivedDomain(
            bundleIdentifier: "dev.dawpro.app", processName: "DAWApp") == "dev.dawpro.app")
        // Bare SwiftPM binary — no bundle identifier at all. This is the case
        // the whole m23-gf isolation mechanism rides on: rename the executable,
        // rename the domain.
        #expect(DefaultsDomainReport.derivedDomain(
            bundleIdentifier: nil, processName: "DAWProStaging") == "DAWProStaging")
        #expect(DefaultsDomainReport.derivedDomain(
            bundleIdentifier: nil, processName: "DAWApp") == "DAWApp")
    }

    @Test("an EMPTY bundle identifier falls through to the process name — \"\" is not a domain")
    func derivationEmptyBundleIdentifier() {
        // A real decision, not defensive noise: `CFBundleIdentifier = ""` yields
        // a non-nil empty string, and answering `""` would name a domain nothing
        // can ever be read from. A plain `bundleIdentifier ?? processName` would
        // return "" here — this is the branch that separates the two spellings.
        #expect(DefaultsDomainReport.derivedDomain(
            bundleIdentifier: "", processName: "DAWApp") == "DAWApp")
    }

    // MARK: - The comparator

    @Test("the fingerprint is TYPE-AWARE: 1 and \"1\" display alike and must not compare equal")
    func fingerprintDiscriminatesTypes() {
        let number = DefaultsDomainReport.ProbeValue.make(1)
        let string = DefaultsDomainReport.ProbeValue.make("1")
        // Positive control on the premise — if the displays differed, this test
        // would be proving nothing about the fingerprint.
        #expect(number?.display == string?.display)
        #expect(number?.fingerprint != string?.fingerprint)

        // Booleans are their own plist type too, so `true` must not read as `1`.
        let bool = DefaultsDomainReport.ProbeValue.make(true)
        #expect(bool?.fingerprint != number?.fingerprint)

        // …and the comparator still says EQUAL for genuinely equal values, which
        // is the control that keeps the two assertions above from passing for a
        // fingerprint that is merely random.
        #expect(DefaultsDomainReport.ProbeValue.make("simple")?.fingerprint
                == DefaultsDomainReport.ProbeValue.make("simple")?.fingerprint)
        #expect(DefaultsDomainReport.ProbeValue.make("simple")?.fingerprint
                != DefaultsDomainReport.ProbeValue.make("pro")?.fingerprint)
    }

    @Test("an absent value fingerprints as nil, never as a sentinel two absences could share")
    func fingerprintAbsence() {
        #expect(DefaultsDomainReport.ProbeValue.make(nil) == nil)
    }

    // MARK: - The probe's vacuity guard

    @Test("a key absent on BOTH sides is VACUOUS: valuesMatch is trivially true, agrees is false")
    func probeVacuity() {
        let probe = DefaultsDomainReport.Probe(
            key: "never.written", standardValue: nil, derivedDomainValue: nil)
        // The trap this flag exists for: nil == nil, so the naive field is true.
        #expect(probe.valuesMatch)
        #expect(probe.vacuous)
        // …and the field callers are told to assert refuses to be green for it.
        #expect(!probe.agrees)
        #expect(!probe.presentInStandard)
        #expect(!probe.presentInDerivedDomain)
    }

    @Test("one-sided presence is a disagreement, not a vacuum")
    func probeOneSided() {
        let standardOnly = DefaultsDomainReport.Probe(
            key: "k",
            standardValue: DefaultsDomainReport.ProbeValue.make("simple"),
            derivedDomainValue: nil)
        #expect(!standardOnly.vacuous)
        #expect(!standardOnly.valuesMatch)
        #expect(!standardOnly.agrees)

        let domainOnly = DefaultsDomainReport.Probe(
            key: "k",
            standardValue: nil,
            derivedDomainValue: DefaultsDomainReport.ProbeValue.make("simple"))
        #expect(!domainOnly.vacuous)
        #expect(!domainOnly.agrees)
    }

    @Test("both sides present with the same value is the ONLY shape that agrees")
    func probeAgreement() {
        let agreeing = DefaultsDomainReport.Probe(
            key: "panelDensity.quantize",
            standardValue: DefaultsDomainReport.ProbeValue.make("simple"),
            derivedDomainValue: DefaultsDomainReport.ProbeValue.make("simple"))
        #expect(agreeing.agrees)
        #expect(!agreeing.vacuous)

        let disagreeing = DefaultsDomainReport.Probe(
            key: "panelDensity.quantize",
            standardValue: DefaultsDomainReport.ProbeValue.make("simple"),
            derivedDomainValue: DefaultsDomainReport.ProbeValue.make("pro"))
        #expect(!disagreeing.agrees)
        #expect(!disagreeing.valuesMatch)
    }

    // MARK: - Snapshot assembly (injected facts, no process swapping)

    @Test("no probeKey means NO probe — never an empty probe that would read as a vacuous pass")
    func snapshotWithoutProbe() {
        for key: String? in [nil, ""] {
            let snapshot = DefaultsDomainReport.snapshot(
                processName: "DAWProStaging",
                bundleIdentifier: nil,
                probeKey: key,
                standardValue: { _ in Issue.record("standard read for a probe-less call"); return nil },
                persistentDomain: { _ in ["a": 1, "b": 2] })
            #expect(snapshot.probe == nil)
            #expect(snapshot.derivedDomain == "DAWProStaging")
            #expect(snapshot.derivedDomainKeyCount == 2)
        }
    }

    @Test("the probe reads the DERIVED domain's contents, not some other domain's")
    func snapshotProbesTheDerivedDomain() {
        var asked: [String] = []
        let snapshot = DefaultsDomainReport.snapshot(
            processName: "DAWApp",
            bundleIdentifier: "dev.dawpro.app",
            probeKey: "panelDensity.quantize",
            standardValue: { _ in "simple" },
            persistentDomain: { name in
                asked.append(name)
                // Only the bundled identifier's domain has anything in it. A
                // reporter that derived `DAWApp` would come back vacuous.
                return name == "dev.dawpro.app" ? ["panelDensity.quantize": "simple"] : nil
            })
        #expect(asked == ["dev.dawpro.app"])
        #expect(snapshot.derivedDomain == "dev.dawpro.app")
        #expect(snapshot.probe?.agrees == true)
    }

    @Test("a MISSING domain reports nil key count — distinct from an existing but empty one")
    func snapshotDomainAbsentVersusEmpty() {
        let missing = DefaultsDomainReport.snapshot(
            processName: "NoSuchProcess", bundleIdentifier: nil, probeKey: nil,
            standardValue: { _ in nil }, persistentDomain: { _ in nil })
        #expect(missing.derivedDomainKeyCount == nil)

        let empty = DefaultsDomainReport.snapshot(
            processName: "NoSuchProcess", bundleIdentifier: nil, probeKey: nil,
            standardValue: { _ in nil }, persistentDomain: { _ in [:] })
        #expect(empty.derivedDomainKeyCount == 0)
    }

    @Test("a value present in the SEARCH LIST but not in the persistent domain does not agree")
    func snapshotSearchListOnlyValue() {
        // The documented ambiguity, pinned so the doc comment cannot drift from
        // the behaviour: `UserDefaults.standard.object(forKey:)` also sees the
        // argument, volatile and registration domains, so a registered default
        // is legitimately absent from the persistent domain on a CORRECTLY
        // derived name. The probe must report that as a non-agreement rather
        // than inventing a match.
        let snapshot = DefaultsDomainReport.snapshot(
            processName: "DAWProStaging", bundleIdentifier: nil,
            probeKey: "registered.only",
            standardValue: { _ in "fromRegistrationDomain" },
            persistentDomain: { _ in [:] })
        #expect(snapshot.probe?.presentInStandard == true)
        #expect(snapshot.probe?.presentInDerivedDomain == false)
        #expect(snapshot.probe?.agrees == false)
    }

    // MARK: - Against a REAL CFPreferences domain

    /// The end-to-end shape, run against a real (scratch) persistent domain — the
    /// only test here that proves the reporter agrees with `cfprefsd` rather than
    /// with a closure the test wrote.
    ///
    /// ⛔ IT ALSO CARRIES THE READ-ONLY PROOF, MEASURED: the scratch domain's
    /// whole contents are captured before and after the reporter runs and must be
    /// identical. THE TEST writes the seed key; the reporter must write nothing.
    /// Non-vacuity is asserted first, so "unchanged" cannot pass for a reporter
    /// that never looked.
    @Test("against a real scratch domain: the probe agrees, and the reporter writes NOTHING")
    func liveDomainAgreementIsReadOnly() throws {
        let suite = "DefaultsDomainReportTests.\(UUID().uuidString)"
        let scratch = try #require(UserDefaults(suiteName: suite))
        defer { scratch.removePersistentDomain(forName: suite) }

        // Seeded BY THE TEST, through the store the app would use.
        scratch.set("simple", forKey: "panelDensity.quantize")
        let before = UserDefaults.standard.persistentDomain(forName: suite)
        // Premise check: the seed really is in the persistent domain. Without
        // this, the agreement below could be two nils shaking hands.
        #expect(before?["panelDensity.quantize"] as? String == "simple")

        let snapshot = DefaultsDomainReport.snapshot(
            processName: suite,                       // the scratch domain IS the "process"
            bundleIdentifier: nil,
            probeKey: "panelDensity.quantize",
            standardValue: { scratch.object(forKey: $0) },
            persistentDomain: { UserDefaults.standard.persistentDomain(forName: $0) })

        #expect(snapshot.derivedDomain == suite)
        #expect(snapshot.derivedDomainKeyCount != nil)
        #expect(snapshot.probe?.vacuous == false)          // asserted BEFORE the read-only claim
        #expect(snapshot.probe?.agrees == true)
        #expect(snapshot.probe?.standardValue?.display == "simple")

        let after = UserDefaults.standard.persistentDomain(forName: suite)
        #expect((before as NSDictionary?) == (after as NSDictionary?))
    }

    @Test("a never-written domain reads back nil — the negative control for the domain read itself")
    func liveDomainNegativeControl() {
        // If `persistentDomain(forName:)` returned an empty dictionary for
        // everything, `derivedDomainExists` would be meaningless and the test
        // above would pass against a broken instrument.
        let absent = "DefaultsDomainReportTests.absent.\(UUID().uuidString)"
        #expect(UserDefaults.standard.persistentDomain(forName: absent) == nil)
    }

    // MARK: - The live process

    @Test("live() reports THIS process honestly, and says the same thing twice")
    func liveProcessRelationships() {
        let first = DefaultsDomainReport.live()
        let second = DefaultsDomainReport.live()

        // Fidelity of the two OBSERVED fields — compared against a fresh read of
        // the same sources, which is the only non-tautological check available
        // for a value the test cannot control.
        #expect(first.processName == ProcessInfo.processInfo.processName)
        #expect(first.bundleIdentifier == Bundle.main.bundleIdentifier)

        // Relationships, not literals: this must hold as `DAWApp`, as
        // `DAWProStaging`, and as `swiftpm-testing-helper` (which is what it is
        // right now).
        #expect(!first.derivedDomain.isEmpty)
        #expect(first.derivedDomain == first.processName
                || first.derivedDomain == first.bundleIdentifier)
        #expect(first.derivedDomain == second.derivedDomain)
        #expect(first.probe == nil)                      // no probeKey asked for
    }

    @Test("live() with an unwritten probe key comes back vacuous rather than green")
    func liveProbeUnwrittenKey() {
        let key = "DefaultsDomainReportTests.neverWritten.\(UUID().uuidString)"
        let snapshot = DefaultsDomainReport.live(probeKey: key)
        #expect(snapshot.probe?.key == key)
        #expect(snapshot.probe?.vacuous == true)
        #expect(snapshot.probe?.agrees == false)
    }
}
