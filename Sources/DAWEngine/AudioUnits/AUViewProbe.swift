import AudioToolbox
import Foundation

/// Reads a v2 Audio Unit's custom-Cocoa-view advertisement
/// (`kAudioUnitProperty_CocoaUI`) from a raw `AudioUnit` handle (M3 vi-b-2,
/// design §3.4). Pure AudioToolbox — no AppKit — so it lives in DAWEngine and is
/// exercised headless against real system units (AUDelay publishes a view;
/// AUMatrixReverb does not). The DAWApp resolver takes the returned bundle URL +
/// class name and does the AppKit half (load the factory bundle, build the
/// `AUCocoaUIBase` view); that half is live-gate-proven only.
///
/// This is the step-2 leg of the never-failing view-resolution ladder: a nil
/// result simply means "no v2 custom view — fall through to the generic body."
@MainActor
public enum AUViewProbe {
    /// The factory-view advertisement: where the vendor's view bundle lives on
    /// disk and the `AUCocoaUIBase` class name inside it.
    public struct CocoaViewInfo: Sendable {
        public let bundleURL: URL
        public let className: String

        public init(bundleURL: URL, className: String) {
            self.bundleURL = bundleURL
            self.className = className
        }
    }

    /// `kAudioUnitProperty_CocoaUI` on a raw v2 `AudioUnit` handle (obtained from
    /// `AUAudioUnitV2Bridge.audioUnit`). Returns nil when the unit publishes no
    /// custom Cocoa view (the property is absent or empty), the advertised bundle
    /// is missing on disk, or the class name is blank — every "no usable custom
    /// view" case collapses to nil so the resolver falls through cleanly.
    ///
    /// CoreFoundation ownership: `AudioUnitGetProperty` returns the CFURL and
    /// CFString +1 (the Get rule for this property — Apple's CocoaAUHost sample
    /// `CFRelease`s both). `takeRetainedValue()` consumes that unbalanced retain,
    /// handing each object to ARC exactly once — no leak, no over-release.
    public static func cocoaViewInfo(_ unit: AudioUnit) -> CocoaViewInfo? {
        // Presence + size probe: absent property → no custom view.
        var dataSize: UInt32 = 0
        var writable: DarwinBoolean = false
        let infoStatus = AudioUnitGetPropertyInfo(
            unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0,
            &dataSize, &writable)
        guard infoStatus == noErr,
              dataSize >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else {
            return nil
        }

        // Read into raw storage sized to the reported dataSize (a unit may
        // advertise more than one class; the struct exposes the first, which is
        // the one hosts use). Zero-init so a short read can't yield garbage.
        let byteCount = Int(dataSize)
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        var readSize = dataSize
        let getStatus = AudioUnitGetProperty(
            unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &readSize)
        guard getStatus == noErr else { return nil }

        let viewInfo = raw.load(as: AudioUnitCocoaViewInfo.self)
        // Take + release (Get-rule ownership) regardless of whether we ultimately
        // return the info, so a discarded advertisement never leaks.
        let bundleURL = viewInfo.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = viewInfo.mCocoaAUViewClass.takeRetainedValue() as String

        // Sanity: a usable advertisement points at a bundle that exists on disk
        // and names a non-empty factory class. Anything else → treat as "no view".
        guard !className.isEmpty,
              FileManager.default.fileExists(atPath: bundleURL.path) else {
            return nil
        }
        return CocoaViewInfo(bundleURL: bundleURL, className: className)
    }
}
