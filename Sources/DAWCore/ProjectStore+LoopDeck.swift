import Foundation

/// The geometry of ONE loop-deck pass, frozen at record start.
///
/// ⚠️ **`cycleBeats` IS NOT IN HERE, AND THAT IS DELIBERATE.** Everything a
/// take must not have moved under it — which layer, which track, what the pass
/// means, where the capture window opened — is frozen. The loop LENGTH is
/// read live at landing, because in press-to-end mode the length is not known
/// until the performer ends the first pass, which happens strictly after this
/// window is built. Freezing a length that did not exist yet would freeze `nil`.
public struct DeckTakeWindow: Sendable, Equatable {
    /// Identifies this pass, so a completion that arrives after the deck moved
    /// on can tell it is stale.
    public var passID: UUID
    public var layerID: UUID
    public var trackID: UUID
    public var mode: LoopLayerMode
    /// The quantized launch boundary — material before it is not this layer's.
    public var launchBeat: Double
    /// True when this pass created its layer (so a peel removes the layer).
    public var createdLayer: Bool
}

/// What `looper.undoLayer` actually did, so a caller can tell a peeled overdub
/// from a removed layer without guessing.
public struct LoopLayerPeel: Codable, Sendable, Equatable {
    public var layerID: UUID
    public var trackID: UUID
    /// True when the whole layer was removed (the peeled pass had created it).
    public var removedLayer: Bool
    /// Notes remaining in the layer's cycle after the peel.
    public var remainingNotes: Int
    public var takeNumber: Int

    /// ⚠️ Spelled `trackId`/`layerId` ON THE WIRE, matching the case every
    /// request param in `Commands.swift` already uses. Swift's default keys
    /// would emit `trackID`, so a caller that read `trackId` from the params it
    /// sent would get `nil` back from the response — a silent mismatch on a
    /// value nothing else in the payload could contradict.
    private enum CodingKeys: String, CodingKey {
        case layerID = "layerId"
        case trackID = "trackId"
        case removedLayer, remainingNotes, takeNumber
    }
}

/// The deck as a caller sees it: the model plus the derived lamp state, so the
/// wire and the view read ONE answer rather than each deriving their own.
public struct LoopDeckStatus: Codable, Sendable, Equatable {
    public struct Lamp: Codable, Sendable, Equatable {
        public var layerID: UUID
        public var trackID: UUID
        public var trackName: String
        public var ordinal: Int
        public var state: LoopLayerState
        public var noteCount: Int
        public var isMuted: Bool

        /// See `LoopLayerPeel.CodingKeys` — `trackId`/`layerId` on the wire.
        private enum CodingKeys: String, CodingKey {
            case layerID = "layerId"
            case trackID = "trackId"
            case trackName, ordinal, state, noteCount, isMuted
        }
    }
    public var originBeat: Double
    public var cycleBeats: Double?
    public var beatsPerBar: Double
    public var lengthMode: LoopLengthMode
    public var quantize: LoopLaunchQuantize
    public var defaultMode: LoopLayerMode
    public var spanCycles: Int
    /// Which cycle the playhead is in right now (0-based).
    public var currentCycle: Int
    /// How far through that cycle the playhead is, 0..<1. The deck strip's
    /// sweep — a moving light, not a number to read.
    public var cyclePhase: Double
    public var lamps: [Lamp]
    /// The beat the queued/rolling pass opens on, when there is one.
    public var pendingLaunchBeat: Double?
    public var pendingPhase: LoopPendingLayer.Phase?
    public var canPeel: Bool
}

@MainActor
extension ProjectStore {

    // MARK: - Session lifecycle

    /// LIVE LOOPING (m34-h-1) — open a loop-deck session.
    ///
    /// - Parameter bars: the loop length in bars, or nil for **press-to-end**,
    ///   where the first layer's own length decides it (rounded to the nearest
    ///   whole bar so an off-grid loop is unrepresentable).
    ///
    /// ⭐ **THE DEFAULT IS FIXED BARS, AND THE RESEARCH IS EXPLICIT ABOUT WHY**:
    /// with a bar count you cannot pick a bad length, because you never pick a
    /// length at all. Press-to-end is offered because RC-505 AUTO and Ableton's
    /// free record both ship it and some performers think in phrases, not bars.
    ///
    /// Cycle 0 is provisionally the bar line at or before the playhead; the
    /// FIRST layer's launch boundary then becomes the real origin, so a
    /// performer who opens the deck and then waits three bars before playing
    /// gets a loop that starts where they played, not where they pressed.
    @discardableResult
    public func beginLoopDeck(bars: Int? = nil,
                              quantize: LoopLaunchQuantize = .cycle,
                              mode: LoopLayerMode = .overdub,
                              horizonCycles: Int? = nil) throws -> LoopDeckStatus {
        guard loopDeck == nil else {
            throw ProjectError.transportBusy(
                "a live-looping session is already open — end it with looper.end first")
        }
        guard !transport.isRecording else {
            throw ProjectError.transportBusy(
                "cannot open a live-looping session while recording — stop the take first")
        }
        // Refused up front rather than at the first arm, because the refusal is
        // structural and the teaching error is worth reading BEFORE a performer
        // has committed to a session. `ProjectStore.recordLayer()` and
        // `AudioEngine.startTakeInPlayback` both refuse a layer under a loop;
        // a deck loops by TILING A CLIP, not by wrapping the transport.
        guard !transport.isLoopEnabled else {
            throw ProjectError.invalidLoopRange(
                "cannot open a live-looping session while the transport loop is enabled — "
                + "disable it with transport.setLoop. A loop deck repeats by tiling each "
                + "layer's clip forward on a LINEAR timeline; the transport loop is the "
                + "take-comping feature (several attempts at one part), which is the "
                + "opposite of stacking layers.")
        }
        if let bars, bars < 1 || bars > 64 {
            throw ProjectError.invalidLoopRange(
                "loop length must be 1...64 bars — got \(bars)")
        }
        let beatsPerBar = Double(transport.meterMap.beatsPerBar(atBeat: transport.positionBeats))
        // Floor to the bar line at or before the playhead: an origin behind the
        // playhead can always be reached forward, one ahead of it cannot.
        let origin = (transport.positionBeats / beatsPerBar).rounded(.down) * beatsPerBar
        loopDeck = LoopDeck(
            originBeat: max(0, origin),
            cycleBeats: bars.map { Double($0) * beatsPerBar },
            beatsPerBar: beatsPerBar,
            lengthMode: bars == nil ? .pressToEnd : .fixedBars,
            quantize: quantize,
            defaultMode: mode,
            horizonCycles: max(2, horizonCycles ?? LoopDeckMath.defaultHorizonCycles))
        // The content-end bound is suspended while a deck is open
        // (`currentEndStopBound`), so it must be recomputed the moment the deck
        // appears — otherwise a bound armed before this call would still stop
        // the music at the old content end.
        refreshEndStopForLoopDeck()
        return loopDeckStatus!
    }

    /// Closes the session. The layers stay: they are ordinary clips on ordinary
    /// tracks, which is the point of the linear route.
    public func endLoopDeck() throws {
        guard loopDeck != nil else {
            throw ProjectError.transportBusy("no live-looping session is open")
        }
        cancelQueuedDeckPass()
        loopDeck = nil
        // Re-arms the content-end bound the open session suspended.
        refreshEndStopForLoopDeck()
    }

    /// The deck plus its derived lamp states, or nil when no session is open.
    public var loopDeckStatus: LoopDeckStatus? {
        guard let deck = loopDeck else { return nil }
        let cycleBeats = deck.cycleBeats
        let cycle = cycleBeats.map {
            LoopDeckMath.cycleIndex(ofBeat: transport.positionBeats,
                                    origin: deck.originBeat, cycleBeats: $0)
        } ?? 0
        var phase = 0.0
        if let cycleBeats, cycleBeats > 0 {
            let raw = (transport.positionBeats - deck.originBeat)
                .truncatingRemainder(dividingBy: cycleBeats)
            phase = min(0.999_999, max(0, (raw < 0 ? raw + cycleBeats : raw) / cycleBeats))
        }
        let lamps = deck.layers.sorted { $0.ordinal < $1.ordinal }.map { layer in
            LoopDeckStatus.Lamp(
                layerID: layer.id,
                trackID: layer.trackID,
                trackName: tracks.first { $0.id == layer.trackID }?.name ?? "—",
                ordinal: layer.ordinal,
                state: deck.state(of: layer),
                noteCount: layer.cycle.count,
                isMuted: layer.isMuted)
        }
        return LoopDeckStatus(
            originBeat: deck.originBeat,
            cycleBeats: cycleBeats,
            beatsPerBar: deck.beatsPerBar,
            lengthMode: deck.lengthMode,
            quantize: deck.quantize,
            defaultMode: deck.defaultMode,
            spanCycles: deck.spanCycles,
            currentCycle: cycle,
            cyclePhase: phase,
            lamps: lamps,
            pendingLaunchBeat: deck.pending?.launchBeat,
            pendingPhase: deck.pending?.phase,
            canPeel: !deck.passHistory.isEmpty)
    }

    // MARK: - Arming a layer

    /// Arms the next layer on `trackID`, to open at the next quantize boundary.
    ///
    /// ⭐ **THE PRESS DOES NOT START THE RECORDING — THE BOUNDARY DOES.** The
    /// lamp flashes `queued` until then, which is the state the research
    /// singles out as mattering most: a press that visibly did nothing would
    /// read as ignored and invite a second press.
    ///
    /// ⭐ **"RECORD AGAIN" ON A TRACK THAT ALREADY HAS A LAYER MEANS OVERDUB**,
    /// per rule ③ — pass `mode: .replace` for the variant. Both are one verb.
    @discardableResult
    public func armLoopLayer(trackID: UUID, mode: LoopLayerMode? = nil) throws -> LoopDeckStatus {
        guard var deck = loopDeck else {
            throw ProjectError.transportBusy(
                "no live-looping session is open — start one with looper.begin")
        }
        guard deck.pending == nil else {
            throw ProjectError.transportBusy(
                "a layer is already armed or recording — finish it with looper.finishLayer "
                + "(or take it back with looper.undoLayer)")
        }
        // The same teaching error `recordLayer()` gives, and for the same
        // reason: a deck layer joins playback that is already running.
        guard transport.isPlaying else {
            throw ProjectError.transportBusy(
                "nothing is playing — press play first, then arm a layer")
        }
        guard !transport.isRecording else {
            throw ProjectError.transportBusy(
                "a take is already rolling — finish it before arming a deck layer")
        }
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        // v1 refusal, stated rather than silently mis-landing: a layer repeats
        // by TILING its notes inside one clip, and a recorded waveform cannot
        // be tiled that way.
        guard tracks[index].kind == .instrument else {
            throw ProjectError.trackKindUnsupported(tracks[index].kind)
        }

        let plan = LoopDeckScheduler.plan(deck: deck, playheadBeat: transport.positionBeats)
        // ⭐ THE FIRST LAYER DEFINES CYCLE 0. `begin` could only guess (the bar
        // line under the playhead at the time); the first launch boundary is
        // where the music actually starts.
        if deck.layers.isEmpty && deck.passHistory.isEmpty {
            deck.originBeat = plan.launchBeat
        }
        let passMode = mode ?? deck.defaultMode
        let existing = deck.layer(onTrack: trackID)
        let layerID: UUID
        let created: Bool
        if let existing {
            layerID = existing.id
            created = false
        } else {
            let layer = LoopLayer(trackID: trackID,
                                  ordinal: (deck.layers.map(\.ordinal).max() ?? 0) + 1)
            deck.layers.append(layer)
            layerID = layer.id
            created = true
        }
        deck.pending = LoopPendingLayer(
            trackID: trackID,
            layerID: layerID,
            mode: passMode,
            launchBeat: plan.launchBeat,
            armBeat: plan.armBeat,
            closeBeat: nil,
            phase: .queued,
            definesLength: deck.cycleBeats == nil,
            isNewLayer: created)
        loopDeck = deck
        // Exactly one track armed, in ONE journal entry: `recordLayer()` records
        // onto EVERY armed instrument track, so a stale arm elsewhere would
        // silently capture the same performance onto two layers.
        applyExclusiveArm(trackID: trackID)
        // An arm pressed inside the pre-roll window is already due; without this
        // the launch would wait for the next ~33 ms tick for no reason.
        refreshLoopDeck()
        return loopDeckStatus!
    }

    /// Ends the rolling layer.
    ///
    /// - Parameter immediate: close at the press instead of at the next cycle
    ///   boundary. The default (`false`) keeps a pass a whole number of cycles
    ///   long, which is what a looper does; `immediate` exists for a performer
    ///   who wants out now and is going to peel the layer anyway.
    ///
    /// In **press-to-end** mode this is the press that DECIDES THE LOOP LENGTH:
    /// the captured span is rounded to the nearest whole bar and becomes the
    /// cycle for this and every later layer.
    @discardableResult
    public func finishLoopLayer(immediate: Bool = false) throws -> LoopDeckStatus {
        guard var deck = loopDeck else {
            throw ProjectError.transportBusy(
                "no live-looping session is open — start one with looper.begin")
        }
        guard var pending = deck.pending else {
            throw ProjectError.transportBusy(
                "no layer is armed or recording — arm one with looper.armLayer")
        }
        switch pending.phase {
        case .queued:
            // It never opened, so there is nothing to close: unwind the arm
            // instead of closing a take that does not exist.
            cancelQueuedDeckPass()
            return loopDeckStatus!
        case .closing:
            throw ProjectError.transportBusy(
                "this layer is already closing — it ends at beat "
                + String(format: "%.3f", pending.closeBeat ?? 0))
        case .recording:
            break
        }
        let now = transport.positionBeats
        if pending.definesLength, deck.cycleBeats == nil {
            let captured = max(0, now - pending.launchBeat)
            let length = LoopDeckMath.pressToEndCycleBeats(capturedBeats: captured,
                                                           beatsPerBar: deck.beatsPerBar)
            deck.cycleBeats = length
            pending.closeBeat = pending.launchBeat + length
        } else if immediate {
            pending.closeBeat = now
        } else {
            let grid = deck.cycleBeats ?? deck.beatsPerBar
            pending.closeBeat = LoopDeckMath.boundary(atOrAfter: now,
                                                      origin: deck.originBeat,
                                                      grid: grid)
        }
        pending.phase = .closing
        deck.pending = pending
        loopDeck = deck
        refreshLoopDeck()
        return loopDeckStatus!
    }

    // MARK: - Peel (undo the last layer)

    /// ⭐⭐ **THE MOST-USED CONTROL IN LIVE LOOPING — AND IT MUST NOT STOP THE
    /// MUSIC.** Pops the most recent landed pass: a pass that created its layer
    /// removes the layer and its clip; a pass that overdubbed restores the
    /// cycle as it stood before. Repeatable, so three bad passes take three
    /// presses (Loopy Pro's "Peel" is explicitly multi-level).
    ///
    /// ⛔ **THIS IS NOT `undo()`.** The general journal is refused mid-take,
    /// carries every other edit in the session, and would reverse "whatever
    /// happened last" — a fader move, a track rename. Rule ④ of the
    /// Boss/Ableton/Loopy convergence is that this control is scoped to ONE
    /// layer and is its own gesture.
    @discardableResult
    public func peelLoopLayer() throws -> LoopLayerPeel {
        guard var deck = loopDeck else {
            throw ProjectError.transportBusy(
                "no live-looping session is open — start one with looper.begin")
        }
        guard let record = deck.passHistory.last else {
            throw ProjectError.nothingToUndo
        }
        guard let layerIndex = deck.layers.firstIndex(where: { $0.id == record.layerID }) else {
            // The layer vanished under a general undo. Drop the stale record
            // rather than wedging, and let the performer press again.
            deck.passHistory.removeLast()
            loopDeck = deck
            throw ProjectError.nothingToUndo
        }
        deck.passHistory.removeLast()
        let layer = deck.layers[layerIndex]
        let removedLayer = record.createdLayer
        var remaining = 0
        if removedLayer {
            deck.layers.remove(at: layerIndex)
        } else {
            deck.layers[layerIndex].cycle = record.previousCycle ?? []
            remaining = deck.layers[layerIndex].cycle.count
        }
        loopDeck = deck
        let clipID = layer.clipID
        let trackID = layer.trackID
        performEdit("Peel loop layer \(layer.ordinal)") {
            if removedLayer {
                if let clipID, let ti = tracks.firstIndex(where: { $0.id == trackID }) {
                    tracks[ti].clips.removeAll { $0.id == clipID }
                }
            }
            materializeDeckLayers(span: loopDeck?.spanCycles ?? 0)
            engine?.tracksDidChange(tracks)
        }
        return LoopLayerPeel(layerID: layer.id, trackID: trackID,
                             removedLayer: removedLayer, remainingNotes: remaining,
                             takeNumber: record.takeNumber)
    }

    /// Silences or un-silences one layer without touching its material — the
    /// "drop the drums for a chorus" control. Applied to the layer's clip gain
    /// so it is a mixer-shaped change, not a structural one.
    @discardableResult
    public func setLoopLayerMuted(layerID: UUID, muted: Bool) throws -> LoopDeckStatus {
        guard var deck = loopDeck else {
            throw ProjectError.transportBusy(
                "no live-looping session is open — start one with looper.begin")
        }
        guard let index = deck.layers.firstIndex(where: { $0.id == layerID }) else {
            throw ProjectError.nothingToUndo
        }
        deck.layers[index].isMuted = muted
        loopDeck = deck
        let layer = deck.layers[index]
        performEdit("\(muted ? "Mute" : "Unmute") loop layer \(layer.ordinal)") {
            materializeDeckLayers(span: deck.spanCycles)
            engine?.tracksDidChange(tracks)
        }
        return loopDeckStatus!
    }

    // MARK: - The tick driver

    /// Applies whatever the deck's schedule says is due at the current
    /// playhead. Driven from BOTH transports — the engine's playhead handler
    /// and the headless ticker — so a wire session and a unit test see one
    /// behaviour rather than two that agree by luck.
    ///
    /// ⚠️ **THE WORK IS DISPATCHED ON A HOPPED MAIN-ACTOR TASK, AND THAT IS A
    /// CORRECTNESS REQUIREMENT, NOT TIDINESS.** The engine's playhead handler
    /// documents that it "NEVER calls back into the engine", and `AudioEngine`
    /// is `@MainActor`: firing `recordLayer()` straight from that closure would
    /// re-enter the engine synchronously while it is mid-playhead-tick. The
    /// decision made HERE is pure arithmetic; only the hop touches the engine.
    public func refreshLoopDeck() {
        guard let deck = loopDeck, !deck.launchInFlight else { return }
        guard !LoopDeckScheduler.actions(deck: deck,
                                         playheadBeat: transport.positionBeats).isEmpty else {
            return
        }
        loopDeck?.launchInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.loopDeck?.launchInFlight = false }
            self.applyDueDeckActions()
        }
    }

    /// ⚠️ **INTERNAL, AND THE REASON IS TESTABILITY OF THE HOP.**
    /// `refreshLoopDeck()` defers this onto a fresh main-actor `Task`, which a
    /// synchronous test cannot observe without a wall-clock wait — and a
    /// wall-clock wait is exactly the shape that retired a test on m34-a-2 when
    /// the full suite ran under load. Tests call THIS to apply what is due, and
    /// pin the hop itself separately by its observable consequence.
    func applyDueDeckActions() {
        guard let deck = loopDeck else { return }
        for action in LoopDeckScheduler.actions(deck: deck,
                                                playheadBeat: transport.positionBeats) {
            switch action {
            case .fireArm: fireDeckArm()
            case .fireClose: fireDeckClose()
            case .extendSpan(let cycles): extendDeckSpan(to: cycles)
            }
        }
    }

    private func fireDeckArm() {
        guard var deck = loopDeck, var pending = deck.pending, pending.phase == .queued else {
            return
        }
        let window = DeckTakeWindow(passID: UUID(),
                                    layerID: pending.layerID,
                                    trackID: pending.trackID,
                                    mode: pending.mode,
                                    launchBeat: pending.launchBeat,
                                    createdLayer: pending.isNewLayer)
        do {
            try startLayerTake(deckWindow: window)
        } catch {
            // The launch failed (nothing armed, permission, engine gone). Unwind
            // the pass so the deck is armable again instead of stuck flashing.
            noteRecordingError((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription)
            cancelQueuedDeckPass()
            return
        }
        pending.phase = .recording
        pending.passID = window.passID
        deck.pending = pending
        loopDeck = deck
    }

    private func fireDeckClose() {
        guard loopDeck?.pending?.phase == .closing else { return }
        // The landing is asynchronous: `landDeckLayer` resolves the pass when
        // the take result arrives. A failure here leaves the pass rolling, which
        // is recoverable (`looper.finishLayer` again, or `transport.stop`).
        try? finishLayer()
    }

    private func extendDeckSpan(to cycles: Int) {
        guard let deck = loopDeck, deck.spanCycles < cycles, deck.cycleBeats != nil else { return }
        loopDeck?.spanCycles = cycles
        performEdit("Extend loop runway") {
            materializeDeckLayers(span: cycles)
            engine?.tracksDidChange(tracks)
        }
    }

    // MARK: - Landing

    /// Lands a deck LAYER take: fold the capture into one cycle, merge it onto
    /// the layer, and tile every layer forward across the deck's span — all in
    /// ONE `performEdit`, so a layer is one journal entry exactly like an
    /// ordinary take.
    func landDeckLayer(_ take: TakeResult,
                       window: DeckTakeWindow,
                       instrumentTrackIDs: [UUID],
                       recordStartBeats: Double,
                       takeNumber: Int) {
        guard var deck = loopDeck else { return }
        // Stale completion: the deck was ended, peeled or re-armed while this
        // take was in flight. Landing it would put material on a layer the
        // performer has already taken back.
        guard let pending = deck.pending, pending.passID == window.passID else { return }
        guard let cycleBeats = deck.cycleBeats, cycleBeats > 0 else {
            abandonDeckPass()
            noteRecordingError("loop layer discarded — the session has no loop length yet")
            return
        }
        guard instrumentTrackIDs.contains(window.trackID),
              let layerIndex = deck.layers.firstIndex(where: { $0.id == window.layerID }) else {
            abandonDeckPass()
            return
        }
        let captured = take.midi?.notes ?? []
        let incoming = LoopDeckMath.fold(captured,
                                         clipStartBeat: recordStartBeats,
                                         captureOpenBeat: window.launchBeat,
                                         originBeat: deck.originBeat,
                                         cycleBeats: cycleBeats)
        guard !incoming.isEmpty else {
            // ⭐ NOTHING WAS PLAYED INSIDE THE WINDOW. A layer this pass created
            // is removed rather than left as an empty lamp promising material
            // that is not coming — the same rule `finishTake` applies to an
            // empty ordinary take, which it discards outright.
            if window.createdLayer { deck.layers.remove(at: layerIndex) }
            deck.pending = nil
            loopDeck = deck
            noteRecordingError("empty loop layer discarded — no notes inside the loop window")
            return
        }
        let previous = deck.layers[layerIndex].cycle
        deck.layers[layerIndex].cycle = LoopDeckMath.merge(existingCycle: previous,
                                                           incomingCycle: incoming,
                                                           mode: window.mode)
        deck.passHistory.append(LoopPassRecord(layerID: window.layerID,
                                               createdLayer: window.createdLayer,
                                               previousCycle: window.createdLayer ? nil : previous,
                                               takeNumber: takeNumber))
        // The runway: enough material ahead of the playhead that the performer
        // never plays off the end of it. Computed from where the playhead IS,
        // not from cycle 0, so a session that has been running a while extends
        // forward rather than re-tiling from the start.
        let here = LoopDeckMath.cycleIndex(ofBeat: transport.positionBeats,
                                           origin: deck.originBeat, cycleBeats: cycleBeats)
        deck.spanCycles = max(deck.spanCycles, here + deck.horizonCycles)
        deck.pending = nil
        loopDeck = deck
        performEdit("Record Take \(takeNumber)") {
            materializeDeckLayers(span: loopDeck?.spanCycles ?? 0)
            engine?.tracksDidChange(tracks)
        }
    }

    /// Writes every layer's clip from its cycle: ONE clip per layer, starting at
    /// the deck origin, `span` cycles long, notes tiled.
    ///
    /// ⚠️ **MUST BE CALLED INSIDE A `performEdit`** — it mutates `tracks`
    /// directly so that a landing, a peel and a runway extension are each ONE
    /// journal entry rather than one per layer.
    private func materializeDeckLayers(span: Int) {
        guard var deck = loopDeck, let cycleBeats = deck.cycleBeats, span > 0 else { return }
        let length = Double(span) * cycleBeats
        for (i, layer) in deck.layers.enumerated() {
            guard let ti = tracks.firstIndex(where: { $0.id == layer.trackID }) else { continue }
            let notes = layer.isMuted
                ? []
                : LoopDeckMath.tile(layer.cycle, cycles: span, cycleBeats: cycleBeats)
            if let clipID = layer.clipID,
               let ci = tracks[ti].clips.firstIndex(where: { $0.id == clipID }) {
                tracks[ti].clips[ci].notes = notes
                tracks[ti].clips[ci].startBeat = deck.originBeat
                tracks[ti].clips[ci].lengthBeats = length
            } else {
                let clip = Clip(name: "\(tracks[ti].name) Loop \(layer.ordinal)",
                                startBeat: deck.originBeat,
                                lengthBeats: length,
                                notes: notes)
                tracks[ti].clips.append(clip)
                deck.layers[i].clipID = clip.id
            }
        }
        loopDeck = deck
    }

    // MARK: - Unwinding

    /// Drops a pass that can no longer land (a failed take, a failed launch).
    /// Removes the layer too when the pass had just created it, so a failure
    /// leaves no empty lamp behind.
    func abandonDeckPass() {
        guard var deck = loopDeck, let pending = deck.pending else { return }
        if pending.isNewLayer, let index = deck.layers.firstIndex(where: { $0.id == pending.layerID }),
           deck.layers[index].cycle.isEmpty {
            deck.layers.remove(at: index)
        }
        deck.pending = nil
        deck.launchInFlight = false
        loopDeck = deck
    }

    /// Cancels a pass that is still QUEUED — it never opened, so there is no
    /// take to close. A rolling pass is left alone: its take is real and must
    /// land or fail on its own path.
    func cancelQueuedDeckPass() {
        guard let pending = loopDeck?.pending, pending.phase == .queued else { return }
        abandonDeckPass()
    }

    /// `refreshEndStop()` behind a name the extension can reach — the deck
    /// opening or closing changes the answer (`currentEndStopBound` suspends the
    /// bound while a session is open), and both edges must recompute it.
    private func refreshEndStopForLoopDeck() {
        // ⚠️ **NOT `performEdit` — that was the first version and it was
        // WRONG.** Opening or closing a deck changes no project content, but
        // `performEdit` marks the project dirty UNCONDITIONALLY, so
        // `looper.begin` on a freshly-saved project raised an unsaved-changes
        // prompt for a document nobody had edited. `refreshEndStopAfterModeChange`
        // reaches the SAME single `refreshEndStop()` without the document
        // semantics; the bound is still computed in exactly one place.
        refreshEndStopAfterModeChange()
    }

    /// Arms exactly `trackID` and disarms every other track, in ONE edit.
    private func applyExclusiveArm(trackID: UUID) {
        let needsChange = tracks.contains { ($0.id == trackID) != $0.isArmed
            && ($0.kind == .instrument || $0.kind == .audio) }
        guard needsChange else { return }
        performEdit("Arm loop layer") {
            for i in tracks.indices where tracks[i].kind == .instrument || tracks[i].kind == .audio {
                tracks[i].isArmed = (tracks[i].id == trackID)
            }
            engine?.tracksDidChange(tracks)
        }
        try? engine?.prepare()
    }
}
