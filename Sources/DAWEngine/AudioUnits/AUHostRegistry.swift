import AVFAudio
import AudioToolbox
import DAWCore
import Foundation

/// Identity of one hosted-AU endpoint addressable by the app layer (M3 vi-b):
/// the release callback reports which live instance just went away so a plugin
/// window (or any vendor view observing the parameter tree) tears down against
/// the still-allocated AU. Foundation-only (bare UUIDs) so it crosses the module
/// boundary without dragging AudioToolbox with it.
public enum HostedAUEndpoint: Hashable, Sendable {
    case instrument(trackID: UUID)
    case effect(effectID: UUID)
}

/// Owns hosted Audio Unit instrument lifecycle for a set of tracks: discovery,
/// async instantiation, format/state/resource setup, and save-time state
/// capture. All AU property access happens here, on the main actor; the
/// render-safe product is a `HostedAUInstrument` whose render path touches
/// only its two captured blocks.
///
/// Every AU call runs inside a timeout-raced Task so a stalled (v3 XPC)
/// component can never block the main actor: on timeout the track fails
/// readably and renders the silent placeholder.
@MainActor
public final class AUHostRegistry {
    /// Per-track hosting status, published for snapshots.
    public private(set) var status: [UUID: AudioUnitTrackStatus] = [:]

    /// Invalidation seam for the plugin-window layer (M3 vi-b). Fired AFTER an
    /// instance is actually removed from the table and BEFORE its
    /// `deallocateRenderResources`, only when a release removed a real instance
    /// (never for bookkeeping-only no-op releases). Main actor, synchronous —
    /// the window closes in the SAME turn as the model change, against a still-
    /// allocated AU. The engine re-exposes this as `hostedAUReleased`.
    var onRelease: ((HostedAUEndpoint) -> Void)?

    private var instruments: [UUID: HostedAUInstrument] = [:]

    /// Idempotency identity of one prepare attempt.
    struct PrepareKey: Equatable {
        let component: AudioUnitComponentID
        let sampleRate: Double
        let stateData: Data?
    }

    /// Key of the last attempt per track — successful or not — so repeated
    /// `tracksDidChange` passes never re-instantiate an unchanged (or
    /// terminally failed/missing) configuration.
    private var attempted: [UUID: PrepareKey] = [:]

    /// Per-track serialization: each prepare chains behind the previous one.
    private var prepareChains: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Test seam: replaces `AUAudioUnit.instantiate` so tests can simulate a
    /// hung or failing component without any real plugin.
    var instantiator: @MainActor (AudioComponentDescription, AudioComponentInstantiationOptions)
        async throws -> AUAudioUnit = { description, options in
        try await AUAudioUnit.instantiate(with: description, options: options)
    }

    public init() {}

    // MARK: - Discovery

    /// All installed Audio Unit music devices ('aumu', wildcard sub/manu).
    public static func listMusicDevices() -> [AudioUnitComponentInfo] {
        var wildcard = AudioComponentDescription()
        wildcard.componentType = kAudioUnitType_MusicDevice
        return AVAudioUnitComponentManager.shared()
            .components(matching: wildcard)
            .map { component in
                let description = component.audioComponentDescription
                return AudioUnitComponentInfo(
                    component: AudioUnitComponentID(
                        type: fourCCString(description.componentType),
                        subType: fourCCString(description.componentSubType),
                        manufacturer: fourCCString(description.componentManufacturer)
                    ),
                    name: component.name,
                    manufacturerName: component.manufacturerName,
                    versionString: component.versionString,
                    isV3: description.componentFlags
                        & AudioComponentFlags.isV3AudioUnit.rawValue != 0
                )
            }
    }

    /// All installed Audio Unit effects ('aufx', wildcard sub/manu) — the
    /// M4 (v) insert-hosting counterpart of `listMusicDevices`.
    public static func listEffectComponents() -> [AudioUnitComponentInfo] {
        var wildcard = AudioComponentDescription()
        wildcard.componentType = kAudioUnitType_Effect
        return AVAudioUnitComponentManager.shared()
            .components(matching: wildcard)
            .map { component in
                let description = component.audioComponentDescription
                return AudioUnitComponentInfo(
                    component: AudioUnitComponentID(
                        type: fourCCString(description.componentType),
                        subType: fourCCString(description.componentSubType),
                        manufacturer: fourCCString(description.componentManufacturer)
                    ),
                    name: component.name,
                    manufacturerName: component.manufacturerName,
                    versionString: component.versionString,
                    isV3: description.componentFlags
                        & AudioComponentFlags.isV3AudioUnit.rawValue != 0
                )
            }
    }

    // MARK: - Lifecycle

    /// Full async setup for one track's Audio Unit: instantiate →
    /// maximumFramesPerSlice → setFormat → apply saved state →
    /// allocateRenderResources → wrap in `HostedAUInstrument`. Idempotent per
    /// (trackID, componentID, sampleRate, stateData identity); serialized per
    /// track; the whole sequence races `timeout`.
    public func prepare(track: Track, sampleRate: Double,
                        timeout: Duration = .seconds(10)) async {
        let id = track.id
        let previous = prepareChains[id]?.task
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            await self?.performPrepare(track: track, sampleRate: sampleRate, timeout: timeout)
        }
        prepareChains[id] = (token, task)
        _ = await task.value
        if prepareChains[id]?.token == token {
            prepareChains[id] = nil
        }
    }

    /// The render-ready instrument for a track, once (and only once) `.ready`.
    public func preparedInstrument(forTrack id: UUID) -> HostedAUInstrument? {
        instruments[id]
    }

    /// Current `fullStateForDocument` of the track's AU as a binary plist.
    public func instrumentState(forTrack id: UUID) -> Data? {
        guard let instrument = instruments[id],
              let state = instrument.auAudioUnit.fullStateForDocument else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: state, format: .binary, options: 0)
    }

    /// Tears one track's instrument down: deallocate render resources, reset
    /// (main-actor-only — never from the render thread), drop all bookkeeping.
    public func releaseInstrument(forTrack id: UUID) {
        attempted[id] = nil
        status[id] = nil
        guard let instrument = instruments.removeValue(forKey: id) else { return }
        // Invalidate any plugin window BEFORE the AU's render resources go — the
        // window (and any observing vendor view) detaches against a live AU.
        onRelease?(.instrument(trackID: id))
        instrument.auAudioUnit.deallocateRenderResources()
        instrument.auAudioUnit.reset()
    }

    /// True when the track's descriptor demands a (re)prepare: config changed,
    /// or nothing was ever attempted. False for an unchanged config whatever
    /// its outcome (ready, missing, or failed — no retry storms).
    func needsPrepare(track: Track, sampleRate: Double) -> Bool {
        guard let key = Self.prepareKey(track: track, sampleRate: sampleRate) else {
            // .audioUnit with no component selected: nothing to instantiate.
            return attempted[track.id] != nil || status[track.id] != .missing
        }
        return attempted[track.id] != key
    }

    /// Every track id this registry holds any state for.
    var knownTrackIDs: [UUID] {
        Array(Set(status.keys).union(instruments.keys).union(attempted.keys))
    }

    // MARK: - Effect lifecycle (M4 v)

    /// Per-effect hosting status, published for diagnostics/tests.
    public private(set) var effectStatus: [UUID: AudioUnitTrackStatus] = [:]

    private var effects: [UUID: HostedAUEffect] = [:]
    private var effectAttempted: [UUID: PrepareKey] = [:]
    private var effectPrepareChains: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Full async setup for one insert effect's Audio Unit — the
    /// `prepare(track:)` mirror: instantiate → maximumFramesToRender →
    /// setFormat on BOTH busses (effects negotiate input and output) → apply
    /// saved state → allocateRenderResources → wrap in `HostedAUEffect`.
    /// Idempotent per (effectID, componentID, sampleRate, stateData identity);
    /// serialized per effect; the whole sequence races `timeout`.
    public func prepareEffect(effectID: UUID, config: AudioUnitConfig,
                              sampleRate: Double, maxFrames: Int = 8_192,
                              timeout: Duration = .seconds(10)) async {
        let previous = effectPrepareChains[effectID]?.task
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            await self?.performPrepareEffect(effectID: effectID, config: config,
                                             sampleRate: sampleRate,
                                             maxFrames: maxFrames, timeout: timeout)
        }
        effectPrepareChains[effectID] = (token, task)
        _ = await task.value
        if effectPrepareChains[effectID]?.token == token {
            effectPrepareChains[effectID] = nil
        }
    }

    /// The render-ready effect for an insert, once (and only once) `.ready`.
    public func preparedEffect(forEffect id: UUID) -> HostedAUEffect? {
        effects[id]
    }

    /// Current `fullStateForDocument` of the effect's AU as a binary plist.
    public func effectState(forEffect id: UUID) -> Data? {
        guard let effect = effects[id],
              let state = effect.auAudioUnit.fullStateForDocument else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: state, format: .binary, options: 0)
    }

    /// Tears one insert's effect down: deallocate render resources, reset
    /// (main-actor-only), drop all bookkeeping. A straggler render against
    /// the deallocated AU is covered by the adapter's error path (dry
    /// passthrough, no trap).
    public func releaseEffect(forEffect id: UUID) {
        effectAttempted[id] = nil
        effectStatus[id] = nil
        guard let effect = effects.removeValue(forKey: id) else { return }
        // Invalidate any plugin window BEFORE the AU's render resources go (the
        // instrument-path ordering — §2.2).
        onRelease?(.effect(effectID: id))
        effect.auAudioUnit.deallocateRenderResources()
        effect.auAudioUnit.reset()
    }

    /// True when the config demands a (re)prepare — changed identity or never
    /// attempted. False for an unchanged config whatever its outcome (no
    /// retry storms; the instrument rule).
    func effectNeedsPrepare(effectID: UUID, config: AudioUnitConfig,
                            sampleRate: Double) -> Bool {
        effectAttempted[effectID] != PrepareKey(component: config.component,
                                                sampleRate: sampleRate,
                                                stateData: config.stateData)
    }

    /// Every effect id this registry holds any state for.
    var knownEffectIDs: [UUID] {
        Array(Set(effectStatus.keys).union(effects.keys).union(effectAttempted.keys))
    }

    private func performPrepareEffect(effectID: UUID, config: AudioUnitConfig,
                                      sampleRate: Double, maxFrames: Int,
                                      timeout: Duration) async {
        let key = PrepareKey(component: config.component, sampleRate: sampleRate,
                             stateData: config.stateData)
        guard effectAttempted[effectID] != key else { return }  // idempotent per identity

        // A different config replaces the old effect wholesale.
        if effects[effectID] != nil { releaseEffect(forEffect: effectID) }
        effectAttempted[effectID] = key

        // Component lookup never instantiates: unknown → .missing.
        var componentDescription = AudioComponentDescription()
        componentDescription.componentType = Self.fourCC(config.component.type)
        componentDescription.componentSubType = Self.fourCC(config.component.subType)
        componentDescription.componentManufacturer = Self.fourCC(config.component.manufacturer)
        let matches = AVAudioUnitComponentManager.shared()
            .components(matching: componentDescription)
        guard let match = matches.first else {
            effectStatus[effectID] = .missing
            return
        }
        let isV3 = match.audioComponentDescription.componentFlags
            & AudioComponentFlags.isV3AudioUnit.rawValue != 0

        effectStatus[effectID] = .pending
        let stateData = config.stateData
        let outcome = await raceAgainstTimeout(timeout) { [instantiator] in
            let au: AUAudioUnit
            if isV3 {
                // v3: in-process first (lower latency), out-of-process retry.
                do {
                    au = try await instantiator(componentDescription, [.loadInProcess])
                } catch {
                    au = try await instantiator(componentDescription, [.loadOutOfProcess])
                }
            } else {
                au = try await instantiator(componentDescription, [])
            }

            au.maximumFramesToRender = AUAudioFrameCount(maxFrames)
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 2
            ) else {
                throw EngineError.renderFailed("no standard stereo format at \(sampleRate) Hz")
            }
            try au.inputBusses[0].setFormat(format)
            try au.outputBusses[0].setFormat(format)
            // The v2 bridge leaves input busses DISABLED by default; without
            // this the render never pulls its input block and fails with
            // kAudioUnitErr_NoConnection (-10876, measured on AUDelay).
            au.inputBusses[0].isEnabled = true

            // Restore order contract: state BEFORE allocateRenderResources
            // (maxFrames → format → state → allocate).
            if let stateData {
                do {
                    let plist = try PropertyListSerialization.propertyList(
                        from: stateData, options: [], format: nil)
                    if let dictionary = plist as? [String: Any] {
                        au.fullStateForDocument = dictionary
                    } else {
                        FileHandle.standardError.write(Data(
                            "AUHostRegistry: saved AU effect state is not a dictionary — continuing stateless\n".utf8))
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "AUHostRegistry: saved AU effect state failed to decode (\(error)) — continuing stateless\n".utf8))
                }
            }

            try au.allocateRenderResources()
            // Post-allocate rate assertion — fail readably, never silently.
            let allocatedRate = au.outputBusses[0].format.sampleRate
            guard allocatedRate == sampleRate else {
                au.deallocateRenderResources()
                throw EngineError.renderFailed(
                    "output bus allocated at \(allocatedRate) Hz, wanted \(sampleRate) Hz")
            }
            return HostedAUEffect(au: au, sampleRate: sampleRate, maxFrames: maxFrames)
        }

        switch outcome {
        case .value(let effect):
            effects[effectID] = effect
            effectStatus[effectID] = .ready
        case .error(let error):
            effectStatus[effectID] = .failed(Self.reason(error))
        case .timedOut:
            effectStatus[effectID] = .failed(
                "Audio Unit preparation timed out after \(timeout) — component may be stalled")
        }
    }

    // MARK: - Internals

    private static func prepareKey(track: Track, sampleRate: Double) -> PrepareKey? {
        guard let config = track.instrument?.audioUnit else { return nil }
        return PrepareKey(component: config.component, sampleRate: sampleRate,
                          stateData: config.stateData)
    }

    private func performPrepare(track: Track, sampleRate: Double, timeout: Duration) async {
        let id = track.id
        let descriptor = track.instrument ?? .default
        guard descriptor.kind == .audioUnit else { return }
        guard let config = descriptor.audioUnit,
              let key = Self.prepareKey(track: track, sampleRate: sampleRate) else {
            // Legal descriptor with no component selected → missing placeholder.
            attempted[id] = nil
            status[id] = .missing
            return
        }
        guard attempted[id] != key else { return }  // idempotent per identity

        // A different config replaces the old instrument wholesale.
        if instruments[id] != nil { releaseInstrument(forTrack: id) }
        attempted[id] = key

        // Component lookup never instantiates: unknown → .missing.
        var componentDescription = AudioComponentDescription()
        componentDescription.componentType = Self.fourCC(config.component.type)
        componentDescription.componentSubType = Self.fourCC(config.component.subType)
        componentDescription.componentManufacturer = Self.fourCC(config.component.manufacturer)
        let matches = AVAudioUnitComponentManager.shared()
            .components(matching: componentDescription)
        guard let match = matches.first else {
            status[id] = .missing
            return
        }
        let isV3 = match.audioComponentDescription.componentFlags
            & AudioComponentFlags.isV3AudioUnit.rawValue != 0

        status[id] = .pending
        let outcome = await raceAgainstTimeout(timeout) { [instantiator] in
            let au: AUAudioUnit
            if isV3 {
                // v3: in-process first (lower latency), out-of-process retry.
                do {
                    au = try await instantiator(componentDescription, [.loadInProcess])
                } catch {
                    au = try await instantiator(componentDescription, [.loadOutOfProcess])
                }
            } else {
                au = try await instantiator(componentDescription, [])
            }

            au.maximumFramesToRender = 8_192
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 2
            ) else {
                throw EngineError.renderFailed("no standard stereo format at \(sampleRate) Hz")
            }
            try au.outputBusses[0].setFormat(format)

            // Restore order contract: state BEFORE allocateRenderResources
            // (maxFrames → format → state → allocate).
            if let stateData = config.stateData {
                do {
                    let plist = try PropertyListSerialization.propertyList(
                        from: stateData, options: [], format: nil)
                    if let dictionary = plist as? [String: Any] {
                        au.fullStateForDocument = dictionary
                    } else {
                        FileHandle.standardError.write(Data(
                            "AUHostRegistry: saved AU state is not a dictionary — continuing stateless\n".utf8))
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "AUHostRegistry: saved AU state failed to decode (\(error)) — continuing stateless\n".utf8))
                }
            }

            try au.allocateRenderResources()
            // Post-allocate rate assertion: a format the AU silently refused
            // would render silence (or garbage) — fail readably instead.
            let allocatedRate = au.outputBusses[0].format.sampleRate
            guard allocatedRate == sampleRate else {
                au.deallocateRenderResources()
                throw EngineError.renderFailed(
                    "output bus allocated at \(allocatedRate) Hz, wanted \(sampleRate) Hz")
            }
            return try HostedAUInstrument(au: au, sampleRate: sampleRate)
        }

        switch outcome {
        case .value(let instrument):
            instruments[id] = instrument
            status[id] = .ready
        case .error(let error):
            status[id] = .failed(Self.reason(error))
        case .timedOut:
            status[id] = .failed(
                "Audio Unit preparation timed out after \(timeout) — component may be stalled")
        }
    }

    private enum RaceOutcome<T: Sendable>: Sendable {
        case value(T)
        case error(any Error)
        case timedOut
    }

    /// Races `work` against a timeout with UNSTRUCTURED tasks: a stalled AU
    /// call is abandoned, never awaited, so the main actor is never blocked
    /// past `timeout`. First resume wins (both resumers run on the main
    /// actor, so the once-guard needs no lock).
    private func raceAgainstTimeout<T: Sendable>(
        _ timeout: Duration,
        _ work: @escaping @MainActor () async throws -> T
    ) async -> RaceOutcome<T> {
        await withCheckedContinuation { continuation in
            let gate = ResumeGate<T>(continuation)
            Task { @MainActor in
                do {
                    let value = try await work()
                    gate.resume(.value(value))
                } catch {
                    gate.resume(.error(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.resume(.timedOut)
            }
        }
    }

    /// Resumes a continuation exactly once. Main-actor confined.
    @MainActor
    private final class ResumeGate<T: Sendable> {
        private var continuation: CheckedContinuation<RaceOutcome<T>, Never>?

        init(_ continuation: CheckedContinuation<RaceOutcome<T>, Never>) {
            self.continuation = continuation
        }

        func resume(_ outcome: RaceOutcome<T>) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    // MARK: - FourCC helpers

    /// "dls " → OSType. The ID type guarantees exactly 4 ASCII characters.
    static func fourCC(_ code: String) -> OSType {
        var result: OSType = 0
        for scalar in code.unicodeScalars.prefix(4) {
            result = (result << 8) | OSType(scalar.value & 0xFF)
        }
        return result
    }

    /// OSType → 4-character string ("aumu"); non-printable bytes become "?".
    static func fourCCString(_ code: OSType) -> String {
        let bytes = [UInt8(code >> 24 & 0xFF), UInt8(code >> 16 & 0xFF),
                     UInt8(code >> 8 & 0xFF), UInt8(code & 0xFF)]
        return String(bytes.map { byte in
            (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
        })
    }

    private static func reason(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
