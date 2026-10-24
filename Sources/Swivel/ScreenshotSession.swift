import AppKit
import Darwin

/// Advisory lock survives app activation changes and is released by the kernel on exit/crash.
/// O_CLOEXEC keeps converters and other subprocesses from inheriting the app's ownership.
final class AppInstanceLease {
    private let file: URL
    private var descriptor: Int32 = -1
    init(file: URL) { self.file = file }
    func acquire() throws -> Bool {
        if descriptor >= 0 { return true }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { descriptor = fd; return true }
        let failure = errno; close(fd)
        if failure == EWOULDBLOCK { return false }
        throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }
    func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 } }
    deinit { if descriptor >= 0 { close(descriptor) } }
}

/// A process may restore only the screenshot settings it currently owns. The original
/// values stay shared so a new process can recover a session left by a crashed instance.
@MainActor
final class ScreenshotSession {
    static let savedKey = "savedScreencaptureSettings"
    static let ownerKey = "screencapture.owner"
    static let pathKey = "screencapture.managedPath"
    private let defaults: UserDefaults
    private let owner: String
    private let read: (String) -> Any?
    private let write: (String, Any?) -> Void
    private let synchronize: () -> Void
    private let unset = "__unset__"

    init(defaults: UserDefaults, owner: String = UUID().uuidString,
         read: @escaping (String) -> Any?, write: @escaping (String, Any?) -> Void,
         synchronize: @escaping () -> Void) {
        self.defaults = defaults; self.owner = owner
        self.read = read; self.write = write; self.synchronize = synchronize
    }

    func isActive(into folder: URL) -> Bool {
        read("location") as? String == folder.path && read("show-thumbnail") as? Bool == false
    }

    func enable(into folder: URL) {
        if defaults.string(forKey: Self.ownerKey) == owner, defaults.dictionary(forKey: Self.savedKey) != nil,
           defaults.string(forKey: Self.pathKey) == folder.path, isActive(into: folder) { return }
        defaults.synchronize()
        if var original = defaults.dictionary(forKey: Self.savedKey) {
            // Keep an explicit system-toolbar change as the new restore destination,
            // even if a later activation repairs takeover while the feature stays on.
            let path = read("location") as? String
            let previousPath = original["location"] as? String == unset ? nil : original["location"] as? String
            if path != folder.path && path != previousPath { original["location"] = path ?? unset }
            let thumbnail = read("show-thumbnail") as? Bool
            if thumbnail != false && thumbnail != original["show-thumbnail"] as? Bool { original["show-thumbnail"] = thumbnail as Any? ?? unset }
            defaults.set(original, forKey: Self.savedKey)
        } else {
            let abandoned = read("location") as? String == folder.path
            // Without a backup, never make our private Incoming folder the quit destination.
            var original: [String: Any] = [:]
            for key in ["location", "show-thumbnail"] { original[key] = abandoned ? unset : (read(key) ?? unset) }
            defaults.set(original, forKey: Self.savedKey)
        }
        defaults.set(owner, forKey: Self.ownerKey); defaults.set(folder.path, forKey: Self.pathKey)
        defaults.synchronize()
        if !isActive(into: folder) {
            write("location", folder.path); write("show-thumbnail", false); synchronize()
        }
    }

    var originalLocation: URL {
        let saved = defaults.dictionary(forKey: Self.savedKey)
        if let path = saved?["location"] as? String, path != unset { return directory(path) }
        if saved == nil, let path = read("location") as? String, path != defaults.string(forKey: Self.pathKey) { return directory(path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    @discardableResult func restore() -> Bool {
        defaults.synchronize()
        guard defaults.string(forKey: Self.ownerKey) == owner,
              let saved = defaults.dictionary(forKey: Self.savedKey) else { return false }
        // A user may have chosen another destination in the system screenshot toolbar.
        // Restore only fields that still have the values this session installed.
        if let path = defaults.string(forKey: Self.pathKey), read("location") as? String == path {
            write("location", restored(saved["location"]))
        }
        if read("show-thumbnail") as? Bool == false { write("show-thumbnail", restored(saved["show-thumbnail"])) }
        synchronize()
        for key in [Self.savedKey, Self.ownerKey, Self.pathKey] { defaults.removeObject(forKey: key) }
        defaults.synchronize()
        return true
    }

    private func restored(_ value: Any?) -> Any? { value as? String == unset ? nil : value }
    private func directory(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true) }
}

/// Launching the Desktop copy while the Applications copy is running reopens the owner.
/// A second process must exit before starting watchers or claiming screenshot settings.
@MainActor
enum AppInstance {
    static let reopen = Notification.Name("SwivelReopenExistingInstance")
    private static var lease: AppInstanceLease?
    struct Process: Equatable { var pid: Int32; var launched: Date }
    static func leader(_ processes: [Process]) -> Int32? {
        processes.min { $0.launched == $1.launched ? $0.pid < $1.pid : $0.launched < $1.launched }?.pid
    }
    static func reopenExisting() throws -> Bool {
        // Bundle.main can resolve differently when an .app executable is invoked directly.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let containingApp = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let id = Bundle.main.bundleIdentifier ?? (containingApp.pathExtension == "app" ? Bundle(url: containingApp)?.bundleIdentifier : nil)
        guard let id else { return false }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swivel", isDirectory: true).appendingPathComponent("instance-" + id + ".lock")
        let lease = AppInstanceLease(file: file)
        if try lease.acquire() { self.lease = lease; return false }
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy != .prohibited }
        let pid = leader(peers.map { Process(pid: $0.processIdentifier, launched: $0.launchDate ?? .distantPast) })
        DistributedNotificationCenter.default().postNotificationName(reopen, object: id, userInfo: nil, deliverImmediately: true)
        if let existing = peers.first(where: { $0.processIdentifier == pid }) {
            NSApp.yieldActivation(to: existing)
            existing.activate(from: .current, options: [])
        }
        return true
    }
}
