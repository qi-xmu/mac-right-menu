import SwiftUI

/// Independent window showing every RPC exchange and wake/lifecycle event the
/// Container can observe, in real time. Newest entries appear at the top.
/// In-memory only; cleared on relaunch.
struct DebugLogView: View {
    @EnvironmentObject var appState: AppState
    @State private var filter: FilterCategory = .all
    /// Keep the window above other apps. Persisted across launches.
    @AppStorage("debugLogAlwaysOnTop") private var alwaysOnTop = false

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Visible entries after applying the current category filter.
    private var visibleEntries: [DebugLogEntry] {
        let entries = Array(appState.debugLog.reversed()) // newest first
        guard let cat = filter.category else { return entries }
        return entries.filter { $0.category == cat }
    }

    /// Apply the always-on-top level to the hosting window. Safe to call
    /// repeatedly; a no-op if the window can't be resolved yet.
    /// Uses `NSWindow.identifier` ("debug-log", set by the Window scene id)
    /// rather than title, so it works regardless of locale.
    private func syncWindowLevel() {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "debug-log"
        }) else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug Log")
                        .font(.headline)
                    Text("Real-time record of RPC traffic and wake events (Con viewpoint).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    alwaysOnTop.toggle()
                    syncWindowLevel()
                } label: {
                    Image(systemName: alwaysOnTop ? "pin.fill" : "pin")
                        .help(alwaysOnTop
                              ? String(localized: "Disable Always on Top")
                              : String(localized: "Enable Always on Top"))
                }
                .buttonStyle(.borderless)
                Picker("", selection: $filter) {
                    ForEach(FilterCategory.allCases) { c in
                        Text(c.label).tag(c)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Button(role: .destructive) {
                    appState.clearDebugLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(appState.debugLog.isEmpty)
            }
            .padding(16)
            .onAppear {
                // Window might not be registered yet at first render; brief
                // async hop ensures the NSWindow is in the window list.
                DispatchQueue.main.async { syncWindowLevel() }
            }
            .onChange(of: alwaysOnTop) { _, _ in syncWindowLevel() }

            Divider()

            if appState.debugLog.isEmpty {
                ContentUnavailableView(
                    "No Debug Records",
                    systemImage: "ant",
                    description: Text("RPC messages and wake events will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleEntries.isEmpty {
                ContentUnavailableView(
                    "No Records in This Category",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Switch the filter to see other categories.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleEntries) { entry in
                        DebugLogRow(entry: entry, timeFormatter: timeFormatter)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

// MARK: - Filter

private enum FilterCategory: String, CaseIterable, Identifiable {
    case all, rpc, wake, connection, lifecycle
    var id: String { rawValue }
    /// Maps to the DebugLogEntry.Category being filtered, or nil for "all".
    var category: DebugLogEntry.Category? {
        switch self {
        case .all:        return nil
        case .rpc:        return .rpc
        case .wake:       return .wake
        case .connection: return .connection
        case .lifecycle:  return .lifecycle
        }
    }
    var label: String {
        switch self {
        case .all:        return String(localized: "All")
        case .rpc:        return "RPC"
        case .wake:       return String(localized: "Wake")
        case .connection: return String(localized: "Connection")
        case .lifecycle:  return String(localized: "Lifecycle")
        }
    }
}

// MARK: - Row

private struct DebugLogRow: View {
    let entry: DebugLogEntry
    let timeFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 16)
            Text(timeFormatter.string(from: entry.timestamp))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(badge)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(badgeColor.opacity(0.15), in: Capsule())
                .foregroundColor(badgeColor)
            if entry.count > 1 {
                Text(String(localized: "Heartbeat ×\(entry.count)"))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.pink.opacity(0.15), in: Capsule())
                    .foregroundStyle(.pink)
            }
            Text(entry.summary)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer()
            if let end = entry.endTimestamp {
                Text("– \(timeFormatter.string(from: end))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    private var iconName: String {
        switch entry.category {
        case .rpc:
            return entry.direction == .send ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        case .wake:       return "bell.fill"
        case .connection: return "powerplugs.fill"
        case .lifecycle:  return "gearshape.fill"
        }
    }

    private var iconColor: Color {
        switch entry.category {
        case .rpc:        return entry.direction == .send ? .blue : .green
        case .wake:       return .orange
        case .connection: return .purple
        case .lifecycle:  return .secondary
        }
    }

    /// Short tag rendered as a capsule: RPC direction symbol, or the method/
    /// event name for non-RPC entries.
    private var badge: String {
        switch entry.category {
        case .rpc:
            let sym = entry.direction == .send ? "↑" : "↓"
            let m = entry.method ?? "rpc"
            if let id = entry.rpcID {
                return "\(sym) \(m) #\(id)"
            }
            return "\(sym) \(m)"
        case .wake:       return entry.method ?? String(localized: "Wake")
        case .connection: return entry.method ?? String(localized: "Connection")
        case .lifecycle:  return entry.method ?? String(localized: "Lifecycle")
        }
    }

    private var badgeColor: Color { iconColor }
}
