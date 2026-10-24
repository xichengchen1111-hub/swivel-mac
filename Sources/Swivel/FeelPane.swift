import AppKit

/// A user-facing tuning bench: choices are saved immediately, and trials never run file actions.
final class FeelPane: Pane {
    private let presets = NSPopUpButton()
    private let area = NSPopUpButton()
    private let style = NSPopUpButton()
    private let soundStyle = NSPopUpButton()
    private let textSize = NSPopUpButton()
    private let speed = NSSlider()
    private let bounce = NSSlider()
    private let volume = NSSlider()
    private let speedValue = NSTextField(labelWithString: "")
    private let bounceValue = NSTextField(labelWithString: "")
    private let volumeValue = NSTextField(labelWithString: "")
    private let sounds = NSButton(checkboxWithTitle: L("Sound Effects"), target: nil, action: nil)
    private let haptics = NSButton(checkboxWithTitle: L("Haptic Feedback"), target: nil, action: nil)
    private let gentle = NSButton(checkboxWithTitle: L("Gentle trackpad taps"), target: nil, action: nil)
    private let hoverSound = NSButton(checkboxWithTitle: L("Play sounds when selecting items"), target: nil, action: nil)
    private let bold = NSButton(checkboxWithTitle: L("Bold interface text"), target: nil, action: nil)
    private let preview = PreviewHost(frame: .zero)
    private let motionPreview = FeelMotionPreview(frame: .zero)
    private let previewHolder = NSView()
    private let trialHint = NSTextField(wrappingLabelWithString: "")
    private let sample = NSTextField(wrappingLabelWithString: L("Swivel — comfortable at a glance. 文件 · 写真"))
    private var selectedArea: FeelArea { FeelArea.allCases[max(area.indexOfSelectedItem, 0)] }

    init() { super.init(size: NSSize(width: 860, height: 1400)) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        stack.addArrangedSubview(label("Feel & Text", size: 26, weight: .bold))
        stack.addArrangedSubview(label("Too bouncy, too slow or too noisy? Make Swivel comfortable for you. Changes are saved as you go.", secondary: true))

        presets.addItems(withTitles: [L("Custom")] + FeelPreset.allCases.map(\.title))
        connect(presets, "Feel preset", #selector(presetChanged))
        card("Start with a preset", [row("Preset", presets),
            label("Original · Calm · Snappy · Playful · Quiet. Presets keep your text size and feedback switches.", size: 12, secondary: true)])

        area.addItems(withTitles: FeelArea.allCases.map(\.title))
        connect(area, "Motion area", #selector(areaChanged))
        style.addItems(withTitles: MenuStyle.allCases.map(\.title))
        style.selectItem(at: MenuStyle.allCases.firstIndex(of: Prefs.style) ?? 0)
        connect(style, "Preview layout", #selector(previewChanged))
        configure(speed, min: 0.75, max: 1.5, name: "Animation speed", action: #selector(motionChanged))
        configure(bounce, min: 0, max: 1, name: "Animation bounce", action: #selector(motionChanged))
        let motionHint = label("Less bounce feels steadier. More speed finishes movement sooner.", size: 12, secondary: true)
        motionHint.preferredMaxLayoutWidth = 330
        motionHint.widthAnchor.constraint(equalToConstant: 330).isActive = true
        trialHint.font = .systemFont(ofSize: 11)
        trialHint.textColor = .secondaryLabelColor
        trialHint.preferredMaxLayoutWidth = 350
        trialHint.widthAnchor.constraint(equalToConstant: 350).isActive = true
        let controls = ToolUI.stack([
            label("Adjust one area", size: 13, weight: .semibold), area,
            label("Speed", secondary: true), sliderRow(speed, speedValue),
            label("Bounce", secondary: true), sliderRow(bounce, bounceValue),
            motionHint,
        ], spacing: 8)
        controls.widthAnchor.constraint(equalToConstant: 330).isActive = true
        previewHolder.widthAnchor.constraint(equalToConstant: 360).isActive = true
        previewHolder.heightAnchor.constraint(equalToConstant: 260).isActive = true
        let background = WallpaperView()
        background.translatesAutoresizingMaskIntoConstraints = false
        previewHolder.addSubview(background)
        for child in [background, preview, motionPreview] {
            child.translatesAutoresizingMaskIntoConstraints = false
            if child !== background { previewHolder.addSubview(child) }
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: previewHolder.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: previewHolder.trailingAnchor),
                child.topAnchor.constraint(equalTo: previewHolder.topAnchor),
                child.bottomAnchor.constraint(equalTo: previewHolder.bottomAnchor),
            ])
        }
        let trials = ToolUI.stack([previewHolder, style, trialHint], spacing: 8)
        let columns = NSStackView(views: [controls, trials])
        columns.alignment = .top
        columns.spacing = 24
        card("Motion", [columns, label("Reduce Motion in macOS always takes priority. Try the menu above, or click the sample to replay.", size: 12, secondary: true)])

        soundStyle.addItems(withTitles: SoundStyle.allCases.map(\.title))
        connect(soundStyle, "Sound style", #selector(audioChanged))
        configure(volume, min: 0, max: 1, name: "Sound level", action: #selector(audioChanged))
        for (button, action) in [(sounds, #selector(toggleSounds)), (haptics, #selector(toggleHaptics)),
                                  (gentle, #selector(audioChanged)), (hoverSound, #selector(audioChanged))] {
            button.target = self
            button.action = action
        }
        let switches = NSStackView(views: [sounds, haptics])
        switches.spacing = 24
        let tests = NSStackView(views: [testButton("Selection", 0), testButton("Page turn", 1),
                                       testButton("Confirm", 2), testButton("Completion", 3)])
        tests.spacing = 8
        card("Sound & touch", [switches, row("Sound style", soundStyle), row("Sound level", sliderRow(volume, volumeValue)),
            hoverSound, gentle, tests,
            label("Sound level is relative to the macOS effects volume. System sound settings and your feedback switches are respected.", size: 12, secondary: true)])

        textSize.addItems(withTitles: TextSize.allCases.map(\.title))
        connect(textSize, "Interface text size", #selector(textChanged))
        bold.target = self
        bold.action = #selector(textChanged)
        sample.font = .systemFont(ofSize: 15)
        card("Text", [row("Text size", textSize), bold, sample,
            label("Applies immediately to Swivel windows, tools and menu labels. Text inside exported images is unchanged.", size: 12, secondary: true)])
        let reset = NSButton(title: L("Restore tuning defaults"), target: self, action: #selector(reset))
        reset.bezelStyle = .push
        stack.addArrangedSubview(reset)
        showPreview()
    }

    private func card(_ title: String, _ views: [NSView]) {
        let box = CardView()
        let content = ToolUI.stack([label(title, size: 17, weight: .semibold)] + views, spacing: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        box.widthAnchor.constraint(equalToConstant: 790).isActive = true
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -16),
        ])
        for child in views.compactMap({ $0 as? NSTextField }) {
            child.preferredMaxLayoutWidth = 750
            child.widthAnchor.constraint(lessThanOrEqualToConstant: 750).isActive = true
        }
        stack.addArrangedSubview(box)
    }

    private func connect(_ popup: NSPopUpButton, _ name: String, _ action: Selector) {
        popup.target = self
        popup.action = action
        popup.setAccessibilityLabel(L(name))
    }

    private func configure(_ slider: NSSlider, min: Double, max: Double, name: String, action: Selector) {
        slider.minValue = min
        slider.maxValue = max
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        slider.setAccessibilityLabel(L(name))
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
    }

    private func sliderRow(_ slider: NSSlider, _ value: NSTextField) -> NSStackView {
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return NSStackView(views: [slider, value])
    }

    private func testButton(_ title: String, _ tag: Int) -> NSButton {
        let button = NSButton(title: L(title), target: self, action: #selector(testFeedback(_:)))
        button.bezelStyle = .push
        button.tag = tag
        return button
    }

    override func refresh() {
        let settings = Prefs.interaction
        presets.selectItem(at: settings.matchingPreset.flatMap { FeelPreset.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        let tuning = settings[selectedArea]
        speed.doubleValue = tuning.speed
        bounce.doubleValue = tuning.bounce
        speedValue.stringValue = String(format: "%.2f×", tuning.speed)
        bounceValue.stringValue = String(format: "%.0f%%", tuning.bounce * 100)
        volume.doubleValue = settings.volume
        volumeValue.stringValue = String(format: "%.0f%%", settings.volume * 100)
        soundStyle.selectItem(at: SoundStyle.allCases.firstIndex(of: settings.soundStyle) ?? 0)
        textSize.selectItem(at: TextSize.allCases.firstIndex(of: settings.textSize) ?? 1)
        bold.state = settings.boldText ? .on : .off
        sounds.state = Prefs.soundEffects ? .on : .off
        haptics.state = Prefs.haptics ? .on : .off
        gentle.state = settings.gentleHaptics ? .on : .off
        hoverSound.state = settings.hoverSound ? .on : .off
        for control in [soundStyle as NSControl, volume, hoverSound] { control.isEnabled = Prefs.soundEffects }
        gentle.isEnabled = Prefs.haptics
        preview.preview?.needsDisplay = true
        motionPreview.needsDisplay = true
    }

    @objc private func presetChanged() {
        guard presets.indexOfSelectedItem > 0 else { return }
        var settings = Prefs.interaction
        settings.apply(FeelPreset.allCases[presets.indexOfSelectedItem - 1])
        Prefs.interaction = settings
        motionPreview.replay()
    }

    @objc private func areaChanged() { refresh(); showPreview() }
    @objc private func previewChanged() { showPreview() }

    private func showPreview() {
        let isMenu = selectedArea == .menu
        trialHint.stringValue = isMenu ? L("Move the pointer over the menu to try it") : L("Click the sample to replay")
        preview.isHidden = !isMenu
        preview.isInteractive = isMenu
        motionPreview.isHidden = isMenu
        style.isHidden = !isMenu
        if isMenu {
            preview.show(menuPreview(style: MenuStyle.allCases[max(style.indexOfSelectedItem, 0)],
                                     titles: ["Copy", "Move", "AirDrop", "Copy Path", "Terminal", "Hang"], mode: .actions))
        } else {
            motionPreview.area = selectedArea
            motionPreview.replay()
        }
    }

    @objc private func motionChanged() {
        var settings = Prefs.interaction
        settings[selectedArea] = MotionTuning(speed: (speed.doubleValue * 100).rounded() / 100,
                                              bounce: (bounce.doubleValue * 100).rounded() / 100)
        Prefs.interaction = settings
        motionPreview.replay()
    }

    @objc private func audioChanged() {
        var settings = Prefs.interaction
        settings.soundStyle = SoundStyle.allCases[max(soundStyle.indexOfSelectedItem, 0)]
        settings.volume = (volume.doubleValue * 100).rounded() / 100
        settings.hoverSound = hoverSound.state == .on
        settings.gentleHaptics = gentle.state == .on
        Prefs.interaction = settings
        Sounds.prepare()
    }

    @objc private func toggleSounds() { Prefs.soundEffects = sounds.state == .on; Sounds.prepare() }
    @objc private func toggleHaptics() { Prefs.haptics = haptics.state == .on }

    @objc private func textChanged() {
        var settings = Prefs.interaction
        settings.textSize = TextSize.allCases[max(textSize.indexOfSelectedItem, 0)]
        settings.boldText = bold.state == .on
        Prefs.interaction = settings
        showPreview()
    }

    @objc private func testFeedback(_ sender: NSButton) {
        switch sender.tag {
        case 0: Feedback.hover()
        case 1: Feedback.page()
        case 2: Feedback.press()
        default: Feedback.done()
        }
    }

    @objc private func reset() { Prefs.interaction = InteractionSettings(); showPreview() }
}

/// Safe, local trial of the same rope oscillator / tool spring. Does not activate screenshot takeover.
final class FeelMotionPreview: NSView {
    var area: FeelArea = .clothesline
    private var spring = Spring(0, response: 0.34, damping: 0.81)
    private var drop: CGFloat = 0
    private var velocity: CGFloat = 0
    private lazy var driver: FrameDriver = {
        let driver = FrameDriver(view: self)
        driver.onFrame = { [weak self] dt in self?.advance(dt) ?? false }
        return driver
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("Replay motion sample"))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { if window == nil { driver.stop() } }
    override func mouseDown(with event: NSEvent) { replay() }
    override func accessibilityPerformPress() -> Bool { replay(); return true }

    func replay() {
        guard window != nil, !isHidden else { return }
        drop = Motion.reduced ? 0 : -80
        velocity = 0
        spring.snap(Motion.reduced ? 1 : 0)
        spring.target = 1
        needsDisplay = true
        driver.start()
    }

    private func advance(_ dt: CGFloat) -> Bool {
        if Motion.reduced { drop = 0; velocity = 0; spring.snap(1) }
        let tuning = Prefs.interaction[area]
        spring.step(dt, tuning: tuning)
        var left = min(dt, 1 / 30)
        while left > 0 {
            let h = min(left, RopeTuning.step)
            RopeTuning.advance(&drop, &velocity, toward: 0, RopeTuning.fall.tuned(tuning), h: h)
            left -= h
        }
        needsDisplay = true
        return !isHidden && window != nil && (!spring.isSettled || abs(drop) > 0.01 || abs(velocity) > 0.01)
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = bounds.midY + (area == .clothesline ? -drop : (spring.value - 1) * 50)
        if area == .clothesline {
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let rope = NSBezierPath()
            rope.move(to: NSPoint(x: 18, y: y + 50))
            rope.curve(to: NSPoint(x: bounds.width - 18, y: y + 50), controlPoint1: NSPoint(x: 100, y: y + 30),
                       controlPoint2: NSPoint(x: bounds.width - 100, y: y + 30))
            rope.lineWidth = 3
            rope.stroke()
        }
        let rect = NSRect(x: bounds.midX - 66, y: y - 38, width: 132, height: 84)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        let title = area == .clothesline ? L("Clothesline") : L("Tools & settings")
        let attrs: [NSAttributedString.Key: Any] = [.font: AppTypography.font(ofSize: 13, weight: .semibold),
                                                  .foregroundColor: NSColor.labelColor]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }
}
