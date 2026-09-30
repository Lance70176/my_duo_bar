import AppKit

/// The power history window: the whole power log on one large chart. Drag to move through time, pinch or
/// scroll up and down to zoom, pick a range, or jump back to the latest reading. Opened by clicking the chart
/// in the Battery submenu.
@MainActor
final class PowerHistoryWindowController: NSWindowController, NSWindowDelegate {
    static let ranges: [TimeInterval] = [2 * 3600, 6 * 3600, 24 * 3600, 7 * 86400]

    let chart = PowerChartView(width: 720)
    let rangeControl = NSSegmentedControl()
    let latestButton = NSButton()
    private let hint = NSTextField(labelWithString: "")
    private let fileURL: URL?
    private let worker = DispatchQueue(label: "com.rex.myduobar.power-history", qos: .userInitiated)

    init(fileURL: URL?) {
        self.fileURL = fileURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 320)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        rangeControl.segmentCount = Self.ranges.count
        rangeControl.trackingMode = .selectOne
        rangeControl.target = self
        rangeControl.action = #selector(pickRange)
        latestButton.bezelStyle = .rounded
        latestButton.target = self
        latestButton.action = #selector(showLatest)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chart.interactive = true
        chart.fontSize = 11
        chart.span = Self.ranges[0]
        chart.onViewChange = { [weak self] in self?.syncControls() }

        let bar = NSStackView(views: [rangeControl, hint, latestButton])
        bar.orientation = .horizontal
        bar.spacing = 12
        // The hint takes the spare width; the range buttons and Latest keep their natural size.
        rangeControl.segmentDistribution = .fit
        rangeControl.setContentHuggingPriority(.required, for: .horizontal)
        latestButton.setContentHuggingPriority(.required, for: .horizontal)
        hint.setContentHuggingPriority(.init(1), for: .horizontal)
        let content = NSView()
        for view in [bar, chart] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            chart.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            chart.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            chart.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            chart.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        window.contentView = content
        applyTitles()
        syncControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-titles everything in the current language.
    func applyTitles() {
        window?.title = L10n.powerHistoryTitle
        for (index, range) in Self.ranges.enumerated() {
            rangeControl.setLabel(L10n.powerRange(range), forSegment: index)
        }
        latestButton.title = L10n.powerHistoryLatest
        hint.stringValue = L10n.powerHistoryHint
    }

    /// Shows the window with the readings already in memory, then fills in the rest of the log.
    func present(recent: [PowerSample]) {
        if chart.samples.isEmpty { chart.samples = recent }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        loadLog()
    }

    /// Reads the whole CSV log off the main thread and puts it in front of the readings taken since.
    func loadLog() {
        guard let url = fileURL else { return }
        worker.async { [weak self] in
            let history = PowerLogFile.load(from: url, since: .distantPast)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !history.isEmpty else { return }
                    let after = history.last!.date
                    self.chart.samples = history + self.chart.samples.filter { $0.date > after }
                    self.syncControls()
                }
            }
        }
    }

    /// A new reading while the window is open.
    func add(_ sample: PowerSample) {
        guard window?.isVisible == true, sample.date > chart.samples.last?.date ?? .distantPast else { return }
        chart.samples.append(sample)
    }

    func syncControls() {
        rangeControl.selectedSegment = Self.ranges.firstIndex(of: chart.span) ?? -1
        latestButton.isEnabled = chart.now != nil
    }

    @objc private func pickRange() {
        guard Self.ranges.indices.contains(rangeControl.selectedSegment) else { return }
        chart.span = Self.ranges[rangeControl.selectedSegment]
        chart.pan(by: 0)
        syncControls()
    }

    @objc private func showLatest() {
        chart.now = nil
        syncControls()
    }
}
