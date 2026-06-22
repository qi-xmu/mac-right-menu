import SwiftUI
import UniformTypeIdentifiers

struct AppsSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: String?   // AppMenuItem.id

    var body: some View {
        VStack(spacing: 12) {
            // MARK: - Section: Open With master switch
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(String(localized: "Open With Apps"))
                        .fontWeight(.medium)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.appsSectionEnabled },
                        set: { appState.appsSectionEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Text(String(localized: "Add applications to open files with from the right-click menu."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            
            // MARK: Show App Icons toggle
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(String(localized: "Show App Icons"))
                    Spacer()
                    Toggle("", isOn: $appState.showAppIcons)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                Text(String(localized: "Display the application icon next to each app in the right-click menu."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            .padding(.bottom, 12)

            Divider()

            // MARK: - Section: Apps list header
            VStack(alignment: .leading, spacing: 4) {
                Text("Applications")
                    .font(.headline)
                Text("Select an application to open files with from Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)


            // MARK: - List (fills remaining height)
            if appState.appItems.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No Apps Configured",
                    systemImage: "square.grid.2x2",
                    description: Text("Click + to add your first application.")
                )
                Spacer()
            } else {
                VStack(spacing: 4) {
                    List(selection: $selection) {
                        ForEach(appState.appItems) { item in
                            HStack {
                                Image(nsImage: item.icon)
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .fontWeight(.medium)
                                    Text(item.appURL.path)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { item.isEnabled },
                                    set: { newValue in
                                        if let index = appState.appItems.firstIndex(where: { $0.id == item.id }) {
                                            appState.configuration.appItems[index].isEnabled = newValue
                                            appState.saveConfiguration()
                                        }
                                    }
                                )).toggleStyle(.switch)
                                    .controlSize(.mini)
                            }
                            .padding(.vertical, 2)
                            .tag(item.id)
                        }
                        .onMove { source, dest in
                            appState.moveApp(from: source, to: dest)
                        }
                        .onDelete { offsets in
                            appState.removeApp(at: offsets)
                        }
                    }
                    .listStyle(.inset)
                    Divider()
                    toolbar
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            }

            if appState.appItems.isEmpty {
                Divider()
                toolbar
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - +/- toolbar

    private var toolbar: some View {
        HStack {
            Button { chooseAppFromDisk() } label: {
                Image(systemName: "plus").frame(width: 16, height: 16)
            }
            .help(String(localized: "Add an app from disk"))

            Spacer()

            Button {
                if let id = selection,
                   let index = appState.appItems.firstIndex(where: { $0.id == id }) {
                    appState.removeApp(at: IndexSet(integer: index))
                    selection = nil
                }
            } label: {
                Image(systemName: "minus").frame(width: 16, height: 16)
            }
            .disabled(selection == nil)
            .help(String(localized: "Remove selected"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func chooseAppFromDisk() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.addApp(url)
        selection = url.path   // AppMenuItem.id == url.path
    }
}
