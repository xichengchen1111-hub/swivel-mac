import AppKit

struct ActionResult {
    var message: String
    var files: [URL] = []
}

struct WheelItem {
    let title: String
    @MainActor var displayTitle: String { Catalog.displayTitle(title) }
    let run: @MainActor ([URL]) async throws -> ActionResult
    @MainActor func perform(_ urls: [URL]) async throws -> ActionResult {
        try ConversionNotice.confirm(title: title, urls: urls)
        return try await run(urls)
    }
}

/// Owns the wheel panel: opens it at the cursor on a key tap, pages it, and runs the dropped-on item.
@MainActor
final class WheelController {
    private let panel = WheelPanel()
    private var toast: Toast { Toast.shared }
    private var mode: WheelMode?
    private var pages: [[WheelItem]] = []
    private var page = 0
    private static let perPage = 8
    /// Demo only: a menu style to use instead of the saved one.
    var styleOverride: MenuStyle?
    private var clickMonitors: [Any] = []
    var isVisible: Bool { panel.isVisible && !panel.isClosing }

    init() {
        panel.wheel.onDrop = { [weak self] item, urls in self?.perform(item, urls: urls) }
        panel.wheel.onClick = { [weak self] item in self?.perform(item, urls: []) }
        panel.wheel.onCancel = { [weak self] in self?.close(.cancel) }
        panel.wheel.onNextPage = { [weak self] in self?.demoNextPage() }
        panel.wheel.onDragEndedWithoutDrop = { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isClosing, self.panel.wheel.pressed == nil else { return }
            self.close(.cancel)
        }
        // Draw a menu once offscreen so fonts and shadows are cached before the first real one opens.
        DispatchQueue.main.async { [panel] in
            let view = menuPreview(style: .wheel, titles: ["JPG", "PNG", "HEIC", "PDF"], mode: .convert, hovered: 0)
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: rep) }
            _ = panel
        }
    }

    func keyTapped(_ newMode: WheelMode, urls: [URL]) {
        panel.wheel.isClickable = false
        if newMode == mode, panel.isVisible, !panel.isClosing {
            guard pages.count > 1 else {
                Feedback.refuse()
                return
            }
            page = (page + 1) % pages.count
            refresh()
            panel.wheel.rehover(atScreen: NSEvent.mouseLocation)
            return
        }
        let items = Catalog.items(for: urls, mode: newMode)
        guard !items.isEmpty else {
            Feedback.refuse()
            toast.show("Nothing to show for this file", symbol: "nosign", near: NSEvent.mouseLocation)
            return
        }
        mode = newMode
        panel.wheel.style = styleOverride ?? Prefs.style
        pages = stride(from: 0, to: items.count, by: Self.perPage).map {
            Array(items[$0..<min($0 + Self.perPage, items.count)])
        }
        page = 0
        panel.wheel.subtitle = urls.count == 1 ? urls[0].lastPathComponent : L("%d files", urls.count)
        refresh()
        panel.show(at: NSEvent.mouseLocation)
    }

    /// Keyboard-launched wheels use the same layouts and feedback, with click/arrow/Return selection.
    func showClickable(_ items: [WheelItem], mode: WheelMode = .tools) {
        guard !items.isEmpty else { return }
        removeClickMonitors()
        self.mode = mode; page = 0
        pages = stride(from: 0, to: items.count, by: Self.perPage).map { Array(items[$0..<min($0 + Self.perPage, items.count)]) }
        panel.wheel.isClickable = true; panel.wheel.style = styleOverride ?? Prefs.style
        panel.wheel.subtitle = L("Click or use arrows · Return · Space for next page")
        panel.acceptsMouseMovedEvents = true
        refresh(); panel.show(at: NSEvent.mouseLocation); panel.makeKey(); panel.makeFirstResponder(panel.wheel)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close(.cancel) }
        }) { clickMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if event.window !== self?.panel { self?.close(.cancel) }; return event
        }) { clickMonitors.append(monitor) }
    }
    func dismiss() { close(.cancel) }
    private func removeClickMonitors() { clickMonitors.forEach(NSEvent.removeMonitor); clickMonitors.removeAll() }

    /// Demo only: shows an item as hovered (ignored if out of range).
    func demoHover(_ index: Int) {
        guard panel.wheel.items.indices.contains(index) else { return }
        panel.wheel.hovered = index
    }

    /// Demo only: drops on an item without running it.
    func demoPress(_ index: Int) {
        guard panel.wheel.items.indices.contains(index) else { return }
        panel.wheel.beginConfirm(index)
        Feedback.press()
        close(.confirm)
    }

    /// Demo only: turns to the next page as a second key tap would.
    func demoNextPage() {
        guard let mode, pages.count > 1 else { return }
        if panel.wheel.isClickable { page = (page + 1) % pages.count; refresh(); return }
        keyTapped(mode, urls: [])
    }

    func dragEnded() {
        guard panel.isVisible, !panel.isClosing else { return }
        // Released on the hub or away from the menu: nothing will be dropped, so clear it away at once.
        guard panel.wheel.hovered != nil else {
            close(.cancel)
            return
        }
        // Released over an item: the drop callback can arrive just after the mouse button is seen going up.
        let token = panel.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.panel.generation == token, self.panel.wheel.pressed == nil else { return }
            self.close(.cancel)
        }
    }

    private func refresh() {
        guard let mode else { return }
        panel.wheel.configure(items: pages[page], mode: mode, page: page, pageCount: pages.count)
        panel.relayout()
    }

    private func close(_ how: WheelPanel.Dismissal) {
        removeClickMonitors()
        panel.dismiss(how)
        mode = nil
    }

    private func perform(_ item: WheelItem, urls: [URL]) {
        close(.confirm)
        let editorsBefore = Editor.presented
        // Slow actions get a progress toast; items that open their own window (editors) don't need one.
        let busy = DispatchWorkItem { [toast] in
            guard Editor.presented == editorsBefore else { return }
            toast.show(item.displayTitle + "…", symbol: "arrow.triangle.2.circlepath.circle", autoHide: false, spinning: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: busy)
        Task { @MainActor in
            do {
                let result = try await item.perform(urls)
                busy.cancel()
                if !result.files.isEmpty { Feedback.done() }
                if result.message.isEmpty, result.files.isEmpty {
                    toast.hide()
                } else {
                    toast.show(result.message, symbol: "checkmark.circle.fill", files: result.files)
                }
            } catch is Cancelled {
                busy.cancel()
                // Closing an editor window is its own confirmation; only say "Cancelled" for other actions.
                if Editor.presented == editorsBefore {
                    toast.show("Cancelled", symbol: "xmark.circle", tint: .secondaryLabelColor)
                } else {
                    toast.hide()
                }
            } catch let info as Info {
                busy.cancel()
                toast.show(info.message, symbol: "info.circle.fill")
            } catch {
                busy.cancel()
                toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .systemRed)
            }
        }
    }
}

final class WheelPanel: NSPanel {
    let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))

    init() {
        super.init(contentRect: wheel.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none

        // Clear glass under styles that want a frosted backdrop (wheel, list).
        let container = NSView(frame: wheel.frame)
        container.wantsLayer = true
        container.addSubview(glass)
        container.addSubview(wheel)
        contentView = container
    }

    private let glass = WheelPanel.makeGlass(frame: .zero, radius: 0)

    /// Resizes the panel and its glass for the menu's current style and item count, keeping it where it opened.
    func relayout() {
        let size = WheelView.size(for: wheel.style, count: wheel.items.count, live: true)
        if size != frame.size {
            setContentSize(size)
            if isVisible { place(at: anchor) }
        }
        contentView?.frame = NSRect(origin: .zero, size: size)
        wheel.frame = NSRect(origin: .zero, size: size)
        // Under Reduce Transparency the wheel draws its own solid disc; the list keeps the effect view, whose
        // system fallback is already opaque.
        if let (rect, radius) = wheel.backdrop,
           !(wheel.style == .wheel && NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
            glass.isHidden = false
            glass.frame = rect
            if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
                glass.cornerRadius = radius
            } else {
                glass.layer?.cornerRadius = radius
            }
        } else {
            glass.isHidden = true
        }
        wheel.needsDisplay = true
    }

    private static func makeGlass(frame: NSRect, radius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .clear
            glass.cornerRadius = radius
            return glass
        }
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0.6
        blur.wantsLayer = true
        blur.layer?.cornerRadius = radius
        blur.layer?.masksToBounds = true
        return blur
    }

    override var canBecomeKey: Bool { wheel.isClickable }
    override var canBecomeMain: Bool { false }
    override func accessibilityChildren() -> [Any]? { wheel.isClickable ? [wheel] : super.accessibilityChildren() }

    enum Dismissal { case cancel, confirm }

    /// True while the menu animates away after a drop or cancel.
    private(set) var isClosing = false
    /// Changes every time the menu opens or goes away, so stale timers and completions can tell.
    private(set) var generation = 0
    private var anchor = NSPoint.zero

    /// A strong ease-out: fades start at once and land softly.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    /// Puts the menu at the pointer. The wheel centres on it (the hub is the cancel zone) and only moves if its ring
    /// would leave the screen; other styles open beside the pointer, flipping sides when there's no room.
    private func place(at point: NSPoint) {
        anchor = point
        let size = frame.size
        let area = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.frame
            ?? NSRect(origin: .zero, size: size)
        var origin: NSPoint
        switch wheel.style {
        case .wheel:
            // .popUpMenu sits above the Dock and menu bar, so only the visible ring has to fit on screen.
            let r = wheel.outerRadius + 14
            let c = NSPoint(x: min(max(point.x, area.minX + r), area.maxX - r),
                            y: min(max(point.y, area.minY + r), area.maxY - r))
            origin = NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        case .list:
            origin = NSPoint(x: point.x + 28, y: point.y - size.height / 2)
            if origin.x + size.width > area.maxX { origin.x = point.x - 28 - size.width }
            origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        default:
            origin = NSPoint(x: point.x - size.width / 2, y: point.y + 28)
            if origin.y + size.height > area.maxY { origin.y = point.y - 28 - size.height }
            origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        }
        setFrameOrigin(origin)
    }

    func show(at point: NSPoint) {
        let switching = isVisible && !isClosing
        generation += 1
        isClosing = false
        // Explicitly false: the clear margin around the ring then still catches the drag.
        ignoresMouseEvents = false
        if !switching || hypot(point.x - anchor.x, point.y - anchor.y) > 4 { place(at: point) }
        wheel.isLive = true
        wheel.beginOpen(pointer: wheel.convert(convertPoint(fromScreen: point), from: nil))
        Feedback.prepare()
        // Switching to another menu keeps the panel up and just blooms the new items.
        guard !switching else { return }
        contentView?.layer?.removeAllAnimations()
        alphaValue = 0
        orderFrontRegardless()
        if !Motion.reduced { contentView?.popIn(from: 0.94) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.09 / Double(Prefs.interaction.menu.safeSpeed)
            ctx.timingFunction = Self.easeOut
            animator().alphaValue = 1
        }
    }

    /// Animates the menu away. A confirmed drop lets the pressed item finish its release first; a cancel shrinks
    /// and fades at once. Opening again (a new key tap) interrupts it.
    func dismiss(_ how: Dismissal) {
        guard isVisible, !isClosing else { return }
        isClosing = true
        ignoresMouseEvents = true
        let token = generation
        // A confirmed drop stays up long enough for the file's icon to land in the chosen item (about 0.2 s).
        let delay: TimeInterval = how == .confirm ? 0.16 / Double(Prefs.interaction.menu.safeSpeed) : 0
        let duration: TimeInterval = (how == .confirm ? 0.14 : 0.12) / Double(Prefs.interaction.menu.safeSpeed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token else { return }
            if !Motion.reduced { self.contentView?.shrinkAway(to: how == .confirm ? 0.97 : 0.93, duration: duration) }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = Self.easeOut
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.hide()
                }
            })
        }
    }

    /// Removes the menu immediately.
    func hide() {
        generation += 1
        isClosing = false
        orderOut(nil)
        contentView?.layer?.removeAllAnimations()
        contentView?.layer?.transform = CATransform3DIdentity
        wheel.hovered = nil
    }
}
