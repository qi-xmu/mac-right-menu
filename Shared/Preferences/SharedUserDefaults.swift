import Foundation

/// Shared data stored in Extension's sandbox container.
/// Extension can freely read/write inside its own container.
/// Container App (unsandboxed) accesses via absolute path.
public enum SharedUserDefaults {

    // MARK: - Store

    static let store: PreferenceStore = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = "Library/Containers/\(Constants.extensionBundleID)/Data/Documents/SharedData.plist"
        let url = home.appendingPathComponent(path)
        return PreferenceStore(fileURL: url)
    }()

    // MARK: - Menu Configuration

    public static var menuConfiguration: MenuConfiguration {
        get {
            guard let data = store.data(forKey: Constants.Defaults.menuConfigKey) else {
                return .default
            }
            return (try? JSONDecoder().decode(MenuConfiguration.self, from: data)) ?? .default
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            store.set(data, forKey: Constants.Defaults.menuConfigKey)
        }
    }

    // MARK: - Extension Enabled

    public static var isExtensionEnabled: Bool {
        get { store.bool(forKey: Constants.Defaults.isExtensionEnabledKey) }
        set { store.set(newValue, forKey: Constants.Defaults.isExtensionEnabledKey) }
    }

    // MARK: - Command Log Only

    public static var commandLogOnly: Bool {
        get { store.bool(forKey: Constants.Defaults.commandLogOnlyKey) }
        set { store.set(newValue, forKey: Constants.Defaults.commandLogOnlyKey) }
    }
}

// MARK: - PreferenceStore

final class PreferenceStore: @unchecked Sendable {
    private let fileURL: URL
    private var storage: [String: Any] = [:]
    private var cachedModificationDate: Date?
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
        reloadFromDisk()
    }

    func data(forKey key: String) -> Data? {
        lock.lock()
        reloadIfChanged()
        let value = storage[key] as? Data
        lock.unlock()
        return value
    }

    func bool(forKey key: String) -> Bool {
        lock.lock()
        reloadIfChanged()
        let value = (storage[key] as? NSNumber)?.boolValue ?? false
        lock.unlock()
        return value
    }

    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        reloadIfChanged()
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
        persist()
        lock.unlock()
    }

    func set(_ value: Bool, forKey key: String) {
        set(NSNumber(value: value), forKey: key)
    }

    private func reloadIfChanged() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modDate = attrs[.modificationDate] as? Date else { return }
        if cachedModificationDate == nil || modDate > cachedModificationDate! {
            reloadFromDisk()
            cachedModificationDate = modDate
        }
    }

    private func reloadFromDisk() {
        if let dict = NSDictionary(contentsOf: fileURL) as? [String: Any] {
            storage = dict
        }
    }

    private func persist() {
        let dict = storage as NSDictionary
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dict.write(to: fileURL, atomically: true)
        cachedModificationDate = Date()
    }
}
