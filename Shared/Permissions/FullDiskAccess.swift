import Foundation

/// Detects Full Disk Access (FDA) status for the running process.
///
/// macOS exposes no public API to query FDA. The reliable workaround for a
/// non-sandboxed app is to attempt a READ of a TCC-protected file that is only
/// reachable with FDA. A read (as opposed to a write) does NOT trigger a TCC
/// consent prompt — it simply fails with permission denied when FDA is missing.
///
/// The Container (Con) is non-sandboxed (no `app-sandbox` entitlement), so this
/// technique applies. FDA is the catch-all permission that lets Con's file
/// operations — copy path, new file, open with app, shell commands — reach
/// files in any location, including TCC-protected ones like ~/Library/Mail.
enum FullDiskAccess {

    /// Standard canary: the system's own TCC database. Only readable with FDA.
    /// A stable, well-known path across macOS versions.
    private static let canaryPath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// Returns `true` if the current process can read the TCC canary file,
    /// i.e. Full Disk Access is granted. `false` otherwise.
    ///
    /// `FileManager.isReadableFile` alone has been observed to return `true`
    /// without actual read access in some edge cases, so a real `FileHandle`
    /// open is used as the source of truth and both must succeed.
    ///
    /// Cheap (a stat + open + close); safe to call off the main thread.
    /// The caller is responsible for dispatching — this method is synchronous.
    static func isGranted() -> Bool {
        guard FileManager.default.isReadableFile(atPath: canaryPath),
              let handle = FileHandle(forReadingAtPath: canaryPath)
        else { return false }
        handle.closeFile()
        return true
    }
}
