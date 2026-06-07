import SwiftUI

struct NewFileSettingsTab: View {
    @EnvironmentObject var appState: AppState

    @State private var showingAddTemplate = false
    @State private var newName = ""
    @State private var newExtension = "txt"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Section: New File Templates
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("New File Templates")
                            .font(.headline)
                        Spacer()
                        Button("Add Template...") { showingAddTemplate = true }
                    }

                    Text("Add file templates for creating new files from the right-click menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if appState.newFileTemplates.isEmpty {
                        ContentUnavailableView(
                            "No Templates",
                            systemImage: "doc.badge.plus",
                            description: Text("Click \"Add Template...\" to create your first template.")
                        )
                        .frame(maxHeight: 200)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(appState.newFileTemplates) { template in
                                HStack {
                                    Image(systemName: iconForExtension(template.fileExtension))
                                        .frame(width: 20)
                                        .foregroundColor(.accentColor)
                                    VStack(alignment: .leading) {
                                        Text(template.name)
                                            .fontWeight(.medium)
                                        Text(".\(template.fileExtension)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        if let index = appState.newFileTemplates.firstIndex(where: { $0.id == template.id }) {
                                            appState.configuration.newFileTemplates.remove(at: index)
                                            appState.saveConfiguration()
                                        }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
        .sheet(isPresented: $showingAddTemplate) {
            addTemplateSheet
        }
    }

    var addTemplateSheet: some View {
        VStack(spacing: 16) {
            Text("Add File Template")
                .font(.headline)

            TextField("Template Name (e.g. Shell Script)", text: $newName)
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
                    let template = NewFileTemplate(name: newName, fileExtension: newExtension)
                    appState.configuration.newFileTemplates.append(template)
                    appState.saveConfiguration()
                    showingAddTemplate = false
                    newName = ""
                    newExtension = "txt"
                }
                .disabled(newName.isEmpty || newExtension.isEmpty)
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
