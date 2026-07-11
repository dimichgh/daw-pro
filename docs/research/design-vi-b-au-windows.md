# Design — M3 (vi-b): AU plugin UI windows

**Status:** DESIGN SETTLED 2026-07-10 (this document is the implementation contract).
**Roadmap item:** docs/ROADMAP.md:37 — "AU plugin UI windows — `requestViewController`/v2 view
hosting in floating glass-chrome windows; open/close over the control protocol."
**Author:** daw-architect. **Implementing agents:** swift-app-engineer (windows/chrome/resolver),
mcp-integration-engineer (commands/tools), qa-test-engineer (suites + gate script support).

Every code fact below was verified against the working tree on 2026-07-10; every Apple API fact
was verified against the local macOS SDK headers at
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`
(paths cited inline).

---

## 0. Decision summary

| # | Question | Decision |
|---|---|---|
| 1 | Instance plumbing | Two `@MainActor` accessors on the **concrete** `AudioEngine` return the live `AUAudioUnit` (`hostedInstrumentAudioUnit(forTrack:)` / `hostedEffectAudioUnit(forEffect:)`), reading `auRegistry.prepared…().auAudioUnit` module-internally. Plus one invalidation seam `hostedAUReleased: ((HostedAUEndpoint) -> Void)?` fired from the registry's release paths. NOT on `AudioEngineControlling` (DAWCore stays Foundation-only). The reference never leaves the main actor — no Sendable crossing exists. |
| 2 | v2 vs v3 view paths | Three-step resolution ladder, never-failing: (1) `requestViewController` raced against a 5 s timeout → custom v3 view; (2) if nil and the unit is an `AUAudioUnitV2Bridge`, query `kAudioUnitProperty_CocoaUI` on `bridge.audioUnit`, load the factory bundle, `AUCocoaUIBase.uiViewForAudioUnit:withSize:` → custom v2 view; (3) **`AUGenericViewController`** (CoreAudioKit, macOS 13+, works for v2-bridged AND v3 units) → generic body. No hand-rolled parameter editor in v1. |
| 3 | Window model | `@MainActor PluginWindowManager` in DAWApp owns `NSPanel`s keyed by `PluginUITarget` (one window per live instance; reopen = focus). Pure bookkeeping (`PluginWindowLedger`) lives in DAWAppKit for headless tests. Lifecycle is driven by exactly one invalidation source: the registry release callback (covers effect/track removal, instrument switch, project open/new, config/sample-rate change). Engine recovery (`recoverEngine`/`watchdogRestart`) does NOT touch the registry — windows survive it (verified, AudioEngine.swift:1309–1387). |
| 4 | Control surface | Three commands in the already-reserved `plugin.*` namespace (docs/ARCHITECTURE.md "Control protocol (v0)" already lists `plugin.*`): `plugin.openUI {trackId, effectId?, x?, y?}`, `plugin.closeUI {trackId, effectId?}`, `plugin.listOpenUIs {}`. Routed through a new typed `@MainActor` async seam on `CommandRouter` (`pluginUI: PluginUIControlling?`), installed by the app — the `copilotEngine`/`appCommandHandler` two-phase wiring precedent. Headless (seam nil): open/close fail with a readable error; listOpenUIs answers honestly `{available:false, windows:[]}`. Three MCP tools mirror them 1:1. |
| 5 | Staging/verification | Headless suites prove: command taxonomy + routing (DAWControlTests, fake `PluginUIControlling`), ledger math (DAWAppKitTests), accessor identity + release callback against real system AUs (DAWEngineTests — DLSMusicDevice/AUDelay are already instantiated headless there today). Live gate (orchestrator, ports 17695–17698): open DLSMusicDevice + AUDelay windows over the wire at pinned x/y, capture via the extended `debug.captureUI {target:"plugin"}`, list, close, and prove auto-close on `fx.remove`. |
| 6 | Bare vs bundled | Cycle 1 (generic bodies + v2 in-process views) works fully in the bare `swift run` dev flow. Only the **out-of-process AUv3 custom view** leg needs `dist/DAWPro.app` (recorded vi-a finding, ROADMAP.md:156); bare runs degrade to the generic body with a `warning` field instead of failing. No full-Xcode requirement anywhere in this item. |

**Split:** two cycles — **vi-b-1** (plumbing, commands, window manager, generic body, capture, gate)
and **vi-b-2** (vendor-view ladder: requestViewController + v2 CocoaUI + sizing/resize + bundled
AUv3 leg). vi-b-1 alone delivers the full agent-visible capability.

---

## 1. Scope and non-goals

In scope: floating windows showing the LIVE, sounding AU instance (the registry's
`HostedAUInstrument.auAudioUnit` / `HostedAUEffect.auAudioUnit` — the same object whose captured
`renderBlock` the graph is pulling); open/close/list over the control protocol and MCP; glass
chrome per docs/DESIGN-LANGUAGE.md; two small UI affordances (mixer AU-effect row + instrument
panel "open window" buttons) so UI and wire converge on the same manager.

Non-goals (explicitly out of v1, do not gold-plate):
- `AUAudioUnitViewConfiguration` / `supportedViewConfigurations` compact-view negotiation.
- A themed DAW-Pro generic parameter editor (AUGenericViewController is the v1 fallback body;
  a themed replacement is a labeled future enhancement).
- Window-frame persistence across sessions; multi-monitor placement policy beyond clamping.
- Reopening windows automatically after a config-change re-prepare (v1 closes; user/agent reopens).
- Any change to offline rendering (OfflineRenderer builds fresh AUs per render — no interaction;
  an open window during a bounce refers to the live instance only, which is correct).
- Built-in effects/instruments (kind != .audioUnit) get no windows — they already have first-class
  in-app panels.

---

## 2. Instance plumbing (Decision 1, in full)

### 2.1 Where the live instance lives today

- Instruments: `AUHostRegistry.instruments: [UUID(trackID): HostedAUInstrument]`;
  `preparedInstrument(forTrack:)` (Sources/DAWEngine/AudioUnits/AUHostRegistry.swift:119).
- Effects: `AUHostRegistry.effects: [UUID(effectID): HostedAUEffect]`;
  `preparedEffect(forEffect:)` (AUHostRegistry.swift:191).
- Both adapters hold `let auAudioUnit: AUAudioUnit` documented **MAIN-ACTOR-ONLY** for everything
  except the two captured render blocks (HostedAUInstrument.swift:29–32, HostedAUEffect.swift:21–24).
- `AudioEngine.auRegistry` is module-internal by design ("Never reached from outside the module",
  AudioEngine.swift:14) — we keep that; the app gets narrow accessors instead.

### 2.2 New DAWEngine API

File: `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift` (enum + callback) and
`Sources/DAWEngine/AudioEngine.swift` (public forwarders).

```swift
/// Identity of one hosted-AU endpoint addressable by the app layer.
public enum HostedAUEndpoint: Hashable, Sendable {
    case instrument(trackID: UUID)
    case effect(effectID: UUID)
}

// AUHostRegistry (@MainActor):
/// Fired AFTER an instance is actually removed from the table and BEFORE
/// deallocateRenderResources, only when a release removed a real instance
/// (never for bookkeeping-only no-op releases). Main actor, synchronous.
var onRelease: ((HostedAUEndpoint) -> Void)?

// AudioEngine (@MainActor):
/// CONTROL-PLANE ONLY. The live, sounding AU for a track's hosted instrument —
/// nil unless the registry reports .ready. This accessor (and its effect twin)
/// is the ONE sanctioned AudioToolbox type on DAWEngine's public surface:
/// plugin-view hosting is definitionally AUAudioUnit-shaped. Callers must stay
/// on the main actor and must never reach the render-thread contract members.
public func hostedInstrumentAudioUnit(forTrack id: UUID) -> AUAudioUnit?
public func hostedEffectAudioUnit(forEffect id: UUID) -> AUAudioUnit?

/// The registry's onRelease, re-exposed for the app (wired in init alongside
/// the graph providers, AudioEngine.swift:213–221 neighborhood).
public var hostedAUReleased: ((HostedAUEndpoint) -> Void)?

/// Effect mirror of audioUnitStatus(forTrack:) so open-failure errors can
/// report pending/missing/failed(reason) readably.
public func audioUnitEffectStatus(forEffect id: UUID) -> AudioUnitTrackStatus?
```

Implementation notes:
- `releaseInstrument(forTrack:)` (AUHostRegistry.swift:133) and `releaseEffect(forEffect:)`
  (AUHostRegistry.swift:207) currently `guard let … = removeValue(...) else { return }` — insert
  `onRelease?(.instrument(trackID: id))` / `onRelease?(.effect(effectID: id))` immediately after the
  successful `removeValue`, BEFORE `deallocateRenderResources()`. Rationale: the window (and any
  vendor view observing the parameter tree) is torn down against a still-allocated AU. The callback
  runs synchronously on the main actor inside the same turn — ordering is deterministic.
- `audioUnitEffectStatus` is additive on `AudioEngineControlling` (DAWCore/EngineProtocol.swift)
  with a `nil` default-implementation, mirroring `audioUnitStatus(forTrack:)` at line 221 — it uses
  only the existing Foundation-safe `AudioUnitTrackStatus` type, so DAWCore stays dependency-free.
- **Boundary exception (must be recorded in docs/ARCHITECTURE.md by the implementing cycle):**
  `AudioEngine`'s module doc says "AVFoundation types must not leak out of this module"
  (AudioEngine.swift:8). The two accessors above are a deliberate, documented exception, concrete-
  class-only (NOT on the protocol), control-plane-only. DAWApp already links audio frameworks
  (Sources/DAWApp/Timeline/ClipWaveform.swift imports AVFAudio), so no packaging change follows.

### 2.3 Swift 6 sendability analysis (why this is safe)

`AUAudioUnit` is not Sendable and never needs to be here:
- Accessors are `@MainActor` members of a `@MainActor` class, called by the `@MainActor`
  `PluginWindowManager`. The reference is produced and consumed inside one isolation domain —
  no crossing, nothing for the compiler to reject, nothing to `@unchecked`.
- The ONLY cross-thread hop in the whole feature is the `requestViewController` completion (§3.3):
  the SDK header explicitly says the completion runs "in a thread/dispatch queue context internal
  to the implementation" (CoreAudioKit/AUViewController.h:76–83, local SDK — verified). The bridge
  in §3.3 transfers the sole `NSViewController?` reference to the main actor before any use.
- The render thread is untouched end to end: opening a window performs main-actor ObjC property
  access on the AU (the same sanctioned side as `fullStateForDocument` at save time), plus AppKit
  work. Nothing here adds Tier-1 code, publishes render-side state, or touches `PlaybackGraph`.
  Vendor-view parameter edits reach DSP through the AU's own internal host-side machinery — the
  plugin's contract, not ours.

---

## 3. View resolution ladder (Decision 2, in full)

All units are instantiated as `AUAudioUnit` (v2 components arrive as the system's
`AUAudioUnitV2Bridge` subclass — AUHostRegistry.swift:257–268/364–375 uses `AUAudioUnit.instantiate`
for both). The ladder therefore starts from a single type and never fails: a window ALWAYS opens.

### 3.1 Verified API facts (do not re-litigate)

| Fact | Source (verified 2026-07-10) |
|---|---|
| `requestViewController(completionHandler:)` is asynchronous; the completion arrives "in a thread/dispatch queue context internal to the implementation, with a view controller, **or nil in the case of an audio unit without a custom view controller**". | Local SDK `CoreAudioKit.framework/Headers/AUViewController.h` lines 74–83 (`API_AVAILABLE(macos(10.12))`). |
| `AUAudioUnitV2Bridge.audioUnit` exposes the underlying v2 `AudioUnit` handle; sanctioned for "rare cases … For example, a v2 plugin may define custom properties that are not bridged to v3". Available macOS 11+. | Local SDK `AudioToolbox.framework/Headers/AUAudioUnitImplementation.h` lines 432–445. |
| `kAudioUnitProperty_CocoaUI` (property 31, macOS-only) yields `AudioUnitCocoaViewInfo { mCocoaAUViewBundleLocation: CFURLRef, mCocoaAUViewClass: [CFStringRef] }`; the class is a factory conforming to `AUCocoaUIBase`. | Local SDK `AudioToolbox.framework/Headers/AudioUnitProperties.h` lines 375–383, 1286–1297. |
| `AUCocoaUIBase.uiViewForAudioUnit:withSize:` "is a factory function: each call to it must return a unique view … returned … autoreleased. It is the client's responsibility to retain". | Local SDK `AudioToolbox.framework/Headers/AUCocoaUIView.h` lines 42–56. |
| `AUGenericViewController: AUViewControllerBase` with settable `@property AUAudioUnit *auAudioUnit` — a host-usable generic parameter UI for ANY AUAudioUnit. `API_AVAILABLE(macos(13.0))` — inside our macOS 14 floor. | Local SDK `CoreAudioKit.framework/Headers/AUGenericViewController.h`. |
| `AUGenericView` (macOS 10.4+, NSView, takes a v2 `AudioUnit` handle) still exists — kept as the CONTINGENCY if AUGenericViewController proves empty for bridged v2 units (§10 risk 1). | Local SDK `CoreAudioKit.framework/Headers/AUGenericView.h`. |
| Whether `AUAudioUnitV2Bridge` answers `requestViewController` with a wrapped CocoaUI view is NOT documented and host lore disagrees — so the ladder treats a nil answer from step 1 as normal for v2 and simply proceeds to step 2. Either behavior produces the correct end state. | Apple docs are silent; forum evidence inconclusive ([Apple forums 25838](https://developer.apple.com/forums/thread/25838), [Cockos AU CocoaUI thread](https://forum.cockos.com/archive/index.php/t-39117.html)). |

### 3.2 The ladder

```
resolve(au) -> (viewController: NSViewController, body: .custom | .generic, warning: String?)

1. vc = await requestViewControllerOnMain(au) raced vs 5 s timeout
     non-nil            -> (vc, .custom, nil)
     nil                -> continue
     timeout            -> continue with warning = "custom view request timed out after 5s"
2. if let bridge = au as? AUAudioUnitV2Bridge,
      let info = AUViewProbe.cocoaViewInfo(bridge.audioUnit)      // DAWEngine, testable
      -> load Bundle(url: info.bundleURL), NSClassFromString(info.className),
         factory = class.init() as? AUCocoaUIBase,
         view = factory.uiView(forAudioUnit: bridge.audioUnit, withSize: NSSize(480, 320))
      non-nil view      -> (BodyHostViewController(view), .custom, carried warning)
      any step fails    -> continue (append readable note to warning)
3. generic = AUGenericViewController(); generic.auAudioUnit = au
                        -> (generic, .generic, carried warning)
```

Step 3 cannot fail (plain init + property set), which is what makes `plugin.openUI` total for any
`.ready` instance. In **cycle vi-b-1 only step 3 ships**; steps 1–2 are cycle vi-b-2 (§8).

### 3.3 The completion→async bridge (exact shape, load-bearing)

```swift
/// Sources/DAWApp/PluginUI/AUViewResolver.swift
@MainActor
static func requestViewControllerOnMain(_ au: AUAudioUnit,
                                        timeout: Duration) async -> RequestOutcome {
    await withCheckedContinuation { continuation in
        let gate = ResumeGate(continuation)          // copy of the AUHostRegistry idiom
        au.requestViewController { vc in
            // Header contract: this closure may run on ANY thread. `vc` is the
            // sole reference (transfer semantics); move it to the main actor
            // before ANY use — AppKit objects are main-thread-only.
            nonisolated(unsafe) let transfer = vc
            Task { @MainActor in gate.resume(.viewController(transfer)) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            gate.resume(.timedOut)                   // abandoned completion is harmless:
        }                                            // gate resumes exactly once
    }
}
```

- The timeout race copies `AUHostRegistry.raceAgainstTimeout`'s unstructured-task + once-gate
  pattern (AUHostRegistry.swift:437–471) — a stalled extension can never wedge the main actor.
- If the completion fires AFTER the timeout won, the late `gate.resume` is a no-op; the orphaned
  view controller is released on the main actor. Never call `requestViewController` twice
  concurrently for the same AU (the manager serializes opens per target — §4.4).

### 3.4 `AUViewProbe` (DAWEngine, headless-testable)

```swift
/// Sources/DAWEngine/AudioUnits/AUViewProbe.swift  (cycle vi-b-2)
@MainActor
public enum AUViewProbe {
    public struct CocoaViewInfo: Sendable { public let bundleURL: URL; public let className: String }
    /// kAudioUnitProperty_CocoaUI on a raw v2 AudioUnit handle; nil when the
    /// unit publishes no custom Cocoa view (the common case for Apple units).
    public static func cocoaViewInfo(_ unit: AudioUnit) -> CocoaViewInfo?
}
```
Pure AudioToolbox (`AudioUnitGetPropertyInfo`/`AudioUnitGetProperty`, correct CF memory handling:
the returned CFURL/CFString follow the Get rule — take ownership and release). No AppKit — it can
live in DAWEngine and be tested headless against AUDelay (expected nil) and, when present on the
machine, any third-party v2 unit (expected non-nil). The bundle-loading + factory + NSView half
stays in DAWApp (AppKit, live-gate-proven only).

---

## 4. Window model (Decision 3, in full)

### 4.1 Ownership and modules

- `PluginWindowManager` (`Sources/DAWApp/PluginUI/PluginWindowManager.swift`, new, `@MainActor`)
  — implements the DAWControl seam (§5), owns `[PluginUITarget: PluginPanelController]`, owned by
  `AppModel` (strong), referenced by `CommandRouter` weakly (the `copilotEngine` precedent,
  DAWProApp.swift:387–392).
- `PluginPanelController` (`Sources/DAWApp/PluginUI/PluginPanelController.swift`, new) — one
  `NSPanel` + chrome + embedded body VC + `NSWindowDelegate`.
- `PluginWindowLedger` (`Sources/DAWAppKit/PluginWindowLedger.swift`, new) — PURE bookkeeping so
  the state model tests headless (DAWAppKit is the sanctioned home for exactly this,
  Package.swift:49–52): keys, per-key `ObjectIdentifier` instance stamps, cascade-frame math,
  open/focus/close transitions, snapshot values. No AppKit import; geometry in CGRect/CGPoint
  (CoreGraphics is already in DAWAppKit's diet via existing geometry models).

### 4.2 Window construction (glass chrome per docs/DESIGN-LANGUAGE.md)

```
NSPanel(contentRect:…, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
  titleVisibility = .hidden; titlebarAppearsTransparent = true
  standardWindowButton(.miniaturizeButton/.zoomButton)?.isHidden = true   // native close stays
  isReleasedWhenClosed = false; hidesOnDeactivate = false
  level = .floating; collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
  isMovableByWindowBackground = true (chrome header only)
contentView = NSStackView(vertical):
  [ NSHostingView(PluginChromeHeader(...)) fixed 34 pt,
    body view (vendor NSView / generic VC's view) ]
```

`PluginChromeHeader` (`Sources/DAWApp/PluginUI/PluginChromeHeader.swift`, SwiftUI): background
`DAWTheme.panel`, bottom `DAWTheme.hairline`, title = "PluginName" (`textPrimary`, 13 semibold),
subtitle = "TrackName · ManufacturerName" (`textDim`, 11), a 2 pt `DAWTheme.playback` (cyan)
accent line under the header while the panel is key. **Neutral/cyan only — violet is reserved for
AI meaning and never appears here.** The vendor body is accepted as-is (it will not match the
theme; that is expected and correct). Generic bodies (`AUGenericViewController`) are Apple chrome
inside our frame — acceptable for v1; a themed generic editor is a labeled future item, NOT scope.

Sizing: body preferred size = v3 `preferredContentSize` if non-zero, else the resolved view's
`frame.size` if non-zero, else 480×320. Clamp body to [320×180, screen.visibleFrame − chrome].
Follow-up resizes: observe `NSView.frameDidChangeNotification` on the body (v2 views self-resize)
with a reentrancy guard; `preferredContentSize` KVO is out of scope for v1.

Placement: default = deterministic cascade from the ledger
(`x = visible.minX + 140 + 28·(n mod 10)`, `topY = visible.maxY − 120 − 28·(n mod 10)`, n = count
of currently open plugin windows). Explicit `x`/`y` params (top-left-origin screen points, the
agent-friendly convention) pin the origin exactly: AppKit conversion
`frame.origin.y = screen.frame.maxY − y − frame.height`. The ACTUAL frame (same top-left
convention) is always returned in the command result — that is what makes captures deterministic.

Show: `makeKeyAndOrderFront(nil)` + `orderFrontRegardless()` (the app may be backgrounded during
wire-driven verification runs — same reasoning as the WindowGroup activation hack,
DAWProApp.swift:19–24).

### 4.3 Lifecycle matrix (the contract)

| Trigger | Mechanism | Window behavior |
|---|---|---|
| `plugin.closeUI` / chrome close button / user ⌘W | `panel.close()` → `windowWillClose` → manager unregisters | closed; `listOpenUIs` reflects immediately |
| Effect removed / track removed / instrument switched off AU | `syncAudioUnitEffects`/`syncAudioUnitInstruments` → `registry.release…` → `onRelease` → `hostedAUReleased` → manager closes | auto-close, same turn as the model change |
| `project.open` / `project.new` | same path (old tracks leave the model → releases) | all plugin windows close |
| AU config change incl. `stateData` identity change (PrepareKey mismatch) | release-then-re-prepare (AudioEngine.swift:580–592, 629–650) → `onRelease` | close; v1 does NOT auto-reopen (documented) |
| Device/sample-rate change that alters the graph rate | PrepareKey contains sampleRate → same release path | close (v1 accepted) |
| `recoverEngine()` / `watchdogRestart()` (crash-a/c) | registry NOT touched (verified AudioEngine.swift:1309–1387 — recovery restarts players/engine only) | windows STAY OPEN; instance identity unchanged |
| App quit | AppKit teardown; `windowWillClose` may fire during termination | no special handling beyond nil-safe manager callbacks |
| Reopen while open | manager finds key, verifies `ObjectIdentifier(au)` stamp | focus + `alreadyOpen: true`; if the stamp is stale (instance swapped between callback and command — belt-and-braces), close old, open fresh |

The single-source rule: **the ONLY invalidation authority is the registry release callback.** The
manager never watches `ProjectStore` — that would create a second, racy source of truth. The stamp
check on reopen is the only defensive redundancy.

### 4.4 Open serialization

`openUI` is async (view resolution awaits). The manager keeps `pendingOpens: Set<PluginUITarget>`;
a second open for a target already resolving returns the readable error
`"plugin UI for this target is already opening"` (agents retry; simpler and more honest than
queueing). Different targets open concurrently without interference.

---

## 5. Control surface (Decision 4, in full)

### 5.1 Why an app-layer seam and not ProjectStore

Plugin windows are session/view state, not project state — they must not enter `ProjectStore`
(DAWCore is UI-free, Principle 3) and must not persist. The codebase already has the app-layer
command precedent (`appCommandHandler` serving `debug.*`/`ui.*`, Commands.swift:72–84 and
DAWProApp.swift:477–546), but that seam is synchronous and excluded from `allCommands`. Plugin UI
control is a first-class agent capability, so it gets a first-class, **typed, async** seam and
full `allCommands` + MCP membership. The `plugin.*` namespace is already reserved in
docs/ARCHITECTURE.md ("Control protocol (v0)" namespace list) — this item is its first occupant.

### 5.2 New DAWControl types

File: `Sources/DAWControl/PluginUISurface.swift` (new — keeps Commands.swift growth bounded):

```swift
public enum PluginUITarget: Hashable, Sendable {
    case instrument(trackID: UUID)
    case effect(trackID: UUID, effectID: UUID)
}

public struct PluginUIWindowInfo: Sendable {
    public var trackID: UUID
    public var effectID: UUID?                       // nil = instrument window
    public var title: String                         // "DLSMusicDevice — Keys"
    public var componentName: String
    public var manufacturerName: String
    public var isV3: Bool
    public var body: BodyKind
    public var frame: Frame                          // top-left-origin screen points
    public var warning: String?
    public enum BodyKind: String, Sendable { case custom, generic }
    public struct Frame: Sendable { public var x, y, width, height: Double }
}

@MainActor
public protocol PluginUIControlling: AnyObject {
    /// Opens (or focuses) the window for a validated target. x/y pin the
    /// top-left origin in screen points; nil = deterministic cascade.
    func openUI(_ target: PluginUITarget, x: Double?, y: Double?) async throws
        -> (info: PluginUIWindowInfo, alreadyOpen: Bool)
    /// True if a window was open and is now closed; false = honest no-op.
    func closeUI(_ target: PluginUITarget) -> Bool
    func listOpenUIs() -> [PluginUIWindowInfo]
}
```

`CommandRouter` gains `public weak var pluginUI: (any PluginUIControlling)?` (weak; AppModel owns
the manager — the copilotEngine wiring shape).

### 5.3 Commands (wire shapes)

Add to `CommandRouter.allCommands` (Commands.swift:94): `"plugin.openUI"`, `"plugin.closeUI"`,
`"plugin.listOpenUIs"` → **98 → 101 commands; MCP 101 → 104 tools; run /mcp-verify after wiring.**

**`plugin.openUI {trackId, effectId?, x?, y?}`** — async case (the router is already async).
Validation order (all headless-testable BEFORE the seam check):
1. `params.requireTrackID()`; track must exist → else the standard `noTrack` error.
2. If `effectId` present: `requireEffectID()`; effect must exist on that track → `effectNotFound`;
   `effect.kind == .audioUnit` → else `"effect '<id>' is a built-in <kind> — plugin windows apply
   only to Audio Unit effects"`.
3. Else: `track.kind == .instrument` and `(track.instrument ?? .default).kind == .audioUnit` →
   else `"track '<id>' uses the built-in <kind> instrument — plugin windows apply only to Audio
   Unit instruments"`.
4. `pluginUI != nil` → else `"plugin UI unavailable — this control session has no app UI
   (headless). Launch DAWApp/DAWPro.app and retry."`
5. `try await pluginUI.openUI(target, x:, y:)`.

Result:
```json
{"trackId":"…","effectId":"…"|absent,"title":"AUDelay — Drums",
 "component":{"name":"AUDelay","manufacturerName":"Apple","isV3":false},
 "body":"generic","alreadyOpen":false,
 "frame":{"x":140,"y":120,"width":480,"height":354},
 "warning":"custom view request timed out after 5s"|absent}
```

**`plugin.closeUI {trackId, effectId?}`** — validates UUID SYNTAX only (no store lookup: the
target may have just been removed, and idempotent close is the agent-friendly contract). Seam nil
→ same headless error. Result: `{"closed": true|false}`.

**`plugin.listOpenUIs {}`** — never errors. Result:
`{"available": bool, "windows": [ …openUI result objects… ]}` with `available:false, windows:[]`
when the seam is nil (the honest headless answer).

Manager-side error taxonomy (thrown from `openUI` as `LocalizedError`, surfaced verbatim by
`CommandRouter.handle`'s existing mapping, Commands.swift:225–237):

| Condition | Message shape |
|---|---|
| Registry has no ready instance | `"Audio Unit is not ready (status: pending) — retry once prepared"` / `(status: missing)` / `(status: failed: <reason>)` — status via `audioUnitStatus(forTrack:)` / new `audioUnitEffectStatus(forEffect:)` |
| Concurrent open in flight | `"plugin UI for this target is already opening"` |
| View resolution timeout | NOT an error — generic body + `warning` field (ladder is total) |

### 5.4 MCP tools (mcp-server/src/server.ts)

Three tools, standard `bridge.send` passthrough (the `fx_add` pattern, server.ts:954–1005):
- `plugin_open_ui` — zod: `trackId: string.uuid`, `effectId?: string.uuid`, `x?/y?: number`.
  Description must state: opens the LIVE plugin's window (edits affect sound immediately), body
  `"generic"` means the system parameter view (normal for Apple stock units), headless sessions
  error readably, and the returned `frame` is top-left-origin screen points for captures.
- `plugin_close_ui` — `trackId`, `effectId?`; explain idempotent `closed:false`.
- `plugin_list_open_uis` — no params; explain `available:false` = app has no UI in this session.

### 5.5 App wiring (DAWProApp.swift)

In `AppModel.init` next to the router wiring (DAWProApp.swift:383–393):
```swift
let pluginWindows = PluginWindowManager(engine: engine, store: store)
self.pluginWindows = pluginWindows
router.pluginUI = pluginWindows
engine.hostedAUReleased = { [weak pluginWindows] endpoint in
    pluginWindows?.hostedAUReleased(endpoint)
}
```
UI affordances (same manager, one command surface): a small window glyph on the AU rows in
`Sources/DAWApp/Mixer/MixerStripView.swift` and on the AU instrument selection in the instrument
panel — both call `pluginWindows.openUI/closeUI` via `AppModel`. Keep them to one button each.

### 5.6 `debug.captureUI` extension (capture staging)

Extend the existing handler (DAWProApp.swift:1377–1443): optional `target: "main"|"plugin"`
(default `"main"`), with `trackId` (+ `effectId`) selecting the plugin window when `"plugin"`.
Implementation: `pluginWindows.window(for:)` → same `cacheDisplay(in:to:)` path on that panel's
contentView; readable error when the window isn't open. KNOWN LIMIT (document in the command
comment): an out-of-process AUv3 remote view rasterizes blank through `cacheDisplay` — the capture
then proves chrome + frame only; `plugin.listOpenUIs` remains the functional assertion. In-process
bodies (all of cycle 1: generic + v2 views) capture fully.

---

## 6. Bare vs bundled (Decision 6, in full)

`scripts/bundle.sh` → ad-hoc-signed `dist/DAWPro.app` exists (docs/PACKAGING.md), lifting the
vi-a deferral (ROADMAP.md:156) — but dev runs remain the bare SPM binary, so the matrix below is
the contract. **Cycle vi-b-1 must be fully provable bare.**

| Path | bare `swift run DAWApp` | `dist/DAWPro.app` |
|---|---|---|
| Generic body (`AUGenericViewController`) — all Apple stock v2 units | WORKS (plain AppKit; NSApplication is made regular at launch, DAWProApp.swift:19–24) | works |
| v2 custom Cocoa views (`kAudioUnitProperty_CocoaUI`, in-process bundle load) | expected WORKS (ordinary NSBundle + NSView; no bundle identity involved) | works |
| v3 in-process custom VC (`.loadInProcess` succeeded — registry tries it first, AUHostRegistry.swift:260–265) | works when the extension permits in-process loading (rare) | works |
| v3 OUT-OF-PROCESS custom VC (remote view over the extension's view service) | UNRELIABLE — the recorded vi-a finding ("the current bare SPM executable can't reliably host plugin view extensions", ROADMAP.md:156). Ladder step 1 times out or nils → generic body + `warning`. NEVER a hard failure. | expected works — verify in the vi-b-2 gate; ad-hoc signing caveats per docs/PACKAGING.md |
| `debug.captureUI target:plugin` pixels | full pixels for generic/v2 bodies; blank body for remote views | same limitation (remote layer) |

No entitlements, no AUv3 target of our own, no notarization → **nothing in this item requires
full Xcode**; `bundle.sh` (swift build + codesign ad-hoc) suffices for the bundled leg.

---

## 7. Test strategy (Decision 5, in full)

Runner: `./scripts/test.sh` (never bare `swift test`). Baselines to preserve: 1479/178 Swift,
npm 19/19; expect +~25 Swift tests.

### 7.1 Headless — DAWControlTests (`Tests/DAWControlTests/PluginUICommandTests.swift`, new)

Fake seam (`final class FakePluginUI: PluginUIControlling` recording calls, scripted results):
1. `allCommands` contains the three commands (parity guard for /mcp-verify).
2. `plugin.openUI` taxonomy WITHOUT the fake installed, in order: missing trackId; malformed
   trackId; unknown track; builtin instrument track; audio track with no `effectId`; unknown
   effectId; builtin-kind effect; THEN (valid target, seam nil) the headless error — proving
   validation precedes the seam check.
3. With fake installed: target/x/y arrive correctly for instrument and effect shapes; result JSON
   carries frame/body/alreadyOpen/warning; thrown manager errors surface verbatim.
4. `plugin.closeUI`: syntax-only validation (unknown-but-well-formed ids reach the fake);
   `closed:false` passthrough; headless error when seam nil.
5. `plugin.listOpenUIs`: `{available:false, windows:[]}` seam-nil; window list mapping with fake.

### 7.2 Headless — DAWAppKitTests (`Tests/DAWAppKitTests/PluginWindowLedgerTests.swift`, new)

Cascade determinism (index n → exact origin, wrap at 10), register/unregister/focus transitions,
stale-stamp detection (`isStale` true iff live `ObjectIdentifier` differs or is nil), snapshot
ordering stability (sorted by open sequence — deterministic `listOpenUIs`).

### 7.3 Headless — DAWEngineTests (extend `AUHostingTests.swift` / `AUEffectHostingTests.swift`)

These suites ALREADY instantiate real system AUs headless (DLSMusicDevice, AUMIDISynth, AUDelay)
— reuse that:
1. `hostedInstrumentAudioUnit(forTrack:)` returns the IDENTICAL object (`===`) to
   `preparedInstrument(forTrack:).auAudioUnit` after a real DLS prepare; nil before prepare and
   for unknown ids. Effect twin against AUDelay.
2. `onRelease`/`hostedAUReleased` fires with the right endpoint on: config change re-prepare,
   track leaving the model, effect leaving the model (drive `tracksDidChange` exactly as existing
   sync tests do); does NOT fire for no-op releases; does NOT fire across
   `recoverEngine()`/`watchdogRestart()` (assert zero callbacks — pins the windows-survive-recovery
   contract).
3. (vi-b-2) `AUViewProbe.cocoaViewInfo` — nil for AUDelay's bridge handle; struct memory handling
   exercised without leaks (run under the existing suite; no view is created).

NOT headless-testable, by design: NSPanel behavior, actual view creation, `requestViewController`
against real extensions — the live gate owns those. Keep the untestable AppKit slab thin and
defensive; anything decision-shaped stays in the ledger/probe/router where tests reach it.

### 7.4 Live gate (orchestrator-run; ports 17695 orchestrator / 17696–17698 agents)

Environment: this Mac, bare binary first (`DAW_CONTROL_PORT=17695 swift run DAWApp`). System AUs
only — always present: DLSMusicDevice (`aumu/dls /appl`, v2, no custom view → generic body) and
AUDelay (`aufx/dely/appl`, v2, no custom view → generic body).

1. `track.add {kind:"instrument"}` → `track.setInstrument {trackId, audioUnit:{subType:"dls ",
   manufacturer:"appl"}}`; poll `plugin.openUI` until the not-ready error clears (or ~2 s).
2. `plugin.openUI {trackId, x:120, y:90}` → assert ok, `body:"generic"`, frame echoes 120/90.
3. `debug.captureUI {target:"plugin", trackId, path:…}` → PNG exists; chrome title row visible;
   parameter rows non-blank (in-process generic view rasterizes).
4. `fx.add {trackId2, kind:"audioUnit", audioUnit:{subType:"dely", manufacturer:"appl"}}` →
   `plugin.openUI {trackId2, effectId}` → capture → `plugin.listOpenUIs` shows BOTH with correct
   targets/frames.
5. Reopen focus: second `plugin.openUI` on the instrument → `alreadyOpen:true`, count still 2.
6. `plugin.closeUI` (effect) → `closed:true`; list shows 1.
7. Auto-close: reopen effect window, `fx.remove {trackId2, effectId}` → list shows 1 (instrument
   only) with NO close command — proves the release-callback path.
8. Recovery survival (optional but cheap): `debug`-drive `watchdogTick`? No — out of wire scope;
   the headless test in 7.3(2) pins it instead.
9. `project.new` → list shows 0.
10. Param-edit-affects-sound proxy (identity, not audio): headless test 7.3(1) already proves the
    window binds the sounding instance; the gate additionally does `fx.setParam`-free sanity —
    open UI, `project.save`, confirm save succeeds (state capture path unaffected).
11. vi-b-2 adds: bundled leg (`bash scripts/bundle.sh`, launch `dist/DAWPro.app` with
    `DAW_CONTROL_PORT`), and — if any AUv3 with a UI is installed on the runner — a
    `body:"custom"` open; otherwise that assertion is SKIPPED and recorded, never faked.

---

## 8. Implementation plan (two cycles)

### Cycle vi-b-1 — "plugin windows: plumbing + generic body" (fully provable bare)

| Step | File(s) | Work |
|---|---|---|
| 1 | `Sources/DAWEngine/AudioUnits/AUHostRegistry.swift` | `HostedAUEndpoint`, `onRelease`, fire in both release paths (§2.2) |
| 2 | `Sources/DAWEngine/AudioEngine.swift` | two accessors, `hostedAUReleased` forwarding, `audioUnitEffectStatus` |
| 3 | `Sources/DAWCore/EngineProtocol.swift` | additive `audioUnitEffectStatus(forEffect:) -> AudioUnitTrackStatus?` + nil default |
| 4 | `Sources/DAWControl/PluginUISurface.swift` (new) | target/info/protocol types (§5.2) |
| 5 | `Sources/DAWControl/Commands.swift` | `pluginUI` seam, 3 cases + validation helper, `allCommands` +3 |
| 6 | `Sources/DAWAppKit/PluginWindowLedger.swift` (new) | pure bookkeeping (§4.1) |
| 7 | `Sources/DAWApp/PluginUI/PluginWindowManager.swift`, `PluginPanelController.swift`, `PluginChromeHeader.swift`, `AUViewResolver.swift` (new dir) | manager + panel + chrome; resolver = step-3-only ladder (generic body) |
| 8 | `Sources/DAWApp/DAWProApp.swift` | AppModel wiring (§5.5), `debug.captureUI` target extension (§5.6) |
| 9 | `Sources/DAWApp/Mixer/MixerStripView.swift` + instrument panel | one open-window button each |
| 10 | `mcp-server/src/server.ts` | 3 tools (§5.4); `npm run build`; /mcp-verify |
| 11 | `Tests/…` per §7.1–7.3 | new suites + extensions |
| 12 | docs | ROADMAP vi-b-1 checkbox; ARCHITECTURE.md: settle "plugin windows" under Key future decisions + record the DAWEngine boundary exception (§2.2) |

### Cycle vi-b-2 — "vendor views" 

| Step | File(s) | Work |
|---|---|---|
| 1 | `Sources/DAWEngine/AudioUnits/AUViewProbe.swift` (new) | CocoaUI probe (§3.4) + engine test |
| 2 | `Sources/DAWApp/PluginUI/AUViewResolver.swift` | full ladder: async bridge + timeout gate (§3.3), v2 bundle/factory path, warning plumbing |
| 3 | `Sources/DAWApp/PluginUI/PluginPanelController.swift` | v3 `preferredContentSize` sizing, `frameDidChangeNotification` follow with reentrancy guard |
| 4 | gate | bundled AUv3 leg + custom-body assertion (skip-if-absent), §7.4(11) |
| 5 | docs | PACKAGING.md note (out-of-proc views need the bundle); ROADMAP vi-b-2 |

---

## 9. Alternatives considered (strongest two per major call)

1. **Intent-state in ProjectStore** (declarative `openPluginUIs` set, app reconciles into windows)
   — keeps "everything converges on ProjectStore" literal. LOSES: smears session UI state into the
   UI-free domain model; headless commands would "succeed" while materializing nothing (dishonest
   result), or need an availability back-channel that reinvents the seam anyway; adds a reconcile
   race against registry releases. The typed app seam keeps honesty and testability.
2. **Generalizing `appCommandHandler`** (route `plugin.*` through the existing untyped sync hook)
   — smallest diff. LOSES: it is synchronous (view resolution is async), untyped (taxonomy tests
   degrade to string checks), and by convention excluded from `allCommands`/MCP parity — plugin
   windows are a first-class capability, not a debug affordance.
3. **SwiftUI `WindowGroup(for: PluginUIKey.self)` windows** instead of NSPanels — LOSES:
   `openWindow` is view-environment-scoped (awkward from a command path), frame pinning for
   deterministic captures is indirect, floating level + vendor-NSView embedding + close
   interception all fight the SwiftUI window model. AppKit panels are the boring right tool.
4. **Own themed generic parameter editor in v1** instead of `AUGenericViewController` — LOSES on
   scope: parameter observation (KVO tokens arrive off-main), indexed/boolean/ramped parameter
   kinds, and value formatting are exactly the long tail that sinks a "small" v1. Apple's generic
   VC is one property assignment and works for v2-bridge AND v3. Revisit as polish later.
5. **Engine-side window manager** (DAWEngine owns NSPanels, no AUAudioUnit export) — LOSES:
   AppKit/CoreAudioKit inside the audio module inverts the layering worse than the narrow
   accessor exception, and makes the engine untestable headless.

---

## 10. Failure modes & mitigations

1. **`AUGenericViewController` renders empty for v2-bridged units** (undocumented corner; believed
   fine — the bridge populates `parameterTree`). Mitigation: gate step 3 asserts non-blank
   parameter rows; CONTINGENCY (one branch, pre-approved): fall back to `AUGenericView(audioUnit:
   bridge.audioUnit)` (macOS 10.4+, verified header §3.1) for bridge units with empty trees.
2. **Broken extension never calls the completion** — timeout gate (§3.3) abandons it; generic body
   + warning; main actor never wedges (registry precedent).
3. **Vendor view resize storms / zero preferred sizes** — clamp [320×180, visibleFrame], observer
   reentrancy guard, default 480×320.
4. **Remote-view captures blank** — documented limit (§5.6); gate asserts chrome + `listOpenUIs`.
5. **Window outlives the instance** (VC retains AU after release) — harmless (ObjC object outlives
   its render resources; render path already tolerates dead AUs via error-path silence/dry), and
   the release callback closes the window in the same main-actor turn anyway. The panel is closed
   BEFORE `deallocateRenderResources` (§2.2 ordering) so observing views detach against a live AU.
6. **Double-open races** — per-target `pendingOpens` (§4.4).
7. **Key-window stealing / shortcut interception by NSPanel** — panels are `.floating` and can
   become key (needed for text fields in vendor UIs); main-window menu commands stay functional
   because panels don't become MAIN. Verify manually in the gate; if a vendor view swallows ⌘W,
   accept (its window, its keys).
8. **Swift 6 diagnostics on the completion transfer** — the `nonisolated(unsafe) let` +
   `Task { @MainActor }` shape (§3.3) is the sanctioned pattern; do NOT mark anything Sendable and
   do NOT touch the VC off-main "just to check nil" (nil-check the transferred binding after the
   hop).

**Hard risk that could sink vi-b-2** (NOT vi-b-1): out-of-process AUv3 view hosting may fail even
from the ad-hoc-signed bundle (signing/identity requirements of the view-service handshake are
undocumented). De-risk BEFORE committing to vi-b-2's gate scope: a 30-line spike — instantiate any
installed AUv3 with `.loadOutOfProcess`, `requestViewController`, attach to a bare NSWindow — run
once bare, once from `dist/DAWPro.app`, record both outcomes in the vi-b-2 plan. vi-b-1 is immune
by construction (generic bodies only).

---

## 11. Documentation obligations for the implementing cycles

- `docs/ARCHITECTURE.md` → "Key future decisions": add **"Plugin UI windows: SETTLED (M3 vi-b,
  2026-07-10)"** summarizing §0 (this doc is the reference), and record the DAWEngine
  `AUAudioUnit`-accessor boundary exception next to the module-leak rule.
- `docs/ROADMAP.md`: replace the single vi-b line with vi-b-1 / vi-b-2 sub-items (checkbox on land).
- `docs/PACKAGING.md` (vi-b-2): out-of-process AUv3 view note per §6.
- MCP parity: /mcp-verify after the +3 tools; command/tool counts move 98→101 / 101→104.

---

## 12. ADDENDUM — §10 spike outcome + machine inventory correction (orchestrator, 2026-07-10)

The §10 de-risk spike was resolved by inventory before any code was needed:

1. **No AUv3 exists on this machine.** `AVAudioUnitComponentManager` lists 64 components, 26 of
   type aumu/aufx/aumf — ALL v2 (`isV3AudioUnit` flag clear on every one), all Apple.
   `pluginkit -m -p com.apple.AudioUnit-UI` and `-p com.apple.AudioUnit` both return empty.
   The out-of-process AUv3 view spike therefore CANNOT run here; per §7.4(11) the vi-b-2 gate's
   AUv3 custom-view assertion is **SKIPPED-no-AUv3-installed, recorded, never faked**. The §10
   hard risk cannot materialize on this runner; the ladder still ships total-by-design, and a
   later machine with an AUv3 installed inherits the documented §6 degradation (generic body +
   warning at worst).
2. **CORRECTION to §3.1/§7.3/§7.4 assumptions:** 19 of the installed v2 units DO publish custom
   Cocoa views (`AVAudioUnitComponent.hasCustomView == true`), including **AUDelay, AUFilter,
   AUGraphicEQ, AUParametricEQ, DLSMusicDevice, AUSampler**. The design's claim that Apple stock
   units publish no custom view (and §7.3(3)'s "nil for AUDelay's bridge handle") is WRONG.
   Consequences for vi-b-2, which IMPROVE the gate:
   - `AUViewProbe.cocoaViewInfo` headless test: expect **non-nil for AUDelay**, and nil for a
     genuinely view-less unit — use **AUMatrixReverb (aufx/mrev/appl)** or AUSampleDelay (sdly).
   - The live gate can prove `body:"custom"` with system units: `fx.add dely` → custom v2 view;
     `fx.add mrev` → generic fallback. Both ladder branches live-provable on this machine.
   - vi-b-1's gate saw `body:"generic"` for these units ONLY because the resolver was
     step-3-only; after vi-b-2 the same opens yield `body:"custom"`. Any assertion pinning
     generic for dely/dls must be updated in the vi-b-2 gate script (headless suites use fakes
     and are unaffected).
