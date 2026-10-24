import AppKit

/// A mark on the photo. Points are normalized (0–1), bottom-left origin, so marks scale to full resolution.
struct Mark {
    enum Kind { case arrow, rectangle, ellipse, text, number }
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var width: CGFloat      // relative to the image's longer side
    var text = ""
}

/// Draws marks into any context whose drawing area is `rect`.
enum MarkRenderer {
    static func draw(_ marks: [Mark], in rect: CGRect, context ctx: CGContext) {
        let side = max(rect.width, rect.height)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }

        for mark in marks {
            let a = point(mark.start), b = point(mark.end)
            let lineWidth = max(1, mark.width * side)
            ctx.saveGState()
            ctx.setStrokeColor(mark.color.cgColor)
            ctx.setFillColor(mark.color.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setShadow(offset: CGSize(width: 0, height: -lineWidth * 0.3), blur: lineWidth,
                          color: NSColor.black.withAlphaComponent(0.3).cgColor)
            let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))

            switch mark.kind {
            case .arrow:
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = lineWidth * 4.5
                let shaftEnd = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
                ctx.move(to: a)
                ctx.addLine(to: shaftEnd)
                ctx.strokePath()
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - cos(angle - .pi / 7) * head, y: b.y - sin(angle - .pi / 7) * head))
                ctx.addLine(to: CGPoint(x: b.x - cos(angle + .pi / 7) * head, y: b.y - sin(angle + .pi / 7) * head))
                ctx.closePath()
                ctx.fillPath()
            case .rectangle:
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: lineWidth, cornerHeight: lineWidth, transform: nil))
                ctx.strokePath()
            case .ellipse:
                ctx.strokeEllipse(in: box)
            case .text:
                let size = lineWidth * 7
                drawString(mark.text, attrs: textAttributes(mark, size: size), at: CGPoint(x: a.x, y: a.y - size), in: ctx)
            case .number:
                let r = lineWidth * 3.5
                ctx.fillEllipse(in: CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2))
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: r * 1.15, weight: .heavy),
                                                            .foregroundColor: NSColor.white]
                let size = (mark.text as NSString).size(withAttributes: attrs)
                drawString(mark.text, attrs: attrs, at: CGPoint(x: a.x - size.width / 2, y: a.y - size.height / 2), in: ctx)
            }
            ctx.restoreGState()
        }
    }

    static func textAttributes(_ mark: Mark, size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: mark.color]
    }

    /// Where a just-placed mark grows from when it pops in: a number's centre, the middle of a text label.
    static func anchor(of mark: Mark, in rect: CGRect) -> CGPoint {
        let a = CGPoint(x: rect.minX + mark.start.x * rect.width, y: rect.minY + mark.start.y * rect.height)
        guard mark.kind == .text else { return a }
        let size = max(1, mark.width * max(rect.width, rect.height)) * 7
        let width = (mark.text as NSString).size(withAttributes: textAttributes(mark, size: size)).width
        return CGPoint(x: a.x + width / 2, y: a.y - size / 2)
    }

    private static func drawString(_ string: String, attrs: [NSAttributedString.Key: Any], at point: CGPoint, in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (string as NSString).draw(at: point, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The photo with marks drawn in, at the photo's own size.
    static func composite(_ image: CGImage, _ marks: [Mark]) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: rect)
        draw(marks, in: rect, context: ctx)
        return ctx.makeImage()
    }
}

/// What ⇧ does to a shape being drawn, in view points. Pure, so it can be tested.
enum MarkConstraint {
    /// The end of a line from `a` toward `b`, turned to the nearest multiple of 45°: the pointer projected onto that
    /// direction, plus which of the eight directions it is.
    static func snap45(from a: CGPoint, to b: CGPoint) -> (point: CGPoint, direction: Int)? {
        let dx = b.x - a.x, dy = b.y - a.y
        guard hypot(dx, dy) > 0.5 else { return nil }
        let step = CGFloat.pi / 4
        let direction = Int((atan2(dy, dx) / step).rounded())
        let angle = CGFloat(direction) * step
        let length = dx * cos(angle) + dy * sin(angle)
        return (CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length), (direction + 8) % 8)
    }

    /// The corner opposite `a` of the square whose side is the larger of the drag's width and height.
    static func square(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let side = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGPoint(x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side))
    }

    /// Pulls `b` back toward `a` (which is inside `rect`) until it's inside too, keeping the direction.
    static func clamp(_ b: CGPoint, from a: CGPoint, in rect: CGRect) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        var t: CGFloat = 1
        if b.x < rect.minX, dx != 0 { t = min(t, (rect.minX - a.x) / dx) }
        if b.x > rect.maxX, dx != 0 { t = min(t, (rect.maxX - a.x) / dx) }
        if b.y < rect.minY, dy != 0 { t = min(t, (rect.minY - a.y) / dy) }
        if b.y > rect.maxY, dy != 0 { t = min(t, (rect.maxY - a.y) / dy) }
        t = max(t, 0)
        return CGPoint(x: a.x + dx * t, y: a.y + dy * t)
    }
}

/// The photo with committed marks baked into one picture (a layer the GPU scales), and an overlay that draws only
/// the shape being dragged, so drawing stays quick however many marks there are. A placed number or text pops in.
final class AnnotateCanvas: NSView {
    var image: CGImage? {
        didSet {
            rebuild()
            needsLayout = true
        }
    }
    private(set) var marks: [Mark] = []
    var draft: Mark? { didSet { overlay.needsDisplay = true } }
    var makeMark: ((CGPoint) -> Mark?)?
    var onCommit: ((Mark) -> Void)?
    /// A click that couldn't place anything (the Text tool with no text).
    var onRefused: (() -> Void)?

    private let picture = PictureView()
    private let overlay = OverlayView()
    private var popping: Int?
    private var pop = Spring(1, response: 0.22, damping: 0.7)
    /// The ⇧ constraint holding (a direction 0–7, or 100 for a square), for one tap as each one catches.
    private var constraint: Int?
    private var lastPoint: NSPoint?
    private lazy var driver: FrameDriver = {
        let driver = FrameDriver(view: self)
        driver.onFrame = { [weak self] dt in self?.advance(dt) ?? false }
        return driver
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        overlay.drawer = { [unowned self] in self.drawOverlay() }
        addSubview(picture)
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    var imageRect: NSRect {
        guard let image else { return .zero }
        return fit(CGSize(width: image.width, height: image.height), in: bounds.insetBy(dx: 12, dy: 12))
    }

    override func layout() {
        super.layout()
        picture.frame = imageRect
        overlay.frame = bounds
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: .crosshair)
    }

    /// Replaces the committed marks; `popLast` makes the newest one pop in.
    func setMarks(_ new: [Mark], popLast: Bool) {
        popping = popLast && !new.isEmpty && !Motion.reduced ? new.count - 1 : nil
        if popping != nil {
            pop.snap(1.2)
            pop.target = 1
            driver.start()
        }
        marks = new
        rebuild()
    }

    private func rebuild() {
        guard let image else {
            picture.image = nil
            return
        }
        let baked = marks.enumerated().filter { $0.offset != popping }.map(\.element)
        picture.image = baked.isEmpty ? image : MarkRenderer.composite(image, baked) ?? image
        overlay.needsDisplay = true
    }

    private func advance(_ dt: CGFloat) -> Bool {
        pop.step(dt, tuning: Prefs.interaction.tools)
        if pop.isSettled { settlePop() }
        overlay.needsDisplay = true
        return popping != nil
    }

    /// The popping mark joins the baked picture.
    private func settlePop() {
        guard popping != nil else { return }
        popping = nil
        rebuild()
    }

    func stop() { driver.stop() }

    private func normalized(_ p: NSPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1), y: min(max((p.y - r.minY) / r.height, 0), 1))
    }

    private func drawOverlay() {
        guard image != nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        if let popping, marks.indices.contains(popping) {
            let mark = marks[popping]
            let anchor = MarkRenderer.anchor(of: mark, in: rect)
            ctx.saveGState()
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.scaleBy(x: pop.value, y: pop.value)
            ctx.translateBy(x: -anchor.x, y: -anchor.y)
            MarkRenderer.draw([mark], in: rect, context: ctx)
            ctx.restoreGState()
        }
        if let draft { MarkRenderer.draw([draft], in: rect, context: ctx) }
    }

    // MARK: Pointer

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard image != nil else { return }
        // Clicking the photo ends typing in the Text field, so ⌘Z now means marks.
        window?.makeFirstResponder(self)
        settlePop()
        let p = convert(event.locationInWindow, from: nil)
        lastPoint = p
        constraint = nil
        draft = makeMark?(normalized(p))
        if draft == nil { onRefused?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard draft != nil else { return }
        lastPoint = convert(event.locationInWindow, from: nil)
        reshape(shift: event.modifierFlags.contains(.shift))
    }

    override func flagsChanged(with event: NSEvent) {
        // Pressing or releasing ⇧ mid-drag reshapes at once, without waiting for the pointer to move.
        if draft != nil { reshape(shift: event.modifierFlags.contains(.shift)) }
        super.flagsChanged(with: event)
    }

    /// ⇧ turns an arrow to the nearest 45° and makes a box or circle square, tapping as each direction catches.
    private func reshape(shift: Bool) {
        guard var mark = draft, mark.kind != .number, mark.kind != .text, let p = lastPoint else { return }
        let rect = imageRect
        let a = CGPoint(x: rect.minX + mark.start.x * rect.width, y: rect.minY + mark.start.y * rect.height)
        var b = CGPoint(x: min(max(p.x, rect.minX), rect.maxX), y: min(max(p.y, rect.minY), rect.maxY))
        var caught: Int?
        if shift {
            if mark.kind == .arrow {
                if let snapped = MarkConstraint.snap45(from: a, to: p) {
                    b = MarkConstraint.clamp(snapped.point, from: a, in: rect)
                    caught = snapped.direction
                }
            } else {
                b = MarkConstraint.clamp(MarkConstraint.square(from: a, to: p), from: a, in: rect)
                caught = 100
            }
        }
        if let caught, caught != constraint { Haptics.tick(.alignment) }
        constraint = caught
        mark.end = normalized(b)
        draft = mark
    }

    override func mouseUp(with event: NSEvent) {
        guard let mark = draft else { return }
        draft = nil
        constraint = nil
        lastPoint = nil
        let moved = hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) > 0.01
        if mark.kind == .text || mark.kind == .number || moved { onCommit?(mark) }
    }
}

/// Arrows, boxes, circles, text and numbered callouts. Undo and redo go through the window (⌘Z / ⇧⌘Z), Reset too.
final class AnnotateEditor: Editor {
    private let canvas = AnnotateCanvas()
    private let tools: [(String, Mark.Kind)] = [("Arrow", .arrow), ("Box", .rectangle), ("Circle", .ellipse),
                                                 ("Text", .text), ("Number", .number)]
    private var tool: NSSegmentedControl!
    private let colorWell = NSColorWell(style: .minimal)
    private var thickness: NSSlider!
    private let textField = NSTextField(string: L("Note"))

    init(source: URL) throws {
        super.init(title: "Annotate Photo", source: source, canvas: canvas)
        tool = segments(tools.map(\.0))
        addRow("Tool", tool)
        colorWell.color = .systemRed
        thickness = slider(0.002, 0.015, 0.006)
        addRow("Style", colorWell, thickness)
        textField.placeholderString = L("Text to place")
        addRow("Text", textField)
        // No ⌘Z key equivalent on the button: the Edit menu's Undo reaches the window's undo manager, and lets a
        // field being typed in undo its own typing first.
        let undo = NSButton(title: L("Undo"), target: self, action: #selector(undo))
        let hint = NSTextField(labelWithString: L("Drag on the photo to draw. Text and numbers are placed with a click."))
        hint.textColor = .secondaryLabelColor
        addRow("", undo, hint)

        canvas.makeMark = { [weak self] point in
            guard let self else { return nil }
            let kind = self.tools[self.tool.selectedSegment].1
            var mark = Mark(kind: kind, start: point, end: point, color: self.colorWell.color, width: self.thickness.doubleValue)
            switch kind {
            case .text:
                guard !self.textField.stringValue.isEmpty else { return nil }
                mark.text = self.textField.stringValue
            case .number:
                mark.text = "\(self.canvas.marks.filter { $0.kind == .number }.count + 1)"
            default: break
            }
            return mark
        }
        canvas.onCommit = { [weak self] mark in
            guard let self else { return }
            self.setMarks(self.canvas.marks + [mark], pop: mark.kind == .number || mark.kind == .text)
        }
        canvas.onRefused = { [weak self] in
            // Nothing to place: say so the native way and put the cursor where the text goes.
            guard let self else { return }
            NSSound.beep()
            self.window.makeFirstResponder(self.textField)
            self.textField.selectText(nil)
        }
    }

    override func load() async throws {
        let source = self.source
        canvas.image = try await Images.detached { try Images.load(source, maxPixels: 1600) }
    }

    /// Replaces the marks in a way ⌘Z can take back (and ⇧⌘Z redo).
    private func setMarks(_ new: [Mark], pop: Bool = false) {
        let old = canvas.marks
        canvas.setMarks(new, popLast: pop)
        window.undoManager?.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.setMarks(old) }
        }
        noteEdited()
    }

    @objc private func undo() {
        window.makeFirstResponder(canvas)
        if window.undoManager?.canUndo == true { window.undoManager?.undo() }
    }

    override var hasUnsavedWork: Bool { !canvas.marks.isEmpty }

    override func reset() { if !canvas.marks.isEmpty { setMarks([]) } }

    override func didClose() { canvas.stop() }

    override func apply() async throws -> [URL] {
        let marks = canvas.marks, source = self.source
        return try await Images.detached {
            guard let result = MarkRenderer.composite(try Images.load(source), marks) else { throw ToolError("Image too large") }
            let (type, ext) = Images.writableType(for: source)
            return [try Images.save(result, as: Paths.preferred(for: source, ext: ext, suffix: " annotated"), type: type, quality: 0.95)]
        }
    }
}
