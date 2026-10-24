import AppKit

/// A small HUD at the bottom of the screen reporting what happened. Click it to reveal the output.
///
/// It slides up into place and back down when it leaves; a toast replaced while visible keeps its place and only
/// changes its text, width and symbol. Hovering keeps it on screen.
@MainActor
final class Toast {
    static let shared = Toast()
    private let panel: NSPanel
    private let background = ToastView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: L(""))
    private var files: [URL] = []
    private var hideWork: DispatchWorkItem?
    private var autoHideDelay: TimeInterval?
    /// Changes whenever the toast is shown or hidden, so an older fade-out can't hide a newer toast.
    private var generation = 0
    private var shownSymbol: String?
    private var isSpinning = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.layer?.masksToBounds = true

        icon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1

        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        background.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        background.onClick = { [weak self] in self?.clicked() }
    }

    /// Shows a message. `near` places it just above a screen point (the pointer) instead of the bottom of the
    /// screen, with a small shake, for "that didn't work" moments. `spinning` animates the symbol while busy.
    func show(_ message: String, symbol: String, files: [URL] = [], tint: NSColor = .controlAccentColor,
              autoHide: Bool = true, near point: NSPoint? = nil, spinning: Bool = false) {
        generation += 1
        self.files = files
        background.isClickable = !files.isEmpty
        label.stringValue = files.isEmpty ? L(message) : L(message) + "  ·  " + L("Show")
        icon.contentTintColor = tint
        setSymbol(symbol, spinning: spinning)

        let width = min(max(label.intrinsicContentSize.width + 66, 180), 520)
        let screen = NSScreen.screens.first { NSMouseInRect(point ?? NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        var frame = NSRect(x: area.midX - width / 2, y: area.minY + 70, width: width, height: 48)
        if let point {
            frame.origin = NSPoint(x: point.x - width / 2, y: point.y + 26)
            frame.origin.x = min(max(frame.origin.x, area.minX + 8), area.maxX - width - 8)
            frame.origin.y = min(frame.origin.y, area.maxY - frame.height - 8)
        }

        // A toast by the pointer must sit above an open menu (pop-up menu level); others stay at status-bar level.
        panel.level = point == nil ? .statusBar : NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        let reduced = Motion.reduced
        if panel.isVisible, panel.alphaValue > 0.5, point == nil {
            // Already up: keep the place and let the width follow the new text.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduced ? 0 : 0.2
                ctx.timingFunction = WheelPanel.easeOut
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            // Rise into place from slightly below.
            panel.setFrame(frame.offsetBy(dx: 0, dy: reduced ? 0 : -10), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduced ? 0.12 : 0.22
                ctx.timingFunction = WheelPanel.easeOut
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
            if point != nil, !reduced { shake() }
        }

        hideWork?.cancel()
        autoHideDelay = autoHide ? (files.isEmpty ? 2.2 : 4) : nil
        // A toast that went away under the pointer (clicked, faded) never got a mouse-exited; start from where the
        // pointer really is, so an old hover can't hold this toast up forever.
        background.syncHover(NSMouseInRect(NSEvent.mouseLocation, frame, false))
        scheduleHide()
    }

    /// Takes down a busy toast (a window that just opened is its own feedback); leaves results and errors alone.
    func hideIfSpinning() {
        if isSpinning { hide() }
    }

    /// Fades the toast out now.
    func hide() {
        hideWork?.cancel()
        guard panel.isVisible else { return }
        generation += 1
        let token = generation
        let target = panel.frame.offsetBy(dx: 0, dy: Motion.reduced ? 0 : -6)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = WheelPanel.easeOut
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.panel.orderOut(nil)
                self.icon.removeAllSymbolEffects()
            }
        })
    }

    private func scheduleHide(after delay: TimeInterval? = nil) {
        hideWork?.cancel()
        guard let wait = delay ?? autoHideDelay, !background.isHovered else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Hovering holds the toast; leaving gives a little more time to read it.
    private func hoverChanged(_ inside: Bool) {
        if inside {
            hideWork?.cancel()
        } else if let delay = autoHideDelay {
            scheduleHide(after: min(delay, 1.2))
        }
    }

    private func setSymbol(_ name: String, spinning: Bool) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        icon.removeAllSymbolEffects()
        if shownSymbol != nil, shownSymbol != name, panel.isVisible, !Motion.reduced {
            icon.setSymbolImage(image, contentTransition: .replace.magic(fallback: .replace.downUp))
            if name == "checkmark.circle.fill" { icon.addSymbolEffect(.bounce, options: .nonRepeating) }
        } else {
            icon.image = image
        }
        shownSymbol = name
        isSpinning = spinning
        if spinning, !Motion.reduced { icon.addSymbolEffect(.rotate, options: .repeating) }
    }

    /// A short horizontal shake, like a refused password.
    private func shake() {
        guard let layer = background.layer else { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -7, 6, -4, 3, -1, 0]
        anim.duration = 0.32
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(anim, forKey: "shake")
    }

    private func clicked() {
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
        hide()
    }
}

/// The toast's background: tracks hover and gives a pressed state when the toast can be clicked.
final class ToastView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var isClickable = false
    private(set) var isHovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func syncHover(_ inside: Bool) { isHovered = inside }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        setPressed(false)
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { setPressed(true) }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() {
        if isClickable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// Presses in slightly while the mouse is down, so the click lands on something that responds.
    private func setPressed(_ pressed: Bool) {
        guard let layer, !Motion.reduced else { return }
        let scale: CGFloat = pressed ? 0.97 : 1
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer.presentation()?.transform ?? layer.transform
        anim.toValue = t
        anim.duration = pressed ? 0.08 : 0.16
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        layer.transform = t
        layer.add(anim, forKey: "press")
    }
}
