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
        case .about: AboutSettingsTab()
        }
    }
}

// MARK: - Sidebar Navigation Items

private enum SettingsNav: String, CaseIterable, Identifiable {
    case general, extensions, file, apps, actions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .extensions: String(localized: "Extensions")
        case .file: String(localized: "File")
        case .apps: String(localized: "Apps")
        case .actions: String(localized: "Actions")
        case .about: String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .extensions: "puzzlepiece.extension"
        case .file: "doc.badge.plus"
        case .apps: "square.grid.2x2"
        case .actions: "bolt"
        case .about: "info.circle"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
