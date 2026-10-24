import AppKit
import UniformTypeIdentifiers

struct Cancelled: LocalizedError {
    var errorDescription: String? { "Cancelled" }
}

/// A floating editor window: a canvas on top, controls below, Reset / Apply at the bottom.
/// `present()` suspends until the user applies (returning the saved files) or closes the window.
///
/// The main thread stays free throughout: subclasses decode in `load()`, render previews with `LiveRender`, and in
/// `apply()` read their controls first, then hand the full-resolution work to `Images.detached`.
@MainActor
class Editor: NSObject, NSWindowDelegate {
    private static var open: [Editor] = []
    /// How many editor windows have been opened, so callers can tell whether an action showed one.
    private(set) static var presented = 0

    let window: NSWindow
    let source: URL
    let controls = NSStackView()
    private let canvas: NSView
    private let well = NSBox()
    private var continuation: CheckedContinuation<[URL], Error>?
    private var applyButton: NSButton!
    private var resetButton: NSButton!
    private var cancelButton: NSButton!
    private let savingSpinner = NSProgressIndicator()
    private let loadingSpinner = NSProgressIndicator()
    /// Covers the canvas while saving, so a click, drag or draw can't change what Apply already read.
    private let shield = InputShield()
    /// The window's undo manager (handed over in `windowWillReturnUndoManager`); locked while saving.
    let history = EditorUndoManager()
    private var sliders: [DetentSlider] = []
    private var disabledWhileSaving: [NSControl] = []
    /// `load()` finished; until then the controls can move but nothing renders.
    private(set) var isLoaded = false
    private(set) var isSaving = false
    private var closed = false
    private var discardConfirmed = false
    /// The window opened during `load()`, with a spinner in place of the canvas.
    private var revealedWhileLoading = false

    init(title: String, source: URL, canvas: NSView) {
        self.source = source
        self.canvas = canvas
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = L(title)
        window.subtitle = source.lastPathComponent
        window.isReleasedWhenClosed = false
        // Floating until it first becomes key: opened from a drop while Finder is active, activation can be refused,
        // and the editor must still show up. Once key it drops to normal, so switching apps puts it behind them.
        window.level = .floating
        window.minSize = NSSize(width: 480, height: 580)
        window.delegate = self

        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10

        // macOS convention: secondary action on the left, Cancel / default action on the right.
        resetButton = NSButton(title: L("Reset"), target: self, action: #selector(resetClicked))
        cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"
        applyButton = NSButton(title: L("Saving…"), target: self, action: #selector(applyClicked))
        applyButton.keyEquivalent = "\r"
        // Wide enough for "Saving…", so the buttons don't shift when Apply is pressed.
        let applyWidth = max(80, applyButton.fittingSize.width)
        applyButton.title = L("Apply")
        for button in [resetButton!, cancelButton!, applyButton!] {
            button.bezelStyle = .push
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: button === applyButton ? applyWidth : 80).isActive = true
        }
        applyButton.isEnabled = false
        resetButton.isEnabled = false
        savingSpinner.style = .spinning
        savingSpinner.controlSize = .small
        savingSpinner.isDisplayedWhenStopped = false
        let bar = NSStackView()
        bar.addView(resetButton, in: .leading)
        bar.addView(savingSpinner, in: .trailing)
        bar.addView(cancelButton, in: .trailing)
        bar.addView(applyButton, in: .trailing)

        // The canvas sits in a recessed well, like Preview's editing area.
        well.boxType = .custom
        well.cornerRadius = 10
        well.borderColor = .separatorColor
        well.borderWidth = 1
        well.fillColor = .underPageBackgroundColor
        well.contentViewMargins = .zero
        well.contentView = canvas
        well.translatesAutoresizingMaskIntoConstraints = false
        well.setContentHuggingPriority(.defaultLow, for: .vertical)
        well.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        loadingSpinner.style = .spinning
        loadingSpinner.isDisplayedWhenStopped = false
        // Hidden, not only stopped, when not loading: a stopped spinner still takes the clicks at the canvas's centre.
        loadingSpinner.isHidden = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(loadingSpinner)
        shield.isHidden = true
        shield.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(shield)

        let separator = NSBox()
        separator.boxType = .separator

        let root = NSStackView(views: [well, controls, separator, bar])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.setCustomSpacing(12, after: separator)
        root.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            well.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            controls.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            separator.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            bar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            well.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            loadingSpinner.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            shield.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            shield.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            shield.topAnchor.constraint(equalTo: well.topAnchor),
            shield.bottomAnchor.constraint(equalTo: well.bottomAnchor),
        ])
        window.contentView = content
    }

    func present() async throws -> [URL] {
        Editor.open.append(self)
        Editor.presented += 1
        // Opened from the Wheel before Settings ever was, the app has no menu, and without one ⌘C / ⌘V / ⌘Z / ⌘W
        // do nothing in the editor's fields.
        if NSApp.mainMenu == nil { NSApp.mainMenu = AppWindow.mainMenu() }
        window.center()
        // Large photos take a moment to decode. If it's more than a blink, open the window with a spinner in the well
        // rather than leave nothing on screen after the drop.
        let early = DispatchWorkItem { [weak self] in self?.reveal(loading: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: early)
        do {
            try await load()
            early.cancel()
            if closed { throw Cancelled() }
        } catch {
            early.cancel()
            abandon()
            throw error
        }
        isLoaded = true
        applyButton.isEnabled = true
        resetButton.isEnabled = true
        update()
        // Already open with a spinner: swap in the canvas even if the window was minimized or hidden meanwhile (it
        // then stays where the user put it). Not open yet: open it now.
        if revealedWhileLoading { finishLoading() } else { reveal(loading: false) }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    // MARK: Overridable

    /// Decodes what the editor shows. Runs before the window has content; do the heavy part off the main thread.
    func load() async throws {}
    /// Saves the result and returns the written files.
    func apply() async throws -> [URL] { [] }
    func reset() {}
    /// Called whenever a control changes (only once loaded).
    func update() {}
    /// A slider drag ended: a good moment for a final, exact preview.
    func trackingEnded() {}
    /// Work that closing without applying would lose; while true, the close button shows the edited dot and
    /// Cancel / Esc / ⌘W ask first.
    var hasUnsavedWork: Bool { false }
    /// The window is closing, either way: stop animations, renders and playback.
    func didClose() {}
    /// Editors with a cooperative save worker can keep Cancel available during a save.
    var canCancelSaving: Bool { false }
    func cancelSaving() {}

    /// Call after a change that `hasUnsavedWork` depends on.
    func noteEdited() { window.isDocumentEdited = hasUnsavedWork }

    // MARK: Plumbing

    private func reveal(loading: Bool) {
        guard !closed, !window.isVisible else { return }
        if loading {
            revealedWhileLoading = true
            canvas.alphaValue = 0
            loadingSpinner.isHidden = false
            loadingSpinner.startAnimation(nil)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // The window is the feedback now; a busy toast from the action that opened it would otherwise spin on.
        Toast.shared.hideIfSpinning()
    }

    private func finishLoading() {
        loadingSpinner.stopAnimation(nil)
        loadingSpinner.isHidden = true
        guard window.isVisible else {
            // Minimized or hidden while loading: ready when it comes back.
            canvas.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            canvas.animator().alphaValue = 1
        }
    }

    /// Loading failed or the window was closed during it: tidy up without a continuation to resume.
    private func abandon() {
        window.delegate = nil
        window.close()
        Editor.open.removeAll { $0 === self }
        didClose()
    }

    @objc private func cancelClicked() { window.performClose(nil) }

    @objc private func resetClicked() {
        guard isLoaded, !isSaving else { return }
        reset()
        update()
        noteEdited()
    }

    @objc private func applyClicked() {
        guard isLoaded, !isSaving else { return }
        // Return pressed mid-drag on the canvas: the drag would go on changing the picture after Apply read it.
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            NSSound.beep()
            return
        }
        // A half-typed value (W/H, the Text field) has to reach the editor before it reads its controls. A field
        // holding something invalid refuses to let go; leave it to the user.
        guard window.makeFirstResponder(nil) else {
            NSSound.beep()
            return
        }
        setSaving(true)
        let started = CACurrentMediaTime()
        Task { @MainActor [self] in
            do {
                let files = try await apply()
                // A save the user waited for ends with a firm tap. A quick one would only echo the click itself.
                // The success chime comes from the toast that reports the files.
                if CACurrentMediaTime() - started > 0.3 { Haptics.press() }
                finish(.success(files))
            } catch {
                setSaving(false)
                guard !closed else { return }
                if error is CancellationError || error is Cancelled { return }
                Feedback.refuse()
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// Apply's pressed state lasts as long as the save: a spinner, "Saving…", and nothing else to click — the
    /// controls are disabled, the canvas is covered and ⌘Z / ⇧⌘Z wait, because `apply()` has already read them all.
    func setSaving(_ saving: Bool) {
        isSaving = saving
        applyButton.title = saving ? L("Saving…") : L("Apply")
        history.isLocked = saving
        shield.isHidden = !saving
        window.invalidateCursorRects(for: shield)
        if saving {
            savingSpinner.startAnimation(nil)
            disabledWhileSaving = (Self.controls(in: controls) + [resetButton, cancelButton, applyButton]).filter(\.isEnabled)
            for control in disabledWhileSaving { control.isEnabled = false }
            if canCancelSaving { cancelButton.isEnabled = true }
        } else {
            savingSpinner.stopAnimation(nil)
            for control in disabledWhileSaving { control.isEnabled = true }
            disabledWhileSaving = []
        }
    }

    private static func controls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { sub -> [NSControl] in
            if let control = sub as? NSControl { return [control] }
            return controls(in: sub)
        }
    }

    @objc func controlChanged(_ sender: Any?) {
        guard isLoaded else { return }
        update()
    }

    private func finish(_ result: Result<[URL], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        window.delegate = nil
        Editor.open.removeAll { $0 === self }
        didClose()
        continuation.resume(with: result)
        guard case .success = result else {
            window.close()
            return
        }
        // Saved: the window gives way to the toast instead of vanishing in one frame. Nothing can reopen this window,
        // so the fade's completion can't hide anything newer.
        let window = self.window
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.close() }
        })
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A save can't be abandoned halfway: its file would still appear after "Cancelled".
        if isSaving { if canCancelSaving { cancelSaving() }; return false }
        guard isLoaded, hasUnsavedWork, !discardConfirmed else { return true }
        let alert = NSAlert()
        alert.messageText = L("Discard your changes?")
        alert.addButton(withTitle: L("Keep Editing"))
        let discard = alert.addButton(withTitle: L("Discard"))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            self.discardConfirmed = true
            self.window.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        finish(.failure(Cancelled()))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window.level != .normal { window.level = .normal }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }

    // MARK: Control builders

    func addRow(_ title: String, _ views: NSView...) {
        let row = makeRow(title, views)
        controls.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
    }

    /// A row as `addRow` builds it, for an editor that places its rows itself.
    func makeRow(_ title: String, _ views: [NSView]) -> NSStackView {
        // Right-aligned "Label:" column, as in System Settings and inspector panels.
        let label = NSTextField(labelWithString: title.isEmpty ? "" : L(title) + (Language.resolved == .en ? ":" : "："))
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let row = NSStackView(views: [label] + views)
        row.spacing = 8
        return row
    }

    /// A continuous slider whose starting value is a soft detent (see `DetentSlider`).
    func slider(_ min: Double, _ max: Double, _ value: Double) -> DetentSlider {
        let slider = DetentSlider(value: value, minValue: min, maxValue: max, target: self, action: #selector(controlChanged))
        slider.isContinuous = true
        slider.neutral = value
        slider.onTrackingEnded = { [weak self] in
            guard let self, self.isLoaded else { return }
            self.trackingEnded()
        }
        sliders.append(slider)
        return slider
    }

    /// A slider is being dragged right now.
    var isTracking: Bool { sliders.contains { $0.isTracking } }

    func segments(_ labels: [String]) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels.map { L($0) }, trackingMode: .selectOne, target: self,
                                         action: #selector(controlChanged))
        control.selectedSegment = 0
        return control
    }

    func popup(_ items: [String]) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: items.map { L($0) })
        popup.target = self
        popup.action = #selector(controlChanged)
        return popup
    }

    func checkbox(_ title: String, _ on: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: L(title), target: self, action: #selector(controlChanged))
        box.state = on ? .on : .off
        return box
    }

    func numberField(_ value: Int) -> NSTextField {
        let field = NSTextField(string: "\(value)")
        field.alignment = .center
        field.target = self
        field.action = #selector(controlChanged)
        // Tabbing or clicking away commits too, not only Return.
        field.cell?.sendsActionOnEndEditing = true
        field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        field.formatter = formatter
        return field
    }
}

// MARK: - Slider detent

/// Where a slider sticks while dragged: within `zone` of `neutral` the value is pulled onto it, and the step that
/// enters the zone (or jumps across it in one event) asks for one tap. Leaving re-arms only past `rearm` (twice the
/// zone), so resting on the boundary doesn't buzz. Pure, so it can be tested.
///
/// A default at either end of the slider's travel is an end stop instead (`forSlider`): the slider's own clamp
/// already holds the value there, so there's no capture band — every value up to the end stays reachable (the first
/// and last seconds of an hour-long clip) — only a tap as the value arrives exactly at the end.
struct Detent {
    let neutral: Double
    let zone: Double
    let rearm: Double
    private(set) var engaged: Bool
    private var last: Double

    init(neutral: Double, range: Double, at value: Double, fraction: Double = 0.015) {
        self.init(neutral: neutral, zone: abs(range) * fraction, rearm: abs(range) * fraction * 2, at: value)
    }

    /// An end stop at `end`: values are never moved; arriving exactly at the end taps once, and it re-arms after
    /// moving `fraction` of the range away.
    static func endStop(_ end: Double, range: Double, at value: Double, fraction: Double = 0.015) -> Detent {
        Detent(neutral: end, zone: 0, rearm: abs(range) * fraction, at: value)
    }

    /// The detent for a drag starting at `value` on a slider from `min` to `max` whose default is `neutral`.
    static func forSlider(neutral: Double, min: Double, max: Double, at value: Double) -> Detent {
        neutral <= min || neutral >= max
            ? endStop(neutral, range: max - min, at: value)
            : Detent(neutral: neutral, range: max - min, at: value)
    }

    /// Starts at `value`: already engaged if it rests in the detent, so the first move doesn't tap.
    private init(neutral: Double, zone: Double, rearm: Double, at value: Double) {
        self.neutral = neutral
        self.zone = zone
        self.rearm = rearm
        last = value
        engaged = abs(value - neutral) <= zone
    }

    /// The value to show for a raw slider value, and whether this step should tap the trackpad.
    mutating func filter(_ raw: Double) -> (value: Double, tick: Bool) {
        let distance = abs(raw - neutral)
        let crossed = (last - neutral) * (raw - neutral) < 0
        last = raw
        if distance <= zone {
            let tick = !engaged
            engaged = true
            return (neutral, tick)
        }
        let tick = crossed && !engaged
        if distance > rearm { engaged = false }
        return (raw, tick)
    }
}

/// A native slider with a soft detent at its default: while dragging it sticks to the default within ±1.5 % of its
/// range and taps the trackpad once on the way in (Logic and Figma do the same). A default at one end of the range
/// only taps on arrival (see `Detent`). ⌘ while dragging turns the detent off, as it turns off snapping in Crop, so
/// the values right beside the default can be reached too. Double-click resets it.
final class DetentSlider: NSSlider {
    var neutral: Double?
    /// The mouse went up after a drag (or a double-click reset).
    var onTrackingEnded: (() -> Void)?
    private(set) var isTracking = false
    private var detent: Detent?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let neutral, isEnabled {
            doubleValue = neutral
            _ = sendAction(action, to: target)
            onTrackingEnded?()
            return
        }
        isTracking = true
        // Built per drag, from the range as it is now (Trim learns its clip's length only after opening).
        detent = neutral.map { Detent.forSlider(neutral: $0, min: minValue, max: maxValue, at: doubleValue) }
        super.mouseDown(with: event)  // the cell's tracking loop; returns on mouse up
        isTracking = false
        onTrackingEnded?()
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        // Only a drag is magnetic: arrow keys and VoiceOver must be able to step off the default.
        if isTracking, var detent {
            let (value, tick) = detent.filter(doubleValue)
            self.detent = detent
            if !NSEvent.modifierFlags.contains(.command) {
                if value != doubleValue { doubleValue = value }
                if tick { Haptics.tick(.alignment) }
            }
        }
        return super.sendAction(action, to: target)
    }
}

// MARK: - Saving locks

/// The editor window's undo manager. While a save runs it's locked: ⌘Z / ⇧⌘Z (and the Edit menu's items) do
/// nothing, so the picture can't change after `apply()` read it. Registering still works, so a change that lands
/// meanwhile (Redact's detection finishing) keeps its history.
final class EditorUndoManager: UndoManager {
    var isLocked = false

    override var canUndo: Bool { !isLocked && super.canUndo }
    override var canRedo: Bool { !isLocked && super.canRedo }

    override func undo() {
        if !isLocked { super.undo() }
    }

    override func undoNestedGroup() {
        if !isLocked { super.undoNestedGroup() }
    }

    override func redo() {
        if !isLocked { super.redo() }
    }
}

/// Lies over the canvas while saving and takes every click, drag and scroll aimed at it.
private final class InputShield: NSView {
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

// MARK: - Live preview

/// Renders previews off the main thread, newest request wins: while one render runs, later requests replace each
/// other and only the latest runs next. Results arrive in order on the main thread, and the preview keeps showing
/// the last one meanwhile, so a slider never waits for a render.
@MainActor
final class LiveRender<Output: Sendable> {
    private var busy = false
    private var queued: (@Sendable () -> Output)?
    private var generation = 0
    private let deliver: (Output) -> Void

    init(_ deliver: @escaping (Output) -> Void) {
        self.deliver = deliver
    }

    var isBusy: Bool { busy || queued != nil }

    func request(_ job: @escaping @Sendable () -> Output) {
        if busy {
            queued = job
        } else {
            run(job)
        }
    }

    /// Drops queued work and any result still on its way.
    func cancel() {
        queued = nil
        generation += 1
    }

    private func run(_ job: @escaping @Sendable () -> Output) {
        busy = true
        let token = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let output = job()
            await self?.finished(output, token)
        }
    }

    private func finished(_ output: Output, _ token: Int) {
        busy = false
        if token == generation { deliver(output) }
        if let job = queued {
            queued = nil
            run(job)
        }
    }
}

// MARK: - Canvas pieces

/// A picture held as a layer's contents: the GPU scales it, so redrawing what's on top never resamples the photo.
/// It ignores the mouse; its owner positions it.
final class PictureView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contentsGravity = .resize
        layer?.contents = image
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A transparent view its owner draws into (guides, handles, the shape being drawn). It ignores the mouse.
final class OverlayView: NSView {
    var drawer: (() -> Void)?
    var topDown = false

    override var isFlipped: Bool { topDown }

    override func draw(_ dirtyRect: NSRect) { drawer?() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shows a CGImage aspect-fit with a soft shadow. The image is a layer's contents, so a new preview costs a texture
/// upload, not a CPU resample. When `original` is set, pressing and holding shows it instead, to compare.
final class ImagePreview: NSView {
    var image: CGImage? { didSet { refresh() } }
    var original: CGImage? {
        didSet { toolTip = original == nil ? nil : L("Press and hold to compare with the original") }
    }
    private let content = CALayer()
    private var comparing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        content.contentsGravity = .resize
        content.shadowColor = NSColor.black.cgColor
        content.shadowOpacity = 0.25
        content.shadowRadius = 5
        content.shadowOffset = CGSize(width: 0, height: -3)
        content.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "shadowPath": NSNull()]
        layer?.addSublayer(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    var imageRect: NSRect {
        guard let shown = image ?? original else { return .zero }
        return fit(CGSize(width: shown.width, height: shown.height), in: bounds.insetBy(dx: 12, dy: 12))
    }

    /// Replaces the image with a short crossfade, for changes that rearrange the picture (a new layout).
    func setImage(_ image: CGImage?, fade: Bool) {
        self.image = image
        if fade {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.15
            content.add(transition, forKey: "fade")
        }
    }

    private func refresh() {
        content.contents = comparing ? (original ?? image) : image
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rect = imageRect
        content.frame = rect
        content.shadowPath = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
    }

    func showOriginal(_ showing: Bool) {
        comparing = showing
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        guard original != nil else { return super.mouseDown(with: event) }
        showOriginal(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard comparing else { return super.mouseUp(with: event) }
        comparing = false
        refresh()
    }
}

func fit(_ size: CGSize, in bounds: NSRect) -> NSRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
}

func byteString(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
