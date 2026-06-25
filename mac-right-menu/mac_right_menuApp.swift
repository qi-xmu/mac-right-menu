import SwiftUI

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}

// MARK: - App

@main
struct MacRightMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            Button("Open Settings") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")
            Divider()
            Button("Execution Log") {
                openWindow(id: "log")
                NSApp.activate(ignoringOtherApps: true)
            }.keyboardShortcut("l")
            if appState.debugLogEnabled {
                Button("Debug Log") {
                    openWindow(id: "debug-log")
                    NSApp.activate(ignoringOtherApps: true)
                }.keyboardShortcut("d", modifiers: [.command, .shift])
            }
            Divider()
            Button("Check for Updates") {
                appState.quickCheckUpdate()
            }
            Text("v\(Constants.version) (\(Constants.build))")
                .font(.caption2)

            Divider()
            Button("Quit") {
                appState.quit()
            }
            .keyboardShortcut("q")


        } label: {
            Image(systemName: "menubar.dock.rectangle")
        }

        Window("mac-right-menu Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .frame(
                    maxWidth: 800,
                    maxHeight: 640
                )
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("Execution Log", id: "log") {
            ExecutionLogView()
                .environmentObject(appState)
        }
        .windowResizability(.contentMinSize)

        Window("Debug Log", id: "debug-log") {
            DebugLogView()
                .environmentObject(appState)
        }
        .windowResizability(.contentMinSize)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
