import SwiftUI

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag { openSettings() }
        return true
    }

    @MainActor func openSettings() {
        if let window = NSApp.windows.first(where: {
            $0.title.contains("mac-right-menu")
        }) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(self)
        } else {
            NotificationCenter.default.post(
                name: .openSettingsWindow,
                object: nil
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: {
                    $0.title.contains("mac-right-menu")
                })?.makeKeyAndOrderFront(nil)
            }
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
            Button("Open Settings") {
                if let window = NSApp.windows.first(where: {
                    $0.title.contains("mac-right-menu")
                }) {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(self)
                } else {
                    openWindow(id: "settings")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first(where: {
                            $0.title.contains("mac-right-menu")
                        })?.makeKeyAndOrderFront(nil)
                    }
                }
            }
            .keyboardShortcut(",")
            Button("Execution Log") {
                openWindow(id: "log")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: {
                        $0.title.contains("Execution Log")
                    })?.makeKeyAndOrderFront(nil)
                }
            }.keyboardShortcut("l")
            Divider()
            Button("Quit") {
                appState.shutdownExtensions()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "menubar.dock.rectangle")
        }

        Window("mac-right-menu Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .frame(
                    minWidth: 560,
                    maxWidth: 560,
                    minHeight: 400,
                    maxHeight: 600
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
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
