import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: SettingsNav = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsNav.allCases) { nav in
                    Label(nav.title, systemImage: nav.systemImage)
                        .tag(nav)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            detailView
                .navigationTitle(selection.title)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general: GeneralSettingsTab()
        case .extensions: ExtensionsSettingsTab()
        case .file: NewFileSettingsTab()
        case .apps: AppsSettingsTab()
        case .actions: ActionsSettingsTab()
        }
    }
}

// MARK: - Sidebar Navigation Items

private enum SettingsNav: String, CaseIterable, Identifiable {
    case general, extensions, file, apps, actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .extensions: String(localized: "Extensions")
        case .file: String(localized: "File")
        case .apps: String(localized: "Apps")
        case .actions: String(localized: "Actions")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .extensions: "puzzlepiece.extension"
        case .file: "doc.badge.plus"
        case .apps: "square.grid.2x2"
        case .actions: "bolt"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
