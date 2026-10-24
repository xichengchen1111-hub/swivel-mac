import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ImagePreset: Codable, Equatable, Identifiable, Sendable {
    enum Format: String, Codable, CaseIterable, Sendable {
        case jpeg, png, heic, tiff
        var title: String { self == .jpeg ? "JPG" : rawValue.uppercased() }
        var type: UTType {
            switch self { case .jpeg: .jpeg; case .png: .png; case .heic: .heic; case .tiff: .tiff }
        }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var isLossy: Bool { self == .jpeg || self == .heic }
    }

    var id: String
    var name: String
    var nameKey: String?
    var longEdge: Int // 0 keeps the original dimensions; never enlarge.
    var format: Format
    var quality: Int
    var stripMetadata: Bool

    var displayName: String { nameKey.map { L($0) } ?? name }
    var actionID: String { "preset.\(id)" }
    var isValid: Bool {
        !id.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 60 &&
        (longEdge == 0 || (64...16384).contains(longEdge)) && (1...100).contains(quality)
    }
    /// The long-edge field as typed: whole pixels, surrounding spaces allowed.
    static func longEdge(from text: String) -> Int? { Int(text.trimmingCharacters(in: .whitespaces)) }

    /// Which field of the preset form is wrong (the first one, top to bottom), so the sheet can point at it.
    static func formIssue(name: String, longEdge text: String) -> FormIssue? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 60 { return .name }
        guard let pixels = longEdge(from: text), pixels == 0 || (64...16384).contains(pixels) else { return .size }
        return nil
    }

    enum FormIssue: Equatable { case name, size }

    var summary: String {
        let size = longEdge == 0 ? L("Original size") : L("Long edge %d px", longEdge)
        let qualityText = format.isLossy ? " · " + L("Quality %d%%", quality) : ""
        return "\(size) · \(format.title)\(qualityText) · " + L(stripMetadata ? "Remove metadata" : "Keep metadata")
    }

    static let starters: [ImagePreset] = [
        .init(id: "web", name: "Web JPG", nameKey: "Web JPG", longEdge: 1600, format: .jpeg, quality: 80, stripMetadata: true),
        .init(id: "small-png", name: "Small PNG", nameKey: "Small PNG", longEdge: 1200, format: .png, quality: 100, stripMetadata: true),
        .init(id: "full-jpg", name: "Full-size JPG", nameKey: "Full-size JPG", longEdge: 0, format: .jpeg, quality: 92, stripMetadata: false),
    ]

    /// Encode entirely before writing, so a failed conversion leaves no half-written result.
    func apply(to url: URL) throws -> URL {
        guard isValid else { throw ToolError(L("Check the preset name, size and quality.")) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ToolError(L("Could not read %@", url.lastPathComponent))
        }
        let image = try Images.load(url, maxPixels: longEdge == 0 ? nil : longEdge)
        var properties = stripMetadata ? [:] : (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:])
        // Images.load has already applied EXIF orientation to the pixels.
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        properties[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        let pixels = format == .jpeg && image.hasAlpha ? image.flattened() : image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw ToolError(L("This image format is not available on this Mac."))
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ToolError(L("Could not encode the image.")) }
        return try Paths.create(data as Data, at: Paths.preferred(for: url, ext: format.fileExtension, suffix: " processed"))
    }
}

@MainActor
enum PresetActions {
    /// `progress` hears (files finished, total) before each file, so a caller can show how far along it is.
    static func run(_ preset: ImagePreset, urls: [URL], progress: ((Int, Int) -> Void)? = nil) async throws -> ActionResult {
        guard Feature.imagePresets.isOn else { throw ToolError(L("This feature is turned off.")) }
        var output: [URL] = []
        var failures: [String] = []
        for (index, url) in urls.enumerated() {
            progress?(index, urls.count)
            do {
                let result = try await Images.detached { try preset.apply(to: url) }
                output.append(result)
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("Saved %d files; %d could not be processed.", output.count, failures.count)
            alert.informativeText = failures.prefix(8).joined(separator: "\n")
            alert.addButton(withTitle: L("OK"))
            NSApp.activate()
            alert.runModal()
        }
        return ActionResult(message: failures.isEmpty ? L("Saved %d files", output.count) : L("Saved %d files; %d could not be processed.", output.count, failures.count), files: output)
    }
}

/// A conventional form sheet; drafts are only persisted when Save is pressed.
@MainActor
final class PresetEditor: NSObject, NSTextFieldDelegate {
    private let panel: NSPanel
    private let original: ImagePreset
    private let name = NSTextField()
    private let edge = NSTextField()
    private let format = NSPopUpButton(frame: .zero, pullsDown: false)
    private let quality = NSSlider(value: 80, minValue: 1, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "")
    private let strip = NSButton(checkboxWithTitle: L("Remove metadata"), target: nil, action: nil)
    private let errorLabel = ToolUI.note("")
    private let saved: (ImagePreset) -> Void
    /// The round quality value the slider is resting in, if any.
    private var detent: Double?

    init(preset: ImagePreset?, saved: @escaping (ImagePreset) -> Void) {
        original = preset ?? ImagePreset(id: UUID().uuidString, name: L("My Preset"), longEdge: 1600, format: .jpeg, quality: 80, stripMetadata: true)
        self.saved = saved
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = L(preset == nil ? "New Preset" : "Edit Preset")
        name.stringValue = original.displayName
        edge.stringValue = String(original.longEdge)
        name.setAccessibilityLabel(L("Name"))
        edge.setAccessibilityLabel(L("Long edge (px)"))
        name.delegate = self
        edge.delegate = self
        format.addItems(withTitles: ImagePreset.Format.allCases.map(\.title))
        format.selectItem(at: ImagePreset.Format.allCases.firstIndex(of: original.format) ?? 0)
        format.target = self; format.action = #selector(changed(_:))
        quality.doubleValue = Double(original.quality)
        quality.target = self; quality.action = #selector(changed(_:))
        quality.setAccessibilityLabel(L("Quality"))
        strip.state = original.stripMetadata ? .on : .off
        let qualityRow = ToolUI.stack([quality, qualityLabel], vertical: false)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("Name")), name],
            [NSTextField(labelWithString: L("Long edge (px)")), edge],
            [NSTextField(labelWithString: L("Format")), format],
            [NSTextField(labelWithString: L("Quality")), qualityRow],
            [NSGridCell.emptyContentView, strip],
        ])
        grid.rowSpacing = 14; grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        name.widthAnchor.constraint(equalToConstant: 290).isActive = true
        quality.widthAnchor.constraint(equalToConstant: 210).isActive = true
        qualityLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let hint = ToolUI.note("Use 0 for original size, or 64–16384 px. Small images are never enlarged. JPG uses a white background for transparency.")
        let cancel = ToolUI.button("Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = ToolUI.button("Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.addView(cancel, in: .trailing); buttons.addView(save, in: .trailing)
        let root = ToolUI.stack([grid, hint, errorLabel, buttons], spacing: 16)
        let content = NSView(); panel.contentView = content
        ToolUI.embed(root, in: content)
        for view in [hint, errorLabel, buttons] { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        errorLabel.textColor = .systemRed
        changed(nil)
    }

    func present(on window: NSWindow) {
        window.beginSheet(panel) { [self] _ in panel.orderOut(nil) }
        panel.makeFirstResponder(name)
    }

    @objc private func changed(_ sender: Any?) {
        // Only while dragging: arrow keys must still be able to step through 9, 10, 11.
        if (sender as? NSSlider) === quality, NSEvent.pressedMouseButtons & 1 != 0 { settleOnDetent() }
        qualityLabel.stringValue = L("%d%%", quality.integerValue)
        quality.isEnabled = ImagePreset.Format.allCases[format.indexOfSelectedItem].isLossy
    }

    /// Round qualities (10, 20 … 100) hold the knob for most of a point either side, with a detent tap on the
    /// trackpad as it settles in. The % label is the visual cue for mice.
    private func settleOnDetent() {
        let snapped = QualityDetent.snap(quality.doubleValue)
        guard QualityDetent.isDetent(snapped) else { detent = nil; return }
        quality.doubleValue = snapped
        if detent != snapped { Haptics.tick(.alignment) }
        detent = snapped
    }

    /// Once an error is showing, it follows the typing and clears as soon as the field is fixed.
    func controlTextDidChange(_ obj: Notification) {
        guard !errorLabel.stringValue.isEmpty else { return }
        errorLabel.stringValue = message(for: ImagePreset.formIssue(name: name.stringValue, longEdge: edge.stringValue))
    }

    private func message(for issue: ImagePreset.FormIssue?) -> String {
        switch issue {
        case .name: L("Give the preset a name of up to 60 characters.")
        case .size: L("Enter 0, or a size from 64 to 16384 px.")
        case nil: ""
        }
    }

    @objc private func cancel() { panel.sheetParent?.endSheet(panel) }
    @objc private func save() {
        if let issue = ImagePreset.formIssue(name: name.stringValue, longEdge: edge.stringValue) {
            refuse(issue == .name ? name : edge, message(for: issue))
            return
        }
        var value = original
        value.name = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.name != original.displayName { value.nameKey = nil }
        value.longEdge = ImagePreset.longEdge(from: edge.stringValue) ?? original.longEdge
        value.format = ImagePreset.Format.allCases[format.indexOfSelectedItem]
        value.quality = quality.integerValue
        value.stripMetadata = strip.state == .on
        guard value.isValid else { refuse(name, L("Check the preset name, size and quality.")); return }
        saved(value)
        panel.sheetParent?.endSheet(panel)
    }

    /// Points at the field that's wrong: says why, selects its text for retyping, and shakes it.
    private func refuse(_ field: NSTextField, _ text: String) {
        errorLabel.stringValue = text
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        ToolUI.refuse(field)
    }
}

/// Soft detents on the quality slider.
enum QualityDetent {
    /// Values within 0.75 of a multiple of ten (10…100) snap to it; anything else is left alone, so 9 and 11 can
    /// still be picked.
    static func snap(_ value: Double) -> Double {
        let nearest = (value / 10).rounded() * 10
        return nearest >= 10 && abs(value - nearest) <= 0.75 ? nearest : value
    }

    static func isDetent(_ value: Double) -> Bool { value >= 10 && value.truncatingRemainder(dividingBy: 10) == 0 }
}
