import Foundation

public enum Constants {
    public static let appGroupID = "group.com.qi-xmu.mac-right-menu"

    public static let mainAppBundleID = "com.qi-xmu.mac-right-menu"
    public static let extensionBundleID = "com.qi-xmu.mac-right-menu.FinderExtension"

    public enum Notifications {
        /// Posted by Container App when settings change
        public static let settingsChanged = "com.example.mac-right-menu.settingsChanged"
        /// Posted by Container App when requesting extension to refresh
        public static let refreshMenu = "com.example.mac-right-menu.refreshMenu"
    }

    public enum Defaults {
        public static let menuConfigKey = "menuConfiguration"
        public static let isExtensionEnabledKey = "isExtensionEnabled"
    }

    public enum TagBase: Int {
        case appItem = 0          // 0-999: open with app
        case copyPath = 1000       // absolute path
        case copyFileName = 1001   // file name only
        case newFile = 2000        // 2000+n: template index
        case moveToTrash = 3000
        case toggleHidden = 4000
        case openParent = 5000
        case testItem = 9000
    }
}
