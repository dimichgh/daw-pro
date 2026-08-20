import Foundation
import Testing
@testable import DAWCore

/// The m28-knob CC→target table.
///
/// ⭐ **NOT `@MainActor`, deliberately.** `MainActorOccupancySiteTests`' Leg C
/// caps the tree's `@MainActor` `@Suite` count at 330 and the tree is AT 330 —
/// so the table was designed as a pure value type precisely so its rules could
/// be asserted without buying a slot. Everything that genuinely needs the main
/// actor (the store controller, the pad adapter) is folded into an existing
/// suite instead.
///
/// ⛔ **NO HARDWARE, EVER.** Every event here is synthesised. A gate that needs
/// a physical knob is a flake generator and would also mean touching the user's
/// MIDI devices, which is forbidden outright.
@Suite struct MIDIControlMapTests {

    private func event(controller: Int, value: Int, channel: Int = 0,
                       source: Int32 = 77) -> MIDIControlChangeEvent {
        MIDIControlChangeEvent(sourceID: source, channel: channel,
                               controller: controller, value: value)
    }

    // MARK: - The value contract

    /// ⛔ **`/ 127`, NOT `/ 128`.** A radius that could never quite reach 1 would
    /// be a control with an unreachable end — the dot would stop just short of
    /// the rim forever and nothing would say why.
    @Test func aControllerAtItsMaximumIsExactlyOneAndAtItsMinimumExactlyZero() {
        #expect(event(controller: 74, value: 127).normalized == 1.0)
        #expect(event(controller: 74, value: 0).normalized == 0.0)
        // And the midpoint is where a centre-detented knob sits.
        #expect(abs(event(controller: 74, value: 64).normalized - 0.5039) < 0.001)
    }

    @Test func anInvertedBindingFlipsTheSweepAndOnlyTheSweep() {
        let plain = MIDIControlBinding(target: .breathPadRadius, controller: 74)
        let flipped = MIDIControlBinding(target: .breathPadRadius, controller: 74,
                                         inverted: true)
        #expect(plain.value(for: event(controller: 74, value: 127)) == 1)
        #expect(flipped.value(for: event(controller: 74, value: 127)) == 0)
        #expect(flipped.value(for: event(controller: 74, value: 0)) == 1)
        // Inversion must not change WHICH events match.
        #expect(flipped.matches(event(controller: 74, value: 3)))
        #expect(!flipped.matches(event(controller: 75, value: 3)))
    }

    // MARK: - Filtering

    @Test func aBindingWithNoChannelIsOmniAndOneWithAChannelIsNot() {
        let omni = MIDIControlBinding(target: .breathPadAngle, controller: 74)
        #expect(omni.matches(event(controller: 74, value: 1, channel: 0)))
        #expect(omni.matches(event(controller: 74, value: 1, channel: 9)))

        let pinned = MIDIControlBinding(target: .breathPadAngle, controller: 74, channel: 9)
        #expect(!pinned.matches(event(controller: 74, value: 1, channel: 0)))
        #expect(pinned.matches(event(controller: 74, value: 1, channel: 9)))
    }

    /// Two controllers with the same CC number on the same knob is the common
    /// case, so a learned binding pins the DEVICE.
    @Test func aBindingWithASourceAcceptsOnlyThatDevice() {
        let pinned = MIDIControlBinding(target: .breathPadAngle, controller: 74, sourceID: 77)
        #expect(pinned.matches(event(controller: 74, value: 1, source: 77)))
        #expect(!pinned.matches(event(controller: 74, value: 1, source: 78)))
    }

    // MARK: - The table

    @Test func aTargetHasAtMostOneControlAndRebindingReplacesRatherThanAccumulates() {
        var map = MIDIControlMap()
        map.bind(MIDIControlBinding(target: .breathPadAngle, controller: 74))
        map.bind(MIDIControlBinding(target: .breathPadAngle, controller: 71))
        #expect(map.bindings.count == 1)
        #expect(map.binding(for: .breathPadAngle)?.controller == 71)

        // A different target coexists.
        map.bind(MIDIControlBinding(target: .breathPadRadius, controller: 74))
        #expect(map.bindings.count == 2)

        let removed = map.unbind(target: .breathPadAngle)
        let removedAgain = map.unbind(target: .breathPadAngle)
        #expect(removed)
        #expect(!removedAgain, "unbind is idempotent")
        #expect(map.bindings.map(\.target) == [.breathPadRadius])
    }

    /// One controller MAY drive several targets — that is a MACRO and it is
    /// deliberate, unlike two controllers fighting over one target.
    @Test func oneControllerMayDriveSeveralTargetsAtOnce() {
        var map = MIDIControlMap(bindings: [
            MIDIControlBinding(target: .breathPadAngle, controller: 74),
            MIDIControlBinding(target: .breathPadRadius, controller: 74),
        ])
        let out = map.ingest(event(controller: 74, value: 127))
        #expect(out.updates.count == 2)
        #expect(Set(out.updates.map(\.target)) == [.breathPadAngle, .breathPadRadius])
        #expect(out.updates.allSatisfy { $0.value == 1 })
    }

    @Test func anUnmappedControllerMovesNothing() {
        var map = MIDIControlMap(bindings: [
            MIDIControlBinding(target: .breathPadAngle, controller: 74),
        ])
        // ⚠️ Hoisted: `ingest` is `mutating`, and `#expect` evaluates its
        // argument inside a closure where the captured value is immutable.
        let out = map.ingest(event(controller: 11, value: 100))
        #expect(out.updates.isEmpty)
        // …but it is still SEEN. That is the whole diagnostic.
        #expect(map.lastEvent?.controller == 11)
    }

    // MARK: - Learn

    /// ⭐ Learn binds AND emits the same event's update. A knob that binds and
    /// then visibly does nothing until you turn it again is indistinguishable
    /// from a learn that failed.
    @Test func learnBindsTheFirstControllerSeenAndMovesTheTargetOnTheSameEvent() {
        var map = MIDIControlMap()
        map.armLearn(target: .breathPadAngle)
        #expect(map.isLearning)

        let out = map.ingest(event(controller: 74, value: 127, channel: 5, source: 42))
        #expect(out.learned?.target == .breathPadAngle)
        #expect(out.learned?.controller == 74)
        #expect(out.updates.map(\.value) == [1.0])
        #expect(!map.isLearning, "learn disarms itself once it has bound")

        // A SECOND controller does not steal the binding.
        let second = map.ingest(event(controller: 71, value: 10))
        #expect(second.learned == nil)
        #expect(map.binding(for: .breathPadAngle)?.controller == 74)
    }

    /// ⭐ The learn-time channel/source decision, asserted so it cannot drift:
    /// the DEVICE is pinned, the CHANNEL is not. Binding the channel is the
    /// classic MIDI-learn footgun — the user changes their controller's global
    /// channel and the mapping dies silently.
    @Test func learnPinsTheDeviceAndLeavesTheChannelOmni() {
        var map = MIDIControlMap()
        map.armLearn(target: .breathPadRadius)
        let learned = map.ingest(event(controller: 74, value: 64, channel: 5, source: 42)).learned
        #expect(learned?.sourceID == 42)
        #expect(learned?.channel == nil)

        // Same device, DIFFERENT channel: still steers.
        let otherChannel = map.ingest(event(controller: 74, value: 0, channel: 11, source: 42))
        #expect(otherChannel.updates.count == 1)
        // Different device: ignored.
        let otherDevice = map.ingest(event(controller: 74, value: 0, channel: 5, source: 43))
        #expect(otherDevice.updates.isEmpty)
    }

    @Test func cancellingLearnChangesNoBindings() {
        var map = MIDIControlMap(bindings: [
            MIDIControlBinding(target: .breathPadAngle, controller: 74),
        ])
        map.armLearn(target: .breathPadRadius)
        map.cancelLearn()
        #expect(!map.isLearning)
        let out = map.ingest(event(controller: 71, value: 5))
        #expect(out.learned == nil)
        #expect(map.bindings.count == 1)
        #expect(map.binding(for: .breathPadRadius) == nil)
    }

    /// `lastEvent` is the diagnostic that separates "your knob is not mapped"
    /// from "your knob is not sending" — two failures that look identical from
    /// the outside, and only one of which is our bug. Reading it must never
    /// consume the event.
    @Test func theLastSeenEventIsRecordedNonDestructivelyEvenWithAnEmptyTable() {
        var map = MIDIControlMap()
        #expect(map.lastEvent == nil, "nothing seen yet is distinct from nothing mapped")
        map.ingest(event(controller: 74, value: 3, channel: 2, source: 9))
        #expect(map.lastEvent?.controller == 74)
        #expect(map.lastEvent?.value == 3)
        // Reading it twice gives the same answer — it is not a queue.
        #expect(map.lastEvent == map.lastEvent)
        map.ingest(event(controller: 74, value: 4, channel: 2, source: 9))
        #expect(map.lastEvent?.value == 4)
    }

    // MARK: - A whole pump pass

    @Test func aBatchIngestPreservesArrivalOrderAcrossEveryEvent() {
        var map = MIDIControlMap(bindings: [
            MIDIControlBinding(target: .breathPadAngle, controller: 74),
        ])
        let out = map.ingest([
            event(controller: 74, value: 0),
            event(controller: 11, value: 60),     // unmapped, contributes nothing
            event(controller: 74, value: 127),
        ])
        #expect(out.updates.map(\.value) == [0, 1])
        #expect(map.lastEvent?.value == 127)
    }

    // MARK: - The catalogue

    /// Every target must be describable, because `midi.getControlMap` publishes
    /// the catalogue and an agent cannot discover what it may bind to otherwise.
    @Test func everyTargetCarriesABeginnerReadableNameAndSummary() {
        for target in MIDIControlTarget.allCases {
            #expect(!target.displayName.isEmpty)
            #expect(target.summary.count >= 40,
                    "\(target.rawValue) needs a real sentence, not a label")
            #expect(MIDIControlTarget(rawValue: target.rawValue) == target)
        }
        #expect(MIDIControlTarget.allCases.count == 2)
    }
}
