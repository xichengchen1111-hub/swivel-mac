import Foundation
import Darwin
import DoctorCatalog

/// What a Mac Doctor fix will move to the Trash, checked when it is planned and again just before it runs.
///
/// Rules: the target lies inside the home folder on the home folder's volume; every folder on the way down from the
/// home folder is a real folder (never a symbolic link) and is still the same folder when the move runs; only real
/// files and folders on that volume are moved (links, sockets and other volumes are left alone). A cache is cleaned
/// by gathering what is inside it into one folder named after the cache and moving that folder to the Trash, so the
/// Trash shows one recognisable item per cache and the cache folder itself stays. A single file (a leftover launch
/// agent) is moved as it is. Nothing is ever deleted: everything stays in the Trash until the user empties it.
struct DoctorTrashPlan: Sendable {
    /// A cache's contents (the folder stays), one regular file, or one whole folder.
    enum Mode: Sendable { case contents, item, folder }

    struct Entry: Sendable, Equatable {
        let url: URL
        let identity: FileIdentity
    }

    let mode: Mode
    /// The cache folder (kept) or the single file.
    let target: URL
    /// The home folder, then every folder down to and including the target.
    let chain: [Entry]
    /// What will move: the cache's direct children, or the file itself.
    let items: [Entry]
    /// Links, sockets and items on other volumes that are left in place.
    let skipped: Int
    /// Names the folder that collects a cache's contents in the Trash.
    let name: String
}

/// What a fix moved, so it can be put back.
struct DoctorTrashReceipt: Sendable {
    struct Moved: Sendable, Equatable {
        /// Where the moved item was: the collecting folder inside the cache, or the file.
        let original: URL
        let trashed: URL
        let identity: FileIdentity
        /// The folders from home down to `original`'s folder, as they were.
        let parents: [DoctorTrashPlan.Entry]
        /// The cache's own items inside the collecting folder; empty for a single file.
        let children: [String]
    }

    var moved: [Moved] = []
    /// One line per item that could not be moved; the rest were moved anyway.
    var failures: [String] = []
    var movedItems: Int { moved.reduce(0) { $0 + max(1, $1.children.count) } }
}

enum DoctorTrash {
    /// Moves one item to the Trash and returns where it went. Swapped for a stub in tests.
    typealias Mover = @Sendable (URL) throws -> URL

    static let systemTrash: Mover = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw ToolError(L("The Trash didn’t say where the item went.")) }
        return result as URL
    }

    // MARK: What may be moved

    /// Cache folders may only be emptied when they are vendored catalogue entries; single files only when they are
    /// property lists directly inside ~/Library/LaunchAgents, or files the large-file search found in Downloads,
    /// Desktop or Documents (with the identity they had then). Nothing else, whatever a row says.
    static func isAllowed(_ target: DoctorTrashTarget, catalogue: [CacheEntry] = ClearDiskCatalog.entries) -> Bool {
        switch target.origin {
        case .standard: break
        case .duplicate, .similar: return DoctorDuplicates.isAllowed(target)
        case .build: return DoctorProjects.isAllowed(target)
        case .leftover: return DoctorUninstall.isAllowedLeftover(target)
        }
        switch target.mode {
        case .folder:
            return false
        case .contents:
            return catalogue.contains { $0.path == target.path }
        case .item:
            if DoctorLargeFiles.isAllowed(target) { return true }
            let prefix = "~/Library/LaunchAgents/"
            guard target.path.hasPrefix(prefix) else { return false }
            let name = target.path.dropFirst(prefix.count)
            return name.hasSuffix(".plist") && !name.contains("/") && name.count > 6 && DoctorCommand.isPlain(String(name))
        }
    }

    // MARK: Validation

    /// Resolves "~/a/b" against `home`, checking every step without following links. Returns the home folder and
    /// each step's identity; the last step must be `kind` (a folder or a regular file).
    static func chain(_ homeRelative: String, home: URL, expect kind: mode_t = S_IFDIR) throws -> [DoctorTrashPlan.Entry] {
        guard homeRelative.hasPrefix("~/") else { throw refusal() }
        let parts = homeRelative.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && DoctorCommand.isPlain($0) })
        else { throw refusal() }
        let root = try realHome(home)
        let rootInfo = try status(root)
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw refusal() }
        var entries = [DoctorTrashPlan.Entry(url: root, identity: identity(rootInfo))]
        var url = root
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            url = url.appendingPathComponent(part, isDirectory: !last || kind == S_IFDIR)
            let info = try status(url)
            // Every step must be a real folder (the last one a folder or a regular file as asked), on the home
            // folder's volume, so a symbolic link or a mounted disk can never redirect the move.
            guard info.st_mode & S_IFMT == (last ? kind : S_IFDIR), info.st_dev == rootInfo.st_dev else { throw refusal() }
            entries.append(.init(url: url, identity: identity(info)))
        }
        return entries
    }

    /// Resolves "~/a/b" to its URL after checking every step. See `chain`.
    static func resolve(_ homeRelative: String, home: URL, expect kind: mode_t = S_IFDIR) throws -> URL {
        try chain(homeRelative, home: home, expect: kind).last!.url
    }

    /// True when each folder is still exactly the one recorded (same volume, same file number, still a folder).
    static func unchanged(_ chain: [DoctorTrashPlan.Entry], lastIsFile: Bool = false) -> Bool {
        for (index, entry) in chain.enumerated() {
            var info = stat()
            guard lstat(entry.url.path, &info) == 0 else { return false }
            let expected: mode_t = lastIsFile && index == chain.count - 1 ? S_IFREG : S_IFDIR
            guard info.st_mode & S_IFMT == expected, identity(info) == entry.identity else { return false }
        }
        return true
    }

    /// The home folder with links resolved, so the walk starts from the real folder.
    static func realHome(_ home: URL) throws -> URL {
        guard let real = realpath(home.path, nil) else { throw refusal() }
        defer { free(real) }
        let path = String(cString: real)
        guard path.count > 1 else { throw refusal() }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func status(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ToolError(L("Could not access %@", displayPath(url))) }
        return info
    }

    private static func identity(_ info: stat) -> FileIdentity {
        FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino))
    }

    private static func refusal() -> ToolError {
        ToolError(L("Mac Doctor only moves items it can check: real folders inside your home folder, reached without links."))
    }

    // MARK: Planning

    /// Plans moving everything inside a cache folder (`~/…`) to the Trash, keeping the folder itself.
    static func planContents(of homeRelative: String, name: String, home: URL) throws -> DoctorTrashPlan {
        let chain = try chain(homeRelative, home: home)
        let folder = chain.last!
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        var items: [DoctorTrashPlan.Entry] = []
        var skipped = 0
        for child in names.sorted() {
            let url = folder.url.appendingPathComponent(child)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR, info.st_dev == folder.identity.device else { skipped += 1; continue }
            items.append(.init(url: url, identity: identity(info)))
        }
        return DoctorTrashPlan(mode: .contents, target: folder.url, chain: chain, items: items, skipped: skipped,
                               name: name)
    }

    /// Plans moving one regular file (`~/…`) to the Trash. With `expected`, the file must still be the one the
    /// check looked at.
    static func planItem(_ homeRelative: String, home: URL, expected: FileIdentity? = nil) throws -> DoctorTrashPlan {
        let chain = try chain(homeRelative, home: home, expect: S_IFREG)
        let file = chain.last!
        if let expected, file.identity != expected {
            throw ToolError(L("Files changed since the check. Run the check again."))
        }
        return DoctorTrashPlan(mode: .item, target: file.url, chain: chain, items: [file], skipped: 0,
                               name: file.url.deletingPathExtension().lastPathComponent)
    }

    /// Plans moving one whole folder (`~/…`, never a link) to the Trash. With `expected`, the folder must still be
    /// the one the check looked at.
    static func planFolder(_ homeRelative: String, home: URL, expected: FileIdentity? = nil) throws -> DoctorTrashPlan {
        let chain = try chain(homeRelative, home: home, expect: S_IFDIR)
        let folder = chain.last!
        if let expected, folder.identity != expected {
            throw ToolError(L("Files changed since the check. Run the check again."))
        }
        return DoctorTrashPlan(mode: .folder, target: folder.url, chain: chain, items: [folder], skipped: 0,
                               name: folder.url.lastPathComponent)
    }

    /// The plan for a target of any mode.
    static func plan(_ target: DoctorTrashTarget, name: String, home: URL) throws -> DoctorTrashPlan {
        switch target.mode {
        case .contents: try planContents(of: target.path, name: name, home: home)
        case .item: try planItem(target.path, home: home, expected: target.identity)
        case .folder: try planFolder(target.path, home: home, expected: target.identity)
        }
    }

    // MARK: Moving

    /// Moves the planned items to the Trash. Every folder on the way is checked again first, and an item that
    /// changed since the plan is left alone. Blocking: call it off the main thread.
    static func execute(_ plan: DoctorTrashPlan, move: Mover = systemTrash) throws -> DoctorTrashReceipt {
        guard unchanged(plan.chain, lastIsFile: plan.mode == .item) else {
            throw ToolError(L("Files changed since the check. Run the check again."))
        }
        var receipt = DoctorTrashReceipt()
        let parents = plan.mode == .contents ? plan.chain : Array(plan.chain.dropLast())
        if plan.mode != .contents {
            let file = plan.items[0]
            do {
                let trashed = try move(file.url)
                if confirm(trashed, is: file.identity, left: file.url) {
                    receipt.moved.append(.init(original: file.url, trashed: trashed, identity: file.identity,
                                               parents: parents, children: []))
                } else {
                    // It may well be in the Trash, but Undo can't be sure it is the same item: say where to look.
                    receipt.failures.append(L("%@ was moved to the Trash as “%@” but couldn’t be confirmed there; Undo won’t restore it. Check the Trash.",
                                              displayPath(file.url), DoctorText.visible(trashed.lastPathComponent)))
                }
            } catch {
                receipt.failures.append(failure(file.url, error))
            }
            return receipt
        }

        // Gather the cache's items into one new folder inside it, then move that folder.
        let folder = try makeCollector(in: plan.target, name: plan.name)
        let folderIdentity = try FileIdentity.read(folder)
        var gathered: [String] = []
        for item in plan.items {
            guard (try? FileIdentity.read(item.url)) == item.identity else {
                receipt.failures.append(L("%@ changed since the check and was left in place.", displayPath(item.url)))
                continue
            }
            let name = item.url.lastPathComponent
            if let error = rename(item.url, folder.appendingPathComponent(name)) {
                receipt.failures.append(failure(item.url, error))
            } else {
                gathered.append(name)
            }
        }
        guard !gathered.isEmpty else {
            rmdir(folder.path)
            return receipt
        }
        do {
            guard unchanged(plan.chain) else { throw ToolError(L("Files changed since the check. Run the check again.")) }
            let trashed = try move(folder)
            if confirm(trashed, is: folderIdentity, left: folder) {
                receipt.moved.append(.init(original: folder, trashed: trashed, identity: folderIdentity, parents: parents,
                                           children: gathered))
            } else {
                receipt.failures.append(L("%@ was moved to the Trash as “%@” but couldn’t be confirmed there; Undo won’t restore it. Check the Trash.",
                                          displayPath(folder), DoctorText.visible(trashed.lastPathComponent)))
            }
        } catch {
            // Put everything back where it was; nothing was moved.
            for name in gathered { _ = rename(folder.appendingPathComponent(name), plan.target.appendingPathComponent(name)) }
            rmdir(folder.path)
            receipt.failures.append(failure(plan.target, error))
        }
        return receipt
    }

    /// The item really left its place and arrived in the Trash as the same file.
    private static func confirm(_ trashed: URL, is identity: FileIdentity, left original: URL) -> Bool {
        (try? FileIdentity.read(trashed)) == identity && (try? FileIdentity.read(original)) != identity
    }

    /// "Google Chrome cache (Mac Doctor)" or "npm Cache (Mac Doctor)", in the user's language, numbered if that name
    /// is taken. Created exclusively.
    static func collectorName(_ name: String) -> String {
        let shown = L(name)
        return DoctorText.fileName(name.localizedCaseInsensitiveContains("cache") ? L("%@ (Mac Doctor)", shown)
                                                                                   : L("%@ cache (Mac Doctor)", shown))
    }

    private static func makeCollector(in folder: URL, name: String) throws -> URL {
        let base = collectorName(name)
        for number in 1...99 {
            let candidate = folder.appendingPathComponent(number == 1 ? base : "\(base) \(number)", isDirectory: true)
            if mkdir(candidate.path, 0o700) == 0 { return candidate }
            if errno != EEXIST { break }
        }
        throw ToolError(L("Couldn’t prepare %@ for the Trash.", displayPath(folder)))
    }

    /// Moves without replacing anything and without following a link anywhere in either path. nil on success.
    private static func rename(_ source: URL, _ destination: URL) -> Error? {
        let flags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in renamex_np(from!, to!, flags) }
        }
        return result == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func failure(_ url: URL, _ error: Error) -> String {
        if let posix = error as? POSIXError, [.EACCES, .EPERM].contains(posix.code) {
            return L("%@ belongs to another user or is read-only, so it was left in place.", displayPath(url))
        }
        if (error as NSError).code == NSFileWriteNoPermissionError {
            return L("%@ belongs to another user or is read-only, so it was left in place.", displayPath(url))
        }
        return L("%@ couldn’t be moved to the Trash: %@", displayPath(url), error.localizedDescription)
    }

    /// Puts moved items back where they were. Nothing is overwritten: an item whose place was taken again (the app
    /// rebuilt it) stays where it is and is reported. Blocking: call it off the main thread.
    static func undo(_ receipt: DoctorTrashReceipt) -> (restored: Int, left: [URL]) {
        var restored = 0
        var left: [URL] = []
        for moved in receipt.moved.reversed() {
            guard (try? FileIdentity.read(moved.trashed)) == moved.identity, unchanged(moved.parents),
                  rename(moved.trashed, moved.original) == nil else {
                left.append(moved.trashed)
                continue
            }
            guard !moved.children.isEmpty else { restored += 1; continue }
            let cache = moved.original.deletingLastPathComponent()
            for name in moved.children {
                if rename(moved.original.appendingPathComponent(name), cache.appendingPathComponent(name)) == nil {
                    restored += 1
                } else {
                    left.append(moved.original.appendingPathComponent(name))
                }
            }
            rmdir(moved.original.path)  // only succeeds once it is empty
        }
        return (restored, left)
    }

    // MARK: Paths

    /// "~/…" for a URL inside `home`; throws for anything outside it.
    static func homeRelativePath(_ url: URL, home: URL) throws -> String {
        let base = DoctorPrivacy.canonical(try realHome(home).path)
        let path = DoctorPrivacy.canonical(url.path)
        guard path.hasPrefix(base + "/"), !path.contains("/../"), !path.hasSuffix("/..") else { throw refusal() }
        return "~" + path.dropFirst(base.count)
    }

    /// A path for messages: inside the home folder it starts with "~".
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return DoctorText.visible(path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path, limit: 300)
    }
}
