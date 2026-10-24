import AppKit
import CryptoKit
import Darwin

// Space map, duplicate files, project build folders and app uninstalling. Ideas from MangoDisk
// (github.com/harry0703/MangoDisk, GPL-3.0): only its feature list was used; no code or rules were read or copied.
// Every check here starts from a folder or app the user picks; nothing is remembered after Swivel quits.

/// Shared walking rules: never follow links, stay on one volume, never download cloud placeholders, skip
/// macOS-protected places below the picked folder.
enum DoctorWalk {
    /// Runs `body` with dataless (cloud placeholder) files left in the cloud for this thread.
    static func withoutDownloads<T>(_ body: () -> T) -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if previous >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) } }
        return body()
    }

    /// Calls `visit` for every entry below `root` (physical, one volume). Return `false` from a folder visit to skip
    /// its contents. Stops on cancellation or after `limit` entries; returns false when it stopped early.
    @discardableResult
    static func walk(_ root: URL, limit: Int = 5_000_000,
                     _ visit: (_ entry: UnsafeMutablePointer<FTSENT>, _ info: Int32, _ path: String) -> Bool) -> Bool {
        guard let path = strdup(root.path) else { return false }
        defer { free(path) }
        var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return false }
        defer { fts_close(fts) }
        var count = 0
        while let entry = fts_read(fts) {
            count += 1
            if count % 4096 == 0, Task.isCancelled || count >= limit { return false }
            let info = Int32(entry.pointee.fts_info)
            let current = String(cString: entry.pointee.fts_path)
            if !visit(entry, info, current), info == FTS_D { fts_set(fts, entry, FTS_SKIP) }
        }
        return true
    }

    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// A folder Finder shows as one document or app (Scrivener projects, DEVONthink databases, libraries…): its
    /// files are never offered one by one. The known list first, then what the system says about the folder.
    static func isPackage(_ path: String) -> Bool {
        if DoctorLargeFiles.packageExtensions.contains((path as NSString).pathExtension.lowercased()) { return true }
        guard !(path as NSString).pathExtension.isEmpty else { return false }
        return (try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }
}

// MARK: - Space map

/// One box of the space map: a folder with its largest items, or a file, or "other items" together.
struct DoctorSpaceNode: Sendable, Equatable {
    var name: String
    var url: URL?
    var bytes: Int64
    var isFolder: Bool
    var children: [DoctorSpaceNode] = []
}

enum DoctorSpaceMap {
    static let depth = 4
    static let keep = 24

    private final class Node {
        let name: String, url: URL, isFolder: Bool
        var bytes: Int64 = 0
        var children: [Node] = []
        init(name: String, url: URL, isFolder: Bool) { self.name = name; self.url = url; self.isFolder = isFolder }

        func frozen() -> DoctorSpaceNode {
            var sorted = children.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
            var rest: Int64 = 0, restCount = 0
            if sorted.count > DoctorSpaceMap.keep {
                for node in sorted[DoctorSpaceMap.keep...] { rest += node.bytes; restCount += 1 }
                sorted.removeLast(sorted.count - DoctorSpaceMap.keep)
            }
            var out = sorted.map { $0.frozen() }
            if rest > 0 { out.append(DoctorSpaceNode(name: L("%d other items", restCount), url: nil, bytes: rest, isFolder: false)) }
            return DoctorSpaceNode(name: DoctorText.visible(name), url: url, bytes: bytes, isFolder: isFolder, children: out)
        }
    }

    struct Outcome: Sendable {
        var root: DoctorSpaceNode
        var size: DoctorStorage.Size
    }

    /// Sizes everything below `root` in one walk, keeping folders and files to `depth` levels. Blocking.
    static func build(_ root: URL, home: URL) -> Outcome {
        DoctorWalk.withoutDownloads {
            var size = DoctorStorage.Size()
            let top = Node(name: root.lastPathComponent, url: root, isFolder: true)
            var stack: [Node] = []
            var linked = Set<UInt64>()
            let finished = DoctorWalk.walk(root) { entry, info, path in
                let level = Int(entry.pointee.fts_level)
                switch info {
                case FTS_DNR, FTS_ERR, FTS_NS:
                    size.unreadable += 1
                    return true
                case FTS_DP:
                    if level > 0, level <= depth, let done = stack.popLast(), let parent = stack.last { parent.bytes += done.bytes }
                    if level == 0, let done = stack.popLast() { top.bytes = done.bytes }
                    return true
                case FTS_D:
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    if level > 0, DoctorPrivacy.shouldSkip(url, below: root, home: home) { size.skipped += 1; return false }
                    size.items += 1
                    if level == 0 { stack.append(top); return true }
                    if level <= depth {
                        let node = Node(name: DoctorWalk.name(path), url: url, isFolder: true)
                        stack.last?.children.append(node)
                        stack.append(node)
                    }
                    return true
                default:
                    guard let stat = entry.pointee.fts_statp?.pointee else { return true }
                    size.items += 1
                    if stat.st_flags & UInt32(SF_DATALESS) != 0 { size.inCloud += 1; return true }
                    if stat.st_nlink > 1, !linked.insert(UInt64(stat.st_ino)).inserted { return true }
                    let bytes = Int64(stat.st_blocks) * 512
                    size.bytes += bytes
                    guard let folder = stack.last else { return true }
                    if level <= depth {
                        let node = Node(name: DoctorWalk.name(path), url: URL(fileURLWithPath: path), isFolder: false)
                        node.bytes = bytes
                        folder.children.append(node)
                    }
                    folder.bytes += bytes
                    return true
                }
            }
            size.cancelled = !finished
            if !finished { top.bytes = size.bytes }
            return Outcome(root: top.frozen(), size: size)
        }
    }
}

// MARK: - Duplicate files

enum DoctorDuplicates {
    static let smallest: Int64 = 1_000_000
    static let maxGroups = 150

    struct Copy: Sendable, Equatable {
        var url: URL
        var bytes: Int64
        var modified: Date
        var identity: FileIdentity
        /// An APFS clone shares its blocks with another file: moving it frees nothing.
        var shared = false
    }

    struct Group: Sendable {
        var digest: String
        var copies: [Copy]
        var wasted: Int64 { copies.dropFirst().filter { !$0.shared }.reduce(0) { $0 + $1.bytes } }
    }

    struct Outcome: Sendable {
        var groups: [Group] = []
        /// Files that are nearly the same (photos, text): shown with how similar they are, never selected for you.
        var similar: [DoctorSimilar.Group] = []
        var cancelled = false
        var skipped = 0
    }

    /// Files with exactly the same content: same size, then the same first and last 64 KB, then the same SHA-256 of
    /// everything. Links, hard links of one file, packages, hidden folders, cloud placeholders and protected places
    /// below the picked folders are never counted. Blocking; checks for cancellation.
    static func find(_ roots: [URL], home: URL, smallest: Int64 = smallest, similar: Bool = true) -> Outcome {
        DoctorWalk.withoutDownloads {
            var outcome = Outcome()
            var bySize: [Int64: [Copy]] = [:]
            var candidates: [Copy] = []
            var seen = Set<String>()
            for root in roots {
                let finished = DoctorWalk.walk(root) { entry, info, path in
                    if info == FTS_D {
                        let name = DoctorWalk.name(path)
                        let ext = (name as NSString).pathExtension.lowercased()
                        if entry.pointee.fts_level > 0, name.hasPrefix(".") || name == "node_modules"
                            || DoctorWalk.isPackage(path)
                            || DoctorPrivacy.shouldSkip(URL(fileURLWithPath: path), below: root, home: home) {
                            outcome.skipped += 1
                            return false
                        }
                        return true
                    }
                    guard info == FTS_F, let stat = entry.pointee.fts_statp?.pointee,
                          stat.st_flags & UInt32(SF_DATALESS) == 0 else { return true }
                    let size = Int64(stat.st_size)
                    let kind = similar ? DoctorSimilar.kind(of: path, size: size) : nil
                    guard size >= smallest || kind != nil else { return true }
                    let identity = FileIdentity(device: stat.st_dev, inode: UInt64(stat.st_ino))
                    guard seen.insert("\(identity.device):\(identity.inode)").inserted else { return true }  // the same file reached twice
                    let copy = Copy(url: URL(fileURLWithPath: path), bytes: Int64(stat.st_blocks) * 512,
                                    modified: Date(timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec)), identity: identity)
                    if size >= smallest { bySize[size, default: []].append(copy) }
                    if kind != nil { candidates.append(copy) }
                    return true
                }
                if !finished { outcome.cancelled = true; return outcome }
            }
            for (_, copies) in bySize where copies.count > 1 {
                if Task.isCancelled { outcome.cancelled = true; break }
                var byEnds: [Data: [Copy]] = [:]
                for copy in copies { if let ends = ends(copy.url) { byEnds[ends, default: []].append(copy) } }
                for (_, candidates) in byEnds where candidates.count > 1 {
                    var byDigest: [String: [Copy]] = [:]
                    for copy in candidates {
                        if Task.isCancelled { break }
                        if let digest = digest(copy.url) { byDigest[digest, default: []].append(copy) }
                    }
                    for (digest, same) in byDigest where same.count > 1 {
                        // The oldest copy is kept by default: it is usually the original.
                        let copies = same.sorted { ($0.modified, $0.url.path) < ($1.modified, $1.url.path) }.map { copy -> Copy in
                            var copy = copy
                            copy.shared = (try? copy.url.resourceValues(forKeys: [.mayShareFileContentKey]).mayShareFileContent) == true
                            return copy
                        }
                        outcome.groups.append(Group(digest: digest, copies: copies))
                    }
                }
            }
            outcome.groups.sort { $0.wasted > $1.wasted }
            if outcome.groups.count > maxGroups { outcome.groups.removeLast(outcome.groups.count - maxGroups) }
            // Files with identical copies stay out of the similarity search altogether: one file in two groups could
            // otherwise be both a kept copy and a moved one.
            let extra = Set(outcome.groups.flatMap { $0.copies.map(\.url.path) })
            if similar, !Task.isCancelled {
                outcome.similar = DoctorSimilar.groups(candidates.filter { !extra.contains($0.url.path) })
            }
            if Task.isCancelled { outcome.cancelled = true }
            return outcome
        }
    }

    /// Opens a regular file without following a link, for reading only.
    private static func open(_ url: URL) -> FileHandle? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { close(fd); return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func ends(_ url: URL) -> Data? {
        guard let handle = open(url) else { return nil }
        let chunk = 65_536
        var data = (try? handle.read(upToCount: chunk)) ?? Data()
        if let end = try? handle.seekToEnd(), end > UInt64(chunk) {
            try? handle.seek(toOffset: end - UInt64(chunk))
            data += (try? handle.read(upToCount: chunk)) ?? Data()
        }
        return data
    }

    /// SHA-256 of the whole file, read in 1 MB pieces; nil when it can't be read or the task is cancelled.
    static func digest(_ url: URL) -> String? {
        guard let handle = open(url) else { return nil }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            let data: Data?
            do { data = try handle.read(upToCount: 1 << 20) } catch { return nil }
            guard let data, !data.isEmpty else { break }  // nil or empty: the end of the file
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A copy may be moved only from inside the home folder (never ~/Library), as the file the search found.
    static func isAllowed(_ target: DoctorTrashTarget) -> Bool {
        guard target.mode == .item, target.identity != nil, target.path.hasPrefix("~/"), !target.path.contains("/../"),
              !target.path.hasPrefix("~/Library/") else { return false }
        return target.path.split(separator: "/").count >= 3
    }

    static func result(_ outcome: Outcome, roots: [URL], home: URL) -> DoctorResult {
        var result = DoctorResult(section: .duplicates, severity: .info, badge: "", headline: "")
        let wasted = outcome.groups.reduce(Int64(0)) { $0 + $1.wasted }
        for (index, group) in outcome.groups.enumerated() {
            let id = "dup.\(index)"
            let tag = "dup." + group.digest
            result.rows.append(DoctorRow(id: id, title: DoctorText.visible(group.copies[0].url.lastPathComponent),
                                         value: L("%d copies · %@ each", group.copies.count, DoctorFormat.bytes(group.copies[0].bytes)),
                                         detail: L("Identical content (checked with SHA-256). Keep one copy; the others free %@.", DoctorFormat.bytes(group.wasted)),
                                         severity: group.wasted >= 1_000_000_000 ? .review : .info, group: tag))
            for (number, copy) in group.copies.enumerated() {
                let target = (try? DoctorTrash.homeRelativePath(copy.url, home: home)).map {
                    DoctorTrashTarget(path: $0, mode: .item, identity: copy.identity, origin: .duplicate)
                }.flatMap { DoctorTrash.isAllowed($0) ? $0 : nil }
                var note = number == 0 ? L("Oldest copy: kept when you choose Select Duplicates.") : L("A copy of the file above.")
                if copy.shared { note += " " + L("It shares its disk space with another copy (an APFS clone), so moving it frees almost nothing.") }
                result.rows.append(DoctorRow(id: "\(id).\(number)", title: DoctorText.visible(copy.url.lastPathComponent),
                                             value: DoctorFormat.bytes(copy.bytes),
                                             detail: DoctorFormat.path(copy.url) + "\n" + L("Modified %@", DoctorFormat.date(copy.modified)) + "\n" + note,
                                             severity: .info, bytes: copy.bytes, location: copy.url, trash: target,
                                             group: tag, level: 1))
            }
        }
        for (index, group) in outcome.similar.enumerated() {
            let id = "sim.\(index)"
            let tag = "sim.\(index)." + group.copies[0].url.path
            let lowest = Int((group.similarity.dropFirst().min() ?? 1) * 100)
            result.rows.append(DoctorRow(id: id, title: DoctorText.visible(group.copies[0].url.lastPathComponent),
                                         value: lowest >= 100 ? L("%d files that look the same", group.copies.count)
                                            : L("%d similar files · %d%% or more alike", group.copies.count, lowest),
                                         detail: L(group.kind == .photo ? "Photos that look almost the same (burst shots, edited or re-saved copies). Compare them before choosing; nothing is selected for you."
                                                                        : "Text files with almost the same lines (an edited copy, an older version). Compare them before choosing; nothing is selected for you."),
                                         severity: .info, group: tag))
            for (number, copy) in group.copies.enumerated() {
                let target = (try? DoctorTrash.homeRelativePath(copy.url, home: home)).map {
                    DoctorTrashTarget(path: $0, mode: .item, identity: copy.identity, origin: .similar)
                }.flatMap { DoctorTrash.isAllowed($0) ? $0 : nil }
                let percent = Int((group.similarity[number] * 100).rounded(.down))
                let value = number == 0 ? L("Largest · %@", DoctorFormat.bytes(copy.bytes))
                    : percent >= 100 ? L("Looks the same · %@", DoctorFormat.bytes(copy.bytes))
                    : L("%d%% alike · %@", percent, DoctorFormat.bytes(copy.bytes))
                result.rows.append(DoctorRow(id: "\(id).\(number)", title: DoctorText.visible(copy.url.lastPathComponent), value: value,
                                             detail: DoctorFormat.path(copy.url) + "\n" + L("Modified %@", DoctorFormat.date(copy.modified)),
                                             severity: .info, bytes: copy.bytes, location: copy.url, trash: target, group: tag, level: 1))
            }
        }
        let found = !outcome.groups.isEmpty || !outcome.similar.isEmpty
        result.badge = !found ? L("None found") : wasted > 0 ? DoctorFormat.bytes(wasted) : L("%d similar groups", outcome.similar.count)
        result.headline = !found ? L("No duplicate or similar files were found.")
            : outcome.similar.isEmpty ? L("%d files have identical copies; removing the extra copies frees %@.", outcome.groups.count, DoctorFormat.bytes(wasted))
            : outcome.groups.isEmpty ? L("No identical copies, but %d groups of files are nearly the same. Compare them and keep the ones you want.", outcome.similar.count)
            : L("%d files have identical copies (extra copies use %@), and %d groups of files are nearly the same.", outcome.groups.count, DoctorFormat.bytes(wasted), outcome.similar.count)
        result.severity = wasted >= 5_000_000_000 ? .review : .info
        if !outcome.groups.isEmpty {
            result.notes.append(L("Select Duplicates selects every copy except the oldest in each group. Mac Doctor never moves the last copy of a file, and checks the content again just before moving."))
        }
        if !outcome.similar.isEmpty {
            result.notes.append(L("Similar files are not the same file: each may hold something the others don’t. Use Show in Finder or Quick Look to compare, and keep at least one of each group."))
        }
        if outcome.groups.count >= maxGroups { result.notes.append(L("Only the %d groups that free the most space are listed.", maxGroups)) }
        if outcome.cancelled { result.notes.append(L("The search stopped before it finished.")) }
        result.notes.append(L("Only files inside your home folder (outside Library) can be moved from here; others can be shown in Finder."))
        result.report.append(L("Duplicate files in chosen folders: %d groups; extra copies use %@.", outcome.groups.count, DoctorFormat.bytes(wasted)))
        _ = roots
        return result
    }
}

// MARK: - Project build folders

enum DoctorProjects {
    struct Kind: Sendable {
        let folder: String
        /// Files next to the folder that show which tool made it; "*.csproj" matches by extension.
        let markers: [String]
        /// A file inside the folder that must exist too, if any.
        let inside: String?
        let rebuild: String
    }

    static let kinds: [Kind] = [
        Kind(folder: "node_modules", markers: ["package.json"], inside: nil, rebuild: "npm install, pnpm install or yarn"),
        Kind(folder: "target", markers: ["Cargo.toml"], inside: nil, rebuild: "cargo build"),
        Kind(folder: ".build", markers: ["Package.swift"], inside: nil, rebuild: "swift build"),
        Kind(folder: "build", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], inside: nil, rebuild: "gradle build"),
        Kind(folder: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], inside: nil, rebuild: "gradle build"),
        Kind(folder: "build", markers: ["CMakeLists.txt"], inside: "CMakeCache.txt", rebuild: "cmake"),
        Kind(folder: ".venv", markers: ["pyproject.toml", "requirements.txt", "setup.py"], inside: "pyvenv.cfg", rebuild: "python -m venv, then pip install"),
        Kind(folder: "venv", markers: ["pyproject.toml", "requirements.txt", "setup.py"], inside: "pyvenv.cfg", rebuild: "python -m venv, then pip install"),
        Kind(folder: "obj", markers: ["*.csproj", "*.fsproj", "*.vbproj"], inside: nil, rebuild: "dotnet build"),
        Kind(folder: "bin", markers: ["*.csproj", "*.fsproj", "*.vbproj"], inside: nil, rebuild: "dotnet build"),
        Kind(folder: ".next", markers: ["next.config.js", "next.config.mjs", "next.config.ts"], inside: nil, rebuild: "next build"),
        Kind(folder: ".godot", markers: ["project.godot"], inside: nil, rebuild: "opening the project in Godot"),
        Kind(folder: ".dart_tool", markers: ["pubspec.yaml"], inside: nil, rebuild: "flutter pub get"),
        Kind(folder: "Pods", markers: ["Podfile"], inside: nil, rebuild: "pod install"),
    ]
    static let names = Set(kinds.map(\.folder))
    static let smallest: Int64 = 10_000_000

    struct Found: Sendable {
        var url: URL
        var kind: Kind
        var bytes: Int64
        var identity: FileIdentity
        var changed: Date
    }

    /// The kind a folder is, judged by the files next to it (and inside it), or nil.
    /// Places where tools install software that only looks like a project (editor extensions, global npm packages,
    /// version managers): moving their folders breaks the tool, and "npm install" isn't how it comes back.
    static let installedTools = ["/.vscode/", "/.vscode-insiders/", "/.cursor/", "/.windsurf/", "/.nvm/", "/.npm/",
                                 "/.pnpm-store/", "/.yarn/", "/.bun/", "/.deno/", "/.cargo/", "/.rustup/", "/.pyenv/",
                                 "/.rbenv/", "/.gem/", "/.local/", "/.cache/", "/.m2/", "/.gradle/caches/", "/Library/",
                                 "/lib/node_modules/", "/.config/", "/.oh-my-zsh/", "/Applications/"]

    static func isInstalledTool(_ path: String) -> Bool {
        let folded = DoctorPrivacy.location(path) + "/"
        return installedTools.contains { folded.contains($0.lowercased()) }
    }

    static func kind(of folder: URL) -> Kind? {
        let name = folder.lastPathComponent
        guard names.contains(name), !isInstalledTool(folder.path) else { return nil }
        let parent = folder.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return kinds.first { kind in
            guard kind.folder == name else { return false }
            let marked = kind.markers.contains { marker in
                marker.hasPrefix("*.") ? siblings.contains { $0.lowercased().hasSuffix(marker.dropFirst()) } : siblings.contains(marker)
            }
            guard marked else { return false }
            guard let inside = kind.inside else { return true }
            var info = stat()
            return lstat(folder.appendingPathComponent(inside).path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        }
    }

    /// Rebuildable folders inside the picked folders. Found folders aren't entered, nor are packages or
    /// version-control folders. Blocking; checks for cancellation.
    static func find(_ roots: [URL], home: URL, smallest: Int64 = smallest) -> (found: [Found], cancelled: Bool) {
        var found: [Found] = []
        var cancelled = false
        DoctorWalk.withoutDownloads {
            for root in roots {
                let finished = DoctorWalk.walk(root) { entry, info, path in
                    guard info == FTS_D, entry.pointee.fts_level > 0 else { return true }
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    let name = url.lastPathComponent
                    if let kind = kind(of: url), let stat = entry.pointee.fts_statp?.pointee {
                        found.append(Found(url: url, kind: kind, bytes: 0,
                                           identity: FileIdentity(device: stat.st_dev, inode: UInt64(stat.st_ino)),
                                           changed: Date(timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec))))
                        return false
                    }
                    let ext = url.pathExtension.lowercased()
                    // Hidden folders are entered (projects live in ~/.codex or ~/.config too), except version-control data.
                    if [".git", ".hg", ".svn", ".Trash"].contains(name) || DoctorWalk.isPackage(path) || isInstalledTool(path)
                        || DoctorPrivacy.shouldSkip(url, below: root, home: home) { return false }
                    return true
                }
                if !finished { cancelled = true; break }
            }
        }
        for index in found.indices {
            if Task.isCancelled { cancelled = true; break }
            found[index].bytes = DoctorStorage.size(of: found[index].url, home: home).bytes
        }
        return (found.filter { $0.bytes >= smallest }.sorted { $0.bytes > $1.bytes }, cancelled)
    }

    /// Only a folder with a known name, inside the home folder, as it was found.
    static func isAllowed(_ target: DoctorTrashTarget) -> Bool {
        guard target.mode == .folder, target.identity != nil, target.path.hasPrefix("~/"), !target.path.contains("/../"),
              !target.path.hasPrefix("~/Library/") else { return false }
        let parts = target.path.split(separator: "/")
        return parts.count >= 3 && names.contains(String(parts.last!))
    }

    static func result(_ found: [Found], cancelled: Bool, home: URL) -> DoctorResult {
        var result = DoctorResult(section: .projects, severity: .info, badge: "", headline: "")
        let total = found.reduce(Int64(0)) { $0 + $1.bytes }
        for (index, item) in found.enumerated() {
            let project = DoctorText.visible(item.url.deletingLastPathComponent().lastPathComponent)
            let target = (try? DoctorTrash.homeRelativePath(item.url, home: home)).map {
                DoctorTrashTarget(path: $0, mode: .folder, identity: item.identity, origin: .build)
            }.flatMap { DoctorTrash.isAllowed($0) ? $0 : nil }
            result.rows.append(DoctorRow(id: "build.\(index)", title: project + " · " + item.kind.folder,
                                         value: DoctorFormat.bytes(item.bytes),
                                         detail: DoctorFormat.path(item.url) + "\n" + L("Rebuilt by %@.", L(item.kind.rebuild)) + "\n"
                                            + L("Last changed %@", DoctorFormat.date(item.changed)),
                                         severity: item.bytes >= 1_000_000_000 ? .review : .info, bytes: item.bytes,
                                         location: item.url, trash: target))
        }
        result.badge = found.isEmpty ? L("None found") : DoctorFormat.bytes(total)
        result.headline = found.isEmpty ? L("No rebuildable project folders over 10 MB were found.")
            : L("%d project folders can be rebuilt by their tools; together %@.", found.count, DoctorFormat.bytes(total))
        result.severity = total >= 5_000_000_000 ? .review : .info
        if !found.isEmpty {
            result.notes.append(L("Each folder is recognised by the project file next to it (package.json, Cargo.toml, Package.swift…). The next build or install recreates it, which can take a while and may need the network."))
        }
        if cancelled { result.notes.append(L("The search stopped before it finished.")) }
        result.report.append(L("Rebuildable project folders: %d, together %@.", found.count, DoctorFormat.bytes(total)))
        return result
    }
}

// MARK: - Uninstalling apps

enum DoctorUninstall {
    /// Folders in ~/Library where apps keep their own files, and what is found there.
    static let places: [(path: String, what: String)] = [
        ("Library/Application Support", "Support files and data"),
        ("Library/Caches", "Cache"),
        ("Library/Preferences", "Settings"),
        ("Library/Preferences/ByHost", "Settings for this Mac"),
        ("Library/Saved Application State", "Saved windows"),
        ("Library/HTTPStorages", "Web storage"),
        ("Library/WebKit", "Web data"),
        ("Library/Logs", "Logs"),
        ("Library/LaunchAgents", "Starts by itself"),
        ("Library/Application Scripts", "Scripts"),
    ]
    /// Folder names many apps share; never matched by name.
    static let sharedNames: Set<String> = ["google", "microsoft", "adobe", "apple", "jetbrains", "mozilla", "zoom",
                                           "steam", "cloud", "data", "cache", "caches", "logs", "app", "helper"]

    struct Leftover: Sendable {
        var url: URL
        var path: String
        var what: String
        var bytes: Int64
        var isFolder: Bool
        var identity: FileIdentity
        /// Matched by the app's name rather than its bundle identifier: shown, not selected.
        var byName: Bool
    }

    struct App: Sendable {
        var url: URL
        var bundleID: String
        var name: String
        var version: String
        var bytes: Int64
        var identity: FileIdentity
        var refusal: String?
        var leftovers: [Leftover]
        /// Another copy of the app is installed, or the identifier isn't reverse-DNS: its files may not be this copy's
        /// alone, so nothing is selected for you.
        var sharedIdentifier = false
    }

    /// Why an app can't be uninstalled here, or nil.
    static func refusal(bundleID: String, url: URL) -> String? {
        let path = url.path
        if bundleID.lowercased().hasPrefix("com.apple.") || path.hasPrefix("/System/") { return L("Apps that come with macOS can’t be removed.") }
        if let own = Bundle.main.bundleIdentifier, bundleID == own || bundleID.hasPrefix(own + ".") { return L("Swivel can’t remove itself.") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") else {
            return L("Only apps in the Applications folder can be removed here.")
        }
        return nil
    }

    /// Reads the app and finds its files in ~/Library: names that are its bundle identifier (or start with it), and
    /// folders named exactly like the app (shown, never preselected). Containers are protected and never read.
    static func inspect(_ app: URL, home: URL,
                        installedCopies: (String) -> [URL] = { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }) -> App? {
        guard let bundle = Bundle(url: app), let id = bundle.bundleIdentifier, DoctorCommand.isPlain(id),
              let identity = try? FileIdentity.read(app) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? app.deletingPathExtension().lastPathComponent
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var leftovers: [Leftover] = []
        let lowerID = id.lowercased(), lowerName = name.lowercased()
        let realHome = (try? DoctorTrash.realHome(home)) ?? home
        for place in places {
            let folder = realHome.appendingPathComponent(place.path, isDirectory: true)
            guard !DoctorPrivacy.isProtected(folder, home: realHome),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for entry in names {
                let lower = entry.lowercased()
                // Exactly the identifier (with a file extension such as .plist, .savedState or .binarycookies) is the
                // app's own. A longer identifier may be another app (com.google.Chrome.canary): shown, not selected,
                // and left out when that app is installed.
                let stem = ["plist", "savedstate", "binarycookies"].contains((lower as NSString).pathExtension)
                    ? (lower as NSString).deletingPathExtension : lower
                let exact = stem == lowerID
                let longer = !exact && stem.hasPrefix(lowerID + ".")
                if longer, otherAppInstalled(stem, longerThan: lowerID) { continue }
                let byName = !exact && !longer && lower == lowerName && lowerName.count >= 4 && !sharedNames.contains(lowerName)
                    && ["Library/Application Support", "Library/Caches", "Library/Logs"].contains(place.path)
                guard exact || longer || byName else { continue }
                if place.path == "Library/LaunchAgents", !lower.hasSuffix(".plist") { continue }
                let url = folder.appendingPathComponent(entry)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { continue }
                let type = info.st_mode & S_IFMT
                guard type == S_IFREG || type == S_IFDIR else { continue }
                let bytes = type == S_IFDIR ? DoctorStorage.size(of: url, home: realHome).bytes : Int64(info.st_blocks) * 512
                leftovers.append(Leftover(url: url, path: "~/" + place.path + "/" + entry, what: place.what, bytes: bytes,
                                          isFolder: type == S_IFDIR, identity: FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)),
                                          byName: byName || longer))
            }
        }
        let parts = lowerID.split(separator: ".", omittingEmptySubsequences: false)
        let own = app.resolvingSymlinksInPath().standardizedFileURL.path
        let otherCopy = installedCopies(id).contains { $0.resolvingSymlinksInPath().standardizedFileURL.path != own }
        return App(url: app, bundleID: id, name: name, version: version,
                   bytes: DoctorStorage.size(of: app, home: realHome).bytes, identity: identity,
                   refusal: refusal(bundleID: id, url: app), leftovers: leftovers.sorted { $0.bytes > $1.bytes },
                   sharedIdentifier: otherCopy || parts.count < 2 || parts.contains { $0.isEmpty })
    }

    /// True when an installed app has this bundle identifier (or one of its dotted prefixes longer than the app's).
    static func otherAppInstalled(_ identifier: String, longerThan own: String) -> Bool {
        var parts = identifier.split(separator: ".").map(String.init)
        let ownParts = own.split(separator: ".").count
        // The app's own identifier is still installed while it is inspected: only longer ones say "another app".
        while parts.count > ownParts {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) != nil { return true }
            parts.removeLast()
        }
        return false
    }

    /// A direct child of one of `places`, never Apple's own, as it was found.
    static func isAllowedLeftover(_ target: DoctorTrashTarget) -> Bool {
        guard target.mode == .item || target.mode == .folder, target.identity != nil, !target.path.contains("/../") else { return false }
        return places.contains { place in
            let prefix = "~/" + place.path + "/"
            guard target.path.hasPrefix(prefix) else { return false }
            let name = target.path.dropFirst(prefix.count)
            return !name.isEmpty && !name.contains("/") && !name.lowercased().hasPrefix("com.apple.")
                && DoctorCommand.isPlain(String(name))
        }
    }

    static func result(_ app: App?, home: URL) -> DoctorResult {
        var result = DoctorResult(section: .uninstall, severity: .info, badge: "", headline: "")
        guard let app else {
            result.headline = L("That isn’t an app Mac Doctor can read.")
            return result
        }
        let leftoverBytes = app.leftovers.reduce(Int64(0)) { $0 + $1.bytes }
        result.rows.append(DoctorRow(id: "uninstall.app", title: DoctorText.visible(app.name) + (app.version.isEmpty ? "" : " " + DoctorText.visible(app.version)),
                                     value: DoctorFormat.bytes(app.bytes),
                                     detail: DoctorFormat.path(app.url) + "\n" + DoctorText.visible(app.bundleID),
                                     severity: app.refusal == nil ? .info : .review, bytes: app.bytes, location: app.url,
                                     bundleIDs: [app.bundleID]))
        for (index, item) in app.leftovers.enumerated() {
            let target = DoctorTrashTarget(path: item.path, mode: item.isFolder ? .folder : .item, identity: item.identity, origin: .leftover)
            let unsure = item.byName || app.sharedIdentifier
            let why = item.byName ? L("Named like the app, not by its identifier: check it before selecting.")
                : app.sharedIdentifier ? L("Another copy of this app, or another app with the same identifier, may use this too: check it before selecting.")
                : L("Named after the app’s identifier.")
            result.rows.append(DoctorRow(id: "left.\(index)", title: L(item.what) + " · " + DoctorText.visible(item.url.lastPathComponent),
                                         value: DoctorFormat.bytes(item.bytes), detail: DoctorFormat.path(item.url) + "\n" + why,
                                         severity: unsure ? .review : .info, bytes: item.bytes, location: item.url,
                                         trash: DoctorTrash.isAllowed(target) ? target : nil, level: 1))
        }
        result.badge = DoctorFormat.bytes(app.bytes + leftoverBytes)
        if let refusal = app.refusal {
            result.severity = .review
            result.headline = refusal
        } else {
            result.headline = L("%@ uses %@, and %d related items in your Library use %@.", DoctorText.visible(app.name),
                                DoctorFormat.bytes(app.bytes), app.leftovers.count, DoctorFormat.bytes(leftoverBytes))
            result.notes.append(L("Uninstall moves the app and the selected items to the Trash; items found by identifier are selected for you. Nothing is deleted until you empty the Trash, and Undo Last Move puts everything back."))
            if app.sharedIdentifier {
                result.notes.append(L("Another copy of this app is installed, or its identifier is unusual, so nothing is selected for you."))
            }
        }
        result.notes.append(L("The app’s sandbox container, if it has one, is protected by macOS and isn’t read. Remove it in System Settings → General → Storage → Applications."))
        result.report.append(L("App to uninstall: %@ with %d related items using %@.", DoctorFormat.bytes(app.bytes), app.leftovers.count,
                               DoctorFormat.bytes(leftoverBytes)))
        return result
    }

    /// Moves the app bundle itself to the Trash, if it is still the one inspected and not running. Blocking.
    static func trashApp(_ app: URL, identity: FileIdentity, bundleID: String, move: DoctorTrash.Mover) throws -> DoctorTrashReceipt.Moved {
        var info = stat()
        guard lstat(app.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              FileIdentity(device: info.st_dev, inode: UInt64(info.st_ino)) == identity,
              Bundle(url: app)?.bundleIdentifier == bundleID, refusal(bundleID: bundleID, url: app) == nil else {
            throw ToolError(L("Files changed since the check. Run the check again."))
        }
        let trashed: URL
        do { trashed = try move(app) } catch {
            throw ToolError(L("macOS didn’t let Swivel move the app. Drag it to the Trash in Finder; it may ask for your password."))
        }
        guard (try? FileIdentity.read(trashed)) == identity else { throw ToolError(L("%@ couldn’t be confirmed in the Trash.", DoctorTrash.displayPath(app))) }
        return .init(original: app, trashed: trashed, identity: identity, parents: [], children: [])
    }
}

// MARK: - Similar files

/// Files that are nearly the same: photos by a 64-bit difference hash of a small greyscale thumbnail (how alike they
/// look), text by the share of lines they have in common. Original implementations; each group is measured against
/// its largest file. Blocking; checks for cancellation.
enum DoctorSimilar {
    enum Kind: Sendable { case photo, text }

    struct Group: Sendable {
        var kind: Kind
        /// The largest first.
        var copies: [DoctorDuplicates.Copy]
        /// How alike each copy is to the first, 0…1 (the first is 1).
        var similarity: [Double]
    }

    static let photoExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "bmp"]
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm", "srt",
                                              "swift", "py", "js", "ts", "java", "kt", "c", "h", "cpp", "go", "rs", "rb", "sh"]
    static let photoThreshold = 0.9   // at most 6 of 64 bits differ
    static let textThreshold = 0.8
    static let maxPhotos = 20_000, maxTexts = 4_000, maxGroups = 150

    static func kind(of path: String, size: Int64) -> Kind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if photoExtensions.contains(ext), size >= 10_000 { return .photo }
        if textExtensions.contains(ext), (1_000...2_000_000).contains(size) { return .text }
        return nil
    }

    static func groups(_ candidates: [DoctorDuplicates.Copy]) -> [Group] {
        var photos: [(DoctorDuplicates.Copy, UInt64)] = []
        var texts: [(DoctorDuplicates.Copy, Set<Int>, String)] = []
        for copy in candidates {
            if Task.isCancelled { return [] }
            switch kind(of: copy.url.path, size: copy.bytes) ?? (photoExtensions.contains(copy.url.pathExtension.lowercased()) ? .photo : .text) {
            case .photo:
                if photos.count < maxPhotos, let hash = photoHash(copy.url) { photos.append((copy, hash)) }
            case .text:
                if texts.count < maxTexts, let lines = textLines(copy.url), lines.count >= 5 {
                    texts.append((copy, lines, copy.url.pathExtension.lowercased()))
                }
            }
        }
        var out: [Group] = []
        // Photos: compare every pair of hashes; 20 000 photos is 200 million cheap bit counts at most.
        out += cluster(photos.count, kind: .photo, copy: { photos[$0].0 }) { a, b in
            1 - Double((photos[a].1 ^ photos[b].1).nonzeroBitCount) / 64
        }
        out += cluster(texts.count, kind: .text, copy: { texts[$0].0 }) { a, b in
            guard texts[a].2 == texts[b].2 else { return 0 }
            let x = texts[a].1, y = texts[b].1
            // Sizes far apart can't share 80% of their lines.
            guard Double(min(x.count, y.count)) / Double(max(x.count, y.count)) >= textThreshold else { return 0 }
            return Double(x.intersection(y).count) / Double(x.union(y).count)
        }
        out.sort { $0.copies.dropFirst().reduce(0) { $0 + $1.bytes } > $1.copies.dropFirst().reduce(0) { $0 + $1.bytes } }
        return Array(out.prefix(maxGroups))
    }

    /// Joins files that are alike enough into groups, then measures each against the group's largest file.
    private static func cluster(_ count: Int, kind: Kind, copy: (Int) -> DoctorDuplicates.Copy,
                                similarity: (Int, Int) -> Double) -> [Group] {
        guard count > 1 else { return [] }
        let threshold = kind == .photo ? photoThreshold : textThreshold
        var parent = Array(0..<count)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for a in 0..<count {
            if Task.isCancelled { return [] }
            for b in (a + 1)..<count where similarity(a, b) >= threshold {
                let ra = root(a), rb = root(b)
                if ra != rb { parent[rb] = ra }
            }
        }
        var members: [Int: [Int]] = [:]
        for i in 0..<count { members[root(i), default: []].append(i) }
        return members.values.filter { $0.count > 1 }.map { indices in
            let sorted = indices.sorted { copy($0).bytes > copy($1).bytes }
            let first = sorted[0]
            return Group(kind: kind, copies: sorted.map(copy), similarity: sorted.map { $0 == first ? 1 : similarity(first, $0) })
        }
    }

    /// A difference hash: a 9×8 greyscale thumbnail, one bit per neighbouring pair that gets brighter. Plain images
    /// (almost no edges) give no useful hash and are left out.
    static func photoHash(_ url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= 100_000_000,  // no full decode of a huge picture
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(thumb, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard drawn else { return nil }
        var hash: UInt64 = 0
        var edges = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let left = Int(pixels[y * 9 + x]), right = Int(pixels[y * 9 + x + 1])
                hash <<= 1
                if left < right { hash |= 1 }
                if abs(left - right) > 4 { edges += 1 }
            }
        }
        return edges >= 8 ? hash : nil
    }

    /// The set of a text file's non-empty lines, trimmed (only valid UTF-8, read without following links).
    static func textLines(_ url: URL) -> Set<Int>? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: 2_000_001), data.count <= 2_000_000,
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = Set<Int>()
        for line in text.split(whereSeparator: \.isNewline) {
            if lines.count >= 20_000 { return nil }  // a data file, not a document: comparing it costs too much
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.insert(trimmed.hashValue) }
        }
        return lines
    }
}
