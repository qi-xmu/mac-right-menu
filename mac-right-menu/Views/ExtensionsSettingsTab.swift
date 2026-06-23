import SwiftUI

struct ExtensionsSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("RPC Address")
                    Spacer()
                    Text("\(Constants.rpcHost):\(String(Constants.rpcPort))")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                
                Divider()

                ForEach(appState.extensions) { ext in
                    extensionCard(ext)
                }

                Text(
                    "If an extension does not appear automatically, enable it in:\nSystem Settings → Privacy & Security → Extensions → Finder Extensions"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    @ViewBuilder
    private func extensionCard(_ ext: ExtensionInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ext.displayName)
                    .fontWeight(.medium)
                Spacer()
                // Manual re-probe of pluginkit status: lets the user refresh
                // after enabling the extension in System Settings without
                // relaunching the Container.
                Button {
                    appState.checkExtensionRegistration()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Refresh"))
            }

            HStack(spacing: 16) {
                // Registration status: Enabled (+ !) / Disabled (- =) /
                // Not Installed (absent). Color mirrors the connected dot below.
                HStack(spacing: 6) {
                    Circle()
                        .fill(registrationColor(ext.registrationStatus))
                        .frame(width: 8, height: 8)
                    Text(registrationLabel(ext.registrationStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(ext.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(ext.isConnected ? String(localized: "Connected") : String(localized: "Disconnected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Guidance: only offer the System Settings deep-link when the
            // extension isn't usable yet. Enabled extensions need no action.
            if ext.registrationStatus != .enabled {
                Button("Open System Settings…") {
                    appState.openSystemSettingsForExtensions()
                }
            }

            if ext.isConnected {
                HStack(spacing: 16) {
                    if let pid = ext.connectedPID {
                        Text("PID: \(pid)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let version = ext.connectedVersion {
                        Text("v\(version)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let last = ext.lastHeartbeatAt {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text("Heartbeat: \(last, style: .relative) ago")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Divider()

            Toggle(
                "Auto-launch on start",
                isOn: Binding(
                    get: { ext.autoLaunch },
                    set: {
                        appState.setAutoLaunch(
                            bundleID: ext.bundleID,
                            enabled: $0
                        )
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }

    // MARK: - Registration status presentation

    private func registrationColor(_ status: RegistrationStatus) -> Color {
        switch status {
        case .enabled:      return .green
        case .disabled:     return .orange
        case .notInstalled: return .red
        }
    }

    private func registrationLabel(_ status: RegistrationStatus) -> String {
        switch status {
        case .enabled:      return String(localized: "Enabled")
        case .disabled:     return String(localized: "Disabled")
        case .notInstalled: return String(localized: "Not Installed")
        }
    }
}
