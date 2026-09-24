import IOBluetooth
import ObjectiveC

/// What a device reports about its battery: one level, or AirPods' left bud, right bud and case.
enum BluetoothBattery: Equatable, Sendable {
    case single(Int)
    case earbuds(left: Int?, right: Int?, case: Int?)

    /// One figure for the Bluetooth item's subtitle: the level, or the lower bud.
    var brief: String {
        switch self {
        case .single(let percent): return "\(percent)%"
        case .earbuds(let left, let right, let box):
            if let lowest = [left, right].compactMap({ $0 }).min() { return "\(lowest)%" }
            return box.map { "\($0)%" } ?? ""
        }
    }
    /// The full text for a device row, e.g. "95%" or "L 100% · R 90% · Case 86%".
    var summary: String {
        switch self {
        case .single(let percent): return "\(percent)%"
        case .earbuds(let left, let right, let box): return L10n.earbudsBattery(left: left, right: right, case: box)
        }
    }
}

/// A device paired with this Mac, as the Bluetooth submenu lists it.
struct BluetoothDevice: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case connected, disconnected, connecting, disconnecting

        var isOn: Bool { self == .connected || self == .connecting }
        var isTransitioning: Bool { self == .connecting || self == .disconnecting }
        var title: String {
            switch self {
            case .connected: return L10n.connected
            case .disconnected: return L10n.notConnected
            case .connecting: return L10n.vpnConnecting
            case .disconnecting: return L10n.vpnDisconnecting
            }
        }
    }

    /// The Bluetooth address; stable across renames.
    var id: String
    var name: String
    var symbol: String
    var status: Status
    /// The battery level while connected; nil when the device doesn't report one.
    var battery: BluetoothBattery?

    /// The status line under the name: "Connected · 81%" once the level is known.
    var detail: String {
        guard status == .connected, let battery else { return status.title }
        return status.title + " · " + battery.summary
    }
    /// The name with its level, for the list of connected devices under the Bluetooth item.
    var listing: String {
        guard status == .connected, let battery, !battery.brief.isEmpty else { return name }
        return name + " " + battery.brief
    }

    /// SF Symbol for a device, from its name and Bluetooth device class.
    static func symbol(name: String, major: UInt32, minor: UInt32) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if lower.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        switch major {
        case UInt32(kBluetoothDeviceClassMajorAudio):
            switch minor {
            case UInt32(kBluetoothDeviceClassMinorAudioLoudspeaker), UInt32(kBluetoothDeviceClassMinorAudioPortable),
                 UInt32(kBluetoothDeviceClassMinorAudioHiFi):
                return "hifispeaker.fill"
            default:
                return "headphones"
            }
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            // The low bits name the device, the high bits say whether it also has a keyboard or pointer.
            let kind = minor & 0x0F
            if kind == UInt32(kBluetoothDeviceClassMinorPeripheral2Gamepad) || kind == UInt32(kBluetoothDeviceClassMinorPeripheral2Joystick) {
                return "gamecontroller.fill"
            }
            switch minor & 0x30 {
            case UInt32(kBluetoothDeviceClassMinorPeripheral1Pointing): return "computermouse.fill"
            case UInt32(kBluetoothDeviceClassMinorPeripheral1Keyboard), UInt32(kBluetoothDeviceClassMinorPeripheral1Combo): return "keyboard"
            default: return "dot.radiowaves.left.and.right"
            }
        case UInt32(kBluetoothDeviceClassMajorPhone): return "iphone"
        case UInt32(kBluetoothDeviceClassMajorComputer): return "laptopcomputer"
        case UInt32(kBluetoothDeviceClassMajorWearable): return "applewatch"
        case UInt32(kBluetoothDeviceClassMajorImaging): return "printer.fill"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

/// What the Bluetooth submenu shows: whether the radio is on, and every paired device.
struct BluetoothState: Equatable, Sendable {
    /// nil when this Mac has no Bluetooth controller.
    var powered: Bool?
    var devices: [BluetoothDevice] = []

    static var unavailable: BluetoothState { BluetoothState(powered: nil) }

    var connectedNames: [String] { devices.filter { $0.status == .connected }.map(\.name) }
    /// The subtitle under the Bluetooth item: connected devices with their levels.
    var title: String {
        guard let powered else { return L10n.bluetoothUnavailable }
        guard powered else { return L10n.turnedOff }
        let listings = devices.filter { $0.status == .connected }.map(\.listing)
        return listings.isEmpty ? L10n.notConnected : listings.joined(separator: L10n.listSeparator)
    }
}

/// Reads paired devices and connects or disconnects them through IOBluetooth, the public framework the
/// system Bluetooth menu is built on. Nothing is paired, unpaired or discovered here.
///
/// Battery levels come from two places. Apple devices (Magic Trackpad, Magic Keyboard, AirPods) report
/// them through `IOBluetoothDevice` properties macOS keeps but doesn't declare publicly; they are looked
/// up at runtime and simply absent when missing. Other Bluetooth Low Energy devices are read through
/// `BLEBatteryReader`, which uses the standard Battery Service with Core Bluetooth.
enum BluetoothService {
    static func read() -> BluetoothState {
        guard let controller = IOBluetoothHostController.default() else { return .unavailable }
        let powered = controller.powerState == kBluetoothHCIPowerStateON
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let bleLevels = powered ? BLEBatteryReader.shared.levels() : [:]
        let devices = paired.compactMap { device -> BluetoothDevice? in
            guard let id = device.addressString, !id.isEmpty else { return nil }
            let name = device.name ?? device.nameOrAddress ?? id
            let symbol = BluetoothDevice.symbol(name: name, major: UInt32(device.deviceClassMajor), minor: UInt32(device.deviceClassMinor))
            let connected = device.isConnected()
            let battery = connected ? (appleBattery(device) ?? bleLevels[name].map { .single($0) }) : nil
            return BluetoothDevice(id: id, name: name, symbol: symbol, status: connected ? .connected : .disconnected, battery: battery)
        }
        return BluetoothState(powered: powered, devices: sorted(devices))
    }

    /// A level macOS keeps for Apple devices, read from an undeclared `IOBluetoothDevice` property. 0 means unknown.
    private static func percent(_ device: IOBluetoothDevice, _ property: String) -> Int? {
        let selector = NSSelectorFromString(property)
        guard device.responds(to: selector), let method = class_getInstanceMethod(type(of: device), selector),
              method_getTypeEncoding(method).map({ String(cString: $0) })?.hasPrefix("C") == true else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt8
        let value = unsafeBitCast(method_getImplementation(method), to: Getter.self)(device, selector)
        return value > 0 ? Int(min(value, 100)) : nil
    }

    static func appleBattery(_ device: IOBluetoothDevice) -> BluetoothBattery? {
        let left = percent(device, "batteryPercentLeft")
        let right = percent(device, "batteryPercentRight")
        let box = percent(device, "batteryPercentCase")
        if left != nil || right != nil || box != nil { return .earbuds(left: left, right: right, case: box) }
        return percent(device, "batteryPercentSingle").map { .single($0) }
    }

    /// Connected devices first, then by name, like the system Bluetooth menu.
    static func sorted(_ devices: [BluetoothDevice]) -> [BluetoothDevice] {
        devices.sorted {
            if $0.status.isOn != $1.status.isOn { return $0.status.isOn }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Opens the baseband connection; macOS then brings up the device's profiles (audio, input) itself.
    /// Blocks until the device answers or the attempt times out, so call it off the main thread.
    @discardableResult
    static func connect(id: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: id) else { return false }
        return device.openConnection() == kIOReturnSuccess
    }

    @discardableResult
    static func disconnect(id: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: id) else { return false }
        return device.closeConnection() == kIOReturnSuccess
    }
}
