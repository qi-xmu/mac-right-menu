import Foundation

public enum Constants {
    public static let appGroupID = "group.com.qi-xmu.mac-right-menu"

    public static let mainAppBundleID = "com.qi-xmu.mac-right-menu"
    public static let extensionBundleID = "com.qi-xmu.mac-right-menu.FinderExtension"

    public enum Defaults {
        public static let menuConfigKey = "menuConfiguration"
        public static let isExtensionEnabledKey = "isExtensionEnabled"
        public static let commandLogOnlyKey = "commandLogOnly"
    }

    public enum TagBase: Int {
        case appItem = 0          // 0-999: open with app
        case copyPath = 1000       // absolute path
        case copyFileName = 1001   // file name only
        case newFile = 2000        // 2000+n: template index
        case toggleHidden = 4000
        case openParent = 5000
    }
}
