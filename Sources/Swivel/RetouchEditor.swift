import AppKit

/// Shared between the UI and the worker; the next stroke cancels obsolete work at a patch boundary.
final class RetouchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

final class RetouchEditor: Editor {
    private let canvas = RetouchCanvas()
    private var small: CGImage?
    private(set) var strokes: [RetouchStroke] = []
    private var brush: DetentSlider!
    private let status = NSTextField(wrappingLabelWithString: L("Paint over an object to repair the background."))
    private var cancellation = RetouchCancellation()
    private var saveTask: Task<[URL], Error>?
    private lazy var renderer = LiveRender<Result<CGImage, Error>> { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let image):
            self.canvas.preview.image = image
            self.status.stringValue = L("Paint over an object to repair the background.")
        case .failure(let error):
            if !(error is Cancelled) { self.status.stringValue = error.localizedDescription }
        }
    }

    init(source: URL) throws {
        super.init(title: "Retouch", source: source, canvas: canvas)
        brush = slider(0.003, 0.15, 0.025)
        addRow("Brush Size", brush)
        let compare = RetouchCompareButton(title: L("Show Original"), target: nil, action: nil)
        compare.bezelStyle = .push
        compare.onHold = { [weak self] showing in self?.canvas.preview.showOriginal(showing) }
        addRow("", compare)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        addRow("", status)
        canvas.onBegin = { [weak self] in self?.cancelPreview() }
        canvas.onCommit = { [weak self] stroke in
            guard let self else { return }
            self.replace(self.strokes + [stroke])
        }
    }

    override func load() async throws {
        let source = self.source
        let image = try await Images.detached { try Images.load(source, maxPixels: 1400) }
        small = image
        canvas.preview.image = image
        canvas.preview.original = image
    }

    private func replace(_ next: [RetouchStroke]) {
        let previous = strokes
        history.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.replace(previous) }
        }
        strokes = next
        render()
        noteEdited()
    }

    private func cancelPreview() { cancellation.cancel(); renderer.cancel() }

    private func render() {
        cancelPreview()
        guard let small else { return }
        cancellation = RetouchCancellation()
        let token = cancellation, strokes = self.strokes
        renderer.request { Result { try Retouch.render(small, strokes: strokes, cancelled: { token.isCancelled }) } }
    }

    override func update() { canvas.diameter = brush.doubleValue }
    override var hasUnsavedWork: Bool { !strokes.isEmpty }
    override func reset() { if !strokes.isEmpty { replace([]) } }
    override var canCancelSaving: Bool { true }
    override func cancelSaving() { saveTask?.cancel() }
    override func didClose() { cancelPreview(); saveTask?.cancel() }

    override func apply() async throws -> [URL] {
        cancelPreview()
        let source = self.source, strokes = self.strokes
        let task = Task.detached(priority: .userInitiated) { [try Retouch.save(source, strokes: strokes)] }
        saveTask = task
        defer { saveTask = nil }
        return try await task.value
    }
}

/// The preview keeps its normal aspect-fit geometry. This parent consumes brush events while the existing
/// ImagePreview implements press-and-hold comparison, driven by the labelled button below the canvas.
final class RetouchCanvas: NSView {
    let preview = ImagePreview()
    var diameter = 0.025
    var onBegin: (() -> Void)?
    var onCommit: ((RetouchStroke) -> Void)?
    private var draft: RetouchStroke?
    private let overlay = OverlayView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(preview)
        addSubview(overlay)
        overlay.drawer = { [unowned self] in
            guard let draft else { return }
            let rect = preview.imageRect
            let path = NSBezierPath()
            path.lineWidth = max(1, draft.diameter * max(rect.width, rect.height))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (index, p) in draft.points.enumerated() {
                let point = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                if index == 0 { path.move(to: point); path.line(to: point) } else { path.line(to: point) }
            }
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            path.stroke()
        }
        setAccessibilityLabel(L("Retouch"))
        toolTip = L("Paint over an object to repair the background.")
    }

    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); preview.frame = bounds; overlay.frame = bounds }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(preview.imageRect, cursor: .crosshair) }

    private func normalized(_ event: NSEvent) -> CGPoint? {
        let rect = preview.imageRect
        guard !rect.isEmpty else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(1, max(0, (p.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (p.y - rect.minY) / rect.height)))
    }

    override func mouseDown(with event: NSEvent) {
        guard preview.imageRect.contains(convert(event.locationInWindow, from: nil)), let point = normalized(event) else { return }
        window?.makeFirstResponder(self)
        onBegin?()
        draft = RetouchStroke(points: [point], diameter: diameter)
        overlay.needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard draft != nil, let point = normalized(event) else { return }
        draft?.points.append(point)
        overlay.needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard var stroke = draft else { return }
        if let point = normalized(event) { stroke.points.append(point) }
        draft = nil
        overlay.needsDisplay = true
        onCommit?(stroke)
        Feedback.press()
    }
}

private final class RetouchCompareButton: NSButton {
    var onHold: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onHold?(true)
        defer { onHold?(false) }
        super.mouseDown(with: event)
    }
}
