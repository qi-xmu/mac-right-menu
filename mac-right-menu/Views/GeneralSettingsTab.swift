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

                // MARK: Extension

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Extension Status")
                        Spacer()
                        if appState.isExtensionActive {
                            Label(
                                "Active",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)
                            .fontWeight(.semibold)
                        } else {
                            Label("Inactive", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .fontWeight(.semibold)
                        }
                    }

                    Text(
                        "If the extension does not appear automatically, enable it in:\nSystem Settings → Privacy & Security → Extensions → Finder Extensions"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    }
}
