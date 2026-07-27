import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit
@testable import DAWCore

/// Unit tests for the arrange track-header context menu's headless ITEM LIST
/// (m23-m3b).
///
/// **Why the list is tested and not just the predicate.** A SwiftUI
/// `.contextMenu` is an AppKit popup that `debug.captureUI` cannot open, so
/// asserting `Track.canExportMIDI` alone would not DISCRIMINATE — the rule can be
/// perfectly right while the menu ignores it. The row therefore renders FROM
/// `TrackHeaderMenu.items` with no inline conditions of its own, and these tests
/// pin what that function returns.
///
/// **Every leg asserts the WHOLE list, in order, not `contains(.exportMIDI)`.**
/// The refactor from inline `if`s to a `ForEach` can silently drop or reorder an
/// item, and a present/absent leg on one action passes a model that lost
/// `rename` or `removeTrack` entirely.
@Suite("TrackHeaderMenu — the item list (m23-m3b)")
struct TrackHeaderMenuTests {

    /// Wide enough that the automation disclosure always rides inline, so the
    /// eligibility legs below vary ONE thing at a time.
    private static let wide: CGFloat = 400
    /// Below `TrackHeaderLayout.clipBadgeMinSidebarWidth` — the only width at
    /// which the automation item can appear (and only on a take-group row).
    private static let narrow: CGFloat = 250

    private func actions(_ track: Track,
                         sidebarWidth: CGFloat = TrackHeaderMenuTests.wide,
                         expanded: Bool = false) -> [TrackHeaderMenuAction] {
        TrackHeaderMenu.items(track: track,
                              sidebarWidth: sidebarWidth,
                              isAutomationExpanded: expanded).map(\.action)
    }

    private func takeGroupTrack(kind: TrackKind) -> Track {
        var track = Track(name: "Vox", kind: kind)
        var clip = Clip(name: "Take", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/tmp/take.caf"))
        clip.takeGroupID = UUID()
        track.takeGroups = [TakeGroup(name: "Vox Takes",
                                      lanes: [TakeLane(name: "Take 1", clip: clip)])]
        return track
    }

    // MARK: - Export MIDI eligibility (the m23-m3b deliverable)

    /// The four configurations that discriminate. `exportMIDI` and
    /// `bounceInPlace` have DIFFERENT rules, so a track showing one and not the
    /// other is the case that catches a copy-pasted condition.
    @Test("Export MIDI is offered on instrument tracks and on nothing else")
    func exportEligibility() {
        // Instrument straight to master: both export and bounce.
        let toMaster = Track(name: "Lead", kind: .instrument)
        #expect(actions(toMaster) == [.rename, .bounceInPlace, .exportMIDI, .removeTrack])

        // Instrument routed THROUGH a bus: still exports (MIDI has no routing),
        // but has no stem of its own, so bounce hides. The two rules part here.
        var routed = Track(name: "Lead", kind: .instrument)
        routed.outputBusID = UUID()
        #expect(actions(routed) == [.rename, .exportMIDI, .removeTrack])

        // A bus bounces but carries no notes — ABSENT, asserted as its own leg
        // (an always-present item passes a present-only test).
        let bus = Track(name: "Reverb", kind: .bus)
        #expect(actions(bus) == [.rename, .bounceInPlace, .removeTrack])

        // Audio, both routings — never exports.
        let audio = Track(name: "Vox", kind: .audio)
        #expect(actions(audio) == [.rename, .bounceInPlace, .removeTrack])
        var audioRouted = Track(name: "Vox", kind: .audio)
        audioRouted.outputBusID = UUID()
        #expect(actions(audioRouted) == [.rename, .removeTrack])
    }

    /// The menu's offer and the store's refusal read the SAME property, so this
    /// pins the seam rather than a second comparison that happens to agree.
    @Test("the item's presence tracks Track.canExportMIDI exactly")
    func presenceFollowsThePredicate() {
        for kind in TrackKind.allCases {
            let track = Track(name: "T", kind: kind)
            #expect(actions(track).contains(.exportMIDI) == track.canExportMIDI,
                    "kind \(kind.rawValue)")
        }
    }

    /// m23-m3c closed the OPEN m23-m3b filed: "Bounce in Place"'s condition was
    /// a byte-identical copy of `StemPlan`'s master-input filter. Both now read
    /// `Track.isMasterInput`, so this pins the seam rather than a second
    /// comparison that happens to agree today.
    @Test("m23-m3c: Bounce in Place's presence tracks Track.isMasterInput exactly")
    func bouncePresenceFollowsThePredicate() {
        let bus = Track(name: "Verb", kind: .bus)
        for kind in TrackKind.allCases {
            for routing in [nil, bus.id] {
                var track = Track(name: "T", kind: kind)
                track.outputBusID = routing
                #expect(actions(track).contains(.bounceInPlace) == track.isMasterInput,
                        "kind \(kind.rawValue), routed: \(routing != nil)")
            }
        }
    }

    @Test("the item is titled for a human and is not destructive")
    func exportItemShape() {
        let items = TrackHeaderMenu.items(track: Track(name: "Lead", kind: .instrument),
                                          sidebarWidth: Self.wide,
                                          isAutomationExpanded: false)
        let export = items.first { $0.action == .exportMIDI }
        #expect(export?.title == "Export MIDI…")
        #expect(export?.isDestructive == false)
        // Exactly one item wears the destructive role, and it is removal.
        #expect(items.filter(\.isDestructive).map(\.action) == [.removeTrack])
    }

    // MARK: - The items that gained assertability for free

    /// The automation item is the INVERSE of the inline disclosure rule — the
    /// sign is the easy thing to get wrong, and nothing else in the suite would
    /// catch a flip.
    @Test("Show/Hide Automation appears only where the inline disclosure folded away")
    func automationFold() {
        // No take groups → the disclosure rides inline at EVERY width, so the
        // menu never carries it.
        let plain = Track(name: "Lead", kind: .instrument)
        #expect(actions(plain, sidebarWidth: Self.narrow) == [.rename, .bounceInPlace,
                                                              .exportMIDI, .removeTrack])
        #expect(actions(plain, sidebarWidth: Self.wide) == [.rename, .bounceInPlace,
                                                            .exportMIDI, .removeTrack])

        // A take-group row at a WIDE sidebar still has the room — inline, so
        // still absent here.
        let heavy = takeGroupTrack(kind: .instrument)
        #expect(actions(heavy, sidebarWidth: Self.wide) == [.rename, .bounceInPlace,
                                                            .exportMIDI, .removeTrack])

        // Take groups + a NARROW sidebar is the one configuration that folds it
        // into the menu (m10-j), and it lands SECOND, before the exports.
        #expect(actions(heavy, sidebarWidth: Self.narrow)
                == [.rename, .toggleAutomation, .bounceInPlace, .exportMIDI, .removeTrack])

        // The threshold is the layout rule's, not a second constant.
        let t = TrackHeaderLayout.clipBadgeMinSidebarWidth
        #expect(actions(heavy, sidebarWidth: t).contains(.toggleAutomation) == false)
        #expect(actions(heavy, sidebarWidth: t - 1).contains(.toggleAutomation) == true)
    }

    /// The title carries state, which is why it lives in the model and not in
    /// the ViewBuilder.
    @Test("the automation item names the action it will perform, both ways")
    func automationTitleFlips() {
        let heavy = takeGroupTrack(kind: .audio)
        func title(expanded: Bool) -> String? {
            TrackHeaderMenu.items(track: heavy,
                                  sidebarWidth: Self.narrow,
                                  isAutomationExpanded: expanded)
                .first { $0.action == .toggleAutomation }?.title
        }
        #expect(title(expanded: false) == "Show Automation")
        #expect(title(expanded: true) == "Hide Automation")
        // Expansion changes the TITLE and nothing else about the list.
        #expect(actions(heavy, sidebarWidth: Self.narrow, expanded: true)
                == actions(heavy, sidebarWidth: Self.narrow, expanded: false))
    }

    /// Rename and Remove are unconditional; a list that lost one would still
    /// pass every eligibility leg above if those asserted membership only.
    @Test("Rename and Remove are offered on every kind, first and last")
    func alwaysPresentItems() {
        for kind in TrackKind.allCases {
            let list = actions(Track(name: "T", kind: kind))
            #expect(list.first == .rename, "kind \(kind.rawValue)")
            #expect(list.last == .removeTrack, "kind \(kind.rawValue)")
        }
    }

    /// Every action the view switches over must be reachable from SOME track,
    /// or the switch has a dead branch nobody will notice going stale.
    @Test("every action in the vocabulary is reachable")
    func vocabularyIsFullyReachable() {
        var seen: Set<TrackHeaderMenuAction> = []
        for kind in TrackKind.allCases {
            for width in [Self.narrow, Self.wide] {
                seen.formUnion(actions(Track(name: "T", kind: kind), sidebarWidth: width))
                seen.formUnion(actions(takeGroupTrack(kind: kind), sidebarWidth: width))
            }
        }
        #expect(seen == Set(TrackHeaderMenuAction.allCases))
    }
}
