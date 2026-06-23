import SwiftUI
import UniformTypeIdentifiers

struct AppsSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: String?   // AppTarget.id (appURL.path)

    var body: some View {
        VStack(spacing: 12) {
            // MARK: - Section: Open With master switch
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Open With Apps")
                        .fontWeight(.medium)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.appsSectionEnabled },
                        set: { appState.appsSectionEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Text("Add applications to open files with from the right-click menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            // MARK: Show App Icons toggle
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Show App Icons")
                    Spacer()
                    Toggle("", isOn: $appState.appsShowAppIcons)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                Text("Display the application icon next to each app in the right-click menu. Note: showing app icons has a significant performance impact and may slow down menu opening.")
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
            if appState.appRows.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No Apps Configured",
                    systemImage: "square.grid.2x2",
                    description: Text("Click + to add your first application.")
                )
                Spacer()
            } else {
                VStack(spacing: 8) {
                    List(selection: $selection) {
                        ForEach(appState.appRows) { row in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: row.app.appURL.path))
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.app.displayName)
                                        .fontWeight(.medium)
                                    Text(row.app.appURL.path)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { row.isEnabled },
                                    set: { newValue in appState.setAppEnabled(id: row.id, enabled: newValue) }
                                )).toggleStyle(.switch)
                                    .controlSize(.mini)
                            }
                            .padding(.vertical, 2)
                            .tag(row.id)
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

            if appState.appRows.isEmpty {
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
                   let index = appState.appRows.firstIndex(where: { $0.id == id }) {
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
        selection = url.path   // AppTarget.id == url.path
    }
}
