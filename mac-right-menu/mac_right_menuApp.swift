import SwiftUI

// MARK: - AppDelegate

/// Handles macOS reopen event and manages the settings window lifecycle.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            openSettings()
        }
        return true
    }

    @MainActor func openSettings() {
        if let window = NSApp.windows.first(where: { $0.title.contains("mac-right-menu") }) {
            window.makeKeyAndOrderFront(self)
        } else {
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}

// MARK: - App

@main
struct MacRightMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            Button("Open Settings...") {
                if let window = NSApp.windows.first(where: { $0.title.contains("mac-right-menu") }) {
                    window.makeKeyAndOrderFront(self)
                } else {
                    openWindow(id: "settings")
                }
            }
            .keyboardShortcut(",")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "menubar.dock.rectangle")
            Text("mac-right-menu")
        }

        Window("mac-right-menu Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .frame(minWidth: 500, minHeight: 400)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
