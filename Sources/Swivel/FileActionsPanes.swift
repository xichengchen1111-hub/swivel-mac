import AppKit
import UniformTypeIdentifiers

final class FileActionsPane: Pane {
    private let feature: Feature
    private var chooseButton: NSButton!
    private var libraryButton: NSButton?
    init(_ feature: Feature) { self.feature = feature; super.init(size: NSSize(width: 760, height: 370)) }
    required init?(coder: NSCoder) { fatalError() }
    override func build() {
        let description: String
        switch feature {
        case .batchRename: description = "Combine a base name, text replacement, prefix, suffix and numbering. Review the full preview and conflicts before changing names. Undo remains available while the rename window is open."
        case .pdfPages: description = "Select page ranges, drag thumbnails to change order, rotate or remove pages, then export selected pages or save all. The original PDFs are kept."
        default: description = "Choose images to read QR codes and barcodes locally. Copy the decoded content, or review a web link before opening it. No camera or screen capture is used."
        }
        stack.addArrangedSubview(label(feature.title, size: 17, weight: .semibold))
        stack.addArrangedSubview(label(description, secondary: true))
        chooseButton = ToolUI.button("Choose Files…", target: self, action: #selector(choose))
        stack.addArrangedSubview(chooseButton)
        if feature == .qrCodes {
            let button = ToolUI.button("QR Library…", target: self, action: #selector(openLibrary))
            libraryButton = button; stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(label(feature == .batchRename ? "Also available in the Wheel’s Actions menu and Quick Actions." : "Also available in the Wheel’s Tools menu and Quick Actions.", size: 12, secondary: true))
        stack.addArrangedSubview(label("Turn this feature on above to get started.", size: 11, secondary: true))
    }
    override func refresh() { chooseButton?.isEnabled = feature.isOn; libraryButton?.isEnabled = feature.isOn }
    @objc private func choose() { Self.chooseAndOpen(feature) }
    @objc private func openLibrary() { QRLibraryWindow().show() }
    @MainActor static func chooseAndOpen(_ feature: Feature) {
        guard feature.isOn else { return }
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = true; picker.canChooseDirectories = feature == .batchRename
        picker.prompt = L("Choose")
        if feature == .pdfPages { picker.allowedContentTypes = [.pdf] }
        if feature == .qrCodes { picker.allowedContentTypes = [.image] }
        NSApp.activate()
        guard picker.runModal() == .OK, feature.isOn else { return }
        switch feature {
        case .batchRename: BatchRenameWindow(picker.urls).show()
        case .pdfPages: PDFPagesWindow(picker.urls).show()
        case .qrCodes: QRCodesWindow(picker.urls).show()
        default: break
        }
    }
}

final class AppActionsPane: Pane, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    private var targets: [FileAppTarget] = []
    private var editButton: NSButton!, removeButton: NSButton!
    private var editor: AppTargetEditor?
    init() { super.init(size: NSSize(width: 790, height: 610)) }
    required init?(coder: NSCoder) { fatalError() }
    override func build() {
        stack.addArrangedSubview(label("Your files, your apps", size: 17, weight: .semibold))
        stack.addArrangedSubview(label("Choose which apps and web pages appear in the Apps wheel. Add as many as you like, such as Word, Mail, Photoshop or an upload page, and optionally limit their file extensions.", secondary: true))
        for (id, title, width) in [("enabled", "On", 45.0), ("app", "App or Web Page", 210.0), ("delivery", "Delivery", 215.0), ("types", "File extensions", 160.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = L(title); column.width = width; table.addTableColumn(column)
        }
        table.style = .inset; table.rowHeight = 44; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(editTarget)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.widthAnchor.constraint(equalToConstant: 720).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
        stack.addArrangedSubview(scroll)
        let add = ToolUI.button("Add Application…", target: self, action: #selector(addTarget))
        let addPage = ToolUI.button("Add Web Page…", target: self, action: #selector(addPage))
        editButton = ToolUI.button("Edit…", target: self, action: #selector(editTarget))
        removeButton = ToolUI.button("Remove", target: self, action: #selector(removeTarget))
        stack.addArrangedSubview(ToolUI.stack([add, addPage, editButton!, removeButton!], vertical: false))
        stack.addArrangedSubview(label("Codex and Claude Code open a new draft containing local file references. They do not upload attachments or send a message automatically. Review and send in the target app.", size: 12, secondary: true))
        stack.addArrangedSubview(label("Open files uses macOS to hand files to the app. Copy files and open app prepares attachments for you to paste. This only changes Swivel’s actions; your system’s default apps stay the same.", size: 12, secondary: true))
        stack.addArrangedSubview(label("A web page opens in your browser, and the files appear on a small card: drag it into the page (or press ⌘V there) to attach them. Nothing is uploaded until you do.", size: 12, secondary: true))
    }
    override func refresh() {
        let latest = Prefs.fileAppTargets
        if targets != latest { targets = latest; table.reloadData() }
        editButton?.isEnabled = targets.indices.contains(table.selectedRow)
        removeButton?.isEnabled = targets.indices.contains(table.selectedRow)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refresh() }
    @objc private func addTarget() { showEditor(nil) }
    @objc private func addPage() { showEditor(nil, web: true) }
    @objc private func editTarget() { if targets.indices.contains(table.selectedRow) { showEditor(targets[table.selectedRow]) } }
    private func showEditor(_ target: FileAppTarget?, web: Bool = false) {
        guard let window = view.window else { return }
        editor = AppTargetEditor(target, web: web) { [weak self] value in
            guard let self else { return }
            var latest = Prefs.fileAppTargets
            if let index = latest.firstIndex(where: { $0.id == value.id }) { latest[index] = value } else { latest.append(value) }
            Prefs.fileAppTargets = latest
            if let index = latest.firstIndex(where: { $0.id == value.id }) { table.selectRowIndexes([index], byExtendingSelection: false) }
        }
        editor?.present(on: window)
    }
    @objc private func removeTarget() {
        guard targets.indices.contains(table.selectedRow) else { return }
        let id = targets[table.selectedRow].id
        Prefs.fileAppTargets = targets.filter { $0.id != id }
    }
    @objc private func toggleTarget(_ sender: NSButton) {
        guard targets.indices.contains(sender.tag) else { return }
        targets[sender.tag].enabled = sender.state == .on; Prefs.fileAppTargets = targets
    }
    func numberOfRows(in tableView: NSTableView) -> Int { targets.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let target = targets[row]
        if tableColumn?.identifier.rawValue == "enabled" {
            let toggle = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleTarget(_:)))
            toggle.state = target.enabled ? .on : .off; toggle.tag = row; toggle.setAccessibilityLabel(target.name); return toggle
        }
        if tableColumn?.identifier.rawValue == "app" {
            let name = NSTextField(labelWithString: target.name); name.lineBreakMode = .byTruncatingTail
            let installed = FileAppRouting.application(for: target) != nil
            let note = target.isWebPage ? (installed ? L("Web page · %@", target.pageHost) : L("Choose a browser to finish setup"))
                                        : (installed ? L("Installed") : L("Choose the app to finish setup"))
            let detail = ToolUI.note(note); detail.lineBreakMode = .byTruncatingTail; detail.maximumNumberOfLines = 1
            detail.toolTip = target.webAddress
            return ToolUI.stack([name, detail], spacing: 3)
        }
        let value = tableColumn?.identifier.rawValue == "delivery" ? target.delivery.title : target.extensions.isEmpty ? L("All files") : target.extensions.joined(separator: ", ")
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingTail; label.toolTip = value; return label
    }
}

@MainActor
final class AppTargetEditor: NSObject, NSTextFieldDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 610, height: 440), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private var value: FileAppTarget
    private let saved: (FileAppTarget) -> Void
    private let kind = NSSegmentedControl(labels: [L("Application"), L("Web Page")], trackingMode: .selectOne, target: nil, action: nil)
    private let name = NSTextField(), extensions = NSTextField(), address = NSTextField(), appLabel = ToolUI.note("")
    private let delivery = NSPopUpButton()
    private let installedApps = NSPopUpButton()
    private let browsers = NSPopUpButton()
    private var applicationURLs: [URL] = []
    private var browserURLs: [URL] = []
    /// The application and the browser are kept apart, so switching between the two kinds loses neither.
    private var app: (path: String, bundleID: String)
    private var browser: (path: String, bundleID: String) = ("", "")
    private let grid: NSGridView
    private let chooseRow: NSStackView
    private let pageNote = ToolUI.note("Swivel opens the page, copies the files and shows them on a small card: drag it into the page to attach them, or press ⌘V there. For Gmail, use a new-message link: https://mail.google.com/mail/?view=cm&fs=1. File names and contents are never added to the address.")
    private let issue = ToolUI.note("")
    private var isWeb: Bool { kind.selectedSegment == 1 }

    init(_ target: FileAppTarget?, web: Bool = false, saved: @escaping (FileAppTarget) -> Void) {
        value = target ?? FileAppTarget(id: UUID().uuidString, name: "", bundleID: "", appPath: "", delivery: web ? .copyAndOpenPage : .openFiles,
                                        webAddress: web ? "" : nil)
        app = value.isWebPage ? ("", "") : (value.appPath, value.bundleID)
        if value.isWebPage { browser = (value.appPath, value.bundleID) }
        self.saved = saved
        let choose = ToolUI.button("Choose Application…", target: nil, action: nil)
        chooseRow = ToolUI.stack([choose, appLabel], vertical: false)
        grid = NSGridView(views: [[NSTextField(labelWithString: L("Open in")), kind],
                                  [NSTextField(labelWithString: L("Application")), installedApps],
                                  [NSTextField(labelWithString: ""), chooseRow],
                                  [NSTextField(labelWithString: L("Address")), address],
                                  [NSTextField(labelWithString: L("Browser")), browsers],
                                  [NSTextField(labelWithString: L("Name")), name],
                                  [NSTextField(labelWithString: L("Delivery")), delivery],
                                  [NSTextField(labelWithString: L("File extensions")), extensions]])
        super.init()
        choose.target = self; choose.action = #selector(chooseApp)
        panel.title = L(target == nil ? (web ? "Add Web Page" : "Add Application") : (value.isWebPage ? "Edit Web Page" : "Edit Application"))
        kind.selectedSegment = value.isWebPage ? 1 : 0
        kind.target = self; kind.action = #selector(kindChanged); kind.setAccessibilityLabel(L("Open in"))
        name.stringValue = value.name; name.placeholderString = L("Name in the Wheel"); name.setAccessibilityLabel(L("Name in the Wheel"))
        address.stringValue = value.webAddress ?? ""; address.placeholderString = "https://example.com/upload"
        address.setAccessibilityLabel(L("Address")); address.delegate = self
        extensions.stringValue = value.extensions.joined(separator: ", "); extensions.placeholderString = L("Empty means all files, e.g. png, jpg, pdf")
        extensions.setAccessibilityLabel(L("File extensions"))
        delivery.addItems(withTitles: FileAppTarget.Delivery.forApplications.map(\.title))
        delivery.selectItem(at: FileAppTarget.Delivery.forApplications.firstIndex(of: value.delivery) ?? 0)
        delivery.target = self; delivery.action = #selector(deliveryChanged); delivery.setAccessibilityLabel(L("Delivery"))
        applicationURLs = Self.installedApplications()
        installedApps.addItem(withTitle: L("Choose an installed app…"))
        for url in applicationURLs { installedApps.menu?.addItem(Self.menuItem(for: url)) }
        if let index = applicationURLs.firstIndex(where: { $0.path == app.path }) { installedApps.selectItem(at: index + 1) }
        installedApps.target = self; installedApps.action = #selector(installedAppChanged); installedApps.setAccessibilityLabel(L("Application"))
        browserURLs = Self.installedBrowsers()
        let fallback = URL(string: "https://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        browsers.addItem(withTitle: fallback.map { L("Default Browser (%@)", $0.deletingPathExtension().lastPathComponent) } ?? L("Default Browser"))
        for url in browserURLs { browsers.menu?.addItem(Self.menuItem(for: url)) }
        if let index = browserURLs.firstIndex(where: { $0.path == browser.path }) { browsers.selectItem(at: index + 1) } else { browser = ("", "") }
        browsers.target = self; browsers.action = #selector(browserChanged); browsers.setAccessibilityLabel(L("Browser"))
        grid.rowSpacing = 12; grid.columnSpacing = 12; grid.column(at: 0).xPlacement = .trailing
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true
        address.widthAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true
        let cancel = ToolUI.button("Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let save = ToolUI.button("Save", target: self, action: #selector(save)); save.keyEquivalent = "\r"
        let bar = NSStackView(); bar.addView(cancel, in: .trailing); bar.addView(save, in: .trailing)
        let root = ToolUI.stack([grid, pageNote, issue, bar])
        panel.contentView = NSView(); ToolUI.embed(root, in: panel.contentView!)
        bar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        pageNote.preferredMaxLayoutWidth = 550; issue.preferredMaxLayoutWidth = 550
        updateKind()
    }
    func present(on window: NSWindow) { window.beginSheet(panel) }

    /// Apps in the usual folders, and one folder down: Adobe's apps (and other suites) live in their own folders,
    /// such as /Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app.
    static func installedApplications(in roots: [String] = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                                            "/Applications/Utilities", NSHomeDirectory() + "/Applications"]) -> [URL] {
        let fm = FileManager.default
        var found = Set<URL>()
        for root in roots {
            for entry in (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] {
                if entry.pathExtension == "app" { found.insert(entry.standardizedFileURL); continue }
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                for inner in (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] where inner.pathExtension == "app" {
                    found.insert(inner.standardizedFileURL)
                }
            }
        }
        return found.filter { Bundle(url: $0)?.bundleIdentifier.map { $0 != "local.swivel.app" } ?? false }
            .sorted { $0.deletingPathExtension().lastPathComponent.localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending }
    }

    /// Apps that open web pages.
    static func installedBrowsers() -> [URL] {
        guard let page = URL(string: "https://example.com") else { return [] }
        var seen = Set<String>()
        return NSWorkspace.shared.urlsForApplications(toOpen: page)
            .filter { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier.map { $0 != "local.swivel.app" && seen.insert($0).inserted } ?? false }
            .sorted { $0.deletingPathExtension().lastPathComponent.localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending }
    }

    private static func menuItem(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: nil, keyEquivalent: "")
        let icon = NSWorkspace.shared.icon(forFile: url.path); icon.size = NSSize(width: 16, height: 16)
        item.image = icon; item.toolTip = url.path
        return item
    }

    @objc private func kindChanged() { updateKind() }
    private func updateKind() {
        let web = isWeb
        for (row, showsForWeb) in [(1, false), (2, false), (3, true), (4, true), (6, false)] { grid.row(at: row).isHidden = web != showsForWeb }
        pageNote.isHidden = !web
        issue.stringValue = ""
        if web { checkAddress() }
        updateAppLabel()
    }
    @objc private func deliveryChanged() { updateAppLabel() }
    @objc private func browserChanged() {
        let index = browsers.indexOfSelectedItem - 1
        browser = browserURLs.indices.contains(index) ? (browserURLs[index].path, Bundle(url: browserURLs[index])?.bundleIdentifier ?? "") : ("", "")
    }
    func controlTextDidChange(_ notification: Notification) { if notification.object as? NSTextField === address { checkAddress() } }
    private func checkAddress() {
        let text = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        issue.stringValue = text.isEmpty || FileAppTarget.pageURL(from: text) != nil ? "" : Self.addressProblem
    }
    private static var addressProblem: String { L("Enter a web address starting with https:// (http only for this Mac or your local network).") }

    /// The target as the form shows it now.
    private func current() -> FileAppTarget {
        var result = value
        result.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.extensions = FileAppTarget.normalizedExtensions(extensions.stringValue)
        if isWeb {
            result.webAddress = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            result.delivery = .copyAndOpenPage; result.appPath = browser.path; result.bundleID = browser.bundleID
            if result.name.isEmpty { result.name = String(result.pageHost.prefix(80)) }
        } else {
            result.webAddress = nil
            result.delivery = FileAppTarget.Delivery.forApplications[max(delivery.indexOfSelectedItem, 0)]
            result.appPath = app.path; result.bundleID = app.bundleID
        }
        return result
    }
    private func updateAppLabel() {
        appLabel.stringValue = isWeb ? "" : FileAppRouting.application(for: current())?.lastPathComponent ?? L("No application selected")
        appLabel.lineBreakMode = .byTruncatingMiddle
    }
    @objc private func installedAppChanged() {
        let index = installedApps.indexOfSelectedItem - 1
        guard applicationURLs.indices.contains(index) else { return }
        selectApplication(applicationURLs[index])
    }
    private func selectApplication(_ url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier, id != "local.swivel.app" else { return }
        app = (url.path, id)
        if name.stringValue.isEmpty { name.stringValue = url.deletingPathExtension().lastPathComponent }
        updateAppLabel()
    }
    @objc private func chooseApp() {
        let picker = NSOpenPanel(); picker.allowsMultipleSelection = false
        // App bundles are directories. Let the panel select packages on all supported macOS versions,
        // then validate the selected bundle below rather than relying on the panel's UTI filter.
        picker.canChooseFiles = true; picker.canChooseDirectories = true; picker.treatsFilePackagesAsDirectories = false
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        // Use an application-modal picker here: this editor is already a sheet.
        NSApp.activate()
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard url.pathExtension == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id != "local.swivel.app" else {
            issue.stringValue = L("Choose an installed application first."); return
        }
        selectApplication(url)
    }
    @objc private func cancel() { panel.sheetParent?.endSheet(panel) }
    @objc private func save() {
        let result = current()
        if isWeb, result.pageURL == nil { issue.stringValue = Self.addressProblem; return }
        guard result.isValid else { issue.stringValue = L("Enter a name of 1–80 characters."); return }
        if !extensions.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result.extensions.isEmpty {
            issue.stringValue = L("Enter file extensions separated by commas."); return
        }
        guard FileAppRouting.application(for: result) != nil else {
            issue.stringValue = isWeb ? L("Choose an installed browser.") : L("Choose an installed application first."); return
        }
        value = result
        saved(result); panel.sheetParent?.endSheet(panel)
    }
}
