import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What a press on the crop box grabs. Coordinates are top-left origin (the crop view is flipped).
enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

    var left: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var right: Bool { self == .topRight || self == .right || self == .bottomRight }
    var top: Bool { self == .topLeft || self == .top || self == .topRight }
    var bottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (left || right) && (top || bottom) }

    /// The handle under `p` for a box drawn at `box`, or nil outside it. `tolerance` reaches outward from each edge;
    /// inward it shrinks to a quarter of the box, so a small box keeps a middle you can move it by and never grabs
    /// both opposite edges at once.
    static func hit(_ p: CGPoint, box: CGRect, tolerance: CGFloat) -> CropHandle? {
        guard box.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return nil }
        let inX = min(tolerance, box.width / 4), inY = min(tolerance, box.height / 4)
        func near(_ edge: CGFloat, _ value: CGFloat, outsideIsBelow: Bool, inner: CGFloat) -> Bool {
            let outside = outsideIsBelow ? value < edge : value > edge
            return abs(value - edge) < (outside ? tolerance : inner)
        }
        let l = near(box.minX, p.x, outsideIsBelow: true, inner: inX)
        let r = !l && near(box.maxX, p.x, outsideIsBelow: false, inner: inX)
        let t = near(box.minY, p.y, outsideIsBelow: true, inner: inY)
        let b = !t && near(box.maxY, p.y, outsideIsBelow: false, inner: inY)
        switch (l, r, t, b) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return box.contains(p) ? .move : nil
        }
    }
}

/// Picks the snap target a dragged edge should take: the one it already holds while still within `leave`, else the
/// nearest within `enter`. Holding on a little longer than it takes to catch is what stops a guide flickering.
struct SnapPick {
    struct Candidate: Equatable {
        var id: Int
        var delta: CGFloat  // target − current position
    }

    static func pick(_ candidates: [Candidate], previous: Int?, enter: CGFloat, leave: CGFloat) -> Candidate? {
        if let previous, let held = candidates.first(where: { $0.id == previous }), abs(held.delta) <= leave { return held }
        return candidates.filter { abs($0.delta) <= enter }.min { abs($0.delta) < abs($1.delta) }
    }
}

/// The geometry of one crop drag, in image pixels with a top-left origin. Free of AppKit so it can be tested.
///
/// Snap ids: lines 0–4 are the image's left/top edge, first third, centre, second third and right/bottom edge (a
/// moving box adds 10 × which of its own edges is caught: 0 leading, 1 middle, 2 trailing). Ids from 100 are
/// `freeRatios[id − 100]`.
struct CropDrag {
    var start: CGRect
    var handle: CropHandle
    var size: CGSize
    /// Locked width / height (an aspect segment, or ⇧ on a corner).
    var ratio: CGFloat?
    /// Ratios a free drag snaps to.
    var freeRatios: [CGFloat] = []
    /// Snap distance in pixels (the view converts its points).
    var enter: CGFloat
    var minSide: CGFloat = 16

    struct Snap: Equatable {
        var x: Int?
        var y: Int?
    }

    struct Result {
        var rect: CGRect
        var snap: Snap
    }

    var leave: CGFloat { enter * 1.5 }

    func lines(_ length: CGFloat) -> [CGFloat] { [0, length / 3, length / 2, length * 2 / 3, length] }

    /// The rect for a pointer that has moved by (dx, dy) pixels since the press.
    func rect(dx: CGFloat, dy: CGFloat, snapping: Bool, previous: Snap = Snap()) -> Result {
        let W = size.width, H = size.height
        var snap = Snap()
        if handle == .move {
            var r = start.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(0, r.minX), W - r.width)
            r.origin.y = min(max(0, r.minY), H - r.height)
            if snapping {
                if let hit = SnapPick.pick(moveCandidates(r.minX, r.width, lines(W)), previous: previous.x, enter: enter, leave: leave) {
                    r.origin.x = min(max(0, r.minX + hit.delta), W - r.width)
                    snap.x = hit.id
                }
                if let hit = SnapPick.pick(moveCandidates(r.minY, r.height, lines(H)), previous: previous.y, enter: enter, leave: leave) {
                    r.origin.y = min(max(0, r.minY + hit.delta), H - r.height)
                    snap.y = hit.id
                }
            }
            return Result(rect: r.roundedToPixels, snap: snap)
        }
        if let ratio { return locked(ratio, dx: dx, dy: dy, snapping: snapping, previous: previous) }

        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.left { minX = min(max(0, minX + dx), maxX - minSide) }
        if handle.right { maxX = max(min(W, maxX + dx), minX + minSide) }
        if handle.top { minY = min(max(0, minY + dy), maxY - minSide) }
        if handle.bottom { maxY = max(min(H, maxY + dy), minY + minSide) }
        if snapping {
            // Horizontal edge first; a corner's vertical edge may then catch a ratio of the width it got.
            if handle.left || handle.right {
                let edge = handle.left ? minX : maxX
                var candidates = lineCandidates(edge, lines(W))
                if !(handle.top || handle.bottom) {
                    let h = maxY - minY
                    candidates += freeRatios.enumerated().map { i, ratio in
                        .init(id: 100 + i, delta: (handle.left ? maxX - h * ratio : minX + h * ratio) - edge)
                    }
                }
                if let hit = SnapPick.pick(candidates.filter { valid(edge + $0.delta, horizontal: true, minX, maxX) },
                                           previous: previous.x, enter: enter, leave: leave) {
                    if handle.left { minX += hit.delta } else { maxX += hit.delta }
                    snap.x = hit.id
                }
            }
            if handle.top || handle.bottom {
                let edge = handle.top ? minY : maxY
                let w = maxX - minX
                var candidates = lineCandidates(edge, lines(H))
                candidates += freeRatios.enumerated().map { i, ratio in
                    .init(id: 100 + i, delta: (handle.top ? maxY - w / ratio : minY + w / ratio) - edge)
                }
                if let hit = SnapPick.pick(candidates.filter { valid(edge + $0.delta, horizontal: false, minY, maxY) },
                                           previous: previous.y, enter: enter, leave: leave) {
                    if handle.top { minY += hit.delta } else { maxY += hit.delta }
                    snap.y = hit.id
                }
            }
        }
        return Result(rect: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).roundedToPixels, snap: snap)
    }

    /// With a locked ratio: an edge drives its own dimension and the other follows, centred; a corner follows the
    /// pointer projected onto the box's diagonal, with the opposite corner pinned.
    private func locked(_ ratio: CGFloat, dx: CGFloat, dy: CGFloat, snapping: Bool, previous: Snap) -> Result {
        let W = size.width, H = size.height
        var snap = Snap()
        if handle.isCorner {
            let sx: CGFloat = handle.right ? 1 : -1, sy: CGFloat = handle.bottom ? 1 : -1
            // Growth of the height along the diagonal (width grows by ratio × this).
            var t = (sx * dx * ratio + sy * dy) / (ratio * ratio + 1)
            let room = min(handle.right ? (W - start.maxX) / ratio : start.minX / ratio,
                           handle.bottom ? H - start.maxY : start.minY)
            t = min(max(t, max((minSide - start.width) / ratio, minSide - start.height)), room)
            let w = start.width + t * ratio, h = start.height + t
            let x = handle.right ? start.minX : start.maxX - w
            let y = handle.bottom ? start.minY : start.maxY - h
            return Result(rect: CGRect(x: x, y: y, width: w, height: h).roundedToPixels, snap: snap)
        }
        if handle.left || handle.right {
            var edge = (handle.left ? start.minX : start.maxX) + dx
            if snapping, let hit = SnapPick.pick(lineCandidates(edge, lines(W)), previous: previous.x, enter: enter, leave: leave) {
                edge += hit.delta
                snap.x = hit.id
            }
            let maxW = min(handle.left ? start.maxX : W - start.minX, H * ratio)
            let w = min(max(handle.left ? start.maxX - edge : edge - start.minX, max(minSide, minSide * ratio)), maxW)
            let h = w / ratio
            let x = handle.left ? start.maxX - w : start.minX
            let y = min(max(0, start.midY - h / 2), H - h)
            return Result(rect: CGRect(x: x, y: y, width: w, height: h).roundedToPixels, snap: snap)
        }
        var edge = (handle.top ? start.minY : start.maxY) + dy
        if snapping, let hit = SnapPick.pick(lineCandidates(edge, lines(H)), previous: previous.y, enter: enter, leave: leave) {
            edge += hit.delta
            snap.y = hit.id
        }
        let maxH = min(handle.top ? start.maxY : H - start.minY, W / ratio)
        let h = min(max(handle.top ? start.maxY - edge : edge - start.minY, max(minSide, minSide / ratio)), maxH)
        let w = h * ratio
        let y = handle.top ? start.maxY - h : start.minY
        let x = min(max(0, start.midX - w / 2), W - w)
        return Result(rect: CGRect(x: x, y: y, width: w, height: h).roundedToPixels, snap: snap)
    }

    /// The largest rect of `ratio` inside `rect`, for a press that takes over a glide toward a locked ratio (the box
    /// drawn mid-glide has neither ratio). It keeps the grabbed edges where they are, so they stay under the pointer,
    /// and centres the rest; it stays inside the image and at least `minSide` on each side.
    static func fitted(_ rect: CGRect, to ratio: CGFloat, keeping handle: CropHandle, in size: CGSize,
                       minSide: CGFloat = 16) -> CGRect {
        var w = rect.width, h = rect.height
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        let grow = max(1, minSide / min(w, h))
        w *= grow
        h *= grow
        let shrink = min(1, size.width / w, size.height / h)
        w *= shrink
        h *= shrink
        var x = handle.left ? rect.minX : handle.right ? rect.maxX - w : rect.midX - w / 2
        var y = handle.top ? rect.minY : handle.bottom ? rect.maxY - h : rect.midY - h / 2
        x = min(max(0, x), size.width - w)
        y = min(max(0, y), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h).roundedToPixels
    }

    private func lineCandidates(_ edge: CGFloat, _ lines: [CGFloat]) -> [SnapPick.Candidate] {
        lines.enumerated().map { .init(id: $0.offset, delta: $0.element - edge) }
    }

    /// A moving box: its leading and trailing edges catch the image edges and thirds, its middle the centre.
    private func moveCandidates(_ origin: CGFloat, _ length: CGFloat, _ lines: [CGFloat]) -> [SnapPick.Candidate] {
        var list: [SnapPick.Candidate] = [.init(id: 12, delta: lines[2] - (origin + length / 2))]
        for i in [0, 1, 3, 4] {
            list.append(.init(id: i, delta: lines[i] - origin))
            list.append(.init(id: 20 + i, delta: lines[i] - (origin + length)))
        }
        return list
    }

    private func valid(_ edge: CGFloat, horizontal: Bool, _ low: CGFloat, _ high: CGFloat) -> Bool {
        let limit = horizontal ? size.width : size.height
        guard edge >= 0, edge <= limit else { return false }
        let leading = horizontal ? handle.left : handle.top
        return leading ? edge <= high - minSide : edge >= low + minSide
    }
}

extension CGRect {
    /// Edges rounded to whole pixels (not outward like `integral`, which would push a snapped edge off its line).
    var roundedToPixels: CGRect {
        let x0 = minX.rounded(), y0 = minY.rounded()
        return CGRect(x: x0, y: y0, width: maxX.rounded() - x0, height: maxY.rounded() - y0)
    }
}

/// Draggable crop box over an image. `crop` is in pixels of the full image with a top-left origin; what's drawn is
/// a smaller proxy of it.
///
/// Handles show resize cursors and grow under the pointer; the grabbed one turns white. While dragging, the thirds
/// grid fades in and edges snap to the image's edges, thirds and centre lines (in Free mode also to the original and
/// square ratios), with one trackpad tap as each snap catches and a guide line while it holds. ⌘ turns snapping off;
/// ⇧ on a corner keeps the ratio. Aspect, size and reset changes glide on a spring.
final class CropView: NSView {
    private(set) var image: CGImage?
    /// The full image, which `crop` is measured in.
    private(set) var pixelSize = CGSize(width: 1, height: 1)
    private(set) var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private(set) var ratio: CGFloat?
    var onChange: (() -> Void)?

    private let picture = PictureView()
    private let overlay = OverlayView()
    private lazy var driver: FrameDriver = {
        let driver = FrameDriver(view: self)
        driver.onFrame = { [weak self] dt in self?.advance(dt) ?? false }
        return driver
    }()

    // Motion: the drawn box (minX, minY, maxX, maxY), per-handle growth, the grabbed handle whitening, the grid and
    // the snap guides.
    private var shown = (0..<4).map { _ in Spring(0, response: 0.3, damping: 0.9) }
    private var growth = Dictionary(uniqueKeysWithValues: CropHandle.allCases.map { ($0, Spring(0, response: 0.2, damping: 0.7)) })
    private var press = Spring(0, response: 0.1, damping: 1)
    private var grid = Spring(0, response: 0.14, damping: 1)
    private var guideX = Spring(0, response: 0.1, damping: 1)
    private var guideY = Spring(0, response: 0.1, damping: 1)
    private var pill = Spring(0, response: 0.12, damping: 1)
    private var guideXAt: CGFloat = 0, guideYAt: CGFloat = 0
    private var pillText = ""

    private var hover: CropHandle?
    private var grabbed: CropHandle?
    private var drag: CropDrag?
    private var snap = CropDrag.Snap()
    private var startPoint = NSPoint.zero

    private static let tolerance: CGFloat = 12
    private static let snapPoints: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        overlay.topDown = true
        overlay.drawer = { [unowned self] in self.drawOverlay() }
        addSubview(picture)
        addSubview(overlay)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                              .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setImage(_ image: CGImage, pixelSize: CGSize) {
        self.image = image
        self.pixelSize = pixelSize
        picture.image = image
        setCrop(CGRect(origin: .zero, size: pixelSize), animated: false)
        needsLayout = true
    }

    private var imageRect: NSRect {
        image == nil ? .zero : fit(pixelSize, in: bounds.insetBy(dx: 14, dy: 14))
    }

    /// View points per image pixel.
    private var scale: CGFloat { max(imageRect.width / pixelSize.width, 0.0001) }

    private var shownCrop: CGRect {
        CGRect(x: shown[0].value, y: shown[1].value, width: shown[2].value - shown[0].value, height: shown[3].value - shown[1].value)
    }

    private func viewRect(_ r: CGRect) -> NSRect {
        let i = imageRect, s = scale
        return NSRect(x: i.minX + r.minX * s, y: i.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    override func layout() {
        super.layout()
        picture.frame = imageRect
        overlay.frame = bounds
    }

    // MARK: Changes from the controls

    func setRatio(_ ratio: CGFloat?) {
        self.ratio = ratio
        guard let ratio else { return }
        let W = pixelSize.width, H = pixelSize.height
        let size = W / H > ratio ? CGSize(width: H * ratio, height: H) : CGSize(width: W, height: W / ratio)
        setCrop(CGRect(x: (W - size.width) / 2, y: (H - size.height) / 2, width: size.width, height: size.height).roundedToPixels,
                animated: true)
    }

    func setSize(width: CGFloat, height: CGFloat) {
        let W = pixelSize.width, H = pixelSize.height
        let w = min(max(width, 16), W), h = min(max(height, 16), H)
        var r = CGRect(x: crop.midX - w / 2, y: crop.midY - h / 2, width: w, height: h)
        r.origin.x = min(max(0, r.minX), W - w)
        r.origin.y = min(max(0, r.minY), H - h)
        setCrop(r.roundedToPixels, animated: true)
    }

    func reset() {
        ratio = nil
        setCrop(CGRect(origin: .zero, size: pixelSize), animated: true)
    }

    /// `crop` takes the new value at once (fields and Apply read it); the drawing glides there unless told not to.
    private func setCrop(_ rect: CGRect, animated: Bool) {
        crop = rect
        let edges = [rect.minX, rect.minY, rect.maxX, rect.maxY]
        for i in 0..<4 {
            if animated { shown[i].target = edges[i] } else { shown[i].snap(edges[i]) }
        }
        kick()
    }

    // MARK: Motion

    private func kick() {
        if window == nil || Motion.reduced {
            // No movement: everything lands at once, but fades still read as fades on the next frames.
            for i in 0..<4 { shown[i].snap(shown[i].target) }
            for key in growth.keys { growth[key]?.snap(0) }
        }
        overlay.needsDisplay = true
        if window != nil { driver.start() }
    }

    private func advance(_ dt: CGFloat) -> Bool {
        for i in 0..<4 { shown[i].step(dt, tuning: Prefs.interaction.tools) }
        for key in growth.keys { growth[key]?.step(dt, tuning: Prefs.interaction.tools) }
        press.step(dt, tuning: Prefs.interaction.tools)
        grid.step(dt, tuning: Prefs.interaction.tools)
        guideX.step(dt, tuning: Prefs.interaction.tools)
        guideY.step(dt, tuning: Prefs.interaction.tools)
        pill.step(dt, tuning: Prefs.interaction.tools)
        overlay.needsDisplay = true
        return !(shown.allSatisfy(\.isSettled) && growth.values.allSatisfy(\.isSettled)
                 && [press, grid, guideX, guideY, pill].allSatisfy(\.isSettled))
    }

    private func setHover(_ handle: CropHandle?) {
        hover = handle
        retargetHandles()
    }

    private func retargetHandles() {
        let active = grabbed ?? hover
        for key in growth.keys {
            growth[key]?.target = (key == active && key != .move && !Motion.reduced) ? 1 : 0
        }
        press.target = grabbed == nil || grabbed == .move ? 0 : 1
        // Exits are a little quicker than entrances.
        grid.response = grabbed == nil ? 0.11 : 0.14
        grid.target = grabbed == nil ? 0 : 0.35
        kick()
    }

    // MARK: Pointer

    private func cursor(for handle: CropHandle?) -> NSCursor {
        switch handle {
        case nil: .arrow
        case .move: grabbed == .move ? .closedHand : .openHand
        case .topLeft: .frameResize(position: .topLeft, directions: .all)
        case .top: .frameResize(position: .top, directions: .all)
        case .topRight: .frameResize(position: .topRight, directions: .all)
        case .right: .frameResize(position: .right, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        case .bottom: .frameResize(position: .bottom, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .left: .frameResize(position: .left, directions: .all)
        }
    }

    private func handle(at event: NSEvent) -> CropHandle? {
        guard image != nil else { return nil }
        return CropHandle.hit(convert(event.locationInWindow, from: nil), box: viewRect(shownCrop), tolerance: Self.tolerance)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(for: grabbed ?? handle(at: event)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard grabbed == nil else { return }
        let handle = handle(at: event)
        if handle != hover { setHover(handle) }
        cursor(for: handle).set()
    }

    override func mouseExited(with event: NSEvent) {
        guard grabbed == nil else { return }
        setHover(nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let handle = handle(at: event) else { return }
        // Take over from a running glide where the box is drawn now, so the drag starts 1:1 under the pointer. With a
        // ratio locked, the in-between box is first fitted to it: no drag restores a ratio it didn't start with, and
        // the crop would be saved off-ratio with the ratio still selected.
        var current = shownCrop.roundedToPixels
        if current != crop {
            if let ratio { current = CropDrag.fitted(current, to: ratio, keeping: handle, in: pixelSize) }
            setCrop(current, animated: false)
            onChange?()
        }
        grabbed = handle
        startPoint = convert(event.locationInWindow, from: nil)
        snap = CropDrag.Snap()
        drag = CropDrag(start: crop, handle: handle, size: pixelSize, ratio: ratio,
                        freeRatios: [pixelSize.width / pixelSize.height, 1], enter: Self.snapPoints / scale)
        retargetHandles()
        cursor(for: handle).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if ratio == nil {
            drag.ratio = event.modifierFlags.contains(.shift) && drag.handle.isCorner ? drag.start.width / drag.start.height : nil
        }
        let result = drag.rect(dx: (p.x - startPoint.x) / scale, dy: (p.y - startPoint.y) / scale,
                               snapping: !event.modifierFlags.contains(.command), previous: snap)
        caught(result.snap)
        setCrop(result.rect, animated: false)
        onChange?()
    }

    override func mouseUp(with event: NSEvent) {
        guard grabbed != nil else { return }
        grabbed = nil
        drag = nil
        caught(CropDrag.Snap())
        hover = handle(at: event)
        retargetHandles()
        cursor(for: hover).set()
    }

    /// Taps once as each snap catches (not while it holds, never on letting go) and shows its guide while it holds.
    private func caught(_ new: CropDrag.Snap) {
        if (new.x != nil && new.x != snap.x) || (new.y != nil && new.y != snap.y) { Haptics.tick(.alignment) }
        snap = new
        let lines: [CGFloat] = [0, 1.0 / 3, 0.5, 2.0 / 3, 1]
        // Guides only for lines inside the image; at its edges the box itself shows the catch.
        if let x = new.x, x < 100, [1, 2, 3].contains(x % 10) {
            guideXAt = lines[x % 10] * pixelSize.width
            guideX.target = 1
        } else {
            guideX.target = 0
        }
        if let y = new.y, y < 100, [1, 2, 3].contains(y % 10) {
            guideYAt = lines[y % 10] * pixelSize.height
            guideY.target = 1
        } else {
            guideY.target = 0
        }
        if let id = [new.x, new.y].compactMap({ $0 }).first(where: { $0 >= 100 }) {
            pillText = id == 100 ? L("Original ratio") : "1:1"
            pill.target = 1
        } else {
            pill.target = 0
        }
        kick()
    }

    // MARK: Drawing

    private func drawOverlay() {
        guard image != nil else { return }
        let rect = imageRect
        let box = viewRect(shownCrop)
        let dim = NSBezierPath(rect: rect)
        dim.append(NSBezierPath(rect: box))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()

        // Rule-of-thirds guides, only while the box is held (as in Photos).
        if grid.value > 0.003 {
            NSColor.white.withAlphaComponent(min(grid.value, 0.35)).setStroke()
            for i in 1...2 {
                let x = box.minX + box.width * CGFloat(i) / 3, y = box.minY + box.height * CGFloat(i) / 3
                NSBezierPath.strokeLine(from: NSPoint(x: x, y: box.minY), to: NSPoint(x: x, y: box.maxY))
                NSBezierPath.strokeLine(from: NSPoint(x: box.minX, y: y), to: NSPoint(x: box.maxX, y: y))
            }
        }

        let accent = NSColor.controlAccentColor
        accent.setStroke()
        let border = NSBezierPath(rect: box)
        border.lineWidth = 2
        border.stroke()

        // Snap guides run across the whole image, over the border, so a caught edge visibly lights up. Yellow, as in
        // Keynote: it stands apart from the accent border and reads on most photos.
        if guideX.value > 0.003 {
            NSColor.systemYellow.withAlphaComponent(min(guideX.value, 1)).setFill()
            let x = (rect.minX + guideXAt * scale).rounded()
            NSRect(x: x - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
        }
        if guideY.value > 0.003 {
            NSColor.systemYellow.withAlphaComponent(min(guideY.value, 1)).setFill()
            let y = (rect.minY + guideYAt * scale).rounded()
            NSRect(x: rect.minX, y: y - 0.5, width: rect.width, height: 1).fill()
        }

        for handle in CropHandle.allCases where handle != .move {
            let grow = growth[handle]?.value ?? 0
            let center = NSPoint(x: handle.left ? box.minX : handle.right ? box.maxX : box.midX,
                                 y: handle.top ? box.minY : handle.bottom ? box.maxY : box.midY)
            let size: NSSize
            if handle.isCorner {
                let s = 10 + 4 * grow
                size = NSSize(width: s, height: s)
            } else {
                let long = 20 + 6 * grow, short = 5 + 2 * grow
                size = handle.top || handle.bottom ? NSSize(width: long, height: short) : NSSize(width: short, height: long)
            }
            let frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            let path = handle.isCorner ? NSBezierPath(rect: frame) : NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2)
            // The grabbed handle turns white with an accent ring: pressed, under the finger.
            let pressed = handle == grabbed ? press.value : 0
            accent.mix(.white, pressed).setFill()
            path.fill()
            if pressed > 0.01 {
                accent.withAlphaComponent(pressed).setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        }

        if pill.value > 0.01, !pillText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(pill.value)]
            let text = pillText as NSString
            let size = text.size(withAttributes: attrs)
            var frame = NSRect(x: box.midX - size.width / 2 - 8, y: box.minY + 10, width: size.width + 16, height: size.height + 6)
            frame.origin.y = min(frame.minY, box.maxY - frame.height - 6)
            accent.withAlphaComponent(0.9 * pill.value).setFill()
            NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
            text.draw(at: NSPoint(x: frame.minX + 8, y: frame.minY + 3), withAttributes: attrs)
        }
    }

    func stop() { driver.stop() }
}

/// Crops an image, or every page of a PDF by the same proportion.
final class CropEditor: Editor {
    private let view = CropView()
    private let ratios: [(String, CGFloat?)] = [("Free", nil), ("1:1", 1), ("16:9", 16 / 9), ("9:16", 9 / 16),
                                                 ("4:3", 4 / 3), ("3:4", 3 / 4)]
    private var aspect: NSSegmentedControl!
    private var widthField: NSTextField!
    private var heightField: NSTextField!
    private var lastAspect = 0
    private let isPDF: Bool
    /// Output units per image pixel (PDF crops are shown in points).
    private let unit: CGFloat
    /// The longest side of the image drawn on screen; the full image is decoded only to apply.
    private nonisolated static let proxyPixels = 2400

    init(source: URL) throws {
        isPDF = FileKind.of(source) == .pdf
        unit = isPDF ? 0.5 : 1
        super.init(title: "Crop Image", source: source, canvas: view)
        if isPDF { window.title = L("Crop PDF") }

        aspect = segments(ratios.map(\.0))
        addRow("Aspect ratio", aspect)
        widthField = numberField(0)
        heightField = numberField(0)
        for field in [widthField!, heightField!] { field.action = #selector(sizeEdited) }
        let units = NSTextField(labelWithString: isPDF ? "pt" : "px")
        units.textColor = .secondaryLabelColor
        let times = NSTextField(labelWithString: L("×"))
        addRow("Size", NSTextField(labelWithString: L("W")), widthField, times, NSTextField(labelWithString: L("H")),
               heightField, units)
        view.onChange = { [weak self] in self?.syncFields() }
    }

    override func load() async throws {
        let source = self.source, isPDF = self.isPDF
        let (image, size) = try await Images.detached { () throws -> (CGImage, CGSize) in
            if isPDF {
                guard let page = try PDFs.open(source).page(at: 0) else { throw ToolError("This PDF has no pages") }
                let image = try PDFs.render(page, dpi: 144)
                return (image, CGSize(width: image.width, height: image.height))
            }
            guard let size = CropEditor.uprightSize(source) else {
                let image = try Images.load(source)
                return (image, CGSize(width: image.width, height: image.height))
            }
            return (try Images.load(source, maxPixels: CropEditor.proxyPixels), size)
        }
        view.setImage(image, pixelSize: size)
    }

    /// The decoded size of the full image (EXIF rotation applied), read from the header without decoding.
    nonisolated static func uprightSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private func syncFields() {
        widthField.integerValue = Int((view.crop.width * unit).rounded())
        heightField.integerValue = Int((view.crop.height * unit).rounded())
    }

    override func update() {
        if aspect.selectedSegment != lastAspect {
            lastAspect = aspect.selectedSegment
            view.setRatio(ratios[lastAspect].1)
        }
        syncFields()
    }

    @objc private func sizeEdited(_ sender: Any?) {
        guard isLoaded else { return }
        view.setSize(width: CGFloat(widthField.integerValue) / unit, height: CGFloat(heightField.integerValue) / unit)
        syncFields()
    }

    override func reset() {
        view.reset()
        aspect.selectedSegment = 0
        lastAspect = 0
    }

    override func didClose() { view.stop() }

    override func apply() async throws -> [URL] {
        let crop = view.crop, size = view.pixelSize, source = self.source
        if isPDF {
            return try await Images.detached {
                let doc = try PDFs.open(source)
                // The preview showed the media box, rotated for display; map the crop back onto each page's media box.
                let unit = CGRect(x: crop.minX / size.width, y: crop.minY / size.height,
                                  width: crop.width / size.width, height: crop.height / size.height)
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    let box = CropEditor.pageRect(unit, rotation: page.rotation, in: page.bounds(for: .mediaBox))
                    page.setBounds(box, for: .cropBox)
                    page.setBounds(box, for: .mediaBox)
                }
                return [try PDFs.save(doc, as: Paths.preferred(for: source, ext: "pdf", suffix: " cropped"))]
            }
        }
        return try await Images.detached {
            let full = try Images.load(source)
            // The crop was measured against the header's size; scale in case the decoder returned another.
            let sx = CGFloat(full.width) / size.width, sy = CGFloat(full.height) / size.height
            let rect = CGRect(x: crop.minX * sx, y: crop.minY * sy, width: crop.width * sx, height: crop.height * sy)
                .roundedToPixels.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
            guard !rect.isEmpty, let cropped = full.cropping(to: rect) else { throw ToolError("Couldn't crop") }
            let (type, ext) = Images.writableType(for: source)
            return [try Images.save(cropped, as: Paths.preferred(for: source, ext: ext, suffix: " cropped"), type: type, quality: 0.95)]
        }
    }

    /// A crop given as a fraction of the page as displayed (top-left origin, after the page's clockwise `rotation`),
    /// in the page's own coordinates (bottom-left origin, unrotated).
    nonisolated static func pageRect(_ unit: CGRect, rotation: Int, in box: CGRect) -> CGRect {
        // (s, t): fractions across and down the unrotated page.
        let s0: CGFloat, s1: CGFloat, t0: CGFloat, t1: CGFloat
        switch ((rotation % 360) + 360) % 360 {
        case 90: (s0, s1, t0, t1) = (unit.minY, unit.maxY, 1 - unit.maxX, 1 - unit.minX)
        case 180: (s0, s1, t0, t1) = (1 - unit.maxX, 1 - unit.minX, 1 - unit.maxY, 1 - unit.minY)
        case 270: (s0, s1, t0, t1) = (1 - unit.maxY, 1 - unit.minY, unit.minX, unit.maxX)
        default: (s0, s1, t0, t1) = (unit.minX, unit.maxX, unit.minY, unit.maxY)
        }
        return CGRect(x: box.minX + s0 * box.width, y: box.maxY - t1 * box.height,
                      width: (s1 - s0) * box.width, height: (t1 - t0) * box.height)
    }
}

/// Re-encodes an image with a chosen quality, size cap and format, showing the resulting size and look live.
final class CompressEditor: Editor {
    private struct Settings: Equatable, Sendable {
        var quality: Double
        var maxPixels: Int
        var format: Int
        var targetBytes: Int
    }

    private struct Estimate: Sendable {
        var settings: Settings
        var data: Data
        var preview: CGImage?
        var error: String? = nil
    }

    private let preview = ImagePreview()
    private let originalBytes: Int
    private let sizes = [0, 3840, 2560, 1920, 1280, 800]
    private var formats: [(String, UTType, String)] = []
    /// Decoded source per size cap, so dragging the quality only re-encodes.
    let decoded = DecodedSources()
    private var latest: Estimate?
    private var quality: NSSlider!
    private var qualityLabel: NSTextField!
    private var maxSize: NSPopUpButton!
    private var format: NSPopUpButton!
    private var target: NSPopUpButton!
    private let estimate = NSTextField(labelWithString: L(""))
    private var calculating: DispatchWorkItem?
    private lazy var estimator = LiveRender<Estimate?> { [weak self] in self?.show($0) }
    /// An estimate is being worked out or waits its turn.
    var isEstimating: Bool { estimator.isBusy }

    init(source: URL) throws {
        originalBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        super.init(title: "Compress Image", source: source, canvas: preview)

        let (sourceType, sourceExt) = Images.writableType(for: source)
        let lossy: Set<UTType> = [.jpeg, .heic, .webP]
        if lossy.contains(sourceType) { formats.append((L("Same (%@)", sourceExt.uppercased()), sourceType, sourceExt)) }
        formats += [("JPG", .jpeg, "jpg"), ("HEIC", .heic, "heic"), ("PNG", .png, "png")]

        quality = slider(0.1, 1, 0.7)
        qualityLabel = NSTextField(labelWithString: L("70%"))
        qualityLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        qualityLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        addRow("Quality", quality, qualityLabel)
        maxSize = popup(sizes.map { $0 == 0 ? L("Original size") : L("Max %d px", $0) })
        addRow("Dimensions", maxSize)
        target = popup([L("Off"), L("100 KB"), L("200 KB"), L("500 KB"), L("1 MB"), L("2 MB"), L("5 MB")])
        target.selectItem(at: Prefs.compressTargets.firstIndex(of: Prefs.compressTargetBytes) ?? 0)
        addRow("Target size", target)
        format = popup(formats.map(\.0))
        addRow("Format", format)
        estimate.font = .systemFont(ofSize: 13, weight: .semibold)
        estimate.lineBreakMode = .byWordWrapping
        estimate.maximumNumberOfLines = 3
        estimate.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addRow("Result", estimate)
    }

    override func load() async throws {
        let source = self.source
        let image = try await Images.detached { try Images.load(source, maxPixels: 1400) }
        preview.image = image
        preview.original = image
    }

    private var settings: Settings {
        Settings(quality: quality.doubleValue, maxPixels: sizes[maxSize.indexOfSelectedItem], format: format.indexOfSelectedItem, targetBytes: Prefs.compressTargets[target.indexOfSelectedItem])
    }

    override func update() {
        let settings = self.settings, type = formats[settings.format].1, decoded = self.decoded, source = self.source
        qualityLabel.stringValue = settings.targetBytes == 0 ? "\(Int((quality.doubleValue * 100).rounded()))%" : L("Auto")
        quality.isEnabled = settings.targetBytes == 0
        if Prefs.compressTargetBytes != settings.targetBytes { Prefs.compressTargetBytes = settings.targetBytes }
        // Keep the last result visible, dimmed, while the new one is worked out; only a slow encode says so in words.
        estimate.textColor = .tertiaryLabelColor
        calculating?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.estimate.stringValue = L("Calculating…") }
        calculating = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        // The source is looked up when the job runs, not now: a request queued behind the first (full-size) decode
        // then reuses that decode instead of starting another.
        estimator.request {
            do {
                let image = try decoded.image(source, maxPixels: settings.maxPixels)
                let data = try settings.targetBytes == 0
                    ? Images.encode(image, type: type, quality: settings.quality)
                    : Images.fitting(image, type: type, maxBytes: settings.targetBytes).data
                return Estimate(settings: settings, data: data, preview: CompressEditor.decode(data, maxPixels: 1400))
            } catch {
                return Estimate(settings: settings, data: Data(), preview: nil, error: error.localizedDescription)
            }
        }
    }

    /// The encoded result decoded back at preview size, so the quality change shows in the picture.
    private nonisolated static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    private func show(_ result: Estimate?) {
        guard let result else { return }
        latest = result
        let current = result.settings == settings
        if current { calculating?.cancel() }
        if let error = result.error {
            estimate.stringValue = error
            estimate.textColor = current ? .systemRed : .tertiaryLabelColor
            return
        }
        let bytes = result.data.count
        let change = originalBytes > 0 ? Int((1 - Double(bytes) / Double(originalBytes)) * 100) : 0
        estimate.stringValue = "\(byteString(originalBytes)) → \(byteString(bytes))" + (change > 0 ? "  (−\(change)%)" : "  (+\(-change)%)")
        estimate.textColor = !current ? .tertiaryLabelColor : change > 0 ? .systemGreen : .systemRed
        if result.settings.targetBytes > 0 {
            estimate.stringValue = L("%@ — under target %@", byteString(bytes), byteString(result.settings.targetBytes))
            estimate.textColor = current ? .systemGreen : .tertiaryLabelColor
        }
        if let image = result.preview { preview.image = image }
    }

    override func reset() {
        quality.doubleValue = 0.7
        maxSize.selectItem(at: 0)
        format.selectItem(at: 0)
        target.selectItem(at: 0)
    }

    override func didClose() {
        estimator.cancel()
        calculating?.cancel()
    }

    override func apply() async throws -> [URL] {
        let settings = self.settings, (_, type, ext) = formats[settings.format], source = self.source
        // The estimate already encoded exactly this; write those bytes rather than encode again.
        let ready = latest?.settings == settings && latest?.error == nil ? latest?.data : nil
        let decoded = self.decoded
        return try await Images.detached {
            let data: Data
            if let ready { data = ready }
            else {
                let image = try decoded.image(source, maxPixels: settings.maxPixels)
                data = try settings.targetBytes == 0 ? Images.encode(image, type: type, quality: settings.quality)
                    : Images.fitting(image, type: type, maxBytes: settings.targetBytes).data
            }
            return [try Paths.create(data, at: Paths.preferred(for: source, ext: ext, suffix: " compressed"))]
        }
    }
}

/// Decoded copies of one source, per size cap (0 = full size), shared by Compress's estimates and its Apply.
/// Whoever needs a size first decodes it; anyone asking meanwhile waits for that decode rather than starting a second
/// one (a 48 MP original is about 200 MB and a fifth of a second).
final class DecodedSources: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [Int: CGImage] = [:]
    private var decodes = 0

    /// How many decodes have run (for tests).
    var decodeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return decodes
    }

    func image(_ source: URL, maxPixels: Int) throws -> CGImage {
        lock.lock()
        defer { lock.unlock() }
        if let image = images[maxPixels] { return image }
        let image = try Images.load(source, maxPixels: maxPixels == 0 ? nil : maxPixels)
        images[maxPixels] = image
        decodes += 1
        return image
    }
}
