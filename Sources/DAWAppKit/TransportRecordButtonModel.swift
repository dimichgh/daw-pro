import Foundation
import DAWCore

/// The transport's Record button (p2-sing-f2): whether it can be pressed, the sentence on its tooltip, and the
/// press itself.
///
/// The bar's pattern for a refused transport action is `LoopDeckControlModel`'s: a refusal the store WILL give is
/// predicted, and the button disables with the store's own sentence on its tooltip instead of accepting a press and
/// discarding it. Here that covers two cases: nothing armed (the bar's existing rule) and the voice recorder being
/// open (`ProjectStore.voiceRecorderOpenReason`). A refusal it cannot predict (microphone permission, the song
/// already playing, a loop too short, the engine) comes back from `press` in the store's words and goes on the same
/// tooltip. The press used to be `try? store.record()`, which threw that sentence away at the call site.
///
/// ⚠️ **This predicts the store's answer; it is not the store's answer.** `ProjectStore.record()` refuses on its
/// own while the recorder is open, so the wire (`transport.record`) and every other door meet the same sentence.
/// `TransportRecordButtonModelTests` drives a real store to keep the two in agreement.
///
/// No SwiftUI. `resolve` is pure; only `press` touches the store (on the main actor, like every store call).
public struct TransportRecordButtonModel: Equatable, Sendable {
    /// False: the button is drawn disabled and its tooltip says why.
    public var isEnabled: Bool
    /// The tooltip: what a press does, or why it cannot.
    public var help: String

    public init(isEnabled: Bool, help: String) {
        self.isEnabled = isEnabled
        self.help = help
    }

    /// While a take records, the button is Stop.
    public static let stopHelp = "Stop recording"
    public static let readyHelp = "Record onto armed tracks"
    public static let armFirstHelp = "Record — arm a track (R) first"

    /// The button's state. Order matters: a running take is always stoppable; the recorder's refusal is the
    /// store's FIRST gate, so it is shown first; then the last refusal (this press's own, else the store's last
    /// recording error from any door); then the arm hint.
    public static func resolve(isRecording: Bool, hasArmedTracks: Bool, recorderOpenReason: String?,
                               pressRefusal: String?, lastRecordingError: String?) -> TransportRecordButtonModel {
        if isRecording { return TransportRecordButtonModel(isEnabled: true, help: stopHelp) }
        if let recorderOpenReason { return TransportRecordButtonModel(isEnabled: false, help: recorderOpenReason) }
        if let refusal = pressRefusal ?? lastRecordingError {
            return TransportRecordButtonModel(isEnabled: hasArmedTracks, help: refusal)
        }
        return TransportRecordButtonModel(isEnabled: hasArmedTracks, help: hasArmedTracks ? readyHelp : armFirstHelp)
    }

    /// `resolve` read off a live store (what the bar draws).
    @MainActor
    public static func resolve(store: ProjectStore, pressRefusal: String?) -> TransportRecordButtonModel {
        resolve(isRecording: store.transport.isRecording,
                hasArmedTracks: store.hasArmedAudioTracks || store.hasArmedInstrumentTracks,
                recorderOpenReason: store.voiceRecorderOpenReason,
                pressRefusal: pressRefusal,
                lastRecordingError: store.lastRecordingError)
    }

    /// The press: Stop while a take records, otherwise the store's own `record()`. Returns the refusal in the
    /// store's words, or nil when the take started (or stopped). Never swallows a refusal.
    @MainActor
    public static func press(_ store: ProjectStore) -> String? {
        if store.transport.isRecording {
            store.stop()
            return nil
        }
        do {
            try store.record()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
