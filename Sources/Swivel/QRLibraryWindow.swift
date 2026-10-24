import AppKit
import UniformTypeIdentifiers

private final class CodeLibraryNode: NSObject {
    let title: String
    let entry: SavedQRCode?
    var children: [CodeLibraryNode]
    init(title: String, entry: SavedQRCode? = nil, children: [CodeLibraryNode] = []) { self.title = title; self.entry = entry; self.children = children }
}

@MainActor
final class QRLibraryWindow: FileToolWindow, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private let store: QRLibraryStore
    private var entries: [SavedQRCode] = []
    private var roots: [CodeLibraryNode] = []
    private var undoValues: [(before: [SavedQRCode], after: [SavedQRCode])] = []
    private let outline = NSOutlineView(), search = NSSearchField()
    let tree = QRGardenView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: ""), content = NSTextField(wrappingLabelWithString: "")
    private let status = ToolUI.note("")
    private let mode = NSSegmentedControl(labels: [L("Scene"), L("QR Code")], trackingMode: .selectOne, target: nil, action: nil)
    private let season = NSPopUpButton()
    private let template = NSPopUpButton()
    private let emptyState = NSView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyHint = ToolUI.note("")
    private var editButton: NSButton!, removeButton: NSButton!, copyButton: NSButton!, exportButton: NSButton!, undoButton: NSButton!
    private var editor: SavedCodeEditor?
    private var observer: NSObjectProtocol?
    private var workMessage: String?

    init(store: QRLibraryStore = QRLibraryStore(), select id: UUID? = nil) {
        self.store = store
        super.init(feature: .qrCodes, title: "QR Library", size: NSSize(width: 1030, height: 750))
        window.minSize = NSSize(width: 940, height: 670)
        search.placeholderString = L("Search saved codes…"); search.delegate = self; search.sendsSearchStringImmediately = true
        let column = NSTableColumn(identifier: .init("code")); outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.style = .sourceList; outline.rowHeight = 30
        outline.dataSource = self; outline.delegate = self
        let list = NSScrollView(); list.documentView = outline; list.hasVerticalScroller = true
        list.widthAnchor.constraint(equalToConstant: 245).isActive = true
        let add = ToolUI.button("New Code…", target: self, action: #selector(addCode))
        let imported = ToolUI.button("Import Images…", target: self, action: #selector(importImages))
        let left = ToolUI.stack([search, list, ToolUI.stack([add, imported], vertical: false, spacing: 8)])
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold); titleLabel.lineBreakMode = .byTruncatingTail
        content.font = .monospacedSystemFont(ofSize: 12, weight: .regular); content.isSelectable = true
        content.maximumNumberOfLines = 3; content.lineBreakMode = .byTruncatingMiddle
        mode.target = self; mode.action = #selector(modeChanged); mode.selectedSegment = 0
        season.addItems(withTitles: QRSeason.allCases.map(\.title)); season.target = self; season.action = #selector(seasonChanged)
        season.setAccessibilityLabel(L("Season"))
        template.addItems(withTitles: QRTemplate.allCases.map(\.title)); template.target = self; template.action = #selector(templateChanged)
        template.setAccessibilityLabel(L("Template"))
        let preview = NSView()
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        for child in [tree, emptyState] {
            child.translatesAutoresizingMaskIntoConstraints = false; preview.addSubview(child)
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: preview.leadingAnchor), child.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
                                         child.topAnchor.constraint(equalTo: preview.topAnchor), child.bottomAnchor.constraint(equalTo: preview.bottomAnchor)])
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: "qrcode", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 44, weight: .light); icon.contentTintColor = .secondaryLabelColor
        emptyTitle.font = .systemFont(ofSize: 19, weight: .semibold)
        emptyHint.alignment = .center; emptyHint.preferredMaxLayoutWidth = 430
        let emptyActions = ToolUI.stack([ToolUI.button("New Code…", target: self, action: #selector(addCode)),
                                        ToolUI.button("Import Images…", target: self, action: #selector(importImages))], vertical: false)
        let emptyContent = ToolUI.stack([icon, emptyTitle, emptyHint, emptyActions], spacing: 18); emptyContent.alignment = .centerX
        emptyContent.translatesAutoresizingMaskIntoConstraints = false; emptyState.addSubview(emptyContent)
        NSLayoutConstraint.activate([emptyContent.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor), emptyContent.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
                                     emptyContent.widthAnchor.constraint(lessThanOrEqualTo: emptyState.widthAnchor, constant: -40)])
        tree.onToggle = { [weak self] code in self?.mode.selectedSegment = code ? 1 : 0 }
        editButton = ToolUI.button("Edit…", target: self, action: #selector(editCode))
        removeButton = ToolUI.button("Remove", target: self, action: #selector(removeCode))
        undoButton = ToolUI.button("Undo", target: self, action: #selector(undoChange))
        copyButton = ToolUI.button("Copy QR Image", target: self, action: #selector(copyImage))
        exportButton = ToolUI.button("Export PNG…", target: self, action: #selector(exportImage))
        let detail = ToolUI.stack([titleLabel, content, ToolUI.stack([mode, template, season], vertical: false), preview,
                                   ToolUI.note("Click the scene to look at it from above, where it becomes the QR code. Click again to look around it."),
                                   ToolUI.stack([editButton!, removeButton!, undoButton!, copyButton!, exportButton!], vertical: false, spacing: 8), status])
        for v in [titleLabel, content, preview, status] { v.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
        let divider = NSBox(); divider.boxType = .separator
        let body = ToolUI.stack([left, divider, detail], vertical: false, spacing: 18); body.alignment = .top
        install(body)
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 650).isActive = true
        observer = NotificationCenter.default.addObserver(forName: QRLibraryStore.changed, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? URL == self.store.file else { return }
                self.reload(select: self.selected?.id)
            }
        }
        reload(select: id)
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private var selected: SavedQRCode? { (outline.item(atRow: outline.selectedRow) as? CodeLibraryNode)?.entry }
    private func reload(select id: UUID? = nil) {
        do { entries = try store.load(); rebuild(select: id) }
        catch { status.stringValue = error.localizedDescription }
    }
    private func rebuild(select id: UUID? = nil) {
        let matches = entries.filter { search.stringValue.isEmpty || [$0.name, $0.value, $0.collection].contains { $0.localizedStandardContains(search.stringValue) } }
        let groups = Dictionary(grouping: matches, by: \.collection)
        roots = groups.keys.sorted().map { key in CodeLibraryNode(title: key.isEmpty ? L("Ungrouped") : key, children: groups[key]!.map { CodeLibraryNode(title: $0.name, entry: $0) }) }
        outline.reloadData(); outline.expandItem(nil, expandChildren: true)
        let nodes = roots.flatMap(\.children)
        if let node = nodes.first(where: { $0.entry?.id == id }) ?? nodes.first {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
        showSelection()
    }
    private func showSelection() {
        let selected = selected
        emptyState.isHidden = selected != nil; tree.isHidden = selected == nil
        emptyTitle.stringValue = entries.isEmpty ? L("Save your first QR code") : L("No matching codes")
        emptyHint.stringValue = entries.isEmpty ? L("Create a code from a link or text, or import an image containing a QR code. Your saved codes will appear here as trees.") : L("Try another search, or add a new code.")
        titleLabel.stringValue = selected?.name ?? L("Your QR collection")
        content.stringValue = selected?.value ?? L("Add a code or import an image to plant your first tree.")
        do { try tree.display(selected) } catch { status.stringValue = error.localizedDescription }
        mode.selectedSegment = 0; season.selectItem(at: QRSeason.allCases.firstIndex(of: selected?.season ?? .summer) ?? 1)
        template.selectItem(at: QRTemplate.allCases.firstIndex(of: selected?.template ?? .tree) ?? 0)
        for button in [editButton, removeButton, copyButton, exportButton] { button?.isEnabled = selected != nil && !isBusy }
        mode.isEnabled = selected != nil; season.isEnabled = selected != nil; template.isEnabled = selected != nil; undoButton?.isEnabled = !undoValues.isEmpty && !isBusy
        status.stringValue = L("%d saved codes · stored on this Mac", entries.count)
    }
    func controlTextDidChange(_ obj: Notification) { rebuild(select: selected?.id) }
    func outlineViewSelectionDidChange(_ notification: Notification) { showSelection() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? CodeLibraryNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? CodeLibraryNode)?.children[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! CodeLibraryNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? CodeLibraryNode)?.entry != nil }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! CodeLibraryNode
        let image = NSImageView(image: NSImage(systemSymbolName: node.entry.map(\.template.symbol) ?? "folder", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "tree", accessibilityDescription: nil)!)
        image.contentTintColor = node.entry == nil ? .secondaryLabelColor : .systemGreen
        let text = NSTextField(labelWithString: node.title); text.lineBreakMode = .byTruncatingTail
        return ToolUI.stack([image, text], vertical: false, spacing: 6)
    }
    @objc private func modeChanged() { tree.setShowsCode(mode.selectedSegment == 1) }
    @objc private func seasonChanged() {
        guard var entry = selected else { return }
        entry.season = QRSeason.allCases[season.indexOfSelectedItem]; saveEntry(entry)
    }
    @objc private func templateChanged() {
        guard var entry = selected else { return }
        entry.template = QRTemplate.allCases[template.indexOfSelectedItem]; saveEntry(entry)
    }
    @objc private func addCode() { edit(nil) }
    @objc private func editCode() { if let selected { edit(selected) } }
    private func edit(_ value: SavedQRCode?) {
        editor = SavedCodeEditor(value) { [weak self] in self?.saveEntry($0) }
        editor?.present(on: window)
    }
    private func saveEntry(_ entry: SavedQRCode) {
        guard Feature.qrCodes.isOn else { return }
        do {
            let before = try store.load()
            var latest = before
            if let i = latest.firstIndex(where: { $0.id == entry.id }) { latest[i] = entry } else { latest.insert(entry, at: 0) }
            try store.save(latest); undoValues.append((before, latest)); search.stringValue = ""; reload(select: entry.id)
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func removeCode() {
        guard Feature.qrCodes.isOn, let selected else { return }
        do {
            let latest = try store.load(), after = latest.filter { $0.id != selected.id }
            try store.save(after); undoValues.append((latest, after)); reload()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func undoChange() {
        guard Feature.qrCodes.isOn, let old = undoValues.last else { return }
        do { try store.revert(before: old.before, after: old.after); undoValues.removeLast(); reload() } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func importImages() {
        ingestImages(ToolUI.chooseFiles(imagesOnly: true))
    }
    func ingestImages(_ files: [URL]) {
        guard !files.isEmpty else { return }
        runWork {
            let codes = try await CodeRecognition.recognize(files)
            guard !codes.isEmpty else { self.workMessage = L("No readable QR codes or barcodes found."); return }
            let before = try self.store.load()
            var after = before
            for code in codes {
                let entry = SavedQRCode(name: code.source.deletingPathExtension().lastPathComponent, value: code.value)
                guard entry.isValid else { throw ToolError(L("Check the code name and content.")) }
                if !after.contains(where: { $0.value == entry.value && $0.collection == entry.collection }) { after.insert(entry, at: 0) }
            }
            guard after != before else { self.workMessage = L("These codes are already in your library."); return }
            try self.store.save(after); self.undoValues.append((before, after)); self.search.stringValue = ""; self.reload()
        }
    }
    override func workFinished() {
        showSelection()
        if let workMessage { status.stringValue = workMessage; self.workMessage = nil }
    }
    @objc private func copyImage() {
        guard Feature.qrCodes.isOn, let selected else { return }
        do {
            let image = NSImage(cgImage: try QRImage.cgImage(selected.value), size: .zero)
            let item = NSPasteboardItem()
            item.setData(image.tiffRepresentation ?? Data(), forType: .tiff)
            item.setData(Data(), forType: Clothesline.ownCopyType)
            if DetectedCode.isSecret(selected.value) { item.setData(Data(), forType: DetectedCode.concealed) }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item])
            Feedback.press(); status.stringValue = L("Copied")
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func exportImage() {
        guard Feature.qrCodes.isOn, let selected else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = selected.name.replacingOccurrences(of: "/", with: "-") + ".png"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, Feature.qrCodes.isOn else { return }
            do {
                // Never overwrite an existing export even if the system save panel offered to replace it.
                try QRImage.png(selected.value).write(to: url, options: .withoutOverwriting)
                self.status.stringValue = L("Saved %@", url.lastPathComponent); Feedback.done()
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
}

@MainActor
final class SavedCodeEditor: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 570, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private var value: SavedQRCode
    private let saved: (SavedQRCode) -> Void
    private let name = NSTextField(), collection = NSTextField(), content = CaptureTextView(), issue = ToolUI.note("")
    init(_ value: SavedQRCode?, saved: @escaping (SavedQRCode) -> Void) {
        self.value = value ?? SavedQRCode(name: "", value: ""); self.saved = saved; super.init()
        panel.title = L(value == nil ? "New QR Code" : "Edit QR Code")
        name.stringValue = self.value.name; name.placeholderString = L("Code name"); name.setAccessibilityLabel(L("Code name"))
        collection.stringValue = self.value.collection; collection.placeholderString = L("Collection (optional)"); collection.setAccessibilityLabel(L("Collection"))
        content.string = self.value.value; content.isRichText = false; content.isVerticallyResizable = true
        content.autoresizingMask = [.width]; content.textContainer?.widthTracksTextView = true
        content.font = .systemFont(ofSize: 13); content.setAccessibilityLabel(L("QR content"))
        let scroll = NSScrollView(); scroll.documentView = content; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        let cancel = ToolUI.button("Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let save = ToolUI.button("Save", target: self, action: #selector(save))
        let bar = NSStackView(); bar.addView(cancel, in: .trailing); bar.addView(save, in: .trailing)
        let root = ToolUI.stack([name, collection, ToolUI.note("Enter a URL or text. Saved codes stay on this Mac until you remove them."), scroll, issue, bar])
        panel.contentView = NSView(); ToolUI.embed(root, in: panel.contentView!)
        for view in [name, collection, scroll, bar] { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }
    func present(on window: NSWindow) { window.beginSheet(panel) }
    @objc private func cancel() { panel.sheetParent?.endSheet(panel) }
    @objc private func save() {
        guard Feature.qrCodes.isOn else { return }
        value.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value.collection = collection.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); value.value = content.string
        do {
            guard value.isValid else { throw ToolError(L("Check the code name and content.")) }
            _ = try QRImage.raw(value.value); saved(value); panel.sheetParent?.endSheet(panel)
        } catch { issue.stringValue = error.localizedDescription }
    }
}
