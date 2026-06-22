import SwiftUI

struct NewFileSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: String?   // template id
    @State private var showingAddTemplate = false
    @State private var newExtension = "txt"
    @State private var newFileName = ""

    var body: some View {
        VStack(spacing: 12) {
            // MARK: - Section: New File master switch
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(localized: "New File"))
                        .fontWeight(.medium)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.newFileSectionEnabled },
                        set: { appState.newFileSectionEnabled = $0 }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Text(String(localized: "Create a new file from templates"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }

            Divider()

            // MARK: - Section: New File Templates header
            VStack(alignment: .leading, spacing: 8) {
                Text("New File Templates")
                    .font(.headline)
                Text("Add file templates for creating new files from the right-click menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)

            // MARK: - List (fills remaining height)
            if appState.newFileTemplates.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "No Templates",
                    systemImage: "doc.badge.plus",
                    description: Text("Click + to create your first template.")
                )
                Spacer()
            } else {
                VStack(spacing: 8) {
                    List(selection: $selection) {
                        ForEach(appState.newFileTemplates) { template in
                            HStack {
                                Image(systemName: iconForExtension(template.fileExtension))
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                Text(template.resolvedFileName)
                                    .fontWeight(.medium)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { template.isEnabled },
                                    set: { newValue in
                                        if let index = appState.newFileTemplates.firstIndex(where: { $0.id == template.id }) {
                                            appState.configuration.newFileTemplates[index].isEnabled = newValue
                                            appState.saveConfiguration()
                                        }
                                    }
                                ))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                            }
                            .padding(.vertical, 2)
                            .tag(template.id)
                        }
                        .onDelete { offsets in
                            appState.configuration.newFileTemplates.remove(atOffsets: offsets)
                            appState.saveConfiguration()
                        }
                    }
                    .listStyle(.inset)
                    Divider()
                    toolbar
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
            }

            if appState.newFileTemplates.isEmpty {
                Divider()
                toolbar
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 420)
        .sheet(isPresented: $showingAddTemplate) {
            addTemplateSheet
        }
    }

    // MARK: - +/- toolbar

    private var toolbar: some View {
        HStack {
            Button { showingAddTemplate = true } label: {
                Image(systemName: "plus").frame(width: 16, height: 16)
            }
            .help(String(localized: "Add a template"))

            Spacer()

            Button {
                if let id = selection,
                   let index = appState.newFileTemplates.firstIndex(where: { $0.id == id }) {
                    appState.configuration.newFileTemplates.remove(at: index)
                    appState.saveConfiguration()
                    selection = nil
                }
            } label: {
                Image(systemName: "minus").frame(width: 16, height: 16)
            }
            .disabled(selection == nil)
            .help(String(localized: "Remove selected"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Add sheet

    var addTemplateSheet: some View {
        VStack(spacing: 16) {
            Text("Add File Template")
                .font(.headline)

            TextField(String(localized: "Untitled"), text: $newFileName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Extension:")
                TextField("e.g. sh", text: $newExtension)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
            }

            HStack {
                Button("Cancel") { showingAddTemplate = false }
                Button("Add") {
                    let trimmed = newFileName.trimmingCharacters(in: .whitespaces)
                    let template = NewFileTemplate(
                        fileName: trimmed,
                        fileExtension: newExtension
                    )
                    appState.configuration.newFileTemplates.append(template)
                    appState.saveConfiguration()
                    showingAddTemplate = false
                    newExtension = "txt"
                    newFileName = ""
                }
                .disabled(newExtension.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 350, height: 200)
    }

    private func iconForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "txt": return "doc.text"
        case "md": return "doc.richtext"
        case "json": return "curlybraces"
        case "rtf": return "doc.richtext"
        case "sh", "bash", "zsh": return "terminal"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "swift": return "swift"
        default: return "doc"
        }
    }
}
