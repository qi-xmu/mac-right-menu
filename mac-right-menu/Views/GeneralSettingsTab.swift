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
                    // Two distinct states:
                    //  - Registered: the system has the extension enabled (pluginkit).
                    //  - Connected:  an RPC connection is live (heartbeat).
                    HStack {
                        Text("Extension Registered")
                        Spacer()
                        if appState.isExtensionRegistered {
                            Label("Enabled", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .fontWeight(.semibold)
                        } else {
                            Label("Not Enabled", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .fontWeight(.semibold)
                        }
                    }

                    HStack {
                        Text("Extension Connected")
                        Spacer()
                        if appState.isExtensionConnected {
                            Label("Connected", systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                                .fontWeight(.semibold)
                        } else {
                            Label("Disconnected", systemImage: "antenna.radiowaves.left.and.right.slash")
                                .foregroundStyle(.orange)
                                .fontWeight(.semibold)
                        }
                    }

                    // Live connection details, refreshed every second so the
                    // "last heartbeat" relative time stays current.
                    if appState.isExtensionConnected {
                        VStack(alignment: .leading, spacing: 4) {
                            if let pid = appState.connectedExtPID {
                                detailRow(label: "Extension PID", value: "\(pid)")
                            }
                            if let version = appState.connectedExtVersion {
                                detailRow(label: "Version", value: version)
                            }
                            if let last = appState.lastHeartbeatAt {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    HStack {
                                        Text("Last Heartbeat")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(last, style: .relative) ago")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.leading, 2)
                    } else if appState.isExtensionRegistered {
                        Text("Extension is enabled but not yet running. Trigger a Finder right-click to start it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .frame(minWidth: 560, minHeight: 420)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
