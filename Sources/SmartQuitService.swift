import AppKit
import ApplicationServices

/// What Smart Quit acts on, read again each time a window closes so a change in the menu applies at once.
struct SmartQuitRules: Sendable, Equatable {
    /// Apps that keep running after their last window closes: the system shell, and this app.
    static let alwaysKept: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.rex.myduobar"]

    var exceptions: Set<String> = []
    /// Whether closing with ⌘W (or ⇧⌘W) counts, not just the close button.
    var commandW = true

    /// False for the apps that must never be quit and for the user's exceptions.
    func allows(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return !Self.alwaysKept.contains(bundleID) && !exceptions.contains(bundleID)
    }

    /// ⌘W and ⇧⌘W; Caps Lock and the keypad flag are ignored, any other modifier means another shortcut.
    static func isCloseShortcut(characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.command, .option, .control, .shift])
        guard relevant == .command || relevant == [.command, .shift] else { return false }
        return characters?.lowercased() == "w"
    }
}

/// The calls the Smart Quit submenu needs; `SmartQuitService` is the real one.
@MainActor protocol SmartQuitWatching: AnyObject {
    /// Whether macOS lets this app read other apps' windows (Privacy & Security → Accessibility).
    var isTrusted: Bool { get }
    /// Shows the system prompt that leads to the Accessibility list.
    func requestTrust()
    /// Starts watching; false while Accessibility access is missing.
    func start(rules: @escaping @MainActor () -> SmartQuitRules) -> Bool
    func stop()
}

/// Quits an app once the user closes its last window, as Windows does. Only a close the user asked for
/// counts: a click on a window's close button, or ⌘W when allowed. A window an app closes by itself,
/// a panel, or a window still open on another Space never quits anything.
///
/// Built on the Accessibility API: an `AXObserver` per regular app reports new and destroyed standard
/// windows, and global event monitors see the click or key that asked for the close.
@MainActor
final class SmartQuitService: SmartQuitWatching {
    /// A close within this long of the click or key, before or after it, is the user's doing.
    static let intentWindow: TimeInterval = 2
    /// The exact window the click or key aimed at still counts this long, e.g. after a Save sheet.
    static let targetedIntentWindow: TimeInterval = 60
    /// Some apps replace a window by closing one first; give them a moment before counting.
    static let settleDelay: TimeInterval = 0.5
    /// A just-launched app may not answer Accessibility calls yet.
    static let attachRetries = 5

    fileprivate final class Watch {
        let app: NSRunningApplication
        let element: AXUIElement
        let observer: AXObserver
        weak var service: SmartQuitService?
        /// Standard windows with a destroy notification registered, including ones on other Spaces seen earlier.
        var windows: [AXUIElement] = []
        init(app: NSRunningApplication, element: AXUIElement, observer: AXObserver) {
            self.app = app; self.element = element; self.observer = observer
        }
        var pid: pid_t { app.processIdentifier }
        var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    }

    private struct Intent {
        let pid: pid_t
        let window: AXUIElement?
        let at: Date
    }

    private var watches: [pid_t: Watch] = [:]
    private var monitors: [Any] = []
    private var tokens: [NSObjectProtocol] = []
    private var rules: @MainActor () -> SmartQuitRules = { SmartQuitRules() }
    private var intent: Intent?
    private let systemWide = AXUIElementCreateSystemWide()
    private(set) var isRunning = false

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestTrust() {
        // The key's value is "AXTrustedCheckOptionPrompt"; the global itself is not concurrency-safe in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func start(rules: @escaping @MainActor () -> SmartQuitRules) -> Bool {
        self.rules = rules
        guard !isRunning else { return true }
        guard isTrusted else { return false }
        isRunning = true
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self?.attach(app, retries: Self.attachRetries) } }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.detach(pid) } }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                if let watch = self.watches[app.processIdentifier] { self.scan(watch) } else { self.attach(app, retries: 0) }
            }
        })
        // Accessibility lists only the current Space's windows, so pick up the others as the user visits them.
        tokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanAll() }
        })
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            let point = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.clicked(at: point) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let isClose = SmartQuitRules.isCloseShortcut(characters: event.charactersIgnoringModifiers, flags: event.modifierFlags)
            MainActor.assumeIsolated { if isClose { self?.pressedClose() } }
        }) { monitors.append(monitor) }
        for app in NSWorkspace.shared.runningApplications { attach(app, retries: 0) }
        return true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens = []
        for pid in Array(watches.keys) { detach(pid) }
        intent = nil
    }

    // MARK: Watching apps

    private func attach(_ app: NSRunningApplication, retries: Int) {
        let pid = app.processIdentifier
        guard isRunning, watches[pid] == nil, !app.isTerminated, app.activationPolicy == .regular,
              pid != ProcessInfo.processInfo.processIdentifier,
              !SmartQuitRules.alwaysKept.contains(app.bundleIdentifier ?? "") else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, smartQuitCallback, &created) == .success, let observer = created else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let watch = Watch(app: app, element: element, observer: observer)
        watch.service = self
        let result = AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, watch.refcon)
        guard result == .success || result == .notificationAlreadyRegistered else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attach(app, retries: retries - 1) }
            }
            return
        }
        watches[pid] = watch
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        scan(watch)
    }

    private func detach(_ pid: pid_t) {
        guard let watch = watches.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .commonModes)
        watch.windows = []
        if intent?.pid == pid { intent = nil }
    }

    private func scanAll() { for watch in watches.values { scan(watch) } }

    /// Registers every standard window not yet tracked, and forgets tracked ones that no longer exist.
    private func scan(_ watch: Watch) {
        watch.windows.removeAll { !Self.exists($0) }
        for window in Self.standardWindows(of: watch.element) ?? [] { track(window, in: watch) }
    }

    private func track(_ window: AXUIElement, in watch: Watch) {
        guard !watch.windows.contains(where: { CFEqual($0, window) }) else { return }
        let result = AXObserverAddNotification(watch.observer, window, kAXUIElementDestroyedNotification as CFString, watch.refcon)
        if result == .success || result == .notificationAlreadyRegistered { watch.windows.append(window) }
    }

    fileprivate func received(_ notification: String, element: AXUIElement, watch: Watch) {
        guard watches[watch.pid] === watch else { return }
        if notification == kAXWindowCreatedNotification {
            if Self.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole { track(element, in: watch) }
        } else if notification == kAXUIElementDestroyedNotification {
            windowClosed(element, in: watch)
        }
    }

    /// Waits a moment before judging: the global key monitor can report ⌘W after the window is already gone.
    private func windowClosed(_ window: AXUIElement, in watch: Watch) {
        let before = watch.windows.count
        watch.windows.removeAll { CFEqual($0, window) }
        guard watch.windows.count < before else { return }
        let closedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.askedToClose(window, of: watch, at: closedAt) else { return }
            self.intent = nil
            self.quitIfEmpty(watch)
        }
    }

    private func askedToClose(_ window: AXUIElement, of watch: Watch, at closedAt: Date) -> Bool {
        guard let intent, intent.pid == watch.pid else { return false }
        let gap = closedAt.timeIntervalSince(intent.at)
        if let aimed = intent.window, CFEqual(aimed, window), gap > -Self.settleDelay, gap < Self.targetedIntentWindow { return true }
        return abs(gap) < Self.intentWindow
    }

    private func quitIfEmpty(_ watch: Watch) {
        guard isRunning, watches[watch.pid] === watch, !watch.app.isTerminated,
              rules().allows(bundleID: watch.app.bundleIdentifier) else { return }
        scan(watch)
        // An unanswered query is not "no windows": only quit on a confirmed empty list.
        guard watch.windows.isEmpty, let open = Self.standardWindows(of: watch.element), open.isEmpty else { return }
        watch.app.terminate()
    }

    // MARK: What the user asked for

    /// A click on a window's close button (the red one) marks that window as closed on purpose.
    private func clicked(at point: NSPoint) {
        guard let primary = NSScreen.screens.first else { return }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(primary.frame.maxY - point.y), &hit) == .success,
              let hit, Self.string(hit, kAXSubroleAttribute) == kAXCloseButtonSubrole else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, watches[pid] != nil else { return }
        intent = Intent(pid: pid, window: Self.element(hit, kAXWindowAttribute), at: Date())
    }

    /// ⌘W in the frontmost app marks its focused window.
    private func pressedClose() {
        guard rules().commandW, let app = NSWorkspace.shared.frontmostApplication,
              let watch = watches[app.processIdentifier] else { return }
        intent = Intent(pid: watch.pid, window: Self.element(watch.element, kAXFocusedWindowAttribute), at: Date())
    }

    // MARK: Accessibility helpers

    /// The app's standard windows on the current Space (minimized ones included); nil when the app did not answer.
    static func standardWindows(of app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.filter { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }
    }

    private static func exists(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) != .invalidUIElement
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

/// Runs on the main run loop, where every observer's source is added.
private func smartQuitCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let name = notification as String
    // Already on the main thread: these only cross into the main actor's view of the same thread.
    nonisolated(unsafe) let pointer = refcon
    nonisolated(unsafe) let target = element
    MainActor.assumeIsolated {
        let watch = Unmanaged<SmartQuitService.Watch>.fromOpaque(pointer).takeUnretainedValue()
        watch.service?.received(name, element: target, watch: watch)
    }
}
