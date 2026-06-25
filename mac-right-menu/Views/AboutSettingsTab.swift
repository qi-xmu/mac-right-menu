import SwiftUI

struct AboutSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var updateMessage: String?
    @State private var downloadURL: String?
    @State private var downloadError: String?

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
                if let url = downloadURL {
                    performDownload(url: url)
                } else {
                    checkForUpdates()
                }
            } label: {
                HStack(spacing: 6) {
                    if appState.isCheckingUpdate || appState.isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(String(localized: appState.isDownloading ? "Downloading..." :
                        appState.isCheckingUpdate ? "Checking..." :
                        downloadURL != nil ? "Download & Install" : "Check for Updates"))
                }
            }
            .disabled(appState.isCheckingUpdate || appState.isDownloading)

            VStack {
                if let msg = updateMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = downloadError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }.frame(height: 20)

        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func checkForUpdates() {
        if appState.isCheckingUpdate { return }
        updateMessage = nil
        downloadURL = nil
        downloadError = nil
        appState.checkForUpdate { result in
            DispatchQueue.main.async {
                switch result {
                case .upToDate:
                    updateMessage = String(localized: "You're up to date!")
                case .updateAvailable(let latest, let url):
                    updateMessage = String(localized: "New version v\(latest) available!")
                    downloadURL = url
                case .error(let msg):
                    updateMessage = msg
                }
            }
        }
    }

    private func performDownload(url: String) {
        downloadError = nil
        appState.downloadAndInstall(from: url) { error in
            if let error {
                downloadError = error
            } else {
                downloadURL = nil
                updateMessage = nil
            }
        }
    }
}
