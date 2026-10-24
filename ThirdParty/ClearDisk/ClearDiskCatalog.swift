// Cache locations and safety texts from ClearDisk (https://github.com/bysiber/cleardisk),
// revision fb5429c4f8a2ee37340840150153a08e074fdff8. MIT License, Copyright (c) 2026 Kadir Can Ozden;
// see LICENSE and UPSTREAM.md in this folder. Data only: names, paths and texts are verbatim, with
// `\(home)` written as `~` and a stable id added for Swivel.

/// One cache folder that rebuilds itself or downloads again when it is gone.
public struct CacheEntry: Sendable, Hashable {
    public enum Section: String, Sendable {
        case app, developer
    }

    public let id: String
    /// English display name, as ClearDisk wrote it.
    public let name: String
    /// Home-relative path starting with "~/".
    public let path: String
    public let group: String?
    public let section: Section
    public let description: String
    /// What moving the folder's contents removes and keeps, and what to do first. Only app entries have these.
    public let removes: String?
    public let keeps: String?
    public let note: String?
    /// Upstream file and line the entry came from.
    public let source: String

    public init(id: String, name: String, path: String, group: String?, section: Section, description: String,
                removes: String? = nil, keeps: String? = nil, note: String? = nil, source: String) {
        self.id = id
        self.name = name
        self.path = path
        self.group = group
        self.section = section
        self.description = description
        self.removes = removes
        self.keeps = keeps
        self.note = note
        self.source = source
    }
}

public enum ClearDiskCatalog {
    // AppCacheCatalog.swift:97-106 (browserImpact, electronImpact)
    private static let browserRemoves = "Cached copies of pages, images, scripts, generated code, and media."
    private static let browserKeeps = "Cookies, logins, passwords, bookmarks, history, extensions, profiles, and open tabs."
    private static let browserNote = "Quit the browser first. The first launch and first page loads may be slower."
    private static let electronRemoves = "Only the listed HTTP, generated-code, network, or graphics cache directory."
    private static let electronKeeps = "Accounts, messages, cookies, local storage, settings, and documents."
    private static let electronNote = "Quit the app first so it can rebuild these files cleanly."

    private static func browser(_ id: String, _ name: String, _ path: String, _ description: String,
                                _ source: String) -> CacheEntry {
        CacheEntry(id: id, name: name, path: path, group: "Browsers", section: .app, description: description,
                   removes: browserRemoves, keeps: browserKeeps, note: browserNote, source: source)
    }

    private static func electron(_ id: String, _ name: String, _ path: String, _ group: String,
                                 _ description: String, _ source: String) -> CacheEntry {
        CacheEntry(id: id, name: name, path: path, group: group, section: .app, description: description,
                   removes: electronRemoves, keeps: electronKeeps, note: electronNote, source: source)
    }

    private static func developer(_ id: String, _ name: String, _ path: String, _ group: String?,
                                  _ description: String, _ source: String) -> CacheEntry {
        CacheEntry(id: id, name: name, path: path, group: group, section: .developer, description: description,
                   source: source)
    }

    public static let entries: [CacheEntry] = [
        // App caches (AppCacheCatalog.swift)
        browser("chrome-cache", "Google Chrome", "~/Library/Caches/Google/Chrome",
                "Cached Chrome web resources; browser profile data is not targeted.", "AppCacheCatalog.swift:115"),
        browser("firefox-cache", "Firefox", "~/Library/Caches/Firefox",
                "Firefox web, startup, thumbnail, and safe-browsing caches.", "AppCacheCatalog.swift:118"),
        browser("safari-cache", "Safari", "~/Library/Caches/com.apple.Safari",
                "Safari's macOS cache container; website data is stored separately.", "AppCacheCatalog.swift:121"),
        browser("edge-cache", "Microsoft Edge", "~/Library/Caches/Microsoft Edge",
                "Cached Edge web resources; browser profile data is not targeted.", "AppCacheCatalog.swift:122"),
        browser("brave-cache", "Brave", "~/Library/Caches/BraveSoftware/Brave-Browser",
                "Cached Brave web resources; browser profile data is not targeted.", "AppCacheCatalog.swift:125"),
        browser("arc-cache", "Arc", "~/Library/Caches/company.thebrowser.Browser",
                "Arc's macOS cache container; spaces and profiles are not targeted.", "AppCacheCatalog.swift:128"),
        electron("discord-web-cache", "Discord Web Cache", "~/Library/Application Support/discord/Cache",
                 "Communication", "Discord HTTP cache only.", "AppCacheCatalog.swift:134"),
        electron("discord-code-cache", "Discord Code Cache", "~/Library/Application Support/discord/Code Cache",
                 "Communication", "Generated JavaScript and WebAssembly cache only.", "AppCacheCatalog.swift:135"),
        electron("slack-web-cache", "Slack Web Cache", "~/Library/Application Support/Slack/Cache",
                 "Communication", "Slack HTTP cache only.", "AppCacheCatalog.swift:138"),
        electron("slack-code-cache", "Slack Code Cache", "~/Library/Application Support/Slack/Code Cache",
                 "Communication", "Slack generated-code cache only.", "AppCacheCatalog.swift:139"),
        CacheEntry(id: "spotify-cache", name: "Spotify", path: "~/Library/Caches/com.spotify.client",
                   group: "Media & Games", section: .app,
                   description: "Streamed music and podcast cache; offline downloads are stored separately.",
                   removes: "Previously streamed temporary audio and artwork.",
                   keeps: "Your account, playlists, local files, and explicitly downloaded offline library.",
                   note: "Quit Spotify first. Streamed content may use bandwidth again.",
                   source: "AppCacheCatalog.swift:150"),
        electron("steam-web-cache", "Steam Web Cache", "~/Library/Caches/Steam/config/htmlcache",
                 "Media & Games", "Steam store, community, and library web-interface cache.",
                 "AppCacheCatalog.swift:153"),
        electron("steam-legacy-web-cache", "Steam Legacy Web Cache",
                 "~/Library/Application Support/Steam/config/htmlcache",
                 "Media & Games", "Steam's alternate web-interface cache location.", "AppCacheCatalog.swift:154"),
        CacheEntry(id: "raycast-web-cache", name: "Raycast Web Cache", path: "~/Library/Caches/com.raycast.macos/urlcache",
                   group: "Productivity", section: .app,
                   description: "Raycast Store and API response cache. Clipboard history is explicitly excluded.",
                   removes: "Raycast Store, API, and web-response cache.",
                   keeps: "Clipboard history, extensions, preferences, snippets, and account data.",
                   note: "Quit Raycast first. ClearDisk never targets the sibling Clipboard folder.",
                   source: "AppCacheCatalog.swift:158"),
        electron("obsidian-web-cache", "Obsidian Web Cache", "~/Library/Application Support/obsidian/Cache",
                 "Productivity", "Obsidian HTTP cache only; vaults and metadata storage are not targeted.",
                 "AppCacheCatalog.swift:159"),
        electron("obsidian-code-cache", "Obsidian Code Cache", "~/Library/Application Support/obsidian/Code Cache",
                 "Productivity", "Obsidian generated-code cache only.", "AppCacheCatalog.swift:160"),
        electron("notion-web-cache", "Notion Web Cache", "~/Library/Application Support/Notion/Cache",
                 "Productivity", "Notion HTTP cache only.", "AppCacheCatalog.swift:162"),
        electron("notion-code-cache", "Notion Code Cache", "~/Library/Application Support/Notion/Code Cache",
                 "Productivity", "Notion generated-code cache only.", "AppCacheCatalog.swift:163"),
        electron("github-desktop-web-cache", "GitHub Desktop Web Cache",
                 "~/Library/Application Support/GitHub Desktop/Cache",
                 "Productivity", "GitHub Desktop HTTP cache only; repositories are not targeted.",
                 "AppCacheCatalog.swift:165"),
        electron("codex-web-cache", "Codex Web Cache", "~/Library/Caches/Codex/Default/Cache",
                 "Productivity", "Codex HTTP cache only; task and account data are not targeted.",
                 "AppCacheCatalog.swift:166"),
        CacheEntry(id: "codex-browser-cache", name: "Codex Browser Cache",
                   path: "~/Library/Caches/Codex/Default/Partitions/codex-browser-app/Cache",
                   group: "Productivity", section: .app,
                   description: "HTTP cache for Codex's isolated browser partition.",
                   removes: "Cached browser responses used by Codex.",
                   keeps: "Codex tasks, accounts, settings, browser cookies, and downloaded files.",
                   note: "Quit Codex first. Browser content may load more slowly once while the cache rebuilds.",
                   source: "AppCacheCatalog.swift:167"),

        // Developer caches (DiskMonitor.swift: paths from allCachePaths(), descriptions from cacheDescriptions)
        developer("xcode-derived-data", "Xcode DerivedData", "~/Library/Developer/Xcode/DerivedData", "Xcode",
                  "Build products, indexes, and logs. Rebuilds automatically when you open a project.",
                  "DiskMonitor.swift:656, 514"),
        developer("xcode-device-support", "Xcode Device Support", "~/Library/Developer/Xcode/iOS DeviceSupport", "Xcode",
                  "Debug symbols for connected iPhones/iPads. Re-downloads when device connects.",
                  "DiskMonitor.swift:660, 518"),
        developer("coresimulator-logs", "Xcode Logs", "~/Library/Logs/CoreSimulator", "Xcode",
                  "Simulator crash reports and diagnostic logs. Safe to remove anytime.", "DiskMonitor.swift:661, 519"),
        developer("xcode-previews", "Xcode Previews", "~/Library/Developer/Xcode/UserData/Previews", "Xcode",
                  "SwiftUI preview simulator data. Rebuilds automatically on next preview.", "DiskMonitor.swift:662, 520"),
        developer("coresimulator-caches", "Simulator Caches", "~/Library/Developer/CoreSimulator/Caches", "Xcode",
                  "CoreSimulator dyld and framework caches. Rebuilds automatically.", "DiskMonitor.swift:663, 521"),
        developer("swiftpm-cache", "Swift PM Cache", "~/Library/Caches/org.swift.swiftpm", "Xcode",
                  "Downloaded Swift packages. Re-downloads on next build (swift build).", "DiskMonitor.swift:664, 522"),
        developer("cocoapods-cache", "CocoaPods Cache", "~/Library/Caches/CocoaPods", nil,
                  "Downloaded pod specs and sources. Re-downloads on pod install.", "DiskMonitor.swift:666, 523"),
        developer("homebrew-cache", "Homebrew Cache", "~/Library/Caches/Homebrew", nil,
                  "Downloaded formula bottles and taps. Re-downloads on brew install.", "DiskMonitor.swift:669, 525"),
        developer("npm-cache", "npm Cache", "~/.npm/_cacache", nil,
                  "Cached package tarballs from npmjs.org. Re-downloads on npm install.", "DiskMonitor.swift:671, 526"),
        developer("yarn-cache", "Yarn Cache", "~/Library/Caches/Yarn", nil,
                  "Cached Yarn packages. Re-downloads on yarn install.", "DiskMonitor.swift:672, 527"),
        developer("node-gyp-headers", "node-gyp Headers", "~/Library/Caches/node-gyp", nil,
                  "Node.js headers and libraries, one set per Node version, used to compile native addons. "
                    + "Re-downloads on the next native build.", "DiskMonitor.swift:678, 530"),
        developer("typescript-types", "TypeScript Types", "~/Library/Caches/typescript", nil,
                  "Type definitions fetched automatically for JavaScript files (VS Code automatic type acquisition). "
                    + "Re-downloads when needed.", "DiskMonitor.swift:679, 531"),
        developer("bun-cache", "Bun Cache", "~/.bun/install/cache", nil,
                  "Cached Bun packages. Re-downloads on bun install.", "DiskMonitor.swift:680, 532"),
        developer("pip-cache", "pip Cache", "~/Library/Caches/pip", nil,
                  "Downloaded Python wheels and sdists. Re-downloads on pip install.", "DiskMonitor.swift:683, 534"),
        developer("uv-cache", "UV Cache", "~/.cache/uv", nil,
                  "Cached Python packages from uv (fast pip alternative). Re-downloads on uv pip install.",
                  "DiskMonitor.swift:685, 535"),
        developer("gradle-caches", "Gradle Cache", "~/.gradle/caches", nil,
                  "Downloaded JARs, build outputs, and wrapper dists. Re-downloads on gradle build.",
                  "DiskMonitor.swift:689, 539"),
        developer("gradle-wrapper", "Gradle Wrapper", "~/.gradle/wrapper/dists", nil,
                  "Gradle distribution binaries downloaded by wrapper scripts. Re-downloads on next gradle build.",
                  "DiskMonitor.swift:784, 589"),
        developer("go-build-cache", "Go Build Cache", "~/Library/Caches/go-build", nil,
                  "Compiled package objects that make rebuilds fast (GOCACHE). Rebuilds itself — the first build after "
                    + "clearing is slower. Equivalent to go clean -cache.", "DiskMonitor.swift:715, 549"),
        developer("go-module-cache", "Go Modules", "~/go/pkg/mod/cache", nil,
                  "Go module download cache. Re-downloads on go mod download.", "DiskMonitor.swift:714, 548"),
        developer("cargo-registry", "Rust Cargo", "~/.cargo/registry", nil,
                  "Cached crate sources and registries. Re-downloads on cargo build.", "DiskMonitor.swift:716, 550"),
        developer("playwright-browsers", "Playwright Browsers", "~/Library/Caches/ms-playwright", nil,
                  "Downloaded browser binaries for Playwright testing. Re-downloads on npx playwright install.",
                  "DiskMonitor.swift:718, 552"),
        developer("vscode-cache", "VS Code Cache", "~/Library/Caches/com.microsoft.VSCode", "VS Code",
                  "VS Code application cache. Safe to delete, rebuilds automatically.", "DiskMonitor.swift:737, 594"),
        developer("vscode-cached-data", "VS Code Data", "~/Library/Application Support/Code/CachedData", "VS Code",
                  "VS Code compiled JavaScript cache. Safe to delete, recompiles on launch.", "DiskMonitor.swift:738, 595"),
        developer("vscode-extension-vsix-cache", "VS Code Extensions Cache",
                  "~/Library/Application Support/Code/CachedExtensionVSIXs", "VS Code",
                  "Downloaded extension VSIX packages. Safe to delete, re-downloads when needed.",
                  "DiskMonitor.swift:739, 596"),
        developer("vscode-chromium-cache", "VS Code Chromium Cache", "~/Library/Application Support/Code/Cache", "VS Code",
                  "Chromium disk cache used by VS Code. Safe to delete, rebuilds on launch.", "DiskMonitor.swift:740, 597"),
    ]
}
