import AppKit
import ImageIO
import Testing
import DoctorCatalog
@testable import Swivel

/// Mac Doctor's safety rules: fixed commands only, Trash moves that can't be redirected, no reads of protected
/// places, and no "Open Anyway" advice for apps Apple has blocked. Every file test runs in a temporary home folder
/// with an injected Trash, so the real ~/.Trash and ~/Library are never touched.
@Suite(.serialized)
@MainActor
struct DoctorSafetyTests {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwivelDoctor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try DoctorTrash.realHome(url)
    }

    private func file(_ url: URL, _ text: String = "cache data") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A Trash stand-in: moves items into `<home>/FakeTrash` and returns the new place.
    private func fakeTrash(_ home: URL) throws -> DoctorTrash.Mover {
        let trash = home.appendingPathComponent("FakeTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return { url in
            let target = trash.appendingPathComponent(url.lastPathComponent + "-" + UUID().uuidString.prefix(4))
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    // MARK: Commands

    private let sampleApp = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    /// One sample per case, with no `default`: a new DoctorCommand case doesn't compile until it is listed here.
    private func sample(_ command: DoctorCommand) -> DoctorCommand {
        switch command {
        case .localSnapshots, .dnsConfiguration, .proxySettings, .launchdUserJobs, .processCPU, .processMemory,
             .networkQuality, .externalDisks: command
        case .launchdSystemService: .launchdSystemService("com.example.agent")
        case .gatekeeperAssessment: .gatekeeperAssessment(sampleApp)
        case .codeSignature: .codeSignature(sampleApp)
        case .diskInfo: .diskInfo("disk4")
        case .eject: .eject(URL(fileURLWithPath: "/Volumes/Backup"))
        }
    }

    private var allCommands: [DoctorCommand] {
        [.localSnapshots, .dnsConfiguration, .proxySettings, .launchdUserJobs, .launchdSystemService(""), .processCPU,
         .processMemory, .networkQuality, .gatekeeperAssessment(sampleApp), .codeSignature(sampleApp), .externalDisks,
         .diskInfo(""), .eject(sampleApp)].map(sample)
    }

    @Test func everyCommandIsOneAllowedToolAndVerb() {
        // An allow-list, so a state-changing verb (thinlocalsnapshots, unmountDisk, bootout, --remove-signature) fails.
        let allowed: [String: Set<String>] = [
            "/usr/bin/tmutil": ["listlocalsnapshots"], "/usr/sbin/scutil": ["--dns", "--proxy"],
            "/bin/launchctl": ["list", "print"], "/usr/bin/top": ["-l"], "/usr/bin/networkQuality": ["-M"],
            "/usr/sbin/spctl": ["--assess"], "/usr/bin/codesign": ["--verify"], "/usr/sbin/diskutil": ["list", "info", "eject"],
        ]
        for command in allCommands {
            let verbs = allowed[command.tool]
            #expect(verbs?.contains(command.arguments.first ?? "") == true, "\(command.tool) \(command.arguments)")
        }
        // Every argument is pinned, not only the verb.
        let pinned: [String: [String]] = [
            "/usr/bin/tmutil": ["listlocalsnapshots", "/"], "/usr/bin/networkQuality": ["-M", "30", "-c"],
            "/usr/bin/top": [], "/bin/launchctl": [], "/usr/sbin/scutil": [], "/usr/sbin/diskutil": [], "/usr/sbin/spctl": [], "/usr/bin/codesign": [],
        ]
        #expect(DoctorCommand.localSnapshots.arguments == pinned["/usr/bin/tmutil"])
        #expect(DoctorCommand.networkQuality.arguments == pinned["/usr/bin/networkQuality"])
        #expect(DoctorCommand.dnsConfiguration.arguments == ["--dns"] && DoctorCommand.proxySettings.arguments == ["--proxy"])
        #expect(DoctorCommand.launchdUserJobs.arguments == ["list"])
        #expect(DoctorCommand.processCPU.arguments == ["-l", "2", "-s", "1", "-n", "12", "-o", "cpu", "-stats", "pid,cpu,mem,command"])
        #expect(DoctorCommand.processMemory.arguments == ["-l", "1", "-n", "12", "-o", "mem", "-stats", "pid,cpu,mem,command"])
        #expect(DoctorCommand.gatekeeperAssessment(sampleApp).arguments == ["--assess", "--type", "execute", "--raw", "--no-cache", "--", sampleApp.path])
        #expect(DoctorCommand.codeSignature(sampleApp).arguments == ["--verify", "--deep", "--", sampleApp.path])
        #expect(DoctorCommand.externalDisks.arguments == ["list", "-plist", "external"])
        #expect(DoctorCommand.diskInfo("disk4").arguments == ["info", "-plist", "disk4"])
        #expect(DoctorCommand.eject(URL(fileURLWithPath: "/Volumes/Backup")).arguments == ["eject", "/Volumes/Backup"])
        #expect(DoctorCommand.launchdSystemService("x").arguments == ["print", "system/x"])
        #expect(DoctorCommand.processCPU.arguments.contains("-stats") && !DoctorCommand.processCPU.arguments.contains("-k"))
        #expect(!DoctorCommand.networkQuality.arguments.contains("-C") && !DoctorCommand.networkQuality.arguments.contains("-k"))
    }

    @Test func everyCommandIsAFixedSystemToolThatNeedsNoAdministrator() {
        let forbidden = ["sudo", "rm", "osascript", "sh", "bash", "zsh", "xattr", "--master-disable", "deletelocalsnapshots",
                         "resetbtm", "dumpbtm", "--strict", "-f", "force", "erase", "kill"]
        for command in allCommands {
            #expect(["/usr/bin/", "/bin/", "/usr/sbin/"].contains { command.tool.hasPrefix($0) }, "\(command)")
            for argument in command.arguments { #expect(!forbidden.contains(argument), "\(command) \(argument)") }
            #expect(!command.tool.hasSuffix("/sh") && !command.tool.hasSuffix("stapler"))
        }
        #expect(allCommands.filter(\.changesState) == [.eject(URL(fileURLWithPath: "/Volumes/Backup"))])
        #expect(Set(allCommands.filter(\.usesNetwork).map(\.tool)) == ["/usr/bin/networkQuality", "/usr/sbin/spctl"])
        // A picked path always comes after "--", so it can never read as an option.
        #expect(DoctorCommand.gatekeeperAssessment(sampleApp).arguments.suffix(2) == ["--", sampleApp.path])
        #expect(DoctorCommand.codeSignature(sampleApp).arguments.suffix(2) == ["--", sampleApp.path])
        #expect(DoctorCommand.gatekeeperAssessment(sampleApp).arguments.contains("--raw"))
        #expect(DoctorCommand.gatekeeperAssessment(sampleApp).arguments.contains("--no-cache"))
    }

    @Test func administratorCommandsAreFixedTextThatNothingCanRun() throws {
        for admin in DoctorAdminCommand.all { #expect(admin.command.hasPrefix("sudo ")) }
        // No runnable command contains what the admin commands do.
        let adminWords = ["sudo", "deletelocalsnapshots", "dscacheutil", "killall", "mDNSResponder", "sfltool", "dumpbtm", "resetbtm"]
        for command in allCommands {
            for word in adminWords {
                #expect(!command.tool.contains(word) && !command.arguments.contains { $0.contains(word) }, "\(command)")
            }
        }
        // And DoctorAdminCommand values are only ever the three constants, never built at run time.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Swivel")
        for name in try FileManager.default.contentsOfDirectory(atPath: sources.path) where name.hasPrefix("Doctor") {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            let constructions = text.components(separatedBy: "DoctorAdminCommand(").count - 1
            #expect(constructions == (name == "DoctorCommands.swift" ? 3 : 0), "\(name) builds \(constructions) admin commands")
        }
    }

    @Test func pickedPathsLabelsAndDisksMustBePlain() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let good = home.appendingPathComponent("Good.app")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        #expect(DoctorCommand.validatedApp(good)?.path == good.path)
        for name in ["Bad\r.app", "Bad\u{2028}.app", "Bad\u{202E}ppa.app", "Bad\u{85}.app", "Bad\n.app"] {
            let bad = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
            #expect(DoctorCommand.validatedApp(bad) == nil, "\(name.debugDescription)")
        }
        let notApp = home.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: notApp, withIntermediateDirectories: true)
        #expect(DoctorCommand.validatedApp(notApp) == nil)
        // A link to an app is checked as the app itself; a dangling one is refused.
        let link = home.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: good)
        #expect(DoctorCommand.validatedApp(link)?.path == good.path)
        let dangling = home.appendingPathComponent("Gone.app")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: home.appendingPathComponent("Nowhere.app").path)
        #expect(DoctorCommand.validatedApp(dangling) == nil)

        for label in ["com.example.agent", "org.mozilla.updater-2"] { #expect(DoctorCommand.isSafeLabel(label)) }
        for label in ["x; sudo sh -c \"$(curl host)\"", "a$(b)", "a`b`", "a\nb", "com.\u{202E}elppa", "-flag", "../system/x", ""] {
            #expect(!DoctorCommand.isSafeLabel(label), "\(label.debugDescription)")
        }
        #expect(DoctorCommand.isDiskIdentifier("disk4") && DoctorCommand.isDiskIdentifier("disk12s3"))
        #expect(!DoctorCommand.isDiskIdentifier("disk4; ls") && !DoctorCommand.isDiskIdentifier("/dev/disk4"))
        #expect(DoctorCommand.validatedVolume(URL(fileURLWithPath: "/Volumes/Backup")) != nil)
        #expect(DoctorCommand.validatedVolume(URL(fileURLWithPath: "/Volumes/A/B")) == nil)
        #expect(DoctorCommand.validatedVolume(URL(fileURLWithPath: "/Users/me")) == nil)
    }

    // MARK: Runner

    @Test func captureReadsLargeOutputInOrderAndReportsExitStatus() async throws {
        let output = try await Shell.capture("/usr/bin/perl", ["-e", "print qq($_\\n) for 1..60000; print STDERR qq(done\\n); exit 3"],
                                             timeout: 30, limit: 4 << 20)
        #expect(output.status == 3)
        let lines = output.text.split(separator: "\n")
        #expect(lines.count == 60000 && lines.first == "1" && lines.last == "60000")
        #expect(output.errorText.contains("done") && !output.truncated && !output.timedOut)
        let capped = try await Shell.capture("/usr/bin/perl", ["-e", "print qq(x) x 200000"], timeout: 30, limit: 1000)
        #expect(capped.stdout.count == 1000 && capped.truncated && capped.status == 0)
    }

    @Test func captureStopsAToolThatRunsTooLongAndHonoursCancellation() async throws {
        let start = Date()
        let slow = try await Shell.capture("/bin/sleep", ["30"], timeout: 1, limit: 1000)
        #expect(slow.timedOut && Date().timeIntervalSince(start) < 10)
        let task = Task { try await Shell.capture("/bin/sleep", ["30"], timeout: 60, limit: 1000) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(start) < 15)
    }

    // MARK: Trash

    @Test func cleaningMovesACachesContentsAsOneFolderAndUndoPutsThemBack() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/Homebrew")
        try file(cache.appendingPathComponent("downloads/a.tar.gz"))
        try file(cache.appendingPathComponent("b.json"))
        let plan = try DoctorTrash.planContents(of: "~/Library/Caches/Homebrew", name: "Homebrew Cache", home: home)
        #expect(plan.items.count == 2 && plan.skipped == 0)
        let receipt = try DoctorTrash.execute(plan, move: fakeTrash(home))
        #expect(receipt.failures.isEmpty && receipt.moved.count == 1 && receipt.movedItems == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)  // the folder stays, empty
        let trashed = try #require(receipt.moved.first?.trashed)
        #expect(trashed.lastPathComponent.hasPrefix(DoctorTrash.collectorName("Homebrew Cache")))
        #expect(DoctorTrash.collectorName("Google Chrome") == DoctorText.fileName(L("%@ cache (Mac Doctor)", "Google Chrome")))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: trashed.path)) == ["downloads", "b.json"])

        let outcome = DoctorTrash.undo(receipt)
        #expect(outcome.restored == 2 && outcome.left.isEmpty)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)) == ["downloads", "b.json"])
    }

    @Test func undoNeverOverwritesWhatTheAppRebuilt() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/pip")
        try file(cache.appendingPathComponent("wheels"), "old")
        let receipt = try DoctorTrash.execute(try DoctorTrash.planContents(of: "~/Library/Caches/pip", name: "pip Cache", home: home),
                                              move: fakeTrash(home))
        try file(cache.appendingPathComponent("wheels"), "rebuilt")
        let outcome = DoctorTrash.undo(receipt)
        #expect(outcome.restored == 0 && outcome.left.count == 1)
        #expect(try String(contentsOf: cache.appendingPathComponent("wheels"), encoding: .utf8) == "rebuilt")
    }

    @Test func linksOtherVolumesAndSwappedFoldersAreNeverFollowed() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let documents = home.appendingPathComponent("Documents")
        try file(documents.appendingPathComponent("thesis.txt"), "precious")
        // A cache folder that is a link to Documents is refused outright.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/Yarn"), withDestinationURL: documents)
        #expect(throws: ToolError.self) { try DoctorTrash.planContents(of: "~/Library/Caches/Yarn", name: "Yarn", home: home) }
        // A link inside a cache is left in place, and its target survives.
        let cache = home.appendingPathComponent("Library/Caches/CocoaPods")
        try file(cache.appendingPathComponent("Specs/x"))
        try FileManager.default.createSymbolicLink(at: cache.appendingPathComponent("link"), withDestinationURL: documents)
        let plan = try DoctorTrash.planContents(of: "~/Library/Caches/CocoaPods", name: "CocoaPods", home: home)
        #expect(plan.items.map(\.url.lastPathComponent) == ["Specs"] && plan.skipped == 1)
        // The cache folder is swapped for a link between the check and the move: nothing moves.
        try FileManager.default.moveItem(at: cache, to: home.appendingPathComponent("Library/Caches/CocoaPods-real"))
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: documents)
        #expect(throws: ToolError.self) { try DoctorTrash.execute(plan, move: try fakeTrash(home)) }
        #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("thesis.txt").path))
    }

    @Test func anItemChangedSinceTheCheckIsLeftInPlace() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent(".npm/_cacache")
        try file(cache.appendingPathComponent("index"))
        try file(cache.appendingPathComponent("content"))
        let plan = try DoctorTrash.planContents(of: "~/.npm/_cacache", name: "npm Cache", home: home)
        try FileManager.default.removeItem(at: cache.appendingPathComponent("index"))
        try file(cache.appendingPathComponent("index"), "new file under the old name")
        let receipt = try DoctorTrash.execute(plan, move: fakeTrash(home))
        #expect(receipt.movedItems == 1 && receipt.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("index").path))
    }

    @Test func aTrashFailurePutsEverythingBack() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/go-build")
        try file(cache.appendingPathComponent("00/a"))
        let failing: DoctorTrash.Mover = { _ in throw ToolError("no Trash") }
        let receipt = try DoctorTrash.execute(try DoctorTrash.planContents(of: "~/Library/Caches/go-build", name: "Go", home: home),
                                              move: failing)
        #expect(receipt.moved.isEmpty && receipt.failures.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == ["00"])
    }

    @Test func onlyCatalogueCachesAndYourOwnLaunchAgentsCanBeMoved() {
        #expect(DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Caches/Homebrew", mode: .contents)))
        #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/LaunchAgents", mode: .contents)))
        #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Documents", mode: .contents)))
        #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Caches", mode: .contents)))
        #expect(DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/LaunchAgents/com.example.agent.plist", mode: .item)))
        #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/LaunchAgents/sub/x.plist", mode: .item)))
        #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Preferences/x.plist", mode: .item)))
        #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Caches/Homebrew", mode: .item)))
    }

    @Test func aLeftoverAgentMovesAsOneFileAndRefusesSwapsAndReplacements() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let thesis = home.appendingPathComponent("Documents/thesis.txt")
        try file(thesis, "precious")
        let agent = home.appendingPathComponent("Library/LaunchAgents/gone.plist")
        try file(agent, "<plist/>")
        let identity = try FileIdentity.read(agent)
        let receipt = try DoctorTrash.execute(try DoctorTrash.planItem("~/Library/LaunchAgents/gone.plist", home: home, expected: identity),
                                              move: fakeTrash(home))
        #expect(receipt.moved.count == 1 && !FileManager.default.fileExists(atPath: agent.path))
        #expect(DoctorTrash.undo(receipt).restored == 1 && FileManager.default.fileExists(atPath: agent.path))
        // A different file under the same name (the app was reinstalled) is never moved.
        try FileManager.default.removeItem(at: agent)
        try file(agent, "<plist/>")
        #expect(throws: ToolError.self) { try DoctorTrash.planItem("~/Library/LaunchAgents/gone.plist", home: home, expected: identity) }
        // A link in place of the file, or of its folder, is refused; the target survives.
        let plan = try DoctorTrash.planItem("~/Library/LaunchAgents/gone.plist", home: home)
        try FileManager.default.removeItem(at: agent)
        try FileManager.default.createSymbolicLink(at: agent, withDestinationURL: thesis)
        #expect(throws: ToolError.self) { try DoctorTrash.execute(plan, move: try fakeTrash(home)) }
        #expect(throws: ToolError.self) { try DoctorTrash.planItem("~/Library/LaunchAgents/gone.plist", home: home) }
        let folder = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.moveItem(at: folder, to: home.appendingPathComponent("Library/Agents-real"))
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: home.appendingPathComponent("Documents"))
        #expect(throws: ToolError.self) { try DoctorTrash.planItem("~/Library/LaunchAgents/thesis.txt", home: home) }
        #expect(try String(contentsOf: thesis, encoding: .utf8) == "precious")
    }

    @Test func undoRefusesWhenTheCacheFolderWasSwappedForALink() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/Homebrew")
        try file(cache.appendingPathComponent("a"))
        let receipt = try DoctorTrash.execute(try DoctorTrash.planContents(of: "~/Library/Caches/Homebrew", name: "Homebrew Cache", home: home),
                                              move: fakeTrash(home))
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: home.appendingPathComponent("Documents"))
        let outcome = DoctorTrash.undo(receipt)
        #expect(outcome.restored == 0 && outcome.left.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Documents").path).isEmpty)
    }

    // MARK: Protected places

    @Test func protectedPlacesAreSkippedWhileSizingAFolder() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for place in ["Documents", "Library/Containers/com.example", "Library/Mail"] {
            try file(home.appendingPathComponent(place).appendingPathComponent("private.bin"), String(repeating: "x", count: 100_000))
        }
        try file(home.appendingPathComponent("Library/Caches/thing/data.bin"), String(repeating: "y", count: 100_000))
        #expect(DoctorPrivacy.isProtected(home.appendingPathComponent("Documents/a"), home: home))
        #expect(DoctorPrivacy.isProtected(URL(fileURLWithPath: "/Volumes/USB"), home: home))
        #expect(DoctorPrivacy.isProtected(home.appendingPathComponent("Pictures/Photos Library.photoslibrary"), home: home))
        #expect(!DoctorPrivacy.isProtected(home.appendingPathComponent("Library/Caches/thing"), home: home))
        let size = DoctorStorage.size(of: home, home: home)
        #expect(size.skipped == 3)
        #expect(size.bytes >= 100_000 && size.bytes < 200_000)
        // Other spellings of the same places: the Data volume's firmlink, "..", another case, network mounts.
        let data = URL(fileURLWithPath: "/System/Volumes/Data" + DoctorPrivacy.canonical(home.path))
        for spelling in [data.appendingPathComponent("Documents/a").path, home.path + "/Library/../Documents/a",
                         home.path.uppercased() + "/DESKTOP", "/System/Volumes/Data/Volumes/USB", "/Network", "/net/host/x"] {
            #expect(DoctorPrivacy.isProtected(URL(fileURLWithPath: spelling), home: home), "\(spelling)")
        }
        let throughData = DoctorStorage.size(of: data, home: home)
        #expect(throughData.skipped == 3 && throughData.bytes < 200_000)
        // A protected folder the user picked themselves is looked into.
        let picked = DoctorStorage.size(of: home.appendingPathComponent("Documents"), home: home)
        #expect(picked.skipped == 0 && picked.bytes >= 100_000)
    }

    @Test func everyCatalogueEntryIsANarrowCacheFolderOutsideProtectedPlaces() {
        let entries = ClearDiskCatalog.entries
        #expect(entries.count == 46)
        #expect(Set(entries.map(\.id)).count == entries.count && Set(entries.map(\.path)).count == entries.count)
        let home = URL(fileURLWithPath: "/Users/someone")
        let allowedSupport: Set<String> = ["Cache", "Code Cache", "GPUCache", "htmlcache", "CachedData", "CachedExtensionVSIXs"]
        for entry in entries {
            #expect(entry.path.hasPrefix("~/") && !entry.path.contains("..") && entry.path.split(separator: "/").count >= 3, "\(entry.id)")
            #expect(!entry.path.contains("/Containers/") && !entry.path.contains("Group Containers"), "\(entry.id)")
            if entry.path.hasPrefix("~/Library/Application Support/") {
                #expect(allowedSupport.contains(String(entry.path.split(separator: "/").last!)), "\(entry.id)")
            }
            #expect(DoctorTrash.isAllowed(DoctorTrashTarget(path: entry.path, mode: .contents)))
            let url = home.appendingPathComponent(String(entry.path.dropFirst(2)))
            #expect(!DoctorPrivacy.isProtected(url, home: home) || entry.id == "safari-cache", "\(entry.id)")
            for other in entries where other.id != entry.id { #expect(!other.path.hasPrefix(entry.path + "/"), "\(entry.id) contains \(other.id)") }
            if entry.section == .app { #expect(entry.removes != nil && entry.keeps != nil && entry.note != nil, "\(entry.id)") }
        }
    }

    // MARK: Background items

    private func plist(_ url: URL, _ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url)
    }

    @Test func onlyAnAbsoluteProgramThatIsReallyGoneCountsAsLeftOver() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try plist(agents.appendingPathComponent("gone.plist"), ["Label": "com.example.gone", "Program": home.path + "/Applications/Gone.app/Contents/MacOS/Gone"])
        try plist(agents.appendingPathComponent("bare.plist"), ["Label": "com.example.bare", "ProgramArguments": ["bash", "-c", "true"]])
        try plist(agents.appendingPathComponent("docs.plist"), ["Label": "com.example.docs", "Program": home.path + "/Documents/run.sh"])
        try plist(agents.appendingPathComponent("bundle.plist"), ["Label": "com.example.bundle", "BundleProgram": "Contents/MacOS/Helper"])
        try plist(agents.appendingPathComponent("empty.plist"), [:])
        try FileManager.default.createSymbolicLink(atPath: agents.appendingPathComponent("dangling.plist").path,
                                                   withDestinationPath: home.appendingPathComponent("nowhere.plist").path)
        func item(_ name: String) -> DoctorBackground.Item {
            DoctorBackground.read(agents.appendingPathComponent(name), place: .userAgents, home: home)
        }
        #expect(item("gone.plist").status == .missing)
        #expect(item("bare.plist").status == .present)
        #expect(item("docs.plist").status == .cantCheck)  // in Documents: not even looked at
        #expect(item("bundle.plist").status == .managedByApp)
        #expect(item("empty.plist").kind == .inert)
        #expect(item("dangling.plist").kind == .danglingLink)

        let items = ["gone.plist", "bare.plist", "docs.plist", "bundle.plist", "empty.plist", "dangling.plist"].map(item)
        let result = DoctorBackground.check(items, loaded: [:], systemLoaded: [], home: home)
        let movable = result.rows.filter { $0.trash != nil }
        #expect(movable.count == 1 && movable[0].trash?.path == "~/Library/LaunchAgents/gone.plist")
        #expect(result.adminCommands == [.listBackgroundItems])
    }

    @Test func plistReaderRefusesFIFOsHugeFilesAndDeepNesting() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let fifo = home.appendingPathComponent("fifo.plist")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let start = Date()
        #expect(DoctorBackground.readSmallFile(fifo) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
        let huge = home.appendingPathComponent("huge.plist")
        try Data(count: 70_000).write(to: huge)
        #expect(DoctorBackground.readSmallFile(huge) == nil)
        let deep = String(repeating: "<array>", count: 40) + String(repeating: "</array>", count: 40)
        #expect(DoctorBackground.parse(Data(("<plist><dict><key>a</key>" + deep + "</dict></plist>").utf8)) == nil)
    }

    @Test func disguisedNamesAreFlagged() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/LaunchAgents/x.plist")
        let items = [
            DoctorBackground.Item(file: file, place: .userAgents, kind: .regular, label: "com.\u{0430}pple.update", program: "/bin/ls",
                                  status: .present, runsAtLoad: true, keepsAlive: false, disabled: false, app: nil),
            DoctorBackground.Item(file: file, place: .userAgents, kind: .regular, label: "com.apple.softwareupdate", program: "/bin/ls",
                                  status: .present, runsAtLoad: true, keepsAlive: false, disabled: false, app: nil),
            DoctorBackground.Item(file: file, place: .userAgents, kind: .regular, label: "x\u{202E}gpj.exe", program: "/bin/ls",
                                  status: .present, runsAtLoad: true, keepsAlive: false, disabled: false, app: nil),
        ]
        let result = DoctorBackground.check(items, loaded: nil, systemLoaded: [], home: home)
        #expect(result.rows.allSatisfy { $0.severity == .review })
        #expect(result.rows.contains { $0.title.contains("\\u{202E}") })
        #expect(result.names.allSatisfy { $0 == "<unusual name>" || $0 == "com.apple.softwareupdate" })
    }

    // MARK: Apps that won't open

    private func findings(signature: DoctorParse.Signature?, verdict: DoctorParse.Assessment.Verdict?, source: String? = nil,
                          adHoc: Bool = false, signed: Bool = true, quarantine: UInt32? = 0x0083) -> DoctorApp.Findings {
        DoctorApp.Findings(name: "Sample", iOSApp: false, bundleComplete: true, adHoc: adHoc, hasSignature: signed,
                           signature: signature, assessment: verdict.map { .init(verdict: $0, source: source) },
                           quarantine: quarantine.map { .init(flags: $0, date: nil, agent: "Safari") }, intelOnly: false,
                           rosettaInstalled: true, minimumSystem: nil, tooNew: false, temporaryLocation: false)
    }

    /// Everything the section shows: headline, notes, row texts.
    private func text(_ result: DoctorResult) -> String {
        ([result.headline] + result.notes + result.rows.flatMap { [$0.title, $0.value, $0.detail] }).joined(separator: "\n")
    }

    @Test func appsAppleBlockedAreNeverSteeredTowardsOpenAnyway() {
        let openAnyway = L("To open it anyway: 1. Try to open the app once and close the message. 2. Open Privacy & Security and scroll down. 3. Choose Open Anyway and enter your password. The button appears for about an hour after the first try.")
        let app = URL(fileURLWithPath: "/Applications/Sample.app")
        for revoked in [findings(signature: .revoked, verdict: .rejected), findings(signature: .valid, verdict: .revoked)] {
            let result = DoctorApp.check(revoked, app: app)
            #expect(result.severity == .problem)
            #expect(result.headline == L("Apple has blocked this app as harmful. Move it to the Trash and don’t open it."))
            #expect(!text(result).contains(openAnyway))
            #expect(result.report.contains(L("Apple has blocked this app as harmful: never suggest opening it.")))
        }
        // Only a valid, identified, unnotarized app on its first open gets the steps, framed as a risk decision.
        let unnotarized = DoctorApp.check(findings(signature: .valid, verdict: .rejected, source: "Unnotarized Developer ID"), app: app)
        #expect(text(unnotarized).contains(openAnyway) && unnotarized.panes == [.privacy])
        let others = [findings(signature: .unsigned, verdict: .rejected, signed: false),
                      findings(signature: .valid, verdict: .rejected, adHoc: true),
                      // A self-signed app: intact, but Gatekeeper names no source, so not an identified developer.
                      findings(signature: .valid, verdict: .rejected),
                      findings(signature: .modified, verdict: .invalidSignature),
                      findings(signature: .other("x"), verdict: .invalidSignature),
                      findings(signature: .revoked, verdict: .rejected),
                      findings(signature: .valid, verdict: .rejected, source: "Unnotarized Developer ID", quarantine: 0x00c3)]
        for other in others {
            let result = DoctorApp.check(other, app: app)
            #expect(!text(result).contains(openAnyway) && !result.panes.contains(.privacy), "\(other.signature as Any)")
            #expect(!DoctorReport.soundsRisky(text(result)))
            #expect(result.adminCommands.isEmpty)
        }
        let selfSigned = DoctorApp.check(findings(signature: .valid, verdict: .rejected), app: app)
        #expect(selfSigned.rows.contains { $0.detail == L("Signed, but not by a developer Apple has identified.") })
        #expect(!text(selfSigned).contains(L("Signed by Apple.")))
        #expect(DoctorApp.check(findings(signature: .other("x"), verdict: .invalidSignature), app: app).severity == .problem)
        // No downloaded flag: Gatekeeper doesn't stop it at launch, so it isn't "blocked".
        let local = DoctorApp.check(findings(signature: .valid, verdict: .rejected, adHoc: true, quarantine: nil), app: app)
        #expect(local.severity == .info && local.headline == L("Gatekeeper wouldn’t approve this app, but it has no downloaded flag, so macOS opens it without asking. If it still won’t open, it may be crashing: try reinstalling it."))
        // Gatekeeper never answered: say so, never "accepts".
        let unanswered = DoctorApp.check(findings(signature: .valid, verdict: nil), app: app)
        #expect(unanswered.headline == L("Gatekeeper’s check didn’t finish, so Mac Doctor can’t say yet whether macOS allows this app. Try again; large apps can take a few minutes."))
        let accepted = DoctorApp.check(findings(signature: .valid, verdict: .accepted, source: "Notarized Developer ID"), app: app)
        #expect(accepted.severity == .ok)
        #expect(accepted.headline == L("Gatekeeper accepts this app’s signature. The first time you open it, macOS asks once to confirm — that is normal. This is not a malware scan."))
    }

    @Test func inspectingAnAppReadsItsFlagsWithoutFollowingItsInfoPlist() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Fake.app")
        let contents = app.appendingPathComponent("Contents")
        try plist(contents.appendingPathComponent("Info.plist"), ["CFBundleExecutable": "../../../Documents/x", "CFBundleName": "Fake",
                                                                    "LSMinimumSystemVersion": "99.0"])
        try file(contents.appendingPathComponent("MacOS/Fake"))
        let flag = "00c3;6720b1c2;Safari;"
        #expect(setxattr(app.path, "com.apple.quarantine", flag, flag.utf8.count, 0, XATTR_NOFOLLOW) == 0)
        let findings = DoctorApp.inspect(try #require(DoctorCommand.validatedApp(app)), home: home)
        #expect(!findings.bundleComplete)  // an executable name with "/" is refused, not followed
        #expect(findings.quarantine?.approved == true && findings.quarantine?.agent == "Safari")
        #expect(findings.tooNew && findings.signer == .none && !findings.hasSignature)
        // A FIFO as the program file: never opened (Security would block on it forever).
        let fifoApp = home.appendingPathComponent("Fifo.app")
        try plist(fifoApp.appendingPathComponent("Contents/Info.plist"), ["CFBundleExecutable": "Fifo"])
        try FileManager.default.createDirectory(at: fifoApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        #expect(mkfifo(fifoApp.appendingPathComponent("Contents/MacOS/Fifo").path, 0o600) == 0)
        let start = Date()
        #expect(!DoctorApp.inspect(fifoApp, home: home).bundleComplete)
        #expect(Date().timeIntervalSince(start) < 2)

        let wrapped = home.appendingPathComponent("Phone.app")
        try FileManager.default.createDirectory(at: wrapped.appendingPathComponent("Wrapper/Inner.app"), withIntermediateDirectories: true)
        #expect(DoctorApp.inspect(wrapped, home: home).iOSApp)
    }

    @Test func architecturesComeFromTheProgramsOwnHeader() {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: calculator.path) else { return }
        let findings = DoctorApp.inspect(calculator, home: FileManager.default.homeDirectoryForCurrentUser)
        #expect(findings.bundleComplete && findings.hasSignature && !findings.adHoc && !findings.intelOnly && !findings.iOSApp)
        #expect(DoctorApp.machOArchitectures(calculator.appendingPathComponent("Contents/MacOS/Calculator")).contains(DoctorApp.cpuARM64))
        // Only Gatekeeper's verdict makes it Apple's; without one the signer is unknown, not "unidentified".
        var withVerdict = findings
        #expect(withVerdict.signer == .unknown)
        withVerdict.assessment = .init(verdict: .rejected, source: nil)
        #expect(withVerdict.signer == .unidentified)
        withVerdict.assessment = .init(verdict: .accepted, source: "Apple System")
        #expect(withVerdict.signer == .apple)
    }
}

/// The storage cleanup and memory tools: what the large-file search may offer, how those files move, and which
/// apps may be asked to quit.
extension DoctorSafetyTests {
    @Suite(.serialized)
    @MainActor
    struct DoctorCleanupTests {
        private func temporaryHome() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwivelDoctorCleanup-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return try DoctorTrash.realHome(url)
        }

        private func file(_ url: URL, bytes: Int) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }

        @Test func theSearchOffersInstallersAndLargeFilesButNeverLinksPackagesHiddenFoldersOrHardLinks() throws {
            let home = try temporaryHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try file(home.appendingPathComponent("Downloads/Setup.dmg"), bytes: 1_200_000)
            try file(home.appendingPathComponent("Downloads/tiny.pkg"), bytes: 20_000)
            try file(home.appendingPathComponent("Documents/Film/cut.mov"), bytes: 2_500_000)
            try file(home.appendingPathComponent("Documents/notes.txt"), bytes: 50_000)
            try file(home.appendingPathComponent("Desktop/Tool.app/Contents/Resources/big.bin"), bytes: 2_500_000)
            try file(home.appendingPathComponent("Documents/Repo/.git/objects/pack.bin"), bytes: 2_500_000)
            try file(home.appendingPathComponent("Documents/Site/node_modules/dep/blob.bin"), bytes: 2_500_000)
            try file(home.appendingPathComponent("Documents/shared.bin"), bytes: 2_500_000)
            try FileManager.default.linkItem(at: home.appendingPathComponent("Documents/shared.bin"),
                                             to: home.appendingPathComponent("Documents/shared copy.bin"))
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Desktop/alias.dmg"),
                                                       withDestinationURL: home.appendingPathComponent("Downloads/Setup.dmg"))
            let outcome = DoctorLargeFiles.scan(home: home, large: 2_000_000, installer: 1_000_000)
            #expect(Set(outcome.files.map(\.url.lastPathComponent)) == ["Setup.dmg", "cut.mov"])
            #expect(outcome.files.first?.url.lastPathComponent == "cut.mov" && outcome.unreadable.isEmpty)
            #expect(outcome.files.first { $0.url.lastPathComponent == "Setup.dmg" }?.installer == true)

            let result = DoctorLargeFiles.merge(nil, outcome, home: home)
            let rows = result.rows.filter { $0.trash != nil }
            #expect(rows.count == 2 && rows.allSatisfy { DoctorTrash.isAllowed($0.trash!) && $0.trash?.identity != nil })
            #expect(rows.allSatisfy { $0.trash!.path.hasPrefix("~/Downloads/") || $0.trash!.path.hasPrefix("~/Documents/") })
            // Names stay on the Mac: the assistant report only has counts.
            #expect(!result.report.joined().contains("cut.mov") && result.names.isEmpty)
        }

        @Test func onlyFilesTheSearchFoundInTheThreeFoldersCanBeMoved() {
            let identity = FileIdentity(device: 1, inode: 2)
            #expect(DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Downloads/Setup.dmg", mode: .item, identity: identity)))
            #expect(DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Documents/Film/cut.mov", mode: .item, identity: identity)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Downloads/Setup.dmg", mode: .item)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Downloads", mode: .contents)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Preferences/x.plist", mode: .item, identity: identity)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Documents/../Library/x", mode: .item, identity: identity)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Pictures/big.mov", mode: .item, identity: identity)))
        }

        @Test func aFoundFileMovesAndComesBackButAReplacedOneStays() async throws {
            let defaults = UserDefaults.standard, before = defaults.object(forKey: "feature.doctor")
            defer { if let before { defaults.set(before, forKey: "feature.doctor") } else { defaults.removeObject(forKey: "feature.doctor") } }
            Prefs.setFeatureEnabled(.doctor, true)
            let home = try temporaryHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let setup = home.appendingPathComponent("Downloads/Setup.dmg")
            let movie = home.appendingPathComponent("Documents/cut.mov")
            try file(setup, bytes: 1_200_000)
            try file(movie, bytes: 2_500_000)
            let outcome = DoctorLargeFiles.scan(home: home, large: 2_000_000, installer: 1_000_000)
            let rows = DoctorLargeFiles.merge(nil, outcome, home: home).rows.filter { $0.trash != nil }
            // The movie is replaced by a different file under the same name after the search.
            try FileManager.default.removeItem(at: movie)
            try file(movie, bytes: 10)
            let trash = home.appendingPathComponent("FakeTrash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let center = DoctorCenter.shared
            let saved = center.environment
            defer { center.environment = saved }
            center.environment.home = home
            center.environment.trash = { url in
                let target = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
            let receipt = try await center.moveToTrash(rows)
            #expect(receipt.moved.count == 1 && receipt.failures.count == 1)
            #expect(!FileManager.default.fileExists(atPath: setup.path) && FileManager.default.fileExists(atPath: trash.appendingPathComponent("Setup.dmg").path))
            #expect((try Data(contentsOf: movie)).count == 10)
            #expect(DoctorTrash.undo(receipt).restored == 1 && FileManager.default.fileExists(atPath: setup.path))
            center.cancelAll()
        }

        @Test func essentialAppsAndSwivelAreNeverOfferedAndChangedAppsAreNeverAsked() {
            #expect(!DoctorApps.quittable("com.apple.finder", own: "local.swivel.app"))
            #expect(!DoctorApps.quittable("com.apple.dock", own: "local.swivel.app"))
            #expect(!DoctorApps.quittable("local.swivel.app", own: "local.swivel.app"))
            #expect(!DoctorApps.quittable("local.swivel.app.mcp", own: "local.swivel.app"))
            #expect(DoctorApps.quittable("com.google.Chrome", own: "local.swivel.app"))
            #expect(DoctorApps.quittable("com.google.Chrome", own: ""))
            // No such process, and this test process under a made-up identity: neither is asked to quit.
            let outcome = DoctorApps.quit([DoctorQuitTarget(pid: 999_999, bundleID: "com.example.gone", launched: nil),
                                           DoctorQuitTarget(pid: getpid(), bundleID: "com.example.other", launched: nil)])
            #expect(outcome.asked.isEmpty && outcome.skipped.count == 2)
            let rows = DoctorApps.rows([DoctorApps.Usage(app: .init(pid: 42, bundleID: "com.example.big", name: "Big\u{202E}App",
                                                                     bundlePath: "/Applications/Big.app", launched: nil), bytes: 3_000_000_000)])
            #expect(rows.count == 2 && rows[1].quit?.pid == 42 && rows[1].level == 1 && rows[1].severity == .review)
            #expect(rows[1].title.contains("\\u{202E}"))
            #expect(DoctorApps.usage([]).isEmpty)
        }

        @Test func liveReadingsAreSaneAndTheChartsTakeThem() {
            var live = DoctorLive()
            #expect(live.cpu() == nil)
            usleep(50_000)
            if let cpu = live.cpu() { #expect((0...1).contains(cpu)) }
            let memory = DoctorLive.memory()
            #expect(memory != nil && memory!.used > 0 && (0...1).contains(memory!.fraction))
            let disk = DoctorChartPanel(.disk)
            disk.showDisk(DoctorStorage.Space(total: 1_000, available: 300, important: 400), selected: 50, inTrash: true)
            disk.showDisk(nil, selected: 0, inTrash: true)
            let panel = DoctorChartPanel(.memory)
            panel.showMemory(memory, pressure: 2, swap: 1_000, selected: 10)
            panel.showHistory(cpu: [0.1, 0.5, 2], memory: [0.4, 0.45])
            panel.view.layoutSubtreeIfNeeded()
            #expect(panel.view.fittingSize.width > 300)
            let caches = DoctorChartPanel(.caches)
            caches.showCaches([], selected: [])
            let rows = (0..<9).map { DoctorRow(id: "cache.\($0)", title: "Cache \($0)", value: "", detail: "", severity: .info,
                                               bytes: Int64(9 - $0) * 100_000_000) }
            caches.showCaches(rows, selected: ["cache.0"])
            caches.showCaches(rows, selected: [])
            caches.view.layoutSubtreeIfNeeded()
            #expect(caches.view.fittingSize.height > 150)
        }
    }
}

/// Space map, duplicate files, project build folders and uninstalling (ideas from MangoDisk, reimplemented).
extension DoctorSafetyTests {
    @Suite(.serialized)
    @MainActor
    struct DoctorExploreTests {
        private func temporaryHome() throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwivelDoctorExplore-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return try DoctorTrash.realHome(url)
        }

        private func file(_ url: URL, _ data: Data) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        private func withDoctor(_ body: () async throws -> Void) async rethrows {
            let defaults = UserDefaults.standard, before = defaults.object(forKey: "feature.doctor")
            defer { if let before { defaults.set(before, forKey: "feature.doctor") } else { defaults.removeObject(forKey: "feature.doctor") } }
            Prefs.setFeatureEnabled(.doctor, true)
            try await body()
        }

        private func fakeTrash(_ home: URL) throws -> DoctorTrash.Mover {
            let trash = home.appendingPathComponent("FakeTrash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            return { url in
                let target = trash.appendingPathComponent(url.lastPathComponent + "-" + UUID().uuidString.prefix(4))
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
        }

        @Test func theSpaceMapAddsUpFoldersAndTheTreemapFillsItsBox() throws {
            let home = try temporaryHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let root = home.appendingPathComponent("Stuff")
            try file(root.appendingPathComponent("Video/a.mov"), Data(count: 400_000))
            try file(root.appendingPathComponent("Video/Old/b.mov"), Data(count: 200_000))
            try file(root.appendingPathComponent("notes.txt"), Data(count: 50_000))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/System"))
            let map = DoctorSpaceMap.build(root, home: home)
            let video = try #require(map.root.children.first { $0.name == "Video" })
            #expect(video.isFolder && video.children.contains { $0.name == "Old" })
            #expect(map.root.bytes == map.root.children.reduce(0) { $0 + $1.bytes } && map.root.bytes == map.size.bytes)
            #expect(video.bytes > 590_000 && map.root.children.first?.name == "Video")
            let rect = NSRect(x: 0, y: 0, width: 400, height: 300)
            let boxes = DoctorTreemap.squarify(map.root.children, in: rect)
            let area = boxes.reduce(0.0) { $0 + Double($1.0.width * $1.0.height) }
            #expect(abs(area - 120_000) < 1 && boxes.allSatisfy { rect.insetBy(dx: -0.5, dy: -0.5).contains($0.0) })
        }

        @Test func duplicatesAreFoundByContentAndTheLastCopyNeverMoves() async throws {
            try await withDoctor {
                let home = try temporaryHome()
                defer { try? FileManager.default.removeItem(at: home) }
                let same = Data((0..<1_500_000).map { UInt8($0 % 251) })
                var other = same; other[700_000] ^= 1  // same size and ends, different middle
                try file(home.appendingPathComponent("Pictures/a.jpg"), same)
                try file(home.appendingPathComponent("Pictures/Copy/a copy.jpg"), same)
                try file(home.appendingPathComponent("Pictures/near.jpg"), other)
                try file(home.appendingPathComponent("Pictures/.hidden/a.jpg"), same)
                try FileManager.default.linkItem(at: home.appendingPathComponent("Pictures/a.jpg"), to: home.appendingPathComponent("Pictures/hard.jpg"))
                let outcome = DoctorDuplicates.find([home.appendingPathComponent("Pictures")], home: home)
                #expect(outcome.groups.count == 1 && outcome.groups[0].copies.count == 2)
                #expect(Set(outcome.groups[0].copies.map(\.url.lastPathComponent)) == ["a copy.jpg", "a.jpg"] || Set(outcome.groups[0].copies.map(\.url.lastPathComponent)) == ["a copy.jpg", "hard.jpg"])
                let result = DoctorDuplicates.result(outcome, roots: [], home: home)
                let copies = result.rows.filter { $0.level == 1 }
                #expect(copies.count == 2 && copies.allSatisfy { $0.trash?.origin == .duplicate })
                #expect(!result.report.joined().contains("a.jpg"))

                let center = DoctorCenter.shared
                let saved = center.environment
                defer { center.environment = saved; center.cancelAll() }
                center.environment.home = home
                center.environment.trash = try fakeTrash(home)
                center.record(result)
                // Both copies selected: refused, nothing moves.
                await #expect(throws: ToolError.self) { _ = try await center.moveToTrash(copies) }
                #expect(copies.allSatisfy { FileManager.default.fileExists(atPath: $0.location!.path) })
                // The kept copy changed after the search: the other stays too.
                let kept = copies[0].location!, extra = copies[1]
                try other.write(to: kept)
                let refused = try await center.moveToTrash([extra])
                #expect(refused.moved.isEmpty && FileManager.default.fileExists(atPath: extra.location!.path))
                try same.write(to: kept)
                let receipt = try await center.moveToTrash([extra])
                #expect(receipt.moved.count == 1 && !FileManager.default.fileExists(atPath: extra.location!.path))
                #expect(FileManager.default.fileExists(atPath: kept.path))
            }
        }

        /// A test picture: soft shapes on a gradient, drawn at `size`, saved as `type`.
        private func picture(_ url: URL, size: Int, seed: Int, type: CFString, quality: Double = 0.9) throws {
            let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for y in stride(from: 0, to: size, by: 4) {
                context.setFillColor(red: CGFloat(y) / CGFloat(size), green: 0.4, blue: CGFloat(seed % 3) / 3, alpha: 1)
                context.fill(CGRect(x: 0, y: y, width: size, height: 4))
            }
            for i in 0..<6 {
                let v = CGFloat((seed * 37 + i * 53) % 100) / 100
                context.setFillColor(red: 1 - v, green: v, blue: 0.2, alpha: 1)
                context.fillEllipse(in: CGRect(x: CGFloat(size) * v * 0.7, y: CGFloat(size) * CGFloat(i) / 7, width: CGFloat(size) / 4, height: CGFloat(size) / 5))
            }
            // Noise so the file is big enough to be compared, without changing how it looks.
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<(size * 4) {
                context.setFillColor(gray: CGFloat.random(in: 0...1, using: &rng), alpha: 0.08)
                context.fill(CGRect(x: Int.random(in: 0..<size, using: &rng), y: Int.random(in: 0..<size, using: &rng), width: 1, height: 1))
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
        }

        @Test func nearlyIdenticalPhotosAndTextsAreGroupedWithHowAlikeTheyAreAndNeverPreselected() async throws {
            try await withDoctor {
                let home = try temporaryHome()
                defer { try? FileManager.default.removeItem(at: home) }
                let pictures = home.appendingPathComponent("Pictures")
                try picture(pictures.appendingPathComponent("beach.png"), size: 800, seed: 1, type: "public.png" as CFString)
                try picture(pictures.appendingPathComponent("beach small.jpg"), size: 500, seed: 1, type: "public.jpeg" as CFString, quality: 0.6)
                try picture(pictures.appendingPathComponent("forest.png"), size: 800, seed: 2, type: "public.png" as CFString)
                let lines = (0..<30).map { "Line \($0): the quick brown fox number \($0 * 7) jumps." }
                var edited = lines; edited[3] = "Line 3 was rewritten entirely."; edited[20] = "A new line 20."
                try file(home.appendingPathComponent("Documents/notes.md"), Data(lines.joined(separator: "\n").utf8))
                try file(home.appendingPathComponent("Documents/notes old.md"), Data(edited.joined(separator: "\n").utf8))
                try file(home.appendingPathComponent("Documents/other.md"), Data((0..<30).map { "Unrelated \($0 * 13)" }.joined(separator: "\n").utf8))
                let outcome = DoctorDuplicates.find([pictures, home.appendingPathComponent("Documents")], home: home)
                #expect(outcome.groups.isEmpty)
                let photo = try #require(outcome.similar.first { $0.kind == .photo })
                #expect(Set(photo.copies.map(\.url.lastPathComponent)) == ["beach.png", "beach small.jpg"])
                #expect(photo.similarity[0] == 1 && photo.similarity[1] >= 0.9)
                let text = try #require(outcome.similar.first { $0.kind == .text })
                #expect(Set(text.copies.map(\.url.lastPathComponent)) == ["notes.md", "notes old.md"])
                #expect(text.similarity[1] >= 0.8 && text.similarity[1] < 1)
                #expect(outcome.similar.count == 2)

                let result = DoctorDuplicates.result(outcome, roots: [], home: home)
                let rows = result.rows.filter { $0.trash?.origin == .similar }
                #expect(rows.count == 4 && rows.allSatisfy { $0.value.contains("%") || $0.value.contains("·") })
                #expect(!result.report.joined().contains("beach"))
                // A whole group selected is refused; one of them may go while the other stays.
                let center = DoctorCenter.shared
                let saved = center.environment
                defer { center.environment = saved; center.cancelAll() }
                center.environment.home = home
                center.environment.trash = try fakeTrash(home)
                center.record(result)
                let group = rows.filter { $0.group == rows[0].group }
                await #expect(throws: ToolError.self) { _ = try await center.moveToTrash(group) }
                let receipt = try await center.moveToTrash([group[1]])
                #expect(receipt.moved.count == 1 && FileManager.default.fileExists(atPath: group[0].location!.path))
            }
        }

        @Test func reviewFindingsStayFixed() async throws {
            try await withDoctor {
                let home = try temporaryHome()
                defer { try? FileManager.default.removeItem(at: home) }
                // 1. A file with identical copies never also sits in a similar group, so it can't be both kept and moved.
                let lines = (0..<30).map { "Row \($0) of the shared notes, item \($0 * 11)." }
                var edited = lines; edited[5] = "Changed row."
                let text = Data(lines.joined(separator: "\n").utf8)
                let docs = home.appendingPathComponent("Documents")
                try file(docs.appendingPathComponent("a.md"), text)
                try file(docs.appendingPathComponent("b.md"), text)
                try file(docs.appendingPathComponent("c.md"), Data(edited.joined(separator: "\n").utf8))
                let outcome = DoctorDuplicates.find([docs], home: home, smallest: 1)
                #expect(outcome.groups.count == 1)
                let exact = Set(outcome.groups.flatMap { $0.copies.map(\.url.path) })
                #expect(outcome.similar.allSatisfy { Set($0.copies.map(\.url.path)).isDisjoint(with: exact) })
                // A batch that includes every copy of a group is refused even when the rows come from different groups.
                let result = DoctorDuplicates.result(outcome, roots: [], home: home)
                let center = DoctorCenter.shared
                let saved = center.environment
                defer { center.environment = saved; center.cancelAll() }
                center.environment.home = home
                center.environment.trash = try fakeTrash(home)
                center.record(result)
                let copies = result.rows.filter { $0.trash?.origin == .duplicate }
                await #expect(throws: ToolError.self) { _ = try await center.moveToTrash(copies) }

                // 3. Leftovers of a longer identifier are shown but not preselected.
                let app = home.appendingPathComponent("Applications/Tidy.app")
                try file(app.appendingPathComponent("Contents/Info.plist"), try PropertyListSerialization.data(fromPropertyList: [
                    "CFBundleIdentifier": "com.example.tidy", "CFBundleName": "Tidy", "CFBundlePackageType": "APPL"], format: .xml, options: 0))
                try file(home.appendingPathComponent("Library/Caches/com.example.tidy/x"), Data(count: 10))
                try file(home.appendingPathComponent("Library/Caches/com.example.tidy.canary/x"), Data(count: 10))
                try file(home.appendingPathComponent("Library/Preferences/com.example.tidy.plist"), Data("x".utf8))
                let info = try #require(DoctorUninstall.inspect(app, home: home))
                #expect(info.leftovers.first { $0.url.lastPathComponent == "com.example.tidy.canary" }?.byName == true)
                #expect(info.leftovers.filter { !$0.byName }.map(\.url.lastPathComponent).sorted() == ["com.example.tidy", "com.example.tidy.plist"])

                // 4. Editor extensions and globally installed tools aren't projects.
                let ext = home.appendingPathComponent(".vscode/extensions/some.ext")
                try file(ext.appendingPathComponent("package.json"), Data("{}".utf8))
                try file(ext.appendingPathComponent("node_modules/dep/index.js"), Data(count: 100))
                let global = home.appendingPathComponent(".nvm/versions/node/v20/lib/node_modules/tool")
                try file(global.appendingPathComponent("package.json"), Data("{}".utf8))
                try file(global.appendingPathComponent("node_modules/dep/index.js"), Data(count: 100))
                #expect(DoctorProjects.find([home], home: home, smallest: 1).found.isEmpty)
                #expect(DoctorProjects.kind(of: ext.appendingPathComponent("node_modules")) == nil)
            }
        }

        @Test func onlyRecognisedProjectFoldersAreOfferedAndMovedWhole() async throws {
            try await withDoctor {
                let home = try temporaryHome()
                defer { try? FileManager.default.removeItem(at: home) }
                let code = home.appendingPathComponent("Developer")
                try file(code.appendingPathComponent("web/package.json"), Data("{}".utf8))
                try file(code.appendingPathComponent("web/node_modules/dep/index.js"), Data(count: 300_000))
                try file(code.appendingPathComponent("web/node_modules/dep/node_modules/x/y.js"), Data(count: 10))
                try file(code.appendingPathComponent("rusty/Cargo.toml"), Data())
                try file(code.appendingPathComponent("rusty/target/debug/app"), Data(count: 200_000))
                try file(code.appendingPathComponent("photos/target/keep.jpg"), Data(count: 200_000))  // no Cargo.toml: not a build
                try file(code.appendingPathComponent("cmake/CMakeLists.txt"), Data())
                try file(code.appendingPathComponent("cmake/build/notes.txt"), Data(count: 200_000))  // no CMakeCache.txt
                let found = DoctorProjects.find([code], home: home, smallest: 1)
                #expect(Set(found.found.map { $0.url.deletingLastPathComponent().lastPathComponent + "/" + $0.url.lastPathComponent }) == ["web/node_modules", "rusty/target"])
                let result = DoctorProjects.result(found.found, cancelled: false, home: home)
                #expect(result.rows.allSatisfy { $0.trash?.mode == .folder && $0.trash?.origin == .build })
                #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Developer/photos", mode: .folder, identity: FileIdentity(device: 1, inode: 1), origin: .build)))
                #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/x/node_modules", mode: .folder, identity: FileIdentity(device: 1, inode: 1), origin: .build)))

                let center = DoctorCenter.shared
                let saved = center.environment
                defer { center.environment = saved; center.cancelAll() }
                center.environment.home = home
                center.environment.trash = try fakeTrash(home)
                center.record(result)
                // The project file went away after the search: the folder stays.
                let rust = try #require(result.rows.first { $0.title.hasPrefix("rusty") })
                try FileManager.default.removeItem(at: code.appendingPathComponent("rusty/Cargo.toml"))
                let web = try #require(result.rows.first { $0.title.hasPrefix("web") })
                let receipt = try await center.moveToTrash([rust, web])
                #expect(receipt.moved.count == 1 && receipt.failures.count == 1)
                #expect(!FileManager.default.fileExists(atPath: code.appendingPathComponent("web/node_modules").path))
                #expect(FileManager.default.fileExists(atPath: code.appendingPathComponent("web/package.json").path))
                #expect(FileManager.default.fileExists(atPath: code.appendingPathComponent("rusty/target").path))
                #expect(DoctorTrash.undo(receipt).restored == 1 && FileManager.default.fileExists(atPath: code.appendingPathComponent("web/node_modules/dep/index.js").path))
            }
        }

        @Test func uninstallFindsTheAppsOwnFilesAndRefusesAppleApps() throws {
            let home = try temporaryHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let app = home.appendingPathComponent("Applications/Tidy Notes.app")
            try file(app.appendingPathComponent("Contents/Info.plist"), try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "com.example.tidynotes", "CFBundleName": "Tidy Notes", "CFBundleShortVersionString": "2.1",
                "CFBundlePackageType": "APPL"], format: .xml, options: 0))
            try file(home.appendingPathComponent("Library/Caches/com.example.tidynotes/blob"), Data(count: 5000))
            try file(home.appendingPathComponent("Library/Preferences/com.example.tidynotes.plist"), Data("x".utf8))
            try file(home.appendingPathComponent("Library/Application Support/Tidy Notes/db"), Data(count: 1000))
            try file(home.appendingPathComponent("Library/Application Support/com.example.tidynotesextra/db"), Data(count: 10))
            try file(home.appendingPathComponent("Library/Application Support/Google/x"), Data(count: 10))
            try file(home.appendingPathComponent("Library/Containers/com.example.tidynotes/x"), Data(count: 10))
            let info = try #require(DoctorUninstall.inspect(app, home: home))
            #expect(info.bundleID == "com.example.tidynotes" && info.name == "Tidy Notes")
            let names = Set(info.leftovers.map { $0.url.lastPathComponent })
            #expect(names == ["com.example.tidynotes", "com.example.tidynotes.plist", "Tidy Notes"])
            #expect(info.leftovers.first { $0.url.lastPathComponent == "Tidy Notes" }?.byName == true)
            let result = DoctorUninstall.result(info, home: home)
            #expect(result.rows.filter { $0.trash?.origin == .leftover }.count == 3)
            #expect(!info.sharedIdentifier)
            // Another installed copy with the same identifier: its files are shown, never selected for you.
            let other = home.appendingPathComponent("Applications/Tidy Notes 2.app")
            let shared = try #require(DoctorUninstall.inspect(app, home: home, installedCopies: { _ in [app, other] }))
            #expect(shared.sharedIdentifier)
            #expect(DoctorUninstall.result(shared, home: home).rows.filter { $0.trash != nil }.allSatisfy { $0.severity == .review })
            // A dotless identifier such as "Google" is never trusted to name only this app's files.
            let odd = home.appendingPathComponent("Applications/Odd.app")
            try file(odd.appendingPathComponent("Contents/Info.plist"), try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "Google", "CFBundleName": "Odd", "CFBundlePackageType": "APPL"], format: .xml, options: 0))
            let oddInfo = try #require(DoctorUninstall.inspect(odd, home: home, installedCopies: { _ in [] }))
            #expect(oddInfo.sharedIdentifier && oddInfo.leftovers.contains { $0.url.lastPathComponent == "Google" })
            #expect(DoctorUninstall.result(oddInfo, home: home).rows.filter { $0.trash != nil }.allSatisfy { $0.severity == .review })
            #expect(DoctorUninstall.refusal(bundleID: "COM.APPLE.Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")) != nil)
            #expect(DoctorUninstall.refusal(bundleID: "com.apple.Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")) != nil)
            #expect(DoctorUninstall.refusal(bundleID: "com.example.x", url: URL(fileURLWithPath: "/Users/Shared/X.app")) != nil)
            #expect(DoctorUninstall.refusal(bundleID: "com.example.x", url: URL(fileURLWithPath: "/Applications/X.app")) == nil)
            let id = FileIdentity(device: 1, inode: 1)
            #expect(DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Caches/com.example.x", mode: .folder, identity: id, origin: .leftover)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Caches/com.apple.Safari", mode: .folder, identity: id, origin: .leftover)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Caches", mode: .folder, identity: id, origin: .leftover)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Caches/a/b", mode: .folder, identity: id, origin: .leftover)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Documents/com.example.x", mode: .folder, identity: id, origin: .leftover)))
            #expect(!DoctorTrash.isAllowed(DoctorTrashTarget(path: "~/Library/Caches/com.example.x", mode: .folder, origin: .leftover)))
            // The app itself moves only while it is the very bundle that was inspected.
            #expect(throws: ToolError.self) {
                _ = try DoctorUninstall.trashApp(app, identity: FileIdentity(device: 0, inode: 0), bundleID: info.bundleID, move: { $0 })
            }
        }
    }
}
