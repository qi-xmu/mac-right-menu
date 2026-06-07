import SwiftUI
import Combine

/// Observable state for the Container App settings UI.
/// Reads from and writes to SharedUserDefaults (App Group UserDefaults).
@MainActor
class AppState: ObservableObject {
    @Published var configuration: MenuConfiguration {
        didSet {
            saveConfiguration()
        }
    }

    init() {
        self.configuration = SharedUserDefaults.menuConfiguration
    }

    func saveConfiguration() {
        SharedUserDefaults.menuConfiguration = configuration
        SettingsSync.postSettingsChanged()
    }

    // MARK: - Convenience accessors

    var isEnabled: Bool {
        get { configuration.isEnabled }
        set {
            configuration.isEnabled = newValue
            saveConfiguration()
        }
    }

    var appItems: [AppMenuItem] {
        get { configuration.appItems }
        set {
            configuration.appItems = newValue
            saveConfiguration()
        }
    }

    var actionItems: [ActionMenuItem] {
        get { configuration.actionItems }
        set {
            configuration.actionItems = newValue
            saveConfiguration()
        }
    }

    var newFileTemplates: [NewFileTemplate] {
        get { configuration.newFileTemplates }
        set {
            configuration.newFileTemplates = newValue
            saveConfiguration()
        }
    }

    // MARK: - Actions

    func addApp(_ appURL: URL) {
        let newItem = AppMenuItem(appURL: appURL, isEnabled: true)
        if !configuration.appItems.contains(where: { $0.id == newItem.id }) {
            configuration.appItems.append(newItem)
            saveConfiguration()
        }
    }

    func removeApp(at offsets: IndexSet) {
        configuration.appItems.remove(atOffsets: offsets)
        saveConfiguration()
    }

    func moveApp(from source: IndexSet, to destination: Int) {
        configuration.appItems.move(fromOffsets: source, toOffset: destination)
        saveConfiguration()
    }

    func toggleAction(_ actionType: ActionType) {
        guard let index = configuration.actionItems.firstIndex(where: { $0.actionType == actionType }) else { return }
        configuration.actionItems[index].isEnabled.toggle()
        saveConfiguration()
    }

    func resetToDefaults() {
        configuration = .default
        saveConfiguration()
    }
}
