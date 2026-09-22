import CoreAudio
import Foundation

/// System output volume and mute via public CoreAudio device properties.
/// No Accessibility, no other-app scanning.
enum SystemVolume {
    /// Typical macOS volume-key step (~1/16).
    static let step: Float = 1.0 / 16.0

    /// Virtual master volume FourCharCode ('vvol') when the device exposes it.
    private static let virtualMasterVolume: AudioObjectPropertySelector = 0x76766F6C

    /// Current output volume in 0...1. Nil if the default device has no software volume
    /// (common for some HDMI / TV sinks).
    static func volume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        if let v = scalar(device: device, selector: virtualMasterVolume) {
            return min(max(v, 0), 1)
        }
        // Built-in speakers expose a single master scalar on element 0 / Main.
        if let v = scalar(device: device, selector: kAudioDevicePropertyVolumeScalar, element: 0) {
            return min(max(v, 0), 1)
        }
        let left = scalar(device: device, selector: kAudioDevicePropertyVolumeScalar, element: 1)
        let right = scalar(device: device, selector: kAudioDevicePropertyVolumeScalar, element: 2)
        switch (left, right) {
        case let (l?, r?): return min(max((l + r) / 2, 0), 1)
        case let (l?, nil): return min(max(l, 0), 1)
        case let (nil, r?): return min(max(r, 0), 1)
        default: return nil
        }
    }

    /// Wing and volume overlay: crossed speaker at mute or 0%.
    static func showsCrossedSpeaker() -> Bool {
        ZonePolicy.wantsCrossedSpeaker(muted: isMuted(), level: volume())
    }

    static func isMuted() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        for element: AudioObjectPropertyElement in [0, 1, 2] {
            if let muted = muteValue(device: device, element: element) {
                return muted
            }
        }
        return false
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var ok = false
        for element: AudioObjectPropertyElement in [0, 1, 2] {
            if writeMute(device: device, element: element, muted: muted) {
                ok = true
            }
        }
        return ok
    }

    /// Toggle mute. Returns the new muted state (true = muted).
    @discardableResult
    static func toggleMute() -> Bool {
        let next = !isMuted()
        _ = setMuted(next)
        return isMuted()
    }

    /// Set the output level to 0...1. Unmutes when the new level is audible.
    @discardableResult
    static func setLevel(_ value: Float) -> Float? {
        writeLevel(value, unmute: value > 0.001 && isMuted())
    }

    /// Adjust volume by delta (−1...1). Unmutes when raising. Returns new volume 0...1.
    @discardableResult
    static func adjust(by delta: Float) -> Float? {
        let current = volume() ?? 0
        return writeLevel(current + delta, unmute: delta > 0 && isMuted())
    }

    @discardableResult
    private static func writeLevel(_ value: Float, unmute: Bool) -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        if unmute {
            _ = setMuted(false)
        }
        let next = min(max(value, 0), 1)
        if setScalar(device: device, selector: virtualMasterVolume, value: next) {
            return next
        }
        if setScalar(device: device, selector: kAudioDevicePropertyVolumeScalar, element: 0, value: next) {
            return next
        }
        let left = setScalar(device: device, selector: kAudioDevicePropertyVolumeScalar, element: 1, value: next)
        let right = setScalar(device: device, selector: kAudioDevicePropertyVolumeScalar, element: 2, value: next)
        guard left || right else { return nil }
        return volume()
    }

    // MARK: - Private

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func scalar(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement = 0
    ) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func setScalar(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement = 0,
        value: Float
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(device, &address, &settable)
        guard settable.boolValue else { return false }
        var v = value
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<Float>.size), &v
        )
        return status == noErr
    }

    private static func muteValue(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        guard status == noErr else { return nil }
        return muted != 0
    }

    @discardableResult
    private static func writeMute(device: AudioDeviceID, element: AudioObjectPropertyElement, muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(device, &address, &settable)
        guard settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )
        return status == noErr
    }
}
