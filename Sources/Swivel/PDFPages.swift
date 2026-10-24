import AppKit
import PDFKit

struct PDFPageItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: URL
    let page: Int
    var rotation: Int = 0
    init(source: URL, page: Int) { id = UUID(); self.source = source; self.page = page }
}

enum PDFPageOrder {
    static func parse(_ text: String, count: Int) throws -> IndexSet {
        var result = IndexSet()
        let fields = text.replacingOccurrences(of: "，", with: ",").split(separator: ",", omittingEmptySubsequences: false)
        for field in fields {
            let bounds = field.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count), let first = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
                  first >= 1, first <= count else { throw ToolError(L("Use page numbers such as 1, 3-5 within this document.")) }
            let last = bounds.count == 2 ? Int(bounds[1].trimmingCharacters(in: .whitespaces)) : first
            guard let last, last >= first, last <= count else { throw ToolError(L("Use page numbers such as 1, 3-5 within this document.")) }
            result.insert(integersIn: (first - 1)..<last)
        }
        return result
    }

    /// The drop index refers to the list before removal, just like NSTableView's above-row drop.
    static func moving(_ items: [PDFPageItem], indexes: IndexSet, to destination: Int) -> [PDFPageItem] {
        let valid = indexes.intersection(IndexSet(items.indices))
        let selected = valid.map { items[$0] }
        var rest = items.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let target = min(rest.count, max(0, destination - valid.filter { $0 < destination }.count))
        rest.insert(contentsOf: selected, at: target)
        return rest
    }
}

/// Keep immutable source snapshots: external edits cannot silently change what a page preview will export.
struct PDFPagesSnapshot: Sendable {
    let data: [URL: Data]
    let items: [PDFPageItem]

    static func load(_ urls: [URL]) throws -> Self {
        var sources: [URL: Data] = [:], items: [PDFPageItem] = []
        var remainingBytes = 256 * 1024 * 1024
        for url in urls {
            let bytes = try sources[url] ?? FileSafety.read(url, limit: remainingBytes)
            if sources[url] == nil { remainingBytes -= bytes.count }
            guard let document = PDFDocument(data: bytes), !document.isLocked, document.pageCount > 0 else {
                throw ToolError(L("Could not open %@. Unlock password-protected PDFs first.", url.lastPathComponent))
            }
            guard items.count + document.pageCount <= 2000 else { throw ToolError(L("Choose at most 2,000 PDF pages at a time.")) }
            sources[url] = bytes
            items += (0..<document.pageCount).map { PDFPageItem(source: url, page: $0) }
        }
        guard !items.isEmpty else { throw ToolError(L("Choose a PDF with at least one page.")) }
        return Self(data: sources, items: items)
    }

    func export(_ pages: [PDFPageItem]) throws -> URL {
        guard let first = items.first, !pages.isEmpty else { throw ToolError(L("Select at least one page.")) }
        let documents = data.compactMapValues(PDFDocument.init(data:))
        let result = PDFDocument()
        for item in pages {
            guard let document = documents[item.source], item.page >= 0, item.page < document.pageCount,
                  let page = document.page(at: item.page)?.copy() as? PDFPage else { throw ToolError(L("A selected page is unavailable.")) }
            page.rotation = ((page.rotation + item.rotation) % 360 + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        guard let bytes = result.dataRepresentation(), let check = PDFDocument(data: bytes), check.pageCount == pages.count else {
            throw ToolError(L("Could not write PDF"))
        }
        return try Paths.create(bytes, at: Paths.preferred(for: first.source, ext: "pdf", suffix: " arranged"))
    }
}

@MainActor
final class PDFPagesWindow: FileToolWindow, @preconcurrency NSTableViewDataSource, NSTableViewDelegate {
    private(set) var snapshot: PDFPagesSnapshot?
    private(set) var items: [PDFPageItem] = []
    private var previous: [[PDFPageItem]] = []
    private var documents: [URL: PDFDocument] = [:]
    private var thumbnails: [UUID: NSImage] = [:]
    private let dragType = NSPasteboard.PasteboardType("local.swivel.pdf-pages")
    let table = NSTableView(), range = NSTextField()
    let status = ToolUI.note("Loading pages…")
    private var exportButton: NSButton!, saveButton: NSButton!, deleteButton: NSButton!, rotateButton: NSButton!, undoButton: NSButton!
    private var upButton: NSButton!, downButton: NSButton!

    init(_ urls: [URL]) {
        super.init(feature: .pdfPages, title: "PDF Pages", size: NSSize(width: 850, height: 720))
        for (id, title, width) in [("preview", "Preview", 105.0), ("page", "Page", 100.0), ("source", "Source file", 500.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = L(title); column.width = width; table.addTableColumn(column)
        }
        table.style = .inset; table.rowHeight = 100; table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes([dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        range.placeholderString = L("Pages, e.g. 1, 3-5"); range.setAccessibilityLabel(L("Select pages"))
        range.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        let select = ToolUI.button("Select Pages", target: self, action: #selector(selectRange))
        let all = ToolUI.button("Select All", target: self, action: #selector(selectAllPages))
        deleteButton = ToolUI.button("Remove Pages", target: self, action: #selector(removePages))
        rotateButton = ToolUI.button("Rotate", target: self, action: #selector(rotatePages))
        undoButton = ToolUI.button("Undo", target: self, action: #selector(undoEdit))
        upButton = ToolUI.button("Move Up", target: self, action: #selector(moveUp))
        downButton = ToolUI.button("Move Down", target: self, action: #selector(moveDown))
        let tools = ToolUI.stack([upButton!, downButton!, rotateButton!, deleteButton!, undoButton!], vertical: false, spacing: 8)
        exportButton = ToolUI.button("Export Selected…", target: self, action: #selector(exportSelected))
        saveButton = ToolUI.button("Save All Pages", target: self, action: #selector(saveAll)); saveButton.keyEquivalent = "\r"
        let footer = NSStackView(); footer.addView(status, in: .leading); footer.addView(exportButton, in: .trailing); footer.addView(saveButton, in: .trailing)
        let root = ToolUI.stack([ToolUI.note("Select pages to export, drag rows to reorder, or remove unwanted pages. Save creates a new PDF beside the first original."),
                                 ToolUI.stack([range, select, all], vertical: false), tools, scroll, footer])
        install(root)
        for v in [scroll, footer] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        updateButtons()
        runWork {
            let value = try await Images.detached { try PDFPagesSnapshot.load(urls) }
            self.snapshot = value; self.items = value.items; self.documents = value.data.compactMapValues(PDFDocument.init(data:))
            self.table.reloadData(); self.table.selectRowIndexes([0], byExtendingSelection: false)
        }
    }

    private var selected: IndexSet { table.selectedRowIndexes.intersection(IndexSet(items.indices)) }
    private func updateButtons() {
        let ready = !isBusy && snapshot != nil && Feature.pdfPages.isOn
        exportButton?.isEnabled = ready && !selected.isEmpty
        saveButton?.isEnabled = ready && !items.isEmpty
        for button in [deleteButton, rotateButton, upButton, downButton] { button?.isEnabled = ready && !selected.isEmpty }
        undoButton?.isEnabled = ready && !previous.isEmpty
        status.stringValue = snapshot == nil ? L("Choose a PDF to get started.") : L("%d pages · %d selected", items.count, selected.count)
    }
    override func workFinished() { updateButtons() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    @objc private func selectAllPages() { guard !isBusy else { return }; table.selectAll(nil) }
    @objc private func selectRange() {
        guard !isBusy else { return }
        do { table.selectRowIndexes(try PDFPageOrder.parse(range.stringValue, count: items.count), byExtendingSelection: false) }
        catch { status.stringValue = error.localizedDescription; ToolUI.refuse(range) }
    }
    private func change(_ next: [PDFPageItem], select ids: Set<UUID> = []) {
        guard Feature.pdfPages.isOn, !isBusy, next != items else { return }
        previous.append(items); items = next
        table.reloadData(); table.selectRowIndexes(IndexSet(items.indices.filter { ids.contains(items[$0].id) }), byExtendingSelection: false)
        updateButtons()
    }
    @objc private func removePages() { let indexes = selected; change(items.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)) }
    @objc private func rotatePages() {
        var next = items
        for i in selected { next[i].rotation = (next[i].rotation + 90) % 360; thumbnails.removeValue(forKey: next[i].id) }
        change(next, select: Set(selected.map { items[$0].id }))
    }
    @objc private func moveUp() {
        guard let first = selected.first, first > 0 else { return }
        change(PDFPageOrder.moving(items, indexes: selected, to: first - 1), select: Set(selected.map { items[$0].id }))
    }
    @objc private func moveDown() {
        guard let last = selected.last, last < items.count - 1 else { return }
        change(PDFPageOrder.moving(items, indexes: selected, to: last + 2), select: Set(selected.map { items[$0].id }))
    }
    @objc private func undoEdit() {
        guard Feature.pdfPages.isOn, !isBusy, let value = previous.popLast() else { return }
        items = value; thumbnails.removeAll(); table.reloadData(); updateButtons()
    }
    @objc private func exportSelected() { save(selected.map { items[$0] }) }
    @objc private func saveAll() { save(items) }
    private func save(_ pages: [PDFPageItem]) {
        guard let snapshot, !pages.isEmpty else { return }
        runWork {
            let out = try await Images.detached { try snapshot.export(pages) }
            Toast.shared.show(L("Saved %@", out.lastPathComponent), symbol: "checkmark.circle.fill", files: [out])
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        if tableColumn?.identifier.rawValue == "preview" {
            if thumbnails[item.id] == nil, let sourcePage = documents[item.source]?.page(at: item.page)?.copy() as? PDFPage {
                sourcePage.rotation = (sourcePage.rotation + item.rotation) % 360
                thumbnails[item.id] = sourcePage.thumbnail(of: NSSize(width: 70, height: 90), for: .cropBox)
            }
            let view = NSImageView(); view.image = thumbnails[item.id]; view.imageScaling = .scaleProportionallyUpOrDown
            view.setAccessibilityLabel(L("Page %d", row + 1)); return view
        }
        let value = tableColumn?.identifier.rawValue == "page" ? L("Page %d", row + 1) : L("%@ · original page %d", item.source.lastPathComponent, item.page + 1)
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = value; return label
    }
    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        guard !isBusy else { return false }
        pboard.declareTypes([dragType], owner: nil)
        pboard.setString(rowIndexes.map(String.init).joined(separator: ","), forType: dragType); return true
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !isBusy, Feature.pdfPages.isOn, info.draggingSource as? NSTableView === table else { return [] }
        table.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard !isBusy, info.draggingSource as? NSTableView === table,
              let value = info.draggingPasteboard.string(forType: dragType) else { return false }
        let indexes = IndexSet(value.split(separator: ",").compactMap { Int($0) }).intersection(IndexSet(items.indices))
        let ids = Set(indexes.map { items[$0].id })
        change(PDFPageOrder.moving(items, indexes: indexes, to: row), select: ids); return true
    }
}
