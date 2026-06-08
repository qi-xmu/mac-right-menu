import SwiftUI

struct ActionsSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Section: Available Actions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Available Actions")
                        .font(.headline)

                    Text("Toggle which actions appear in the right-click menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(appState.actionItems) { item in
                            HStack {
                                Image(systemName: item.iconName ?? "gearshape")
                                    .frame(width: 20)
                                    .foregroundColor(.accentColor)
                                Text(item.title)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { item.isEnabled },
                                    set: { newValue in
                                        if let index = appState.actionItems.firstIndex(where: { $0.id == item.id }) {
                                            appState.configuration.actionItems[index].isEnabled = newValue
                                            appState.saveConfiguration()
                                        }
                                    }
                                ))
                            }
                        }
                    }
                }

                Divider()

                // MARK: - Section: Info
                VStack(alignment: .leading, spacing: 12) {
                    Text("About Actions")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        actionInfoRow(icon: "doc.badge.plus", title: "New File", description: "Create a new file from templates")
                        actionInfoRow(icon: "doc.on.clipboard", title: "Copy Path", description: "Copy the full file path to clipboard")
                        actionInfoRow(icon: "doc.on.clipboard", title: "Copy File Name", description: "Copy only the file name to clipboard")
                        actionInfoRow(icon: "eye.slash", title: "Toggle Hidden", description: "Show or hide files in Finder")
                        actionInfoRow(icon: "arrow.up.doc", title: "Open Parent Folder", description: "Open the parent directory in Finder")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func actionInfoRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
