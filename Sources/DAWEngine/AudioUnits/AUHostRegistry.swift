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
/// capture. All AU property access happens here, on the main actor — with ONE
/// documented exception (m10-n §5.3): the `.soundBank` bank load runs on a
/// DETACHED task against an AU that is exclusively owned by its prepare
/// (allocated, never yet published to any graph), because
/// `kAUSamplerProperty_LoadInstrument` is calling-thread-synchronous and a
/// GB-scale SF2 would stall the main actor. The render-safe product is a
/// `HostedAUInstrument` whose render path touches only its two captured
/// blocks.
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

    /// Idempotency identity of one prepare attempt. `soundBankAddress` is the
    /// STRUCTURAL bank identity for `.soundBank` tracks (nil for plain AU
    /// hosting/effects) — `displayName` is excluded by construction (LAW L8).
    struct PrepareKey: Equatable {
        let component: AudioUnitComponentID
        let sampleRate: Double
        let stateData: Data?
        let soundBankAddress: SoundBankConfig.Address?
    }

    /// The Apple AUSampler music device that hosts every `.soundBank` track
    /// (m10-n) — an implementation detail SYNTHESIZED here, never read from
    /// (or written to) the track's `audioUnit` config.
    static let auSamplerComponent = AudioUnitComponentID(
        type: "aumu", subType: "samp", manufacturer: "appl")

    /// Resolves the `"gm"` sentinel / bank paths for the pre-instantiation
    /// existence check (default directories — resolution never touches them).
    private static let soundBankLibrary = SoundBankLibrary()

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

    /// Full async setup for one track's hosted instrument (`.audioUnit`, or
    /// `.soundBank` hosting AUSampler — m10-n): instantiate →
    /// maximumFramesPerSlice → setFormat → apply saved state →
    /// allocateRenderResources → (soundBank only) detached bank load → wrap
    /// in `HostedAUInstrument`. Idempotent per `prepareKey` identity
    /// (component, sampleRate, stateData, bank address); serialized per
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
                                                stateData: config.stateData,
                                                soundBankAddress: nil)
    }

    /// Every effect id this registry holds any state for.
    var knownEffectIDs: [UUID] {
        Array(Set(effectStatus.keys).union(effects.keys).union(effectAttempted.keys))
    }

    private func performPrepareEffect(effectID: UUID, config: AudioUnitConfig,
                                      sampleRate: Double, maxFrames: Int,
                                      timeout: Duration) async {
        let key = PrepareKey(component: config.component, sampleRate: sampleRate,
                             stateData: config.stateData, soundBankAddress: nil)
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

    /// Structural prepare identity for one track's hosted instrument, for
    /// BOTH hosted kinds (m10-n §5.5 — the ONE keying authority, shared with
    /// `AudioEngine.syncAudioUnitInstruments` so the engine's desired-map and
    /// this registry's idempotency check can never drift): `.audioUnit` keys
    /// component + stateData; `.soundBank` keys the synthesized AUSampler
    /// component + the bank ADDRESS, stateData ALWAYS nil (LAW L3) and
    /// displayName excluded by construction (LAW L8). nil when there is
    /// nothing to instantiate (componentless/configless → the `.missing`
    /// placeholder branch; built-in kinds).
    static func prepareKey(track: Track, sampleRate: Double) -> PrepareKey? {
        let descriptor = track.instrument ?? .default
        switch descriptor.kind {
        case .audioUnit:
            guard let config = descriptor.audioUnit else { return nil }
            return PrepareKey(component: config.component, sampleRate: sampleRate,
                              stateData: config.stateData, soundBankAddress: nil)
        case .soundBank:
            guard let config = descriptor.soundBank else { return nil }
            return PrepareKey(component: Self.auSamplerComponent, sampleRate: sampleRate,
                              stateData: nil, soundBankAddress: config.address)
        case .testTone, .polySynth, .sampler:
            return nil
        }
    }

    private func performPrepare(track: Track, sampleRate: Double, timeout: Duration) async {
        let id = track.id
        let descriptor = track.instrument ?? .default
        guard descriptor.kind == .audioUnit || descriptor.kind == .soundBank else { return }
        guard let key = Self.prepareKey(track: track, sampleRate: sampleRate) else {
            // Legal descriptor with no component/bank selected → missing placeholder.
            attempted[id] = nil
            status[id] = .missing
            return
        }
        guard attempted[id] != key else { return }  // idempotent per identity

        // A different config replaces the old instrument wholesale.
        if instruments[id] != nil { releaseInstrument(forTrack: id) }
        attempted[id] = key

        // `.soundBank`: resolve the bank file BEFORE instantiating (the
        // lookup-never-instantiates spirit) — a missing bank fails readably
        // with no AU ever created, and the track renders honest silence,
        // never a built-in fallback (LAW L5).
        let soundBank: (config: SoundBankConfig, url: URL)?
        if descriptor.kind == .soundBank, let config = descriptor.soundBank {
            do {
                soundBank = (config, try Self.soundBankLibrary.resolve(config.source))
            } catch {
                status[id] = .failed(Self.reason(error))
                return
            }
        } else {
            soundBank = nil
        }

        // Component lookup never instantiates: unknown → .missing. For
        // `.soundBank` the description is SYNTHESIZED from
        // `auSamplerComponent` (already folded into `key.component`) — never
        // read from the track's `audioUnit` config.
        var componentDescription = AudioComponentDescription()
        componentDescription.componentType = Self.fourCC(key.component.type)
        componentDescription.componentSubType = Self.fourCC(key.component.subType)
        componentDescription.componentManufacturer = Self.fourCC(key.component.manufacturer)
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
            // (maxFrames → format → state → allocate). `key.stateData` is
            // ALWAYS nil for `.soundBank` (LAW L3 — `SoundBankConfig` is the
            // single source of truth, `fullStateForDocument` is never
            // captured or restored for that kind).
            if let stateData = key.stateData {
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
            // `.soundBank`: load the bank program AFTER allocate (an
            // uninitialized-AU load would hide its cost inside the main-actor
            // AudioUnitInitialize) and BEFORE wrapping/publishing — still
            // inside this timeout race, on an instance nobody else can see
            // (m10-n §5.3). Failure lands the existing `.failed` outcome.
            if let soundBank {
                do {
                    try await Self.loadSoundBank(into: au, config: soundBank.config,
                                                 resolvedURL: soundBank.url)
                } catch {
                    au.deallocateRenderResources()
                    throw error
                }
            }
            return try HostedAUInstrument(au: au, sampleRate: sampleRate)
        }

        switch outcome {
        case .value(let instrument):
            if let soundBank {
                // R7 reload hook (§5.8): T6 measured that render-resource
                // reallocation drops AUSampler's loaded instrument, so a rate
                // renegotiation must re-apply the bank before the next pull.
                instrument.reloadAfterRenegotiation = { au in
                    Self.reloadSoundBankAfterRenegotiation(
                        au: au, config: soundBank.config, resolvedURL: soundBank.url)
                }
            }
            instruments[id] = instrument
            status[id] = .ready
        case .error(let error):
            status[id] = .failed(Self.reason(error))
        case .timedOut:
            status[id] = .failed(
                "Audio Unit preparation timed out after \(timeout) — component may be stalled")
        }
    }

    /// Loads one SF2/DLS program into a freshly allocated AUSampler (m10-n
    /// §5.3). Called from the timeout-raced prepare closure; the AU is
    /// EXCLUSIVELY owned here — allocated, never yet published to any graph,
    /// so no render pulls it and no other code holds it.
    ///
    /// Threading: `kAUSamplerProperty_LoadInstrument` on an INITIALIZED AU
    /// loads synchronously on the calling thread (TN2283), and a GB-scale
    /// SF2 can block for seconds — so the call runs on a DETACHED task
    /// (LAW L2), never on the main actor. v2 CoreAudio property calls are
    /// safe from any single thread; the `@unchecked Sendable` box is the
    /// sanctioned pre-publish-exclusive crossing (the
    /// `HostedAUInstrument: @unchecked Sendable` precedent). A timed-out
    /// prepare abandons the detached task harmlessly: it finishes against an
    /// AU that was never published and dies by ARC.
    private static func loadSoundBank(into au: AUAudioUnit, config: SoundBankConfig,
                                      resolvedURL: URL) async throws {
        guard let bridge = au as? AUAudioUnitV2Bridge else {
            // All-v2 machine today; if Apple ever ships samp as v3 this fails
            // readably instead of hosting a half-configured sampler.
            throw EngineError.renderFailed("AUSampler did not expose a v2 handle — cannot load bank")
        }
        struct UnitBox: @unchecked Sendable { let unit: AudioUnit }  // pre-publish exclusive (§5.3a)
        let box = UnitBox(unit: bridge.audioUnit)
        let path = resolvedURL.path
        let msb = UInt8(clamping: config.bankMSB)
        let lsb = UInt8(clamping: config.bankLSB)
        let program = UInt8(clamping: config.program)

        let status: OSStatus = await Task.detached(priority: .userInitiated) {
            Self.setLoadInstrumentProperty(unit: box.unit, path: path,
                                           bankMSB: msb, bankLSB: lsb, program: program)
        }.value

        guard status == noErr else {
            throw EngineError.renderFailed(
                "sound bank load failed (OSStatus \(status)) — \(path), program \(program), bank \(msb)/\(lsb)")
        }
    }

    /// The raw `kAUSamplerProperty_LoadInstrument` write, shared by the
    /// detached prepare-time load and the R7 post-renegotiation re-load.
    /// `nonisolated`: pure C-API call, runs on whatever thread owns the AU
    /// at that moment (detached task pre-publish; main actor for R7).
    private nonisolated static func setLoadInstrumentProperty(
        unit: AudioUnit, path: String,
        bankMSB: UInt8, bankLSB: UInt8, program: UInt8
    ) -> OSStatus {
        let url = URL(fileURLWithPath: path) as CFURL
        return withExtendedLifetime(url) {  // R6: the CFURL must outlive the call
            var data = AUSamplerInstrumentData(
                fileURL: Unmanaged.passUnretained(url),
                instrumentType: UInt8(kInstrumentType_SF2Preset),  // == DLSPreset == 1: ONE path (R5)
                bankMSB: bankMSB, bankLSB: bankLSB, presetID: program)
            return AudioUnitSetProperty(unit, kAUSamplerProperty_LoadInstrument,
                                        kAudioUnitScope_Global, 0, &data,
                                        UInt32(MemoryLayout<AUSamplerInstrumentData>.size))
        }
    }

    /// R7 (m10-n §5.8) — synchronous bank RE-load after a rate renegotiation.
    /// MEASURED NECESSITY (T6, 2026-07-11): `deallocateRenderResources` →
    /// `allocateRenderResources` DROPS AUSampler's loaded instrument — the
    /// renegotiated sampler reverted to the factory default (sine) preset,
    /// byte-identical output to an unloaded instance. Runs synchronously on
    /// the main actor INSIDE `HostedAUInstrument.prepare`'s already
    /// synchronous, bounded, logged renegotiation path: a transient
    /// wrong-timbre window (async reload) would violate LAW L5's honesty —
    /// for the rare registry-rate ≠ graph-rate recovery path, a bounded
    /// stall is the lesser evil (the NORMAL prepare path stays detached,
    /// LAW L2). Failure logs and leaves the default preset — the same
    /// degrade-with-stderr contract as a failed renegotiation itself.
    private nonisolated static func reloadSoundBankAfterRenegotiation(
        au: AUAudioUnit, config: SoundBankConfig, resolvedURL: URL
    ) {
        guard let bridge = au as? AUAudioUnitV2Bridge else { return }
        let status = setLoadInstrumentProperty(
            unit: bridge.audioUnit, path: resolvedURL.path,
            bankMSB: UInt8(clamping: config.bankMSB),
            bankLSB: UInt8(clamping: config.bankLSB),
            program: UInt8(clamping: config.program))
        if status != noErr {
            FileHandle.standardError.write(Data(
                "AUHostRegistry: sound bank re-load after rate renegotiation failed (OSStatus \(status)) — instrument may render the factory default preset\n".utf8))
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
