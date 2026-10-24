import AppKit
import Darwin
import DoctorCatalog

/// Runs Mac Doctor's checks and keeps their results in memory while Swivel is open (never on disk), so the window
/// can be closed and reopened without checking again. Results are written in the language they were checked in, so
/// a language change clears them. Checks start only when the user asks.
@MainActor
final class DoctorCenter {
    static let shared = DoctorCenter()
    /// Posted whenever a result, a running check or the chosen folders change. Not Prefs.changed: that would rebuild
    /// the ◎ menu and every settings page on each step.
    static let changed = Notification.Name("SwivelDoctorChanged")
    /// Posted once when "Check This Mac" has finished every section.
    static let finishedAll = Notification.Name("SwivelDoctorFinishedAll")

    var environment = DoctorEnvironment.live
    private var stored: [DoctorSection: DoctorResult] = [:]
    /// The latest speed test, kept apart from the DNS result so either can be checked again on its own.
    private var speed: DoctorNetwork.SpeedOutcome?
    /// The latest large-file search, shown under Storage. Kept apart so "Check This Mac" never repeats it.
    private var largeFiles: DoctorLargeFiles.Outcome?
    private var language = Language.resolved
    /// Every section's latest result; Network shows the DNS check with the latest speed test on top.
    var results: [DoctorSection: DoctorResult] {
        var all = stored
        if let speed { all[.network] = DoctorNetwork.withSpeed(stored[.network], speed) }
        if let largeFiles { all[.storage] = DoctorLargeFiles.merge(stored[.storage], largeFiles, home: environment.home) }
        return all
    }
    private(set) var running: Set<DoctorSection> = []
    private(set) var testingSpeed = false
    private(set) var searchingFiles = false
    private var filesTask: Task<Void, Never>?
    /// Chosen in this session only; nothing about them is saved.
    private(set) var folders: [URL] = []
    private(set) var duplicateFolders: [URL] = []
    private(set) var projectFolders: [URL] = []
    /// The app chosen on Uninstall Apps, and what was found for it.
    private(set) var uninstallApp: URL?
    private var uninstallInfo: DoctorUninstall.App?
    /// The app App Check last looked at, also for this session only.
    private(set) var app: URL?
    /// One receipt per Move to Trash, newest last, until Swivel quits.
    private(set) var receipts: [DoctorTrashReceipt] = []
    private var tasks: [DoctorSection: Task<Void, Never>] = [:]
    private var speedTask: Task<Void, Never>?
    private var checkingAll: Set<DoctorSection> = []
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DoctorCenter.shared.preferencesChanged() }
        }
    }

    var isBusy: Bool { !running.isEmpty || testingSpeed || searchingFiles }

    private func preferencesChanged() {
        if !Feature.doctor.isOn { cancelAll() }
        // Results are written in the language they were checked in: a new language starts fresh.
        if Language.resolved != language {
            language = Language.resolved
            cancelAll()
            stored = [:]
            speed = nil
            largeFiles = nil
            post()
        }
    }

    // MARK: Running

    /// Every check that reads only this Mac and needs nothing chosen: not App Check, Folder Sizes or Test Speed.
    func runAll() {
        let sections = DoctorSection.allCases.filter(\.runsWithAll)
        checkingAll = Set(sections)
        for section in sections { run(section) }
    }

    /// Checks an app the user picked. Returns false when it isn't an app bundle with a plain path.
    @discardableResult
    func checkApp(_ url: URL) -> Bool {
        guard let app = DoctorCommand.validatedApp(url) else { return false }
        self.app = app
        run(.app)
        return true
    }

    func run(_ section: DoctorSection) {
        guard Feature.doctor.isOn, section != .summary else { return }
        tasks[section]?.cancel()
        running.insert(section)
        post()
        let env = environment
        let folders = folders
        let duplicateFolders = duplicateFolders
        let projectFolders = projectFolders
        let uninstallApp = uninstallApp
        let app = app
        tasks[section] = Task { [weak self] in
            let result: DoctorResult? = switch section {
            case .summary: nil
            case .storage: await DoctorStorage.checkStorage(env)
            case .caches: await DoctorStorage.checkCaches(env)
            case .folders: await DoctorStorage.checkFolders(folders)
            case .duplicates:
                await Task.detached(priority: .utility) {
                    DoctorDuplicates.result(DoctorDuplicates.find(duplicateFolders, home: env.home), roots: duplicateFolders, home: env.home)
                }.value
            case .projects:
                await Task.detached(priority: .utility) {
                    let found = DoctorProjects.find(projectFolders, home: env.home)
                    return DoctorProjects.result(found.found, cancelled: found.cancelled, home: env.home)
                }.value
            case .uninstall: await self?.inspectUninstall(uninstallApp, home: env.home)
            case .performance: await Self.performance(env)
            case .power: await Self.power()
            case .network: await DoctorNetwork.check(dns: try? env.run(.dnsConfiguration), proxy: try? env.run(.proxySettings))
            case .drives: await Self.drives(env)
            case .background: await Self.background(env)
            case .app: if let app { await Self.appCheck(app, env: env) } else { nil }
            }
            guard let self, !Task.isCancelled else { return }
            if let result { stored[section] = result }
            running.remove(section)
            tasks[section] = nil
            finishedOne(section)
            post()
        }
    }

    private func finishedOne(_ section: DoctorSection) {
        guard checkingAll.remove(section) != nil, checkingAll.isEmpty else { return }
        // One sound for the whole check, not one per section.
        Feedback.done()
        NotificationCenter.default.post(name: Self.finishedAll, object: nil)
    }

    func cancel(_ section: DoctorSection) {
        tasks[section]?.cancel()
        tasks[section] = nil
        running.remove(section)
        checkingAll.remove(section)
        post()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        running = []
        checkingAll = []
        speedTask?.cancel()
        speedTask = nil
        testingSpeed = false
        filesTask?.cancel()
        filesTask = nil
        searchingFiles = false
        post()
    }

    // MARK: Large files

    /// Searches Downloads, Desktop and Documents for large files and installers. Only from its own button: macOS may
    /// ask the user to allow access to these folders. Checks Storage too when it hasn't run yet.
    func searchLargeFiles() {
        guard Feature.doctor.isOn, !searchingFiles else { return }
        searchingFiles = true
        if stored[.storage] == nil, !running.contains(.storage) { run(.storage) }
        post()
        let home = environment.home
        filesTask = Task { [weak self] in
            let outcome = await DoctorLargeFiles.scanDetached(home: home)
            guard let self, !Task.isCancelled else { return }
            largeFiles = outcome
            searchingFiles = false
            filesTask = nil
            Feedback.done()
            post()
        }
    }

    func stopFileSearch() {
        filesTask?.cancel()
        filesTask = nil
        searchingFiles = false
        post()
    }

    /// Asks the apps in these rows to quit, as their own Quit command would; checks memory again a moment later.
    func quitApps(_ rows: [DoctorRow]) -> (asked: [String], skipped: [String]) {
        guard Feature.doctor.isOn else { return ([], []) }
        let outcome = DoctorApps.quit(rows.compactMap(\.quit))
        if !outcome.asked.isEmpty {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, Feature.doctor.isOn else { return }
                run(.performance)
            }
        }
        return outcome
    }

    /// Apple's network quality test: about 20 seconds of test traffic to Apple's servers.
    func testSpeed() {
        guard Feature.doctor.isOn, !testingSpeed else { return }
        testingSpeed = true
        post()
        let env = environment
        speedTask = Task { [weak self] in
            let output = try? await env.run(.networkQuality)
            guard let self, !Task.isCancelled else { return }
            speed = DoctorNetwork.SpeedOutcome(output)
            testingSpeed = false
            speedTask = nil
            post()
        }
    }

    func stopSpeedTest() {
        speedTask?.cancel()
        speedTask = nil
        testingSpeed = false
        post()
    }

    // MARK: Folders

    func addFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        guard !folders.contains(folder) else { return }
        folders.append(folder)
        run(.folders)
    }

    /// Adds folders to Duplicate Files or Project Builds and searches them.
    func addFolders(_ urls: [URL], to section: DoctorSection) {
        let picked = urls.map(\.standardizedFileURL)
        switch section {
        case .duplicates: duplicateFolders += picked.filter { !duplicateFolders.contains($0) }
        case .projects: projectFolders += picked.filter { !projectFolders.contains($0) }
        default: return
        }
        run(section)
    }

    /// The folders where duplicates usually are, as real folders on the home volume.
    static let commonFolders = ["Downloads", "Desktop", "Documents", "Pictures", "Movies", "Music"]

    /// Searches the common folders for duplicate and similar files, replacing the chosen folders.
    func scanCommonFolders() {
        duplicateFolders = Self.commonFolders.compactMap { DoctorLargeFiles.folder($0, home: environment.home) }
        run(.duplicates)
    }

    func clearFolders(_ section: DoctorSection) {
        switch section {
        case .duplicates: duplicateFolders = []
        case .projects: projectFolders = []
        case .folders: folders = []
        default: return
        }
        cancel(section)
        stored[section] = nil
        post()
    }

    /// The app to uninstall. Returns false when it isn't an app bundle with a plain path.
    @discardableResult
    func chooseUninstall(_ url: URL) -> Bool {
        guard let app = DoctorCommand.validatedApp(url) else { return false }
        uninstallApp = app
        run(.uninstall)
        return true
    }

    private func inspectUninstall(_ app: URL?, home: URL) async -> DoctorResult? {
        guard let app else { return nil }
        let info = await Task.detached(priority: .userInitiated) { DoctorUninstall.inspect(app, home: home) }.value
        if !Task.isCancelled { uninstallInfo = info }
        return DoctorUninstall.result(info, home: home)
    }

    func removeFolders() {
        folders = []
        cancel(.folders)
        stored[.folders] = nil
        post()
    }

    // MARK: Fixes

    /// Plans and moves the given rows to the Trash. Rows are re-checked here: only catalogue caches and your own
    /// leftover launch agents can be moved, and never while their app runs. Blocking file work runs off the main thread.
    func moveToTrash(_ rows: [DoctorRow]) async throws -> DoctorTrashReceipt {
        try await move(rows, app: nil)
    }

    /// Moves the inspected app and the chosen leftover rows to the Trash, as one step Undo can reverse.
    func uninstall(_ rows: [DoctorRow]) async throws -> DoctorTrashReceipt {
        guard let app = uninstallApp, let inspected = uninstallInfo, inspected.url == app, inspected.refusal == nil else {
            throw ToolError(L("Choose the app again."))
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: inspected.bundleID)
        guard running.isEmpty else { throw ToolError(L("Quit %@ first", inspected.name)) }
        // A leftover named after a longer identifier may belong to another app that is running (Chrome Canary).
        let busy = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier?.lowercased() else { return false }
            return rows.contains { row in
                let name = (row.location?.lastPathComponent.lowercased() ?? "")
                return name == id || name.hasPrefix(id + ".")
            }
        }
        guard busy.isEmpty else { throw ToolError(L("Quit %@ first", busy.compactMap(\.localizedName).joined(separator: ", "))) }
        let receipt = try await move(rows.filter { $0.trash?.origin == .leftover }, app: inspected)
        if receipt.moved.contains(where: { $0.original == app }) {
            uninstallApp = nil
            uninstallInfo = nil
            stored[.uninstall] = nil
        }
        post()
        return receipt
    }

    /// Plans and moves rows to the Trash. Rows are re-checked here, each by the rule of the check that offered it:
    /// only catalogue caches, your own leftover launch agents, files the searches found (still the same files),
    /// rebuildable project folders whose project file is still there, extra copies whose kept copy still has the
    /// same content, and a removed app's own Library items. Never while an owning app runs. Off the main thread.
    private func move(_ rows: [DoctorRow], app: DoctorUninstall.App?) async throws -> DoctorTrashReceipt {
        guard Feature.doctor.isOn else { throw ToolError(L("This feature is turned off.")) }
        let owners = runningOwners(rows.filter { $0.trash?.origin == .standard })
        guard owners.isEmpty else { throw ToolError(L("Quit %@ first", owners.joined(separator: ", "))) }
        let env = environment
        let catalogue = ClearDiskCatalog.entries
        let keepers = try duplicateKeepers(rows)
        let jobs = rows.compactMap { row -> (DoctorTrashTarget, String, URL?)? in
            guard let target = row.trash, DoctorTrash.isAllowed(target, catalogue: catalogue) else { return nil }
            let name = catalogue.first { $0.path == target.path }?.name ?? row.title
            return (target, name, row.group.flatMap { keepers[$0] })
        }
        guard !jobs.isEmpty || app != nil else { throw ToolError(L("Mac Doctor can’t move these items.")) }
        let receipt = try await Images.detached { () -> DoctorTrashReceipt in DoctorWalk.withoutDownloads {
            var total = DoctorTrashReceipt()
            // Each kept copy is read once per move, however many of its copies go; nil when it can't be read.
            var keptDigests: [URL: String?] = [:]
            func digest(of keeper: URL) -> String? {
                if let known = keptDigests[keeper] { return known }
                let value = DoctorDuplicates.digest(keeper)
                keptDigests[keeper] = value
                return value
            }
            if let app {
                do {
                    total.moved.append(try DoctorUninstall.trashApp(app.url, identity: app.identity, bundleID: app.bundleID, move: env.trash))
                } catch {
                    // Without the app, its files stay too: they may still be needed.
                    total.failures.append(error.localizedDescription)
                    return total
                }
            }
            for (target, name, keeper) in jobs {
                do {
                    switch target.origin {
                    case .duplicate:
                        // The kept copy must still be there with the same content as the one being moved.
                        let file = try DoctorTrash.resolve(target.path, home: env.home, expect: S_IFREG)
                        guard let keeper, keeper.standardizedFileURL != file.standardizedFileURL,
                              (try? FileIdentity.read(keeper)) != target.identity,
                              let kept = digest(of: keeper), kept == DoctorDuplicates.digest(file) else {
                            throw ToolError(L("%@ no longer has an identical copy to keep, so it was left in place.", DoctorTrash.displayPath(file)))
                        }
                    case .build:
                        let folder = try DoctorTrash.resolve(target.path, home: env.home)
                        guard DoctorProjects.kind(of: folder) != nil else {
                            throw ToolError(L("Files changed since the check. Run the check again."))
                        }
                    case .standard where target.mode == .item && !DoctorLargeFiles.isAllowed(target):
                        // Still the same file, and still a leftover: a reinstalled app's agent is never moved.
                        let file = try DoctorTrash.resolve(target.path, home: env.home, expect: S_IFREG)
                        let item = DoctorBackground.read(file, place: .userAgents, home: env.home)
                        guard item.kind == .regular, item.status == .missing else {
                            throw ToolError(L("Files changed since the check. Run the check again."))
                        }
                    case .similar:
                        // Not the same content, but one file of the group must still be there.
                        var kept = stat()
                        guard let keeper, lstat(keeper.path, &kept) == 0, kept.st_mode & S_IFMT == S_IFREG else {
                            throw ToolError(L("Keep at least one copy of each file: deselect one copy of “%@”.", DoctorTrash.displayPath(URL(fileURLWithPath: target.path))))
                        }
                    case .standard, .leftover: break
                    }
                    let receipt = try DoctorTrash.execute(try DoctorTrash.plan(target, name: name, home: env.home), move: env.trash)
                    total.moved += receipt.moved
                    total.failures += receipt.failures
                } catch {
                    total.failures.append(error.localizedDescription)
                }
            }
            return total
        } }
        if !receipt.moved.isEmpty { receipts.append(receipt) }
        let moved = Set(receipt.moved.map(\.original.path))
        largeFiles?.files.removeAll { moved.contains($0.url.path) }
        for section in Set(rows.map { DoctorCenter.section(of: $0) }) {
            if [.duplicates, .projects, .uninstall].contains(section) { prune(section, moved: moved) } else { run(section) }
        }
        post()
        return receipt
    }

    /// For each group of copies being moved, one copy that stays: a copy not among `rows`, still where it was found.
    /// Refuses when every copy of a file was selected.
    private func duplicateKeepers(_ rows: [DoctorRow]) throws -> [String: URL] {
        // By path, not by row: one file can be listed in more than one group, and a file moved by this batch can never
        // be the copy that stays.
        let moving = Set(rows.compactMap { $0.trash != nil ? $0.location.map { DoctorPrivacy.location($0.path) } : nil })
        var keepers: [String: URL] = [:]
        for group in Set(rows.compactMap { [.duplicate, .similar].contains($0.trash?.origin) ? $0.group : nil }) {
            let members = (stored[.duplicates]?.rows ?? []).filter { $0.group == group && $0.level == 1 }
            guard let keep = members.first(where: { row in
                guard let url = row.location else { return false }
                return !moving.contains(DoctorPrivacy.location(url.path)) && FileManager.default.fileExists(atPath: url.path)
            })?.location else {
                throw ToolError(L("Keep at least one copy of each file: deselect one copy of “%@”.", members.first?.title ?? ""))
            }
            keepers[group] = keep
        }
        return keepers
    }

    /// Drops moved rows from a search's result without searching again; a group of copies with one left goes too.
    private func prune(_ section: DoctorSection, moved: Set<String>) {
        guard var result = stored[section] else { return }
        result.rows.removeAll { $0.level == 1 && $0.location.map { moved.contains($0.path) } == true }
        if section == .duplicates {
            let counts = Dictionary(grouping: result.rows.filter { $0.level == 1 }, by: { $0.group ?? "" }).mapValues(\.count)
            result.rows.removeAll { (counts[$0.group ?? ""] ?? 0) < 2 }
        }
        if section == .projects { result.rows.removeAll { $0.location.map { moved.contains($0.path) } == true } }
        stored[section] = result
    }

    /// Puts the newest move back. Items whose place was taken again stay in the Trash.
    func undoLastMove() async -> (restored: Int, left: [URL]) {
        guard let receipt = receipts.popLast() else { return (0, []) }
        let outcome = await (try? Images.detached { DoctorTrash.undo(receipt) }) ?? (0, receipt.moved.map(\.trashed))
        // Quick checks run again; the duplicate and project searches wait for Check Again (they can take minutes).
        for section in [DoctorSection.caches, .background] where results[section] != nil { run(section) }
        if largeFiles != nil { searchLargeFiles() }
        post()
        return outcome
    }

    /// The section a movable row belongs to, to check it again after a move.
    static func section(of row: DoctorRow) -> DoctorSection {
        switch row.id.split(separator: ".").first.map(String.init) ?? "" {
        case "bg": .background
        case "file": .storage
        case "dup", "sim": .duplicates
        case "build": .projects
        case "left": .uninstall
        default: .caches
        }
    }

    /// Names of running apps that own any of these rows.
    func runningOwners(_ rows: [DoctorRow]) -> [String] {
        var names: [String] = []
        for id in Set(rows.flatMap(\.bundleIDs)) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                if let name = app.localizedName, !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    /// Ejects the drive holding a volume, as Finder does (never forced). Returns nil when it worked, otherwise why not.
    func eject(_ volume: URL) async -> String? {
        guard Feature.doctor.isOn, let volume = DoctorCommand.validatedVolume(volume),
              DoctorDrives.volumes().contains(where: { $0.mountPoint == volume.path && $0.local }) else {
            return L("Mac Doctor can’t eject this drive.")
        }
        let output = try? await environment.run(.eject(volume))
        run(.drives)
        guard let output else { return L("The drive couldn’t be ejected.") }
        if output.status == 0 { return nil }
        if let holder = DoctorParse.dissenter(output) { return DoctorDrives.holder(holder.name) }
        return L("The drive couldn’t be ejected. Quit apps that use files on it and try again.")
    }

    // MARK: Checks that need several steps

    private static func performance(_ env: DoctorEnvironment) async -> DoctorResult {
        let cpu = (try? await env.run(.processCPU)).map { DoctorParse.processes($0.text) } ?? []
        let memory = (try? await env.run(.processMemory)).map { DoctorParse.processes($0.text) } ?? []
        var result = DoctorPerformance.check(cpu: cpu, memory: memory, state: DoctorPerformance.memory(),
                                             thermal: ProcessInfo.processInfo.thermalState,
                                             uptime: DoctorPerformance.timeSinceRestart())
        result.ran = [DoctorCommand.processCPU.displayString, DoctorCommand.processMemory.displayString]
        let apps = DoctorApps.candidates()
        let usage = await Task.detached(priority: .utility) { DoctorApps.usage(apps) }.value
        if !usage.isEmpty {
            // Apps the user can quit first, then every busy or large process (macOS's own included) below a heading.
            let processes = result.rows.map { row -> DoctorRow in var row = row; row.level = 1; return row }
            result.rows = DoctorApps.rows(usage)
            if !processes.isEmpty {
                result.rows.append(DoctorRow(id: "processes", title: L("Busiest and largest processes, macOS included"), value: "",
                                             detail: L("For reading only: macOS restarts its own processes when they are needed."),
                                             severity: .info))
                result.rows += processes
            }
            result.report.append(L("Apps that could be quit: %d, together using %@ of memory.", usage.count,
                                   DoctorFormat.memory(usage.reduce(0) { $0 + $1.bytes })))
        }
        return result
    }

    private static func power() async -> DoctorResult {
        let (assertions, battery) = await Task.detached(priority: .utility) {
            (DoctorPower.assertions(), DoctorBattery.health())
        }.value
        return DoctorPower.check(assertions, battery: battery)
    }

    private static func drives(_ env: DoctorEnvironment) async -> DoctorResult {
        // Mounted volumes: only drives plugged into this Mac and network shares. Disk images (opened .dmg files,
        // simulator runtimes) and internal volumes (a Boot Camp partition) are left out.
        var volumes: [DoctorDrives.Volume] = []
        var infos: [String: DoctorParse.DiskInfo] = [:]
        func info(_ disk: String) async -> DoctorParse.DiskInfo? {
            if let known = infos[disk] { return known }
            guard !Task.isCancelled, DoctorCommand.isDiskIdentifier(disk),
                  let output = try? await env.run(.diskInfo(disk)), output.status == 0,
                  let details = DoctorParse.diskInfo(output.stdout) else { return nil }
            infos[disk] = details
            return details
        }
        for var volume in DoctorDrives.volumes() {
            if !volume.local { volumes.append(volume); continue }
            guard let details = await info(volume.device), details.isExternalDrive else { continue }
            // An APFS volume's own whole disk is a synthesized container: Eject takes the physical drive behind it.
            if let store = details.physicalStore, let physical = await info(store) {
                volume.wholeDisk = physical.wholeDisk
            } else {
                volume.wholeDisk = details.wholeDisk
            }
            volumes.append(volume)
        }
        var unmounted: [DoctorDrives.Unmounted] = []
        if !Task.isCancelled, let list = try? await env.run(.externalDisks), list.status == 0 {
            for (disk, partitions) in DoctorParse.externalDisks(list.stdout).sorted(by: { $0.key < $1.key }) {
                guard let details = await info(disk), details.isExternalDrive else { continue }
                if partitions.isEmpty {
                    unmounted.append(.init(identifier: disk, content: "", size: 0, uninitialized: true))
                }
                for part in partitions where part.mountPoint == nil && part.size > 50_000_000
                    && !DoctorDrives.unmountable(part.content, name: part.name) {
                    unmounted.append(.init(identifier: part.identifier, content: part.content, size: part.size))
                }
            }
        }
        var result = DoctorDrives.check(volumes, unmounted: unmounted)
        result.ran = [DoctorCommand.externalDisks.displayString, "/usr/sbin/diskutil info -plist <disk>"]
        return result
    }

    private static func background(_ env: DoctorEnvironment) async -> DoctorResult {
        let items = await Task.detached(priority: .utility) { DoctorBackground.items(home: env.home) }.value
        let jobs = (try? await env.run(.launchdUserJobs)).flatMap { $0.status == 0 ? DoctorParse.launchdJobs($0.text) : nil }
        var systemLoaded = Set<String>()
        for item in items where item.place == .daemons && item.kind == .regular && DoctorCommand.isSafeLabel(item.label) {
            if Task.isCancelled { break }
            if let output = try? await env.run(.launchdSystemService(item.label)), output.status == 0 {
                systemLoaded.insert(item.label)
            }
        }
        var result = DoctorBackground.check(items, loaded: jobs, systemLoaded: systemLoaded, home: env.home)
        result.ran = [DoctorCommand.launchdUserJobs.displayString, "/bin/launchctl print system/<label>"]
        return result
    }

    private static func appCheck(_ app: URL, env: DoctorEnvironment) async -> DoctorResult {
        var findings = await Task.detached(priority: .userInitiated) { DoctorApp.inspect(app, home: env.home) }.value
        var ran: [String] = []
        // An incomplete bundle is never handed to codesign or spctl: they would follow whatever it points at.
        if !findings.iOSApp, findings.bundleComplete, !Task.isCancelled {
            let signature = DoctorCommand.codeSignature(app)
            ran.append(signature.displayString)
            findings.signature = (try? await env.run(signature)).flatMap { DoctorParse.signature($0, app: app) }
            let gatekeeper = DoctorCommand.gatekeeperAssessment(app)
            if !Task.isCancelled {
                ran.append(gatekeeper.displayString)
                if let output = try? await env.run(gatekeeper), !output.timedOut {
                    findings.assessment = DoctorParse.assessment(output, app: app)
                }
            }
        }
        var result = DoctorApp.check(findings, app: app)
        result.ran = ran
        return result
    }

    // MARK: Summary and assistant

    /// Results worth acting on, most serious first, across every section that has run.
    func findings() -> [(section: DoctorSection, row: DoctorRow?, text: String, severity: DoctorSeverity)] {
        var list: [(DoctorSection, DoctorRow?, String, DoctorSeverity)] = []
        for section in DoctorSection.allCases {
            guard let result = results[section], result.severity >= .review else { continue }
            list.append((section, nil, result.headline, result.severity))
        }
        return list.sorted { $0.3 > $1.3 }
    }

    /// The report for the checks that have run, exactly as it would be sent.
    func report(includeNames: Bool) -> String {
        DoctorReport.text(DoctorSection.allCases.compactMap { results[$0] }, includeNames: includeNames)
    }

    /// Stores a result as if its check had just run (tests and previews).
    func record(_ result: DoctorResult) {
        stored[result.section] = result
        post()
    }

    private func post() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}
