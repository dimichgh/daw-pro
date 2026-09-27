import AppKit
import CoreGraphics
import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// W7-NTU U1 — the pitch editor's header group "Sound like the singer"
/// (natural tuning X9, §1(f), §2f, §4.f, R16, R26): what each row DRAWS
/// (`PitchEditorSingerGroup.resolve`), every word of it (`PitchEditorFormantCopy`,
/// pinned BY VALUE — the state-line law), the metrics the view draws with,
/// measured with the real fonts (`PitchEditorSingerLayout`), where the group
/// sits in the header, the app funnel's READ-BACK predicates
/// (`PitchEditorSingerWrite`), and the wiring, read off the source.
///
/// ⚠️ NOT `@MainActor`: every subject is a pure value, a nonisolated
/// predicate or source text, and an isolated suite would spend one of the
/// review-cadence slots `MainActorOccupancySiteTests` bounds. The gestures and
/// the store writes run in `PitchEditorModelTests` (the W7-NTU extension).
@Suite("PitchEditorSingerGroup — the header group \"Sound like the singer\": faces, words, metrics, placement, read-backs (W7-NTU U1)")
struct PitchEditorSingerGroupTests {
    typealias C = PitchEditorFormantCopy
    typealias L = PitchEditorSingerLayout
    typealias Group = PitchEditorSingerGroup

    // MARK: - Fixtures

    /// A vocal tuned BEFORE natural tuning: the played-line fixture's three
    /// notes (B's wobble flattened, C given a made one), stored with no voice
    /// size, consonants off by default and no slide smoothness (R16's legacy).
    ///
    /// ⚠️ A `let`, built ONCE: the fixture mints its note ids per call, and
    /// the read-back legs compare whole sets, so two calls would be two vocals.
    static let legacy: PitchEditSet = PitchEditorPlayedLineTests.fixture(shift: 0).set
    /// The same notes after the update (`upgradedToNaturalTuning`, X4's one
    /// path): the new-set seed's voice size, consonants on, Smooth slides.
    static let fresh: PitchEditSet = legacy.upgradedToNaturalTuning()

    /// `fresh`'s notes with the three set-level fields spelled out.
    static func set(formant: Double?, consonants: Bool, slope: Double) -> PitchEditSet {
        PitchEditSet(segments: legacy.segments, formantCorrection: formant,
                     keepsConsonantsUntuned: consonants, transitionSlopeCentsPerSecond: slope)
    }

    static func resolve(_ table: PitchEditSet, stretch: Double = 1, semitones: Double = 0,
                        draft: Double? = nil) -> Group {
        Group.resolve(table: table, stretchRatio: stretch, clipSemitones: semitones, voiceDraft: draft)
    }

    @Test("the fixtures are what they claim: the legacy vocal predates natural tuning, the updated one does not")
    func fixturesAreWhatTheyClaim() {
        #expect(Self.legacy.predatesNaturalTuning)
        #expect(Self.legacy.formantCorrection == nil)
        #expect(!Self.legacy.keepsConsonantsUntuned)
        #expect(Self.legacy.transitionSlopeCentsPerSecond == 0)
        #expect(!Self.fresh.predatesNaturalTuning)
        #expect(Self.fresh.formantCorrection == PitchEditSet.newSetFormantCorrection)
        #expect(Self.fresh.keepsConsonantsUntuned)
        #expect(Self.fresh.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
        #expect(Self.fresh.segments == Self.legacy.segments)
    }

    // MARK: - The faces

    @Test("a vocal tuned with this update: 100% voice size, consonants ON, Smooth lit, and each row's novice line")
    func freshVocalFaces() {
        let group = Self.resolve(Self.fresh)
        #expect(group.title == "SOUND LIKE THE SINGER")
        #expect(group.voice == Group.VoiceRow(amount: 1, readout: "100%", needsUpdate: false,
                                              isDragging: false, line: C.voiceLine, help: C.voiceHelp))
        #expect(group.consonants == Group.ConsonantsRow(isOn: true, pausedReason: nil, face: "ON",
                                                        line: C.consonantsLine, help: C.consonantsHelp))
        #expect(group.slides == Group.SlidesRow(face: .step, selected: .smooth,
                                                line: C.slidesLine, help: C.slidesHelp))
    }

    /// Planted and seen red (W7-NTU P-legacy): the voice row reading the
    /// stored amount on a legacy vocal (`amount = voiceDraft ?? formantCorrection`
    /// with no `needsUpdate` gate) — nil reads "—" either way, so the leg
    /// that catches it is the DRAFT one below: a draft on a legacy vocal must
    /// draw nothing.
    @Test("⭐ a vocal tuned before this update: the voice row is DIM with the update line (R16), no amount, no drag; Slides says who set them")
    func legacyVocalFaces() {
        let group = Self.resolve(Self.legacy)
        #expect(group.voice == Group.VoiceRow(amount: nil, readout: "—", needsUpdate: true,
                                              isDragging: false, line: C.voiceUpdateLine,
                                              help: C.voiceUpdateHelp))
        // A drag never runs there (every press is the update), so even a draft
        // handed in draws nothing: nil has no place on the track.
        let dragged = Self.resolve(Self.legacy, draft: 0.5)
        #expect(dragged.voice.amount == nil)
        #expect(!dragged.voice.isDragging)
        #expect(dragged.voice.readout == "—")
        // Consonants: off by default on a legacy set, and not "paused" — the
        // rule's reason is nil while the switch is off.
        #expect(group.consonants == Group.ConsonantsRow(isOn: false, pausedReason: nil, face: "OFF",
                                                        line: C.consonantsLine, help: C.consonantsHelp))
        #expect(group.slides == Group.SlidesRow(face: .oldTuning, selected: nil,
                                                line: C.slidesOldTuningLine, help: C.slidesHelp))
    }

    @Test("a live drag draws its own amount, whole percent, cyan; 0 reads Off (the OFF law)")
    func dragDraws() {
        let half = Self.resolve(Self.fresh, draft: 0.5)
        #expect(half.voice.amount == 0.5)
        #expect(half.voice.readout == "50%")
        #expect(half.voice.isDragging)
        #expect(half.voice.line == C.voiceLine)
        let off = Self.resolve(Self.fresh, draft: 0)
        #expect(off.voice.readout == "Off")
        #expect(off.voice.amount == 0)
        // A set someone set to 0 on purpose reads Off at rest too.
        #expect(Self.resolve(Self.set(formant: 0, consonants: true, slope: 3000)).voice.readout == "Off")
    }

    /// Planted and seen red (W7-NTU P-paused): `resolve` asking the rule about
    /// a fixed 1× and 0 semitones instead of the stretch and transpose it is
    /// handed, so the row never pauses. (That the header hands it the CLIP's
    /// own fields is `headerWiring`'s leg, P-view.)
    @Test("consonants ON but the render cannot run them: the capsule stays ON and the line says why, in the pane's words (§2f)")
    func consonantsPausedSaysWhy() {
        let stretched = Self.resolve(Self.fresh, stretch: 1.25)
        #expect(stretched.consonants.isOn)
        #expect(stretched.consonants.face == "ON")
        #expect(stretched.consonants.pausedReason == .clipStretched)
        #expect(stretched.consonants.line == "Paused while the clip plays faster or slower.")
        let transposed = Self.resolve(Self.fresh, semitones: 2)
        #expect(transposed.consonants.pausedReason == .clipTransposed)
        #expect(transposed.consonants.line == "Paused while the whole clip is shifted in pitch.")
        // Both: the rule's own order (stretch first).
        #expect(Self.resolve(Self.fresh, stretch: 0.8, semitones: -3).consonants.pausedReason == .clipStretched)
        // OFF on a stretched clip is off, not paused.
        let off = Self.resolve(Self.set(formant: 1, consonants: false, slope: 3000), stretch: 1.25)
        #expect(off.consonants.pausedReason == nil)
        #expect(off.consonants.line == C.consonantsLine)
        #expect(off.consonants.face == "OFF")
        // Every reason has its own words (a new reason would need new words).
        for reason in ConsonantMixInactiveReason.allCases {
            #expect(C.consonantsPaused(reason).hasPrefix("Paused while"))
        }
    }

    @Test("Slides: each step lights exactly itself; a custom smoothness lights none and says so; 0 is the old tuning")
    func slidesFaces() {
        for step in PitchEditorSlideStep.allCases {
            let slides = Self.resolve(Self.set(formant: 1, consonants: true, slope: step.centsPerSecond)).slides
            #expect(slides == Group.SlidesRow(face: .step, selected: step, line: C.slidesLine, help: C.slidesHelp),
                    "\(step)")
        }
        let custom = Self.resolve(Self.set(formant: 1, consonants: true, slope: 4500)).slides
        #expect(custom == Group.SlidesRow(face: .custom, selected: nil, line: C.slidesCustomLine, help: C.slidesHelp))
        // ⛔ Never the NEAREST step: 3001 is not Smooth.
        #expect(Self.resolve(Self.set(formant: 1, consonants: true, slope: 3001)).slides.selected == nil)
        let old = Self.resolve(Self.set(formant: 1, consonants: true, slope: 0)).slides
        #expect(old.face == .oldTuning)
        #expect(old.line == C.slidesOldTuningLine)
    }

    // MARK: - The steps and the slider's arithmetic

    /// Planted and seen red (W7-NTU P-snappy0): Snappy writing 0.
    @Test("⛔ the four steps: none is 0, Snappy is the ceiling, today's default is one of them, each is exactly one smoothness")
    func slideSteps() {
        let values = PitchEditorSlideStep.allCases.map(\.centsPerSecond)
        #expect(values == [20000, 6000, 3000, 1500])
        #expect(PitchEditorSlideStep.snappy.centsPerSecond == PitchEditSet.transitionSlopeRange.upperBound)
        for step in PitchEditorSlideStep.allCases {
            #expect(step.centsPerSecond > 0, "\(step) writes \(step.centsPerSecond)")
            #expect(PitchEditSet.transitionSlopeRange.contains(step.centsPerSecond), "\(step)")
            #expect(PitchEditorSlideStep.step(atCentsPerSecond: step.centsPerSecond) == step)
        }
        // TRIPWIRE: if the L2 pick moves the default off every step, a new
        // vocal would light no step and read "custom" — this fails first.
        #expect(PitchEditorSlideStep.step(atCentsPerSecond: PitchEditSet.defaultTransitionSlope) == .smooth)
        #expect(PitchEditorSlideStep.step(atCentsPerSecond: 0) == nil)
        #expect(PitchEditorSlideStep.allCases.map(\.label) == ["Snappy", "Quick", "Smooth", "Slow"])
        #expect(Set(PitchEditorSlideStep.allCases.map(\.id)).count == 4)
    }

    @Test("Keep voice size: the L1 stops are detents, the new-set seed is one; a pointer near one lands on it unless ⌥; whole percent; total")
    func voiceSizeArithmetic() {
        #expect(PitchEditorVoiceSize.detents == [0, 0.5, 0.75, 1])
        // TRIPWIRE: the seed a new vocal gets must be a stop a person can land on.
        #expect(PitchEditorVoiceSize.detents.contains(PitchEditSet.newSetFormantCorrection))
        #expect(PitchEditorVoiceSize.amount(atFraction: 0.52, fine: false) == 0.5)
        #expect(PitchEditorVoiceSize.amount(atFraction: 0.52, fine: true) == 0.52)
        #expect(PitchEditorVoiceSize.amount(atFraction: 0.98, fine: false) == 1)
        #expect(PitchEditorVoiceSize.amount(atFraction: 0.60, fine: false) == 0.6)
        #expect(abs(PitchEditorVoiceSize.amount(atFraction: 0.374, fine: true) - 0.37) < 1e-12)
        #expect(PitchEditorVoiceSize.amount(atFraction: -1, fine: false) == 0)
        #expect(PitchEditorVoiceSize.amount(atFraction: 2, fine: true) == 1)
        #expect(PitchEditorVoiceSize.amount(atFraction: .nan, fine: false) == 0)
        #expect(PitchEditorVoiceSize.amount(atFraction: .infinity, fine: false) == 0)
        // The catch is a comfortable few points on the drawn track.
        let catchPoints = Double(L.voiceTrackWidth) * PitchEditorVoiceSize.detentRadius
        #expect(catchPoints >= 4 && catchPoints <= 10, "the detent catch is \(catchPoints) pt")
    }

    /// Planted and seen red (W7-NTU P-percent): the rounding back to
    /// `(x / 0.01).rounded() * 0.01`, which misses 10 of the 101 (57 →
    /// 0.5700000000000001).
    @Test("every whole percent lands on its OWN canonical value (k / 100), never a neighbouring double")
    func everyPercentIsCanonical() {
        var off: [Int] = []
        for k in 0...100 {
            let asked = Double(k) / 100
            if PitchEditorVoiceSize.amount(atFraction: asked, fine: true) != asked { off.append(k) }
            // A pointer a hair off the percent lands on it too.
            if PitchEditorVoiceSize.amount(atFraction: asked + 0.001, fine: true) != asked { off.append(k) }
        }
        #expect(off.isEmpty, "percents that do not land on k/100: \(off)")
        #expect(PitchEditorVoiceSize.resolution == 0.01)
    }

    @Test("the readout: whole percent, Off at 0, a dash with no setting, never a number the render does not use")
    func voiceReadout() {
        #expect(C.voiceReadout(nil) == "—")
        #expect(C.voiceReadout(0) == "Off")
        #expect(C.voiceReadout(0.004) == "Off")
        #expect(C.voiceReadout(0.75) == "75%")
        #expect(C.voiceReadout(1) == "100%")
        #expect(C.voiceReadout(1.5) == "100%")
        #expect(C.voiceReadout(.nan) == "—")
        #expect(C.voiceReadout(.infinity) == "—")
    }

    // MARK: - The words

    /// Every string the group draws or tooltips, in one list, so the word
    /// rules below cannot miss one.
    static var everyString: [String] {
        var strings = [C.groupTitle, C.settingDidNotTake,
                       C.voiceLabel, C.voiceLine, C.voiceHelp, C.voiceUpdateLine, C.voiceUpdateHelp,
                       C.voiceReadoutUnset, C.voiceReadoutOff,
                       C.consonantsLabel, C.consonantsLine, C.consonantsHelp, C.switchOn, C.switchOff,
                       C.slidesLabel, C.slidesLine, C.slidesHelp, C.slidesOldTuningLine, C.slidesCustomLine]
        strings += ConsonantMixInactiveReason.allCases.map(C.consonantsPaused)
        strings += PitchEditorSlideStep.allCases.flatMap { [C.slideStepName($0), C.slideStepHelp($0)] }
        return strings
    }

    /// The state-line law: one home, pinned by value. A changed word is a
    /// changed test, on purpose.
    @Test("every word, by value (one home: PitchEditorFormantCopy)")
    func wordsByValue() {
        #expect(C.groupTitle == "SOUND LIKE THE SINGER")
        #expect(C.voiceLabel == "Keep voice size")
        #expect(C.voiceLine == "Keeps the voice its own size when notes move.")
        #expect(C.voiceUpdateLine == "Older tuning. Tap, or change a note, to update.")
        #expect(C.voiceUpdateHelp == "This vocal was tuned before the app could keep a singer's voice size, "
            + "S sounds and slides. Tap here, or change any note, and the whole vocal updates in one step. "
            + "Undo takes it back.")
        #expect(C.voiceHelp == "How much of the singer's own voice size a moved note keeps. 100% keeps all "
            + "of it. Off lets the voice follow the note, which can sound small and squeaky after a big move.")
        #expect(C.consonantsLabel == "Consonants")
        #expect(C.consonantsLine == "S, T and breaths keep their own pitch.")
        #expect(C.consonantsHelp == "When this is on, the S, T and breath sounds between notes play as you "
            + "recorded them, so they never get a robotic pitch.")
        #expect(C.switchOn == "ON" && C.switchOff == "OFF")
        #expect(C.slidesLabel == "Slides")
        #expect(C.slidesLine == "How gently a moved note slides into the next.")
        #expect(C.slidesHelp == "How gently a moved note glides into the next one. After a big move, a "
            + "smoother slide sounds more like real singing.")
        #expect(C.slidesOldTuningLine == "Set by the old tuning. Pick one to take over.")
        #expect(C.slidesCustomLine == "Set to a custom smoothness. Pick one to change it.")
        #expect(C.slideStepHelp(.snappy) == "The fastest slide: a moved note jumps into the next one.")
        #expect(C.slideStepHelp(.quick) == "A short slide into the next note.")
        #expect(C.slideStepHelp(.smooth) == "A soft slide that grows with the size of the jump.")
        #expect(C.slideStepHelp(.slow) == "A long, soft slide into the next note.")
        #expect(C.settingDidNotTake
                == "That change did not stick. The vocal is as it was, and nothing else was altered. Try again.")
    }

    @Test("⛔ the word rules: no \"natural\" anywhere (X9), no jargon, no taken step names (R26)")
    func wordRules() {
        for string in Self.everyString {
            let lower = string.lowercased()
            #expect(!lower.contains("natural"), "\"\(string)\" says natural (X9)")
            for jargon in ["formant", "cents", "vibrato"] {
                #expect(!lower.contains(jargon), "\"\(string)\" says \(jargon)")
            }
        }
        for step in PitchEditorSlideStep.allCases {
            #expect(!["Gentle", "Sharp", "Natural", "Tight"].contains(C.slideStepName(step)))
            #expect(!C.slideStepHelp(step).lowercased().contains("gentle"), "\(step)'s tooltip says gentle")
        }
    }

    /// Planted and seen red (W7-NTU P-line): R26's pre-ruling string "Tuned
    /// before this update. Tap to update." — true to the letter, but silent
    /// about the note change that ALSO updates under the user's ruling (b).
    @Test("⭐ the update line: ≤ 51 characters (the dim law) and it says BOTH ways the vocal updates (ruling D4-1 (b))")
    func updateLineBudgetAndTruth() {
        #expect(C.voiceUpdateLine.count <= 51, "\(C.voiceUpdateLine.count) characters")
        // A closure, not `\.isASCII`: `#expect` decomposes the call, and a key
        // path handed to the rethrowing `allSatisfy` there does not compile.
        let ascii = C.voiceUpdateLine.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii, "count ≠ wc -m for a non-ASCII line")
        #expect(C.voiceUpdateLine.contains("Tap"))
        #expect(C.voiceUpdateLine.contains("change a note"))
        #expect(C.voiceUpdateHelp.contains("Undo"))
    }

    // MARK: - The metrics, measured with the real fonts

    static func width(_ string: String, _ font: NSFont, tracking: CGFloat = 0) -> CGFloat {
        let base = (string as NSString).size(withAttributes: [.font: font]).width
        return ceil(base + tracking * CGFloat(string.count))
    }

    @Test("every label, line and readout fits its slot on ONE line, measured with the view's fonts")
    func everythingFitsItsSlot() {
        let label = NSFont.systemFont(ofSize: L.labelFontSize, weight: .medium)
        for text in [C.voiceLabel, C.consonantsLabel, C.slidesLabel] {
            #expect(Self.width(text, label) <= L.labelWidth, "\"\(text)\" is \(Self.width(text, label)) pt")
        }
        let line = NSFont.systemFont(ofSize: L.lineFontSize)
        var lines = [C.voiceLine, C.voiceUpdateLine, C.consonantsLine, C.slidesLine,
                     C.slidesOldTuningLine, C.slidesCustomLine]
        lines += ConsonantMixInactiveReason.allCases.map(C.consonantsPaused)
        for text in lines {
            // A 4 pt margin: SwiftUI's line and this measure are not the same
            // layout engine.
            #expect(Self.width(text, line) <= L.groupWidth - 4, "\"\(text)\" is \(Self.width(text, line)) pt")
        }
        let readout = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        for text in ["100%", "Off", "—", "55%"] {
            #expect(Self.width(text, readout) <= L.readoutWidth, "\"\(text)\" is \(Self.width(text, readout)) pt")
        }
        let step = NSFont.systemFont(ofSize: L.stepFontSize, weight: .semibold)
        let chips = PitchEditorSlideStep.allCases
            .map { Self.width($0.label, step) + 2 * L.stepHorizontalPadding }
            .reduce(0, +) + 3 * L.stepSpacing
        #expect(chips <= L.groupWidth - L.labelWidth - L.labelGap, "the four steps need \(chips) pt")
        // Heights: one line of each font fits its fixed slot.
        let manager = NSLayoutManager()
        #expect(manager.defaultLineHeight(for: line) <= L.lineHeight)
        #expect(manager.defaultLineHeight(for: label) <= L.controlHeight)
        #expect(manager.defaultLineHeight(for: step) <= L.controlHeight)
    }

    @Test("the group's height is 108 pt, and the preset column beside it at its narrowest is never taller")
    func groupHeightAndTheNarrowestPresetColumn() {
        #expect(L.groupHeight == 108)
        // The narrowest column the chips yield to (`presetsMinWidth`), each
        // summary wrapped with TextKit at 9 pt: the column is the caption row,
        // its gap, a chip (10 pt semibold, 5 pt padding each side) and the
        // summary — all under the group's height, so yielding width costs no
        // height the group has not already spent.
        let column = (L.presetsMinWidth - 3 * 10) / 4
        let summary = NSFont.systemFont(ofSize: 9)
        let chipText = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let manager = NSLayoutManager()
        for preset in PitchCorrectionPreset.offeredInUI {
            #expect(Self.width(preset.displayName, chipText) <= column - 12, "\(preset.displayName)")
            let lines = Self.lineCount(preset.summary, font: summary, width: column)
            let height = 18 + 5 + (manager.defaultLineHeight(for: chipText) + 10) + 3
                + CGFloat(lines) * manager.defaultLineHeight(for: summary)
            #expect(height <= L.groupHeight, "\(preset.displayName): \(lines) lines, \(height) pt")
        }
    }

    /// TextKit's line count for `text` at `width` (no padding).
    static func lineCount(_ text: String, font: NSFont, width: CGFloat) -> Int {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var count = 0
        var index = 0
        while index < manager.numberOfGlyphs {
            var range = NSRange()
            manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            count += 1
            index = NSMaxRange(range)
        }
        return count
    }

    // MARK: - Where the group sits

    /// Planted and seen red (W7-NTU P-fit): `fit` dropping the group BELOW
    /// whenever the chips cannot keep their full 790.
    @Test("⭐ beside the chips at the 1208 pt floor (chips untouched), still beside with the Copilot rail open (chips yield), below only under 746 pt")
    func placementRule() {
        #expect(L.presetsWidth == 790)
        #expect(L.besideMinWidth == 746)
        // The floor: WindowFloor's pane, less the header's 12 pt padding each side.
        let floorHeader = WindowFloor.minWidth - WindowFloor.outerHorizontalPadding - 2 * 12
        #expect(floorHeader == 1160)
        #expect(L.fit(headerContentWidth: floorHeader) == L.Fit(placement: .beside, presetsWidth: 790))
        // The Copilot rail (360 pt + a 10 pt gap) at the floor: 790 pt of header.
        #expect(L.fit(headerContentWidth: floorHeader - 370) == L.Fit(placement: .beside, presetsWidth: 434))
        #expect(L.fit(headerContentWidth: 746) == L.Fit(placement: .beside, presetsWidth: 390))
        #expect(L.fit(headerContentWidth: 745.5).placement == .below)
        #expect(L.fit(headerContentWidth: 2000) == L.Fit(placement: .beside, presetsWidth: 790))
        #expect(L.fit(headerContentWidth: .infinity) == L.Fit(placement: .beside, presetsWidth: 790))
        #expect(L.fit(headerContentWidth: .nan).placement == .below)
        // Beside, the group ends inside the header at the floor.
        #expect(790 + L.gapBeforeGroup + L.groupWidth <= floorHeader)
    }

    // MARK: - The funnel's read-backs (never the setter's return)

    /// The predicates `PitchEditorSingerWrite` reads the store back with, each
    /// shown able to say NO (a read-back that cannot fail proves nothing).
    ///
    /// Planted and seen red (W7-NTU P-readback): `tookVoiceSize` accepting
    /// any stored amount (`stored.formantCorrection != nil`).
    @Test("the read-backs say yes to the value asked for and NO to a stale, wrong or missing one")
    func readBacks() {
        typealias W = PitchEditorSingerWrite
        let half = Self.set(formant: 0.5, consonants: true, slope: 3000)
        #expect(W.tookVoiceSize(0.5, stored: half))
        #expect(!W.tookVoiceSize(0.5, stored: Self.fresh))                 // still 1.0
        #expect(!W.tookVoiceSize(0.5, stored: nil))
        #expect(!W.tookVoiceSize(.nan, stored: half))
        #expect(W.tookVoiceSize(1.5, stored: Self.fresh))                  // clamped to 1
        #expect(!W.tookVoiceSize(0.5, stored: Self.legacy))                 // nil amount

        #expect(W.tookUpdate(before: Self.legacy, stored: Self.fresh))
        #expect(!W.tookUpdate(before: Self.legacy, stored: Self.legacy))     // nothing happened
        #expect(!W.tookUpdate(before: Self.legacy, stored: nil))
        var moved = Self.fresh
        moved.segments[0].pitchOffsetCents += 100
        #expect(!W.tookUpdate(before: Self.legacy, stored: moved))           // a note moved too
        #expect(!W.tookUpdate(before: Self.legacy,
                              stored: Self.set(formant: 1, consonants: true, slope: 1500)))

        #expect(W.tookSlides(1500, stored: Self.set(formant: 1, consonants: true, slope: 1500)))
        #expect(!W.tookSlides(1500, stored: Self.fresh))                     // still 3000
        #expect(!W.tookSlides(0, stored: Self.legacy))                       // 0 is never a setting
        #expect(!W.tookSlides(.nan, stored: Self.fresh))
        #expect(W.tookSlides(25000, stored: Self.set(formant: 1, consonants: true, slope: 20000)))
        #expect(!W.tookSlides(3000, stored: nil))
    }

    // MARK: - The wiring, read off the source

    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    /// Comment-stripped source (`PitchEditorInteractionSiteTests`' reader).
    private static func code(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// Planted and seen red (W7-NTU P-arm): the funnel's arm trusting the
    /// setter (no `PitchEditorSingerWrite` read-back, no refusal).
    @Test("the app's funnel writes the group through PitchEditorSingerWrite and REFUSES in words when the read-back fails")
    func funnelArmReadsBack() {
        let staging = Self.code("DAWApp/PitchCorrectionStaging.swift")
        #expect(staging.contains("case .voiceSize, .naturalTuningUpdate, .consonants, .slideSmoothness:"))
        #expect(staging.contains("try PitchEditorSingerWrite.commit(commit.kind, clipID: clipID,"))
        #expect(staging.contains("presentArrangeSplitRefusal(PitchSettingDidNotTake(), clipID: clipID)"))
        #expect(staging.contains("PitchEditorFormantCopy.settingDidNotTake"))
        let write = Self.code("DAWAppKit/PitchEditorSingerWrite.swift")
        // Each store call's RETURN is discarded, and each verdict reads the
        // clip back from the store: four doors, four discards, four read-backs.
        #expect(write.components(separatedBy: "_ = try store.").count - 1 == 4,
                "a store call's return is kept (a setter's return is not a read-back)")
        #expect(write.components(separatedBy: "storedTable(clipID, in: store)").count - 1 >= 4)
        for door in ["setClipFormantCorrection", "upgradeToNaturalTuning",
                     "setClipConsonantProtection", "setClipPitchTransitionSmoothness"] {
            #expect(write.contains("_ = try store.\(door)("), "\(door) is not called, or its return is kept")
        }
    }

    /// Planted and seen red (W7-NTU P-view): the header handing the group a
    /// fixed stretch of 1 instead of the clip's stored `stretchRatio`.
    @Test("the header resolves the group from the CLIP's stored stretch and transpose, draws it through the one Layout, and never a ViewThatFits")
    func headerWiring() {
        let view = Self.code("DAWApp/PitchEditor/PitchEditorView.swift")
        #expect(view.contains("model.singerGroup(stretchRatio: clip.stretchRatio,"))
        #expect(view.contains("clipSemitones: clip.pitchShiftSemitones)"))
        #expect(view.contains("PitchEditorPresetsAndSingerLayout {"))
        let group = Self.code("DAWApp/PitchEditor/PitchEditorSingerGroupView.swift")
        #expect(!group.contains("ViewThatFits"), "the stateful group must not be wrapped in a ViewThatFits")
        #expect(group.contains("PitchEditorSingerLayout.fit(headerContentWidth: width)"))
        #expect(group.contains("PitchEditorSingerLayout.fit(headerContentWidth: bounds.width)"))
        // The gestures reach the model's one-commit-per-gesture doors only.
        #expect(!group.contains("store."), "the group view touches the store")
        let header = view
        for door in ["model.trackVoiceSize(atFraction: fraction, fine: fine)", "model.releaseVoiceSize()",
                     "model.updateToNaturalTuning()", "model.toggleConsonants()", "model.pickSlides(step)"] {
            #expect(header.contains(door), "\(door) is not wired")
        }
        // The controls' callbacks and the debug tier's staged step land in ONE
        // function (`runSinger`), so a gate presses what a hand presses.
        for callback in ["onVoiceTrack: { fraction, fine in runSinger(.voiceTrack(fraction: fraction, fine: fine)) }",
                         "onVoiceRelease: { runSinger(.voiceRelease) }",
                         "onUpdate: { runSinger(.update) }",
                         "onToggleConsonants: { runSinger(.consonants) }",
                         "onPickSlides: { step in runSinger(.slides(step)) }"] {
            #expect(header.contains(callback), "\(callback) is not wired")
        }
        #expect(header.contains("case .singer(let act):"))
        #expect(header.contains("runSinger(act)"))
    }

    /// ONE HOME covers what VoiceOver says as well as what is drawn: a word
    /// typed into the view is a word the by-value pins and the word rules
    /// above never see.
    @Test("every word the group view draws or speaks comes from PitchEditorFormantCopy: its code holds no string literal")
    func groupViewHoldsNoWords() {
        let group = Self.code("DAWApp/PitchEditor/PitchEditorSingerGroupView.swift")
        #expect(group.contains("struct PitchEditorSingerGroupView: View"), "the group view's source was not read")
        #expect(!group.contains("\""), "a string literal in the group view's code: its home is PitchEditorFormantCopy")
        // What VoiceOver hears is what the row draws: the switch's face, and a
        // lit step is SELECTED (a trait, not a word).
        #expect(group.contains(".accessibilityValue(group.consonants.face)"))
        #expect(group.contains(".accessibilityAddTraits(lit ? .isSelected : [])"))
        // CONTROL — the same reader sees a literal where there is one.
        #expect(Self.code("DAWApp/PitchEditor/PitchEditorView.swift").contains("\""))
    }

    @Test("the staged \"singer\" step carries its own echo key, distinct from every other step's")
    func stagedSingerKey() {
        let singer: [PitchEditorStagedStep] = [
            .singer(.voiceTrack(fraction: 0.5, fine: false)), .singer(.voiceRelease), .singer(.update),
            .singer(.consonants), .singer(.slides(.slow)),
        ]
        #expect(Set(singer.map(\.key)) == ["singer"])
        let others: [PitchEditorStagedStep] = [.hover(.zero), .hoverEnd, .press(.zero, .none),
                                               .drag(.zero, .none), .release(.zero, .none), .tool(.pointer),
                                               .scroll(x: 0, y: nil), .noteMenu(.clear, nil), .pinch(.zero, 1),
                                               .pinchEnd, .ruler(x: 0, .none), .findSounds, .keys(.none)]
        #expect(!others.map(\.key).contains("singer"))
    }
}
