import AppKit
import Intents
import CoreAudio
import CoreWLAN
import IOKit.ps
import Network
import SystemConfiguration

/// Owns every system subscription. All mutable state lives on the main actor; the worker queue only
/// performs blocking reads and hands back value types.
@MainActor
final class SystemMonitor: NSObject, CWEventDelegate {
    var onChange: ((SystemStatus) -> Void)?
    private(set) var status = SystemStatus()
    private let worker = DispatchQueue(label: "com.rex.myduobar.status", qos: .utility)
    private let wifi = CWWiFiClient.shared()
    private let path = NWPathMonitor()
    private var route: NetworkLink = .unknown
    private var timer: Timer?
    private var focusTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var dynamicStore: SCDynamicStore?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var audioListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var focusObservation: NSKeyValueObservation?
    private var watchedOutput: AudioDeviceID?
    private var sampling = false
    private var needsAnotherSample = false
    private var sleeping = false
    private var menuOpen = false

    func start() {
        wifi.delegate = self
        for event: CWEventType in [.powerDidChange, .ssidDidChange, .linkDidChange, .linkQualityDidChange] {
            try? wifi.startMonitoringEvent(with: event)
        }
        path.pathUpdateHandler = { [weak self] path in
            let link: NetworkLink
            if path.status != .satisfied { link = .offline }
            else if path.usesInterfaceType(.wifi) { link = .wifi }
            else if path.usesInterfaceType(.wiredEthernet) { link = .ethernet }
            else { link = .other }
            // DispatchQueue.main is FIFO, so a newer path can never be applied before an older one.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.route = link
                    self.refresh()
                }
            }
        }
        path.start(queue: worker)
        // IOKit and SystemConfiguration invoke these C callbacks on the main run loop / main queue.
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        dynamicStore = SCDynamicStoreCreate(nil, "MyDuoBar" as CFString, { _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }, &context)
        if let dynamicStore {
            let patterns = ["State:/Network/Global/.*", "State:/Network/Service/.*/.*", "State:/Network/Interface/.*/.*"] as CFArray
            SCDynamicStoreSetNotificationKeys(dynamicStore, nil, patterns)
            SCDynamicStoreSetDispatchQueue(dynamicStore, .main)
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        listen(system, SystemReaders.address(kAudioHardwarePropertyDevices))
        listen(system, SystemReaders.address(kAudioHardwarePropertyDefaultOutputDevice))
        bindOutput()
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { $0.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { monitor in
            monitor.sleeping = true; monitor.timer?.invalidate(); monitor.focusTimer?.invalidate()
        }
        observe(workspace, NSWorkspace.didWakeNotification) { monitor in
            monitor.sleeping = false; monitor.resetTimer(); monitor.refresh()
        }
        focusObservation = INFocusStatusCenter.default.observe(\.focusStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshFocus() }
        }
        resetTimer()
        refresh()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (SystemMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    func setMenuOpen(_ open: Bool) {
        menuOpen = open
        resetTimer()
        if open { refresh() }
    }

    private func resetTimer() {
        timer?.invalidate()
        focusTimer?.invalidate()
        guard !sleeping else { return }
        let interval: TimeInterval = menuOpen ? 3 : 30
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = menuOpen ? 0.5 : 8
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Supplement Focus notifications without re-reading audio and networking.
        let focusTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFocus() }
        }
        focusTimer.tolerance = 0.25
        RunLoop.main.add(focusTimer, forMode: .common)
        self.focusTimer = focusTimer
    }

    private func refreshFocus() {
        guard !sleeping else { return }
        worker.async { [weak self] in
            let focus = SystemReaders.focus()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.sleeping, self.status.focus != focus else { return }
                    self.status.focus = focus
                    self.onChange?(self.status)
                }
            }
        }
    }

    func refresh() {
        guard !sleeping else { return }
        if sampling { needsAnotherSample = true; return }
        sampling = true
        let route = self.route
        worker.async { [weak self] in
            // Blocking reads only; the Wi-Fi client is a process-wide singleton, so nothing crosses actors.
            var value = SystemStatus()
            value.battery = SystemReaders.battery()
            value.wifi = SystemReaders.wifi(client: CWWiFiClient.shared(), route: route)
            value.vpn = SystemReaders.vpn()
            value.audio = SystemReaders.audio()
            value.focus = SystemReaders.focus()
            let sample = value
            // Keep worker order on the main queue so a focus-only result and a full sample stay ordered.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishSample(sample) } }
        }
    }

    private func finishSample(_ value: SystemStatus) {
        sampling = false
        bindOutput()
        if value != status {
            status = value
            onChange?(value)
        }
        if needsAnotherSample { needsAnotherSample = false; refresh() }
    }

    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return }
        // Listener blocks are dispatched on the main queue.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            audioListeners.append((object, address, block))
        }
    }

    private func bindOutput() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let device: AudioDeviceID? = SystemReaders.value(system, kAudioHardwarePropertyDefaultOutputDevice)
        guard device != watchedOutput else { return }
        for (object, original, block) in audioListeners where object != system {
            var address = original
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        audioListeners.removeAll { $0.0 != system }
        watchedOutput = device
        guard let device, device != kAudioObjectUnknown else { return }
        for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyDataSource] {
            for element: UInt32 in [0, 1, 2] {
                listen(device, SystemReaders.address(selector, scope: kAudioDevicePropertyScopeOutput, element: element))
            }
        }
    }

    // CoreWLAN calls its delegate on a private queue.
    nonisolated func powerStateDidChangeForWiFiInterface(withName name: String) { Task { @MainActor in self.refresh() } }
    nonisolated func ssidDidChangeForWiFiInterface(withName name: String) { Task { @MainActor in self.refresh() } }
    nonisolated func linkDidChangeForWiFiInterface(withName name: String) { Task { @MainActor in self.refresh() } }
    nonisolated func linkQualityDidChangeForWiFiInterface(withName name: String, rssi: Int, transmitRate: Double) {
        Task { @MainActor in self.refresh() }
    }

    func stop() {
        timer?.invalidate()
        focusTimer?.invalidate()
        path.cancel()
        try? wifi.stopMonitoringAllEvents()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        if let dynamicStore { SCDynamicStoreSetDispatchQueue(dynamicStore, nil) }
        for (object, original, block) in audioListeners {
            var address = original
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        audioListeners.removeAll()
        focusObservation?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
}
