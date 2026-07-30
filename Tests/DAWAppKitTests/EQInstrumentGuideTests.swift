import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// m23-o2 — the EQ card's instrument frequency guide: resolution, the mark
/// partition over all 13 families, plot geometry, the empty state's words, the
/// legibility budget and the `debug.effectEditor` probe payload.
///
/// EVERY leg here is a COUNT or a NAMED SET over `InstrumentFamily.allCases`
/// rather than an `if let` inside a loop. That shape is deliberate and it is
/// the m23-o1 review's own lesson: V3 was VACUOUS because `if let` over a
/// filtered collection checks nothing when the filter empties. A leg written
/// `for family in allCases { if let f = fundamental { … } }` here would be
/// vacuous for exactly the three inharmonic rows — which are the rows the
/// hazard list is about — and would stay GREEN after deleting the guard that
/// makes them inharmonic.
@Suite("EQInstrumentGuide")
struct EQInstrumentGuideTests {
    /// The plot's real width — `EQGuidanceLayout.contentWidth`, which is the
    /// card's 560 minus its two 16 pt paddings. Read from the layout rather
    /// than restated, so a card resize moves the tests with the view.
    static let width = EQGuidanceLayout.contentWidth

    // MARK: - Fixtures

    private static func gmMelodic(program: Int) -> InstrumentDescriptor {
        InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: program,
            bankMSB: GMProgramCatalog.melodicBankMSB, bankLSB: 0,
            displayName: GMProgramCatalog.name(forProgram: program)))
    }

    private static func gmPercussion() -> InstrumentDescriptor {
        InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: 0,
            bankMSB: GMProgramCatalog.percussionBankMSB, bankLSB: 0,
            displayName: "Standard Drum Kit"))
    }

    private static func track(_ kind: TrackKind,
                              instrument: InstrumentDescriptor? = nil) -> Track {
        Track(name: "T", kind: kind, instrument: instrument)
    }

    private static func target(_ track: Track?) -> EffectEditorTarget {
        EffectEditorTarget(trackID: track?.id, effectID: UUID())
    }

    /// A synthetic mark — geometry legs must be drivable independently of the
    /// table, because the table exercises only some of the geometry (there is
    /// exactly ONE low-pass corner in v1, and no degenerate span at all).
    private static func mark(_ kind: EQInstrumentGuide.Mark.Kind,
                             _ lowHz: Double, _ highHz: Double,
                             tag: String = "TAG") -> EQInstrumentGuide.Mark {
        EQInstrumentGuide.Mark(kind: kind, lowHz: lowHz, highHz: highHz,
                               isSoft: false, tag: tag)
    }

    // MARK: - M1/M2 — resolution: which state, and the notApplicable/unknown split

    @Test("A master insert and a vanished track are notApplicable, never an empty state")
    func masterAndMissingTrackAreNotApplicable() {
        let audio = Self.track(.audio)
        // trackID nil == the MASTER chain.
        #expect(EQInstrumentGuide.resolve(
            target: EffectEditorTarget(trackID: nil, effectID: UUID()),
            tracks: [audio]) == .notApplicable)
        // No card open at all.
        #expect(EQInstrumentGuide.resolve(target: nil, tracks: [audio]) == .notApplicable)
        // A target whose track is gone (a wire `track.remove` mid-open).
        #expect(EQInstrumentGuide.resolve(target: Self.target(audio),
                                          tracks: []) == .notApplicable)
        // …and the SAME target WITH its track is NOT notApplicable, so the
        // three legs above cannot pass by the function returning one constant.
        #expect(EQInstrumentGuide.resolve(target: Self.target(audio),
                                          tracks: [audio])
                == .unknown(.audioTrackHasNoInstrument))
    }

    @Test("A bus is notApplicable; an audio track is the honest empty state")
    func busIsNotApplicableAudioIsUnknown() {
        let bus = Self.track(.bus)
        let audio = Self.track(.audio)
        // The distinction the m23-o2 gate turns on: a bus can NEVER have an
        // instrument identity (nothing to remedy), an audio track simply does
        // not have one YET (a remedy exists).
        #expect(EQInstrumentGuide.resolve(target: Self.target(bus),
                                          tracks: [bus]) == .notApplicable)
        #expect(EQInstrumentGuide.resolve(target: Self.target(audio),
                                          tracks: [audio])
                == .unknown(.audioTrackHasNoInstrument))
        #expect(EQInstrumentGuide.resolve(target: Self.target(bus),
                                          tracks: [bus]).showsRow == false)
        #expect(EQInstrumentGuide.resolve(target: Self.target(audio),
                                          tracks: [audio]).showsRow == true)
    }

    @Test("Every unresolved instrument-track reason reaches the empty state")
    func instrumentTrackReasonsReachTheEmptyState() {
        let noInstrument = Self.track(.instrument)
        #expect(EQInstrumentGuide.resolve(target: Self.target(noInstrument),
                                          tracks: [noInstrument])
                == .unknown(.instrumentTrackHasNoInstrument))

        let synth = Self.track(.instrument, instrument: InstrumentDescriptor(kind: .polySynth))
        #expect(EQInstrumentGuide.resolve(target: Self.target(synth), tracks: [synth])
                == .unknown(.instrumentKindCarriesNoFamily))

        let au = Self.track(.instrument, instrument: InstrumentDescriptor(kind: .audioUnit))
        #expect(EQInstrumentGuide.resolve(target: Self.target(au), tracks: [au])
                == .unknown(.hostedAudioUnitIsOpaque))

        // GM 16 Drawbar Organ — authored `nil` in the resolver's table.
        let organ = Self.track(.instrument, instrument: Self.gmMelodic(program: 16))
        #expect(EQInstrumentGuide.resolve(target: Self.target(organ), tracks: [organ])
                == .unknown(.gmProgramNotCoveredInV1))
    }

    /// M3 — the pin the advisor asked for: GM 43 is CONTRABASS, which the
    /// resolver maps to `uprightBass` and not to `electricBass`. That mapping
    /// is non-obvious (contrabass lives in GM's *Strings* bucket, not *Bass*)
    /// and exists in exactly one place. Any hand-rolled family guess in the UI
    /// returns nil or `electricBass` here.
    @Test("GM 43 Contrabass resolves to uprightBass through DAWCore's one resolver")
    func gmContrabassResolvesThroughTheOneResolver() {
        let contrabass = Self.track(.instrument, instrument: Self.gmMelodic(program: 43))
        #expect(EQInstrumentGuide.resolve(target: Self.target(contrabass),
                                          tracks: [contrabass])
                == .family(.uprightBass, source: .gmProgram))

        // A DIFFERENT program, so the leg cannot pass by returning one family.
        let acousticBass = Self.track(.instrument, instrument: Self.gmMelodic(program: 32))
        #expect(EQInstrumentGuide.resolve(target: Self.target(acousticBass),
                                          tracks: [acousticBass])
                == .family(.uprightBass, source: .gmProgram))
        let fingered = Self.track(.instrument, instrument: Self.gmMelodic(program: 33))
        #expect(EQInstrumentGuide.resolve(target: Self.target(fingered),
                                          tracks: [fingered])
                == .family(.electricBass, source: .gmProgram))
    }

    /// M5's sibling — a GM percussion track must NOT pick a representative
    /// piece. A kick and a hi-hat are three octaves apart.
    @Test("A GM drum-kit track is its own state and draws no marks")
    func drumKitIsItsOwnState() {
        let kit = Self.track(.instrument, instrument: Self.gmPercussion())
        let guide = EQInstrumentGuide.resolve(target: Self.target(kit), tracks: [kit])
        #expect(guide == .drumKit)
        #expect(guide.family == nil)
        #expect(guide.marks.isEmpty)
        #expect(guide.showsRow)
        #expect(!guide.headline.isEmpty)
        #expect(!guide.detail.isEmpty)
    }

    // MARK: - M4 — the mark partition, as COUNTS over all 13 families

    @Test("Exactly 10 of 13 families draw a fundamental span; the 3 inharmonic rows draw none")
    func fundamentalSpanPartition() {
        var withSpan: [InstrumentFamily] = []
        var withoutSpan: [InstrumentFamily] = []
        for family in InstrumentFamily.allCases {
            let guide = EQInstrumentGuide.family(family, source: .argument)
            let spans = guide.marks.filter { $0.kind == .fundamental }
            // A row draws AT MOST one fundamental span — never two, never a
            // second one from a fallback path.
            #expect(spans.count <= 1, "\(family) emitted \(spans.count) fundamental marks")
            if spans.isEmpty { withoutSpan.append(family) } else { withSpan.append(family) }
        }
        #expect(withSpan.count == 10)
        #expect(Set(withoutSpan) == [.hiHat, .rideCymbal, .crashCymbal])
        // ANTI-VACUITY: the sweep really visited every family.
        #expect(withSpan.count + withoutSpan.count == InstrumentFamily.allCases.count)
        #expect(InstrumentFamily.allCases.count == 13)
    }

    @Test("Every family draws its high-pass corner; exactly one draws a low-pass corner")
    func cornerPartition() {
        var withHighPass: [InstrumentFamily] = []
        var withLowPass: [InstrumentFamily] = []
        for family in InstrumentFamily.allCases {
            let marks = EQInstrumentGuide.family(family, source: .argument).marks
            if marks.contains(where: { $0.kind == .highPass }) { withHighPass.append(family) }
            if marks.contains(where: { $0.kind == .lowPass }) { withLowPass.append(family) }
        }
        // The high pass is REQUIRED on every row (DAWCore design D4) and every
        // shipped corner sits inside the plot axis, so all 13 draw.
        #expect(withHighPass.count == 13)
        // electricGuitar is the ONLY row in v1 with a `.corner` low pass
        // (6 kHz, the amp-cabinet roll-off). The other twelve are
        // `.noneRecommended` and must draw NOTHING — not a corner at 0, not a
        // corner at the axis edge.
        #expect(withLowPass == [.electricGuitar])
        let guitarLP = EQInstrumentGuide.family(.electricGuitar, source: .argument)
            .marks.first { $0.kind == .lowPass }
        #expect(guitarLP?.lowHz == 6000)
    }

    /// The hazard in its sharpest form: "no bracket" and "a zero-width bracket"
    /// look IDENTICAL on screen and mean opposite things, so the payload has to
    /// tell them apart.
    @Test("An inharmonic row reports absence, never a zero-width span")
    func inharmonicReportsAbsenceNotZeroWidth() {
        let hat = EQInstrumentGuide.family(.hiHat, source: .argument)
        let fields = Dictionary(uniqueKeysWithValues: hat.probeFields(width: Self.width, widthSource: .measured))
        #expect(fields["fundamentalHz"] == nil)
        #expect(fields["fundamentalX"] == nil)
        // Absence is REPORTED, carrying the table's OWN reason verbatim — not a
        // sentence this module invented about a row it does not own.
        guard case .string(let none)? = fields["fundamentalNone"] else {
            Issue.record("hiHat did not report fundamentalNone"); return
        }
        guard case .inharmonic(let tableReason) =
                InstrumentFrequencyTable.reference(for: .hiHat).fundamental else {
            Issue.record("hiHat is no longer inharmonic"); return
        }
        #expect(none == tableReason)
        #expect(none.count > 20)
        // Only the high pass is drawn.
        #expect(fields["markCount"] == .number(1))

        // A PITCHED row, by contrast, reports a real two-ended span.
        let kick = EQInstrumentGuide.family(.kick, source: .argument)
        let kickFields = Dictionary(uniqueKeysWithValues: kick.probeFields(width: Self.width, widthSource: .measured))
        #expect(kickFields["fundamentalNone"] == nil)
        guard case .numbers(let hz)? = kickFields["fundamentalHz"] else {
            Issue.record("kick did not report fundamentalHz"); return
        }
        #expect(hz.count == 2)
        #expect(hz[1] > hz[0])
    }

    @Test("The plot axis test is STRICT — a corner on the rim is not drawn")
    func axisTestIsStrict() {
        #expect(EQInstrumentGuide.isOnAxis(20) == false)
        #expect(EQInstrumentGuide.isOnAxis(20_000) == false)
        #expect(EQInstrumentGuide.isOnAxis(20.0.nextUp) == true)
        #expect(EQInstrumentGuide.isOnAxis(20_000.0.nextDown) == true)
        #expect(EQInstrumentGuide.isOnAxis(19.9) == false)
        #expect(EQInstrumentGuide.isOnAxis(20_001) == false)
    }

    // MARK: - M6/M7 — the softness survives the trip to pixels

    @Test("Exactly kick/snare/tom are ADMISSION-DOUBTFUL and exactly piano/ride/crash FILTER-WEAK")
    func softnessPartitionIsDisjointAndNamed() {
        var softFundamentals: [InstrumentFamily] = []
        var softHighPasses: [InstrumentFamily] = []
        var visited = 0
        for family in InstrumentFamily.allCases {
            visited += 1
            let row = InstrumentFrequencyTable.reference(for: family)
            if row.fundamentalStrength.isSoft { softFundamentals.append(family) }
            if row.highPassStrength.isSoft { softHighPasses.append(family) }
            // The two soft cases are FIELD-SPECIFIC by construction — a
            // fundamental is never `filterWeak` and a corner never
            // `admissionDoubtful`. Pinned in both directions.
            #expect(row.fundamentalStrength != .filterWeak, "\(family)")
            #expect(row.highPassStrength != .admissionDoubtful, "\(family)")
        }
        #expect(visited == 13)
        #expect(Set(softFundamentals) == [.kick, .snare, .tom])
        #expect(Set(softHighPasses) == [.piano, .rideCymbal, .crashCymbal])
        // The 7 firm-everywhere rows, stated as a count so a row silently
        // becoming soft is caught from the other side too.
        #expect(InstrumentFamily.allCases.filter {
            let row = InstrumentFrequencyTable.reference(for: $0)
            return !row.fundamentalStrength.isSoft && !row.highPassStrength.isSoft
        }.count == 7)
    }

    @Test("A soft fact's MARK is flagged soft and a firm one is not")
    func softnessReachesTheMarks() {
        func mark(_ family: InstrumentFamily,
                  _ kind: EQInstrumentGuide.Mark.Kind) -> EQInstrumentGuide.Mark? {
            EQInstrumentGuide.family(family, source: .argument).marks.first { $0.kind == kind }
        }
        // Soft where the review said soft…
        #expect(mark(.kick, .fundamental)?.isSoft == true)
        #expect(mark(.snare, .fundamental)?.isSoft == true)
        #expect(mark(.tom, .fundamental)?.isSoft == true)
        #expect(mark(.piano, .highPass)?.isSoft == true)
        #expect(mark(.rideCymbal, .highPass)?.isSoft == true)
        #expect(mark(.crashCymbal, .highPass)?.isSoft == true)
        // …and NOT soft anywhere else, including the OTHER field of the very
        // same row (kick's corner is firm, piano's compass is firm).
        #expect(mark(.kick, .highPass)?.isSoft == false)
        #expect(mark(.piano, .fundamental)?.isSoft == false)
        #expect(mark(.electricBass, .fundamental)?.isSoft == false)
        #expect(mark(.electricBass, .highPass)?.isSoft == false)
        #expect(mark(.electricGuitar, .lowPass)?.isSoft == false)
    }

    /// Dashes cannot say "a drum's pitch is a tuning choice". Words can — and
    /// this pins that the words are actually drawn, on the specific fact that
    /// is soft rather than smeared over the whole row.
    @Test("The guidance row says WHICH fact is soft, in words")
    func theRowNamesTheSoftFactInWords() {
        let kick = EQInstrumentGuide.family(.kick, source: .argument).detail
        #expect(kick.contains("Fundamental"))
        #expect(kick.contains("(tuning-dependent)"))
        #expect(!kick.contains("(soft source)"))   // its corner is firm

        let piano = EQInstrumentGuide.family(.piano, source: .argument).detail
        #expect(piano.contains("High-pass"))
        #expect(piano.contains("(soft source)"))
        #expect(!piano.contains("(tuning-dependent)"))   // its compass is firm

        // A row soft in NEITHER field carries neither qualifier.
        let bass = EQInstrumentGuide.family(.electricBass, source: .argument).detail
        #expect(!bass.contains("(tuning-dependent)"))
        #expect(!bass.contains("(soft source)"))
    }

    // MARK: - M8/M9/M10 — geometry, in the plot's own coordinate space

    @Test("Marks map through the plot's ONE axis, and the arithmetic is pinned")
    func geometryUsesThePlotAxisAndTheArithmeticHolds() {
        // ARITHMETIC pin — x = width · log(f/20) / log(1000). 35 Hz:
        // 528 · ln(1.75)/ln(1000) = 528 · 0.559616/6.907755 = 42.7742…
        let hp = Self.mark(.highPass, 35, 35)
        let x = EQInstrumentGuide.cornerX(hp, width: 528)
        #expect(abs((x ?? -1) - 42.774) < 0.01)
        // DRAWING pin — the same number the plot's own grid/handle layer would
        // produce, so a second mapping cannot creep in beside the first.
        #expect(x == EQCurveGeometry.x(forFrequency: 35, in: 528))

        // The axis ends land where the plot's do.
        #expect(EQCurveGeometry.x(forFrequency: 20, in: 528) == 0)
        #expect(abs(EQCurveGeometry.x(forFrequency: 20_000, in: 528) - 528) < 1e-9)

        // A span uses the same mapping at both ends, and stays inside the plot.
        let kick = EQInstrumentGuide.family(.kick, source: .argument)
            .marks.first { $0.kind == .fundamental }!
        let span = EQInstrumentGuide.spanX(kick, width: 528)!
        #expect(span.lo == EQCurveGeometry.x(forFrequency: kick.lowHz, in: 528))
        #expect(span.hi == EQCurveGeometry.x(forFrequency: kick.highHz, in: 528))
        #expect(span.lo > 0 && span.hi < 528 && span.hi > span.lo)

        // WIDTH is honoured, not assumed: halve the plot and every x halves.
        let half = EQInstrumentGuide.cornerX(hp, width: 264)
        #expect(abs((half ?? -1) * 2 - (x ?? 0)) < 1e-9)
    }

    @Test("A degenerate span is floored to a visible width; a real one is untouched")
    func minimumSpanFloor() {
        // A zero-width span (both ends at 1 kHz) widens to EXACTLY the floor,
        // centred on its true position — it is still the real frequency, just
        // drawable.
        let degenerate = Self.mark(.fundamental, 1000, 1000)
        let widened = EQInstrumentGuide.spanX(degenerate, width: 528)!
        let center = EQCurveGeometry.x(forFrequency: 1000, in: 528)
        #expect(abs((widened.hi - widened.lo) - EQGuidanceLayout.minimumSpanPoints) < 1e-9)
        #expect(abs((widened.lo + widened.hi) / 2 - center) < 1e-9)

        // A REAL span is NOT widened — the floor must not fire unconditionally.
        let kick = EQInstrumentGuide.family(.kick, source: .argument)
            .marks.first { $0.kind == .fundamental }!
        let real = EQInstrumentGuide.spanX(kick, width: 528)!
        #expect(real.hi - real.lo > EQGuidanceLayout.minimumSpanPoints)
        #expect(real.lo == EQCurveGeometry.x(forFrequency: kick.lowHz, in: 528))

        // The floor is for SPANS only. A corner is a line; widening it would
        // turn a single recommended frequency into a fake range.
        #expect(EQInstrumentGuide.spanX(Self.mark(.highPass, 80, 80), width: 528) == nil)
        #expect(EQInstrumentGuide.cornerX(degenerate, width: 528) == nil)
    }

    @Test("Tags sit in two lanes, inside the plot, and never overlap")
    func tagPlacementIsCollisionFreeAndClamped() {
        var checkedFundamental = 0
        var checkedCorner = 0
        for family in InstrumentFamily.allCases {
            let guide = EQInstrumentGuide.family(family, source: .argument)
            let placements = EQInstrumentGuide.placements(guide.marks, width: Self.width)
            #expect(placements.count == guide.marks.count, "\(family)")
            for placement in placements {
                let textWidth = Double(placement.text.count)
                    * EQGuidanceLayout.tagFontSize * EQGuidanceLayout.monoAdvanceEm
                let leading: Double
                switch placement.anchor {
                case .leading: leading = placement.x
                case .center: leading = placement.x - textWidth / 2
                case .trailing: leading = placement.x - textWidth
                }
                #expect(leading >= -1e-9, "\(family) \(placement.kind) ran off the left")
                #expect(leading + textWidth <= Self.width + 1e-9,
                        "\(family) \(placement.kind) ran off the right")
                if placement.kind == .fundamental {
                    checkedFundamental += 1
                    #expect(placement.y == EQGuidanceLayout.fundamentalLaneY)
                } else {
                    checkedCorner += 1
                    #expect(placement.y == EQGuidanceLayout.cornerLaneY)
                }
            }
        }
        // ANTI-VACUITY, per lane: 10 fundamental tags, 13 HP + 1 LP corner tags.
        #expect(checkedFundamental == 10)
        #expect(checkedCorner == 14)
        #expect(EQGuidanceLayout.fundamentalLaneY != EQGuidanceLayout.cornerLaneY)

        // The one family carrying BOTH corner tags: they grow AWAY from each
        // other (HP leading, LP trailing), so they cannot collide.
        let guitar = EQInstrumentGuide.family(.electricGuitar, source: .argument)
        let corners = EQInstrumentGuide.placements(guitar.marks, width: Self.width)
            .filter { $0.kind != .fundamental }
        #expect(corners.count == 2)
        let hp = corners.first { $0.kind == .highPass }!
        let lp = corners.first { $0.kind == .lowPass }!
        #expect(hp.anchor == .leading)
        #expect(lp.anchor == .trailing)
        let hpEnd = hp.x + Double(hp.text.count)
            * EQGuidanceLayout.tagFontSize * EQGuidanceLayout.monoAdvanceEm
        #expect(hpEnd < lp.x - Double(lp.text.count)
                * EQGuidanceLayout.tagFontSize * EQGuidanceLayout.monoAdvanceEm)
    }

    /// No SHIPPED family sits near enough to a rim to need the clamp, so a leg
    /// over the table alone would leave that code unexercised — a synthetic
    /// mark drives it.
    @Test("A tag near the right rim is clamped whole, not scissored")
    func tagNearTheRimIsClamped() {
        let nearTop = Self.mark(.highPass, 19_000, 19_000, tag: "HP 19 kHz")
        let placement = EQInstrumentGuide.placements([nearTop], width: Self.width)[0]
        let textWidth = Double(nearTop.tag.count)
            * EQGuidanceLayout.tagFontSize * EQGuidanceLayout.monoAdvanceEm
        // Unclamped, a LEADING anchor at x(19 kHz) ≈ 523 would run ~43 pt past
        // the right edge.
        #expect(EQCurveGeometry.x(forFrequency: 19_000, in: Self.width)
                + textWidth > Self.width)
        #expect(placement.x + textWidth <= Self.width + 1e-9)
        #expect(placement.x < EQCurveGeometry.x(forFrequency: 19_000, in: Self.width))

        // And near the LEFT rim, a centred span tag is pushed inward.
        let low = Self.mark(.fundamental, 21, 22, tag: "21\u{2013}22 Hz")
        let lowPlacement = EQInstrumentGuide.placements([low], width: Self.width)[0]
        let lowWidth = Double(low.tag.count)
            * EQGuidanceLayout.tagFontSize * EQGuidanceLayout.monoAdvanceEm
        #expect(lowPlacement.x - lowWidth / 2 >= -1e-9)
    }

    // MARK: - M11 — the LEGIBILITY budget (the gate's third leg)

    @Test("Every guidance string fits the row at the width the card actually gets")
    func everyStringFitsTheRealRow() {
        // The budget is arithmetic off the card's own metrics: SF Mono's
        // advance is exactly 0.6 em, so 528 / (9 × 0.6) = 97 characters.
        #expect(EQGuidanceLayout.contentWidth == 528)
        #expect(EQGuidanceLayout.contentWidth
                == EQGuidanceLayout.cardWidth - 2 * EQGuidanceLayout.cardPadding)
        #expect(EQGuidanceLayout.rowCharacterBudget == 97)

        var checked = 0
        func check(_ guide: EQInstrumentGuide, _ label: String) {
            checked += 1
            #expect(guide.headline.count <= EQGuidanceLayout.rowCharacterBudget,
                    "\(label) headline is \(guide.headline.count) chars")
            #expect(guide.detail.count <= EQGuidanceLayout.rowCharacterBudget,
                    "\(label) detail is \(guide.detail.count) chars")
            // A row that fits because it is EMPTY proves nothing.
            #expect(!guide.headline.isEmpty, "\(label) headline is empty")
            #expect(!guide.detail.isEmpty, "\(label) detail is empty")
        }
        for family in InstrumentFamily.allCases {
            check(.family(family, source: .argument), family.rawValue)
        }
        for reason in InstrumentFamilyResolution.Reason.allCases {
            check(.unknown(reason), reason.rawValue)
        }
        check(.drumKit, "drumKit")
        // ANTI-VACUITY: 13 families + 9 reasons + drumKit.
        #expect(checked == 23)
        #expect(InstrumentFamilyResolution.Reason.allCases.count == 9)

        // `.notApplicable` draws NO row at all, so its empty strings are
        // correct rather than a hole in the sweep above.
        #expect(EQInstrumentGuide.notApplicable.showsRow == false)
        #expect(EQInstrumentGuide.notApplicable.headline.isEmpty)
        #expect(EQInstrumentGuide.notApplicable.detail.isEmpty)
    }

    // MARK: - M12 — the empty state's words are for a PERSON

    @Test("No empty-state string tells the user to call a wire verb")
    func emptyStateNamesNoWireVerb() {
        // DAWCore's own explanation/remedy pair is written for the COPILOT and
        // says things like "Call frequency.reference again…" and "measure it
        // instead with fx.spectrum". Those are correct there and unusable here.
        let forbidden = ["frequency.reference", "fx.spectrum", "fx.setParam",
                         "Call ", "trackId", "coveredNotes", "`families`"]
        var hits = [String: Int]()
        var checked = 0
        for reason in InstrumentFamilyResolution.Reason.allCases {
            checked += 1
            let explanation = EQInstrumentGuide.userExplanation(reason)
            let remedy = EQInstrumentGuide.userRemedy(reason)
            #expect(!explanation.isEmpty, "\(reason)")
            #expect(!remedy.isEmpty, "\(reason)")
            for token in forbidden {
                if explanation.contains(token) || remedy.contains(token) {
                    hits[token, default: 0] += 1
                }
            }
        }
        #expect(checked == 9)
        // PER-NEEDLE, not an aggregate: an aggregate "no hits" lets one needle
        // coast on another's silence.
        for token in forbidden {
            #expect(hits[token] == nil, "'\(token)' leaked into the user-facing text")
        }
        // The control: DAWCore's agent prose DOES contain them, so the token
        // list is capable of firing and this leg is not vacuous.
        #expect(InstrumentFamilyResolution.Reason.gmProgramNotCoveredInV1
            .remedy.contains("frequency.reference"))
        #expect(InstrumentFamilyResolution.Reason.instrumentKindCarriesNoFamily
            .explanation.contains("fx.spectrum"))
    }

    @Test("An unresolved track draws no marks — never a defaulted or guessed range")
    func unresolvedDrawsNothing() {
        var checked = 0
        for reason in InstrumentFamilyResolution.Reason.allCases {
            checked += 1
            let guide = EQInstrumentGuide.unknown(reason)
            #expect(guide.marks.isEmpty, "\(reason) drew \(guide.marks.count) marks")
            #expect(guide.reference == nil, "\(reason) reached the table")
            #expect(guide.family == nil)
            let fields = Dictionary(uniqueKeysWithValues: guide.probeFields(width: Self.width, widthSource: .measured))
            #expect(fields["markCount"] == .number(0))
            #expect(fields["fundamentalHz"] == nil)
            #expect(fields["highPassHz"] == nil)
            #expect(fields["reason"] == .string(reason.rawValue))
        }
        #expect(checked == 9)
        #expect(EQInstrumentGuide.notApplicable.marks.isEmpty)
        #expect(EQInstrumentGuide.drumKit.marks.isEmpty)
        // …while a RESOLVED family does draw, so "no marks" is a real result
        // and not the only thing this function can return.
        #expect(EQInstrumentGuide.family(.kick, source: .argument).marks.count == 2)
    }

    // MARK: - M14 — beginner-readable numbers

    @Test("Frequencies read the way a person says them")
    func numberFormatting() {
        #expect(EQInstrumentGuide.hzText(35) == "35 Hz")
        #expect(EQInstrumentGuide.hzText(999) == "999 Hz")
        #expect(EQInstrumentGuide.hzText(1000) == "1 kHz")
        #expect(EQInstrumentGuide.hzText(1047) == "1.05 kHz")
        #expect(EQInstrumentGuide.hzText(6000) == "6 kHz")
        #expect(EQInstrumentGuide.hzText(4186.009) == "4.19 kHz")
        #expect(EQInstrumentGuide.hzText(16_000) == "16 kHz")
        // Unit printed ONCE when both ends share it.
        #expect(EQInstrumentGuide.rangeText(lowHz: 48.999, highHz: 92.499) == "49\u{2013}92 Hz")
        // …and on BOTH ends when they do not.
        #expect(EQInstrumentGuide.rangeText(lowHz: 27.5, highHz: 4186.009)
                == "28 Hz \u{2013} 4.19 kHz")
        // No scientific notation, ever (the plot grid's beginner rule).
        for family in InstrumentFamily.allCases {
            #expect(!EQInstrumentGuide.family(family, source: .argument)
                .detail.lowercased().contains("e+"))
        }
    }

    // MARK: - M15 — the probe reports the value the view draws

    @Test("probeFields reports Hz AND on-screen x, at the width it names")
    func probeReportsBothCoordinateSpaces() {
        let guide = EQInstrumentGuide.family(.electricGuitar, source: .gmProgram)
        let fields = Dictionary(uniqueKeysWithValues: guide.probeFields(width: Self.width, widthSource: .measured))
        #expect(fields["state"] == .string("family"))
        #expect(fields["family"] == .string("electricGuitar"))
        #expect(fields["resolvedFrom"] == .string("gmProgram"))
        #expect(fields["width"] == .number(Self.width))
        #expect(fields["fundamentalSource"] == .string("published"))
        #expect(fields["highPassSource"] == .string("published"))

        // Hz and x are DIFFERENT claims: a coordinate-space bug satisfies the
        // first and fails the second, so both are reported and both are pinned
        // against the geometry the view calls.
        let lp = guide.marks.first { $0.kind == .lowPass }!
        #expect(fields["lowPassHz"] == .number(6000))
        #expect(fields["lowPassX"]
                == .number(EQInstrumentGuide.cornerX(lp, width: Self.width)!))
        let span = guide.marks.first { $0.kind == .fundamental }!
        let spanX = EQInstrumentGuide.spanX(span, width: Self.width)!
        #expect(fields["fundamentalX"] == .numbers([spanX.lo, spanX.hi]))
        #expect(fields["fundamentalHz"] == .numbers([span.lowHz, span.highHz]))

        // The probe reports the DRAWN strings, not a re-derivation of them.
        #expect(fields["headline"] == .string(guide.headline))
        #expect(fields["detail"] == .string(guide.detail))
        guard case .strings(let tags)? = fields["tags"] else {
            Issue.record("no tags reported"); return
        }
        #expect(tags == EQInstrumentGuide.placements(guide.marks, width: Self.width)
            .map(\.text))
        #expect(tags.count == 3)

        // A DIFFERENT width moves the x values and nothing else — proof the
        // reported positions are computed, not baked.
        let narrow = Dictionary(uniqueKeysWithValues: guide.probeFields(width: 264, widthSource: .measured))
        #expect(narrow["lowPassHz"] == fields["lowPassHz"])
        #expect(narrow["lowPassX"] != fields["lowPassX"])
        #expect(narrow["width"] == .number(264))
    }

    @Test("A noneRecommended filter is reported by NAME, not as zero")
    func noneRecommendedIsReportedByName() {
        // Twelve of thirteen rows recommend no low pass. The payload has to say
        // so in a way that cannot be confused with "0 Hz" or "at the axis edge".
        var named = 0
        for family in InstrumentFamily.allCases {
            let fields = Dictionary(uniqueKeysWithValues: EQInstrumentGuide
                .family(family, source: .argument).probeFields(width: Self.width, widthSource: .measured))
            if case .string(let reason)? = fields["lowPassNone"] {
                named += 1
                #expect(!reason.isEmpty)
                #expect(fields["lowPassHz"] == nil, "\(family) reported both")
                #expect(fields["lowPassX"] == nil, "\(family) reported both")
            } else {
                #expect(fields["lowPassHz"] != nil, "\(family) reported neither")
            }
            // The high pass is REQUIRED, so no row may ever report its absence.
            #expect(fields["highPassNone"] == nil, "\(family)")
        }
        #expect(named == 12)
    }

    // MARK: - M23 — the honest cost: which families the CARD can actually reach

    /// ⚠️ THIS LEG RECORDS A COST, NOT A CAPABILITY, AND IT IS THE MOST
    /// IMPORTANT THING IN THIS FILE TO READ BEFORE TRUSTING THE OTHERS.
    ///
    /// Every OTHER family leg here constructs `.family(x, source: .argument)`
    /// directly. That is a legitimate pin on the TABLE — it proves the marks a
    /// row would draw — but it is NOT a claim that a user can ever see that row.
    /// `resolve` passes `percussionNote: nil` by construction, so a GM
    /// percussion track is always `.drumKit`, and the eight families whose
    /// `allowedGMCategories` is empty (the six percussion rows plus both vocal
    /// rows) have no melodic program that reaches them. FIVE of thirteen
    /// families can reach the pixels, and all five are `.pitched`.
    ///
    /// The consequence worth stating out loud: the `.inharmonic` no-bracket
    /// path — one of this item's four briefed hazards — is correct, is pinned
    /// two legs above, and CANNOT FIRE IN THE SHIPPING CARD, because all three
    /// inharmonic rows are cymbals reachable only by percussion note. Likewise
    /// the `(tuning-dependent)` qualifier, which only kick/snare/tom carry.
    ///
    /// This is not a defect to fix here: closing it means either the track-name
    /// heuristic `InstrumentFamilyResolver` structurally refuses, or new
    /// per-track user-set state, which is a feature and not this item's.
    @Test("Only five of thirteen families can reach the card — the cost of no name heuristic")
    func onlyFiveFamiliesAreReachableThroughTheCard() {
        // Sweep through the SAME entry point the view calls, not through
        // `melodicProgramFamilies`: the claim is about what the CARD displays,
        // which runs the whole ladder including `resolve`'s own nil note.
        var reachable: Set<InstrumentFamily> = []
        var resolvedPrograms = 0
        for program in 0..<128 {
            let track = Self.track(.instrument,
                                   instrument: Self.gmMelodic(program: program))
            if case .family(let family, let source) = EQInstrumentGuide.resolve(
                target: Self.target(track), tracks: [track]) {
                resolvedPrograms += 1
                reachable.insert(family)
                #expect(source == .gmProgram, "program \(program)")
            }
        }
        // ANTI-VACUITY: the loop must actually produce. 18 is counted from
        // `melodicProgramFamilies`' non-nil entries (4 piano + 2 acoustic
        // guitar + 5 electric guitar + 2 upright bass + 5 electric bass).
        #expect(resolvedPrograms == 18)
        #expect(reachable == [.piano, .acousticGuitar, .electricGuitar,
                              .uprightBass, .electricBass])
        // NAMED IN BOTH DIRECTIONS, so widening the map fails here loudly
        // rather than quietly making this comment wrong.
        let unreachable = Set(InstrumentFamily.allCases).subtracting(reachable)
        #expect(unreachable == [.kick, .snare, .hiHat, .tom, .rideCymbal,
                               .crashCymbal, .maleVocal, .femaleVocal])
        #expect(reachable.count == 5)
        #expect(unreachable.count == 8)
        // Every reachable row is pitched — so the inharmonic branch, though
        // correct, is unreachable from here.
        for family in reachable {
            guard case .pitched = InstrumentFrequencyTable.reference(for: family)
                .fundamental else {
                Issue.record("\(family) is reachable but not pitched")
                continue
            }
        }
        // And the drum bank lands on its own state, never on a member family.
        let kit = Self.track(.instrument, instrument: Self.gmPercussion())
        #expect(EQInstrumentGuide.resolve(target: Self.target(kit),
                                          tracks: [kit]) == .drumKit)

        // ⚠️ WHERE REACHABILITY MEETS SOFTNESS — the honest answer to "how does
        // softness read on screen". Six of thirteen rows are softly sourced, but
        // only ONE of them is reachable: `piano`, whose HIGH-PASS corner is
        // FILTER-WEAK. So in the shipping card `(soft source)` renders for
        // exactly one family and `(tuning-dependent)` renders for NONE — every
        // ADMISSION-DOUBTFUL row is a drum, reachable only by percussion note.
        // Pinned rather than asserted in prose, because a measured-sounding
        // claim with no leg behind it is the "a comment is not coverage" trap.
        let softFundamental = reachable.filter {
            InstrumentFrequencyTable.reference(for: $0).fundamentalStrength.isSoft
        }
        let softHighPass = reachable.filter {
            InstrumentFrequencyTable.reference(for: $0).highPassStrength.isSoft
        }
        #expect(softFundamental.isEmpty)
        #expect(softHighPass == [.piano])
        // ANTI-VACUITY in the other direction: the table DOES carry soft rows,
        // so an empty `softFundamental` above means "unreachable", not "the
        // strength field stopped working".
        let softAnywhere = Set(InstrumentFamily.allCases).filter {
            let row = InstrumentFrequencyTable.reference(for: $0)
            return row.fundamentalStrength.isSoft || row.highPassStrength.isSoft
        }
        #expect(softAnywhere.count == 6)
        #expect(softAnywhere.intersection(reachable) == [.piano])
    }

    // MARK: - M24 — reference ink must not read as a live readout

    /// The dishonest-readout class. `EQCurveEditorModel.tag(for:)` labels the
    /// six REAL band handles HP·LS·1·2·HS·LP in SF Mono inside this same plot.
    /// A guidance tag reading "HP 35 Hz" is the same two letters, same face,
    /// same size, a few inches from the user's actual high-pass handle — it
    /// reads as *your* setting rather than a *suggested* one, and neutral
    /// dashed ink does not carry that distinction. The STRING has to.
    ///
    /// Read from `tag(for:)` rather than a copied list, so renaming a handle
    /// tag to something a guidance tag already uses fails HERE.
    @MainActor
    @Test("Guidance tags share no vocabulary with the band handles")
    func guidanceTagsShareNoVocabularyWithTheBandHandles() {
        let handleTags = Set(EQCurveEditorModel.Band.allCases
            .map { EQCurveEditorModel.tag(for: $0) })
        // ANTI-VACUITY on the needle itself: if `tag(for:)` ever stops
        // returning these, the subset check below passes for free.
        #expect(handleTags == ["HP", "LS", "1", "2", "HS", "LP"])
        var checked = 0
        for family in InstrumentFamily.allCases {
            for mark in EQInstrumentGuide.family(family, source: .argument).marks {
                checked += 1
                for token in mark.tag.split(separator: " ") {
                    #expect(!handleTags.contains(String(token)),
                            "\(family) \(mark.kind) tag '\(mark.tag)' reuses the handle vocabulary")
                }
                // Positive half: a bare number+unit would also read as a
                // readout, so every tag must lead with a WORD that says what
                // kind of claim it is.
                let lead = mark.tag.split(separator: " ").first.map(String.init) ?? ""
                #expect(["TYPICAL", "CUT"].contains(lead),
                        "\(family) \(mark.kind) tag '\(mark.tag)' does not announce itself as reference")
            }
        }
        // 10 fundamental spans + 13 high-pass corners + 1 low-pass corner.
        #expect(checked == 24)
    }

    // MARK: - M25 — "no row" must be reportable, not inferred from empty strings

    /// `.notApplicable` returns `""` for both `headline` and `detail`, so a gate
    /// reading only those cannot distinguish *the row is deliberately not drawn*
    /// from *the row is drawn and its copy went missing*. That is the same
    /// absence-vs-zero confusion `.inharmonic` and `.noneRecommended` are
    /// reported by NAME to avoid, and the live probe smoke run hit it: the
    /// master-insert leg could not be written until `showsRow` was reported.
    ///
    /// The probe reports the view's OWN `showsRow` — `EQCurveEditor` renders the
    /// guidance row `if guide.showsRow` — not a second predicate over `state`.
    @Test("The probe reports showsRow explicitly, and only notApplicable is false")
    func probeReportsShowsRowRatherThanLeavingItToEmptyStrings() {
        let states: [EQInstrumentGuide] = [
            .notApplicable,
            .unknown(.audioTrackHasNoInstrument),
            .drumKit,
            .family(.electricBass, source: .gmProgram),
        ]
        var drawn = 0
        var hidden = 0
        for state in states {
            let fields = Dictionary(uniqueKeysWithValues:
                                        state.probeFields(width: Self.width, widthSource: .measured))
            guard case .bool(let shows)? = fields["showsRow"] else {
                Issue.record("\(state.stateName) reported no showsRow")
                continue
            }
            // The probe must AGREE with the property the view branches on.
            #expect(shows == state.showsRow, "\(state.stateName)")
            if shows {
                drawn += 1
                // A drawn row always has words in it.
                guard case .string(let headline)? = fields["headline"] else {
                    Issue.record("\(state.stateName) reported no headline")
                    continue
                }
                #expect(!headline.isEmpty, "\(state.stateName) draws an empty row")
            } else {
                hidden += 1
                // And a hidden row is EMPTY — so the two are distinguishable in
                // both directions, not just by the flag.
                #expect(fields["headline"] == .string(""), "\(state.stateName)")
                #expect(fields["detail"] == .string(""), "\(state.stateName)")
            }
        }
        // Partition, counted: exactly one state hides the row.
        #expect(drawn == 3)
        #expect(hidden == 1)
    }

    // MARK: - M26 — the probe must name WHERE its width came from

    /// ⚠️ THE ONE LEG THAT PROTECTS A SURFACE NO SWIFT TEST CAN SEE.
    /// `DAWApp` is the sole `.executableTarget` and has no test target, so
    /// nothing here can observe `EQCurveEditor` drawing or `DAWProApp` building
    /// the payload. A staging gate is the only instrument on that path — and a
    /// gate that asserts "x is consistent with the `width` the probe reports"
    /// is SELF-CONSISTENT AND BLIND if the probe picked that width itself from
    /// a layout constant while the Canvas drew from its measured `size.width`.
    /// Naming the provenance is what makes the fallback assertable: a gate can
    /// require `measured` and redden when the view stops reporting geometry.
    @Test("The probe names its width's provenance, and the two are distinguishable")
    func probeNamesWhetherItsWidthWasMeasuredOrAssumed() {
        let guide = EQInstrumentGuide.family(.electricBass, source: .gmProgram)
        let measured = Dictionary(uniqueKeysWithValues:
            guide.probeFields(width: 528, widthSource: .measured))
        let assumed = Dictionary(uniqueKeysWithValues:
            guide.probeFields(width: 528, widthSource: .layoutConstant))
        #expect(measured["widthSource"] == .string("measured"))
        #expect(assumed["widthSource"] == .string("layoutConstant"))
        // DISTINGUISHABLE: the two payloads differ in exactly the provenance
        // field and nowhere else, so the flag cannot be inferred from the
        // numbers — a gate has to read it.
        #expect(measured["width"] == assumed["width"])
        #expect(measured["fundamentalX"] == assumed["fundamentalX"])
        #expect(measured["widthSource"] != assumed["widthSource"])
        // Both raw values are stable wire strings; a rename breaks the gate
        // loudly rather than turning every `measured` assertion vacuous.
        #expect(EQInstrumentGuide.WidthSource.allCases.map(\.rawValue).sorted()
                == ["layoutConstant", "measured"])
    }
}
