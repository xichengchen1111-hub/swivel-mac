import AppKit
import UniformTypeIdentifiers

@MainActor
enum ToolUI {
    static func button(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: L(title), target: target, action: action)
        button.bezelStyle = .push
        return button
    }

    static func note(_ title: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: L(title))
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    static func show(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = AppWindow.mainMenu()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Brings a tool panel forward without activating Swivel: the app the user is in keeps focus and its menu bar,
    /// and no Dock icon appears. `focus` also makes the panel key so it takes typing straight away.
    static func present(_ panel: ToolPanel, focus: Bool) {
        // Edit and Window menus for ⌘C, ⌘V, ⌘Z and ⌘W once the user clicks into the panel.
        if NSApp.mainMenu == nil { NSApp.mainMenu = AppWindow.mainMenu() }
        panel.orderFrontRegardless()
        if focus { panel.makeKey() }
    }

    /// Runs `body` on the main thread after `delay`, even while a modal session (an Open panel, an alert) is running
    /// inside the current main-queue job. `DispatchQueue.main.asyncAfter` can't do that: GCD holds main-queue blocks
    /// back until that job returns, which is after the modal ends. Run-loop timers keep firing in the modal-panel and
    /// event-tracking modes; they're named here as well as in the common modes, so this doesn't depend on AppKit
    /// having registered them yet. For timing a step (closing a panel), never for motion: that's a Spring.
    static func after(_ delay: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { body() } }
        for mode: RunLoop.Mode in [.common, .modalPanel, .eventTracking] { RunLoop.main.add(timer, forMode: mode) }
    }

    static func didClose() {
        DispatchQueue.main.async {
            // Non-activating panels never asked for the Dock icon, so they don't keep it either.
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) && !$0.styleMask.contains(.nonactivatingPanel) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    static func chooseFiles(imagesOnly: Bool = false, multiple: Bool = true, folders: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = folders
        panel.canChooseFiles = true
        if imagesOnly { panel.allowedContentTypes = [.image] }
        panel.prompt = L("Choose")
        NSApp.activate()
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }

    static func embed(_ child: NSView, in parent: NSView, inset: CGFloat = 20) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

    /// Fades a view up to fully opaque. Opacity only, so it stays the same under Reduce Motion.
    static func fadeIn(_ view: NSView, from alpha: CGFloat = 0, duration: TimeInterval = 0.15) {
        view.alphaValue = alpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration / Double(Prefs.interaction.tools.safeSpeed)
            view.animator().alphaValue = 1
        }
    }

    /// "That didn't work": a short sideways shake of the offending control plus the refuse tap. With Reduce Motion
    /// the control stays still and the system alert sound marks the refusal instead.
    static func refuse(_ view: NSView) {
        Feedback.refuse()
        guard !Motion.reduced else { NSSound.beep(); return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -6, 5, -3, 2, 0]
        shake.duration = 0.28 / Double(Prefs.interaction.tools.safeSpeed)
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(shake, forKey: "refuse")
    }

    /// Keeps a button as wide as its widest title (with its image, if any), so swapping titles (Copied, Processing
    /// 3 of 12…) never shifts the buttons beside it.
    static func reserveWidth(_ button: NSButton, for variants: [(title: String, image: NSImage?)]) {
        let (title, image, position) = (button.title, button.image, button.imagePosition)
        var widest: CGFloat = 0
        for variant in variants {
            button.title = variant.title
            button.image = variant.image
            button.imagePosition = variant.image == nil ? .noImage : .imageLeading
            widest = max(widest, button.intrinsicContentSize.width)
        }
        (button.title, button.image, button.imagePosition) = (title, image, position)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(widest)).isActive = true
    }
}

/// The app the user was in when Swivel had to come forward for a moment (Quick Look only works while Swivel is
/// active), so activation can go back to it afterwards, as the clothesline's QuickLooker does.
struct ActivationReturn {
    private(set) var app: NSRunningApplication?

    /// Call just before activating Swivel. Nothing is remembered when Swivel itself (or nothing) was in front.
    mutating func remember(_ frontmost: NSRunningApplication?, current: NSRunningApplication = .current) {
        app = frontmost == current ? nil : frontmost
    }

    /// The app to give activation back to, at most once: only while Swivel is still the active app (the user hasn't
    /// clicked into another one meanwhile) and that app is still running.
    mutating func take(swivelIsActive: Bool) -> NSRunningApplication? {
        defer { app = nil }
        guard swivelIsActive, let app, !app.isTerminated else { return nil }
        return app
    }
}

/// A floating panel that can take keyboard focus while another app stays active (Spotlight-style).
class ToolPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// While Swivel isn't the active app its menu bar isn't in charge, so route the standard editing shortcuts here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !NSApp.isActive, flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: Selector? = switch key {
        case "x": #selector(NSText.cut(_:))
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "a": #selector(NSText.selectAll(_:))
        case "z": flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        case "w": #selector(NSWindow.performClose(_:))
        default: nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// An accent outline over a drop target while files hover over it. It never takes clicks or drags itself.
final class DropRing: NSView {
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        shape.fillColor = nil
        shape.lineWidth = 2
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        shape.frame = bounds
        shape.path = CGPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    override func updateLayer() {
        shape.strokeColor = NSColor.controlAccentColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    /// Fades in quickly and out a little faster.
    func setShown(_ shown: Bool) {
        needsDisplay = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = (shown ? 0.12 : 0.1) / Double(Prefs.interaction.tools.safeSpeed)
            animator().alphaValue = shown ? 1 : 0
        }
    }
}

/// Native text fields retain editing shortcuts even in a menu-bar app.
final class ToolTable: NSTableView {
    var deleteSelection: (() -> Void)?
    var previewSelection: (() -> Void)?
    /// Files started hovering over the table and it will accept them.
    var dropTargeted: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { deleteSelection?(); return }
        if event.keyCode == 49 { previewSelection?(); return }
        super.keyDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        if !operation.isEmpty { dropTargeted?() }
        return operation
    }
}
