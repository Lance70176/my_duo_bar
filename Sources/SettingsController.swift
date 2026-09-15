import AppKit
import ServiceManagement
import CoreLocation
import Intents

final class SettingsController: NSWindowController, CLLocationManagerDelegate {
    private static let contentWidth: CGFloat = 496
    private let preferences: DotPreferences
    private let dotRows = NSStackView()
    private let login = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let focusStatus = NSTextField(wrappingLabelWithString: "")
    private let location = CLLocationManager()
    private let icon = LargeIconView()
    private let dotsGuide = NSTextField(wrappingLabelWithString: "")
    private var stack: NSStackView?
    var onRefresh: (() -> Void)?
    /// Called after the user picks another language, once the preference has been saved.
    var onLanguageChange: (() -> Void)?

    init(preferences: DotPreferences) {
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        location.delegate = self
        login.target = self; login.action = #selector(toggleLogin)
        languagePopup.target = self; languagePopup.action = #selector(changeLanguage(_:))
        languagePopup.controlSize = .small
        build()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Builds (or rebuilds, after a language change) every label in the current language.
    func build() {
        guard let window, let content = window.contentView else { return }
        stack?.removeFromSuperview()
        window.title = L10n.settingsTitle
        let stack = NSStackView()
        self.stack = stack
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22)
        ])
        icon.translatesAutoresizingMaskIntoConstraints = false
        if icon.constraints.isEmpty {
            icon.widthAnchor.constraint(equalToConstant: 60).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        }
        let name = NSTextField(labelWithString: "MyDuoBar")
        name.font = .systemFont(ofSize: 21, weight: .semibold)
        let caption = NSTextField(labelWithString: L10n.tagline)
        caption.font = .systemFont(ofSize: 12); caption.textColor = .secondaryLabelColor
        let names = NSStackView(views: [name, caption]); names.orientation = .vertical; names.alignment = .leading; names.spacing = 5
        let header = NSStackView(views: [icon, names]); header.spacing = 15
        stack.addArrangedSubview(header)
        buildIconGuide(stack)
        addSeparator(stack)

        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.menuTitle)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: L10n.preference) ?? 0)
        let languageLabel = NSTextField(labelWithString: L10n.language)
        let languageRow = NSStackView(views: [languageLabel, languagePopup])
        languageRow.spacing = 8; languageRow.alignment = .centerY
        stack.addArrangedSubview(languageRow)
        stack.addArrangedSubview(note(L10n.languageNote))
        addSeparator(stack)

        login.title = L10n.launchAtLogin
        stack.addArrangedSubview(login)
        stack.addArrangedSubview(note(L10n.menuBarOnlyNote))
        stack.addArrangedSubview(note(L10n.positionNote))
        addSeparator(stack)
        stack.addArrangedSubview(heading(L10n.bottomDots))
        stack.addArrangedSubview(note(L10n.bottomDotsNote))
        dotRows.orientation = .vertical; dotRows.alignment = .leading; dotRows.spacing = 4
        stack.addArrangedSubview(dotRows)
        dotRows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rebuildDotRows()
        addSeparator(stack)
        stack.addArrangedSubview(heading(L10n.tidyMenuBar))
        stack.addArrangedSubview(note(L10n.tidyMenuBarNote))
        stack.addArrangedSubview(button(L10n.hideSystemIcons, #selector(openMenuBar)))
        addSeparator(stack)
        stack.addArrangedSubview(heading(L10n.statusAccess))
        focusStatus.font = .systemFont(ofSize: 12)
        focusStatus.textColor = .secondaryLabelColor
        focusStatus.preferredMaxLayoutWidth = Self.contentWidth - 52
        stack.addArrangedSubview(focusStatus)
        let actions = NSStackView(views: [
            button(L10n.allowFocus, #selector(explainFocus)),
            button(L10n.allowWiFiName, #selector(requestLocation))
        ])
        actions.spacing = 8
        stack.addArrangedSubview(actions)
        stack.addArrangedSubview(note(L10n.statusAccessNote))
        addSeparator(stack)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        stack.addArrangedSubview(note(L10n.versionFooter(version)))
        fitWindowToContent()
    }

    /// Explains every part of the icon, each line with a small drawing of the part it describes.
    private func buildIconGuide(_ stack: NSStackView) {
        stack.addArrangedSubview(heading(L10n.iconGuide))
        let ink = NSColor.labelColor
        let green = NSColor(calibratedRed: 0.18, green: 0.80, blue: 0.38, alpha: 1)
        dotsGuide.font = .systemFont(ofSize: 11); dotsGuide.textColor = .secondaryLabelColor
        dotsGuide.preferredMaxLayoutWidth = Self.contentWidth - 52 - 30
        let rows: [(NSImage, NSTextField)] = [
            (Self.guideImage { Self.drawRing(ink, fraction: 0.7) }, guideLabel(L10n.guideRing)),
            (Self.guideImage { Self.drawRing(green, fraction: 1) }, guideLabel(L10n.guideRingGreen)),
            (Self.guideImage { Self.drawRing(.systemYellow, fraction: 1) }, guideLabel(L10n.guideRingYellow)),
            (NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))!, guideLabel(L10n.guideCenter)),
            (Self.guideImage { Self.drawDots(ink) }, dotsGuide)
        ]
        for (image, label) in rows {
            let picture = NSImageView(image: image)
            picture.contentTintColor = .labelColor
            picture.translatesAutoresizingMaskIntoConstraints = false
            picture.widthAnchor.constraint(equalToConstant: 22).isActive = true
            picture.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let row = NSStackView(views: [picture, label])
            row.spacing = 8; row.alignment = .firstBaseline
            stack.addArrangedSubview(row)
        }
        updateIconGuide()
    }

    private func guideLabel(_ text: String) -> NSTextField {
        let label = note(text)
        label.preferredMaxLayoutWidth = Self.contentWidth - 52 - 30
        return label
    }

    /// Dot order and visibility change at runtime, so this line and the icon tooltip follow the preferences.
    private func updateIconGuide() {
        dotsGuide.stringValue = L10n.guideDots(preferences.layout.visible.map(\.title))
        icon.toolTip = [L10n.guideRing, L10n.guideRingGreen, L10n.guideRingYellow, L10n.guideCenter, dotsGuide.stringValue]
            .joined(separator: "\n")
    }

    private static func guideImage(_ draw: @escaping () -> Void) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in draw(); return true }
    }
    /// The same capsule track as the menu bar icon, scaled into the 22 × 16 guide image.
    private static func drawRing(_ color: NSColor, fraction: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale: CGFloat = 20 / DuoIcon.ringSize.width
        var transform = CGAffineTransform(translationX: 11 - DuoIcon.center.x * scale, y: 8 - DuoIcon.center.y * scale)
            .scaledBy(x: scale, y: scale)
        ctx.saveGState()
        ctx.setLineWidth(2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(color.withAlphaComponent(0.25).cgColor)
        ctx.addPath(DuoIcon.trackPath().copy(using: &transform) ?? CGMutablePath())
        ctx.strokePath()
        ctx.setStrokeColor(color.cgColor)
        ctx.addPath(DuoIcon.arcPath(from: DuoIcon.trackStart, span: DuoIcon.trackSpan * fraction).copy(using: &transform) ?? CGMutablePath())
        ctx.strokePath()
        ctx.restoreGState()
    }
    private static func drawDots(_ color: NSColor) {
        for (index, alpha) in [1.0, 0.5, 0.5, 1.0].enumerated() {
            color.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: 2 + CGFloat(index) * 5, y: 5.5, width: 4, height: 4)).fill()
        }
    }

    /// Text length differs per language, so size the window to its content instead of a fixed height.
    private func fitWindowToContent() {
        guard let window, let stack else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 22 + 24
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: Self.contentWidth, height: height))
        // Keep the title bar where it was when a rebuild changes the height.
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true)
    }

    private func rebuildDotRows() {
        for row in dotRows.arrangedSubviews { dotRows.removeArrangedSubview(row); row.removeFromSuperview() }
        for (index, glyph) in preferences.layout.order.enumerated() {
            let check = NSButton(checkboxWithTitle: glyph.title, target: self, action: #selector(toggleDot(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(glyph.rawValue)
            check.state = preferences.layout.hidden.contains(glyph) ? .off : .on
            check.setAccessibilityLabel(L10n.showDot(glyph.title))
            let image = NSImageView(image: NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil) ?? NSImage())
            image.contentTintColor = .secondaryLabelColor
            image.widthAnchor.constraint(equalToConstant: 22).isActive = true
            let spacer = NSView()
            let up = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)!, target: self, action: #selector(moveDotUp(_:)))
            let down = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!, target: self, action: #selector(moveDotDown(_:)))
            for b in [up, down] {
                b.bezelStyle = .rounded; b.controlSize = .small
                b.identifier = NSUserInterfaceItemIdentifier(glyph.rawValue)
                b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            }
            up.isEnabled = index > 0; down.isEnabled = index < preferences.layout.order.count - 1
            up.setAccessibilityLabel(L10n.moveEarlier(glyph.title)); down.setAccessibilityLabel(L10n.moveLater(glyph.title))
            up.toolTip = L10n.moveLeft; down.toolTip = L10n.moveRight
            let row = NSStackView(views: [image, check, spacer, up, down])
            row.spacing = 8; row.alignment = .centerY
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
            dotRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: dotRows.widthAnchor).isActive = true
        }
        icon.layout = preferences.layout
        updateIconGuide()
    }
    @objc private func toggleDot(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let glyph = StatusGlyph(rawValue: value) else { return }
        preferences.setVisible(sender.state == .on, for: glyph)
        icon.layout = preferences.layout
        updateIconGuide()
    }
    @objc private func moveDotUp(_ sender: NSButton) { moveDot(sender, by: -1) }
    @objc private func moveDotDown(_ sender: NSButton) { moveDot(sender, by: 1) }
    private func moveDot(_ sender: NSButton, by offset: Int) {
        guard let value = sender.identifier?.rawValue, let glyph = StatusGlyph(rawValue: value) else { return }
        preferences.move(glyph, by: offset)
        rebuildDotRows()
    }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: raw), language != L10n.preference else { return }
        L10n.setPreference(language)
        // Rebuild after the pop-up finishes tracking; the button is reused in the new layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.build()
            self.onLanguageChange?()
        }
    }

    private func addSeparator(_ stack: NSStackView) {
        let line = NSBox(); line.boxType = .separator
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.contentWidth - 52
        return label
    }
    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold); return label
    }
    private func button(_ text: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: text, target: self, action: action)
        button.bezelStyle = .rounded; button.controlSize = .small; return button
    }

    func update(_ status: SystemStatus) {
        icon.status = status
        icon.layout = preferences.layout
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        switch status.focus {
        case .unavailable: focusStatus.stringValue = L10n.focusPrompt
        default: focusStatus.stringValue = L10n.focusReadable + status.focus.title
        }
    }
    func present(status: SystemStatus) {
        update(status)
        fitWindowToContent()
        showWindow(nil); NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLogin() {
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.loginItemFailed
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc private func openMenuBar() { SystemSettings.open(.menubar) }
    @objc private func requestLocation() { location.requestWhenInUseAuthorization() }
    // CoreLocation delivers this on the run loop that created the manager (main); hop explicitly for Swift 6.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.onRefresh?() }
    }

    @objc private func explainFocus() {
        let center = INFocusStatusCenter.default
        if center.authorizationStatus == .denied || center.authorizationStatus == .restricted {
            let alert = NSAlert()
            alert.messageText = L10n.focusNotSharedTitle
            alert.informativeText = L10n.focusNotSharedBody
            alert.addButton(withTitle: L10n.openFocusSettings)
            alert.addButton(withTitle: L10n.later)
            if alert.runModal() == .alertFirstButtonReturn { SystemSettings.open(.focus) }
            return
        }
        center.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async { self?.onRefresh?() }
        }
    }
}
