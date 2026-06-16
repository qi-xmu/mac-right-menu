import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            ExtensionsSettingsTab()
                .tabItem {
                    Label("Extensions", systemImage: "puzzlepiece.extension")
                }
            NewFileSettingsTab()
                .tabItem {
                    Label("File", systemImage: "doc.badge.plus")
                }
            AppsSettingsTab()
                .tabItem {
                    Label("Apps", systemImage: "square.grid.2x2")
                }
            ActionsSettingsTab()
                .tabItem {
                    Label("Actions", systemImage: "bolt")
                }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
