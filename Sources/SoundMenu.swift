import AppKit

/// The Sound item in the status menu and its submenu: a volume slider and a mute switch for the current output.
@MainActor
final class SoundMenuController: NSObject, NSMenuDelegate {
    static let rowWidth: CGFloat = 290
    /// Reads are ignored this long after a local change, so a read taken mid-drag can't pull the slider back.
    static let settleTime: TimeInterval = 0.8
    /// Unmuting an output that sits at zero volume would stay silent, so it comes back at this level.
    static let unmuteVolume: Float = 0.25

    let item = NSMenuItem()
    let submenu = NSMenu()
    var onOpenSettings: ((SystemSettings.Page) -> Void)?
    /// Runs the Core Audio calls. Replaceable in tests so the real volume is never touched.
    var service: SoundServing = SystemSoundService()

    let volumeRow = VolumeRowView()
    let muteRow = SwitchRowView(width: SoundMenuController.rowWidth)
    private let worker = DispatchQueue(label: "com.rex.myduobar.sound", qos: .userInitiated)
    private(set) var output: SoundOutput?
    private var submenuOpen = false
    private var lastLocalChange: Date?
    private var settleGeneration = 0
    private var pendingVolume: Float?
    private var writingVolume = false
    /// For outputs without a mute switch: the level to restore when unmuting.
    private var volumeBeforeMute: Float?

    override init() {
        super.init()
        submenu.delegate = self
        submenu.autoenablesItems = false
        item.submenu = submenu
        volumeRow.slider.target = self
        volumeRow.slider.action = #selector(volumeSliderMoved)
        muteRow.onToggle = { [weak self] in self?.toggleMute() }
        update(status: SystemStatus())
    }

    static func symbol(muted: Bool, percent: Int?) -> String {
        guard !muted else { return "speaker.slash.fill" }
        guard let percent else { return "speaker.wave.2.fill" }
        switch percent {
        case 0: return "speaker.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    func update(status: SystemStatus) {
        let audio = status.audio
        item.title = L10n.sound
        item.subtitle = audio.outputName == L10n.soundOutputUnavailable ? audio.outputName : audio.outputName + " · " + audio.soundTitle
        item.image = NSImage(systemSymbolName: Self.symbol(muted: audio.muted == true, percent: audio.volume), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        item.setAccessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
        // Volume and mute listeners refresh the status; follow them while the submenu is visible.
        if submenuOpen { reload() }
    }

    /// Called when the status menu opens, so the rows are current before the submenu appears.
    func prepare() { reload() }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === submenu else { return }
        submenuOpen = true
        rebuild()
        reload()
    }
    func menuDidClose(_ menu: NSMenu) {
        if menu === submenu { submenuOpen = false }
    }

    func reload() {
        let service = self.service
        worker.async { [weak self] in
            let fresh = service.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(fresh) } }
        }
    }

    /// Takes a fresh read. Right after a local change only the device and its capabilities are taken from it.
    func apply(_ fresh: SoundOutput) {
        if var local = output, local.name == fresh.name, isSettling {
            local.canSetVolume = fresh.canSetVolume
            local.canSetMute = fresh.canSetMute
            output = local
        } else {
            if output?.name != fresh.name { volumeBeforeMute = nil }
            output = fresh
        }
        refreshRows()
    }

    private var isSettling: Bool {
        writingVolume || pendingVolume != nil || volumeRow.slider.isTracking
            || lastLocalChange.map { Date().timeIntervalSince($0) < Self.settleTime } == true
    }

    func rebuild() {
        submenu.removeAllItems()
        submenu.addItem(NSMenuItem.sectionHeader(title: L10n.sound))
        let volume = NSMenuItem(title: L10n.volume, action: nil, keyEquivalent: "")
        volume.view = volumeRow
        submenu.addItem(volume)
        let mute = NSMenuItem(title: L10n.mute, action: nil, keyEquivalent: "")
        mute.view = muteRow
        submenu.addItem(mute)
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.soundSettingsMenu, action: #selector(openSoundSettings), keyEquivalent: "")
        settings.target = self
        submenu.addItem(settings)
        refreshRows()
    }

    private func refreshRows() {
        let current = output
        volumeRow.update(current)
        let muted = current?.isMuted ?? false
        let detail: String
        if current == nil { detail = L10n.reading }
        else if current?.canToggleMute == false { detail = L10n.muteUnsupported }
        else { detail = muted ? L10n.muted : L10n.notMuted }
        muteRow.configure(symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", title: L10n.mute, detail: detail,
                          isOn: muted, isEnabled: current?.canToggleMute == true, help: L10n.muteToggle)
    }

    private func closeMenus() {
        var root: NSMenu? = submenu
        while let parent = root?.supermenu { root = parent }
        root?.cancelTracking()
    }

    @objc private func openSoundSettings() {
        closeMenus()
        onOpenSettings?(.sound)
    }

    // MARK: Changes

    private func markLocalChange() {
        lastLocalChange = Date()
        settleGeneration += 1
        let generation = settleGeneration
        // Once things settle, re-read so the rows show what the device actually took.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settleGeneration == generation else { return }
                self.reload()
            }
        }
    }

    @objc private func volumeSliderMoved() { setVolume(volumeRow.slider.value) }

    /// Sets the volume. Raising it while muted unmutes, like the volume keys.
    func setVolume(_ volume: Float) {
        guard var current = output, current.canSetVolume else { return }
        let volume = max(0, min(1, volume))
        current.volume = volume
        if volume > 0 {
            volumeBeforeMute = nil
            if current.muted == true, current.canSetMute {
                current.muted = false
                let service = self.service
                worker.async { _ = service.setMuted(false) }
            }
        }
        output = current
        markLocalChange()
        refreshRows()
        pendingVolume = volume
        writePendingVolume()
    }

    /// Writes the newest slider value, one at a time, so a fast drag doesn't queue up stale writes.
    private func writePendingVolume() {
        guard !writingVolume, let volume = pendingVolume else { return }
        pendingVolume = nil
        writingVolume = true
        let service = self.service
        worker.async { [weak self] in
            _ = service.setVolume(volume)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.writingVolume = false
                    self.writePendingVolume()
                }
            }
        }
    }

    func toggleMute() {
        guard var current = output, current.canToggleMute else { return }
        let mute = !current.isMuted
        let service = self.service
        if current.canSetMute {
            current.muted = mute
            if !mute, current.volume == 0, current.canSetVolume {
                current.volume = Self.unmuteVolume
                pendingVolume = Self.unmuteVolume
            }
            worker.async { _ = service.setMuted(mute) }
        } else {
            // No mute switch: zero the volume and remember where it was.
            if mute { volumeBeforeMute = current.volume }
            current.volume = mute ? 0 : (volumeBeforeMute.flatMap { $0 > 0 ? $0 : nil } ?? Self.unmuteVolume)
            if !mute { volumeBeforeMute = nil }
            pendingVolume = current.volume
        }
        output = current
        markLocalChange()
        refreshRows()
        writePendingVolume()
    }
}

/// The Core Audio calls the menu needs; `SystemSoundService` is the real one.
protocol SoundServing: Sendable {
    func read() -> SoundOutput
    func setVolume(_ volume: Float) -> Bool
    func setMuted(_ muted: Bool) -> Bool
}

struct SystemSoundService: SoundServing {
    func read() -> SoundOutput { SoundService.read() }
    func setVolume(_ volume: Float) -> Bool { SoundService.setVolume(volume) }
    func setMuted(_ muted: Bool) -> Bool { SoundService.setMuted(muted) }
}

/// Output device name and level above a slider with quiet and loud speaker marks.
final class VolumeRowView: NSView {
    let slider = MenuSlider()
    private let deviceField = NSTextField(labelWithString: "")
    private let levelField = NSTextField(labelWithString: "")
    private let quiet = NSImageView()
    private let loud = NSImageView()
    override var allowsVibrancy: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: SoundMenuController.rowWidth, height: 50))
        deviceField.font = .systemFont(ofSize: 11)
        deviceField.textColor = .secondaryLabelColor
        deviceField.lineBreakMode = .byTruncatingTail
        deviceField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        levelField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        levelField.textColor = .secondaryLabelColor
        levelField.alignment = .right
        levelField.setContentHuggingPriority(.required, for: .horizontal)
        for (view, name) in [(quiet, "speaker.fill"), (loud, "speaker.wave.3.fill")] {
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            view.contentTintColor = .secondaryLabelColor
            view.setAccessibilityElement(false)
        }
        for view in [deviceField, levelField, quiet, loud, slider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            deviceField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            deviceField.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            deviceField.trailingAnchor.constraint(lessThanOrEqualTo: levelField.leadingAnchor, constant: -8),
            levelField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            levelField.firstBaselineAnchor.constraint(equalTo: deviceField.firstBaselineAnchor),
            quiet.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            quiet.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            quiet.widthAnchor.constraint(equalToConstant: 14),
            slider.leadingAnchor.constraint(equalTo: quiet.trailingAnchor, constant: 6),
            slider.trailingAnchor.constraint(equalTo: loud.leadingAnchor, constant: -6),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            slider.heightAnchor.constraint(equalToConstant: MenuSlider.height),
            loud.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            loud.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            loud.widthAnchor.constraint(equalToConstant: 18)
        ])
        deviceField.setAccessibilityElement(false)
        levelField.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var deviceText: String { deviceField.stringValue }
    var levelText: String { levelField.stringValue }

    func update(_ output: SoundOutput?) {
        deviceField.stringValue = output?.name ?? L10n.reading
        let adjustable = output?.canSetVolume == true
        slider.isEnabled = adjustable
        slider.dimmed = output?.isMuted == true
        // Never move the knob under the pointer.
        if !slider.isTracking { slider.value = output?.volume ?? 0 }
        if let output, output.isMuted { levelField.stringValue = L10n.muted }
        else if let percent = output?.percent { levelField.stringValue = "\(percent)%" }
        else { levelField.stringValue = output == nil ? "" : "—" }
        toolTip = output != nil && !adjustable ? L10n.volumeUnsupported : nil
        slider.setAccessibilityLabel(L10n.volume)
        slider.setAccessibilityHelp(adjustable ? nil : L10n.volumeUnsupported)
    }
}
