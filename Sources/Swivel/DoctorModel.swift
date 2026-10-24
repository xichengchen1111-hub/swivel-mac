import AppKit
import ServiceManagement

/// The areas Mac Doctor checks, in the order the window lists them: the summary, then by symptom.
enum DoctorSection: String, CaseIterable, Sendable {
    case summary, storage, caches, folders, duplicates, projects, performance, app, uninstall, drives, network, background, power

    /// English; translated where shown.
    var title: String {
        switch self {
        case .summary: "Summary"
        case .storage: "Storage"
        case .caches: "Caches"
        case .folders: "Folder Sizes"
        case .duplicates: "Duplicate Files"
        case .projects: "Project Builds"
        case .uninstall: "Uninstall Apps"
        case .performance: "Slow or Hot"
        case .app: "Apps That Won’t Open"
        case .drives: "External Drives"
        case .network: "Network"
        case .background: "Background Items"
        case .power: "Battery & Sleep"
        }
    }

    var symbol: String {
        switch self {
        case .summary: "stethoscope"
        case .storage: "internaldrive"
        case .caches: "archivebox"
        case .folders: "folder"
        case .duplicates: "doc.on.doc"
        case .projects: "hammer"
        case .uninstall: "trash.square"
        case .performance: "gauge.with.dots.needle.67percent"
        case .app: "app.badge.checkmark"
        case .drives: "externaldrive"
        case .network: "network"
        case .background: "gearshape.2"
        case .power: "battery.75percent"
        }
    }

    /// What the section checks and what it never does. English; translated where shown.
    var explanation: String {
        switch self {
        case .summary:
            "Mac Doctor only reads. It needs no new permissions, and nothing changes until you choose a fix and confirm it. Only Test Speed, App Check and Ask the Assistant use the network."
        case .storage:
            "How full the startup disk is, how much macOS can free by itself (purgeable space), and the local Time Machine snapshots that often make “System Data” look large. Find Large Files lists big files and installers in Downloads, Desktop and Documents for you to choose from."
        case .caches:
            "Caches that apps rebuild by themselves. They go to the Trash, and you can put them back."
        case .folders:
            "How much space a folder you choose uses, and which items inside it are largest. Mac Doctor only reads sizes; use Finder to decide what to remove. Folders are not remembered."
        case .duplicates:
            "Files with exactly the same content, and files that are nearly the same (similar photos, edited copies of a text), with how alike they are. Mac Doctor compares content, not names, and always keeps at least one of each."
        case .projects:
            "Folders that build tools recreate by themselves (node_modules, Rust target, Swift .build, Gradle build and others) in a folder you choose. Each is recognised by the project file next to it."
        case .uninstall:
            "Remove an app together with the caches, settings and support files it left in your Library. Everything goes to the Trash and can be put back."
        case .performance:
            "Which apps use the most memory and processor, and whether the Mac is short of memory or too hot."
        case .app:
            "Why an app says it is damaged or can’t be opened: its signature, Gatekeeper’s verdict and the “downloaded from the internet” flag. Gatekeeper may ask Apple whether the app is notarized. This is not a malware scan."
        case .drives:
            "Connected drives, their format, whether macOS can write to them, and drives that are connected but not mounted. File names on the drives are never read."
        case .network:
            "Which DNS servers your Mac uses and whether a proxy app is active. Test Speed runs Apple’s network quality test, which sends test traffic to Apple for about 20 seconds."
        case .background:
            "Small programs that run by themselves after your Mac starts, and ones left behind by apps you removed."
        case .power:
            "Battery health, and which apps are keeping your Mac or its display awake right now."
        }
    }

    /// The checks "Check This Mac" runs: everything that reads only this Mac and needs nothing chosen.
    var runsWithAll: Bool { ![.summary, .app, .folders, .duplicates, .projects, .uninstall].contains(self) }

    /// Sections that look only at folders or an app the user picks.
    var needsChoice: Bool { [.app, .folders, .duplicates, .projects, .uninstall].contains(self) }
}

/// How much a result asks for attention. Shown as a symbol and a word, never colour alone.
enum DoctorSeverity: Int, Comparable, Sendable {
    case ok, info, review, problem

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle"
        case .info: "info.circle"
        case .review: "exclamationmark.circle"
        case .problem: "exclamationmark.triangle"
        }
    }

    var tint: NSColor {
        switch self {
        case .ok: .systemGreen
        case .info: .secondaryLabelColor
        case .review: .systemOrange
        case .problem: .systemRed
        }
    }

    /// English; translated where shown.
    var word: String {
        switch self {
        case .ok: "Normal"
        case .info: "Info"
        case .review: "Worth a look"
        case .problem: "Problem"
        }
    }
}

/// A System Settings pane a fix can open. IDs checked against /System/Library/ExtensionKit on macOS 26.
enum DoctorSettingsPane: String, Sendable {
    case storage = "com.apple.settings.Storage"
    case loginItems = "com.apple.LoginItems-Settings.extension"
    case privacy = "com.apple.settings.PrivacySecurity.extension"
    case network = "com.apple.Network-Settings.extension"
    case wifi = "com.apple.wifi-settings-extension"
    case battery = "com.apple.Battery-Settings.extension"
    case lockScreen = "com.apple.Lock-Screen-Settings.extension"
    case timeMachine = "com.apple.Time-Machine-Settings.extension"

    var url: URL { URL(string: "x-apple.systempreferences:" + rawValue)! }

    /// Button title, English; translated where shown.
    var buttonTitle: String {
        switch self {
        case .storage: "Open Storage Settings"
        case .loginItems: "Open Login Items Settings"
        case .privacy: "Open Privacy & Security"
        case .network: "Open Network Settings"
        case .wifi: "Open Wi-Fi Settings"
        case .battery: DoctorBattery.hasBattery ? "Open Battery Settings" : "Open Energy Settings"
        case .lockScreen: "Open Lock Screen Settings"
        case .timeMachine: "Open Time Machine Settings"
        }
    }

    /// Opens the pane; Login Items through its public API, the others by their settings URL.
    @MainActor func open() {
        if self == .loginItems { SMAppService.openSystemSettingsLoginItems(); return }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }
}

/// One line in a section's results.
struct DoctorRow: Sendable, Identifiable {
    let id: String
    /// Shown as is: either already translated or data from the Mac (a label, a process name) that must not be
    /// passed through `L()`.
    var title: String
    var value: String
    var detail: String
    var severity: DoctorSeverity
    var bytes: Int64?
    /// Reveal in Finder.
    var location: URL?
    /// Set when the row can be moved to the Trash: "~/…" and how.
    var trash: DoctorTrashTarget?
    /// Apps that must be quit before the row can be moved to the Trash.
    var bundleIDs: [String] = []
    /// Set when the row is a running app that may be asked to quit.
    var quit: DoctorQuitTarget?
    /// Rows that belong together (copies of one file); a group always keeps at least one.
    var group: String?
    /// 1 for an item listed under the row above it.
    var level = 0
    /// For a drive: the physical disk it is on; volumes on the same disk eject together.
    var disk: String?
}

struct DoctorTrashTarget: Sendable, Equatable {
    let path: String
    let mode: DoctorTrashPlan.Mode
    /// For a single file: the file as it was when the check ran. A different file in its place is never moved.
    var identity: FileIdentity? = nil
    /// Which check offered it; each has its own narrow rule in `DoctorTrash.isAllowed`.
    var origin: Origin = .standard

    enum Origin: Sendable, Equatable {
        /// Catalogue caches, leftover launch agents, files from the large-file search.
        case standard
        /// A copy from the duplicate search; another identical copy must stay.
        case duplicate
        /// A nearly identical file from the duplicate search; another file of its group must stay.
        case similar
        /// A project's rebuildable folder (node_modules, target, .build…).
        case build
        /// A removed app's file or folder in ~/Library.
        case leftover
    }
}

/// What one section found.
struct DoctorResult: Sendable {
    var section: DoctorSection
    var severity: DoctorSeverity
    /// A few words for the sidebar, e.g. "12.4 GB" or "2 to review".
    var badge: String
    /// One or two sentences, already translated.
    var headline: String
    var rows: [DoctorRow] = []
    var notes: [String] = []
    var panes: [DoctorSettingsPane] = []
    var adminCommands: [DoctorAdminCommand] = []
    /// The commands that ran, for the details.
    var ran: [String] = []
    /// Facts for the assistant: numbers, states and counts in translated sentences. Never names of any kind.
    var report: [String] = []
    /// Names the user may choose to include (catalogue entries, apps, labels), already reduced to plain identifiers.
    var names: [String] = []
    /// The latest speed test's facts, kept apart so a fresh DNS check doesn't drop them.
    var speedReport: [String] = []
    /// Folder Sizes: one space map per chosen folder.
    var maps: [DoctorSpaceNode] = []
    var checked = Date()
}

/// Everything the checks touch outside their own code, so tests can replace it.
struct DoctorEnvironment: Sendable {
    var home: URL
    var run: @Sendable (DoctorCommand) async throws -> DoctorOutput
    var trash: DoctorTrash.Mover
    var power: @Sendable () -> [DoctorPower.Assertion]
    var volume: @Sendable (URL) -> DoctorStorage.Space?

    static let live = DoctorEnvironment(
        home: FileManager.default.homeDirectoryForCurrentUser,
        run: { try await Shell.capture($0) },
        trash: DoctorTrash.systemTrash,
        power: { DoctorPower.assertions() },
        volume: { DoctorStorage.space(of: $0) })
}

enum DoctorFormat {
    /// "1.2 GB" (decimal units, as Finder shows them).
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    /// "16 GB" for memory (binary units, as Activity Monitor shows them).
    static func memory(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: count)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Language.resolved == .en ? "en" : Language.resolved.rawValue)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "~/Library/Caches/…" for paths inside the home folder.
    static func path(_ url: URL) -> String { DoctorTrash.displayPath(url) }
}
