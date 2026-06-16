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
                        // `.newFile` is excluded here — its master switch lives
                        // in the File tab header (it gates the whole New File
                        // section, not an individual row).
                        ForEach(appState.actionItems.filter { $0.actionType != .newFile }) { item in
                            HStack(alignment: .top) {
                                Image(systemName: item.iconName ?? "gearshape")
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                // Title + description, so each row is
                                // self-explanatory (the separate "About Actions"
                                // section was removed and folded in here).
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .fontWeight(.medium)
                                    Text(item.actionType.localizedDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
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
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
