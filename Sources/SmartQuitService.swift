import AppKit
import ApplicationServices
import os

/// Read with `log stream --predicate 'subsystem == "com.rex.myduobar"' --info`.
private let smartQuitLog = Logger(subsystem: "com.rex.myduobar", category: "SmartQuit")

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
    /// When to look for a window that was hidden rather than closed, counted from the click or key.
    static let hiddenChecks: [TimeInterval] = [0.6, 1.5, 3]
    /// A just-launched app may not answer Accessibility calls yet.
    static let attachRetries = 5
    /// A window without a close button of its own (Steam) draws one in its top strip this tall.
    static let titleStripHeight: CGFloat = 32

    fileprivate final class Watch {
        let app: NSRunningApplication
        /// The app to quit: `app` itself, or the app a window-owning helper is bundled in (Steam Helper → Steam).
        let owner: NSRunningApplication
        /// The real process, which can differ from `app.processIdentifier`; see `processID(of:)`.
        let pid: pid_t
        let element: AXUIElement
        let observer: AXObserver
        weak var service: SmartQuitService?
        /// Standard windows with a destroy notification registered, including ones on other Spaces seen earlier.
        var windows: [AXUIElement] = []
        init(app: NSRunningApplication, owner: NSRunningApplication, pid: pid_t, element: AXUIElement, observer: AXObserver) {
            self.app = app; self.owner = owner; self.pid = pid; self.element = element; self.observer = observer
        }
        var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    }

    private struct Intent {
        let pid: pid_t
        let window: AXUIElement?
        let at: Date
        /// Whether the app was already hidden (⌘H): an app that hides itself on close counts as closed.
        var appWasHidden = false
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
        guard isTrusted else { smartQuitLog.info("not started: Accessibility access missing"); return false }
        isRunning = true
        smartQuitLog.info("started")
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self?.attach(app, retries: Self.attachRetries) } }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { self?.detach(app) } }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                if let watch = self.watch(for: app) { self.scan(watch) } else { self.attach(app, retries: 0) }
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
        guard isRunning, !app.isTerminated, !SmartQuitRules.alwaysKept.contains(app.bundleIdentifier ?? ""),
              let owner = app.activationPolicy == .regular ? app : Self.hostApp(of: app) else { return }
        guard let pid = Self.processID(of: app) else {
            smartQuitLog.info("no process for \(app.bundleIdentifier ?? "?", privacy: .public)")
            return
        }
        guard watches[pid] == nil,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        var created: AXObserver?
        let result = AXObserverCreate(pid, smartQuitCallback, &created)
        guard result == .success, let observer = created else {
            smartQuitLog.info("cannot observe \(app.bundleIdentifier ?? "?", privacy: .public): \(result.rawValue)")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let watch = Watch(app: app, owner: owner, pid: pid, element: element, observer: observer)
        watch.service = self
        let added = AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, watch.refcon)
        guard added == .success || added == .notificationAlreadyRegistered else {
            if retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attach(app, retries: retries - 1) }
            }
            return
        }
        watches[pid] = watch
        smartQuitLog.info("watching \(app.bundleIdentifier ?? "?", privacy: .public)")
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        scan(watch)
        smartQuitLog.info("\(app.bundleIdentifier ?? "?", privacy: .public) has \(watch.windows.count) standard windows")
    }

    /// A quit app may no longer have a process to look up, so match the watch by the app itself too.
    private func detach(_ app: NSRunningApplication) {
        for (pid, watch) in watches where watch.app == app || pid == app.processIdentifier { detach(pid) }
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
        smartQuitLog.info("window destroyed in \(watch.app.bundleIdentifier ?? "?", privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.askedToClose(window, of: watch, at: closedAt) else {
                smartQuitLog.info("not asked by the user, kept running")
                return
            }
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

    /// `closed` is a window the user closed that the app only hid: it may still be listed.
    /// Counts the windows of the owner app and of every helper bundled in it.
    private func quitIfEmpty(_ watch: Watch, ignoring closed: AXUIElement? = nil) {
        let owner = watch.owner
        let id = owner.bundleIdentifier ?? "?"
        guard isRunning, watches[watch.pid] === watch, !owner.isTerminated else { return }
        guard rules().allows(bundleID: owner.bundleIdentifier) else { smartQuitLog.info("\(id, privacy: .public) is an exception"); return }
        let isClosed: (AXUIElement) -> Bool = { window in closed.map { CFEqual($0, window) } ?? false }
        for member in watches.values where member.owner == owner {
            scan(member)
            member.windows.removeAll(where: isClosed)
            // An unanswered query is not "no windows": only quit on a confirmed empty list.
            let open = Self.standardWindows(of: member.element)?.filter { !isClosed($0) }
            guard member.windows.isEmpty, let open, open.isEmpty else {
                smartQuitLog.info("\(member.app.bundleIdentifier ?? "?", privacy: .public) still has windows: tracked \(member.windows.count), listed \(open.map { "\($0.count)" } ?? "no answer", privacy: .public)")
                return
            }
        }
        smartQuitLog.info("quitting \(id, privacy: .public)")
        if !owner.terminate() { smartQuitLog.info("\(id, privacy: .public) refused to quit") }
    }

    // MARK: What the user asked for

    /// A click on a window's close button (the red one) marks that window as closed on purpose. A window that
    /// draws its own buttons (Steam) shows no close button to Accessibility, so a click in its top strip counts.
    private func clicked(at point: NSPoint) {
        guard let primary = NSScreen.screens.first else { return }
        var hit: AXUIElement?
        let y = primary.frame.maxY - point.y
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(y), &hit) == .success,
              let hit else { return }
        let subrole = Self.string(hit, kAXSubroleAttribute)
        if subrole == kAXStandardWindowSubrole, Self.element(hit, kAXCloseButtonAttribute) == nil,
           let top = Self.point(hit, kAXPositionAttribute)?.y, y >= top, y < top + Self.titleStripHeight {
            var pid: pid_t = 0
            guard AXUIElementGetPid(hit, &pid) == .success, watches[pid] != nil else { return }
            record(Intent(pid: pid, window: hit, at: Date()))
            return
        }
        if subrole != kAXCloseButtonSubrole {
            smartQuitLog.debug("click on \(Self.string(hit, kAXRoleAttribute) ?? "?", privacy: .public) \(subrole ?? "-", privacy: .public)")
            return
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, watches[pid] != nil else { return }
        record(Intent(pid: pid, window: Self.element(hit, kAXWindowAttribute), at: Date()))
    }

    /// ⌘W in the frontmost app marks its focused window.
    private func pressedClose() {
        guard rules().commandW, let app = NSWorkspace.shared.frontmostApplication,
              let watch = watch(for: app) else { return }
        record(Intent(pid: watch.pid, window: Self.element(watch.element, kAXFocusedWindowAttribute), at: Date()))
    }

    /// Some apps (Discord and other Electron apps) only hide a window on close instead of destroying it,
    /// so no destroy notification comes. Look again a few times after the click or key.
    private func record(_ asked: Intent) {
        var new = asked
        new.appWasHidden = watches[new.pid]?.app.isHidden ?? false
        intent = new
        smartQuitLog.info("close asked in \(self.watches[new.pid]?.app.bundleIdentifier ?? "?", privacy: .public), window known: \(new.window != nil)")
        guard new.window != nil else { return }
        for delay in Self.hiddenChecks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.checkHidden(new) }
        }
    }

    /// The window the user closed still exists but is gone from view: dropped from the window list, moved off
    /// screen while still listed (Electron's hide), or the whole app hid itself. Any of these counts as closed.
    private func checkHidden(_ expected: Intent) {
        guard let current = intent, current.at == expected.at, let aimed = current.window,
              let watch = watches[current.pid], Self.exists(aimed),
              let open = Self.standardWindows(of: watch.element) else { return }
        let id = watch.app.bundleIdentifier ?? "?"
        let listed = open.contains { CFEqual($0, aimed) }
        let onscreen = Self.isOnscreen(aimed)
        let minimized = Self.bool(aimed, kAXMinimizedAttribute) == true
        let appHid = watch.app.isHidden && !current.appWasHidden
        smartQuitLog.info("check \(id, privacy: .public): listed \(listed), onscreen \(onscreen.map { "\($0)" } ?? "unknown", privacy: .public), minimized \(minimized), app hid itself \(appHid)")
        guard !minimized, !listed || onscreen == false || appHid else { return }
        smartQuitLog.info("window hidden in \(id, privacy: .public)")
        intent = nil
        quitIfEmpty(watch, ignoring: aimed)
    }

    private func watch(for app: NSRunningApplication) -> Watch? {
        if let watch = watches[app.processIdentifier] { return watch }
        return watches.values.first { $0.app == app }
    }

    /// The app's process. Some apps launched through a helper (Steam) report -1 to AppKit even though
    /// LaunchServices knows the process, so find it by the executable it runs.
    static func processID(of app: NSRunningApplication) -> pid_t? {
        if app.processIdentifier > 0 { return app.processIdentifier }
        guard let executable = app.executableURL?.resolvingSymlinksInPath().path else { return nil }
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            guard length > 0 else { continue }
            if String(decoding: path.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self) == executable { return pid }
        }
        return nil
    }

    /// The regular app whose bundle contains this helper app's bundle, e.g. Steam for Steam Helper.
    static func hostApp(of helper: NSRunningApplication) -> NSRunningApplication? {
        guard helper.activationPolicy == .accessory, let path = helper.bundleURL?.standardizedFileURL.path else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy == .regular, let host = app.bundleURL?.standardizedFileURL.path else { return false }
            return path.hasPrefix(host.hasSuffix("/") ? host : host + "/")
        }
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

    /// Whether the window server shows the window; nil when its window number is unavailable.
    /// Uses `_AXUIElementGetWindow`, which window managers rely on; looked up at run time.
    private static func isOnscreen(_ window: AXUIElement) -> Bool? {
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        var number: CGWindowID = 0
        guard unsafeBitCast(symbol, to: GetWindow.self)(window, &number) == .success, number != 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]],
              let entry = info.first else { return nil }
        return entry[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
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
