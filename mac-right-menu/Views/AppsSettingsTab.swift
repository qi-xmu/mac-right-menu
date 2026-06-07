import SwiftUI
import UniformTypeIdentifiers

struct AppsSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Section: Open With Apps
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Open With Apps")
                            .font(.headline)
                        Spacer()
                        Button("Add App...") {
                            chooseApp()
                        }
                    }

                    Text("Add applications to open files with from the right-click menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if appState.appItems.isEmpty {
                        ContentUnavailableView(
                            "No Apps Configured",
                            systemImage: "square.grid.2x2",
                            description: Text("Click \"Add App...\" to add your first application.")
                        )
                        .frame(maxHeight: 200)
                    } else {
                        List {
                            ForEach(Array(appState.appItems.enumerated()), id: \.element.id) { index, item in
                                HStack {
                                    Image(nsImage: item.icon)
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                    VStack(alignment: .leading) {
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
                                            appState.configuration.appItems[index].isEnabled = newValue
                                            appState.saveConfiguration()
                                        }
                                    ))
                                }
                                .padding(.vertical, 2)
                            }
                            .onMove { source, dest in
                                appState.moveApp(from: source, to: dest)
                            }
                            .onDelete { offsets in
                                appState.removeApp(at: offsets)
                            }
                        }
                        .frame(minHeight: 120)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.addApp(url)
    }
}
