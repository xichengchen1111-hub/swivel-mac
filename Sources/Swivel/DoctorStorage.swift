import Foundation
import Darwin
import DoctorCatalog

/// Storage, caches and folder sizes. Everything here only reads sizes; moving caches to the Trash is DoctorTrash's.
enum DoctorStorage {
    struct Space: Sendable, Equatable {
        var total: Int64
        /// Free right now.
        var available: Int64
        /// Free once macOS clears purgeable space (what Finder and Storage settings show as available).
        var important: Int64
        var purgeable: Int64 { max(0, important - available) }
    }

    /// A fresh URL each time: resource values are cached per URL instance.
    static func space(of url: URL) -> Space? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                               .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return Space(total: Int64(total), available: Int64(available), important: max(important, Int64(available)))
    }

    struct Size: Sendable, Equatable {
        var bytes: Int64 = 0
        var items = 0
        /// Folders or files that could not be read (protected by macOS, or no permission).
        var unreadable = 0
        /// Protected places inside the folder that were skipped (see DoctorPrivacy).
        var skipped = 0
        /// Files kept in iCloud or another cloud service and not downloaded to this Mac.
        var inCloud = 0
        var cancelled = false
    }

    /// Space used on disk by everything inside `folder`: allocated blocks, each hard-linked file once. Symbolic
    /// links are never followed, the walk stays on the folder's volume, protected places inside it are skipped, and
    /// files that live in the cloud are counted without being downloaded. Blocking; checks for cancellation.
    static func size(of folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     maxItems: Int = 20_000_000) -> Size {
        var size = Size()
        // Reading a cloud placeholder's folder would download it: turn that off for this thread, then restore it.
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if previous >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) } }
        guard let path = strdup(folder.path) else { return size }
        defer { free(path) }
        var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            size.unreadable = 1
            return size
        }
        defer { fts_close(fts) }
        var linked = Set<UInt64>()
        while let entry = fts_read(fts) {
            if size.items % 4096 == 0, Task.isCancelled || size.items >= maxItems {
                size.cancelled = true
                break
            }
            switch Int32(entry.pointee.fts_info) {
            case FTS_DNR, FTS_ERR, FTS_NS:
                size.unreadable += 1
            case FTS_DP:
                continue  // a folder seen again on the way back up
            case FTS_D:
                let url = URL(fileURLWithPath: String(cString: entry.pointee.fts_path))
                if entry.pointee.fts_level > 0, DoctorPrivacy.shouldSkip(url, below: folder, home: home) {
                    fts_set(fts, entry, FTS_SKIP)
                    size.skipped += 1
                    continue
                }
                fallthrough
            default:
                guard let info = entry.pointee.fts_statp?.pointee else { continue }
                size.items += 1
                if info.st_flags & UInt32(SF_DATALESS) != 0 { size.inCloud += 1; continue }
                if info.st_mode & S_IFMT != S_IFDIR, info.st_nlink > 1, !linked.insert(UInt64(info.st_ino)).inserted {
                    continue
                }
                size.bytes += Int64(info.st_blocks) * 512
            }
        }
        return size
    }

    // MARK: Storage

    static func checkStorage(_ env: DoctorEnvironment) async -> DoctorResult {
        var result = DoctorResult(section: .storage, severity: .info, badge: "", headline: "")
        result.panes = [.storage, .timeMachine]
        if let space = env.volume(URL(fileURLWithPath: "/")) {
            let free = space.important
            let share = space.total > 0 ? Double(free) / Double(space.total) : 1
            result.severity = free < 5_000_000_000 ? .problem : (free < 20_000_000_000 || share < 0.1 ? .review : .ok)
            result.badge = L("%@ free", DoctorFormat.bytes(free))
            result.headline = L("%@ of %@ is available on the startup disk.", DoctorFormat.bytes(free),
                                DoctorFormat.bytes(space.total))
            result.rows.append(DoctorRow(id: "space.free", title: L("Available now"), value: DoctorFormat.bytes(space.available),
                                         detail: L("Free space before macOS clears anything."), severity: .info))
            if space.purgeable > 0 {
                result.rows.append(DoctorRow(id: "space.purgeable", title: L("Purgeable"),
                                             value: DoctorFormat.bytes(space.purgeable),
                                             detail: L("Space macOS frees by itself when an app needs it: iCloud copies, caches and snapshots."),
                                             severity: .info))
            }
            result.report.append(L("Startup disk: %@ in all, %@ available including %@ that macOS can free by itself.",
                                   DoctorFormat.bytes(space.total), DoctorFormat.bytes(space.important), DoctorFormat.bytes(space.purgeable)))
        } else {
            result.headline = L("Mac Doctor couldn’t read the startup disk’s capacity.")
        }

        let command = DoctorCommand.localSnapshots
        result.ran.append(command.displayString)
        if let output = try? await env.run(command), output.status == 0 {
            let names = DoctorParse.snapshots(output.text)
            for name in names {
                let date = DoctorParse.snapshotDate(name)
                let timeMachine = name.hasPrefix("com.apple.TimeMachine.")
                let shown = DoctorText.visible(name)
                result.rows.append(DoctorRow(
                    id: "snapshot." + shown,
                    title: timeMachine ? L("Time Machine snapshot") : L("Snapshot made by another app"),
                    value: date.map(DoctorFormat.date) ?? "", detail: shown, severity: .info))
            }
            if names.isEmpty {
                result.notes.append(L("There are no local snapshots on the startup disk."))
            } else {
                result.notes.append(L("Local snapshots let Time Machine and backup apps restore recent versions. Their space counts as “System Data” and macOS deletes them by itself when space runs low."))
                // Hourly snapshots kept for a day are normal: they only matter when space is short.
                result.adminCommands.append(.deleteLocalSnapshots)
            }
            result.report.append(L("Local snapshots: %d (%d from Time Machine).", names.count,
                                   names.filter { $0.hasPrefix("com.apple.TimeMachine.") }.count))
        } else {
            result.notes.append(L("Local snapshots couldn’t be listed."))
        }

        // Large places Mac Doctor shows but never cleans: rebuilding them is not automatic.
        for place in reviewOnlyPlaces {
            let expected = env.home.appendingPathComponent(String(place.path.dropFirst(2)))
            if DoctorPrivacy.isProtected(expected, home: env.home) {
                // macOS guards it (iPhone backups): say where to look instead of reading it.
                result.rows.append(DoctorRow(id: "place." + place.id, title: L(place.name), value: L("Not measured"),
                                             detail: L(place.unreadable), severity: .info))
                continue
            }
            guard let url = try? DoctorTrash.resolve(place.path, home: env.home) else { continue }
            let size = await scan(url, home: env.home)
            if size.cancelled { break }
            if size.bytes == 0, size.unreadable > 0 {
                result.rows.append(DoctorRow(id: "place." + place.id, title: L(place.name), value: L("Not readable"),
                                             detail: L(place.unreadable), severity: .info, location: url))
            } else if size.bytes >= 100_000_000 {
                result.rows.append(DoctorRow(id: "place." + place.id, title: L(place.name),
                                             value: DoctorFormat.bytes(size.bytes), detail: L(place.detail),
                                             severity: size.bytes >= 10_000_000_000 ? .review : .info, bytes: size.bytes,
                                             location: url))
                result.report.append(L("%@ uses %@.", L(place.name), DoctorFormat.bytes(size.bytes)))
            }
        }
        result.notes.append(L("“System Data” in Storage settings is everything macOS can’t put in another category: snapshots, caches, logs, virtual memory and app support files. It shrinks by itself as macOS reclaims space."))
        result.notes.append(L("Space often hides in: WeChat and other chat apps (use the app’s own storage manager, e.g. WeChat → Settings → General → Storage), the Photos library (Photos → Settings → iCloud → Optimize Mac Storage), iCloud Drive (Storage settings → Optimize) and the Trash, which frees space only when emptied."))
        return result
    }

    struct Place: Sendable {
        let id: String, name: String, path: String, detail: String, unreadable: String
    }

    static let reviewOnlyPlaces: [Place] = [
        Place(id: "simulators", name: "Simulator devices", path: "~/Library/Developer/CoreSimulator/Devices",
              detail: "iPhone and iPad simulators with their apps and data. Remove unused ones in Xcode → Settings → Components, or with “xcrun simctl delete unavailable”.",
              unreadable: "macOS didn’t let Mac Doctor measure this folder."),
        Place(id: "archives", name: "Xcode archives", path: "~/Library/Developer/Xcode/Archives",
              detail: "Builds you archived for distribution, with their debug symbols. They can’t be rebuilt exactly; remove old ones in Xcode’s Organizer.",
              unreadable: "macOS didn’t let Mac Doctor measure this folder."),
        Place(id: "ios-backups", name: "iPhone and iPad backups", path: "~/Library/Application Support/MobileSync/Backup",
              detail: "Device backups made with Finder. Manage them in Finder: select the device, then Manage Backups.",
              unreadable: "macOS protects this folder. See its size in Storage settings, or in Finder under the device’s Manage Backups."),
    ]

    /// Runs a size scan off the main thread; cancelling the calling task stops it.
    static func scan(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> Size {
        let task = Task.detached(priority: .utility) { size(of: url, home: home) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    // MARK: Caches

    /// Apps that must be quit before a cache is moved to the Trash, by catalogue id.
    static let owners: [String: [String]] = [
        "chrome-cache": ["com.google.Chrome"],
        "firefox-cache": ["org.mozilla.firefox"],
        "safari-cache": ["com.apple.Safari"],
        "edge-cache": ["com.microsoft.edgemac"],
        "brave-cache": ["com.brave.Browser"],
        "arc-cache": ["company.thebrowser.Browser"],
        "discord-web-cache": ["com.hnc.Discord"], "discord-code-cache": ["com.hnc.Discord"],
        "slack-web-cache": ["com.tinyspeck.slackmacgap"], "slack-code-cache": ["com.tinyspeck.slackmacgap"],
        "spotify-cache": ["com.spotify.client"],
        "steam-web-cache": ["com.valvesoftware.steam"], "steam-legacy-web-cache": ["com.valvesoftware.steam"],
        "raycast-web-cache": ["com.raycast.macos"],
        "obsidian-web-cache": ["md.obsidian"], "obsidian-code-cache": ["md.obsidian"],
        "notion-web-cache": ["notion.id"], "notion-code-cache": ["notion.id"],
        "github-desktop-web-cache": ["com.github.GitHubClient"],
        "codex-web-cache": ["com.openai.codex"], "codex-browser-cache": ["com.openai.codex"],
        "xcode-derived-data": ["com.apple.dt.Xcode"], "xcode-previews": ["com.apple.dt.Xcode"],
        "xcode-device-support": ["com.apple.dt.Xcode"],
        "coresimulator-caches": ["com.apple.dt.Xcode", "com.apple.iphonesimulator"],
        "coresimulator-logs": ["com.apple.iphonesimulator"],
        "vscode-cache": ["com.microsoft.VSCode"], "vscode-cached-data": ["com.microsoft.VSCode"],
        "vscode-extension-vsix-cache": ["com.microsoft.VSCode"], "vscode-chromium-cache": ["com.microsoft.VSCode"],
    ]

    /// Swivel's wording where ClearDisk's text speaks about ClearDisk itself (see ThirdParty/ClearDisk/UPSTREAM.md).
    static let displayNotes: [String: String] = [
        "raycast-web-cache": "Quit Raycast first. Mac Doctor never touches the Clipboard folder next to it.",
    ]

    /// Caches smaller than this aren't worth a row.
    static let smallestCache: Int64 = 1_000_000

    static func checkCaches(_ env: DoctorEnvironment, catalogue: [CacheEntry] = ClearDiskCatalog.entries) async -> DoctorResult {
        var result = DoctorResult(section: .caches, severity: .ok, badge: "", headline: "")
        var total: Int64 = 0
        var skipped = 0
        for entry in catalogue {
            if Task.isCancelled { break }
            // Protected caches (Safari's) can't be read without Full Disk Access: never try.
            let expected = env.home.appendingPathComponent(String(entry.path.dropFirst(2)))
            if DoctorPrivacy.isProtected(expected, home: env.home) { continue }
            guard let url = try? DoctorTrash.resolve(entry.path, home: env.home) else {
                // Missing, or reached through a link: a linked cache is never cleaned.
                if isLink(entry.path, home: env.home) { skipped += 1 }
                continue
            }
            let size = await scan(url, home: env.home)
            guard size.bytes >= smallestCache else { continue }
            total += size.bytes
            var detail = L(entry.description)
            if let removes = entry.removes { detail += "\n" + L("Removes: %@", L(removes)) }
            if let keeps = entry.keeps { detail += "\n" + L("Keeps: %@", L(keeps)) }
            if let note = displayNotes[entry.id] ?? entry.note { detail += "\n" + L(note) }
            result.rows.append(DoctorRow(id: "cache." + entry.id, title: L(entry.name), value: DoctorFormat.bytes(size.bytes),
                                         detail: detail, severity: size.bytes >= 1_000_000_000 ? .review : .info,
                                         bytes: size.bytes, location: url,
                                         trash: DoctorTrashTarget(path: entry.path, mode: .contents),
                                         bundleIDs: owners[entry.id] ?? []))
        }
        result.rows.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        result.badge = DoctorFormat.bytes(total)
        if result.rows.isEmpty {
            result.headline = L("No large caches were found.")
        } else {
            result.severity = total >= 5_000_000_000 ? .review : .info
            result.headline = L("%d caches use %@. They rebuild or download again when needed.", result.rows.count,
                                DoctorFormat.bytes(total))
            result.notes.append(L("Select caches and choose Move to Trash. Quit the app that owns a cache first. Items stay in the Trash until you empty it, and Put Back restores them."))
        }
        if skipped > 0 { result.notes.append(L("%d caches are links to other places and are skipped.", skipped)) }
        result.notes.append(L("Space returns when you empty the Trash. If Time Machine keeps local snapshots, some of it returns only when those expire, within about a day."))
        result.notes.append(L("Command-line tools that use a cache (Gradle daemons, swift build, cargo) aren’t apps Mac Doctor can see: stop them first."))
        result.notes.append(L("Cache list from ClearDisk (MIT License)."))
        result.report.append(L("Caches Mac Doctor can move to the Trash: %d, together %@.", result.rows.count, DoctorFormat.bytes(total)))
        result.names += result.rows.prefix(10).map { "\(DoctorText.reportName(catalogueName($0.id, catalogue))): \($0.value)" }
        return result
    }

    /// The English catalogue name for a row, for the assistant report.
    private static func catalogueName(_ rowID: String, _ catalogue: [CacheEntry]) -> String {
        catalogue.first { "cache." + $0.id == rowID }?.name ?? rowID
    }

    private static func isLink(_ path: String, home: URL) -> Bool {
        guard path.hasPrefix("~/"), let base = try? DoctorTrash.realHome(home) else { return false }
        var url = base
        for part in path.dropFirst(2).split(separator: "/") {
            url.appendPathComponent(String(part))
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            if info.st_mode & S_IFMT == S_IFLNK { return true }
        }
        return false
    }

    // MARK: Folders

    /// Sizes of user-chosen folders and their largest items. Names stay on the Mac: the assistant report has none.
    static func checkFolders(_ folders: [URL]) async -> DoctorResult {
        var result = DoctorResult(section: .folders, severity: .info, badge: "", headline: "")
        guard !folders.isEmpty else {
            result.headline = L("Choose a folder to see what takes up its space.")
            return result
        }
        var grand: Int64 = 0
        let home = FileManager.default.homeDirectoryForCurrentUser
        for (number, folder) in folders.enumerated() {
            if Task.isCancelled { break }
            // One walk per folder gives both the list and the space map.
            let map = await Task.detached(priority: .utility) { DoctorSpaceMap.build(folder, home: home) }.value
            if Task.isCancelled { break }
            result.maps.append(map.root)
            let total = map.root.bytes
            grand += total
            result.rows.append(DoctorRow(id: "folder.\(number)", title: DoctorText.visible(folder.lastPathComponent),
                                         value: DoctorFormat.bytes(total), detail: DoctorFormat.path(folder),
                                         severity: .info, bytes: total, location: folder))
            for child in map.root.children.prefix(8) where child.bytes > 0 {
                result.rows.append(DoctorRow(id: "folder.\(number).\(child.name)", title: child.name,
                                             value: DoctorFormat.bytes(child.bytes), detail: child.url.map(DoctorFormat.path) ?? "",
                                             severity: .info, bytes: child.bytes, location: child.url, level: 1))
            }
            let shown = DoctorText.visible(folder.lastPathComponent)
            let size = map.size
            if size.unreadable > 0 { result.notes.append(L("Some items in %@ couldn’t be read and aren’t counted.", shown)) }
            if size.skipped > 0 {
                result.notes.append(L("%d protected places in %@ (such as Documents, Mail or other apps’ data) were skipped, so macOS doesn’t ask for access.", size.skipped, shown))
            }
            if size.inCloud > 0 { result.notes.append(L("%d items in %@ are in the cloud, not on this Mac, and use no space here.", size.inCloud, shown)) }
            if size.cancelled { result.notes.append(L("The search stopped before it finished.")) }
            result.report.append(L("Chosen folder %d: %@ in %d items; largest item %@.", number + 1, DoctorFormat.bytes(total),
                                   map.root.children.count, DoctorFormat.bytes(map.root.children.first?.bytes ?? 0)))
        }
        result.badge = DoctorFormat.bytes(grand)
        result.headline = L("The chosen folders use %@. Click a box in the map to look inside it; select an item and choose Show in Finder to decide what to keep.",
                            DoctorFormat.bytes(grand))
        return result
    }
}
