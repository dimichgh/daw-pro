import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m18-d regression stress. `kAUSamplerProperty_LoadInstrument` and
/// `AudioComponentInstanceDispose` both mutate AudioToolbox's process-GLOBAL
/// DLS/SF2 bank machinery — per-instance exclusivity does not protect it.
/// Pre-fix, a detached bank load racing a main-thread sampler dispose
/// SIGSEGV'd inside CoreAudio (11 swiftpm-testing-helper crashes,
/// 2026-07-11 → 07-16; the 07-16-100906 log shows the exact two-thread
/// interleave). The fix serializes every LoadInstrument write and every
/// sampler teardown/dispose on one utility queue (`AUHostRegistry.dlsBankQueue`).
///
/// This suite is the crash's amplifier turned regression gate: it packs
/// hundreds of load-vs-load and load-vs-dispose windows into one test and
/// passes by SURVIVING (a regression kills the whole test process — there is
/// no softer signal), plus `.ready` assertions to prove the serialized loads
/// still land.
@MainActor
@Suite("AUSampler bank-load vs dispose serialization stress (m18-d)")
struct AUSamplerBankConcurrencyStressTests {
    private func bankTrack(program: Int, bankMSB: Int = 121) -> Track {
        Track(name: "Stress", kind: .instrument,
              instrument: InstrumentDescriptor(
                  kind: .soundBank,
                  soundBank: SoundBankConfig(source: .generalMIDI, program: program,
                                             bankMSB: bankMSB)))
    }

    /// Disposes the victim's live sampler while other loads are in flight —
    /// the main thread runs AudioComponentInstanceDispose (closing the bank
    /// file) in the middle of the loads: the 07-16 crash interleave, on demand.
    private func disposeAfterDelay(_ registry: AUHostRegistry, _ trackID: UUID) async {
        try? await Task.sleep(for: .milliseconds(5))
        registry.releaseInstrument(forTrack: trackID)
    }

    /// Churn: load → immediately dispose, repeatedly, overlapping whatever
    /// the other concurrent tasks are doing at that moment.
    private func churnLoadDispose(iteration: Int) async {
        for churn in 0..<3 {
            let registry = AUHostRegistry()
            let track = bankTrack(program: (iteration + churn * 13) % 128,
                                  bankMSB: churn == 2 ? 120 : 121)
            await registry.prepare(track: track, sampleRate: 48_000)
            registry.releaseInstrument(forTrack: track.id)
        }
    }

    @Test("concurrent bank loads race sampler disposes without faulting")
    func loadsRaceDisposes() async throws {
        for iteration in 0..<12 {
            // A pre-loaded "victim" sampler, disposed mid-flight below.
            let victim = AUHostRegistry()
            let victimTrack = bankTrack(program: 0)
            await victim.prepare(track: victimTrack, sampleRate: 48_000)

            // Three concurrent prepares: each suspends the main actor at its
            // off-actor bank load, so the loads themselves overlap in time.
            let holders = (0..<3).map { _ in AUHostRegistry() }
            let tracks = (0..<3).map { bankTrack(program: (iteration * 7 + $0 * 11) % 128) }
            async let load0: Void = holders[0].prepare(track: tracks[0], sampleRate: 48_000)
            async let load1: Void = holders[1].prepare(track: tracks[1], sampleRate: 48_000)
            async let load2: Void = holders[2].prepare(track: tracks[2], sampleRate: 48_000)
            async let dispose: Void = disposeAfterDelay(victim, victimTrack.id)
            async let churn: Void = churnLoadDispose(iteration: iteration)
            _ = await (load0, load1, load2, dispose, churn)

            // Serialized or not, every surviving load must actually be ready —
            // the fix must not drop or deadlock loads, only order them.
            for (registry, track) in zip(holders, tracks) {
                #expect(registry.status[track.id] == .ready)
            }
            // `holders` dies here: three live samplers dispose via registry
            // deinit (the crash log's thread-0 stack) right before the next
            // iteration starts loading again.
        }
    }
}
