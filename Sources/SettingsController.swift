import AppKit
import ServiceManagement
import CoreLocation
import Intents

final class SettingsController: NSWindowController, CLLocationManagerDelegate {
    private let preferences: DotPreferences
    private let dotRows = NSStackView()
    private let login = NSButton(checkboxWithTitle: "登入時自動啟動", target: nil, action: nil)
    private let focusStatus = NSTextField(wrappingLabelWithString: "")
    private let location = CLLocationManager()
    private let icon = LargeIconView()
    private let wechatCopied = NSTextField(labelWithString: "")
    private let emailCopied = NSTextField(labelWithString: "")
    var onRefresh: (() -> Void)?

    init(preferences: DotPreferences) {
        self.preferences = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 496, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MyDuoBar 設定"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        location.delegate = self
        build()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22)
        ])
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 60).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let name = NSTextField(labelWithString: "MyDuoBar")
        name.font = .systemFont(ofSize: 21, weight: .semibold)
        let caption = NSTextField(labelWithString: "一個位置，讀懂 Mac 的狀態。")
        caption.font = .systemFont(ofSize: 12); caption.textColor = .secondaryLabelColor
        let names = NSStackView(views: [name, caption]); names.orientation = .vertical; names.alignment = .leading; names.spacing = 5
        let header = NSStackView(views: [icon, names]); header.spacing = 15
        stack.addArrangedSubview(header)
        addSeparator(stack)
        login.target = self; login.action = #selector(toggleLogin)
        stack.addArrangedSubview(login)
        stack.addArrangedSubview(note("只在選單列顯示。按一下即可查看，按一下其他地方或按 Esc 收起。"))
        stack.addArrangedSubview(note("位置：按住 ⌘ 拖到控制中心左側。macOS 會記住你調整的位置。"))
        addSeparator(stack)
        stack.addArrangedSubview(heading("底部圓點"))
        stack.addArrangedSubview(note("從左到右排列。圓點大小一致，開啟時點亮，未開啟時變灰。取消勾選可隱藏這一項。"))
        dotRows.orientation = .vertical; dotRows.alignment = .leading; dotRows.spacing = 4
        stack.addArrangedSubview(dotRows)
        dotRows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rebuildDotRows()
        addSeparator(stack)
        stack.addArrangedSubview(heading("整理系統選單列"))
        stack.addArrangedSubview(note("在系統設定中關閉原生 Wi-Fi、電池的選單列顯示，即可留出空間。"))
        stack.addArrangedSubview(button("關閉對應選單列圖示", #selector(openMenuBar)))
        addSeparator(stack)
        stack.addArrangedSubview(heading("狀態讀取"))
        focusStatus.font = .systemFont(ofSize: 12)
        focusStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(focusStatus)
        let actions = NSStackView(views: [
            button("允許讀取專注狀態…", #selector(explainFocus)),
            button("允許顯示 Wi-Fi 名稱…", #selector(requestLocation))
        ])
        actions.spacing = 8
        stack.addArrangedSubview(actions)
        stack.addArrangedSubview(note("顯示 Wi-Fi 名稱需要定位服務權限，App 不會取得地理座標。專注狀態未共享時，圓點保持灰色，詳細資訊會標示「狀態未共享」。"))
        addSeparator(stack)
        stack.addArrangedSubview(heading("聯絡開發者 🌟"))
        stack.addArrangedSubview(contactRow("小紅書：", title: "前往", action: #selector(openXiaohongshu)))
        stack.addArrangedSubview(contactRow("微信：", title: "nybbamboo", action: #selector(copyWeChat), feedback: wechatCopied))
        stack.addArrangedSubview(contactRow("電子郵件：", title: "nybbamboo@163.com", action: #selector(copyEmail), feedback: emailCopied))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        stack.addArrangedSubview(note("\(version) · 本機執行"))
    }

    private func contactRow(_ label: String, title: String, action: Selector, feedback: NSTextField? = nil) -> NSStackView {
        let name = NSTextField(labelWithString: label)
        name.widthAnchor.constraint(equalToConstant: 54).isActive = true
        let row = NSStackView(views: [name, button(title, action)])
        row.spacing = 8; row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if let feedback {
            feedback.font = .systemFont(ofSize: 11)
            feedback.textColor = .systemGreen
            feedback.setAccessibilityLabel(label + "複製結果")
            row.addArrangedSubview(feedback)
        }
        return row
    }

    private func rebuildDotRows() {
        for row in dotRows.arrangedSubviews { dotRows.removeArrangedSubview(row); row.removeFromSuperview() }
        for (index, glyph) in preferences.layout.order.enumerated() {
            let check = NSButton(checkboxWithTitle: glyph.title, target: self, action: #selector(toggleDot(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(glyph.rawValue)
            check.state = preferences.layout.hidden.contains(glyph) ? .off : .on
            check.setAccessibilityLabel("顯示" + glyph.title + "圓點")
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
            up.setAccessibilityLabel(glyph.title + "向前移"); down.setAccessibilityLabel(glyph.title + "向後移")
            up.toolTip = "向左移動"; down.toolTip = "向右移動"
            let row = NSStackView(views: [image, check, spacer, up, down])
            row.spacing = 8; row.alignment = .centerY
            row.heightAnchor.constraint(equalToConstant: 28).isActive = true
            dotRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: dotRows.widthAnchor).isActive = true
        }
        icon.layout = preferences.layout
    }
    @objc private func toggleDot(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let glyph = StatusGlyph(rawValue: value) else { return }
        preferences.setVisible(sender.state == .on, for: glyph)
        icon.layout = preferences.layout
    }
    @objc private func moveDotUp(_ sender: NSButton) { moveDot(sender, by: -1) }
    @objc private func moveDotDown(_ sender: NSButton) { moveDot(sender, by: 1) }
    private func moveDot(_ sender: NSButton, by offset: Int) {
        guard let value = sender.identifier?.rawValue, let glyph = StatusGlyph(rawValue: value) else { return }
        preferences.move(glyph, by: offset)
        rebuildDotRows()
    }

    private func addSeparator(_ stack: NSStackView) {
        let line = NSBox(); line.boxType = .separator
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 444
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
        case .unavailable: focusStatus.stringValue = "按一下下方按鈕，並在系統對話框中允許讀取。另外還需在系統設定中開啟「共享專注狀態」。"
        default: focusStatus.stringValue = "專注狀態可讀 · " + status.focus.title
        }
    }
    func present(status: SystemStatus) {
        update(status)
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
            alert.messageText = "自動啟動尚未完成"
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

    @objc private func openXiaohongshu() {
        if let url = URL(string: "https://www.xiaohongshu.com/user/profile/5fd62d06000000000101e8b1") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func copyWeChat() { copyContact("nybbamboo", feedback: wechatCopied) }
    @objc private func copyEmail() { copyContact("nybbamboo@163.com", feedback: emailCopied) }
    private func copyContact(_ value: String, feedback: NSTextField) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(value, forType: .string) {
            feedback.stringValue = "已複製"
        }
    }

    @objc private func explainFocus() {
        let center = INFocusStatusCenter.default
        if center.authorizationStatus == .denied || center.authorizationStatus == .restricted {
            let alert = NSAlert()
            alert.messageText = "專注狀態尚未共享"
            alert.informativeText = "請在系統設定中允許 MyDuoBar 讀取專注狀態，並在專注模式 → 專注狀態中開啟共享。MyDuoBar 只讀取是否專注，開啟時點亮圓點。"
            alert.addButton(withTitle: "開啟專注設定")
            alert.addButton(withTitle: "稍後")
            if alert.runModal() == .alertFirstButtonReturn { SystemSettings.open(.focus) }
            return
        }
        center.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async { self?.onRefresh?() }
        }
    }
}
