import Foundation

/// The user's choices for the icon: whether the volume marks at the bottom and the network speed beside it are shown.
final class IconPreferences {
    private let defaults: UserDefaults
    private(set) var showVolume: Bool
    private(set) var showNetworkSpeed: Bool
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showVolume = defaults.object(forKey: "showVolume") as? Bool ?? true
        showNetworkSpeed = defaults.object(forKey: "showNetworkSpeed") as? Bool ?? true
    }

    func setShowVolume(_ show: Bool) {
        guard show != showVolume else { return }
        showVolume = show
        defaults.set(show, forKey: "showVolume")
        onChange?()
    }

    func setShowNetworkSpeed(_ show: Bool) {
        guard show != showNetworkSpeed else { return }
        showNetworkSpeed = show
        defaults.set(show, forKey: "showNetworkSpeed")
        onChange?()
    }
}
