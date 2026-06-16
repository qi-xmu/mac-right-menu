import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Enable Finder Context Menu")
                        Spacer()
                        Toggle("", isOn: $appState.isEnabled)
                            .toggleStyle(.switch)

                    }
                    Text("Adds custom right-click menu items to Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Enable Command Execution")
                        Spacer()
                        Toggle(
                            "",
                            isOn: $appState.commandExecutionEnabled
                        ).toggleStyle(.switch)
                    }

                    Text("When disabled, commands are logged but not executed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }

                Divider()

                Button(role: .destructive) {
                    appState.resetToDefaults()
                } label: {
                    Label(
                        "Reset to Defaults",
                        systemImage: "arrow.counterclockwise"
                    )
                }
            }
            .padding(24)
            .frame(alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
