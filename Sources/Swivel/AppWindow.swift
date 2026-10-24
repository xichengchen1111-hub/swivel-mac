import AppKit
import ServiceManagement

/// The app's main window, laid out like PowerToys: features in a sidebar, each with its own switch and settings.
/// While it is open Swivel shows in the Dock with a normal menu bar.
@MainActor
final class AppWindow: NSObject, NSWindowDelegate {
    static let shared = AppWindow()

    enum Tab: Int { case general, shortcuts, style, customize, clothesline, overview, textCapture, shelf, imagePresets, quickActions, feel, colors, batchRename, pdfPages, qrCodes, appRouting, keepAwake, doctor }

    private var window: NSWindow?
    private var split: BundleSplit?

    func show(_ tab: Tab? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        split?.select(tab ?? .overview)
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = Self.mainMenu()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let split = BundleSplit()
        self.split = split
        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.title = "Swivel"
        window.setContentSize(NSSize(width: 1100, height: 780))
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("SwivelBundle")
        window.center()
        return window
    }

    /// Rebuilds the window's contents in the new language and returns to General. The window itself stays, so it
    /// doesn't vanish and come back, or hop between its saved and current frames.
    func reloadForLanguage() {
        guard let window else {
            NotificationCenter.default.post(name: Prefs.changed, object: nil)
            show(.general)
            return
        }
        let frame = window.frame
        let split = BundleSplit()
        self.split = split
        window.contentViewController = split
        window.setFrame(frame, display: false)  // a new content controller resizes the window to its own view
        split.select(.general)
        NSApp.mainMenu = Self.mainMenu()
        NotificationCenter.default.post(name: Prefs.changed, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        ToolUI.didClose()
    }

    /// App, Edit and Window menus, so ⌘V, ⌘C, ⌘A and ⌘W work in the window.
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: L("About Swivel"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Hide Swivel"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Quit Swivel"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for (title, menu) in [("Swivel", app), ("Edit", edit), ("Window", windowMenu)] {
            let item = NSMenuItem(title: L(title), action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return main
    }
}

// MARK: - Shared bits

/// A pane laid out as a vertical form with a fixed preferred size.
class Pane: NSViewController {
    let stack = NSStackView()
    private let size: NSSize

    init(size: NSSize) {
        self.size = size
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        view = root
        preferredContentSize = size
        build()
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func build() {}
    func refresh() {}

    func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: L(text))
        field.font = .systemFont(ofSize: size, weight: weight)
        if secondary { field.textColor = .secondaryLabelColor }
        field.preferredMaxLayoutWidth = self.size.width - 64
        return field
    }

    func row(_ title: String, _ views: NSView...) -> NSStackView {
        let name = NSTextField(labelWithString: title.isEmpty ? "" : L(title) + (Language.resolved == .en ? ":" : "："))
        name.alignment = .right
        name.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [name] + views)
        row.spacing = 10
        return row
    }

    /// The line under a live menu preview that says it can be tried.
    func tryItHint() -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor
        let hint = NSStackView(views: [icon, label("Move the pointer over the menu to try it", size: 11, secondary: true)])
        hint.spacing = 5
        return hint
    }
}

/// A soft desktop-like backdrop so translucent menu previews look the way they do on screen.
final class WallpaperView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSGradient(colors: [NSColor(srgbRed: 0.47, green: 0.66, blue: 0.9, alpha: 1),
                            NSColor(srgbRed: 0.72, green: 0.78, blue: 0.95, alpha: 1),
                            NSColor(srgbRed: 0.98, green: 0.8, blue: 0.62, alpha: 1)])!.draw(in: path, angle: -60)
    }
}

/// A scaled-down menu for previews. It draws settled; a `PreviewHost` makes it live while it is on screen.
@MainActor
func menuPreview(style: MenuStyle, titles: [String], mode: WheelMode, hovered: Int? = nil) -> WheelView {
    let shown = Array(titles.prefix(8))
    let natural = WheelView.size(for: style, count: shown.count)
    let view = WheelView(frame: NSRect(origin: .zero, size: natural))
    view.unregisterDraggedTypes()
    view.style = style
    view.subtitle = "photo.jpg"
    view.configure(items: shown.map { WheelItem(title: $0) { _ in ActionResult(message: "") } }, mode: mode, page: 0,
                   pageCount: titles.count > 8 ? 2 : 1)
    view.hovered = hovered
    view.resetVisit()  // the resting hover is only a picture; the user hasn't visited anything yet
    return view
}

/// Hosts a preview, scaling it to fit while keeping its proportions.
///
/// An interactive host lets the menu be tried with the mouse while it is on screen: moving over it hovers items the
/// way a drag does, pressing an item presses it in with the drop's tap and sound, and the menu then opens again.
/// Off screen the preview is not live (no display link, no feedback) and goes back to its resting picture.
final class PreviewHost: NSView {
    var isInteractive = true {
        didSet {
            updateTrackingAreas()
            updateLiveness()
        }
    }
    private(set) var preview: WheelView?
    private var natural = NSSize(width: 1, height: 1)
    /// What the preview showed hovered before anyone touched it.
    private var restingHover: Int?
    private var tracking: NSTrackingArea?
    /// Bumped by every press and by anything that replaces or resets the menu, so a pending re-open can't act on a
    /// newer state.
    private var trial = 0
    /// The current click already pressed an item (on mouse-down), so its release doesn't press again.
    private var pressedThisClick = false

    /// How long a pressed item takes to clear before the menu opens again.
    static let reopenDelay: TimeInterval = 0.6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `view` at rest. `crossfade` blends over from the previous menu, for edits that change it.
    func show(_ view: WheelView, crossfade: Bool = false) {
        trial += 1
        pressedThisClick = false
        if crossfade, preview != nil, window != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layer?.add(fade, forKey: "swap")
        }
        preview?.removeFromSuperview()
        natural = view.bounds.size
        restingHover = view.hovered
        view.resetVisit()
        preview = view
        addSubview(view)
        layoutPreview()
        updateLiveness()
    }

    override func layout() {
        super.layout()
        layoutPreview()
    }

    private func layoutPreview() {
        guard let preview else { return }
        preview.frame = fit(natural, in: bounds.insetBy(dx: 10, dy: 10))
        preview.bounds = NSRect(origin: .zero, size: natural)  // draws at natural size, scaled into frame
    }

    // MARK: Live only on screen

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLiveness()
    }

    /// The display link needs a window, and a preview that isn't showing must never tick or sound.
    private func updateLiveness() {
        guard let preview else { return }
        if isInteractive, window != nil {
            preview.isLive = true
        } else if preview.isLive {
            preview.isLive = false
            rest()
        }
    }

    /// Back to the resting picture with no motion. Runs while the preview is not live, so nothing gives feedback.
    private func rest() {
        guard let preview else { return }
        trial += 1
        pressedThisClick = false
        if preview.pressed != nil { preview.beginOpen() }
        preview.pointerLeft()
        preview.hovered = restingHover
        // Setting the resting hover marks it visited; clear that, or the next try opens on "Cancel" with a tick.
        preview.resetVisit()
        preview.settle()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard isInteractive else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// A window point in the preview's own, unscaled coordinates (the ones `WheelView.track` expects), if it is over
    /// the menu.
    func previewPoint(forWindowPoint point: NSPoint) -> NSPoint? {
        guard let preview else { return nil }
        let p = preview.convert(point, from: nil)
        return preview.bounds.contains(p) ? p : nil
    }

    private var livePreview: WheelView? { preview?.isLive == true ? preview : nil }

    override func mouseEntered(with event: NSEvent) {
        // Each entry is a fresh try: items visited last time don't make an empty spot mean "cancel" now.
        if let preview = livePreview, preview.pressed == nil { preview.resetVisit() }
        follow(event)
    }

    override func mouseMoved(with event: NSEvent) { follow(event) }

    override func mouseExited(with event: NSEvent) {
        livePreview?.pointerLeft()
    }

    private func follow(_ event: NSEvent) {
        guard let preview = livePreview else { return }
        if let p = previewPoint(forWindowPoint: event.locationInWindow) { preview.track(p) } else { preview.pointerLeft() }
    }

    override func mouseDown(with event: NSEvent) {
        pressedThisClick = false
        if let preview = livePreview, preview.pressed == nil, let p = previewPoint(forWindowPoint: event.locationInWindow) {
            preview.track(p)
            if let index = preview.hovered { press(index) }
        }
        super.mouseDown(with: event)  // passes on, so a Style card around the preview presses too
    }

    override func mouseDragged(with event: NSEvent) {
        // Moving with the button held is a drag: hovering keeps following until something is pressed.
        if !pressedThisClick { follow(event) }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // Letting go on an item reached with the button held is a drop.
        if !pressedThisClick, let preview = livePreview, preview.pressed == nil,
           previewPoint(forWindowPoint: event.locationInWindow) != nil, let index = preview.hovered {
            press(index)
        }
        pressedThisClick = false
        super.mouseUp(with: event)
    }

    /// Presses an item in, the way a drop does, then opens the menu again so it can be tried once more.
    private func press(_ index: Int) {
        guard let preview else { return }
        pressedThisClick = true
        preview.beginConfirm(index)
        Feedback.press()  // the finger is on the trackpad for a click, so the tap lands
        trial += 1
        let current = trial
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reopenDelay) { [weak self] in
            guard let self, self.trial == current else { return }
            self.reopen()
        }
    }

    private func reopen() {
        guard let preview = livePreview, let window else { return }
        preview.beginOpen()
        // A closed or hidden window has no display link running: open at rest instead of animating later.
        guard window.isVisible else {
            preview.pointerLeft()
            preview.settle()
            return
        }
        // Hover whatever is under the pointer now; it may have left while the item was pressed.
        if let p = previewPoint(forWindowPoint: window.mouseLocationOutsideOfEventStream) { preview.track(p) } else { preview.pointerLeft() }
    }
}

// MARK: - General

final class GeneralPane: Pane {
    private let login = NSButton(checkboxWithTitle: L("Open Swivel at login"), target: nil, action: nil)
    private let haptics = NSButton(checkboxWithTitle: L("Haptic feedback on the trackpad"), target: nil, action: nil)
    private let sounds = NSButton(checkboxWithTitle: L("Sound effects"), target: nil, action: nil)
    /// Login-item changes still on their way to the system; until they land the checkbox shows the user's choice.
    private var loginPending = 0
    private nonisolated static let loginQueue = DispatchQueue(label: "local.swivel.login")

    init() { super.init(size: NSSize(width: 680, height: 680)) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        let icon = NSImageView(image: NSImage(systemSymbolName: "circle.circle", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .controlAccentColor
        let title = label("Swivel", size: 22, weight: .bold)
        let subtitle = label("A bundle of small Mac tools. Turn on the ones you want.", secondary: true)
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        stack.addArrangedSubview(NSStackView(views: [icon, titles]))

        login.target = self
        login.action = #selector(toggleLogin)
        stack.addArrangedSubview(row("Startup", login))

        haptics.target = self
        haptics.action = #selector(toggleHaptics)
        sounds.target = self
        sounds.action = #selector(toggleSounds)
        let feedback = NSStackView(views: [haptics, sounds])
        feedback.orientation = .vertical
        feedback.alignment = .leading
        feedback.spacing = 6
        stack.addArrangedSubview(row("Feedback", feedback))

        let tuning = NSButton(title: L("Feel & Text…"), target: self, action: #selector(openFeel))
        tuning.bezelStyle = .push
        stack.addArrangedSubview(row("Personalize", tuning))

        let languages = NSPopUpButton(frame: .zero, pullsDown: false)
        languages.addItems(withTitles: Language.allCases.map(\.title))
        languages.selectItem(at: Language.allCases.firstIndex(of: Language.chosen) ?? 0)
        languages.target = self
        languages.action = #selector(languageChanged(_:))
        stack.addArrangedSubview(row("Language", languages))
        if #available(macOS 26, *) {
            let speech = NSPopUpButton(frame: .zero, pullsDown: false)
            speech.addItems(withTitles: Prefs.transcriptionLanguageTitles.map { L($0) })
            speech.selectItem(at: Prefs.transcriptionLanguages.firstIndex(of: Prefs.transcriptionLanguage) ?? 0)
            speech.target = self
            speech.action = #selector(speechLanguageChanged(_:))
            stack.addArrangedSubview(row("Transcription Language", speech))
        }


        let steps = label("""
            1.  Start dragging any file in Finder and keep holding the mouse button.
            2.  Tap a key once — the menu opens under the pointer.
            3.  Drop the file on an option. Results are saved next to the original.
            Tap the same key again for the next page. Drop on empty space to cancel.
            """, secondary: true)
        steps.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(row("Wheel", steps))

        let shelf = NSButton(title: L("Show Shelf"), target: self, action: #selector(showShelf))
        let rope = NSButton(title: L("Show Clothesline"), target: self, action: #selector(showClothesline))
        stack.addArrangedSubview(row("", shelf, rope))
        stack.addArrangedSubview(row("Agents", MCPSetupView()))
    }

    override func refresh() {
        if loginPending == 0 { login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        haptics.state = Prefs.haptics ? .on : .off
        sounds.state = Prefs.soundEffects ? .on : .off
    }

    @objc private func openFeel() { AppWindow.shared.show(.feel) }

    @objc private func toggleHaptics() {
        Prefs.haptics = haptics.state == .on
        // Let the user feel what they turned on.
        if Prefs.haptics { Haptics.press() }
    }

    @objc private func toggleSounds() {
        Prefs.soundEffects = sounds.state == .on
        // Let the user hear what they turned on.
        if Prefs.soundEffects {
            Feedback.toggle(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { Sounds.play(.done) }
        }
    }


    @objc private func toggleLogin() {
        // Registering goes through a system daemon and can take a few hundred milliseconds. Keep the click instant
        // and the checkbox as ticked; changes run in order off the main thread, and a failure puts it back.
        let enable = login.state == .on
        loginPending += 1
        Task { [weak self] in
            let failure: Error? = await withCheckedContinuation { done in
                Self.loginQueue.async {
                    do {
                        if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        done.resume(returning: nil)
                    } catch {
                        done.resume(returning: error)
                    }
                }
            }
            guard let self else { return }
            self.loginPending -= 1
            if self.loginPending == 0 { self.login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
            if let failure {
                let alert = NSAlert(error: failure)
                if let window = self.view.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    @objc private func speechLanguageChanged(_ sender: NSPopUpButton) {
        Prefs.transcriptionLanguage = Prefs.transcriptionLanguages[sender.indexOfSelectedItem]
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(Language.allCases[sender.indexOfSelectedItem].rawValue, forKey: "language")
        // Rebuild everything that shows text: the window, the ◎ menu and the app menus.
        DispatchQueue.main.async { AppWindow.shared.reloadForLanguage() }
    }

    @objc private func showShelf() {
        if Feature.shelf.isOn { Shelf.shared.show() } else { AppWindow.shared.show(.shelf) }
    }
    @objc private func showClothesline() { Clothesline.shared.toggle() }
}

// MARK: - Clothesline

final class ClotheslinePane: Pane {
    private let takeover = NSButton(checkboxWithTitle: L("Hang new screenshots and screen recordings on the rope"), target: nil, action: nil)
    private let copied = NSButton(checkboxWithTitle: L("Also hang images you copy (e.g. ⌃ screenshots, Copy in Preview)"), target: nil, action: nil)

    init() { super.init(size: NSSize(width: 820, height: 1060)) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        stack.addArrangedSubview(label("A rope hidden under the menu bar. Screenshots hang on it instead of piling up on the desktop; take one down when you need it.", secondary: true))
        for (box, action) in [(takeover, #selector(toggleTakeover)), (copied, #selector(toggleCopied))] {
            box.target = self
            box.action = action
        }
        stack.addArrangedSubview(row("Screenshots", takeover))
        let note = label("Turns off the floating thumbnail and saves screenshots to the rope's folder. Your own settings come back when this is off or Swivel quits.", size: 11, secondary: true)
        note.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(row("", note))
        stack.addArrangedSubview(row("Clipboard", copied))

        stack.addArrangedSubview(RopeColorsView())

        let gestures = NSGridView(views: [
            ["Click", "Copy the image"], ["Double-click", "Open in Preview (QuickTime for recordings)"],
            ["Hold or force click", "Quick Look"], ["Drag into an app", "Send a copy — the original stays on the rope"],
            ["Drag into a folder", "Move it there — it comes off the rope"], ["Drag to the Trash, or click ×", "Throw it away"],
            ["Move to the top edge", "Lower the rope"], ["Click the menu bar", "Put the rope away"], ["⌃ ⌥ T", "Show or hide the rope"],
        ].map { pair -> [NSView] in
            let key = NSTextField(labelWithString: L(pair[0]))
            key.font = .systemFont(ofSize: 12, weight: .semibold)
            let value = NSTextField(labelWithString: L(pair[1]))
            value.font = .systemFont(ofSize: 12)
            value.textColor = .secondaryLabelColor
            return [key, value]
        })
        gestures.rowSpacing = 6
        gestures.columnSpacing = 16
        stack.addArrangedSubview(row("Gestures", gestures))

        let show = NSButton(title: L("Show Rope"), target: self, action: #selector(showRope))
        let open = NSButton(title: L("Open Folder"), target: self, action: #selector(openFolder))
        stack.addArrangedSubview(row("", show, open))
    }

    override func refresh() {
        takeover.state = Prefs.clotheslineTakeover ? .on : .off
        copied.state = Prefs.clotheslineHangCopied ? .on : .off
    }

    @objc private func toggleCopied() { Prefs.clotheslineHangCopied = copied.state == .on }

    @objc private func toggleTakeover() {
        Prefs.clotheslineTakeover = takeover.state == .on
        if Prefs.clotheslineTakeover && Prefs.clotheslineEnabled { ScreenshotTakeover.enable(into: Clothesline.shared.incoming) } else { ScreenshotTakeover.restore() }
    }

    @objc private func showRope() { Clothesline.shared.toggle() }
    @objc private func openFolder() { NSWorkspace.shared.open(Clothesline.shared.folder) }
}

// MARK: - Shortcuts

final class ShortcutsPane: Pane {
    private var popups: [WheelMode: NSPopUpButton] = [:]
    private let launchToggle = NSButton(checkboxWithTitle: L("Open a tool wheel without dragging"), target: nil, action: nil)
    private let launchShortcut = NSPopUpButton()
    private let launchStatus = ToolUI.note("")
    private lazy var showLauncher = NSButton(title: L("Show Tool Wheel"), target: self, action: #selector(openLauncher))

    init() { super.init(size: NSSize(width: 760, height: 560)) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        stack.addArrangedSubview(label("Choose which key opens each menu. Start dragging first, then tap the key.", secondary: true))
        for (mode, title) in [(WheelMode.convert, "Convert formats"), (.tools, "File tools"), (.actions, "File actions"), (.apps, "App Actions"), (.codes, "QR Library"), (.custom, "My Wheel")] {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: TriggerKey.allCases.map(\.title))
            popup.target = self
            popup.action = #selector(changed(_:))
            popup.tag = WheelMode.allCases.firstIndex(of: mode)!
            popups[mode] = popup
            stack.addArrangedSubview(row(title, popup))
        }
        stack.addArrangedSubview(row("", label("""
            Picking a key that another menu uses swaps the two.
            My Wheel’s actions and shortcut are in Customize.
            For fn / 🌐: System Settings → Keyboard →
            “Press 🌐 key to” → “Do Nothing”.
            """, size: 11, secondary: true)))
        stack.addArrangedSubview(row("", NSButton(title: L("Restore Defaults"), target: self, action: #selector(reset))))
        launchToggle.target = self; launchToggle.action = #selector(toggleLauncher)
        launchShortcut.addItems(withTitles: WheelShortcut.allCases.map(\.title)); launchShortcut.target = self; launchShortcut.action = #selector(changeLauncherKey)
        stack.addArrangedSubview(launchToggle)
        stack.addArrangedSubview(row("Tool wheel shortcut", launchShortcut))
        stack.addArrangedSubview(label("Hold Control and Option with the selected key to open the wheel. Space alone only changes pages in an open wheel.", size: 12, secondary: true))
        stack.addArrangedSubview(launchStatus)
        stack.addArrangedSubview(showLauncher)
        stack.addArrangedSubview(label("Click an action, or use arrow keys and Return. Space changes pages; Esc closes. Only enabled tools appear.", size: 12, secondary: true))
        NotificationCenter.default.addObserver(forName: ShortcutWheel.changed, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    override func refresh() {
        for (mode, popup) in popups {
            popup.selectItem(at: TriggerKey.allCases.firstIndex(of: Prefs.key(for: mode))!)
        }
        launchToggle.state = Prefs.shortcutWheelEnabled ? .on : .off
        launchShortcut.selectItem(at: WheelShortcut.allCases.firstIndex(of: Prefs.wheelShortcut) ?? 0)
        launchShortcut.isEnabled = Prefs.shortcutWheelEnabled
        showLauncher.isEnabled = Feature.wheel.isOn && Prefs.shortcutWheelEnabled
        launchStatus.stringValue = !Prefs.shortcutWheelEnabled ? L("Tool wheel shortcut is off") : ShortcutWheel.shared.reservedBySystem ? L("This shortcut is used by macOS. Choose a different shortcut.") : ShortcutWheel.shared.available ? L("Shortcut is ready") : L("This shortcut is unavailable. Choose another shortcut or open the panel below.")
    }

    @objc private func changed(_ sender: NSPopUpButton) {
        Prefs.setKey(TriggerKey.allCases[sender.indexOfSelectedItem], for: WheelMode.allCases[sender.tag])
    }

    @objc private func reset() { Prefs.resetKeys() }
    @objc private func toggleLauncher() { Prefs.shortcutWheelEnabled = launchToggle.state == .on }
    @objc private func openLauncher() { ShortcutWheel.shared.show() }
    @objc private func changeLauncherKey() { Prefs.wheelShortcut = WheelShortcut.allCases[launchShortcut.indexOfSelectedItem] }
}

// MARK: - Style

final class StylePane: Pane {
    private var cards: [TemplateCard] = []

    init() { super.init(size: NSSize(width: 860, height: 640)) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        stack.addArrangedSubview(label("Choose how the menu looks when it pops up. Click a template to use it.", secondary: true))
        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        var row: [NSView] = []
        for style in MenuStyle.allCases {
            let card = TemplateCard(style)
            card.onPick = { Prefs.style = $0 }
            cards.append(card)
            row.append(card)
            if row.count == 3 { grid.addRow(with: row); row = [] }
        }
        if !row.isEmpty { grid.addRow(with: row) }
        stack.addArrangedSubview(grid)
        stack.addArrangedSubview(tryItHint())
    }

    override func refresh() {
        for card in cards { card.setSelected(card.style == Prefs.style) }
    }
}

/// A button-style click: pressed while the mouse is down over the control, committed only on release over it.
struct ClickTracker {
    private(set) var isDown = false
    private(set) var isInside = false
    var showsPressed: Bool { isDown && isInside }

    mutating func down() {
        isDown = true
        isInside = true
    }

    mutating func drag(inside: Bool) {
        if isDown { isInside = inside }
    }

    /// Ends the click. True when it should commit.
    mutating func up(inside: Bool) -> Bool {
        defer {
            isDown = false
            isInside = false
        }
        return isDown && inside
    }
}

/// A template on the Style page. The whole card is one button: its edge lifts under the pointer, it presses in on
/// mouse-down and picks the template on release (dragging off first cancels, as with a native button). The menu
/// inside is a live preview that can be tried on its own.
final class TemplateCard: NSView {
    let style: MenuStyle
    var onPick: ((MenuStyle) -> Void)?
    private(set) var isSelected = false
    private let host = PreviewHost()
    private var click = ClickTracker()
    private var tracking: NSTrackingArea?
    private var keyPress = 0

    // 0 → 1. Hover never overshoots; the press releases with a little give; a pick settles with a small spring.
    private var hover = Spring(0, response: 0.14, damping: 1)
    private var press = Spring(0, response: 0.09, damping: 1)
    private var selection = Spring(0, response: 0.22, damping: 0.7)
    private lazy var driver: FrameDriver = {
        let driver = FrameDriver(view: self)
        driver.onFrame = { [weak self] dt in self?.advance(dt) ?? false }
        return driver
    }()

    init(_ style: MenuStyle) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 250, height: 250))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        let wallpaper = WallpaperView()
        host.show(menuPreview(style: style, titles: ["JPG", "PNG", "HEIC", "WebP", "TIFF", "GIF", "PDF"], mode: .convert, hovered: 1))
        host.translatesAutoresizingMaskIntoConstraints = false
        wallpaper.addSubview(host)
        wallpaper.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: style.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let blurb = NSTextField(wrappingLabelWithString: style.blurb)
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 228
        let content = NSStackView(views: [wallpaper, title, blurb])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // The content sits at a fixed inset, so the border thickening on selection never nudges the preview.
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 250), heightAnchor.constraint(equalToConstant: 250),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            wallpaper.widthAnchor.constraint(equalTo: content.widthAnchor),
            wallpaper.heightAnchor.constraint(equalToConstant: 170),
            host.leadingAnchor.constraint(equalTo: wallpaper.leadingAnchor), host.trailingAnchor.constraint(equalTo: wallpaper.trailingAnchor),
            host.topAnchor.constraint(equalTo: wallpaper.topAnchor), host.bottomAnchor.constraint(equalTo: wallpaper.bottomAnchor),
        ])
        toolTip = L("Use the %@ template", style.title)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        // Picked: the edge thickens into the accent on a short spring. Unpicked: it fades back, quicker.
        let springy = selected && !Motion.reduced
        selection.response = springy ? 0.22 : 0.14
        selection.damping = springy ? 0.7 : 1
        selection.target = selected ? 1 : 0
        kick()
    }

    // MARK: Motion

    private func advance(_ dt: CGFloat) -> Bool {
        hover.step(dt, tuning: Prefs.interaction.tools)
        press.step(dt, tuning: Prefs.interaction.tools)
        selection.step(dt, tuning: Prefs.interaction.tools)
        needsDisplay = true
        return !(hover.isSettled && press.isSettled && selection.isSettled)
    }

    /// Animates on screen; off screen everything jumps to where it's going.
    private func kick() {
        if window != nil {
            driver.start()
        } else {
            hover.snap(hover.target)
            press.snap(press.target)
            selection.snap(selection.target)
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        // Leaving the screen (another page): forget the pointer, so the card comes back at rest.
        driver.stop()
        click = ClickTracker()
        hover.snap(0)
        press.snap(0)
        selection.snap(selection.target)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let h = min(max(hover.value, 0), 1), p = min(max(press.value, 0), 1), s = selection.value
        layer.cornerRadius = 12
        layer.masksToBounds = false  // AppKit turns clipping on with a corner radius; it would cut off the shadow
        layer.borderWidth = 1 + 2 * max(s, 0)
        layer.borderColor = NSColor.separatorColor.mix(.tertiaryLabelColor, h).mix(.controlAccentColor, min(max(s, 0), 1)).cgColor
        // Under the pointer the card lifts on a soft shadow (no scaling, which would blur its text while it rests
        // there); pressed, the shadow tucks back in and the face darkens a little.
        layer.backgroundColor = NSColor.controlBackgroundColor.mix(.labelColor, 0.06 * p).cgColor
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        layer.shadowOpacity = Float((dark ? 0.35 : 0.13) * h * (1 - 0.7 * p))
        layer.shadowRadius = 4 + 6 * h * (1 - 0.5 * p)
        layer.shadowOffset = CGSize(width: 0, height: -(1 + 3 * h * (1 - 0.6 * p)))
        // Pressed in to 97 %, about the centre (a backing layer's anchor is its corner). Reduce Motion: colour only.
        let scale = Motion.reduced ? 1 : 1 - 0.03 * press.value
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        layer.transform = CATransform3DTranslate(t, -c.x, -c.y, 0)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        hover.response = on ? 0.14 : 0.1  // exits are quicker than entrances
        hover.target = on ? 1 : 0
        kick()
    }

    /// The live preview takes the pointer itself; anywhere else on the card, labels included, is the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit.isDescendant(of: host) ? hit : self
    }

    // A click on the preview reaches these too: PreviewHost passes its mouse events on.
    override func mouseDown(with event: NSEvent) {
        click.down()
        pressChanged()
    }

    override func mouseDragged(with event: NSEvent) {
        click.drag(inside: isInside(event))
        pressChanged()
    }

    override func mouseUp(with event: NSEvent) {
        let picked = click.up(inside: isInside(event))
        pressChanged()
        if picked { onPick?(style) }
    }

    private func isInside(_ event: NSEvent) -> Bool { bounds.contains(convert(event.locationInWindow, from: nil)) }

    private func pressChanged() {
        let down = click.showsPressed
        guard press.target != (down ? 1 : 0) else { return }
        // In fast and firm; back out with a little give.
        press.response = down ? 0.09 : 0.28
        press.damping = down ? 1 : 0.8
        press.target = down ? 1 : 0
        kick()
    }

    // MARK: Keyboard and accessibility

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }

    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 else {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }
        // The same press and release as a click; the pick itself doesn't wait for it.
        keyPress += 1
        let current = keyPress
        press.response = 0.09
        press.damping = 1
        press.target = 1
        kick()
        onPick?(style)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self, self.keyPress == current else { return }
            self.pressChanged()
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityLabel() -> String? { style.title }
    override func accessibilityHelp() -> String? { style.blurb }
    override func accessibilityValue() -> Any? { NSNumber(value: isSelected) }

    override func accessibilityPerformPress() -> Bool {
        onPick?(style)
        return true
    }
}

// MARK: - Customize

/// Where a reordered row lands, and when a reorder drag has moved to a new place (one haptic detent per place).
struct DropSlot {
    private(set) var destination: Int?

    /// The index a row moved from `from` ends up at when dropped above row `proposed` (the row itself counts).
    static func destination(from: Int, proposed: Int) -> Int { from < proposed ? proposed - 1 : proposed }

    /// Records the place a drag would drop now. True when that is a new place; the drag's first place doesn't count.
    mutating func move(to place: Int) -> Bool {
        defer { destination = place }
        return destination != nil && destination != place
    }

    mutating func reset() { destination = nil }
}

/// What Customize saves for one menu. Its rows list only the items whose tools are on right now (Extract Text, image
/// presets, Hang and Float come and go with their features), so the stored entries for every other title are carried
/// over: they stay hidden if they were, and each keeps its place right after the title it followed.
enum Arrangement {
    /// My Wheel's picks after editing: the ticked rows in their order, with picks that aren't listed right now (their
    /// tool is off, their app was turned off) kept where they were.
    static func mergedPicks(rows: [(title: String, shown: Bool)], stored: [String]) -> [String] {
        var picks = rows.filter(\.shown).map(\.title)
        let present = Set(rows.map(\.title))
        for (index, id) in stored.enumerated() where !present.contains(id) { picks.insert(id, at: min(index, picks.count)) }
        return picks
    }

    static func merged(rows: [(title: String, shown: Bool)], storedOrder: [String],
                       storedHidden: Set<String>) -> (order: [String], hidden: Set<String>) {
        let present = Set(rows.map(\.title))
        let hidden = Set(rows.filter { !$0.shown }.map(\.title)).union(storedHidden.subtracting(present))
        var order = rows.map(\.title)
        var placed = present
        for (i, title) in storedOrder.enumerated() where !placed.contains(title) {
            placed.insert(title)
            // Everything before it in the stored order is already placed (shown now, or put back just before), so
            // it goes right after its predecessor; one that led the list stays at the front.
            let after = i > 0 ? order.firstIndex(of: storedOrder[i - 1]) : nil
            order.insert(title, at: after.map { $0 + 1 } ?? 0)
        }
        return (order, hidden)
    }
}

/// A Customize row: a native checkbox and a grip. Anywhere but the checkbox starts a drag, so reordering doesn't
/// fight with ticking.
private final class ArrangeCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("arrange")
    let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    /// Shows the grip without taking the click, so a drag that starts on it moves the row.
    private final class Grip: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        let grip = Grip(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage())
        grip.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        grip.contentTintColor = .tertiaryLabelColor
        grip.toolTip = L("Drag to reorder")
        for view in [box, grip] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.trailingAnchor.constraint(lessThanOrEqualTo: grip.leadingAnchor, constant: -8),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class CustomizePane: Pane, NSTableViewDataSource, NSTableViewDelegate {
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let table = NSTableView()
    private let host = PreviewHost()
    private var rows: [(title: String, shown: Bool)] = []
    private var labels: [String] = []  // display titles: renaming an image preset keeps its stored title
    private static let rowType = NSPasteboard.PasteboardType("local.swivel.row")
    private let kinds: [FileKind] = [.image, .video, .audio, .pdf, .document, .archive, .other]
    /// Set while this pane writes Prefs: it already shows the change, so it ignores the notifications that follow.
    private var isSaving = false
    private var dragged: Int?
    private var slot = DropSlot()
    private var previewKey: PreviewKey?
    private var appEditor: AppTargetEditor?
    private lazy var addAppButton = ToolUI.button("Add Application…", target: self, action: #selector(addApplication))
    private lazy var addPageButton = ToolUI.button("Add Web Page…", target: self, action: #selector(addWebPage))
    private lazy var manageAppsButton = ToolUI.button("Manage Applications…", target: self, action: #selector(manageApplications))
    private lazy var libraryButton = ToolUI.button("Open QR Library…", target: self, action: #selector(openLibrary))
    // My Wheel: its key during a drag and its shortcut, beside the actions it shows.
    private let customKey = NSPopUpButton(frame: .zero, pullsDown: false)
    private let recorder = ShortcutRecorder()
    private lazy var showCustom = ToolUI.button("Show My Wheel", target: self, action: #selector(showCustomWheel))
    private let customStatus = ToolUI.note("")
    private var recorderProblem: String?
    private lazy var customControls = ToolUI.stack([
        ToolUI.note("Tick actions from every menu to build My Wheel. While dragging, it shows only the ones that fit the file."),
        ToolUI.stack([NSTextField(labelWithString: L("Key while dragging:")), customKey,
                      NSTextField(labelWithString: L("Shortcut:")), recorder, showCustom], vertical: false, spacing: 8),
        customStatus,
    ], spacing: 6)
    private var listHeight: NSLayoutConstraint?
    private var previewHeight: NSLayoutConstraint?
    /// The menu to show when the page opens (set by `open(_:)`).
    private static var requestedMode: WheelMode?
    private static weak var current: CustomizePane?

    /// Opens Settings on this page with a menu chosen, e.g. My Wheel when its shortcut finds nothing picked.
    static func open(_ mode: WheelMode) {
        requestedMode = mode
        AppWindow.shared.show(.customize)
        current?.applyRequestedMode()
    }
    private func applyRequestedMode() {
        guard isViewLoaded, let mode = Self.requestedMode, let index = WheelMode.allCases.firstIndex(of: mode) else { return }
        Self.requestedMode = nil
        modePopup.selectItem(at: index)
        load(crossfade: false)
    }

    /// What the preview shows; it is rebuilt only when this changes.
    private struct PreviewKey: Equatable {
        let style: MenuStyle
        let mode: WheelMode
        let titles: [String]
        let labels: [String]
    }

    init() { super.init(size: NSSize(width: 860, height: 600)) }
    required init?(coder: NSCoder) { fatalError() }

    private var mode: WheelMode { WheelMode.allCases[modePopup.indexOfSelectedItem] }
    private var kind: FileKind { kinds[kindPopup.indexOfSelectedItem] }

    override func build() {
        stack.addArrangedSubview(label("Pick which options each menu shows and in what order. Untick to hide, drag to reorder.", secondary: true))
        modePopup.addItems(withTitles: ["Convert formats", "File tools", "File actions", "App Actions", "QR Library", "My Wheel"].map { L($0) })
        kindPopup.addItems(withTitles: kinds.map(\.title))
        for (popup, i) in [(modePopup, 0), (kindPopup, 1)] {
            popup.target = self
            popup.action = #selector(selectionChanged)
            popup.tag = i
        }
        for (i, kind) in kinds.enumerated() {
            kindPopup.item(at: i)?.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        }
        let reset = NSButton(title: L("Restore Defaults"), target: self, action: #selector(resetContents))
        let pickers = NSStackView(views: [NSTextField(labelWithString: L("Menu:")), modePopup,
                                          NSTextField(labelWithString: L("File type:")), kindPopup, reset])
        pickers.spacing = 8
        stack.addArrangedSubview(pickers)
        stack.addArrangedSubview(ToolUI.stack([addAppButton, addPageButton, manageAppsButton, libraryButton], vertical: false, spacing: 8))
        customKey.addItems(withTitles: TriggerKey.allCases.map(\.title))
        customKey.target = self; customKey.action = #selector(customKeyChanged); customKey.setAccessibilityLabel(L("Key while dragging"))
        recorder.onProblem = { [weak self] problem in self?.recorderProblem = problem; self?.updateCustomControls() }
        customStatus.preferredMaxLayoutWidth = 780
        stack.addArrangedSubview(customControls)
        NotificationCenter.default.addObserver(forName: CustomWheelLauncher.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCustomControls() }
        }
        Self.current = self

        let column = NSTableColumn(identifier: .init("item"))
        column.title = "Option"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.style = .inset
        // Rows aren't selected for anything, so a click on one shouldn't light it up.
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        // The rows part to show where the dragged one will go, instead of a thin line.
        table.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 260).isActive = true
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 420)
        listHeight?.isActive = true

        let wallpaper = WallpaperView()
        wallpaper.translatesAutoresizingMaskIntoConstraints = false
        host.translatesAutoresizingMaskIntoConstraints = false
        wallpaper.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: wallpaper.leadingAnchor), host.trailingAnchor.constraint(equalTo: wallpaper.trailingAnchor),
            host.topAnchor.constraint(equalTo: wallpaper.topAnchor), host.bottomAnchor.constraint(equalTo: wallpaper.bottomAnchor),
            wallpaper.widthAnchor.constraint(equalToConstant: 500),
        ])
        previewHeight = wallpaper.heightAnchor.constraint(equalToConstant: 420)
        previewHeight?.isActive = true
        let previewColumn = NSStackView(views: [wallpaper, tryItHint()])
        previewColumn.orientation = .vertical
        previewColumn.alignment = .leading
        previewColumn.spacing = 8
        let split = NSStackView(views: [scroll, previewColumn])
        split.spacing = 20
        split.alignment = .top
        stack.addArrangedSubview(split)
        if let mode = Self.requestedMode, let index = WheelMode.allCases.firstIndex(of: mode) { Self.requestedMode = nil; modePopup.selectItem(at: index) }
        load()
    }

    override func refresh() {
        guard isViewLoaded, modePopup.numberOfItems > 0, !isSaving else { return }
        load(crossfade: true)
    }

    private func load(crossfade: Bool = false) {
        for button in [addAppButton, addPageButton, manageAppsButton] { button.isHidden = mode != .apps }
        addAppButton.isEnabled = Feature.appRouting.isOn; addPageButton.isEnabled = Feature.appRouting.isOn
        libraryButton.isHidden = mode != .codes; libraryButton.isEnabled = Feature.qrCodes.isOn
        kindPopup.isEnabled = mode != .codes && mode != .custom
        customControls.isHidden = mode != .custom
        // My Wheel's key and shortcut take a little of the list's height.
        listHeight?.constant = mode == .custom ? 360 : 420; previewHeight?.constant = listHeight?.constant ?? 420
        updateCustomControls()
        let fresh: [(title: String, shown: Bool)], freshLabels: [String]
        if mode == .custom {
            // Every action from every menu: the picked ones first, in their order, then the rest in menu order.
            let candidates = CustomWheel.candidates(), available = Set(candidates.map(\.id))
            let picked = Prefs.customWheelItems.filter(available.contains), pickedSet = Set(picked)
            fresh = picked.map { (title: $0, shown: true) } + candidates.map(\.id).filter { !pickedSet.contains($0) }.map { (title: $0, shown: false) }
            freshLabels = fresh.map { CustomWheel.Ref(id: $0.title).map(CustomWheel.label) ?? $0.title }
        } else {
            let all = Catalog.allItems(mode: mode, kind: kind)
            let hidden = Prefs.hidden(mode, kind)
            let order = Prefs.order(mode, kind)
            let sorted = all.enumerated().sorted { a, b in
                (order.firstIndex(of: a.element) ?? order.count + a.offset) < (order.firstIndex(of: b.element) ?? order.count + b.offset)
            }.map(\.element)
            fresh = sorted.map { (title: $0, shown: !hidden.contains($0)) }
            freshLabels = sorted.map { Catalog.displayTitle($0) }
        }
        // Reload only for a real change from elsewhere (another menu or file type, Restore Defaults, a renamed
        // preset). Reloading for every settings change rebuilt the rows under the pointer, mid-click.
        if fresh.map(\.title) != rows.map(\.title) || fresh.map(\.shown) != rows.map(\.shown) || freshLabels != labels {
            rows = fresh
            labels = freshLabels
            table.reloadData()
        }
        updatePreview(crossfade: crossfade)
    }

    private func updateCustomControls() {
        guard mode == .custom else { return }
        customKey.selectItem(at: TriggerKey.allCases.firstIndex(of: Prefs.key(for: .custom)) ?? 0)
        recorder.refresh()
        showCustom.isEnabled = Feature.wheel.isOn && !Prefs.customWheelItems.isEmpty
        let status: String = switch CustomWheelLauncher.shared.status {
        case .none: Prefs.customWheelShortcut == nil ? L("Record a shortcut to open My Wheel without dragging; picked actions then ask for files.") : ""
        case .ready: L("Shortcut is ready")
        case .reservedBySystem: L("This shortcut is used by macOS. Choose a different shortcut.")
        case .usedBySwivel: L("Another Swivel shortcut uses these keys. Choose a different one.")
        case .unavailable: L("This shortcut is unavailable. Choose another shortcut or open the panel below.")
        }
        customStatus.stringValue = recorderProblem ?? status
        customStatus.textColor = recorderProblem == nil && CustomWheelLauncher.shared.status != .reservedBySystem
            && CustomWheelLauncher.shared.status != .usedBySwivel ? .secondaryLabelColor : .systemRed
    }

    private func updatePreview(crossfade: Bool) {
        // My Wheel's rows are "menu/title" ids; the menu draws the titles.
        let titles = rows.filter(\.shown).map { mode == .custom ? CustomWheel.Ref(id: $0.title)?.title ?? $0.title : $0.title }
        let key = PreviewKey(style: Prefs.style, mode: mode, titles: titles, labels: titles.map { Catalog.displayTitle($0) })
        guard key != previewKey else { return }
        previewKey = key
        host.show(menuPreview(style: key.style, titles: titles, mode: mode), crossfade: crossfade)
    }

    /// Writes the rows over the stored arrangement, keeping what's stored for items whose tools are off right now.
    /// (Restore Defaults is the one thing that clears those too.)
    private func save() {
        if mode == .custom {
            isSaving = true
            Prefs.customWheelItems = Arrangement.mergedPicks(rows: rows, stored: Prefs.customWheelItems)
            isSaving = false
            updateCustomControls()
            updatePreview(crossfade: true)
            return
        }
        let merged = Arrangement.merged(rows: rows, storedOrder: Prefs.order(mode, kind), storedHidden: Prefs.hidden(mode, kind))
        isSaving = true
        Prefs.setArrangement(order: merged.order, hidden: merged.hidden, mode, kind)
        isSaving = false
        updatePreview(crossfade: true)
    }

    @objc private func selectionChanged() { load(crossfade: true) }
    @objc private func addApplication() { addTarget(web: false) }
    @objc private func addWebPage() { addTarget(web: true) }
    private func addTarget(web: Bool) {
        guard Feature.appRouting.isOn, let window = view.window else { return }
        appEditor = AppTargetEditor(nil, web: web) { [weak self] value in
            var latest = Prefs.fileAppTargets; latest.append(value); Prefs.fileAppTargets = latest
            self?.load(crossfade: true)
        }
        appEditor?.present(on: window)
    }
    @objc private func manageApplications() { AppWindow.shared.show(.appRouting) }
    @objc private func openLibrary() { QRLibraryWindow().show() }
    @objc private func resetContents() {
        guard mode == .custom else { Prefs.resetContents(mode, kind); return }
        guard !Prefs.customWheelItems.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("Remove every action from My Wheel?")
        alert.informativeText = L("Its key and shortcut stay as they are.")
        alert.addButton(withTitle: L("Remove All")); alert.addButton(withTitle: L("Cancel"))
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { Prefs.customWheelItems = [] }
            }
        }
    }
    @objc private func customKeyChanged() { Prefs.setKey(TriggerKey.allCases[customKey.indexOfSelectedItem], for: .custom) }
    @objc private func showCustomWheel() { CustomWheelLauncher.shared.show() }

    @objc private func toggled(_ sender: NSButton) {
        // The row, not a tag: rows that were dragged keep their views but not their old index.
        let row = table.row(for: sender)
        guard rows.indices.contains(row) else { return }
        rows[row].shown = sender.state == .on
        save()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ArrangeCell.id, owner: self) as? ArrangeCell ?? ArrangeCell()
        cell.box.title = labels.indices.contains(row) ? labels[row] : Catalog.displayTitle(rows[row].title)
        cell.box.state = rows[row].shown ? .on : .off
        cell.box.target = self
        cell.box.action = #selector(toggled(_:))
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        dragged = rowIndexes.first
        slot.reset()
        // The parting gap slides rows aside as it moves; with Reduce Motion a drop line marks the place instead.
        tableView.draggingDestinationFeedbackStyle = Motion.reduced ? .regular : .gap
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        dragged = nil
        slot.reset()
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        // Over the middle of a row still means "here": aim between rows, so there's no spot that refuses the drop.
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        // A detent each time the gap moves to a new place (the finger is down, so the tap lands).
        if let from = dragged, slot.move(to: DropSlot.destination(from: from, proposed: row)) { Haptics.tick(.alignment) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let string = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let from = Int(string), rows.indices.contains(from) else { return false }
        let to = DropSlot.destination(from: from, proposed: row)
        guard to != from else { return true }  // put back where it was
        rows.insert(rows.remove(at: from), at: to)
        labels.insert(labels.remove(at: from), at: to)
        if Motion.reduced {
            tableView.reloadData()  // appears in place: moveRow always animates the slide
        } else {
            // Slide the row into the gap rather than reloading the list.
            tableView.beginUpdates()
            tableView.moveRow(at: from, to: to)
            tableView.endUpdates()
        }
        save()
        Haptics.tick(.generic)
        return true
    }
}
