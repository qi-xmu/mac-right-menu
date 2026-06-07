import Foundation
import os.log

private let logger = Logger(subsystem: Constants.mainAppBundleID, category: "settings-sync")

/// Manages settings synchronization between Container App and Finder Extension
/// via DistributedNotificationCenter.
public enum SettingsSync {
    /// Post a notification that settings have changed.
    /// Called by the Container App after saving settings.
    public static func postSettingsChanged() {
        logger.notice("Posting settings changed notification")
        DistributedNotificationCenter.default()
            .postNotificationName(
                NSNotification.Name(Constants.Notifications.settingsChanged),
                object: Constants.mainAppBundleID,
                userInfo: nil,
                deliverImmediately: true
            )
    }

    /// Observe settings change notifications from the Container App.
    /// Called by the Finder Extension on setup.
    /// - Parameter handler: Closure called when settings change is detected.
    ///                      Called on whatever thread DNC delivers on (likely the main thread).
    public static func observeSettingsChanged(handler: @escaping () -> Void) {
        DistributedNotificationCenter.default()
            .addObserver(
                forName: NSNotification.Name(Constants.Notifications.settingsChanged),
                object: Constants.mainAppBundleID,
                queue: .main
            ) { notification in
                logger.notice("Received settings changed notification")
                handler()
            }
    }
}
