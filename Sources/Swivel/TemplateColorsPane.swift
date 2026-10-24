import AppKit

/// A palette editor for each template. Neither choosing colours nor trying a preview selects the active menu style.
final class TemplateColorsPane: Pane {
    private let template = NSPopUpButton()
    private let preset = NSPopUpButton()
    private let wells = (0..<5).map { _ in NSColorWell() }
    private let preview = PreviewHost()
    private let railRow = NSStackView()
    private var displayed: TemplatePalette?
    private var area: ColorTemplate { ColorTemplate.allCases[max(template.indexOfSelectedItem, 0)] }

    init() { super.init(size: NSSize(width: 860, height: 640)) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        stack.addArrangedSubview(label("Template colors", size: 22, weight: .bold))
        stack.addArrangedSubview(label("Choose a soft palette or pick your own colors. Bookshelf and Sticky Notes save their colors separately.", secondary: true))
        template.addItems(withTitles: ColorTemplate.allCases.map(\.title))
        template.setAccessibilityLabel(L("Color template"))
        template.target = self
        template.action = #selector(templateChanged)
        stack.addArrangedSubview(row("Template", template))
        preset.addItems(withTitles: TemplateColorPreset.allCases.map(\.title))
        preset.setAccessibilityLabel(L("Template palette"))
        preset.target = self
        preset.action = #selector(presetChanged)
        let swatches = NSStackView()
        swatches.spacing = 8
        for (index, well) in wells.enumerated() {
            well.tag = index
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 48).isActive = true
            well.heightAnchor.constraint(equalToConstant: 32).isActive = true
            well.setAccessibilityLabel(index == 4 ? L("Shelf color") : L("Palette color %d", index + 1))
            if index < 4 {
                let name = label(L("Color %d", index + 1), size: 11)
                let column = ToolUI.stack([well, name], spacing: 4)
                column.widthAnchor.constraint(equalToConstant: 72).isActive = true
                swatches.addArrangedSubview(column)
            }
        }
        railRow.addArrangedSubview(label("Shelf color"))
        railRow.addArrangedSubview(wells[4])
        railRow.spacing = 12
        let hint = label("Click a swatch to choose any color. The four colors repeat across items; dark appearance adjusts them for readability.", size: 12, secondary: true)
        hint.preferredMaxLayoutWidth = 320
        hint.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let reset = ToolUI.button("Reset this palette", target: self, action: #selector(reset))
        let controls = ToolUI.stack([label("Palette", weight: .semibold), preset, swatches, railRow, hint, reset], spacing: 16)
        controls.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let wallpaper = WallpaperView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        wallpaper.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: wallpaper.leadingAnchor), preview.trailingAnchor.constraint(equalTo: wallpaper.trailingAnchor),
            preview.topAnchor.constraint(equalTo: wallpaper.topAnchor), preview.bottomAnchor.constraint(equalTo: wallpaper.bottomAnchor),
            wallpaper.widthAnchor.constraint(equalToConstant: 410), wallpaper.heightAnchor.constraint(equalToConstant: 300),
        ])
        let columns = NSStackView(views: [controls, wallpaper])
        columns.alignment = .top
        columns.spacing = 24
        stack.addArrangedSubview(columns)
        stack.addArrangedSubview(tryItHint())
    }

    override func refresh() {
        let palette = Prefs.templateColors[area]
        preset.selectItem(at: TemplateColorPreset.allCases.firstIndex(of: .matching(palette)) ?? 0)
        for i in 0..<4 { wells[i].color = palette.colors[i].color }
        wells[4].color = palette.rail.color
        railRow.isHidden = area != .shelf
        if displayed != palette {
            displayed = palette
            preview.show(menuPreview(style: area.style, titles: ["JPG", "PNG", "HEIC", "TIFF", "PDF", "GIF", "AVIF", "BMP"], mode: .convert))
        }
    }

    @objc private func templateChanged() {
        for well in wells { well.deactivate() }
        displayed = nil
        refresh()
    }

    @objc private func presetChanged() {
        let choice = TemplateColorPreset.allCases[max(preset.indexOfSelectedItem, 0)]
        guard let palette = choice.palette else { wells[0].activate(true); refresh(); return }
        for well in wells { well.deactivate() }
        var settings = Prefs.templateColors
        settings[area] = palette
        Prefs.templateColors = settings
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let color = RGBColor(sender.color) else { return }
        var settings = Prefs.templateColors
        var palette = settings[area]
        if sender.tag == 4 { palette.rail = color } else { palette.colors[sender.tag] = color }
        settings[area] = palette
        Prefs.templateColors = settings
    }

    @objc private func reset() {
        for well in wells { well.deactivate() }
        var settings = Prefs.templateColors
        settings[area] = .native
        Prefs.templateColors = settings
        refresh()
    }
}
