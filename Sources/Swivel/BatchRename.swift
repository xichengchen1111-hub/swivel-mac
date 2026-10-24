import AppKit
import Darwin

struct RenameRules: Equatable, Sendable {
    var base = ""
    var find = ""
    var replacement = ""
    var prefix = ""
    var suffix = ""
    var number = false
    var start = 1
    var digits = 3

    func name(for url: URL, index: Int) -> String {
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let ext = directory ? "" : url.pathExtension
        var stem = base.isEmpty ? (ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent) : base
        if !find.isEmpty { stem = stem.replacingOccurrences(of: find, with: replacement) }
        stem = prefix + stem + suffix
        if number {
            let value = start.addingReportingOverflow(index)
            guard !value.overflow else { return "" }
            stem += "-" + String(format: "%0*d", min(8, max(1, digits)), value.partialValue)
        }
        return ext.isEmpty ? stem : stem + "." + ext
    }
}

/// lstat identifies the selected directory entry, including a symlink itself rather than its target.
struct FileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else {
            throw ToolError(L("Could not access %@", url.path))
        }
        return Self(device: info.st_dev, inode: UInt64(info.st_ino))
    }
}

struct RenameEntry: Sendable {
    let source: URL
    let destination: URL
    let identity: FileIdentity?
    var issue: String?
    var changes: Bool { source.path != destination.path }
}

struct RenamePlan: Sendable {
    var entries: [RenameEntry]
    var canApply: Bool { !entries.isEmpty && entries.allSatisfy { $0.issue == nil } && entries.contains(where: \.changes) }
    var changedCount: Int { entries.filter(\.changes).count }

    static func preview(_ urls: [URL], rules: RenameRules) -> Self {
        var seen = Set<URL>()
        let files = urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        return validate(files.enumerated().map { index, url in
            let name = rules.name(for: url, index: index)
            var issue: String?
            if !validName(name) || rules.start < 0 || !(1...8).contains(rules.digits) {
                issue = L("Invalid name or numbering")
            }
            return RenameEntry(source: url, destination: url.deletingLastPathComponent().appendingPathComponent(name),
                               identity: try? FileIdentity.read(url), issue: issue)
        })
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") &&
        !name.contains("/") && !name.contains(":") && !name.contains("\0") &&
        name.utf8.count <= 255 && !name.contains(where: { $0.isNewline })
    }

    /// Conservatively compare canonically equivalent names, respecting each volume's case sensitivity.
    static func key(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        let sensitive = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
        let path = url.path.precomposedStringWithCanonicalMapping
        return sensitive ? path : path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func validate(_ original: [RenameEntry]) -> Self {
        var rows = original
        let sources = Set(rows.map { key($0.source) })
        let destinations = Dictionary(grouping: rows.indices, by: { key(rows[$0].destination) })
        for i in rows.indices {
            let row = rows[i]
            if !validName(row.destination.lastPathComponent) || row.source.deletingLastPathComponent().path != row.destination.deletingLastPathComponent().path {
                rows[i].issue = L("Invalid name or numbering")
            }
            if row.identity == nil { rows[i].issue = L("File is missing or unavailable") }
            if (destinations[key(row.destination)]?.count ?? 0) > 1 { rows[i].issue = L("Duplicate destination name") }
            if (try? FileIdentity.read(row.destination)) != nil && !sources.contains(key(row.destination)) {
                rows[i].issue = L("A file with this name already exists")
            }
            if rows.contains(where: { other in row.source.path.hasPrefix(other.source.path + "/") }) {
                rows[i].issue = L("Choose a folder or its contents, not both")
            }
        }
        return Self(entries: rows)
    }
}

struct RenameReceipt: Sendable {
    let entries: [RenameEntry]
    func undo() throws -> RenameReceipt {
        try BatchRenamer.execute(RenamePlan.validate(entries.map {
            RenameEntry(source: $0.destination, destination: $0.source, identity: $0.identity, issue: nil)
        }))
    }
}

enum BatchRenamer {
    /// Atomic no-replace renames prevent a file created after preview from ever being overwritten. Volumes without
    /// RENAME_EXCL (exFAT) get the same guarantee from an exclusive placeholder (`Paths.renameExclusively`).
    static func move(_ source: URL, _ destination: URL) throws {
        do {
            try Paths.renameExclusively(source, to: destination)
        } catch {
            throw ToolError(L("Could not rename %@ to %@", source.path, destination.path))
        }
    }

    static func execute(_ plan: RenamePlan, moveFile: (URL, URL) throws -> Void = move) throws -> RenameReceipt {
        guard plan.canApply, RenamePlan.validate(plan.entries).canApply else { throw ToolError(L("Resolve the highlighted conflicts first.")) }
        let rows = plan.entries.filter(\.changes)
        for row in rows {
            guard try FileIdentity.read(row.source) == row.identity else { throw ToolError(L("Files changed since preview. Refresh and try again.")) }
        }
        // Stage beside each source so case-only changes and name swaps work on the same volume.
        let staging = rows.map { $0.source.deletingLastPathComponent().appendingPathComponent(".swivel-rename-" + UUID().uuidString) }
        var current = rows.map(\.source)
        do {
            for i in rows.indices {
                guard try FileIdentity.read(current[i]) == rows[i].identity else { throw ToolError(L("Files changed since preview. Refresh and try again.")) }
                try moveFile(current[i], staging[i]); current[i] = staging[i]
            }
            for i in rows.indices {
                guard try FileIdentity.read(current[i]) == rows[i].identity else { throw ToolError(L("Files changed since preview. Refresh and try again.")) }
                try moveFile(current[i], rows[i].destination); current[i] = rows[i].destination
            }
        } catch {
            // First free any completed destinations, then restore originals. Never remove a conflicting file.
            for i in rows.indices where current[i] != rows[i].source && current[i] != staging[i] {
                if (try? FileIdentity.read(current[i])) == rows[i].identity,
                   (try? moveFile(current[i], staging[i])) != nil { current[i] = staging[i] }
            }
            for i in rows.indices where current[i] != rows[i].source {
                if (try? FileIdentity.read(current[i])) == rows[i].identity,
                   (try? moveFile(current[i], rows[i].source)) != nil { current[i] = rows[i].source }
            }
            let remaining = rows.indices.filter { current[$0] != rows[$0].source }.map { current[$0].path }
            if !remaining.isEmpty {
                throw ToolError(L("Some files could not be restored. They remain at:\n%@", remaining.joined(separator: "\n")))
            }
            throw error
        }
        return RenameReceipt(entries: rows)
    }
}

@MainActor
final class BatchRenameWindow: FileToolWindow, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var urls: [URL]
    let base = NSTextField(), find = NSTextField(), replacement = NSTextField(), prefix = NSTextField(), suffix = NSTextField()
    let numbering = NSButton(checkboxWithTitle: L("Add a number"), target: nil, action: nil)
    let start = NSTextField(string: "1"), digits = NSPopUpButton()
    let table = NSTableView()
    let status = ToolUI.note("")
    private(set) var plan = RenamePlan(entries: [])
    private var receipt: RenameReceipt?
    private var resultMessage: String?
    private var applyButton: NSButton!, undoButton: NSButton!

    init(_ urls: [URL]) {
        self.urls = urls
        super.init(feature: .batchRename, title: "Batch Rename", size: NSSize(width: 850, height: 690))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("Base name")), base, NSTextField(labelWithString: L("Keep the original name when empty"))],
            [NSTextField(labelWithString: L("Find")), find, replacement],
            [NSTextField(labelWithString: L("Prefix")), prefix, suffix],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10; grid.columnSpacing = 10
        base.placeholderString = L("Original name"); replacement.placeholderString = L("Replace with")
        suffix.placeholderString = L("Suffix")
        for field in [base, find, replacement, prefix, suffix] {
            field.delegate = self
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        }
        for (field, name) in [(base, "Base name"), (find, "Find"), (replacement, "Replace with"), (prefix, "Prefix"), (suffix, "Suffix"), (start, "Start at")] {
            field.setAccessibilityLabel(L(name))
        }
        numbering.target = self; numbering.action = #selector(changed)
        start.delegate = self; start.widthAnchor.constraint(equalToConstant: 80).isActive = true
        digits.addItems(withTitles: ["1", "2", "3", "4", "5", "6", "7", "8"]); digits.selectItem(at: 2)
        digits.target = self; digits.action = #selector(changed); digits.setAccessibilityLabel(L("Digits"))
        let numbers = ToolUI.stack([numbering, NSTextField(labelWithString: L("Start at")), start,
                                    NSTextField(labelWithString: L("Digits")), digits], vertical: false)
        for (id, title, width) in [("old", "Current name", 230.0), ("new", "New name", 260.0), ("status", "Status", 240.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = L(title); column.width = width
            table.addTableColumn(column)
        }
        table.style = .inset; table.rowHeight = 28; table.dataSource = self; table.delegate = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        applyButton = ToolUI.button("Rename Files", target: self, action: #selector(applyRename))
        applyButton.keyEquivalent = "\r"
        undoButton = ToolUI.button("Undo Rename", target: self, action: #selector(undoRename)); undoButton.isEnabled = false
        let choose = ToolUI.button("Choose Files…", target: self, action: #selector(chooseFiles))
        let footer = NSStackView(); footer.addView(choose, in: .leading); footer.addView(undoButton, in: .trailing); footer.addView(applyButton, in: .trailing)
        let root = ToolUI.stack([ToolUI.note("This changes original file names. Review every new name before renaming. Extensions are kept."), grid, numbers, scroll, status, footer])
        install(root)
        for v in [scroll, status, footer] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        refreshPreview()
    }

    var rules: RenameRules {
        RenameRules(base: base.stringValue, find: find.stringValue, replacement: replacement.stringValue,
                    prefix: prefix.stringValue, suffix: suffix.stringValue, number: numbering.state == .on,
                    start: Int(start.stringValue) ?? -1, digits: digits.indexOfSelectedItem + 1)
    }
    func controlTextDidChange(_ obj: Notification) { resultMessage = nil; refreshPreview() }
    @objc private func changed() { resultMessage = nil; refreshPreview() }
    func refreshPreview() {
        plan = RenamePlan.preview(urls, rules: rules)
        table.reloadData(); applyButton.isEnabled = !isBusy && plan.canApply && Feature.batchRename.isOn
        start.isEnabled = numbering.state == .on; digits.isEnabled = numbering.state == .on
        status.stringValue = resultMessage ?? (plan.entries.contains { $0.issue != nil } ? L("Resolve the highlighted conflicts first.") : L("%d files will be renamed", plan.changedCount))
    }
    @objc private func chooseFiles() {
        guard !isBusy else { return }
        let chosen = ToolUI.chooseFiles(folders: true)
        if !chosen.isEmpty { urls = chosen; receipt = nil; resultMessage = nil; undoButton.isEnabled = false; refreshPreview() }
    }
    @objc private func applyRename() {
        guard Feature.batchRename.isOn, !isBusy, plan.canApply else { return }
        let snapshot = plan
        runWork {
            let value = try await Images.detached { try BatchRenamer.execute(snapshot) }
            self.receipt = value
            self.urls = snapshot.entries.map(\.destination)
            self.undoButton.isEnabled = true
            self.refreshPreview()
            self.resultMessage = L("Renamed %d files. Undo is available in this window.", value.entries.count)
        }
    }
    @objc private func undoRename() {
        guard Feature.batchRename.isOn, !isBusy, let receipt else { return }
        runWork {
            _ = try await Images.detached { try receipt.undo() }
            self.urls = self.urls.map { url in receipt.entries.first { $0.destination == url }?.source ?? url }
            self.receipt = nil; self.undoButton.isEnabled = false; self.refreshPreview()
            self.resultMessage = L("Original names restored")
        }
    }
    override func workFinished() { refreshPreview(); undoButton.isEnabled = receipt != nil }
    func numberOfRows(in tableView: NSTableView) -> Int { plan.entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = plan.entries[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "old": value = entry.source.lastPathComponent
        case "new": value = entry.destination.lastPathComponent
        default: value = entry.issue ?? L(entry.changes ? "Ready" : "Unchanged")
        }
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = value
        if entry.issue != nil { label.textColor = .systemRed }
        return label
    }
}
