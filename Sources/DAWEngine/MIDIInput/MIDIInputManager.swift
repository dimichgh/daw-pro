import CAtomics
import CoreMIDI
import DAWCore
import Foundation

/// The armed-instrument fanout the CoreMIDI receive thread reads: strong refs
/// to the armed instrument tracks' renderers (pinning every thru ring's
/// memory across renderer teardown) plus a self-owned buffer of opaque ring
/// pointers the receive thread borrows without retain/release. Published into
/// `MIDIInputRTContext.fanoutSlot` with the same publish / retire-bin-≥1 s
/// pattern as `InstrumentRenderer.publish` — the receive thread borrows for
/// microseconds, never retains.
final class LiveEventFanout: @unchecked Sendable {
    /// Strong refs — main-actor read (flush-on-unplug) and lifetime pinning.
    let renderers: [InstrumentRenderer]
    let ringCount: Int
    private let ringPointers: UnsafeMutablePointer<UnsafeMutableRawPointer>

    init(renderers: [InstrumentRenderer]) {
        self.renderers = renderers
        ringCount = renderers.count
        ringPointers = .allocate(capacity: max(1, renderers.count))
        for (index, renderer) in renderers.enumerated() {
            ringPointers[index] = Unmanaged.passUnretained(renderer.thruRing).toOpaque()
        }
    }

    deinit {
        ringPointers.deallocate()
    }

    /// RECEIVE THREAD: borrow ring `index` — no retain/release (the strong
    /// `renderers` refs keep the ring alive for this object's lifetime).
    @inline(__always)
    func ring(at index: Int) -> LiveEventRing {
        Unmanaged<LiveEventRing>.fromOpaque(ringPointers[index]).takeUnretainedValue()
    }
}

/// Everything the CoreMIDI receive block may touch — preallocated on the main
/// actor; the block captures exactly this one object.
///
/// RECEIVE-THREAD CONTRACT (normative, mirror of `renderQuantum`'s): the block
/// runs on CoreMIDI's realtime receive thread — one thread per port, so it is
/// the SINGLE PRODUCER for every ring. It may: walk `MIDIEventList` packets
/// with pointer math, call `MIDIUMPParser.parse`, call `mach_absolute_time()`
/// (not a syscall) when `packet.timeStamp == 0`, push to rings, and touch
/// CAtomics counters. It must NOT allocate, lock, retain/release, message
/// ObjC, or touch any actor.
final class MIDIInputRTContext: @unchecked Sendable {
    /// Published `LiveEventFanout` (+1 retained by the slot; the main actor's
    /// retire bin keeps displaced fanouts alive ≥ 1 s).
    let fanoutSlot: UnsafeMutablePointer<daw_atomic_ptr>
    /// Global capture ring, drained ~30 Hz on the main actor.
    let captureRing: LiveEventRing
    /// Monotonic count of accepted note events (surfaced as `midiEventCount`).
    let eventCounter: UnsafeMutablePointer<daw_atomic_u32>
    /// Count of ring-push failures across all rings (stuck-note diagnostics).
    let overflowCounter: UnsafeMutablePointer<daw_atomic_u32>

    /// Struct offsets, computed ONCE here (main actor) so the receive thread
    /// never touches key-path machinery.
    private let packetOffset: Int
    private let wordsOffset: Int

    init() {
        fanoutSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(fanoutSlot)
        captureRing = LiveEventRing(capacity: 4_096)
        eventCounter = .allocate(capacity: 1)
        daw_atomic_u32_store(eventCounter, 0)
        overflowCounter = .allocate(capacity: 1)
        daw_atomic_u32_store(overflowCounter, 0)
        // Fallbacks are the fixed C layouts (protocol Int32 + numPackets
        // UInt32 = 8; timeStamp UInt64 + wordCount UInt32 = 12).
        packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet) ?? 8
        wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) ?? 12
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(fanoutSlot, nil) {
            Unmanaged<LiveEventFanout>.fromOpaque(raw).release()
        }
        fanoutSlot.deallocate()
        eventCounter.deallocate()
        overflowCounter.deallocate()
    }

    /// RECEIVE THREAD: walk one event list, parse, fan out. Contract above.
    /// The walker advances by WHOLE UMP messages (see
    /// `MIDIUMPParser.wordCount`) so multi-word messages can't be misparsed.
    func receive(_ eventList: UnsafePointer<MIDIEventList>, sourceID: Int32) {
        var packet = (UnsafeRawPointer(eventList) + packetOffset)
            .assumingMemoryBound(to: MIDIEventPacket.self)
        for packetIndex in 0..<eventList.pointee.numPackets {
            let hostTime = packet.pointee.timeStamp == 0
                ? mach_absolute_time() : packet.pointee.timeStamp
            let wordCount = min(Int(packet.pointee.wordCount), 64)
            let words = (UnsafeRawPointer(packet) + wordsOffset)
                .assumingMemoryBound(to: UInt32.self)
            var index = 0
            while index < wordCount {
                let word = words[index]
                if let note = MIDIUMPParser.parse(word: word) {
                    deliver(note, hostTime: hostTime, sourceID: sourceID)
                }
                index += MIDIUMPParser.wordCount(messageType: word >> 28)
            }
            if packetIndex + 1 < eventList.pointee.numPackets {
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
        }
    }

    /// RECEIVE THREAD: one accepted note event → every fanout ring (armed
    /// instrument tracks) AND the capture ring, plus the counters. Counter
    /// writes are load→store — safe because this thread is the only writer.
    @inline(__always)
    private func deliver(_ note: MIDIUMPParser.LiveNote, hostTime: UInt64, sourceID: Int32) {
        let event = LiveMIDIEvent(hostTime: hostTime, source: sourceID, kind: note.kind,
                                  pitch: note.pitch, velocity: note.velocity,
                                  channel: note.channel)
        var dropped = false
        if let raw = daw_atomic_ptr_load(fanoutSlot) {
            let fanout = Unmanaged<LiveEventFanout>.fromOpaque(raw).takeUnretainedValue()
            for index in 0..<fanout.ringCount where !fanout.ring(at: index).push(event) {
                dropped = true
            }
        }
        if !captureRing.push(event) {
            dropped = true
        }
        daw_atomic_u32_store(eventCounter, daw_atomic_u32_load(eventCounter) &+ 1)
        if dropped {
            daw_atomic_u32_store(overflowCounter, daw_atomic_u32_load(overflowCounter) &+ 1)
        }
    }
}

/// Owns the CoreMIDI client + ONE UMP protocol-1.0 input port, omni-connected
/// to every online source (per-device selection is a later additive filter —
/// the event POD already carries the source's uniqueID). Engine-internal;
/// created LAZILY by `AudioEngine` on the first instrument-track arm or the
/// first `availableMIDIInputs()` call, disposed in `AudioEngine.shutdown()`.
///
/// Hot-plug: the notify block arrives on a CoreMIDI-owned thread and only
/// hops to the main actor; `setupChanged()` re-enumerates, reconnects, and
/// refreshes the cached `devices` list the snapshot reads.
@MainActor
final class MIDIInputManager {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    /// endpoint → uniqueID for every currently connected source.
    private var connected: [MIDIEndpointRef: Int32] = [:]
    /// Cached device list (snapshot + midi.listInputs read this; refreshed on
    /// every setup-changed notification).
    private(set) var devices: [MIDIInputDevice] = []

    let rtContext = MIDIInputRTContext()
    /// Current fanout — strong renderer refs, used to flush armed renderers
    /// when a source vanishes mid-note.
    private var currentFanout: LiveEventFanout?
    /// Displaced fanouts stay alive ≥ 1 s (the receive thread may still be
    /// borrowing the old pointer for microseconds after the exchange).
    private var retiredFanouts: [(fanout: LiveEventFanout, retiredAt: ContinuousClock.Instant)] = []

    private var drainTask: Task<Void, Never>?
    /// Active take's MIDI accumulator; nil between takes. Set by
    /// `AudioEngine.startTake`, fed by the ~30 Hz capture drain.
    var captureSession: MIDICaptureSession?

    /// Renderers currently receiving thru (for AudioEngine's flush diff).
    var fanoutRenderers: [InstrumentRenderer] { currentFanout?.renderers ?? [] }

    /// Monotonic count of accepted live note events.
    var eventCount: Int { Int(daw_atomic_u32_load(rtContext.eventCounter)) }

    /// Ring-push failures (diagnostics sibling of `eventCount`).
    var overflowCount: Int { Int(daw_atomic_u32_load(rtContext.overflowCounter)) }

    /// Creates the client + UMP input port and connects every online source.
    /// Returns false (fully torn down) when CoreMIDI is unavailable — e.g. a
    /// sandboxed CI runner with no MIDI server. Idempotent-ish: call once.
    func start() -> Bool {
        guard client == 0 else { return true }
        // @Sendable is load-bearing on BOTH blocks (same trap as the meter
        // taps): formed in a @MainActor method they would inherit main-actor
        // isolation, and the Swift runtime traps when CoreMIDI invokes them
        // on its own threads.
        var newClient = MIDIClientRef()
        let notifyStatus = MIDIClientCreateWithBlock("DAWPro" as CFString, &newClient) { @Sendable [weak self] _ in
            // CoreMIDI-owned thread — hop to the main actor, nothing else.
            Task { @MainActor in
                self?.setupChanged()
            }
        }
        guard notifyStatus == noErr else { return false }

        let context = rtContext
        var newPort = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithProtocol(
            newClient, "DAWPro In" as CFString, ._1_0, &newPort
        ) { @Sendable eventList, srcConnRefCon in
            // REALTIME receive thread — contract on MIDIInputRTContext. The
            // connRefCon IS the source's uniqueID (bit-cast, no allocation).
            let sourceID = Int32(truncatingIfNeeded: UInt(bitPattern: srcConnRefCon))
            context.receive(eventList, sourceID: sourceID)
        }
        guard portStatus == noErr else {
            MIDIClientDispose(newClient)
            return false
        }
        client = newClient
        port = newPort
        setupChanged()
        startDrain()
        return true
    }

    /// Re-enumerates sources: connects every online source not already
    /// connected, disconnects vanished/offline ones (flushing armed renderers
    /// — an unplug mid-note must not leave a stuck voice), and refreshes the
    /// cached device list.
    func setupChanged() {
        guard client != 0 else { return }
        var present = Set<MIDIEndpointRef>()
        var list: [MIDIInputDevice] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            let uniqueID = Self.integerProperty(source, kMIDIPropertyUniqueID)
            let isOnline = Self.integerProperty(source, kMIDIPropertyOffline) == 0
            let name = Self.stringProperty(source, kMIDIPropertyDisplayName)
                ?? "MIDI Source \(uniqueID)"
            var entity = MIDIEntityRef()
            let isVirtual = MIDIEndpointGetEntity(source, &entity) != noErr || entity == 0
            list.append(MIDIInputDevice(uniqueID: uniqueID, name: name,
                                        isVirtual: isVirtual, isOnline: isOnline))
            if isOnline {
                present.insert(source)
                if connected[source] == nil {
                    let refCon = UnsafeMutableRawPointer(
                        bitPattern: UInt(UInt32(bitPattern: uniqueID)))
                    if MIDIPortConnectSource(port, source, refCon) == noErr {
                        connected[source] = uniqueID
                    }
                }
            }
        }
        let vanished = connected.keys.filter { !present.contains($0) }
        if !vanished.isEmpty {
            for endpoint in vanished {
                MIDIPortDisconnectSource(port, endpoint)
                connected.removeValue(forKey: endpoint)
            }
            // A source vanishing mid-note can orphan a voice on every armed
            // renderer — all-notes-off across the fanout.
            for renderer in fanoutRenderers {
                renderer.requestFlush()
            }
        }
        devices = list
    }

    /// Publishes the armed-instrument thru fanout (empty → unpublish). Same
    /// retire-bin pattern as `InstrumentRenderer.publish`.
    func publishFanout(renderers: [InstrumentRenderer]) {
        let now = ContinuousClock.now
        let fanout = renderers.isEmpty ? nil : LiveEventFanout(renderers: renderers)
        currentFanout = fanout
        let newRaw = fanout.map { UnsafeMutableRawPointer(Unmanaged.passRetained($0).toOpaque()) }
        if let oldRaw = daw_atomic_ptr_exchange(rtContext.fanoutSlot, newRaw) {
            retiredFanouts.append(
                (Unmanaged<LiveEventFanout>.fromOpaque(oldRaw).takeRetainedValue(), now))
        }
        retiredFanouts.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    /// Pops everything queued in the capture ring into the active capture
    /// session (events between takes are discarded — the ring must never
    /// back up while idle). Also runs synchronously from `stopRecording` so
    /// tail events land before `finish`.
    func drainCaptureRing() {
        let ring = rtContext.captureRing
        if daw_atomic_u32_exchange(ring.droppedFlag, 0) == 1 {
            captureSession?.markDropped()
        }
        while let event = ring.pop() {
            captureSession?.ingest(event)
        }
    }

    /// ~30 Hz main-actor capture drain, alive as long as the client is.
    private func startDrain() {
        drainTask?.cancel()
        drainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                self.drainCaptureRing()
            }
        }
    }

    /// Tears down CoreMIDI (client dispose covers the port and connections)
    /// and the drain. Called from `AudioEngine.shutdown()`.
    func dispose() {
        drainTask?.cancel()
        drainTask = nil
        captureSession = nil
        publishFanout(renderers: [])
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
            port = 0
        }
        connected.removeAll()
        devices = []
    }

    // MARK: - CoreMIDI property helpers (main actor only)

    private static func integerProperty(_ object: MIDIObjectRef, _ property: CFString) -> Int32 {
        var value: Int32 = 0
        MIDIObjectGetIntegerProperty(object, property, &value)
        return value
    }

    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
