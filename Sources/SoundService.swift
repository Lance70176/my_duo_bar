import AudioToolbox
import CoreAudio

/// The default output device as the sound submenu sees it.
struct SoundOutput: Equatable, Sendable {
    var name: String
    /// 0...1, or nil when the device doesn't report a volume.
    var volume: Float?
    /// The device's own mute switch, or nil when it has none.
    var muted: Bool?
    var canSetVolume = false
    var canSetMute = false

    static var unavailable: SoundOutput { SoundOutput(name: L10n.soundOutputUnavailable) }

    /// Zero volume is silent too, even when the mute switch is off.
    var isMuted: Bool { muted == true || volume == 0 }
    /// Devices without a mute switch are muted by zeroing their volume.
    var canToggleMute: Bool { canSetMute || (canSetVolume && volume != nil) }
    var percent: Int? { volume.map { max(0, min(100, Int(($0 * 100).rounded()))) } }
}

/// Reads and changes the default output device. Uses the virtual main volume, which macOS derives for
/// devices that only expose per-channel volume, so the slider behaves like the system one.
enum SoundService {
    private static var volumeAddress: AudioObjectPropertyAddress {
        SystemReaders.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }
    private static var muteAddress: AudioObjectPropertyAddress {
        SystemReaders.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        let device: AudioDeviceID? = SystemReaders.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        guard let device, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func read() -> SoundOutput {
        guard let device = defaultOutput() else { return .unavailable }
        var output = SoundOutput(name: SystemReaders.string(device, kAudioObjectPropertyName) ?? L10n.currentOutputDevice)
        output.volume = SystemReaders.value(device, volumeAddress.mSelector, scope: volumeAddress.mScope)
        output.canSetVolume = output.volume != nil && settable(device, volumeAddress)
        let mute: UInt32? = SystemReaders.value(device, muteAddress.mSelector, scope: muteAddress.mScope)
        output.muted = mute.map { $0 != 0 }
        output.canSetMute = output.muted != nil && settable(device, muteAddress)
        return output
    }

    @discardableResult
    static func setVolume(_ volume: Float) -> Bool {
        guard let device = defaultOutput() else { return false }
        return set(device, volumeAddress, Float32(max(0, min(1, volume))))
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutput() else { return false }
        return set(device, muteAddress, UInt32(muted ? 1 : 0))
    }

    private static func settable(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func set<T: BitwiseCopyable>(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}
