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
            }

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(ext.isRegistered ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(ext.isRegistered ? "Registered" : "Not Registered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(ext.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(ext.isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        }
        .padding(12)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(8)
    }
}
