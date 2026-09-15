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

/// An output device the Sound submenu can switch to.
struct AudioOutputDevice: Equatable, Sendable {
    var id: UInt32
    var name: String
    var symbol: String
    var isHeadphone: Bool
    var isDefault: Bool

    /// SF Symbol for a device, from its name and how it is connected.
    static func symbol(name: String, transport: UInt32?, headphone: Bool) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if headphone { return "headphones" }
        switch transport {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "speaker.wave.2.fill"
        }
    }
}

extension SoundService {
    /// Devices that can play sound and be chosen as the default output, as the system Sound menu lists them.
    static func outputDevices() -> [AudioOutputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let devices: [AudioDeviceID] = SystemReaders.values(system, kAudioHardwarePropertyDevices)
        let current = defaultOutput()
        return devices.compactMap { device -> AudioOutputDevice? in
            let alive: UInt32 = SystemReaders.value(device, kAudioDevicePropertyDeviceIsAlive) ?? 0
            let hidden: UInt32 = SystemReaders.value(device, kAudioDevicePropertyIsHidden) ?? 0
            let canBeDefault: UInt32 = SystemReaders.value(device, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                           scope: kAudioDevicePropertyScopeOutput) ?? 0
            let streams: [AudioStreamID] = SystemReaders.values(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            guard alive != 0, hidden == 0, canBeDefault != 0, !streams.isEmpty,
                  let name = SystemReaders.string(device, kAudioObjectPropertyName) else { return nil }
            let headphone = SystemReaders.isHeadphone(device, name: name, streams: streams)
            let transport: UInt32? = SystemReaders.value(device, kAudioDevicePropertyTransportType)
            return AudioOutputDevice(id: device, name: name, symbol: AudioOutputDevice.symbol(name: name, transport: transport, headphone: headphone),
                                     isHeadphone: headphone, isDefault: device == current)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Makes a device the default output, like choosing it in the system Sound menu.
    @discardableResult
    static func selectOutput(id: UInt32) -> Bool {
        let address = SystemReaders.address(kAudioHardwarePropertyDefaultOutputDevice)
        return set(AudioObjectID(kAudioObjectSystemObject), address, AudioDeviceID(id))
    }
}

/// An input device the Sound submenu can switch to.
struct AudioInputDevice: Equatable, Sendable {
    var id: UInt32
    var name: String
    var symbol: String
    var isDefault: Bool

    /// SF Symbol for an input, from its name and how it is connected.
    static func symbol(name: String, transport: UInt32?) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "mic.fill"
        }
    }
}

extension SoundService {
    private static func defaultInput() -> AudioDeviceID? {
        let device: AudioDeviceID? = SystemReaders.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        guard let device, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// Devices that can record sound and be chosen as the default input, as the system Sound menu lists them.
    static func inputDevices() -> [AudioInputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let devices: [AudioDeviceID] = SystemReaders.values(system, kAudioHardwarePropertyDevices)
        let current = defaultInput()
        return devices.compactMap { device -> AudioInputDevice? in
            let alive: UInt32 = SystemReaders.value(device, kAudioDevicePropertyDeviceIsAlive) ?? 0
            let hidden: UInt32 = SystemReaders.value(device, kAudioDevicePropertyIsHidden) ?? 0
            let canBeDefault: UInt32 = SystemReaders.value(device, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                                           scope: kAudioDevicePropertyScopeInput) ?? 0
            let streams: [AudioStreamID] = SystemReaders.values(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            guard alive != 0, hidden == 0, canBeDefault != 0, !streams.isEmpty,
                  let name = SystemReaders.string(device, kAudioObjectPropertyName) else { return nil }
            let transport: UInt32? = SystemReaders.value(device, kAudioDevicePropertyTransportType)
            return AudioInputDevice(id: device, name: name, symbol: AudioInputDevice.symbol(name: name, transport: transport),
                                    isDefault: device == current)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Makes a device the default input, like choosing it in the system Sound menu.
    @discardableResult
    static func selectInput(id: UInt32) -> Bool {
        let address = SystemReaders.address(kAudioHardwarePropertyDefaultInputDevice)
        return set(AudioObjectID(kAudioObjectSystemObject), address, AudioDeviceID(id))
    }
}
