import Testing
import CoreGraphics
@testable import DAWAppKit

/// m23-a: the mixer channel strip's vertical budget. These pin the ONE property
/// the regression violated — the reserved cluster (header · knobs · fader · dB ·
/// Mute/Solo/Arm) always fits, at every insert count and down to the measured
/// window-height floor — so a future block added to the strip fails here instead
/// of silently clipping the Arm row again.
@Suite("MixerStripLayout (m23-a)")
struct MixerStripLayoutTests {

    @Test("the reserved cluster fits inside the strip height at the window floor")
    func reservedClusterFitsAtWindowFloor() {
        let floor = MixerStripLayout.stripHeightAtWindowFloor
        #expect(MixerStripLayout.fitsReservedChrome(available: floor))
        // …and with real margin, not by a hair: the whole point is that the
        // signal-flow region still has usable room at the smallest window.
        #expect(MixerStripLayout.reservedMinimumHeight <= floor - 80,
                "reserved cluster \(MixerStripLayout.reservedMinimumHeight) leaves too little for the inserts at the \(floor) pt floor")
    }

    @Test("the inserts region keeps usable room even at the window floor")
    func signalFlowHasRoomAtWindowFloor() {
        // ≥ 88 pt ≈ the section label + two insert rows: at the smallest window the
        // app allows, the chain is still visible and scrollable — never zero.
        #expect(MixerStripLayout.signalFlowRoomAtWindowFloor >= 88,
                "signal-flow room at the window floor collapsed to \(MixerStripLayout.signalFlowRoomAtWindowFloor)")
    }

    @Test("a maximal chain still fits WITHOUT scrolling at the default window")
    func maximalChainFitsAtTheDefaultWindow() {
        // The property the first m23-a cut got wrong: the reserved cluster fitted,
        // but it had grown enough that an ordinary full chain (8 inserts + a send +
        // the output picker) no longer fitted at 1440×900 — the OUTPUT row was cut
        // mid-button by the scroll fold at the app's DEFAULT window. Any future
        // block added to the reserved cluster has to answer to this.
        let room = MixerStripLayout.signalFlowRoom(
            available: MixerStripLayout.stripHeightAtDefaultWindow)
        #expect(room >= MixerStripLayout.maximalChainNaturalHeight,
                "at the default window the inserts region has \(room) pt but a maximal chain needs \(MixerStripLayout.maximalChainNaturalHeight)")
    }

    @Test("signal-flow room + the reserved floor never exceed the strip")
    func roomNeverOverflowsTheStrip() {
        // The invariant that makes clipping structurally impossible: whatever the
        // strip height, the region's room plus the reserved cluster's floor fits.
        for available in stride(from: CGFloat(200), through: 1400, by: 25) {
            let room = MixerStripLayout.signalFlowRoom(available: available)
            let total = room + MixerStripLayout.reservedMinimumHeightWithSignalFlow
            let reserved = MixerStripLayout.reservedMinimumHeightWithSignalFlow
            #expect(total <= available + 0.001 || room == 0,
                    "at available \(available): room \(room) + reserved \(reserved) > \(available)")
        }
    }

    @Test("room is never negative and never exceeds its share of the strip")
    func roomIsClamped() {
        #expect(MixerStripLayout.signalFlowRoom(available: 0) == 0)
        #expect(MixerStripLayout.signalFlowRoom(available: 100) == 0)   // below the floor
        #expect(MixerStripLayout.signalFlowRoom(available: -50) == 0)
        for available in stride(from: CGFloat(200), through: 2000, by: 50) {
            let room = MixerStripLayout.signalFlowRoom(available: available)
            #expect(room >= 0)
            #expect(room <= available * MixerStripLayout.signalFlowMaxFraction + 0.001,
                    "at available \(available) the region claimed \(room), past its share")
        }
    }

    @Test("room grows with the strip — a taller window shows more of the chain")
    func roomIsMonotonic() {
        var previous = MixerStripLayout.signalFlowRoom(available: 200)
        for available in stride(from: CGFloat(225), through: 2000, by: 25) {
            let room = MixerStripLayout.signalFlowRoom(available: available)
            #expect(room >= previous - 0.001,
                    "room shrank from \(previous) to \(room) at available \(available)")
            previous = room
        }
    }

    @Test("the fader floor is a valve, not the target — well under a comfortable fader")
    func faderFloorIsAValve() {
        // The pre-m23-a hard minimum was 150; the floor must sit clearly below it,
        // so the fader compresses before any reserved element is lost.
        #expect(MixerStripLayout.faderRegionFloor < 150)
        // …but still tall enough to be a usable fader + its dB readout.
        #expect(MixerStripLayout.faderRegionFloor >= 100)
    }

    /// What the fader is left with when the chain is long enough to claim the whole
    /// bound (the worst case — a chain that fits just hugs, and the surplus flows
    /// to the fader anyway).
    private func faderHeightUnderACapFillingChain(available: CGFloat) -> CGFloat {
        available - MixerStripLayout.reservedMinimumHeightWithSignalFlow
            + MixerStripLayout.faderRegionFloor
            - MixerStripLayout.signalFlowRoom(available: available)
    }

    @Test("a cap-filling chain never pushes the fader below its floor, at any height")
    func capFillingChainNeverBreachesTheFaderFloor() {
        for available in stride(from: CGFloat(200), through: 2000, by: 25) {
            let fader = faderHeightUnderACapFillingChain(available: available)
            #expect(fader >= MixerStripLayout.faderRegionFloor - 0.001
                        || available < MixerStripLayout.reservedMinimumHeightWithSignalFlow,
                    "at \(available) pt a cap-filling chain left the fader \(fader)")
        }
    }

    @Test("on a tall window the share cap gives the fader back a long throw")
    func tallWindowRestoresALongFader() {
        // Below ~800 pt the leftover bound governs and the fader sits at its floor
        // (correct — at a short window the reserved cluster is the promise, not a
        // long throw). Past that the `signalFlowMaxFraction` share takes over and
        // the fader grows with the window, which is what the share exists for.
        for available in stride(from: CGFloat(1000), through: 2000, by: 50) {
            let fader = faderHeightUnderACapFillingChain(available: available)
            #expect(fader >= 200,
                    "at \(available) pt a cap-filling chain left the fader only \(fader)")
        }
        #expect(faderHeightUnderACapFillingChain(available: 2000)
                > faderHeightUnderACapFillingChain(available: 1000),
                "the fader's share must grow with the window")
    }
}
