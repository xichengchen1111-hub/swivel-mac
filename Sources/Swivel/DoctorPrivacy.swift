import Foundation
import Darwin

/// Places Mac Doctor never looks into on its own. macOS guards them: reading them either asks the user for access
/// (Desktop, Documents, Downloads, other apps' data, removable and network drives) or fails because only Full Disk
/// Access opens them. Checking this list before every read keeps the promise of "no new permissions" and no prompts.
enum DoctorPrivacy {
    /// Relative to the home folder.
    static let homeRelative = [
        "Desktop", "Documents", "Downloads", "Pictures/Photos Library.photoslibrary",
        "Library/Containers", "Library/Group Containers", "Library/Mobile Documents", "Library/CloudStorage",
        "Library/Mail", "Library/Messages", "Library/Safari", "Library/Caches/com.apple.Safari",
        "Library/Application Support/com.apple.TCC", "Library/Application Support/MobileSync",
        "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Calendars", "Library/Reminders", "Library/HomeKit", "Library/IdentityServices",
        "Library/Suggestions", "Library/Metadata/CoreSpotlight", "Library/Cookies", ".Trash",
    ]

    /// One spelling per place: "/var/…" and "/private/var/…" are the same folder. Never resolves links, so it can't
    /// be redirected; `standardizedFileURL` is avoided because it drops "/private" only for paths that exist.
    static func canonical(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        for short in ["/var/", "/tmp/", "/etc/"] where trimmed.hasPrefix(short) || trimmed + "/" == short {
            return "/private" + trimmed
        }
        return trimmed
    }

    /// The place a path names, for comparing against the protected list: every spelling of one folder gives the same
    /// answer. "." and ".." are folded without touching the disk, the firmlinked "/System/Volumes/Data/Users/…" is the
    /// same folder as "/Users/…", and APFS ignores case, so "/users/me/documents" is ~/Documents too.
    static func location(_ path: String) -> String {
        var parts: [Substring] = []
        for part in canonical(path).split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        var folded = canonical("/" + parts.joined(separator: "/")).lowercased()
        let data = "/system/volumes/data"
        if folded == data { return "/" }
        if folded.hasPrefix(data + "/") { folded = canonical(String(folded.dropFirst(data.count))).lowercased() }
        return folded
    }

    /// True when reading `url` (or anything inside it) could make macOS ask for access or needs Full Disk Access.
    static func isProtected(_ url: URL, home: URL) -> Bool {
        let path = location(url.path)
        for mounts in ["/volumes", "/network", "/net"] where path == mounts || path.hasPrefix(mounts + "/") { return true }
        if path.hasSuffix(".photoslibrary") || path.contains(".photoslibrary/") { return true }
        let base = location(home.path)
        for relative in homeRelative {
            let protected = base + "/" + relative.lowercased()
            if path == protected || path.hasPrefix(protected + "/") { return true }
        }
        return false
    }

    /// True when `url` lies inside one of the protected places, but isn't itself what the user picked: a folder the
    /// user chose is theirs to look into, its protected subfolders are skipped.
    static func shouldSkip(_ url: URL, below root: URL, home: URL) -> Bool {
        location(url.path) != location(root.path) && isProtected(url, home: home)
            && !isProtected(root, home: home)
    }
}
