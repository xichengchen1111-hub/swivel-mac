import AppKit
import Vision

struct DetectedCode: Equatable, Sendable {
    let source: URL
    let kind: String
    let value: String
    var webURL: URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    /// Wi-Fi passwords and one-time-password secrets: copies ask clipboard managers not to keep a history copy.
    static func isSecret(_ value: String) -> Bool {
        ["wifi:", "otpauth:", "otpauth-migration:"].contains { value.lowercased().hasPrefix($0) }
    }
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

enum CodeRecognition {
    static func recognize(_ urls: [URL]) async throws -> [DetectedCode] {
        let work = Task.detached(priority: .userInitiated) {
            var result: [DetectedCode] = []
            for url in urls {
                try Task.checkCancellation()
                let image = try Images.load(url, maxPixels: 8000)
                let request = VNDetectBarcodesRequest()
                try VNImageRequestHandler(cgImage: image).perform([request])
                var seen = Set<String>()
                let observations = (request.results ?? []).sorted {
                    abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.05 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
                }
                for observation in observations {
                    guard let payload = observation.payloadStringValue, !payload.isEmpty,
                          seen.insert(observation.symbology.rawValue + "\0" + payload).inserted else { continue }
                    result.append(DetectedCode(source: url, kind: observation.symbology.rawValue, value: payload))
                }
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}

@MainActor
final class QRCodesWindow: FileToolWindow, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var codes: [DetectedCode] = []
    let table = NSTableView()
    let text = CaptureTextView()
    let status = ToolUI.note("Reading codes…")
    var pasteboard = NSPasteboard.general
    private var copyButton: NSButton!, openButton: NSButton!, saveButton: NSButton!
    init(_ urls: [URL]) {
        super.init(feature: .qrCodes, title: "QR & Barcodes", size: NSSize(width: 760, height: 610))
        let column = NSTableColumn(identifier: .init("code")); column.title = L("Detected codes"); table.addTableColumn(column)
        table.style = .inset; table.rowHeight = 48; table.dataSource = self; table.delegate = self
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        list.heightAnchor.constraint(equalToConstant: 180).isActive = true
        text.isEditable = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.isRichText = false; text.isAutomaticLinkDetectionEnabled = false
        text.textContainerInset = NSSize(width: 10, height: 10); text.setAccessibilityLabel(L("Decoded content"))
        let content = NSScrollView(); content.documentView = text; content.hasVerticalScroller = true; content.borderType = .bezelBorder
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        copyButton = ToolUI.button("Copy Content", target: self, action: #selector(copyCode)); copyButton.keyEquivalent = "\r"
        openButton = ToolUI.button("Open Link…", target: self, action: #selector(openLink))
        saveButton = ToolUI.button("Save to Library", target: self, action: #selector(saveCode))
        let library = ToolUI.button("QR Library…", target: self, action: #selector(openLibrary))
        let footer = NSStackView(); footer.addView(status, in: .leading); footer.addView(openButton, in: .trailing); footer.addView(copyButton, in: .trailing)
        let root = ToolUI.stack([ToolUI.note("Read QR codes and barcodes from images on your Mac. Review the decoded content before copying or opening a link."), list, content, ToolUI.stack([saveButton!, library], vertical: false), footer])
        install(root)
        for v in [list, content, footer] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        updateButtons()
        runWork {
            self.codes = try await CodeRecognition.recognize(urls)
            self.table.reloadData()
            if !self.codes.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
        }
    }
    private var selected: DetectedCode? { codes.indices.contains(table.selectedRow) ? codes[table.selectedRow] : nil }
    private func updateButtons() {
        copyButton?.isEnabled = !isBusy && selected != nil
        openButton?.isEnabled = !isBusy && selected?.webURL != nil
        saveButton?.isEnabled = !isBusy && selected != nil
        text.string = selected?.value ?? ""
        status.stringValue = isBusy ? L("Reading codes…") : codes.isEmpty ? L("No readable QR codes or barcodes found.") : L("%d codes found", codes.count)
    }
    override func workFinished() { updateButtons() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    @objc private func copyCode() {
        guard Feature.qrCodes.isOn, !isBusy, let selected else { return }
        // The concealed marker is declared with the text, so a clipboard manager never sees the secret without it.
        let secret = DetectedCode.isSecret(selected.value)
        pasteboard.declareTypes(secret ? [.string, DetectedCode.concealed] : [.string], owner: nil)
        pasteboard.setString(selected.value, forType: .string)
        if secret { pasteboard.setString("", forType: DetectedCode.concealed) }
        Feedback.press()
        status.stringValue = L("Copied")
    }
    @objc private func saveCode() {
        guard Feature.qrCodes.isOn, !isBusy, let selected else { return }
        do {
            let value = try QRLibraryStore().add(SavedQRCode(name: selected.source.deletingPathExtension().lastPathComponent, value: selected.value))
            QRLibraryWindow(select: value.id).show()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func openLibrary() { QRLibraryWindow().show() }
    @objc private func openLink() {
        guard Feature.qrCodes.isOn, !isBusy, let url = selected?.webURL else { return }
        let alert = NSAlert(); alert.messageText = L("Open this link?"); alert.informativeText = url.absoluteString
        alert.addButton(withTitle: L("Open")); alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, Feature.qrCodes.isOn else { return }
            if !NSWorkspace.shared.open(url) { self.status.stringValue = L("Could not open the link.") }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { codes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let code = codes[row]
        let label = NSTextField(labelWithString: code.value); label.lineBreakMode = .byTruncatingMiddle
        let detail = ToolUI.note(code.source.lastPathComponent + " · " + code.kind)
        detail.lineBreakMode = .byTruncatingMiddle
        return ToolUI.stack([label, detail], spacing: 3)
    }
}
