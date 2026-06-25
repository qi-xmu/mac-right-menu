import SwiftUI

struct AboutSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var updateMessage: String?

    private var currentVersion: String {
        "v\(Constants.version) (\(Constants.build))"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("mac-right-menu")
                .font(.title)
            Text(currentVersion)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Add custom actions to Finder right-click menu: create new files, open with apps, copy paths, toggle hidden files, and more."))
                    .font(.body)
                    .foregroundStyle(.secondary)
                
                Text(String(localized: "Quick Start"))
                    .font(.headline)
                Text(String(localized: "• Right-click files or empty space in Finder to use the menu"))
                Text(String(localized: "• Add file templates in the File tab"))
                Text(String(localized: "• Add apps in the Apps tab"))
                Text(String(localized: "• Check extension status in the Extensions tab"))
                Text(String(localized: "• Error alerts appear when an action fails"))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)

            Button {
                checkForUpdates()
            } label: {
                HStack(spacing: 6) {
                    if(appState.isCheckingUpdate){
                        ProgressView()
                            .controlSize(.small)
                    }
                    
                    Text(String(localized: appState.isCheckingUpdate ? "Checking..." : "Check for Updates"))
                }
            }
            .disabled(appState.isCheckingUpdate)
            VStack{
                if let msg = updateMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }.frame(height: 20)

        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func checkForUpdates() {
        if appState.isCheckingUpdate { return }
        updateMessage = nil
        appState.checkForUpdate { result in
            DispatchQueue.main.async {
                switch result {
                case .upToDate:
                    updateMessage = String(localized: "You're up to date!")
                case .updateAvailable(let latest):
                    updateMessage = String(localized: "New version \(latest) available!")
                case .error(let msg):
                    updateMessage = msg
                }
                // Clear message after 5s
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    updateMessage = nil
                }
            }
        }
    }
}
