import CoreBluetooth
import Foundation

/// Battery levels of the Bluetooth Low Energy devices macOS is connected to, such as third-party keyboards
/// and mice, read from the standard Battery Service (0x180F) with Core Bluetooth. Only peripherals the
/// system has already connected are used: nothing is scanned for or paired, and nothing but the battery
/// level characteristic is read. Levels are keyed by device name, which is how IOBluetooth's paired list
/// and Core Bluetooth's peripherals are matched. Safe to call from a background queue.
final class BLEBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    static let shared = BLEBatteryReader()
    static var batteryService: CBUUID { CBUUID(string: "180F") }
    static var batteryLevel: CBUUID { CBUUID(string: "2A19") }
    /// Connected peripherals are re-checked at most this often; level changes arrive as notifications anyway.
    static let refreshInterval: TimeInterval = 5

    private let queue = DispatchQueue(label: "com.rex.myduobar.ble")
    private let lock = NSLock()
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var known: [UUID: (name: String, percent: Int)] = [:]
    private var lastRefresh = Date.distantPast

    /// Latest known levels by device name. The first call creates the central manager, which is when
    /// macOS asks for Bluetooth access if it hasn't yet.
    func levels() -> [String: Int] {
        lock.lock()
        if central == nil { central = CBCentralManager(delegate: self, queue: queue) }
        let snapshot = known
        lock.unlock()
        queue.async { [self] in refresh() }
        var result: [String: Int] = [:]
        for entry in snapshot.values { result[entry.name] = entry.percent }
        return result
    }

    /// Runs on `queue`: follows the set of connected peripherals and asks each for its level.
    private func refresh() {
        guard let central, central.state == .poweredOn, Date().timeIntervalSince(lastRefresh) >= Self.refreshInterval else { return }
        lastRefresh = Date()
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
        let ids = Set(connected.map(\.identifier))
        lock.lock()
        for id in peripherals.keys where !ids.contains(id) { peripherals[id] = nil; known[id] = nil }
        for peripheral in connected { peripherals[peripheral.identifier] = peripheral }
        lock.unlock()
        for peripheral in connected {
            peripheral.delegate = self
            switch peripheral.state {
            case .connected: read(peripheral)
            case .disconnected: central.connect(peripheral, options: nil)
            default: break
            }
        }
    }

    private func read(_ peripheral: CBPeripheral) {
        let service = peripheral.services?.first { $0.uuid == Self.batteryService }
        if let characteristic = service?.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) {
            peripheral.readValue(for: characteristic)
        } else {
            peripheral.discoverServices([Self.batteryService])
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            lastRefresh = .distantPast
            refresh()
        } else {
            lock.lock(); peripherals.removeAll(); known.removeAll(); lock.unlock()
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { read(peripheral) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lock.lock(); peripherals[peripheral.identifier] = nil; known[peripheral.identifier] = nil; lock.unlock()
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.batteryService {
            peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.batteryLevel {
            peripheral.readValue(for: characteristic)
            if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevel, let byte = characteristic.value?.first, byte <= 100,
              let name = peripheral.name else { return }
        lock.lock(); known[peripheral.identifier] = (name, Int(byte)); lock.unlock()
    }
}
