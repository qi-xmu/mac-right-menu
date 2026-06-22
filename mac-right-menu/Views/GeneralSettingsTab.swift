import SwiftUI
import os.log

private let logger = Logger(subsystem: Constants.mainAppBundleID, category: "general-settings")

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

                // MARK: - Full Disk Access
                fullDiskAccessSection

                Divider()

                HStack(spacing: 12) {
                    Spacer()
                    Button {
                        restartApp()
                    } label: {
                        Label(String(localized: "Restart"), systemImage: "arrow.trianglehead.clockwise")
                    }

                    Button {
                        appState.shutdownExtensions()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            NSApplication.shared.terminate(nil)
                        }
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

    // MARK: - Full Disk Access section

    /// Permission management block. Shows current FDA status, explains why it's
    /// needed, and offers a deep-link to System Settings + a manual re-check.
    /// macOS has no programmatic grant, so the flow is: detect → guide → user
    /// toggles in System Settings → Refresh.
    @ViewBuilder
    private var fullDiskAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status row: colored icon + title + state label + Refresh button.
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .font(.title3)
                Text("Full Disk Access")
                    .fontWeight(.medium)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Spacer()
                Button {
                    appState.checkFullDiskAccess()
                } label: {
                    Label(String(localized: "Refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Re-check Full Disk Access status"))
            }

            Text("Grants access to files in all locations so copy / new file / open / shell commands work everywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .fixedSize(horizontal: false, vertical: true)

            // Guidance + deep-link only when access is actually missing.
            // Once granted, the steps are noise.
            if appState.fullDiskAccessGranted != true {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Click “Open System Settings…” below")
                    // %@ is resolved against the app's bundle name so the
                    // guidance shows the real file the user must add.
                    Text(String(
                        format: String(localized: "2. Add %@ and enable it"),
                        Bundle.main.bundleURL.lastPathComponent
                    ))
                    Text("3. Return here and click “Refresh”")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

                HStack {
                    Spacer()
                    Button {
                        appState.openSystemSettingsForFullDiskAccess()
                    } label: {
                        Label(String(localized: "Open System Settings…"), systemImage: "gear")
                    }
                }
            }
        }
    }

    // MARK: - FDA status presentation

    private var statusIcon: String {
        switch appState.fullDiskAccessGranted {
        case true?:  return "checkmark.circle.fill"
        case false?: return "exclamationmark.triangle.fill"
        case nil:    return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch appState.fullDiskAccessGranted {
        case true?:  return .green
        case false?: return .orange
        case nil:    return .secondary
        }
    }

    private var statusLabel: String {
        switch appState.fullDiskAccessGranted {
        case true?:  return String(localized: "Granted")
        case false?: return String(localized: "Not Granted")
        case nil:    return String(localized: "Not Checked")
        }
    }

    private func restartApp() {
        // Release the single-instance lock so the relaunched Container can
        // acquire it instead of seeing a duplicate and exiting immediately.
        appState.releaseInstanceLock()

        // Restart pattern: we cannot just `openApplication` then `terminate`,
        // because the new instance's `init` runs while this one is still in
        // `NSRunningApplication.runningApplications(withBundleIdentifier:)`
        // (terminating apps linger in that list). The duplicate guard would
        // then see count > 1 and kill the new instance.
        //
        // Fix: schedule a detached shell that waits for THIS process to exit,
        // THEN re-opens the app. By the time the new instance's init checks
        // the running list, this one is gone. `setsid` detaches it from our
        // lifetime so terminate(nil) below doesn't take it down with us.
        let appPath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(appPath)\""
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        // Detach into its own session so it survives our termination.
        do {
            try task.run()
        } catch {
            // Fallback: immediate relaunch (may hit the race, but better than
            // leaving the user with no running app at all).
            logger.error("Restart detached shell failed: \(error.localizedDescription, privacy: .public)")
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
        }

        NSApplication.shared.terminate(nil)
    }
}
