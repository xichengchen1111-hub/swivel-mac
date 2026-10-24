import AppKit
import Quartz

/// Session-only references: staging and removing items never copies or deletes files.
struct ShelfContents {
    private(set) var urls: [URL] = []

    /// Returns the rows that were added and the rows of candidates that were already on the shelf.
    @discardableResult
    mutating func add(_ candidates: [URL]) -> (added: IndexSet, existing: IndexSet) {
        var added = IndexSet(), existing = IndexSet()
        for candidate in candidates where candidate.isFileURL {
            let url = candidate.standardizedFileURL
            if let index = urls.firstIndex(of: url) {
                if !added.contains(index) { existing.insert(index) }
            } else if FileManager.default.fileExists(atPath: url.path) {
                urls.append(url)
                added.insert(urls.count - 1)
            }
        }
        return (added, existing)
    }

    mutating func remove(_ indexes: IndexSet) { urls = urls.enumerated().filter { !indexes.contains($0.offset) }.map(\.element) }
    mutating func clear() { urls.removeAll() }

    /// Puts removed references back where they were (for undo), skipping any that were added again meanwhile.
    /// Returns the rows they now occupy.
    @discardableResult
    mutating func restore(_ items: [(offset: Int, url: URL)]) -> IndexSet {
        var rows = IndexSet()
        for item in items.sorted(by: { $0.offset < $1.offset }) where !urls.contains(item.url) {
            let index = min(item.offset, urls.count)
            rows = IndexSet(rows.map { $0 >= index ? $0 + 1 : $0 })
            urls.insert(item.url, at: index)
            rows.insert(index)
        }
        return rows
    }
}

@MainActor
final class Shelf: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                   QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = Shelf()
    private var panel: ShelfPanel?
    private let table = ToolTable()
    private var contents = ShelfContents()
    private let status = ToolUI.note("")
    private let empty = ShelfPlaceholder(wrappingLabelWithString: L("Drop files here, then select several and drag them out together."))
    private var removeButton: NSButton!
    private var clearButton: NSButton!
    private var previewButton: NSButton!
    private var observer: NSObjectProtocol?
    /// Icons are looked up once per file; reloading rows never touches the disk.
    private var icons: [URL: NSImage] = [:]
    /// Last known availability, refreshed off the main thread when the shelf comes forward.
    private var available: [URL: Bool] = [:]
    private var availabilityCheck: Task<Void, Never>?
    /// A short message ("2 removed · ⌘Z to undo") shown in place of the counts for a few seconds.
    private var notice: String?
    private var noticeGeneration = 0
    private var previewItems: [URL] = []
    /// Who was in front when Quick Look brought Swivel forward, and whether the shelf had the keyboard then.
    private var previewReturn = ActivationReturn()
    private var previewHadKeyboard = false
    private var rekeyObserver: NSObjectProtocol?

    /// Adds files without taking focus, so collecting from Finder or the Wheel never interrupts the drag.
    func add(_ urls: [URL]) {
        guard Feature.shelf.isOn else { return }
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let wasVisible = panel.isVisible
        let change = contents.add(urls)
        for index in change.added { remember(contents.urls[index]) }
        if wasVisible {
            insertRows(change.added)
        } else {
            refresh()
            ToolUI.present(panel, focus: false)
        }
        if change.added.isEmpty, !change.existing.isEmpty { showNotice(L("Already on the shelf")) }
        // Point at what arrived (or what was already there) once the rows exist.
        let highlight = change.added.union(change.existing)
        DispatchQueue.main.async { [weak self] in self?.highlight(highlight) }
    }

    func show() {
        guard Feature.shelf.isOn else { return }
        if panel == nil { panel = makePanel() }
        refresh()
        if let panel { ToolUI.present(panel, focus: true) }
    }

    func hide() {
        if let preview = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, isPreviewing(preview) {
            preview.orderOut(nil)
        }
        panel?.orderOut(nil)
        ToolUI.didClose()
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 470),
                               styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.shelf = self
        panel.title = L("File Shelf")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 330)
        panel.delegate = self
        panel.setFrameAutosaveName("SwivelFileShelf")
        panel.center()
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 52
        table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.deleteSelection = { [weak self] in self?.removeSelected() }
        table.previewSelection = { [weak self] in self?.quickLook() }
        // The finger is on the trackpad during a drag, so a detent tap says "this will take them".
        table.dropTargeted = { Haptics.tick(.alignment) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        for (title, action) in [("Quick Look", #selector(quickLook)), ("Show in Finder", #selector(reveal)), ("Remove from Shelf", #selector(removeSelected))] {
            let item = NSMenuItem(title: L(title), action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let area = NSView()
        ToolUI.embed(scroll, in: area, inset: 0)
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false
        area.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: area.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: area.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: area.widthAnchor, constant: -48),
        ])
        let add = ToolUI.button("Add Files…", target: self, action: #selector(chooseFiles))
        previewButton = ToolUI.button("Quick Look", target: self, action: #selector(quickLook))
        removeButton = ToolUI.button("Remove from Shelf", target: self, action: #selector(removeSelected))
        clearButton = ToolUI.button("Clear", target: self, action: #selector(clearAll))
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 1
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = NSStackView()
        top.addView(status, in: .leading); top.addView(add, in: .trailing)
        let buttons = NSStackView()
        buttons.addView(previewButton, in: .leading)
        buttons.addView(removeButton, in: .trailing); buttons.addView(clearButton, in: .trailing)
        let note = ToolUI.note("Removing an item only clears its reference. Original files stay where they are. This shelf lasts until you quit.")
        let root = ToolUI.stack([top, area, buttons, note])
        let content = NSView(); panel.contentView = content
        ToolUI.embed(root, in: content, inset: 16)
        for view in [top, area, buttons, note] { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        area.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        area.setContentHuggingPriority(.defaultLow, for: .vertical)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAvailability() }
        }
        return panel
    }

    private var selectedURLs: [URL] { table.selectedRowIndexes.compactMap { contents.urls.indices.contains($0) ? contents.urls[$0] : nil } }
    private var availableSelection: [URL] { selectedURLs.filter { available[$0] ?? true } }

    private func remember(_ url: URL) {
        available[url] = true
        if icons[url] == nil { icons[url] = NSWorkspace.shared.icon(forFile: url.path) }
    }

    private func refresh() {
        guard panel != nil else { return }
        panel?.title = L("File Shelf")
        let selected = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(IndexSet(selected.filter { $0 < contents.urls.count }), byExtendingSelection: false)
        updateEmpty()
        updateSelection()
        checkAvailability()
    }

    private func updateEmpty() { empty.isHidden = !contents.urls.isEmpty }

    private func updateSelection() {
        status.stringValue = notice ?? L("%d files · %d selected", contents.urls.count, table.numberOfSelectedRows)
        removeButton?.isEnabled = !selectedURLs.isEmpty
        clearButton?.isEnabled = !contents.urls.isEmpty
        previewButton?.isEnabled = !availableSelection.isEmpty
    }

    private func showNotice(_ text: String) {
        noticeGeneration += 1
        let token = noticeGeneration
        notice = text
        updateSelection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, noticeGeneration == token else { return }
            notice = nil
            updateSelection()
        }
    }

    /// Re-checks which files still exist without blocking the main thread (network or sleeping volumes can stall),
    /// then redraws only the rows that changed.
    private func checkAvailability() {
        let urls = contents.urls
        guard panel?.isVisible == true, !urls.isEmpty else { return }
        availabilityCheck?.cancel()
        availabilityCheck = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { urls.map { FileManager.default.fileExists(atPath: $0.path) } }.value
            guard let self, !Task.isCancelled else { return }
            var changed = IndexSet()
            for (url, exists) in zip(urls, found) where available[url] != exists {
                available[url] = exists
                if let row = contents.urls.firstIndex(of: url) { changed.insert(row) }
            }
            guard !changed.isEmpty else { return }
            table.reloadData(forRowIndexes: changed, columnIndexes: [0])
            updateSelection()
        }
    }

    // MARK: Rows arriving and leaving

    private func insertRows(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        let reduced = Motion.reduced
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18 / Double(Prefs.interaction.tools.safeSpeed)
            table.insertRows(at: rows, withAnimation: reduced ? .effectFade : [.slideDown, .effectFade])
        }
        updateEmpty()
        updateSelection()
    }

    private func removeRows(_ rows: IndexSet) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15 / Double(Prefs.interaction.tools.safeSpeed)
            table.removeRows(at: rows, withAnimation: .effectFade)
        }
        updateEmpty()
        updateSelection()
    }

    /// Scrolls to the rows and gives them a brief accent glow, so it's clear what just landed.
    private func highlight(_ rows: IndexSet) {
        guard let last = rows.last, last < table.numberOfRows else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduced ? 0 : 0.2 / Double(Prefs.interaction.tools.safeSpeed)
            ctx.allowsImplicitAnimation = !Motion.reduced
            table.scrollRowToVisible(last)
        }
        for row in rows where row < table.numberOfRows {
            (table.rowView(atRow: row, makeIfNecessary: false) as? ShelfRowView)?.flash()
        }
    }

    /// Takes rows off the shelf with ⌘Z to bring them back; with undo, Clear doesn't need a confirmation.
    private func removeReferences(at rows: IndexSet) {
        let removed = rows.filter { contents.urls.indices.contains($0) }.map { (offset: $0, url: contents.urls[$0]) }
        guard !removed.isEmpty else { return }
        contents.remove(IndexSet(removed.map(\.offset)))
        table.deselectAll(nil)
        removeRows(IndexSet(removed.map(\.offset)))
        panel?.undoManager?.registerUndo(withTarget: self) { shelf in
            MainActor.assumeIsolated { shelf.restoreReferences(removed) }
        }
        showNotice(L("%d removed · ⌘Z to undo", removed.count))
    }

    private func restoreReferences(_ items: [(offset: Int, url: URL)]) {
        let rows = contents.restore(items)
        for url in items.map(\.url) { remember(url) }
        insertRows(rows)
        table.selectRowIndexes(rows, byExtendingSelection: false)
        // Redo removes the same files again, wherever they are now.
        let urls = items.map(\.url)
        panel?.undoManager?.registerUndo(withTarget: self) { shelf in
            MainActor.assumeIsolated {
                shelf.removeReferences(at: IndexSet(urls.compactMap { shelf.contents.urls.firstIndex(of: $0) }))
            }
        }
        notice = nil
        updateSelection()
        DispatchQueue.main.async { [weak self] in self?.highlight(rows) }
        checkAvailability()
    }

    @objc private func chooseFiles() { add(ToolUI.chooseFiles(folders: true)) }
    @objc private func removeSelected() { removeReferences(at: table.selectedRowIndexes) }
    @objc private func clearAll() { removeReferences(at: IndexSet(contents.urls.indices)) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting(availableSelection) }

    // MARK: Quick Look

    /// Space toggles Quick Look for every selected file; it zooms out of the row's icon like Finder.
    @objc private func quickLook() {
        if let preview = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, preview.isVisible {
            preview.orderOut(nil)
            return
        }
        previewItems = availableSelection
        guard !previewItems.isEmpty, let panel, let preview = QLPreviewPanel.shared() else { return }
        // Quick Look only works while Swivel is active, but the shelf is non-activating: remember who was in front
        // (no preview is up, so this is the user's own app), so closing the preview can hand activation back.
        previewReturn.remember(NSWorkspace.shared.frontmostApplication)
        previewHadKeyboard = panel.isKeyWindow
        NSApp.activate()
        panel.makeKey()
        preview.updateController()
        preview.reloadData()
        preview.makeKeyAndOrderFront(nil)
    }

    private func isPreviewing(_ preview: QLPreviewPanel) -> Bool { preview.isVisible && (preview.dataSource as AnyObject?) === self }

    fileprivate func beginPreview(_ preview: QLPreviewPanel) {
        preview.dataSource = self
        preview.delegate = self
    }

    fileprivate func endPreview(_ preview: QLPreviewPanel) {
        preview.dataSource = nil
        preview.delegate = nil
        DispatchQueue.main.async { [weak self] in self?.previewClosed() }
    }

    /// Once the preview has really closed, give activation back to the app the user was in, unless they've already
    /// clicked into another app (then Swivel isn't active any more). Mirrors the clothesline's QuickLooker.
    private func previewClosed() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true { return }
        let rekey = previewHadKeyboard
        previewHadKeyboard = false
        guard let app = previewReturn.take(swivelIsActive: NSApp.isActive) else { return }
        if rekey { rekeyShelf(after: app) }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }

    /// The shelf had the keyboard before the preview, so it takes it back, without activating Swivel, once `app`
    /// is active again (making it key any earlier would lose out to that app's own key window). If another app
    /// comes forward first, the user has moved on and the keyboard stays there.
    private func rekeyShelf(after app: NSRunningApplication) {
        let center = NSWorkspace.shared.notificationCenter
        if let rekeyObserver { center.removeObserver(rekeyObserver) }
        let pid = app.processIdentifier
        rekeyObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let shelf = self else { return }
                if let token = shelf.rekeyObserver { center.removeObserver(token) }
                shelf.rekeyObserver = nil
                if activated == pid, let panel = shelf.panel, panel.isVisible { panel.makeKey() }
            }
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewItems.indices.contains(index) ? previewItems[index] as NSURL : nil }
    }

    /// ↑ and ↓ move through the shelf while the preview has focus, as in Finder.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard event.type == .keyDown, [125, 126].contains(event.keyCode) else { return false }
            table.keyDown(with: event)
            return true
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        MainActor.assumeIsolated { iconFrame(for: item)?.frame ?? .zero }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                                  contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        MainActor.assumeIsolated { iconFrame(for: item)?.image }
    }

    private func iconFrame(for item: (any QLPreviewItem)?) -> (frame: NSRect, image: NSImage?)? {
        guard let url = item?.previewItemURL, let row = contents.urls.firstIndex(of: url.standardizedFileURL),
              table.rows(in: table.visibleRect).contains(row),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ShelfCell,
              let window = table.window else { return nil }
        return (window.convertToScreen(cell.icon.convert(cell.icon.bounds, to: nil)), cell.icon.image)
    }

    // MARK: Window, table and drag delegate

    func windowWillClose(_ notification: Notification) { ToolUI.didClose() }
    func windowDidBecomeKey(_ notification: Notification) { checkAvailability() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelection()
        // The open preview follows the selection.
        if let preview = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, isPreviewing(preview) {
            let items = availableSelection
            if !items.isEmpty, items != previewItems {
                previewItems = items
                preview.reloadData()
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { contents.urls.count }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        }
        for item in menu.items { item.isEnabled = item.action == #selector(removeSelected) ? !selectedURLs.isEmpty : !availableSelection.isEmpty }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: ShelfRowView.identifier, owner: nil) as? ShelfRowView ?? ShelfRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = contents.urls[row]
        let cell = tableView.makeView(withIdentifier: ShelfCell.identifier, owner: nil) as? ShelfCell ?? ShelfCell()
        if icons[url] == nil { icons[url] = NSWorkspace.shared.icon(forFile: url.path) }
        cell.configure(url: url, icon: icons[url], available: available[url] ?? true)
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let url = contents.urls[row]
        return Feature.shelf.isOn && FileManager.default.fileExists(atPath: url.path) ? url as NSURL : nil
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard Feature.shelf.isOn, info.draggingSource as? NSTableView !== table,
              !ToolUI.fileURLs(from: info.draggingPasteboard).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = ToolUI.fileURLs(from: info.draggingPasteboard)
        guard Feature.shelf.isOn, !urls.isEmpty else { return false }
        add(urls)
        return true
    }
}

/// The shelf's window: hands Quick Look control to the shelf while it's key.
final class ShelfPanel: ToolPanel {
    weak var shelf: Shelf?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { shelf != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { shelf?.beginPreview(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { shelf?.endPreview(panel) }
}

/// One file: icon, name and folder (or a red note when the file has gone). Reused while scrolling.
private final class ShelfCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ShelfCell")
    let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        title.lineBreakMode = .byTruncatingMiddle
        path.lineBreakMode = .byTruncatingMiddle
        path.font = .systemFont(ofSize: 11)
        let labels = ToolUI.stack([title, path], spacing: 3)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = ToolUI.stack([icon, labels], vertical: false, spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(url: URL, icon image: NSImage?, available: Bool) {
        icon.image = image
        title.stringValue = url.lastPathComponent
        path.stringValue = available ? url.deletingLastPathComponent().path : L("File is no longer available")
        path.textColor = available ? .secondaryLabelColor : .systemRed
        toolTip = url.path
        setAccessibilityLabel(url.lastPathComponent)
    }
}

/// A row that can glow briefly in the accent colour when its file arrives.
private final class ShelfRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ShelfRow")
    private let glow = CALayer()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        glow.opacity = 0
        glow.cornerRadius = 6
        // Under the cell's text and icon.
        layer?.insertSublayer(glow, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds.insetBy(dx: 4, dy: 1)
        CATransaction.commit()
    }

    /// Rises fast, holds, then fades: a trace of what arrived rather than motion.
    func flash() {
        glow.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 1, 0]
        pulse.keyTimes = [0, 0.1, 0.35, 1]
        pulse.duration = 0.9 / Double(Prefs.interaction.tools.safeSpeed)
        glow.add(pulse, forKey: "flash")
    }
}

/// Let drops reach the table even when the pointer is over the empty-state text.
private final class ShelfPlaceholder: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
