import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-br-1 — the AU host registry's prepare bookkeeping, the ledger behind
/// `engine.auPrepareStats`.
///
/// WHY IT EXISTS. m20-e's central legs prove "the sample-rate flip
/// re-prepared nothing" by hammering `note.audition` ~18 000 times per window
/// and watching its `reason` field — an INFERENCE, and a lossy one: that
/// field only reaches the registry after mute/solo, `!isRunning` and
/// `noRenderer` have been checked, so a concurrent not-ready can be masked.
/// These counters replace the statistical absence with an exact integer.
///
/// Nearly every test here is deliberately AU-FREE: a component id no machine
/// has (`zzzz/zzzz`) walks the whole prepare body and lands `.missing`
/// WITHOUT instantiating anything, which is both fast and precisely the case
/// the "count at the guard, not at instantiation" rule exists for. The one
/// test that needs a real live instance (releases can only be counted when
/// something real is removed) uses Apple's stock DLSMusicDevice, the
/// `AUHostingTests` recipe.
@MainActor
@Suite("AU prepare stats — m23-br-1", .serialized)
struct AUPrepareStatsTests {
    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")
    /// A component id no machine has: the prepare body runs in full and ends
    /// `.missing` with no AU ever created.
    private static let absent = AudioUnitComponentID(subType: "zzzz", manufacturer: "zzzz")

    private func auTrack(component: AudioUnitComponentID?, id: UUID = UUID(),
                         stateData: Data? = nil) -> Track {
        Track(id: id, name: "AU", kind: .instrument,
              instrument: InstrumentDescriptor(
                  kind: .audioUnit,
                  audioUnit: component.map {
                      AudioUnitConfig(component: $0, stateData: stateData)
                  }))
    }

    // MARK: - Counters

    @Test("a fresh registry reports the all-zero snapshot — identical to the headless/no-engine default, so a gate's baseline read means the same thing everywhere")
    func freshRegistryIsIdle() {
        let registry = AUHostRegistry()
        #expect(registry.prepareStats() == EngineAUPrepareStats.idle)
    }

    /// If someone "improves" the increment down to the successful-instantiation
    /// path, this goes 1 -> 0: a session whose every prepare fails would report
    /// a serene zero, which is the worst storm there is.
    @Test("a prepare that ends .missing STILL counts — the count site is the idempotency guard, not instantiation")
    func missingPrepareIsCounted() async {
        let registry = AUHostRegistry()
        let track = auTrack(component: Self.absent)
        await registry.prepare(track: track, sampleRate: 48_000)

        #expect(registry.status[track.id] == .missing)
        #expect(registry.preparedInstrument(forTrack: track.id) == nil)  // nothing instantiated
        let stats = registry.prepareStats()
        #expect(stats.instrumentPrepares == 1)
        #expect(stats.instrumentReleases == 0)
        #expect(stats.tracks.count == 1)
        #expect(stats.tracks.first?.trackId == track.id.uuidString)
        #expect(stats.tracks.first?.status == "missing")
        #expect(stats.tracks.first?.keyDigest != nil)  // the key WAS attempted
    }

    /// The counter must measure re-prepare WORK, not reconcile passes: a
    /// `tracksDidChange` storm over an unchanged project short-circuits at the
    /// guard and must move nothing.
    @Test("repeating an unchanged prepare short-circuits and does NOT count")
    func idempotentRepeatIsNotCounted() async {
        let registry = AUHostRegistry()
        let track = auTrack(component: Self.absent)
        for _ in 0..<5 {
            await registry.prepare(track: track, sampleRate: 48_000)
        }
        #expect(registry.prepareStats().instrumentPrepares == 1)
    }

    @Test("a CHANGED key gets past the guard and counts again, and the published digest changes with it")
    func changedKeyCountsAgain() async {
        let registry = AUHostRegistry()
        let id = UUID()
        await registry.prepare(track: auTrack(component: Self.absent, id: id), sampleRate: 48_000)
        let firstDigest = registry.prepareStats().tracks.first?.keyDigest

        await registry.prepare(track: auTrack(component: Self.absent, id: id), sampleRate: 44_100)
        let stats = registry.prepareStats()
        #expect(stats.instrumentPrepares == 2)
        #expect(stats.instrumentReleases == 0)  // nothing real was ever instantiated
        #expect(stats.tracks.first?.keyDigest != nil)
        #expect(stats.tracks.first?.keyDigest != firstDigest)
    }

    /// The descriptor-with-nothing-selected bail returns BEFORE the
    /// idempotency guard, so it has no prepare body to count — a deliberate
    /// exclusion (it would otherwise tick on every reconcile pass for such a
    /// track). It still publishes a slot, with no digest.
    @Test("a componentless .audioUnit descriptor publishes a slot with NO digest and is not counted")
    func componentlessDescriptorIsNotCounted() async {
        let registry = AUHostRegistry()
        let track = auTrack(component: nil)
        await registry.prepare(track: track, sampleRate: 48_000)

        let stats = registry.prepareStats()
        #expect(stats.instrumentPrepares == 0)
        #expect(stats.tracks.count == 1)
        #expect(stats.tracks.first?.status == "missing")
        #expect(stats.tracks.first?.keyDigest == nil)
    }

    /// The half of constraint 2 that needs no AU: a release counter that
    /// ticked for bookkeeping-only no-ops would make "instrument churn"
    /// indistinguishable from "a reconcile pass walked the tracks" — which is
    /// exactly what `syncAudioUnitInstruments` does on every project edit.
    @Test("a release that removes NO live instance is not counted — neither an unknown id nor a .missing slot")
    func noOpReleasesAreNotCounted() async {
        let registry = AUHostRegistry()
        registry.releaseInstrument(forTrack: UUID())         // never seen
        registry.releaseEffect(forEffect: UUID())

        let track = auTrack(component: Self.absent)
        await registry.prepare(track: track, sampleRate: 48_000)
        registry.releaseInstrument(forTrack: track.id)       // real slot, no instance

        let stats = registry.prepareStats()
        #expect(stats.instrumentReleases == 0)
        #expect(stats.effectReleases == 0)
        #expect(stats.instrumentPrepares == 1)               // the prepare still counted
    }

    /// The other half: a REAL removal must tick, and a config change must tick
    /// BOTH counters (prepare past the guard, then the wholesale replacement
    /// of the old instance). That 2/1 arithmetic is what m23-br-2's gate will
    /// subtract against. Needs a genuinely instantiated AU, so it uses Apple's
    /// stock DLSMusicDevice.
    @Test("a config change counts one prepare AND one release; the release comes from a REAL instance leaving the table")
    func configChangeCountsBothOnARealInstance() async throws {
        let registry = AUHostRegistry()
        let id = UUID()
        await registry.prepare(track: auTrack(component: Self.dls, id: id), sampleRate: 48_000)
        try #require(registry.status[id] == .ready)
        try #require(registry.preparedInstrument(forTrack: id) != nil)
        #expect(registry.prepareStats().instrumentPrepares == 1)
        #expect(registry.prepareStats().instrumentReleases == 0)  // first prepare: nothing to release

        // Same component, different rate → a changed key → wholesale replace.
        await registry.prepare(track: auTrack(component: Self.dls, id: id), sampleRate: 44_100)
        let stats = registry.prepareStats()
        print("[measured] post-reconfigure status: \(String(describing: registry.status[id])), "
              + "prepares \(stats.instrumentPrepares), releases \(stats.instrumentReleases)")
        // The release fires BEFORE instantiation, so this arithmetic holds
        // whatever the second prepare's outcome turns out to be on this box.
        #expect(stats.instrumentPrepares == 2)
        #expect(stats.instrumentReleases == 1)

        // An explicit release now ticks once more IF the second prepare left a
        // live instance behind, and not at all if it did not — stated as a
        // conditional rather than a fixed number so the leg pins the
        // real-removal rule instead of this machine's DLS behaviour at 44.1k.
        let hadLiveInstance = registry.preparedInstrument(forTrack: id) != nil
        registry.releaseInstrument(forTrack: id)
        #expect(registry.prepareStats().instrumentReleases == (hadLiveInstance ? 2 : 1))
    }

    // MARK: - Effect mirror

    @Test("the effect counters mirror the instrument ones: counted past the guard, not on an idempotent repeat")
    func effectCountersMirrorTheInstrumentPath() async {
        let registry = AUHostRegistry()
        let effectID = UUID()
        let config = AudioUnitConfig(component: Self.absent)
        await registry.prepareEffect(effectID: effectID, config: config, sampleRate: 48_000)
        await registry.prepareEffect(effectID: effectID, config: config, sampleRate: 48_000)

        let stats = registry.prepareStats()
        #expect(stats.effectPrepares == 1)                   // the repeat short-circuited
        #expect(stats.effectReleases == 0)
        #expect(stats.instrumentPrepares == 0)               // the two ledgers are independent
        #expect(stats.effects.count == 1)
        #expect(stats.effects.first?.effectId == effectID.uuidString)
        #expect(stats.effects.first?.status == "missing")
        #expect(stats.effects.first?.keyDigest != nil)

        await registry.prepareEffect(effectID: effectID, config: config, sampleRate: 44_100)
        #expect(registry.prepareStats().effectPrepares == 2)
    }

    // MARK: - Digest

    /// THE cross-run pin. Same-process "equal keys digest equally" is true even
    /// for a per-process-seeded `Hasher`, so only a hardcoded expected value
    /// can catch a swap to `hashValue` — the seed changes every run and this
    /// literal stops matching.
    @Test("the digest of a fully-specified key is a fixed 16-hex-char SHA256 prefix — the golden value a per-process Hasher could never reproduce")
    func digestGoldenValue() {
        let key = AUHostRegistry.PrepareKey(
            component: AudioUnitComponentID(type: "aumu", subType: "samp", manufacturer: "appl"),
            sampleRate: 48_000,
            stateData: Data([0x01, 0x02, 0x03]),
            soundBankAddress: SoundBankConfig.Address(
                source: .generalMIDI, program: 56, bankMSB: 121, bankLSB: 0))
        let digest = AUHostRegistry.digest(of: key)
        print("[measured] golden prepare-key digest: \(digest)")
        #expect(digest == "4546e0b9dbd184f3")
        #expect(digest.count == 16)
        #expect(digest.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("two independently built EQUAL keys digest identically")
    func digestIsStableForEqualKeys() {
        func key() -> AUHostRegistry.PrepareKey {
            AUHostRegistry.PrepareKey(
                component: AudioUnitComponentID(subType: "dls ", manufacturer: "appl"),
                sampleRate: 44_100, stateData: Data([9, 9]), soundBankAddress: nil)
        }
        #expect(key() == key())
        #expect(AUHostRegistry.digest(of: key()) == AUHostRegistry.digest(of: key()))
    }

    /// One leg per field of `PrepareKey`. A digest that ignored a field would
    /// make `engine.auPrepareStats` report "the key did not change" across a
    /// re-prepare that genuinely changed it — the exact false negative this
    /// whole item exists to remove.
    @Test("the digest changes when ANY key field changes — component, sampleRate, stateData, soundBankAddress — and nil stateData differs from EMPTY stateData")
    func digestDiffersPerField() {
        // `PrepareKey`'s fields are `let`, so each leg builds a whole key —
        // which is the honest shape anyway: these are the four axes the
        // registry's own `==` compares.
        func key(component: AudioUnitComponentID
                     = AudioUnitComponentID(subType: "samp", manufacturer: "appl"),
                 sampleRate: Double = 48_000,
                 stateData: Data? = nil,
                 bank: SoundBankConfig.Address? = nil) -> AUHostRegistry.PrepareKey {
            AUHostRegistry.PrepareKey(component: component, sampleRate: sampleRate,
                                      stateData: stateData, soundBankAddress: bank)
        }
        let base = key()
        let baseDigest = AUHostRegistry.digest(of: base)

        let otherComponent = key(
            component: AudioUnitComponentID(subType: "dls ", manufacturer: "appl"))
        #expect(AUHostRegistry.digest(of: otherComponent) != baseDigest)

        #expect(AUHostRegistry.digest(of: key(sampleRate: 44_100)) != baseDigest)

        // nil ("nothing was saved") vs empty ("a zero-byte state was saved")
        // are DIFFERENT keys — `PrepareKey`'s own == says so, and a naive
        // concatenating encoder would collide them.
        let emptyState = key(stateData: Data())
        #expect(emptyState != base)
        let emptyStateDigest = AUHostRegistry.digest(of: emptyState)
        #expect(emptyStateDigest != baseDigest)

        let someState = key(stateData: Data([0x42]))
        #expect(AUHostRegistry.digest(of: someState) != baseDigest)
        #expect(AUHostRegistry.digest(of: someState) != emptyStateDigest)

        let bank = key(bank: SoundBankConfig.Address(
            source: .generalMIDI, program: 0, bankMSB: 121, bankLSB: 0))
        let bankDigest = AUHostRegistry.digest(of: bank)
        #expect(bankDigest != baseDigest)

        let otherProgram = key(bank: SoundBankConfig.Address(
            source: .generalMIDI, program: 1, bankMSB: 121, bankLSB: 0))
        #expect(AUHostRegistry.digest(of: otherProgram) != bankDigest)

        // The bank SOURCE is part of the address too — a file bank and the GM
        // bank at the same program are different instruments.
        let fileBank = key(bank: SoundBankConfig.Address(
            source: .file(path: "/tmp/x.sf2"), program: 0, bankMSB: 121, bankLSB: 0))
        #expect(AUHostRegistry.digest(of: fileBank) != bankDigest)

        // …and so are the two bank-select bytes. MSB 120 vs 121 is the
        // percussion-kit-vs-melodic switch, i.e. a user-reachable change that
        // MUST show up as a different key.
        let percussion = key(bank: SoundBankConfig.Address(
            source: .generalMIDI, program: 0, bankMSB: 120, bankLSB: 0))
        #expect(AUHostRegistry.digest(of: percussion) != bankDigest)
        let otherLSB = key(bank: SoundBankConfig.Address(
            source: .generalMIDI, program: 0, bankMSB: 121, bankLSB: 3))
        #expect(AUHostRegistry.digest(of: otherLSB) != bankDigest)
    }

    @Test("the published digest is exactly the digest of `attempted` — the value the idempotency guard compares against")
    func publishedDigestIsTheAttemptedKey() async throws {
        let registry = AUHostRegistry()
        let track = auTrack(component: Self.absent)
        await registry.prepare(track: track, sampleRate: 48_000)
        let key = try #require(AUHostRegistry.prepareKey(track: track, sampleRate: 48_000))
        #expect(registry.prepareStats().tracks.first?.keyDigest
                == AUHostRegistry.digest(of: key))
    }

    // MARK: - Determinism

    /// Dictionary iteration order is randomized per process; an unsorted
    /// payload would make a gate's before/after diff nondeterministic.
    @Test("track and effect entries are sorted by id, so two reads diff positionally")
    func entriesAreSorted() async {
        let registry = AUHostRegistry()
        for _ in 0..<6 {
            await registry.prepare(track: auTrack(component: Self.absent), sampleRate: 48_000)
            await registry.prepareEffect(effectID: UUID(),
                                         config: AudioUnitConfig(component: Self.absent),
                                         sampleRate: 48_000)
        }
        let stats = registry.prepareStats()
        #expect(stats.tracks.count == 6)
        #expect(stats.effects.count == 6)
        #expect(stats.tracks.map(\.trackId) == stats.tracks.map(\.trackId).sorted())
        #expect(stats.effects.map(\.effectId) == stats.effects.map(\.effectId).sorted())
    }

    // MARK: - The property the gate design rests on

    /// ⚠️ THE LOAD-BEARING TEST OF THIS ITEM. `engine.auPrepareStats` has no
    /// reset seam: every caller subtracts two reads. That only means anything
    /// if the counters SURVIVE the events a caller brackets — a device flip,
    /// a watchdog self-heal, any `rebuildEngine`/`recoverEngine` — which they
    /// do because `AudioEngine.auRegistry` is a `let` while the `AVAudioEngine`
    /// and the `PlaybackGraph` are replaced around it.
    ///
    /// The graph-identity assertion is not decoration: without it a run where
    /// the rebuild silently did NOT fire passes for entirely the wrong reason.
    @Test("the counters survive an engine rebuild — the graph object is replaced, the registry and its ledger are not")
    func countersSurviveEngineRebuild() async {
        let engine = AudioEngine()
        // Count something through the LIVE engine's registry (no instantiation:
        // the absent component lands `.missing` past the guard).
        await engine.auRegistry.prepare(track: auTrack(component: Self.absent),
                                        sampleRate: 48_000)
        let before = engine.auPrepareStats()
        #expect(before.instrumentPrepares == 1)

        // The m16-h C7c rebuild recipe: mark the graph as having run, then
        // cross a project boundary. Plain audio tracks on the far side — an AU
        // track there would spawn an async prepare that races this read.
        engine.graph.engineHasRun = true
        let graphBefore = ObjectIdentifier(engine.graph)
        engine.projectWillReplace()
        engine.tracksDidChange([Track(name: "A", kind: .audio)])

        #expect(ObjectIdentifier(engine.graph) != graphBefore,
                "the rebuild must actually have fired, or this test proves nothing")
        let after = engine.auPrepareStats()
        #expect(after.instrumentPrepares == before.instrumentPrepares)
        #expect(after.instrumentPrepares == 1)
        // The reconcile released the vanished track's slot — a BOOKKEEPING-only
        // release (nothing was ever instantiated), so the release counter is
        // still honest zero.
        #expect(after.instrumentReleases == 0)
        engine.shutdown()
    }

    @Test("there is no way to reset the counters from outside: prepareStats() is a pure read")
    func statsReadIsPure() async {
        let registry = AUHostRegistry()
        await registry.prepare(track: auTrack(component: Self.absent), sampleRate: 48_000)
        let first = registry.prepareStats()
        // NONZERO first, or this test would also pass against a `prepareStats()`
        // that reset the ledger on EVERY call — four equal reads of all-zero.
        #expect(first.instrumentPrepares == 1)
        _ = registry.prepareStats()
        _ = registry.prepareStats()
        #expect(registry.prepareStats() == first)
    }
}
