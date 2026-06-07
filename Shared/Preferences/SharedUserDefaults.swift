import Foundation

public enum SharedUserDefaults {
    public static var suite: UserDefaults {
        guard let defaults = UserDefaults(suiteName: Constants.appGroupID) else {
            fatalError("Unable to create UserDefaults with suite: \(Constants.appGroupID)")
        }
        return defaults
    }

    // MARK: - Menu Configuration

    public static var menuConfiguration: MenuConfiguration {
        get {
            guard let data = suite.data(forKey: Constants.Defaults.menuConfigKey) else {
                return .default
            }
            let decoder = JSONDecoder()
            guard let config = try? decoder.decode(MenuConfiguration.self, from: data) else {
                return .default
            }
            return config
        }
        set {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(newValue) else { return }
            suite.set(data, forKey: Constants.Defaults.menuConfigKey)
            suite.synchronize()
        }
    }

    public static var isExtensionEnabled: Bool {
        get { suite.bool(forKey: Constants.Defaults.isExtensionEnabledKey) }
        set {
            suite.set(newValue, forKey: Constants.Defaults.isExtensionEnabledKey)
            suite.synchronize()
        }
    }
}
