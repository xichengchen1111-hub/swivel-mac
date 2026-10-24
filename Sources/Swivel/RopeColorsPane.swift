import AppKit

/// Independent rope/peg colours, shared by the real clothesline and the pop-up template.
final class RopeColorsView: NSView {
    private let rope = NSPopUpButton()
    private let peg = NSPopUpButton()
    private let ropeWell = NSColorWell()
    private let pegWell = NSColorWell()
    private let preview = PreviewHost()
    private var displayed: ClotheslineColors?
    private var observer: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: L("Rope & peg colors"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let note = ToolUI.note("Choose rope and peg colors separately. Changes apply to the clothesline and its pop-up menu template.")
        note.preferredMaxLayoutWidth = 740
        note.widthAnchor.constraint(equalToConstant: 740).isActive = true
        for (popup, well, name, tag) in [(rope, ropeWell, "Rope color", 0), (peg, pegWell, "Peg color", 1)] {
            popup.addItems(withTitles: RopeColorPreset.allCases.map(\.title))
            for (index, preset) in RopeColorPreset.allCases.enumerated() {
                if let color = preset.rgb?.color {
                    popup.item(at: index)?.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                        color.setFill()
                        NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
                        return true
                    }
                }
            }
            popup.tag = tag
            popup.target = self
            popup.action = #selector(picked(_:))
            popup.setAccessibilityLabel(L(name))
            well.tag = tag
            well.target = self
            well.action = #selector(customized(_:))
            well.setAccessibilityLabel(L(tag == 0 ? "Custom rope color" : "Custom peg color"))
            well.widthAnchor.constraint(equalToConstant: 42).isActive = true
            well.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        func row(_ name: String, _ popup: NSPopUpButton, _ well: NSColorWell) -> NSStackView {
            let label = NSTextField(labelWithString: L(name))
            label.widthAnchor.constraint(equalToConstant: 120).isActive = true
            let row = NSStackView(views: [label, popup, well])
            row.spacing = 12
            return row
        }
        preview.isInteractive = false
        preview.widthAnchor.constraint(equalToConstant: 740).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 190).isActive = true
        let reset = ToolUI.button("Reset rope colors", target: self, action: #selector(reset))
        let stack = ToolUI.stack([title, note, row("Rope color", rope, ropeWell), row("Peg color", peg, pegWell), preview, reset])
        ToolUI.embed(stack, in: self, inset: 0)
        observer = NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func refresh() {
        let colors = Prefs.clotheslineColors
        rope.selectItem(at: RopeColorPreset.allCases.firstIndex(of: .matching(colors.rope)) ?? 0)
        peg.selectItem(at: RopeColorPreset.allCases.firstIndex(of: .matching(colors.peg)) ?? 0)
        ropeWell.color = colors.rope.color
        pegWell.color = colors.peg.color
        if displayed != colors {
            displayed = colors
            preview.show(menuPreview(style: .clothesline, titles: ["Copy", "Move", "AirDrop", "Copy Path", "Terminal", "Hang"], mode: .actions))
        }
    }

    @objc private func picked(_ sender: NSPopUpButton) {
        let preset = RopeColorPreset.allCases[max(sender.indexOfSelectedItem, 0)]
        guard let rgb = preset.rgb else {
            (sender.tag == 0 ? ropeWell : pegWell).activate(true)
            refresh() // Cancelling the picker keeps the stored preset selected.
            return
        }
        var colors = Prefs.clotheslineColors
        if sender.tag == 0 { colors.rope = rgb } else { colors.peg = rgb }
        Prefs.clotheslineColors = colors
    }

    @objc private func customized(_ sender: NSColorWell) {
        guard let rgb = RGBColor(sender.color) else { return }
        var colors = Prefs.clotheslineColors
        if sender.tag == 0 { colors.rope = rgb } else { colors.peg = rgb }
        Prefs.clotheslineColors = colors
    }

    @objc private func reset() { Prefs.clotheslineColors = ClotheslineColors(); refresh() }
}
