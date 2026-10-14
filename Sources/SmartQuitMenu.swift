import AppKit
import UniformTypeIdentifiers

/// The Smart Quit item in the status menu and its submenu: a switch, whether ⌘W counts, a quick exception
/// for the frontmost app, and the full exception list. The setting is remembered; watching starts again
/// at launch once macOS allows Accessibility access.
@MainActor
final class SmartQuitMenuController: NSObject, NSMenuDelegate {
    static let rowWidth: CGFloat = 290
    static let enabledKey = "smartQuitEnabled"
    static let commandWKey = "smartQuitCommandW"
    static let exceptionsKey = "smartQuitExceptions"
    /// While on but not yet allowed, check this often whether access was granted in System Settings.
    static let trustPollInterval: TimeInterval = 2

    /// An app the quick-exception row can name.
    struct AppInfo: Equatable { let name: String; let bundleID: String }

    let item = NSMenuItem()
    let submenu = NSMenu()
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    /// Watches other apps' windows. Replaceable in tests so no app is ever quit.
    var service: SmartQuitWatching = SmartQuitService()
    /// The app in front when the menu opens; this app's own windows and Finder never count.
    var frontmost: () -> AppInfo? = {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              SmartQuitRules().allows(bundleID: id) else { return nil }
        return AppInfo(name: app.localizedName ?? id, bundleID: id)
    }

    let switchRow = SwitchRowView(width: SmartQuitMenuController.rowWidth)
    let commandWRow = ChoiceRowView(width: SmartQuitMenuController.rowWidth, title: "")
    let keepRow = ChoiceRowView(width: SmartQuitMenuController.rowWidth, title: "")
    private let header = NSMenuItem.sectionHeader(title: "")
    private let switchItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let commandWItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let keepSeparator = NSMenuItem.separator()
    let keepItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let exceptionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let accessItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let defaults: UserDefaults
    private var shownApp: AppInfo?
    private var trustPoll: Timer?
    private var exceptionsWindow: SmartQuitExceptionsController?
    private(set) var isRunning = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        item.submenu = submenu
        switchRow.onToggle = { [weak self] in self?.toggle() }
        commandWRow.onSelect = { [weak self] in self?.toggleCommandW() }
        keepRow.onSelect = { [weak self] in self?.toggleFrontmostException() }
        // Items are created once: a view moved to a new menu item is no longer drawn.
        submenu.addItem(header)
        switchItem.view = switchRow
        submenu.addItem(switchItem)
        commandWItem.view = commandWRow
        submenu.addItem(commandWItem)
        submenu.addItem(keepSeparator)
        keepItem.view = keepRow
        submenu.addItem(keepItem)
        exceptionsItem.target = self; exceptionsItem.action = #selector(showExceptions)
        submenu.addItem(exceptionsItem)
        accessItem.target = self; accessItem.action = #selector(openAccessibilitySettings)
        submenu.addItem(accessItem)
        rebuild()
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var includesCommandW: Bool { defaults.object(forKey: Self.commandWKey) as? Bool ?? true }
    /// Bundle identifiers of the apps that keep running, sorted for a stable list.
    var exceptions: [String] { (defaults.stringArray(forKey: Self.exceptionsKey) ?? []).sorted() }
    var rules: SmartQuitRules { SmartQuitRules(exceptions: Set(exceptions), commandW: includesCommandW) }

    /// Starts watching at launch when the switch was left on.
    func activate() {
        if isEnabled { startWatching(prompt: false) }
        refreshRows()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === submenu else { return }
        shownApp = frontmost()
        if isEnabled, !isRunning { startWatching(prompt: false) }
        rebuild()
    }

    /// Re-titles every row in the current language and refreshes its state.
    func rebuild() {
        header.title = L10n.smartQuit
        switchItem.title = L10n.smartQuit
        commandWItem.title = L10n.smartQuitCommandW
        commandWRow.title = L10n.smartQuitCommandW
        exceptionsItem.title = L10n.smartQuitExceptionsMenu
        accessItem.title = L10n.accessibilitySettingsMenu
        exceptionsWindow?.reload()
        refreshRows()
    }

    /// Re-renders the text, e.g. after a language change.
    func refresh() { rebuild() }

    var detail: String {
        if isRunning { return L10n.smartQuitOnDetail }
        return isEnabled ? L10n.smartQuitNeedsAccess : L10n.smartQuitOffDetail
    }

    private func refreshRows() {
        let symbol = isRunning ? "xmark.app.fill" : "xmark.app"
        item.title = L10n.smartQuit
        item.subtitle = isRunning ? L10n.on : (isEnabled ? L10n.needsAccess : L10n.off)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        item.setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        switchRow.configure(symbol: symbol, title: L10n.smartQuit, detail: detail, isOn: isEnabled, isEnabled: true, help: L10n.smartQuitToggle)
        commandWRow.isChecked = includesCommandW
        commandWRow.isEnabled = isEnabled
        if let shownApp {
            keepItem.title = L10n.smartQuitKeep(shownApp.name)
            keepRow.title = keepItem.title
            keepRow.isChecked = exceptions.contains(shownApp.bundleID)
        }
        keepItem.isHidden = shownApp == nil
        accessItem.isHidden = !isEnabled || isRunning
    }

    func toggle() {
        if isEnabled {
            defaults.set(false, forKey: Self.enabledKey)
            stopWatching()
        } else {
            defaults.set(true, forKey: Self.enabledKey)
            startWatching(prompt: true)
        }
        refreshRows()
    }

    func toggleCommandW() {
        defaults.set(!includesCommandW, forKey: Self.commandWKey)
        refreshRows()
    }

    func toggleFrontmostException() {
        guard let shownApp else { return }
        setException(shownApp.bundleID, kept: !exceptions.contains(shownApp.bundleID))
    }

    func setException(_ bundleID: String, kept: Bool) {
        var list = Set(exceptions)
        if kept { list.insert(bundleID) } else { list.remove(bundleID) }
        defaults.set(list.sorted(), forKey: Self.exceptionsKey)
        exceptionsWindow?.reload()
        refreshRows()
    }

    /// Starts the service, or asks for access and waits for it: the switch stays on meanwhile.
    private func startWatching(prompt: Bool) {
        if service.start(rules: { [weak self] in self?.rules ?? SmartQuitRules(exceptions: [], commandW: false) }) {
            isRunning = true
            trustPoll?.invalidate(); trustPoll = nil
            return
        }
        if prompt {
            service.requestTrust()
            closeMenus()
            onOpenSettings?(.accessibility)
        }
        guard trustPoll == nil else { return }
        let timer = Timer(timeInterval: Self.trustPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPoll = timer
    }

    func checkTrust() {
        guard isEnabled, !isRunning else { trustPoll?.invalidate(); trustPoll = nil; return }
        guard service.isTrusted else { return }
        startWatching(prompt: false)
        refreshRows()
    }

    private func stopWatching() {
        trustPoll?.invalidate(); trustPoll = nil
        service.stop()
        isRunning = false
    }

    /// Stops watching when the app quits.
    func stop() { stopWatching() }

    private func closeMenus() {
        var root: NSMenu? = submenu
        while let parent = root?.supermenu { root = parent }
        root?.cancelTracking()
    }

    @objc private func openAccessibilitySettings() {
        service.requestTrust()
        closeMenus()
        onOpenSettings?(.accessibility)
    }

    @objc func showExceptions() {
        closeMenus()
        if exceptionsWindow == nil { exceptionsWindow = SmartQuitExceptionsController(menu: self) }
        exceptionsWindow?.present()
    }
    var exceptionsController: SmartQuitExceptionsController? { exceptionsWindow }
}

/// The exception list: apps that keep running after their last window closes.
@MainActor
final class SmartQuitExceptionsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var source: SmartQuitMenuController?
    let table = NSTableView()
    private let heading = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    let addButton = NSButton(title: "", target: nil, action: nil)
    private(set) var ids: [String] = []

    init(menu: SmartQuitMenuController) {
        source = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 320)
        super.init(window: window)
        build()
        reload()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        guard let content = window?.contentView else { return }
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 11); footer.textColor = .secondaryLabelColor
        empty.font = .systemFont(ofSize: 13); empty.textColor = .tertiaryLabelColor
        let column = NSTableColumn(identifier: .init("app"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self; table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        addButton.bezelStyle = .rounded
        addButton.target = self; addButton.action = #selector(addApp)
        for view in [heading, note, scroll, empty, addButton, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            note.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            addButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            footer.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.centerYAnchor.constraint(equalTo: addButton.centerYAnchor)
        ])
    }

    /// Re-reads the list and every label in the current language.
    func reload() {
        window?.title = L10n.smartQuitExceptionsTitle
        heading.stringValue = L10n.smartQuitExceptionsHeading
        note.stringValue = L10n.smartQuitExceptionsNote
        footer.stringValue = L10n.smartQuitExceptionsFooter
        empty.stringValue = L10n.smartQuitExceptionsEmpty
        addButton.title = L10n.addApp
        ids = source?.exceptions ?? []
        empty.isHidden = !ids.isEmpty
        table.reloadData()
    }

    func present() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = ids[row]
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        let name = NSTextField(labelWithString: url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: id)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let remove = NSButton(title: L10n.remove, target: self, action: #selector(removeApp(_:)))
        remove.bezelStyle = .inline
        remove.controlSize = .small
        remove.identifier = .init(id)
        for view in [icon, name, detail, remove] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            name.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            name.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.topAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -8),
            remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            remove.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    @objc private func removeApp(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        source?.setException(id, kept: false)
    }

    @objc private func addApp() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.addApp.replacingOccurrences(of: "…", with: "")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            MainActor.assumeIsolated {
                for id in ids { self?.source?.setException(id, kept: true) }
            }
        }
    }
}
