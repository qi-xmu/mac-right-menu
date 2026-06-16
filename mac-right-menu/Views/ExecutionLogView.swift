import SwiftUI

/// Independent window showing every command execution in real time.
/// Newest entries appear at the top. In-memory only; cleared on relaunch.
struct ExecutionLogView: View {
    @EnvironmentObject var appState: AppState

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Execution Log")
                        .font(.headline)
                    Text("Real-time record of every command received from the Extension.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    appState.clearLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(appState.executionLog.isEmpty)
            }
            .padding(16)

            Divider()

            if appState.executionLog.isEmpty {
                ContentUnavailableView(
                    "No Execution Records",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Trigger a menu item in Finder to see results here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // Newest first.
                    ForEach(appState.executionLog.reversed()) { entry in
                        ExecutionLogRow(entry: entry, timeFormatter: timeFormatter)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

// MARK: - Row

private struct ExecutionLogRow: View {
    let entry: ExecutionLogEntry
    let timeFormatter: DateFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(entry.success ? .green : .red)
                Text(timeFormatter.string(from: entry.timestamp))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(entry.action)
                    .fontWeight(.semibold)
                if entry.logOnly {
                    Text("Log Only")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(entry.files.count) file\(entry.files.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let err = entry.errorDescription {
                Text(err)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if let cmd = entry.shellCommand {
                Text(cmd)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            }

            // Files (truncated to 3 + "N more").
            if !entry.files.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(entry.files.prefix(3).enumerated()), id: \.offset) { _, path in
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if entry.files.count > 3 {
                        Text("… and \(entry.files.count - 3) more")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Extra payload (appPath / templateIndex / ...).
            if let extra = entry.extra, !extra.isEmpty {
                let pairs = extra.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "  ")
                Text(pairs)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
    }
}
