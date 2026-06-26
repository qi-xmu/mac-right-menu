import AppKit
import Foundation
import os.log

/// System sleep/wake observer via NSWorkspace notifications.
public final class PowerStateObserver: @unchecked Sendable {
    public static let shared = PowerStateObserver()

    public var onSleep: (() -> Void)?
    public var onWake: (() -> Void)?

    private let log = Logger(subsystem: "com.qi-xmu.mac-right-menu", category: "power")

    private init() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.log.notice("System will sleep")
            self?.onSleep?()
        }

        nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.log.notice("System woke up")
            self?.onWake?()
        }
    }
}
