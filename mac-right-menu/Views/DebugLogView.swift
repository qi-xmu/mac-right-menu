import SwiftUI

/// Independent window showing every RPC exchange and wake/lifecycle event the
/// Container can observe, in real time. Newest entries appear at the top.
/// In-memory only; cleared on relaunch.
struct DebugLogView: View {
    @EnvironmentObject var appState: AppState
    @State private var filter: FilterCategory = .all
    /// Keep the window above other apps. Persisted across launches.
    @AppStorage("debugLogAlwaysOnTop") private var alwaysOnTop = false
    /// Expanded entry ids — a Set so multiple rows can be open at once.
    @State private var expanded: Set<UUID> = []
    /// Last export result, surfaced briefly as a toast-ish footer line.
    @State private var exportResult: ExportResult?

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
                Button {
                    if let url = appState.exportDebugLog() {
                        exportResult = ExportResult(.success, url: url)
                    } else if appState.debugLog.isEmpty {
                        exportResult = ExportResult(.empty)
                    } else {
                        exportResult = ExportResult(.cancelled)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(appState.debugLog.isEmpty)
                .help(String(localized: "Save the debug log to a file"))
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
                    systemImage: "ladybug",
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
                        DebugLogRow(
                            entry: entry,
                            timeFormatter: timeFormatter,
                            isExpanded: expanded.contains(entry.id),
                            onToggle: {
                                if expanded.contains(entry.id) {
                                    expanded.remove(entry.id)
                                } else {
                                    expanded.insert(entry.id)
                                }
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }

            // Transient export result banner. Auto-clears after a few seconds
            // so it doesn't sit on screen forever.
            if let result = exportResult {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: result.icon)
                        .foregroundStyle(result.color)
                    Text(result.message)
                        .font(.caption)
                    Spacer()
                    Button {
                        if result.kind == .success, let url = result.url {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } label: {
                        if result.kind == .success {
                            Text("Show")
                        } else {
                            Text("Dismiss")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onAppear {
                    // Auto-dismiss after 6s; user can also click Dismiss.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        if exportResult?.id == result.id { exportResult = nil }
                    }
                }
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

// MARK: - Export result banner

/// Lightweight transient state for the export-result footer. Comparable `id`
/// so the auto-dismiss timer can tell whether the user has since triggered
/// another export (in which case the old timer should leave things alone).
private struct ExportResult: Equatable {
    let id = UUID()
    enum Kind { case success, cancelled, empty }
    let kind: Kind
    let url: URL?

    init(_ kind: Kind, url: URL? = nil) { self.kind = kind; self.url = url }

    var icon: String {
        switch kind {
        case .success:  return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .empty:    return "exclamationmark.triangle"
        }
    }
    var color: Color {
        switch kind {
        case .success:  return .green
        case .cancelled: return .secondary
        case .empty:    return .orange
        }
    }
    var message: String {
        switch kind {
        case .success:
            return String(
                format: String(localized: "Exported to %@"),
                url?.lastPathComponent ?? ""
            )
        case .cancelled:
            return String(localized: "Export cancelled")
        case .empty:
            return String(localized: "Nothing to export — log is empty")
        }
    }
}

// MARK: - Row

private struct DebugLogRow: View {
    let entry: DebugLogEntry
    let timeFormatter: DateFormatter
    let isExpanded: Bool
    let onToggle: () -> Void

    /// True when this row has detail worth expanding into. Rows without detail
    /// (heartbeats, plain lifecycle) render as a flat line and ignore clicks.
    private var hasDetail: Bool {
        if let d = entry.detail, !d.isEmpty { return true }
        if let p = entry.rawPayload, !p.isEmpty { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if hasDetail {
                    // Disclosure chevron. Only the chevron toggles expand — NOT
                    // the whole row — so a drag-to-select on the summary text
                    // isn't stolen by a row-level tap gesture.
                    Button {
                        onToggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 10)
                }
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

            // Expanded detail: raw JSON payload first (if present), then the
            // human-readable detail text below. JSON is pretty-printed so it's
            // readable at a glance; the raw string is preserved for copy/paste.
            if isExpanded {
                if let raw = entry.rawPayload, !raw.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("JSON")
                            .font(.system(.caption2, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                        Text(DebugLogRow.formatJSON(raw))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 34)
                    .padding(.trailing, 8)
                    .padding(.bottom, 2)
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 34)
                        .padding(.trailing, 8)
                        .padding(.bottom, 4)
                }
            }
        }
        // Apply selection at the row-container level: it propagates to every
        // nested Text (header + detail), so the whole row — timestamps, badges,
        // summary, and the expanded payload block — is selectable and copyable
        // (Cmd+C / right-click → Copy). Per Apple docs, applying to a container
        // affects all child Text views.
        .textSelection(.enabled)
    }

    private var iconName: String {
        switch entry.category {
        case .rpc:
            return entry.direction == .send ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        case .wake:       return "bell.fill"
        case .connection: return "cable.connector"
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

    /// Try to pretty-print a raw JSON-RPC payload string. On success returns
    /// indented JSON for readability; on parse failure returns the original raw
    /// string as-is so the user still sees *something*.
    static func formatJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8)
        else { return raw }
        return result
    }
}
