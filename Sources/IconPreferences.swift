import Foundation

/// The user's choice for the icon: whether the volume marks at the bottom are shown.
final class IconPreferences {
    private let defaults: UserDefaults
    private(set) var showVolume: Bool
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showVolume = defaults.object(forKey: "showVolume") as? Bool ?? true
    }

    func setShowVolume(_ show: Bool) {
        guard show != showVolume else { return }
        showVolume = show
        defaults.set(show, forKey: "showVolume")
        onChange?()
    }
}
