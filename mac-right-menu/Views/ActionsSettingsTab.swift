import SwiftUI

struct ActionsSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Actions")
                        .font(.headline)

                    Text("Toggle which actions appear in the right-click menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // MARK: - Section: Available Actions
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(GeneralOperation.allCases, id: \.rawValue) { operation in
                        HStack(alignment: .top) {
                            Image(systemName: operation.systemIconName)
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(operation.displayTitle)
                                    .fontWeight(.medium)
                                Text(operation.localizedDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { appState.operationEnabled(operation) },
                                set: { newValue in appState.setOperation(operation, enabled: newValue) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                    }
                }
            
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
