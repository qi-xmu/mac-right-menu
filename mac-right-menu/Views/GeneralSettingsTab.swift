import SwiftUI

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Enable Finder Context Menu")
                        Spacer()
                        Toggle("", isOn: $appState.isEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
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
                            .controlSize(.mini)
                    }
                    Text("When disabled, commands are logged but not executed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Execution Log")
                        Spacer()
                        Toggle(
                            "",
                            isOn: $appState.executionLogEnabled
                        ).toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    Text("Records every command executed from Finder. On by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Debug Log")
                        Spacer()
                        Toggle(
                            "",
                            isOn: $appState.debugLogEnabled
                        ).toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    Text("Records all RPC traffic and wake events. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }

                Divider()

                HStack(spacing: 12) {
                    Spacer()
                    Button {
                        restartApp()
                    } label: {
                        Label(String(localized: "Restart"), systemImage: "arrow.trianglehead.clockwise")
                    }

                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Label(String(localized: "Quit"), systemImage: "xmark.square")
                    }

                    Button(role: .destructive) {
                        showingResetConfirm = true
                    } label: {
                        Label(
                            String(localized: "Reset"),
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .confirmationDialog(
                        "Reset all settings to defaults? This cannot be undone.",
                        isPresented: $showingResetConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Reset", role: .destructive) {
                            appState.resetToDefaults()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .padding(24)
            .frame(alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private func restartApp() {
        // Release the single-instance lock so the re-launched Container can
        // acquire it instead of seeing a duplicate and exiting immediately.
        appState.releaseInstanceLock()
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            NSApplication.shared.terminate(nil)
        }
    }
}
