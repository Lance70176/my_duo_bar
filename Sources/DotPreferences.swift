import Foundation

struct DotLayout: Equatable {
    var order: [StatusGlyph] = StatusGlyph.allCases
    var hidden: Set<StatusGlyph> = []
    var visible: [StatusGlyph] { order.filter { !hidden.contains($0) } }

    init(order: [StatusGlyph] = StatusGlyph.allCases, hidden: Set<StatusGlyph> = []) {
        var unique: [StatusGlyph] = []
        for item in order + StatusGlyph.allCases where !unique.contains(item) { unique.append(item) }
        self.order = unique
        self.hidden = hidden
    }

    mutating func move(_ glyph: StatusGlyph, by offset: Int) {
        guard let index = order.firstIndex(of: glyph), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
    }
}

final class DotPreferences {
    private let defaults: UserDefaults
    private(set) var layout: DotLayout
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = DotLayout(order: (defaults.stringArray(forKey: "dotOrder") ?? []).compactMap(StatusGlyph.init(rawValue:)),
                           hidden: Set((defaults.stringArray(forKey: "hiddenDots") ?? []).compactMap(StatusGlyph.init(rawValue:))))
    }
    func setVisible(_ visible: Bool, for glyph: StatusGlyph) {
        if visible { layout.hidden.remove(glyph) } else { layout.hidden.insert(glyph) }
        save()
    }
    func move(_ glyph: StatusGlyph, by offset: Int) { layout.move(glyph, by: offset); save() }
    private func save() {
        defaults.set(layout.order.map(\.rawValue), forKey: "dotOrder")
        defaults.set(StatusGlyph.allCases.filter { layout.hidden.contains($0) }.map(\.rawValue), forKey: "hiddenDots")
        onChange?()
    }
}
