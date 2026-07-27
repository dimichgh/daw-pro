import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// T11 (design-m22g-reference-tracks §9): headless coverage for the REFERENCE
/// panel's state machine, its plain-language derivations, the mix-spectrum
/// average, and the shared spectrum geometry — everything the panel and the
/// master strip's REFERENCE row print or draw, proven without a running app
/// (the `StereoScopeModel` / `GainReductionMeterModel` precedent).
@MainActor
@Suite("Reference panel model + spectrum geometry (m22-g P3)")
struct ReferencePanelModelTests {

    // MARK: - Fixtures

    private func slot(name: String = "Reference Song",
                      path: String = "/tmp/ref.wav",
                      offset: Double = 0,
                      trim: Double = 0,
                      analyzed: Bool = true) -> ReferenceSlot {
        ReferenceSlot(name: name, sourcePath: path, offsetSeconds: offset,
                      trimDb: trim,
                      analysis: analyzed ? ReferenceSeed.sampleAnalysis() : nil)
    }

    /// A model wired to mutable boxes so a test can drive reads and observe writes.
    private final class Harness {
        var slot: ReferenceSlot?
        var status = ReferenceStatus()
        var compare: ReferenceCompareResult?
        var exists = true
        var importCalls: [String] = []
        var monitorCalls: [Bool] = []
        var offsetCalls: [Double] = []
        var trimCalls: [Double] = []
        var removeCalls = 0
        var analyzeCalls = 0
        var importError: (any Error)?
        var monitorError: (any Error)?
        var removeError: (any Error)?
        var analyzeError: (any Error)?
    }

    private func makeModel(_ h: Harness) -> ReferencePanelModel {
        ReferencePanelModel(
            slotProvider: { h.slot },
            statusProvider: { h.status },
            compareProvider: { h.compare },
            fileExists: { _ in h.exists },
            importAction: { path in
                h.importCalls.append(path)
                if let error = h.importError { throw error }
            },
            analyzeAction: {
                h.analyzeCalls += 1
                if let error = h.analyzeError { throw error }
            },
            removeAction: {
                h.removeCalls += 1
                if let error = h.removeError { throw error }
            },
            monitorAction: { on in
                h.monitorCalls.append(on)
                if let error = h.monitorError { throw error }
            },
            offsetAction: { h.offsetCalls.append($0) },
            trimAction: { h.trimCalls.append($0) })
    }

    // MARK: - State machine (§7.3)

    @Test("no slot reads EMPTY; a slot with its file on disk reads READY")
    func phaseEmptyAndReady() {
        let h = Harness()
        let model = makeModel(h)
        model.open()
        #expect(model.phase == .empty)
        h.slot = slot()
        model.refreshFileState()
        #expect(model.phase == .ready)
        #expect(model.needsAnalysis == false)
    }

    @Test("a slot whose file is gone reads FILE MISSING, slot and analysis intact")
    func phaseFileMissing() {
        let h = Harness()
        h.slot = slot()
        h.exists = false
        let model = makeModel(h)
        model.open()
        #expect(model.phase == .fileMissing)
        // The slot survives — honest absence, never a silent drop (§3.3).
        #expect(model.slot?.analysis != nil)
    }

    @Test("a slot that never analyzed reads READY but flags needsAnalysis")
    func phaseUnanalyzed() {
        let h = Harness()
        h.slot = slot(analyzed: false)
        let model = makeModel(h)
        model.open()
        #expect(model.phase == .ready)
        #expect(model.needsAnalysis)
    }

    @Test("import and analyze occupy their own busy phases and clear on finish")
    func phaseBusy() async {
        let h = Harness()
        let model = makeModel(h)
        await model.runImport(path: "/tmp/song.wav")
        #expect(h.importCalls == ["/tmp/song.wav"])
        #expect(model.busy == nil)
        #expect(model.refusal == nil)

        h.slot = slot()
        await model.runAnalyze()
        #expect(h.analyzeCalls == 1)
        #expect(model.busy == nil)
        #expect(model.phase == .ready)
    }

    @Test("open/close reset the confirmation, the refusal, and the mix average")
    func lifecycleResets() {
        let h = Harness()
        h.slot = slot()
        let model = makeModel(h)
        model.open()
        #expect(model.isOpen)
        model.confirmingRemove = true
        model.mixAverage.advance(
            toward: [Double](repeating: -30, count: ReferenceSpectrumGeometry.bandCount),
            deltaTime: 0.2)
        #expect(model.mixAverage.bandsDb != nil)
        model.close()
        #expect(model.isOpen == false)
        #expect(model.confirmingRemove == false)
        #expect(model.mixAverage.bandsDb == nil)
        model.toggleOpen()
        #expect(model.isOpen)
    }

    // MARK: - Refusals reach the user verbatim (the one-vocabulary law)

    @Test("a store refusal is surfaced WORD FOR WORD, never re-worded")
    func refusalsAreVerbatim() {
        let h = Harness()
        h.slot = slot()
        h.monitorError = ProjectError.referenceNotAnalyzed
        let model = makeModel(h)
        model.open()
        model.toggleMonitor()
        let expected = (ProjectError.referenceNotAnalyzed as any LocalizedError).errorDescription
        #expect(model.refusal != nil)
        #expect(model.refusal == expected)
        model.clearRefusal()
        #expect(model.refusal == nil)
    }

    @Test("an import failure surfaces verbatim and still clears the busy phase")
    func importRefusal() async {
        let h = Harness()
        h.importError = ProjectError.importFailed("no file at /nope.wav")
        let model = makeModel(h)
        await model.runImport(path: "/nope.wav")
        #expect(model.busy == nil)
        #expect(model.refusal?.contains("/nope.wav") == true)
    }

    // MARK: - Actions route to the store methods the wire calls

    @Test("the A/B toggle flips against the live monitor state")
    func monitorToggle() {
        let h = Harness()
        h.slot = slot()
        let model = makeModel(h)
        model.toggleMonitor()
        #expect(h.monitorCalls == [true])
        h.status = ReferenceStatus(reference: h.slot, monitoring: true,
                                   matchGainDb: -4.6, matchBasis: "liveIntegrated",
                                   ceilingLimited: false)
        model.toggleMonitor()
        #expect(h.monitorCalls == [true, false])
    }

    @Test("REMOVE arms an in-row confirmation; only the second press commits")
    func removeConfirmation() {
        let h = Harness()
        h.slot = slot()
        let model = makeModel(h)
        model.requestRemove()
        #expect(model.confirmingRemove)
        #expect(h.removeCalls == 0)
        model.cancelRemove()
        #expect(model.confirmingRemove == false)
        model.requestRemove()
        model.requestRemove()
        #expect(h.removeCalls == 1)
        #expect(model.confirmingRemove == false)
    }

    @Test("offset steps by the published grain and never accumulates float dust")
    func offsetStepping() {
        let h = Harness()
        h.slot = slot(offset: 0.2)
        let model = makeModel(h)
        model.nudgeOffset(1)
        #expect(h.offsetCalls.last == 0.3)
        h.slot = slot(offset: 0.3)
        model.nudgeOffset(-4)
        #expect(h.offsetCalls.last == -0.1)
    }

    @Test("trim steps by 0.5 and clamps to the model's ±24 range")
    func trimStepping() {
        let h = Harness()
        h.slot = slot(trim: 23.8)
        let model = makeModel(h)
        model.nudgeTrim(1)
        #expect(h.trimCalls.last == 24.0)
        model.applyTrim(-99)
        #expect(h.trimCalls.last == -24.0)
        #expect(ReferencePanelModel.trimStepDb == 0.5)
        #expect(ReferencePanelModel.offsetStepSeconds == 0.1)
    }

    // MARK: - Readout formatting (nil-tolerant)

    @Test("match gain reads signed with a dash when there is nothing to show")
    func matchGainFormatting() {
        #expect(ReferencePanelModel.matchGainText(-6.24) == "-6.2")
        #expect(ReferencePanelModel.matchGainText(3.0) == "+3.0")
        #expect(ReferencePanelModel.matchGainText(0) == "0.0")
        #expect(ReferencePanelModel.matchGainText(-0.01) == "0.0")   // no "-0.0"
        #expect(ReferencePanelModel.matchGainText(nil) == "–")
        #expect(ReferencePanelModel.matchGainText(.nan) == "–")
    }

    @Test("the displayed match gain is the live one while monitoring, else the preview")
    func displayedMatchGain() {
        let previewing = ReferenceStatus(monitoring: false, wouldMatchGainDb: -5.5)
        #expect(ReferencePanelModel.displayedMatchGainDb(previewing) == -5.5)
        let monitoring = ReferenceStatus(monitoring: true, wouldMatchGainDb: -5.5,
                                         matchGainDb: -4.0, matchBasis: "liveIntegrated")
        #expect(ReferencePanelModel.displayedMatchGainDb(monitoring) == -4.0)
    }

    @Test("the basis line speaks plain language for every case, clamp first")
    func basisLines() {
        let live = ReferenceStatus(monitoring: true, matchGainDb: -4,
                                   matchBasis: "liveIntegrated", ceilingLimited: false)
        #expect(ReferencePanelModel.basisLine(live).hasPrefix("Matched to your mix's loudness"))

        let fallback = ReferenceStatus(monitoring: true, matchGainDb: 9.7,
                                       matchBasis: "fallbackTarget", ceilingLimited: false)
        #expect(ReferencePanelModel.basisLine(fallback).contains("No mix loudness yet"))
        #expect(ReferencePanelModel.basisLine(fallback).contains("Play your mix"))

        // The clamp outranks the basis — it is the fact that changes what you hear.
        let clamped = ReferenceStatus(monitoring: true, matchGainDb: 2.1,
                                      matchBasis: "liveIntegrated", ceilingLimited: true)
        #expect(ReferencePanelModel.basisLine(clamped).hasPrefix("Turned down to protect"))

        let idle = ReferenceStatus(monitoring: false, wouldMatchGainDb: -3)
        #expect(ReferencePanelModel.basisLine(idle).contains("Press REF"))

        let unanalyzed = ReferenceStatus(monitoring: false)
        #expect(ReferencePanelModel.basisLine(unanalyzed).contains("Analyze the reference"))
    }

    @Test("file facts read as duration and rate; an unanalyzed slot says so")
    func fileFacts() {
        let analysis = ReferenceSeed.sampleAnalysis()
        #expect(ReferencePanelModel.fileFactsLine(analysis) == "3:42 · 44.1 kHz")
        #expect(ReferencePanelModel.fileFactsLine(nil) == "Not analyzed yet")
        #expect(ReferencePanelModel.durationText(0) == "0:00")
        #expect(ReferencePanelModel.durationText(65.4) == "1:05")
        #expect(ReferencePanelModel.sampleRateText(48_000) == "48 kHz")
        #expect(ReferencePanelModel.sampleRateText(0) == "–")
    }

    @Test("offset and trim readouts are signed, zero unsigned")
    func stepperReadouts() {
        #expect(ReferencePanelModel.offsetText(0.3) == "+0.30")
        #expect(ReferencePanelModel.offsetText(-1.25) == "-1.25")
        #expect(ReferencePanelModel.offsetText(0) == "0.00")
        #expect(ReferencePanelModel.trimText(0) == "0.0")
        #expect(ReferencePanelModel.trimText(-3.25) == "-3.2" || ReferencePanelModel.trimText(-3.25) == "-3.3")
        #expect(ReferencePanelModel.trimText(2.5) == "+2.5")
    }

    // MARK: - Delta row (§7.2 point 7)

    @Test("delta cells carry the design's five labels in order")
    func deltaCellLabels() {
        let cells = ReferencePanelModel.deltaCells(nil)
        #expect(cells.map(\.label) == ["Δ LUFS", "Δ TRUE PEAK", "Δ LRA", "Δ WIDTH", "Δ CORR"])
        // No evidence → every cell reads the honest em-dash, never a floored 0.
        #expect(cells.allSatisfy { $0.text == "—" })
    }

    @Test("a partially-evidenced delta shows numbers and dashes side by side")
    func deltaCellsNilTolerant() {
        let delta = ReferenceCompareResult.Delta(
            lufs: 2.14, truePeakDb: nil, lra: -0.96, width: -0.183, correlation: 0.205)
        let cells = ReferencePanelModel.deltaCells(delta)
        #expect(cells[0].text == "+2.1")
        #expect(cells[1].text == "—")
        #expect(cells[2].text == "-1.0")
        #expect(cells[3].text == "-0.18")
        #expect(cells[4].text == "+0.21")
    }

    @Test("the beginner caption names the direction, and stays silent without evidence")
    func deltaCaption() {
        // delta = reference − mix, so a POSITIVE lufs delta means the mix is quieter.
        let quieter = ReferenceCompareResult.Delta(lufs: 2.14)
        #expect(ReferencePanelModel.deltaCaption(quieter)
                == "Your mix is 2.1 loudness units quieter than the reference.")
        let louder = ReferenceCompareResult.Delta(lufs: -1.5)
        #expect(ReferencePanelModel.deltaCaption(louder)?.contains("louder than") == true)
        let level = ReferenceCompareResult.Delta(lufs: 0.02)
        #expect(ReferencePanelModel.deltaCaption(level)?.contains("same loudness") == true)
        #expect(ReferencePanelModel.deltaCaption(nil) == nil)
        #expect(ReferencePanelModel.deltaCaption(ReferenceCompareResult.Delta()) == nil)
    }

    // MARK: - Spectrum geometry

    @Test("the log axis spans the analyzer's own 40 Hz-16 kHz band range")
    func spectrumAxis() {
        let width = 400.0
        #expect(ReferenceSpectrumGeometry.x(forFrequency: 40, in: width) == 0)
        #expect(abs(ReferenceSpectrumGeometry.x(forFrequency: 16_000, in: width) - width) < 1e-9)
        // Log axis: the geometric mean of the endpoints sits at the midpoint.
        let mid = (40.0 * 16_000.0).squareRoot()
        #expect(abs(ReferenceSpectrumGeometry.x(forFrequency: mid, in: width) - width / 2) < 1e-9)
        // Off-axis probes clamp instead of running off the plot.
        #expect(ReferenceSpectrumGeometry.x(forFrequency: 1, in: width) == 0)
        #expect(abs(ReferenceSpectrumGeometry.x(forFrequency: 30_000, in: width) - width) < 1e-9)
    }

    @Test("band edges tile the axis and centers sit between their own edges")
    func spectrumBands() {
        #expect(ReferenceSpectrumGeometry.bandEdgeHz(0) == 40)
        #expect(abs(ReferenceSpectrumGeometry.bandEdgeHz(ReferenceSpectrumGeometry.bandCount)
                    - 16_000) < 1e-9)
        for index in 0..<ReferenceSpectrumGeometry.bandCount {
            let lo = ReferenceSpectrumGeometry.bandEdgeHz(index)
            let hi = ReferenceSpectrumGeometry.bandEdgeHz(index + 1)
            let center = ReferenceSpectrumGeometry.bandCenterHz(index)
            #expect(lo < center && center < hi)
        }
    }

    @Test("dB maps to y with the loud end at the top, clamped at both rails")
    func spectrumDbAxis() {
        let height = 180.0
        #expect(ReferenceSpectrumGeometry.y(forDb: -6, in: height) == 0)
        #expect(ReferenceSpectrumGeometry.y(forDb: -72, in: height) == height)
        #expect(ReferenceSpectrumGeometry.y(forDb: -39, in: height) == height / 2)
        #expect(ReferenceSpectrumGeometry.y(forDb: 0, in: height) == 0)          // clamps
        #expect(ReferenceSpectrumGeometry.y(forDb: -200, in: height) == height)  // clamps
    }

    @Test("a curve spans the true band edges; a wrong-count curve draws NOTHING")
    func spectrumPolyline() {
        let bands = [Double](repeating: -30, count: ReferenceSpectrumGeometry.bandCount)
        let points = ReferenceSpectrumGeometry.polylinePoints(
            bandsDb: bands, width: 400, height: 180)
        #expect(points.count == ReferenceSpectrumGeometry.bandCount + 2)
        #expect(points.first?.x == 0)
        #expect(abs(Double(points.last?.x ?? 0) - 400) < 1e-9)
        // Monotone left→right — no crossing points to fold the fill.
        for i in 1..<points.count {
            #expect(points[i].x >= points[i - 1].x)
        }
        // Honest absence: a sanitized/foreign band count is refused outright.
        #expect(ReferenceSpectrumGeometry.polylinePoints(
            bandsDb: [-30, -40], width: 400, height: 180).isEmpty)
        #expect(ReferenceSpectrumGeometry.polylinePoints(
            bandsDb: bands, width: 0, height: 180).isEmpty)
    }

    @Test("grid labels read for a beginner — no scientific notation")
    func spectrumGridLabels() {
        #expect(ReferenceSpectrumGeometry.frequencyLabel(50) == "50")
        #expect(ReferenceSpectrumGeometry.frequencyLabel(1_000) == "1k")
        #expect(ReferenceSpectrumGeometry.frequencyLabel(10_000) == "10k")
        for hz in ReferenceSpectrumGeometry.frequencyGridHz {
            #expect(hz > ReferenceSpectrumGeometry.lowestBandHz)
            #expect(hz < ReferenceSpectrumGeometry.highestBandHz)
        }
    }

    // MARK: - The mix average (the label promises an average, so it must be one)

    @Test("the first frame seeds exactly, then the average eases toward new targets")
    func averageSeedsThenEases() {
        let average = ReferenceSpectrumAverage()
        #expect(average.bandsDb == nil)
        let start = [Double](repeating: -40, count: ReferenceSpectrumGeometry.bandCount)
        average.advance(toward: start, deltaTime: 0.2)
        #expect(average.bandsDb == start)   // exact seed, no ramp from a fake floor

        let target = [Double](repeating: -20, count: ReferenceSpectrumGeometry.bandCount)
        average.advance(toward: target, deltaTime: 0.2)
        let afterOne = try! #require(average.bandsDb)[0]
        // One 0.2 s step at tau 2.5 s moves ~7.7 % of the way — a real average,
        // not a snapshot wearing an average's label.
        #expect(afterOne > -40 && afterOne < -38)

        // Many steps converge; ~5 tau lands within 1 % of the target.
        for _ in 0..<Int(5 * ReferenceSpectrumAverage.tau / 0.2) {
            average.advance(toward: target, deltaTime: 0.2)
        }
        #expect(abs(try! #require(average.bandsDb)[0] - (-20)) < 0.25)
    }

    @Test("a missing or malformed poll never decays the average, and reset re-seeds")
    func averageIgnoresBadFrames() {
        let average = ReferenceSpectrumAverage()
        let start = [Double](repeating: -35, count: ReferenceSpectrumGeometry.bandCount)
        average.advance(toward: start, deltaTime: 0.2)
        average.advance(toward: [], deltaTime: 0.2)
        average.advance(toward: [-1, -2, -3], deltaTime: 0.2)
        #expect(average.bandsDb == start)
        // A non-positive dt is a no-op (a stalled frame must not move it).
        average.advance(toward: [Double](repeating: 0, count: ReferenceSpectrumGeometry.bandCount),
                        deltaTime: 0)
        #expect(average.bandsDb == start)
        average.reset()
        #expect(average.bandsDb == nil)
    }

    @Test("a long gap is clamped so one stalled frame can't snap the average")
    func averageClampsLongSteps() {
        let a = ReferenceSpectrumAverage()
        let b = ReferenceSpectrumAverage()
        let start = [Double](repeating: -60, count: ReferenceSpectrumGeometry.bandCount)
        let target = [Double](repeating: -10, count: ReferenceSpectrumGeometry.bandCount)
        a.advance(toward: start, deltaTime: 0.2)
        b.advance(toward: start, deltaTime: 0.2)
        a.advance(toward: target, deltaTime: ReferenceSpectrumAverage.maxStepSeconds)
        b.advance(toward: target, deltaTime: 30)
        #expect(a.bandsDb == b.bandsDb)
    }

    @Test("the panel's spectrum frame hands back both curves, mix side averaged")
    func advanceSpectrumFeedsBothCurves() {
        let h = Harness()
        h.slot = slot()
        let analysis = ReferenceSeed.sampleAnalysis()
        let mixBands = ReferenceSeed.sampleMixAnalysis().bands.map { Double($0) }
        h.compare = ReferenceCompareResult(
            mix: ReferenceCompareResult.MixSide(bandsDb: mixBands),
            reference: analysis,
            delta: ReferenceCompareResult.Delta())
        let model = makeModel(h)
        model.open()
        let first = model.advanceSpectrum(deltaTime: 1.0 / 5)
        #expect(first.reference == analysis.bandsDb)
        #expect(first.mix == mixBands)          // exact seed on frame one

        // With no compare evidence the reference still draws from the slot and
        // the mix side holds its last average rather than collapsing to a floor.
        h.compare = nil
        let second = model.advanceSpectrum(deltaTime: 1.0 / 5)
        #expect(second.reference == analysis.bandsDb)
        #expect(second.mix == mixBands)
    }

    // MARK: - Seed determinism (captures must be bit-identical run to run)

    @Test("the capture seed's sample curves are deterministic and well-formed")
    func seedSamplesAreDeterministic() {
        let a = ReferenceSeed.sampleAnalysis()
        let b = ReferenceSeed.sampleAnalysis()
        #expect(a == b)
        #expect(a.bandsDb.count == MasterAnalysisSnapshot.bandCount)
        #expect(ReferenceSeed.sampleMixAnalysis().bands.count == MasterAnalysisSnapshot.bandCount)
        // The mix sample sits below the reference at every band (the seeded
        // capture must show two visibly distinct curves).
        let mix = ReferenceSeed.sampleMixAnalysis().bands.map { Double($0) }
        for (index, value) in mix.enumerated() {
            #expect(value < a.bandsDb[index])
        }
    }
}
