import AppKit
import Testing
@testable import Swivel

@Suite(.serialized)
@MainActor
struct InteractionSettingsTests {
    @Test func presetsKeepReadingChoicesAndHaveDistinctFeel() throws {
        var seen: [InteractionSettings] = []
        for preset in FeelPreset.allCases {
            var settings = InteractionSettings()
            settings.textSize = .extraLarge
            settings.boldText = true
            settings.apply(preset)
            #expect(settings.textSize == .extraLarge && settings.boldText)
            #expect(settings.matchingPreset == preset)
            #expect(!seen.contains(settings))
            seen.append(settings)
            let decoded = try JSONDecoder().decode(InteractionSettings.self, from: JSONEncoder().encode(settings))
            #expect(decoded == settings)
        }
        var custom = InteractionSettings()
        custom[.clothesline] = MotionTuning(speed: 1.23, bounce: 0.31)
        #expect(custom.matchingPreset == nil)
        #expect(custom.menu == MotionTuning() && custom.tools == MotionTuning())
    }

    @Test func damagedNumbersCannotDestabilizeMotionOrAudio() {
        let bad = MotionTuning(speed: .infinity, bounce: .nan).sanitized
        #expect(bad == MotionTuning())
        #expect(MotionTuning(speed: -100, bounce: 50).sanitized == MotionTuning(speed: 0.75, bounce: 1))
        var settings = InteractionSettings()
        settings.volume = .nan
        #expect(settings.sanitized.volume == 1)
        #expect(SoundConfiguration(volume: -.infinity).volume == 1)
        #expect(SoundConfiguration(volume: 9).volume == 1)
        #expect(SoundConfiguration(volume: -9).volume == 0)
    }

    @Test func fasterSpringsMatchTheSameMotionEarlierWithoutChangingStateOnRetarget() {
        var normal = Spring(0, response: 0.3, damping: 0.7)
        normal.target = 1
        var fast = normal
        normal.step(0.1)
        fast.step(0.1 / 1.5, tuning: MotionTuning(speed: 1.5))
        #expect(abs(normal.value - fast.value) < 0.00001)
        let before = fast.value
        fast.target = 0
        fast.step(0, tuning: MotionTuning(speed: 0.75, bounce: 0))
        #expect(fast.value == before)
        var calm = Spring(0, response: 0.3, damping: 0.6)
        calm.target = 1
        for _ in 0..<240 {
            calm.step(1 / 120, tuning: MotionTuning(bounce: 0))
            #expect(calm.value <= 1)
        }
        #expect(calm.isSettled)
        #expect(MotionTuning(bounce: 1).damping(1) == 1) // colour and opacity
    }

    @Test func everyRopePresetAndSliderExtremeIsDampedAndSettles() {
        let tunes = [MotionTuning(speed: 0.75, bounce: 0), MotionTuning(speed: 0.75, bounce: 1),
                     MotionTuning(speed: 1.5, bounce: 0), MotionTuning(speed: 1.5, bounce: 1)]
        for tuning in tunes {
            for base in [RopeTuning.fall, .init(k: 150, c: 16), RopeTuning.swing, RopeTuning.arrive] {
                let oscillator = base.tuned(tuning)
                #expect(oscillator.dampingRatio >= 0.6 && oscillator.dampingRatio <= 1.00001)
                var x: CGFloat = -1, v: CGFloat = 0
                for _ in 0..<960 {
                    RopeTuning.advance(&x, &v, toward: 0, oscillator)
                    #expect(x.isFinite && v.isFinite && abs(x) <= 1.1)
                }
                #expect(abs(x) < 0.001 && abs(v) < 0.01)
            }
        }
    }

    @Test func audioStylesRespectVolumeAndNeverClip() {
        for style in SoundStyle.allCases {
            for effect in Sounds.Effect.allCases {
                let config = SoundConfiguration(style: style, volume: 0.25)
                let samples = SoundSynth.samples(effect, pitch: 1, gain: 1, configuration: config)
                let peak = samples.map { abs($0) }.max() ?? 0
                #expect(peak > 0 && peak <= Float(0.23 * 0.25 * style.gain))
                #expect(abs(samples.last ?? 1) < 0.001)
                let muted = SoundSynth.samples(effect, pitch: 1, gain: 1, configuration: .init(style: style, volume: 0))
                #expect(muted.allSatisfy { $0 == 0 })
            }
        }
        #expect(SoundConfiguration(style: .soft, volume: 0.5).cacheKey != SoundConfiguration(style: .soft, volume: 1).cacheKey)
    }

    @Test func typographyUpdatesExistingViewsWithoutCompoundingOrChangingFieldEditor() {
        let old = Prefs.interaction
        defer { Prefs.interaction = old }
        let root = NSView()
        let label = NSTextField(labelWithString: "Text")
        label.font = .systemFont(ofSize: 13)
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.font = .systemFont(ofSize: 13)
        root.addSubview(label)
        root.addSubview(editor)
        var settings = InteractionSettings()
        settings.textSize = .extraLarge
        Prefs.interaction = settings
        for _ in 0..<5 { AppTypography.apply(to: root) }
        #expect(abs((label.font?.pointSize ?? 0) - 16.9) < 0.01)
        #expect(editor.font?.pointSize == 13)
        settings.textSize = .standard
        Prefs.interaction = settings
        AppTypography.apply(to: root)
        #expect(label.font?.pointSize == 13)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @Test func settingsControlsPersistAndAreaChangesStayIndependent() throws {
        let old = Prefs.interaction, sounds = Prefs.soundEffects, haptics = Prefs.haptics
        defer { Prefs.interaction = old; Prefs.soundEffects = sounds; Prefs.haptics = haptics }
        Prefs.interaction = InteractionSettings()
        let pane = FeelPane()
        let controls = descendants(pane.view)
        let area = try #require(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == L("Motion area") })
        area.selectItem(at: 1)
        _ = NSApp.sendAction(try #require(area.action), to: area.target, from: area)
        let slider = try #require(controls.compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == L("Animation speed") })
        slider.doubleValue = 1.4
        _ = NSApp.sendAction(try #require(slider.action), to: slider.target, from: slider)
        #expect(Prefs.interaction.clothesline.speed == 1.4)
        #expect(Prefs.interaction.menu.speed == 1)
        let stored = try #require(UserDefaults.standard.data(forKey: "interaction.v1"))
        #expect(try JSONDecoder().decode(InteractionSettings.self, from: stored) == Prefs.interaction)
        Prefs.soundEffects = false
        Prefs.haptics = false
        let presets = try #require(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == L("Feel preset") })
        presets.selectItem(at: 3) // Snappy
        _ = NSApp.sendAction(try #require(presets.action), to: presets.target, from: presets)
        #expect(Prefs.interaction.matchingPreset == .snappy)
        #expect(!Prefs.soundEffects && !Prefs.haptics)
    }

    @Test func tuningPaneFitsAtEveryTextSizeAndNewStringsAreTranslated() {
        let old = Prefs.interaction
        defer { Prefs.interaction = old }
        let language = UserDefaults.standard.object(forKey: "language")
        defer {
            if let language { UserDefaults.standard.set(language, forKey: "language") }
            else { UserDefaults.standard.removeObject(forKey: "language") }
        }
        for locale in [Language.en, .zhHans, .zhHant, .ja] {
          UserDefaults.standard.set(locale.rawValue, forKey: "language")
          for size in TextSize.allCases {
            var settings = InteractionSettings()
            settings.textSize = size
            Prefs.interaction = settings
            let pane = FeelPane()
            _ = pane.view
            AppTypography.apply(to: pane.view)
            pane.view.layoutSubtreeIfNeeded()
            #expect(pane.stack.fittingSize.height <= pane.preferredContentSize.height)
            if let directory = ProcessInfo.processInfo.environment["SWIVEL_TUNING_RENDERS"] {
                let folder = URL(fileURLWithPath: directory)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    pane.view.appearance = NSAppearance(named: appearance)
                    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 860, pixelsHigh: 1400,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    image.size = pane.view.bounds.size
                    pane.view.cacheDisplay(in: pane.view.bounds, to: image)
                    try? image.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("feel-\(locale.rawValue)-\(size.rawValue)-\(appearance.rawValue).png"))
                }
            }
        }
        }
        for key in ["Feel & Text", "Motion", "Sound & touch", "Animation speed", "Extra Large", "Quiet", "Gentle trackpad taps"] {
            #expect(Strings.table[key]?.count == 3)
        }
    }

    @Test func ropeAndPegColorControlsPersistSeparatelyAndUpdateExistingPrints() throws {
        let old = Prefs.clotheslineColors
        defer { Prefs.clotheslineColors = old }
        Prefs.clotheslineColors = ClotheslineColors()
        let view = RopeColorsView()
        let controls = descendants(view)
        let ropePicker = try #require(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == L("Rope color") })
        let pegPicker = try #require(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == L("Peg color") })
        let ropeView = RopeView(frame: NSRect(x: 0, y: 0, width: 700, height: 214))
        ropeView.setItems([URL(fileURLWithPath: "/tmp/swivel-color-test-not-a-real-image.png")])
        let line = try #require(ropeView.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        let printLayer = try #require(ropeView.layer?.sublayers?.first { !($0 is CAShapeLayer) })
        let peg = try #require(printLayer.sublayers?.first)
        ropePicker.selectItem(at: RopeColorPreset.allCases.firstIndex(of: .sage)!)
        _ = NSApp.sendAction(try #require(ropePicker.action), to: ropePicker.target, from: ropePicker)
        #expect(Prefs.clotheslineColors.rope == RopeColorPreset.sage.rgb)
        #expect(Prefs.clotheslineColors.peg == RopeColorPreset.silver.rgb)
        pegPicker.selectItem(at: RopeColorPreset.allCases.firstIndex(of: .graphite)!)
        _ = NSApp.sendAction(try #require(pegPicker.action), to: pegPicker.target, from: pegPicker)
        let saved = try #require(UserDefaults.standard.data(forKey: "clothesline.colors.v1"))
        #expect(try JSONDecoder().decode(ClotheslineColors.self, from: saved) == Prefs.clotheslineColors)
        #expect(line.strokeColor == Prefs.clotheslineColors.rope.color.cgColor)
        #expect(peg.backgroundColor == Prefs.clotheslineColors.peg.color.cgColor)
        let well = try #require(controls.compactMap { $0 as? NSColorWell }.first { $0.accessibilityLabel() == L("Custom peg color") })
        well.color = NSColor(srgbRed: 0.28, green: 0.48, blue: 0.62, alpha: 0.1)
        _ = NSApp.sendAction(try #require(well.action), to: well.target, from: well)
        #expect(pegPicker.titleOfSelectedItem == L("Custom"))
        #expect(Prefs.clotheslineColors.peg.color.alphaComponent == 1)
        let reset = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == L("Reset rope colors") })
        reset.performClick(nil)
        #expect(Prefs.clotheslineColors == ClotheslineColors())
    }

    @Test func storedColorsRejectInvalidComponentsAndClotheslinePaneFitsLargeText() {
        #expect(RGBColor(-4, .infinity, 9) == RGBColor(0, 0.5, 1))
        let old = Prefs.interaction
        defer { Prefs.interaction = old }
        var settings = old
        settings.textSize = .extraLarge
        Prefs.interaction = settings
        let pane = ClotheslinePane()
        _ = pane.view
        AppTypography.apply(to: pane.view)
        pane.view.layoutSubtreeIfNeeded()
        #expect(pane.stack.fittingSize.height <= pane.preferredContentSize.height)
    }

    @Test func templatePaletteControlsPersistIndependentlyAndResetOnlyOneTemplate() throws {
        let old = Prefs.templateColors, style = Prefs.style, rope = Prefs.clotheslineColors
        defer { Prefs.templateColors = old }
        Prefs.templateColors = TemplateColors()
        let pane = TemplateColorsPane()
        let controls = descendants(pane.view)
        let template = try #require(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == L("Color template") })
        let preset = try #require(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == L("Template palette") })
        func pick(_ popup: NSPopUpButton, _ index: Int) {
            popup.selectItem(at: index)
            _ = NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        }
        pick(preset, TemplateColorPreset.allCases.firstIndex(of: .sage)!)
        #expect(Prefs.templateColors.shelf == TemplateColorPreset.sage.palette)
        #expect(Prefs.templateColors.notes == .native)
        pick(template, 1)
        pick(preset, TemplateColorPreset.allCases.firstIndex(of: .lavender)!)
        let well = try #require(controls.compactMap { $0 as? NSColorWell }.first { $0.accessibilityLabel() == L("Palette color %d", 2) })
        well.color = NSColor(srgbRed: 0.25, green: 0.40, blue: 0.38, alpha: 0.3)
        _ = NSApp.sendAction(try #require(well.action), to: well.target, from: well)
        #expect(preset.titleOfSelectedItem == L("Custom"))
        #expect(Prefs.templateColors.notes.colors[1] == RGBColor(0.25, 0.40, 0.38))
        #expect(Prefs.templateColors.shelf == TemplateColorPreset.sage.palette)
        pick(preset, TemplateColorPreset.allCases.firstIndex(of: .custom)!)
        #expect(NSColorPanel.shared.isVisible)
        for colorWell in controls.compactMap({ $0 as? NSColorWell }) { colorWell.deactivate() }
        NSColorPanel.shared.orderOut(nil)
        let data = try #require(UserDefaults.standard.data(forKey: "templates.colors.v1"))
        #expect(try JSONDecoder().decode(TemplateColors.self, from: data) == Prefs.templateColors)
        let reset = try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == L("Reset this palette") })
        reset.performClick(nil)
        #expect(Prefs.templateColors.notes == .native)
        #expect(Prefs.templateColors.shelf == TemplateColorPreset.sage.palette)
        #expect(Prefs.style == style && Prefs.clotheslineColors == rope)
    }

    @Test func templateTextKeepsContrastForAllPresetsAndCustomColors() {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB)!
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        var palettes = TemplateColorPreset.allCases.compactMap(\.palette)
        for color in [RGBColor(0, 0, 0), RGBColor(1, 1, 1), RGBColor(0.47, 0.47, 0.47), RGBColor(1, 0, 0), RGBColor(0, 0, 1)] {
            palettes.append(TemplatePalette(colors: Array(repeating: color, count: 4), rail: color))
        }
        for palette in palettes {
            for dark in [false, true] {
                for index in 0..<4 {
                    for selected: CGFloat in [0, 1] {
                        let background = luminance(palette.card(index, dark: dark, selection: selected))
                        let text = luminance(palette.ink(index, dark: dark, selection: selected))
                        let contrast = (max(background, text) + 0.05) / (min(background, text) + 0.05)
                        #expect(contrast >= 4.5)
                    }
                }
            }
        }
        #expect(TemplatePalette(colors: [], rail: RGBColor(0, 0, 0)).sanitized.colors.count == 4)
        var railOnly = TemplatePalette.native
        railOnly.rail = RGBColor(0.6, 0.7, 0.8)
        for dark in [false, true] {
            #expect(railOnly.card(0, dark: dark) == TemplatePalette.native.card(0, dark: dark))
        }
    }

    @Test func palettePaneFitsEveryLanguageAtLargeTextAndRendersPresets() throws {
        let old = Prefs.interaction, colors = Prefs.templateColors
        let language = UserDefaults.standard.object(forKey: "language")
        defer {
            Prefs.interaction = old; Prefs.templateColors = colors
            if let language { UserDefaults.standard.set(language, forKey: "language") }
            else { UserDefaults.standard.removeObject(forKey: "language") }
        }
        var settings = old
        settings.textSize = .extraLarge
        Prefs.interaction = settings
        for locale in [Language.en, .zhHans, .zhHant, .ja] {
            UserDefaults.standard.set(locale.rawValue, forKey: "language")
            let pane = TemplateColorsPane()
            _ = pane.view
            AppTypography.apply(to: pane.view)
            pane.view.layoutSubtreeIfNeeded()
            #expect(pane.stack.fittingSize.height <= pane.preferredContentSize.height)
        }
        guard let directory = ProcessInfo.processInfo.environment["SWIVEL_PALETTE_RENDERS"] else { return }
        Prefs.interaction = InteractionSettings()
        UserDefaults.standard.set("zh-Hans", forKey: "language")
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for template in ColorTemplate.allCases {
            for preset in TemplateColorPreset.allCases where preset.palette != nil {
                var settings = Prefs.templateColors
                settings[template] = preset.palette!
                Prefs.templateColors = settings
                for dark in [false, true] {
                    let view = menuPreview(style: template.style, titles: ["JPG", "PNG", "HEIC", "TIFF", "PDF", "GIF", "AVIF", "BMP"], mode: .convert, hovered: 1)
                    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = view.bounds.size
                    let image = NSImage(size: size)
                    image.lockFocus()
                    NSColor(white: dark ? 0.09 : 0.92, alpha: 1).setFill()
                    NSRect(origin: .zero, size: size).fill()
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    bitmap.draw(in: view.bounds)
                    image.unlockFocus()
                    let result = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    try result.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(template.rawValue)-\(preset.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

}
