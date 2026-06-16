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
            AppsSettingsTab()
                .tabItem {
                    Label("Apps", systemImage: "square.grid.2x2")
                }
            ActionsSettingsTab()
                .tabItem {
                    Label("Actions", systemImage: "bolt")
                }
            NewFileSettingsTab()
                .tabItem {
                    Label("New File", systemImage: "doc.badge.plus")
                }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
