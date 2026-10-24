import AppKit
import UniformTypeIdentifiers

struct FileAppTarget: Codable, Equatable, Identifiable, Sendable {
    enum Delivery: String, Codable, CaseIterable, Sendable {
        case openFiles, codexDraft, claudeCodeDraft, copyFiles, copyAndOpenPage
        var title: String {
            switch self {
            case .openFiles: L("Open files")
            case .codexDraft: L("Codex draft")
            case .claudeCodeDraft: L("Claude Code draft")
            case .copyFiles: L("Copy files and open app")
            case .copyAndOpenPage: L("Copy files and open page")
            }
        }
        /// What an application can be given. A web page always gets `copyAndOpenPage`.
        static let forApplications: [Self] = [.openFiles, .codexDraft, .claudeCodeDraft, .copyFiles]
    }
    let id: String
    var name: String
    var bundleID: String
    var appPath: String
    var delivery: Delivery
    var extensions: [String] = []
    var enabled: Bool = true
    /// Set for a web page: the address the browser opens (`bundleID`/`appPath` name a browser, or are empty for the
    /// default one). Optional, so targets saved before web pages existed still decode.
    var webAddress: String?
    var actionID: String { "app." + id }
    var isWebPage: Bool { webAddress != nil }
    var pageURL: URL? { webAddress.flatMap(Self.pageURL(from:)) }
    var isValid: Bool {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else { return false }
        return isWebPage ? pageURL != nil && delivery == .copyAndOpenPage : delivery != .copyAndOpenPage
    }
    func accepts(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { $0.isFileURL && (extensions.isEmpty || extensions.contains($0.pathExtension.lowercased())) }
    }
    static let starters: [Self] = [
        Self(id: "codex", name: "Codex", bundleID: "", appPath: "", delivery: .codexDraft),
        Self(id: "claude-code", name: "Claude Code", bundleID: "com.anthropic.claudefordesktop", appPath: "", delivery: .claudeCodeDraft),
    ]
    /// The page for a typed address, or nil. A bare "example.com" means https. Only https, or http to this Mac or the
    /// local network (a NAS, a dev server); no credentials, spaces or hidden characters. Swivel never adds anything
    /// about the files to it: the files go to the clipboard, and the user pastes them on the page.
    static func pageURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2048,
              !text.unicodeScalars.contains(where: { $0.properties.isWhitespace || AssistantDraft.isHidden($0) }) else { return nil }
        // A scheme only counts at the start: "example.com/up?next=https://x" is still a bare address.
        if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) == nil { text = "https://" + text }
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil, let url = parts.url else { return nil }
        // A percent-escape in the host ("%2F", "%23", "%00") decodes to something else than what a browser connects to.
        guard !(parts.encodedHost ?? parts.percentEncodedHost ?? "%").contains("%") else { return nil }
        switch scheme {
        case "https": return url
        case "http": return isLocal(host) ? url : nil
        default: return nil
        }
    }

    /// This Mac, a Bonjour name or a private IPv4 address.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host == "[::1]" || host == "::1" { return true }
        // Canonical decimal only: browsers read "010" or "0127" as octal (and "+127" isn't an octet), so those could
        // name a public address.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.map { part -> Int? in
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), part == "0" || !part.hasPrefix("0") else { return nil }
            return Int(part)
        }
        guard octets.count == 4, octets.allSatisfy({ $0.map { (0...255).contains($0) } ?? false }) else { return false }
        let a = octets[0]!, b = octets[1]!
        return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
    }

    /// The host shown for a page ("www." dropped), used as its default name.
    var pageHost: String {
        guard let host = pageURL?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func normalizedExtensions(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased().split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }.filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } && seen.insert($0).inserted }
    }
}

enum AssistantDraft {
    static func referenceText(_ urls: [URL]) -> String {
        // JSON strings keep quotes, newlines and unusual names unambiguous. File content is never read here.
        L("Selected local files:") + "\n" + urls.map { "- " + visibleJSONString($0.path) }.joined(separator: "\n")
    }

    /// A JSON string literal that decodes to exactly `text`, with every character a reviewer couldn't see written as
    /// a `\u` escape: controls, format characters (bidi overrides, zero-width, tag characters), variation selectors,
    /// private-use and unassigned code points. A file name can't hide instructions in a draft this way.
    static func visibleJSONString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                guard isHidden(scalar) else { out.unicodeScalars.append(scalar); continue }
                for unit in String(scalar).utf16 { out += String(format: "\\u%04X", unit) }
            }
        }
        return out + "\""
    }

    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        let p = scalar.properties
        switch p.generalCategory {
        case .control, .format, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .surrogate: return true
        case .spaceSeparator: return scalar != " "  // no-break, ideographic and other spaces look like gaps
        default:
            // Letters that render as nothing: Braille blank, Hangul fillers, musical null notehead.
            let blanks: Set<UInt32> = [0x2800, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x1D159]
            return blanks.contains(scalar.value) || p.isDefaultIgnorableCodePoint || p.isVariationSelector || p.isNoncharacterCodePoint
        }
    }
    /// A folder specific enough to hand an assistant as its workspace, after resolving links: a project in the home
    /// folder (~/myrepo, ~/Desktop/Project, but not ~/Desktop, ~/Documents or anything in ~/Library), a folder in iCloud
    /// Drive or another cloud drive, a folder inside a volume or another user's home (/Volumes/Disk/Project), or one
    /// two levels below the root elsewhere (/tmp/notes). Never /, a top-level folder, a volume or the home folder.
    static func isNarrowWorkspace(_ directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let parts = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let homeParts = home.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if parts.starts(with: homeParts) {
            let inside = Array(parts.dropFirst(homeParts.count))
            // Cloud drives count as a home of their own: iCloud Drive's root, or a provider's folder, is too broad.
            if inside.starts(with: ["Library", "Mobile Documents", "com~apple~CloudDocs"]) { return inside.count >= 4 }
            // Google Drive keeps its roots one level down ("GoogleDrive-…/My Drive", "…/Shared drives").
            if inside.starts(with: ["Library", "CloudStorage"]) {
                return inside.count >= (inside.count > 2 && inside[2].hasPrefix("GoogleDrive-") ? 5 : 4)
            }
            guard let top = inside.first, top != "Library" else { return false }
            if top.hasPrefix(".") { return inside.count >= 2 && !["ssh", "aws", "gnupg", "Trash"].contains(String(top.dropFirst())) }
            let shared = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications", "Sites"]
            return inside.count >= (shared.contains(top) ? 2 : 1)
        }
        if homeParts.starts(with: parts) { return false }  // The home folder or above it.
        let roots = ["Volumes", "Users", "System", "Library", "Applications", "private"]
        return parts.count >= (parts.count > 1 && roots.contains(parts[1]) ? 4 : 3)
    }

    static func url(for delivery: FileAppTarget.Delivery, files: [URL]) throws -> URL {
        guard !files.isEmpty, files.allSatisfy(\.isFileURL), [.codexDraft, .claudeCodeDraft].contains(delivery) else {
            throw ToolError(L("Choose files for this draft."))
        }
        let text = referenceText(files)
        guard text.utf8.count <= 12000 else { throw ToolError(L("Too many file paths for one draft. Choose fewer files.")) }
        var components = URLComponents()
        components.scheme = delivery == .codexDraft ? "codex" : "claude"
        components.host = delivery == .codexDraft ? "threads" : "code"
        components.path = "/new"
        // Use an explicit workspace only when all files are in the same directory. No broad common-root grant.
        let directories = Set(files.map { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent()
        })
        components.queryItems = [URLQueryItem(name: delivery == .codexDraft ? "prompt" : "q", value: text)]
        if directories.count == 1, let directory = directories.first, isNarrowWorkspace(directory) {
            components.queryItems?.append(URLQueryItem(name: delivery == .codexDraft ? "path" : "folder", value: directory.path))
        }
        // URLComponents leaves "+" alone, but both apps decode queries as forms, where "+" means a space: a folder
        // such as "C++ notes" would otherwise arrive as "C   notes".
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ToolError(L("Could not prepare the draft.")) }
        return url
    }
}

@MainActor
enum FileAppRouting {
    private static func supports(_ url: URL, delivery: FileAppTarget.Delivery) -> Bool {
        guard let bundle = Bundle(url: url), url.pathExtension == "app" else { return false }
        guard [.codexDraft, .claudeCodeDraft].contains(delivery) else { return true }
        let scheme = delivery == .codexDraft ? "codex" : "claude"
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains(scheme) }
    }
    static func application(for target: FileAppTarget) -> URL? {
        if !target.appPath.isEmpty, let bundle = Bundle(url: URL(fileURLWithPath: target.appPath)),
           supports(bundle.bundleURL, delivery: target.delivery), bundle.bundleIdentifier == target.bundleID { return bundle.bundleURL }
        if !target.bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID), supports(url, delivery: target.delivery) { return url }
        guard target.appPath.isEmpty else { return nil }
        // A web page with no browser chosen opens in the default one.
        if target.isWebPage { return target.pageURL.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } }
        let scheme = target.delivery == .codexDraft ? "codex://threads/new" : target.delivery == .claudeCodeDraft ? "claude://code/new" : ""
        return URL(string: scheme).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    static func run(_ target: FileAppTarget, files: [URL], pasteboard: NSPasteboard = .general,
                    open: (([URL], URL) async throws -> Void)? = nil) async throws -> ActionResult {
        guard Feature.appRouting.isOn, target.enabled, Prefs.fileAppTargets.contains(target), target.accepts(files) else {
            throw ToolError(L("This app action is unavailable or turned off."))
        }
        for file in files { _ = try FileIdentity.read(file) }
        guard let application = application(for: target) else {
            throw ToolError(target.isWebPage ? L("The browser for %@ is not installed. Choose another in App Actions.", target.name)
                                             : L("%@ is not installed. Choose its application in App Actions.", target.name))
        }
        let urls: [URL]
        switch target.delivery {
        case .codexDraft, .claudeCodeDraft: urls = [try AssistantDraft.url(for: target.delivery, files: files)]
        case .copyFiles: urls = []
        case .openFiles: urls = files
        case .copyAndOpenPage:
            guard let page = target.pageURL else { throw ToolError(L("This web address isn’t valid. Edit it in App Actions.")) }
            urls = [page]
        }
        let opener = open ?? openWithWorkspace
        try await opener(urls, application)
        if target.delivery == .copyFiles {
            pasteboard.clearContents()
            guard pasteboard.writeObjects(files as [NSURL]) else { throw ToolError(L("Could not copy the selected files.")) }
        }
        if target.delivery == .copyAndOpenPage {
            // Web pages paste pictures, not Finder files, so images also carry their own bytes (one item each).
            pasteboard.clearContents()
            guard pasteboard.writeObjects(Clothesline.pasteboardItems(for: files)) else { throw ToolError(L("Could not copy the selected files.")) }
            // A page can't be handed files through its address; the card lets the user drop them into it.
            if open == nil { HandoffCard.shared.show(files, page: target.name) }
        }
        let message: String
        switch target.delivery {
        case .codexDraft, .claudeCodeDraft: message = L("Opened %@ draft with file references. Review and send there.", target.name)
        case .copyFiles: message = L("Files copied. Paste them in %@.", target.name)
        case .copyAndOpenPage: message = L("Drag the files from the card into %@, or paste them there with ⌘V.", target.name)
        case .openFiles: message = L("Opened files in %@", target.name)
        }
        return ActionResult(message: message)
    }

    private static func openWithWorkspace(_ urls: [URL], _ app: URL) async throws {
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if urls.isEmpty {
                NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            } else {
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
    }
}

/// After a web page opens: the files on a small floating card, to drag into the page (an upload box, a Gmail
/// message). Dropping is the user's own act, so no permission is needed; the card closes once they're dropped.
@MainActor
final class HandoffCard: NSObject, NSWindowDelegate {
    static let shared = HandoffCard()
    private var panel: ToolPanel?

    func show(_ files: [URL], page: String) {
        close()
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                              styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = page
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true; panel.delegate = self
        let source = HandoffDragView(files) { [weak self] dropped in if dropped { self?.close() } }
        let note = ToolUI.note("Drag into the page to attach, or press ⌘V there.")
        note.alignment = .center; note.preferredMaxLayoutWidth = 260
        let root = ToolUI.stack([source, note], spacing: 8); root.alignment = .centerX
        source.widthAnchor.constraint(equalToConstant: 260).isActive = true
        source.heightAnchor.constraint(equalToConstant: 64).isActive = true
        panel.contentView = NSView(); ToolUI.embed(root, in: panel.contentView!, inset: 14)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 20, y: area.minY + 20))
        }
        self.panel = panel
        ToolUI.present(panel, focus: false)
        ToolUI.fadeIn(root)
    }

    func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) { if (notification.object as? NSPanel) === panel { panel = nil } }
}

/// The files as one draggable tile: their icon and name (or count).
final class HandoffDragView: NSView, NSDraggingSource {
    private let files: [URL]
    private let ended: (Bool) -> Void
    private var start: NSPoint?

    init(_ files: [URL], ended: @escaping (Bool) -> Void) {
        self.files = files; self.ended = ended
        super.init(frame: .zero)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFiles: files.map(\.path)) ?? NSWorkspace.shared.icon(forFile: files[0].path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: files.count == 1 ? files[0].lastPathComponent : L("%d files", files.count))
        name.lineBreakMode = .byTruncatingMiddle; name.font = .systemFont(ofSize: 13, weight: .medium)
        for view in [icon, name] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 44), icon.heightAnchor.constraint(equalToConstant: 44),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
        setAccessibilityRole(.button); setAccessibilityLabel(name.stringValue)
        toolTip = L("Drag into the page to attach, or press ⌘V there.")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let start, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 else { return }
        self.start = nil
        let icon = NSWorkspace.shared.icon(forFile: files[0].path)
        let items = files.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: 10 + CGFloat(index) * 4, y: 10 - CGFloat(index) * 4, width: 44, height: 44), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { ended(operation != []) }
}
