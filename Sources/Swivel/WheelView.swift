import AppKit
import QuartzCore

/// One drop target in a menu layout.
struct Slot {
    var path: NSBezierPath          // hit area and fill
    var label: NSPoint              // label centre
    var angle: CGFloat = 0          // label rotation in degrees
    var maxWidth: CGFloat
    var fontSize: CGFloat = 12
    var labelScale: CGFloat = 1
    var alpha: CGFloat = 1
}

/// Motion constants for the pop-up menu, in one place so the feel can be tuned.
private enum Tune {
    // Hover: the item under the pointer springs out with a small overshoot and settles back calmly. Its colour
    // arrives in the first few frames; only the shape springs.
    static let popOut = (response: CGFloat(0.24), damping: CGFloat(0.7))
    static let popBack = (response: CGFloat(0.18), damping: CGFloat(0.95))
    static let popLift: CGFloat = 10        // wheel sector moves outwards (pt)
    static let popGrow: CGFloat = 4         // and its outer edge grows (pt)
    // Press on drop: sink fast and hold for a beat, then release with a bounce while the rest of the menu clears.
    static let pressIn = (response: CGFloat(0.09), damping: CGFloat(1))
    static let pressOut = (response: CGFloat(0.28), damping: CGFloat(0.6))
    static let pressHold: CGFloat = 0.06    // how long the pressed state is held before releasing
    static let pressSink: CGFloat = 5       // pressed sector sinks back towards the hub (pt)
    static let pressScale: CGFloat = 0.04   // and shrinks by this fraction
    static let exit = (response: CGFloat(0.2), damping: CGFloat(1))
    // Open: items bloom out from the hub one after another, clockwise from the top. No overshoot on a menu.
    static let bloom = (response: CGFloat(0.26), damping: CGFloat(0.86))
    static let bloomStagger: CGFloat = 0.01
    static let bloomRise: CGFloat = 14
    // Page turn: the ring turns by part of a segment and settles.
    static let turn = (response: CGFloat(0.27), damping: CGFloat(0.84))
    static let turnFraction: CGFloat = 0.5
}

/// The pop-up menu. Lays its items out in the chosen `MenuStyle`; every item is a drop target.
///
/// Live menus (`isLive`) animate on a display link: each item has its own spring for hovering, the dropped item
/// is pressed in, and opening blooms the items out from the centre. Previews in Settings draw the settled state.
final class WheelView: NSView {
    var onDrop: ((WheelItem, [URL]) -> Void)?
    var onClick: ((WheelItem) -> Void)?
    var onCancel: (() -> Void)?
    var onNextPage: (() -> Void)?
    var isClickable = false { didSet { setAccessibilityElement(isClickable); if isClickable { setAccessibilityRole(.group) }; updateTrackingAreas() } }
    private var clickTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { isClickable }
    override func accessibilityChildren() -> [Any]? {
        guard isClickable else { return super.accessibilityChildren() }
        let geometry = slots(settled: true)
        var children: [Any] = items.enumerated().map { index, item in
            let element = WheelAccessibilityButton()
            element.setAccessibilityElement(true); element.setAccessibilityRole(.button); element.setAccessibilityLabel(item.displayTitle); element.setAccessibilityParent(self)
            if geometry.indices.contains(index), let window { element.setAccessibilityFrame(window.convertToScreen(convert(geometry[index].path.bounds, to: nil))) }
            element.press = { [weak self] in
                guard let self, self.isClickable, self.items.indices.contains(index) else { return }
                self.hovered = index; self.beginConfirm(index); Feedback.press(); self.onClick?(self.items[index])
            }
            return element
        }
        let cancel = WheelAccessibilityButton(); cancel.setAccessibilityElement(true); cancel.setAccessibilityRole(.button); cancel.setAccessibilityLabel(L("Cancel")); cancel.setAccessibilityParent(self)
        cancel.press = { [weak self] in self?.onCancel?() }; children.append(cancel)
        if pageCount > 1 {
            let next = WheelAccessibilityButton(); next.setAccessibilityElement(true); next.setAccessibilityRole(.button); next.setAccessibilityLabel(L("Next Page")); next.setAccessibilityParent(self)
            next.press = { [weak self] in self?.onNextPage?() }; children.append(next)
        }
        return children
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let clickTracking { removeTrackingArea(clickTracking); self.clickTracking = nil }
        if isClickable {
            let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self)
            addTrackingArea(area); clickTracking = area
        }
    }
    override func mouseMoved(with event: NSEvent) { if isClickable { track(convert(event.locationInWindow, from: nil)) } }
    override func mouseExited(with event: NSEvent) { if isClickable { pointerLeft() } }
    override func mouseDown(with event: NSEvent) {
        guard isClickable else { return }
        _ = track(convert(event.locationInWindow, from: nil))
        guard let index = hovered, items.indices.contains(index) else { onCancel?(); return }
        beginConfirm(index); Feedback.press(); onClick?(items[index])
    }
    override func keyDown(with event: NSEvent) {
        guard isClickable else { return }
        if event.keyCode == 53 { onCancel?(); return }
        if event.keyCode == 49 { onNextPage?(); return }
        if [123, 124, 125, 126].contains(event.keyCode), !items.isEmpty {
            let backwards = event.keyCode == 123 || event.keyCode == 126
            hovered = ((hovered ?? (backwards ? 0 : -1)) + (backwards ? -1 : 1) + items.count) % items.count
            return
        }
        if event.keyCode == 36, let index = hovered, items.indices.contains(index) {
            beginConfirm(index); Feedback.press(); onClick?(items[index])
        }
    }
    var onDragEndedWithoutDrop: (() -> Void)?
    var subtitle = ""
    var style: MenuStyle = .wheel { didSet { needsDisplay = true } }
    /// Animate and give haptic feedback. Off for the static previews in Settings.
    var isLive = false
    /// Tests drive the animation with `advance(_:)` instead of a display link.
    var manualClock = false
    var hovered: Int? {
        didSet { if hovered != oldValue { hoverChanged(from: oldValue) } }
    }

    private(set) var items: [WheelItem] = []
    private var mode: WheelMode = .convert
    private var page = 0
    private var pageCount = 1

    let outerRadius: CGFloat = 122
    private let innerRadius: CGFloat = 52
    private let rimWidth: CGFloat = 9
    private let gap: CGFloat = 7

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    // MARK: Motion state

    private lazy var driver: FrameDriver = {
        let driver = FrameDriver(view: self)
        driver.onFrame = { [weak self] dt in self?.advance(dt) ?? false }
        return driver
    }()
    private var pops: [Spring] = []                 // per item: 0 at rest, 1 hovered
    private var blooms: [Spring] = []               // per item: 0 hidden, 1 shown
    private var bloomClock: CGFloat = .infinity     // seconds since opening, while items are still being released
    private var press = Spring(0, response: Tune.pressIn.response, damping: Tune.pressIn.damping)
    private var pressClock: CGFloat = .infinity
    private(set) var pressed: Int?
    private var exit = Spring(0, response: Tune.exit.response, damping: Tune.exit.damping)
    private var turn = Spring(0, response: Tune.turn.response, damping: Tune.turn.damping)
    private var reveal = Spring(1, response: 0.2, damping: 1)              // labels fading in after a page turn
    private var dial = Spring(90, response: 0.2, damping: 0.8)             // hub indicator angle, degrees
    private var dialAlpha = Spring(0, response: 0.14, damping: 1)
    private var swap = Spring(1, response: 0.2, damping: 1)                // hub/header headline crossfade
    private var previousHeadline = ""
    private var row = Spring(0, response: 0.15, damping: 0.9)              // list: highlight position in rows
    private var rowAlpha = Spring(0, response: 0.12, damping: 1)
    private var hubPress = Spring(0, response: 0.16, damping: 1)           // the hub sinks while it means "cancel"
    /// An item has been hovered since the menu opened, so coming back to the hub (or an empty spot) means cancel.
    private var visited = false
    private var pointerInside = false
    private var openPoint: NSPoint?
    /// Where the pointer is (view coordinates), for the light that follows it across a raised sector.
    private var pointer: NSPoint?
    /// A Force Click during the drag (spring-loading activation): the hovered item is pushed partway in.
    private var deepPressed = false
    private weak var dragInfo: NSDraggingInfo?
    /// Widest header the current page can show, so the header doesn't shift sideways as items are hovered.
    private var headerTitleWidth: CGFloat = 0
    private var prefsObserver: NSObjectProtocol?
    /// Releasing now would cancel: the pointer came back to the hub after visiting an item.
    private(set) var cancelArmed = false {
        didSet {
            guard cancelArmed != oldValue else { return }
            previousHeadline = oldValue ? L("Cancel") : headline(for: hovered)
            swap.snap(0)
            swap.target = 1
            hubPress.target = cancelArmed ? 1 : 0
            if cancelArmed, isLive { Feedback.hover(sound: false) }
            kick()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
        prefsObserver = NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    deinit { if let prefsObserver { NotificationCenter.default.removeObserver(prefsObserver) } }

    required init?(coder: NSCoder) { fatalError() }

    func configure(items: [WheelItem], mode: WheelMode, page: Int, pageCount: Int) {
        let turning = isLive && (manualClock || window?.isVisible == true) && mode == self.mode && page != self.page
            && !items.isEmpty && pressed == nil
        hovered = nil
        self.items = items
        self.mode = mode
        self.page = page
        self.pageCount = pageCount
        pops = items.map { _ in Spring(0, response: Tune.popBack.response, damping: Tune.popBack.damping) }
        // Tags on the rope swing in as they appear (gently: still well damped); everything else settles without overshoot.
        let bloom = style == .clothesline ? (response: CGFloat(0.42), damping: CGFloat(0.62)) : Tune.bloom
        blooms = items.map { _ in Spring(1, response: bloom.response, damping: bloom.damping) }
        headerTitleWidth = ([mode.title, L("Cancel")] + items.map { "\(mode.title): \($0.displayTitle)" })
            .map { ($0 as NSString).size(withAttributes: [.font: AppTypography.font(ofSize: 13, weight: .bold)]).width }
            .max() ?? 0
        bloomClock = .infinity
        swap.snap(1)
        rowAlpha.snap(0)
        dialAlpha.snap(0)
        if !turning { visited = false }
        cancelArmed = false
        hubPress.snap(0)
        if turning {
            if !Motion.reduced {
                turn.snap(step * Tune.turnFraction)
                turn.target = 0
            }
            reveal.snap(0)
            reveal.target = 1
            Feedback.page()
            kick()
        }
        needsDisplay = true
    }

    /// Starts the opening animation; called as the panel appears. `pointer` is where the drag is (view coordinates):
    /// items only react once the pointer has moved a little, so a menu that had to shift to fit on screen can't
    /// select whatever happened to land under a still pointer.
    func beginOpen(pointer: NSPoint? = nil) {
        openPoint = pointer
        pressed = nil
        pressClock = .infinity
        press.snap(0)
        exit.snap(0)
        turn.snap(0)
        reveal.snap(1)
        swap.snap(1)
        dialAlpha.snap(0)
        rowAlpha.snap(0)
        visited = false
        pointerInside = false
        cancelArmed = false
        deepPressed = false
        self.pointer = nil
        hubPress.snap(0)
        if Motion.reduced {
            for i in blooms.indices { blooms[i].snap(1) }
            bloomClock = .infinity
        } else {
            for i in blooms.indices { blooms[i].snap(0) }
            bloomClock = 0
        }
        kick()
    }

    /// Presses the dropped item in, then releases it while the rest of the menu clears away.
    func beginConfirm(_ index: Int) {
        guard items.indices.contains(index) else { return }
        pressedTint = pressedColour()
        deepPressed = false
        pressed = index
        if hovered != index { hovered = index }
        press.response = Tune.pressIn.response
        press.damping = Tune.pressIn.damping
        press.target = 1
        pressClock = 0
        kick()
    }

    /// Jumps every animation to its end state (used by previews and tests).
    func settle() {
        bloomClock = .infinity
        for i in pops.indices { pops[i].snap(pops[i].target) }
        for i in blooms.indices { blooms[i].snap(1) }
        for spring in [\WheelView.press, \.exit, \.turn, \.reveal, \.dial, \.dialAlpha, \.swap, \.row, \.rowAlpha, \.hubPress] as [ReferenceWritableKeyPath<WheelView, Spring>] {
            self[keyPath: spring].snap(self[keyPath: spring].target)
        }
        needsDisplay = true
    }

    /// Advances every spring by `dt` seconds. Returns true while anything is still moving.
    @discardableResult
    func advance(_ dt: CGFloat) -> Bool {
        if bloomClock.isFinite {
            bloomClock += dt * Prefs.interaction.menu.safeSpeed
            for i in blooms.indices where bloomClock >= CGFloat(i) * Tune.bloomStagger { blooms[i].target = 1 }
            if bloomClock >= CGFloat(blooms.count) * Tune.bloomStagger { bloomClock = .infinity }
        }
        if pressClock.isFinite {
            pressClock += dt * Prefs.interaction.menu.safeSpeed
            if pressClock >= Tune.pressHold, press.target == 1 {
                press.response = Tune.pressOut.response
                press.damping = Tune.pressOut.damping
                press.target = 0
                exit.target = 1
                pressClock = .infinity
            }
        }
        for i in pops.indices { pops[i].step(dt, tuning: Prefs.interaction.menu) }
        for i in blooms.indices { blooms[i].step(dt, tuning: Prefs.interaction.menu) }
        press.step(dt, tuning: Prefs.interaction.menu)
        exit.step(dt, tuning: Prefs.interaction.menu)
        turn.step(dt, tuning: Prefs.interaction.menu)
        reveal.step(dt, tuning: Prefs.interaction.menu)
        dial.step(dt, tuning: Prefs.interaction.menu)
        dialAlpha.step(dt, tuning: Prefs.interaction.menu)
        swap.step(dt, tuning: Prefs.interaction.menu)
        row.step(dt, tuning: Prefs.interaction.menu)
        rowAlpha.step(dt, tuning: Prefs.interaction.menu)
        hubPress.step(dt, tuning: Prefs.interaction.menu)
        needsDisplay = true
        return !isSettled
    }

    private var isSettled: Bool {
        !bloomClock.isFinite && !pressClock.isFinite && pops.allSatisfy(\.isSettled) && blooms.allSatisfy(\.isSettled)
            && press.isSettled && exit.isSettled && turn.isSettled && reveal.isSettled && dial.isSettled
            && dialAlpha.isSettled && swap.isSettled && row.isSettled && rowAlpha.isSettled && hubPress.isSettled
    }

    /// Runs the display link for live menus; previews jump straight to the end state.
    private func kick() {
        if manualClock { return }
        if isLive, window != nil {
            driver.start()
        } else {
            settle()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Off screen, or moved into a fresh panel: a display link belongs to the window it was made for.
        driver.stop()
    }

    private func hoverChanged(from old: Int?) {
        if deepPressed, pressed == nil { setDeepPress(false) }
        dragInfo?.resetSpringLoading()
        if let old, pops.indices.contains(old) {
            pops[old].response = Tune.popBack.response
            pops[old].damping = Tune.popBack.damping
            pops[old].target = 0
        }
        if let new = hovered, pops.indices.contains(new) {
            // Tags on the rope straighten gently (the owner's rule for anything on the clothesline).
            let out = style == .clothesline ? (response: CGFloat(0.42), damping: CGFloat(0.8)) : Tune.popOut
            pops[new].response = Motion.reduced ? 0.14 : out.response
            pops[new].damping = Motion.reduced ? 1 : out.damping
            pops[new].target = 1
            let angle = unwrap(centreAngle(new), near: dial.value)
            if dialAlpha.value < 0.05 || Motion.reduced { dial.snap(angle) } else { dial.target = angle }
            if rowAlpha.value < 0.05 || Motion.reduced { row.snap(CGFloat(new)) } else { row.target = CGFloat(new) }
        }
        if hovered != nil { visited = true }
        dialAlpha.target = hovered == nil ? 0 : 1
        rowAlpha.target = hovered == nil ? 0 : 1
        previousHeadline = headline(for: old)
        swap.snap(0)
        swap.target = 1
        if isLive, hovered != nil, pressed == nil { Feedback.hover() }
        kick()
    }

    /// The angle equivalent to `angle` (mod 360) closest to `reference`, so the dial turns the short way.
    private func unwrap(_ angle: CGFloat, near reference: CGFloat) -> CGFloat {
        var a = angle
        while a - reference > 180 { a -= 360 }
        while a - reference < -180 { a += 360 }
        return a
    }

    private func popValue(_ i: Int) -> CGFloat { pops.indices.contains(i) ? pops[i].value : 0 }
    /// Colour follows the pop but arrives in the first few frames, so the highlight never lags the pointer.
    private func tintValue(_ i: Int) -> CGFloat { min(max(popValue(i) * 2.2, 0), 1) }
    private func bloomValue(_ i: Int) -> CGFloat { blooms.indices.contains(i) ? blooms[i].value : 1 }
    private func pressValue(_ i: Int) -> CGFloat { i == (pressed ?? (deepPressed ? hovered : nil)) ? press.value : 0 }

    /// While a dropped item is confirmed, the others clear away (0 → 1).
    private func exitValue(_ i: Int) -> CGFloat { pressed != nil && i != pressed ? exit.value : 0 }

    // MARK: Sizes per style

    static let headerHeight: CGFloat = 34
    static let listRow: CGFloat = 32

    static func bookWidth(_ i: Int) -> CGFloat { [40, 34, 44, 37, 42, 35, 39, 43][i % 8] }
    static func bookHeight(_ i: Int) -> CGFloat { [150, 132, 158, 140, 128, 154, 136, 146][i % 8] }

    /// Natural view size for a style and item count. The live wheel is larger than it looks: the clear margin
    /// keeps catching the drag when a flick overshoots the ring, so the chosen sector stays chosen.
    static func size(for style: MenuStyle, count: Int, live: Bool = false) -> NSSize {
        let n = max(count, 1)
        switch style {
        case .wheel:
            return live ? NSSize(width: 400, height: 400) : NSSize(width: 320, height: 320)
        case .list:
            return NSSize(width: 240, height: headerHeight + CGFloat(n) * listRow + 14)
        case .shelf:
            let books = (0..<n).reduce(CGFloat(0)) { $0 + bookWidth($1) + 5 }
            return NSSize(width: max(books + 56, 220), height: 168 + headerHeight + 24)
        case .notes:
            let cols = min(n, 4), rows = Int(ceil(Double(n) / 4))
            return NSSize(width: max(CGFloat(cols) * 108 + 28, 220), height: CGFloat(rows) * 108 + headerHeight + 28)
        case .clothesline:
            return NSSize(width: max(CGFloat(n) * 82 + 64, 240), height: 178 + headerHeight)
        }
    }

    /// The frosted backdrop behind the menu, if the style uses one (rect, corner radius).
    var backdrop: (NSRect, CGFloat)? {
        switch style {
        case .wheel:
            return (NSRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2), outerRadius)
        case .list:
            return (bounds.insetBy(dx: 4, dy: 4), 14)
        default:
            return nil
        }
    }

    // MARK: Layout

    private var step: CGFloat { 360 / CGFloat(max(items.count, 1)) }

    /// Wheel segment i is centred at the top and proceeds clockwise.
    private func centreAngle(_ i: Int) -> CGFloat { 90 - CGFloat(i) * step }

    /// Area below the header that the items occupy.
    private var body: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - Self.headerHeight)
    }

    /// Item geometry. `settled` lays items out as hit targets: the hovered item fully out, no transient motion.
    private func slots(settled: Bool = false) -> [Slot] {
        let target = hovered
        let pop: (Int) -> CGFloat = settled ? { i in i == target ? 1 : 0 } : popValue
        switch style {
        case .wheel: return wheelSlots(pop: pop, settled: settled)
        case .list: return listSlots()
        case .shelf: return shelfSlots(pop: pop, settled: settled)
        case .notes: return noteSlots(pop: pop, settled: settled)
        case .clothesline: return clothesSlots(pop: pop, settled: settled)
        }
    }

    private func wheelSlots(pop: (Int) -> CGFloat, settled: Bool) -> [Slot] {
        let half = step / 2
        let baseOuter = outerRadius - rimWidth, inner = innerRadius + 6
        let mid = (baseOuter + inner) / 2
        let rotation = settled ? 0 : turn.value
        return items.indices.map { i in
            let p = pop(i)
            let pressed = settled ? 0 : pressValue(i)
            let bloom = settled ? 1 : bloomValue(i)
            let away = settled ? 0 : exitValue(i)
            // Under Reduce Motion nothing moves; the pop shows as colour only.
            let move: CGFloat = Motion.reduced ? 0 : 1
            let outer = baseOuter + Tune.popGrow * max(p, 0) * move
            // The gap to the neighbours narrows as a sector comes out, so it reads as one raised keycap.
            let closing = 1 - 0.45 * min(max(p, 0), 1) * move
            let padOut = (gap / 2) * closing / outer * 180 / .pi
            let padIn = (gap / 2) * closing / inner * 180 / .pi
            let centre = centreAngle(i) + rotation
            let rad = centre * .pi / 180
            let dir = CGVector(dx: cos(rad), dy: sin(rad))
            let lift = move * (Tune.popLift * p - Tune.pressSink * pressed - Tune.bloomRise * (1 - bloom) - 12 * away)

            let path = NSBezierPath()
            if items.count == 1 {
                path.appendOval(in: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
                path.appendOval(in: NSRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
                path.windingRule = .evenOdd
            } else {
                path.appendArc(withCenter: center, radius: outer, startAngle: centre - half + padOut, endAngle: centre + half - padOut, clockwise: false)
                path.appendArc(withCenter: center, radius: inner, startAngle: centre + half - padIn, endAngle: centre - half + padIn, clockwise: true)
                path.close()
            }
            // Scale about the sector's own centre, then move it out along its direction.
            let rest = NSPoint(x: center.x + dir.dx * mid, y: center.y + dir.dy * mid)
            let labelCentre = NSPoint(x: rest.x + dir.dx * lift, y: rest.y + dir.dy * lift)
            let scale = Motion.reduced ? 1 : (1 - Tune.pressScale * pressed) * (0.9 + 0.1 * bloom) * (1 - 0.08 * away)
            var t = AffineTransform(translationByX: labelCentre.x, byY: labelCentre.y)
            t.scale(scale)
            t.translate(x: -rest.x, y: -rest.y)
            if items.count > 1 { path.transform(using: t) }
            return Slot(path: path, label: items.count == 1 ? NSPoint(x: center.x, y: center.y + mid) : labelCentre,
                        maxWidth: mid * sin(.pi / CGFloat(max(items.count, 2))) * 1.7,
                        fontSize: items.count > 6 ? 11 : 12, labelScale: scale * (1 + 0.07 * max(p, 0) * move),
                        alpha: min(max(bloom, 0), 1) * (1 - away))
        }
    }

    private func listRect(_ row: CGFloat) -> NSRect {
        let top = bounds.height - Self.headerHeight
        return NSRect(x: 10, y: top - (row + 1) * Self.listRow, width: bounds.width - 20, height: Self.listRow - 4)
    }

    private func listSlots() -> [Slot] {
        items.indices.map { i in
            let rect = listRect(CGFloat(i))
            return Slot(path: NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7),
                        label: NSPoint(x: rect.minX + 14, y: rect.midY), maxWidth: rect.width - 28, fontSize: 13)
        }
    }

    private var shelfTop: CGFloat { 30 }  // top surface of the plank

    private func shelfSlots(pop: (Int) -> CGFloat, settled: Bool) -> [Slot] {
        let total = items.indices.reduce(CGFloat(0)) { $0 + Self.bookWidth($1) + 5 } - 5
        var x = (bounds.width - total) / 2
        return items.indices.map { i in
            let w = Self.bookWidth(i), h = Self.bookHeight(i)
            let bloom = settled ? 1 : bloomValue(i)
            // Neighbours of the hovered book rise a little too, so it reads as one physical row (Dock-style).
            let near = settled ? 0 : max(i > 0 ? pop(i - 1) : 0, i + 1 < items.count ? pop(i + 1) : 0)
            let lift = Motion.reduced ? 0 : 12 * pop(i) + 3 * max(near, 0) - (settled ? 0 : 4 * pressValue(i)) - 26 * (1 - bloom)
            let rect = NSRect(x: x, y: shelfTop + lift, width: w, height: h)
            x += w + 5
            return Slot(path: NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3),
                        label: NSPoint(x: rect.midX, y: rect.midY + 6), angle: 90, maxWidth: h - 34, fontSize: 12,
                        alpha: min(max(bloom * 1.6, 0), 1) * (1 - (settled ? 0 : exitValue(i))))
        }
    }

    private func noteSlots(pop: (Int) -> CGFloat, settled: Bool) -> [Slot] {
        let cols = min(max(items.count, 1), 4)
        let side: CGFloat = 94, pitch: CGFloat = 108
        let gridWidth = CGFloat(cols) * pitch
        let originX = (bounds.width - gridWidth) / 2 + (pitch - side) / 2
        let top = body.maxY - 10
        return items.indices.map { i in
            let row = i / cols, col = i % cols
            let rect = NSRect(x: originX + CGFloat(col) * pitch, y: top - CGFloat(row + 1) * pitch + (pitch - side) / 2,
                              width: side, height: side)
            let p = pop(i), bloom = settled ? 1 : bloomValue(i)
            let rest: CGFloat = [-3, 2.5, -1.5, 3, -2.5, 1.5, -3.5, 2][i % 8]
            let tilt = Motion.reduced ? rest : rest * (1 - p) + 6 * (1 - bloom)
            let scale = Motion.reduced ? 1 : (1 + 0.08 * p - (settled ? 0 : 0.06 * pressValue(i))) * (0.82 + 0.18 * bloom)
            var t = AffineTransform(translationByX: rect.midX, byY: rect.midY)
            t.rotate(byDegrees: tilt)
            t.scale(scale)
            t.translate(x: -rect.midX, y: -rect.midY)
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            path.transform(using: t)
            return Slot(path: path, label: t.transform(NSPoint(x: rect.midX, y: rect.midY - 4)), angle: tilt,
                        maxWidth: side - 16, fontSize: 15, labelScale: scale,
                        alpha: min(max(bloom * 1.4, 0), 1) * (1 - (settled ? 0 : exitValue(i))))
        }
    }

    /// Rope height at x: a gentle sag between the two posts.
    private func ropeY(_ x: CGFloat) -> CGFloat {
        let left: CGFloat = 22, right = bounds.width - 22
        let t = (x - left) / (right - left)
        return body.maxY - 18 - 16 * 4 * t * (1 - t)
    }

    private func clothesSlots(pop: (Int) -> CGFloat, settled: Bool) -> [Slot] {
        let pitch: CGFloat = 82
        let start = (bounds.width - CGFloat(items.count) * pitch) / 2 + pitch / 2
        return items.indices.map { i in
            let x = start + CGFloat(i) * pitch
            let hang = ropeY(x)
            let w: CGFloat = 66, h: CGFloat = 92
            let p = pop(i), bloom = settled ? 1 : bloomValue(i)
            let rest: CGFloat = [4, -3, 2.5, -4, 3, -2, 3.5, -3][i % 8]
            // Tags swing in from the rope as they appear and straighten when hovered.
            let tilt = Motion.reduced ? rest : rest * (1 - p) + 14 * (1 - bloom)
            let near = settled ? 0 : max(i > 0 ? pop(i - 1) : 0, i + 1 < items.count ? pop(i + 1) : 0)
            let lift = Motion.reduced ? 0 : 4 * p + 1.5 * max(near, 0) - (settled ? 0 : 5 * pressValue(i))
            let rect = NSRect(x: x - w / 2, y: hang - 6 - h + lift, width: w, height: h)
            var t = AffineTransform(translationByX: x, byY: hang)
            t.rotate(byDegrees: tilt)
            t.translate(x: -x, y: -hang)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.transform(using: t)
            let labelPoint = t.transform(NSPoint(x: rect.midX, y: rect.midY - 8))
            return Slot(path: path, label: labelPoint, angle: tilt, maxWidth: w - 10, fontSize: 12,
                        alpha: min(max(bloom * 1.5, 0), 1) * (1 - (settled ? 0 : exitValue(i))))
        }
    }

    /// How far (degrees) the pointer may stray past a hovered sector's edge before the next one takes over: about
    /// 10 pt of arc, so it's the same distance for the hand whether the pointer is near the hub or the rim.
    private func hysteresis(at radius: CGFloat) -> CGFloat { min(max(10 / max(radius, 1) * 180 / .pi, 4), 9) }

    private func slot(at point: NSPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        if style == .wheel {
            let dx = point.x - center.x, dy = point.y - center.y
            let distance = hypot(dx, dy)
            // The hub is the cancel zone; once a sector is chosen it takes a little more to fall back into it.
            guard distance > (hovered == nil ? innerRadius + 2 : innerRadius - 6) else { return nil }
            // A flick that overshoots the ring keeps its sector, but a deliberate move well away from it is empty
            // space again: releasing there cancels.
            guard distance < (hovered == nil ? outerRadius + 40 : outerRadius + 52) else { return nil }
            let angle = atan2(dy, dx) * 180 / .pi
            if let hovered, items.indices.contains(hovered), items.count > 1 {
                var off = (angle - centreAngle(hovered)).truncatingRemainder(dividingBy: 360)
                if off > 180 { off -= 360 }
                if off < -180 { off += 360 }
                if abs(off) <= step / 2 + hysteresis(at: distance) { return hovered }
            }
            var offset = (90 - angle + step / 2).truncatingRemainder(dividingBy: 360)
            if offset < 0 { offset += 360 }
            return min(Int(offset / step), items.count - 1)
        }
        // Other templates: whole bands and cells, gaps included, so moving between items never blinks off and a
        // lifted or straightened item can't move out from under the pointer.
        let n = items.count
        switch style {
        case .list:
            let top = bounds.height - Self.headerHeight - 4
            guard point.y < top, point.x > 4, point.x < bounds.width - 4 else { return nil }
            let i = Int((top - point.y) / Self.listRow)
            return i < n ? i : nil
        case .shelf:
            let total = items.indices.reduce(CGFloat(0)) { $0 + Self.bookWidth($1) + 5 } - 5
            var x = (bounds.width - total) / 2
            guard point.y > shelfTop - 16, point.y < shelfTop + 172 else { return nil }
            for i in items.indices {
                let w = Self.bookWidth(i)
                if point.x >= x - 2.5, point.x < x + w + 2.5 { return i }
                x += w + 5
            }
            return nil
        case .notes:
            let cols = min(max(n, 1), 4), pitch: CGFloat = 108
            let originX = (bounds.width - CGFloat(cols) * pitch) / 2
            let top = body.maxY - 10
            guard point.x >= originX, point.y <= top else { return nil }
            let col = Int((point.x - originX) / pitch), row = Int((top - point.y) / pitch)
            let i = row * cols + col
            return col < cols && i < n ? i : nil
        case .clothesline:
            let pitch: CGFloat = 82
            let start = (bounds.width - CGFloat(n) * pitch) / 2
            guard point.x >= start, point.y < body.maxY - 4, point.y > 4 else { return nil }
            let i = Int((point.x - start) / pitch)
            return i < n ? i : nil
        case .wheel:
            return nil
        }
    }

    /// Re-checks what is under the pointer without waiting for the next drag update (after a page turn).
    func rehover(atScreen point: NSPoint) {
        guard let window, pointerInside else { return }
        hovered = slot(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }

    // MARK: Drawing

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    private var accent: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.92) }
    /// The accent a quarter darker, for an item being pressed (resolved once per drop; system colours are slow to convert).
    private lazy var pressedTint: NSColor = pressedColour()
    private func pressedColour() -> NSColor {
        NSColor.controlAccentColor.usingColorSpace(.sRGB)?.shadow(withLevel: 0.25) ?? .controlAccentColor
    }
    private var ink: NSColor { isDark ? .white : NSColor(white: 0.13, alpha: 1) }

    override func draw(_ dirtyRect: NSRect) {
        labelGlow = isDark ? NSColor.black.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.8)
        switch style {
        case .wheel: drawWheel()
        case .list: drawList()
        case .shelf: drawShelf()
        case .notes: drawNotes()
        case .clothesline: drawClothesline()
        }
    }

    private func headline(for index: Int?) -> String {
        if cancelArmed { return L("Cancel") }
        if let index, items.indices.contains(index) {
            return style == .wheel ? items[index].displayTitle : "\(mode.title): \(items[index].displayTitle)"
        }
        return mode.title
    }

    /// A flash on the confirmed item as it is released (0 → 1 → 0).
    private var flash: CGFloat { pressed == nil ? 0 : sin(.pi * min(max(exit.value, 0), 1)) }

    private func drawWheel() {
        // Frosted keycaps on clear glass: the desktop shows through, labels stay legible.
        let dark = isDark
        let cap = dark ? NSColor(white: 0, alpha: 0.30) : NSColor(white: 1, alpha: 0.38)
        let hubFill = dark ? NSColor(white: 0, alpha: 0.38) : NSColor(white: 1, alpha: 0.6)
        let line = dark ? NSColor(white: 1, alpha: 0.28) : NSColor(white: 1, alpha: 0.9)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency, let (rect, _) = backdrop {
            // No glass under Reduce Transparency: a solid disc keeps the labels readable on any desktop.
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        let all = slots()

        // Raised sectors are drawn last so their shadow falls on their neighbours.
        for i in all.indices.sorted(by: { popValue($0) < popValue($1) }) {
            let slot = all[i]
            guard slot.alpha > 0.01 else { continue }
            let p = min(max(popValue(i), 0), 1), sink = pressValue(i)
            let tint = tintValue(i)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(slot.alpha)
            var fill = cap.mix(accent, tint)
            if sink > 0 { fill = fill.mix(pressedTint, sink * 0.6) }
            if i == pressed, flash > 0 { fill = fill.mix(.white, 0.3 * flash) }
            withShadow(blur: 3 + 9 * p * (1 - sink), alpha: (dark ? 0.4 : 0.12) + 0.18 * p * (1 - sink),
                       offset: 1 + 3 * p * (1 - sink)) {
                fill.setFill()
                slot.path.fill()
            }
            if p > 0.01 {
                // A soft sheen across the raised keycap, and a light under the pointer that follows it.
                NSGraphicsContext.saveGraphicsState()
                slot.path.addClip()
                NSGradient(colors: [NSColor.white.withAlphaComponent(0.28 * p * (1 - sink)), .clear])!
                    .draw(in: slot.path.bounds, angle: -90)
                if let pointer, i == hovered, !Motion.reduced {
                    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22 * p * (1 - sink)), .clear])!
                        .draw(fromCenter: pointer, radius: 0, toCenter: pointer, radius: 70, options: [])
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            line.mix(NSColor.white.withAlphaComponent(0.9), tint).setStroke()
            slot.path.lineWidth = 1
            slot.path.stroke()
            let labelAlpha = i == hovered || sink > 0 ? 1 : reveal.value
            drawLabel(items[i].displayTitle, slot, color: ink.mix(.white, tint).withAlphaComponent(labelAlpha),
                      glow: tint < 0.5)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Hub: shrinks in on open, fades as a confirmed menu clears.
        let hubBloom = blooms.isEmpty ? 1 : min(max(bloomValue(0) * 1.2, 0), 1)
        let sunk = hubPress.value
        let still: CGFloat = Motion.reduced ? 0 : 1
        let hubRadius = innerRadius * (0.86 + 0.14 * hubBloom) * (1 - 0.04 * sunk * still)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(min(max(hubBloom, 0), 1) * (pressed == nil ? 1 : 1 - exit.value))
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius,
                                              width: hubRadius * 2, height: hubRadius * 2))
        withShadow(blur: 3 * (1 - sunk), alpha: dark ? 0.4 : 0.12) {
            hubFill.mix(dark ? NSColor(white: 0, alpha: 0.55) : NSColor(white: 0.82, alpha: 0.7), sunk).setFill()
            hub.fill()
        }
        line.setStroke()
        hub.lineWidth = 1
        hub.stroke()
        if sunk > 0.01 {
            // A small × above the title while releasing would cancel.
            let x = NSBezierPath()
            let c = NSPoint(x: center.x, y: center.y + 24), r: CGFloat = 4
            x.move(to: NSPoint(x: c.x - r, y: c.y - r)); x.line(to: NSPoint(x: c.x + r, y: c.y + r))
            x.move(to: NSPoint(x: c.x - r, y: c.y + r)); x.line(to: NSPoint(x: c.x + r, y: c.y - r))
            x.lineWidth = 1.6
            x.lineCapStyle = .round
            ink.withAlphaComponent(0.7 * sunk).setStroke()
            x.stroke()
        }

        // A short accent arc on the hub's rim turns to the chosen sector, like a dial clicking into place.
        if dialAlpha.value > 0.01 {
            let arc = NSBezierPath()
            let span = min(step * 0.7, 54)
            arc.appendArc(withCenter: center, radius: hubRadius - 2.5, startAngle: dial.value + turn.value - span / 2,
                          endAngle: dial.value + turn.value + span / 2, clockwise: false)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            NSColor.controlAccentColor.withAlphaComponent(0.95 * min(dialAlpha.value, 1)).setStroke()
            arc.stroke()
        }

        drawHeadline(at: NSPoint(x: center.x, y: center.y + 7), maxWidth: hubRadius * 1.7)
        drawText(isClickable ? L(hovered == nil ? "Esc to close" : "Click or Return") : cancelArmed ? L("release to cancel") : hovered == nil ? subtitle : L("drop to apply"),
                 at: NSPoint(x: center.x, y: center.y - 8),
                 font: AppTypography.font(ofSize: 8.5, weight: .medium), color: ink.withAlphaComponent(0.6),
                 maxWidth: hubRadius * 1.6)
        drawPageDots(at: NSPoint(x: center.x, y: center.y - 26), hintBelow: true)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The wheel hub's title: crossfades with a small vertical slide when the hovered item changes.
    private func drawHeadline(at point: NSPoint, maxWidth: CGFloat) {
        let font = AppTypography.font(ofSize: 12, weight: .bold)
        let s = min(max(swap.value, 0), 1)
        let current = headline(for: hovered)
        // The old title leaves upwards in the first third; the new one rises in after it, so they never overlap.
        let changing = previousHeadline != current
        let slide: CGFloat = Motion.reduced ? 0 : 6   // Reduce Motion: a plain crossfade
        let out = min(s / 0.35, 1), into = min(max((s - 0.2) / 0.8, 0), 1)
        if changing, out < 1 {
            let wasItem = previousHeadline != mode.title && previousHeadline != L("Cancel")
            drawText(previousHeadline, at: NSPoint(x: point.x, y: point.y + slide * out), font: font,
                     color: (wasItem ? accent : ink).withAlphaComponent(1 - out), maxWidth: maxWidth)
        }
        drawText(current, at: NSPoint(x: point.x, y: point.y - (changing ? slide * (1 - into) : 0)), font: font,
                 color: (hovered == nil ? ink : accent).withAlphaComponent(changing ? into : 1), maxWidth: maxWidth)
    }

    /// Title, file name and page dots above the items (every style but the wheel).
    private func drawHeader(onGlass: Bool) {
        let rect = NSRect(x: 0, y: bounds.height - Self.headerHeight, width: bounds.width, height: Self.headerHeight)
        let title = headline(for: hovered)
        let detail = isClickable ? L(hovered == nil ? "Esc to close" : "Click or Return") : cancelArmed ? L("release to cancel") : hovered == nil ? subtitle : L("drop to apply")
        let attrs: [NSAttributedString.Key: Any] = [.font: AppTypography.font(ofSize: 13, weight: .bold)]
        // Sized for the widest title this page can show, so hovering never slides the header sideways.
        let titleWidth = max((title as NSString).size(withAttributes: attrs).width, headerTitleWidth)
        let detailFont = AppTypography.font(ofSize: 11)
        var detailWidth = min([subtitle, L("drop to apply"), L("release to cancel")]
            .map { ($0 as NSString).size(withAttributes: [.font: detailFont]).width }.max() ?? 0, 150)
        let dotsWidth: CGFloat = pageCount > 1 ? CGFloat(pageCount) * 7 + 44 : 0
        let capsuleWidth = min(titleWidth + detailWidth + dotsWidth + 34, bounds.width - 8)
        // In a narrow menu the detail text gives way so it never runs into the page dots.
        detailWidth = max(min(detailWidth, capsuleWidth - titleWidth - dotsWidth - 34), 0)
        let capsule = NSRect(x: rect.midX - capsuleWidth / 2, y: rect.midY - 13, width: capsuleWidth, height: 26)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(pressed == nil ? 1 : 1 - exit.value)
        if !onGlass {
            withShadow(blur: 6, alpha: isDark ? 0.5 : 0.18) {
                (isDark ? NSColor(white: 0.12, alpha: 0.86) : NSColor(white: 1, alpha: 0.88)).setFill()
                NSBezierPath(roundedRect: capsule, xRadius: 13, yRadius: 13).fill()
            }
        }
        let s = min(max(swap.value, 0), 1)
        var x = capsule.minX + 13
        let shownTitle = (title as NSString).size(withAttributes: attrs).width
        drawText(title, at: NSPoint(x: x + min(shownTitle, titleWidth) / 2, y: capsule.midY - (Motion.reduced ? 0 : 3 * (1 - s))),
                 font: AppTypography.font(ofSize: 13, weight: .bold),
                 color: (hovered == nil ? ink : NSColor.controlAccentColor).withAlphaComponent(0.4 + 0.6 * s),
                 maxWidth: titleWidth, glow: false)
        x += min(shownTitle, titleWidth) + 8
        let shownDetail = min((detail as NSString).size(withAttributes: [.font: detailFont]).width, detailWidth)
        drawText(detail, at: NSPoint(x: x + shownDetail / 2, y: capsule.midY),
                 font: detailFont, color: ink.withAlphaComponent(0.55), maxWidth: detailWidth, glow: false)
        if pageCount > 1 {
            drawPageDots(at: NSPoint(x: capsule.maxX - dotsWidth / 2 - 6, y: capsule.midY), hintBelow: false)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawPageDots(at point: NSPoint, hintBelow: Bool) {
        guard pageCount > 1 else { return }
        let dot: CGFloat = 4, spacing: CGFloat = 7
        let width = CGFloat(pageCount - 1) * spacing
        let dotsX = hintBelow ? point.x - width / 2 : point.x - width / 2 - 16
        for p in 0..<pageCount {
            let x = dotsX + CGFloat(p) * spacing
            // The current page's dot grows in as the page turns.
            let size = p == page && !Motion.reduced ? dot * (1 + 0.5 * (1 - min(max(reveal.value, 0), 1))) : dot
            (p == page ? accent : ink.withAlphaComponent(0.3)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - size / 2, y: point.y - size / 2, width: size, height: size)).fill()
        }
        let hint = L("%@ next", isClickable ? L("Space") : mode.key)
        if hintBelow {
            drawText(hint, at: NSPoint(x: point.x, y: point.y - 10), font: AppTypography.font(ofSize: 7.5, weight: .semibold),
                     color: ink.withAlphaComponent(0.55), maxWidth: 80)
        } else {
            drawText(hint, at: NSPoint(x: dotsX + width + 22, y: point.y), font: AppTypography.font(ofSize: 9, weight: .semibold),
                     color: ink.withAlphaComponent(0.55), maxWidth: 50, glow: false)
        }
    }

    private func drawList() {
        let dark = isDark
        // Light tint over the glass backdrop so rows read like a native context menu.
        if let (rect, radius) = backdrop {
            (dark ? NSColor(white: 0, alpha: 0.25) : NSColor(white: 1, alpha: 0.35)).setFill()
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            shape.fill()
            NSColor.white.withAlphaComponent(dark ? 0.15 : 0.7).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
        }
        drawHeader(onGlass: true)
        NSColor.separatorColor.setFill()
        NSRect(x: 16, y: bounds.height - Self.headerHeight - 1, width: bounds.width - 32, height: 1).fill()

        // One highlight that slides from row to row instead of jumping.
        if rowAlpha.value > 0.01 {
            var rect = listRect(row.value)
            let pressed = pressed.map { pressValue($0) } ?? 0
            if !Motion.reduced { rect = rect.insetBy(dx: rect.width * 0.02 * pressed, dy: rect.height * 0.06 * pressed) }
            var fill = accent.withAlphaComponent(0.92 * min(rowAlpha.value, 1))
            if pressed > 0 { fill = fill.mix(pressedTint, pressed * 0.6) }
            if flash > 0 { fill = fill.mix(.white, 0.3 * flash) }
            fill.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        }

        for (i, slot) in slots().enumerated() {
            // Text turns white as the highlight passes under it.
            let under = rowAlpha.value * max(0, 1 - abs(row.value - CGFloat(i)))
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let bloom = min(max(bloomValue(i) * 1.5, 0), 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: AppTypography.font(ofSize: slot.fontSize, weight: .medium),
                .foregroundColor: ink.mix(.white, under).withAlphaComponent(bloom * (1 - exitValue(i)) * (i == hovered ? 1 : reveal.value)),
                .paragraphStyle: style,
            ]
            let height = ("A" as NSString).size(withAttributes: attrs).height
            let nudge = Motion.reduced ? 0 : 3 * min(max(popValue(i), 0), 1) - 8 * (1 - bloom)
            (items[i].displayTitle as NSString).draw(with: NSRect(x: slot.label.x + nudge, y: slot.label.y - height / 2,
                                                           width: slot.maxWidth, height: height),
                                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
    }

    private func drawShelf() {
        let theme = MenuAppearance(dark: isDark)
        let palette = Prefs.templateColors[style == .shelf ? .shelf : .notes]
        drawHeader(onGlass: false)

        // A satin rail and inset brackets replace the varnished wood and gold bands.
        let plank = NSRect(x: 10, y: shelfTop - 16, width: bounds.width - 20, height: 16)
        let rail = NSBezierPath(roundedRect: plank, xRadius: 5, yRadius: 5)
        withShadow(blur: 7, alpha: 0.14) { palette.railColor(dark: isDark).setFill(); rail.fill() }
        theme.edge.setStroke()
        rail.lineWidth = 0.75
        rail.stroke()
        for bx in [plank.minX + 22, plank.maxX - 34] {
            theme.trim.setFill()
            NSBezierPath(roundedRect: NSRect(x: bx, y: plank.minY - 10, width: 12, height: 12), xRadius: 3, yRadius: 3).fill()
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: shelfTop - 3, width: bounds.width, height: bounds.height)).addClip()
        for (i, slot) in slots().enumerated() {
            guard slot.alpha > 0.01 else { continue }
            let p = min(max(popValue(i), 0), 1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(slot.alpha)
            var color = palette.card(i, dark: isDark, selection: tintValue(i))
            if i == pressed, flash > 0 { color = color.mix(theme.surface, 0.3 * flash) }
            withShadow(blur: 3 + 4 * p, alpha: 0.15, offset: 1 + p) {
                color.setFill()
                slot.path.fill()
            }
            theme.edge.mix(.controlAccentColor, 0.45 * tintValue(i)).setStroke()
            slot.path.lineWidth = 0.75 + 0.5 * tintValue(i)
            slot.path.stroke()
            let rect = slot.path.bounds
            theme.edge.setFill()
            NSRect(x: rect.minX + 5, y: rect.maxY - 16, width: rect.width - 10, height: 0.75).fill()
            NSRect(x: rect.minX + 5, y: rect.minY + 14, width: rect.width - 10, height: 0.75).fill()
            drawLabel(items[i].displayTitle, slot, color: palette.ink(i, dark: isDark, selection: tintValue(i)).withAlphaComponent(i == hovered ? 1 : reveal.value),
                      glow: false, weight: .semibold)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawNotes() {
        let theme = MenuAppearance(dark: isDark)
        let palette = Prefs.templateColors[style == .shelf ? .shelf : .notes]
        drawHeader(onGlass: false)
        let all = slots()
        for i in all.indices.sorted(by: { popValue($0) < popValue($1) }) {
            let slot = all[i]
            guard slot.alpha > 0.01 else { continue }
            let p = min(max(popValue(i), 0), 1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(slot.alpha)
            var color = palette.card(i, dark: isDark, selection: tintValue(i))
            if i == pressed, flash > 0 { color = color.mix(theme.surface, 0.3 * flash) }
            withShadow(blur: 5 + 5 * p * (1 - pressValue(i)), alpha: 0.14, offset: 1 + 2 * p * (1 - pressValue(i))) {
                color.setFill()
                slot.path.fill()
            }
            theme.edge.mix(.controlAccentColor, 0.45 * tintValue(i)).setStroke()
            slot.path.lineWidth = 0.75 + 0.5 * tintValue(i)
            slot.path.stroke()
            // A small paper tab keeps the note metaphor without a large strip of tape.
            let box = slot.path.bounds
            let tape = NSBezierPath(roundedRect: NSRect(x: box.midX - 13, y: box.maxY - 10, width: 26, height: 5),
                                    xRadius: 2.5, yRadius: 2.5)
            var t = AffineTransform(translationByX: box.midX, byY: box.maxY - 5)
            t.rotate(byDegrees: slot.angle)
            t.translate(x: -box.midX, y: -(box.maxY - 5))
            tape.transform(using: t)
            theme.trim.withAlphaComponent(0.4).setFill()
            tape.fill()
            drawLabel(items[i].displayTitle, slot, color: palette.ink(i, dark: isDark, selection: tintValue(i)).withAlphaComponent(i == hovered ? 1 : reveal.value),
                      glow: false, weight: .medium)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawClothesline() {
        let theme = MenuAppearance(dark: isDark)
        let colors = Prefs.clotheslineColors
        drawHeader(onGlass: false)
        let left: CGFloat = 22, right = bounds.width - 22

        for x in [left, right] {
            withShadow(blur: 3, alpha: 0.14) {
                theme.rail.setFill()
                NSBezierPath(roundedRect: NSRect(x: x - 4, y: 6, width: 8, height: ropeY(x) - 6 + 8), xRadius: 4, yRadius: 4).fill()
            }
        }
        let rope = NSBezierPath()
        rope.move(to: NSPoint(x: left, y: ropeY(left)))
        for x in stride(from: left, through: right, by: 4) { rope.line(to: NSPoint(x: x, y: ropeY(x))) }
        rope.lineWidth = 2.5
        rope.lineCapStyle = .round
        withShadow(blur: 2, alpha: 0.18) { colors.rope.color.setStroke(); rope.stroke() }

        for (i, slot) in slots().enumerated() {
            guard slot.alpha > 0.01 else { continue }
            let p = min(max(popValue(i), 0), 1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(slot.alpha)
            var card = theme.card(i, selection: tintValue(i))
            if i == pressed, flash > 0 { card = card.mix(theme.surface, 0.3 * flash) }
            withShadow(blur: 4 + 4 * p, alpha: 0.15, offset: 1 + p) {
                card.setFill()
                slot.path.fill()
            }
            theme.edge.mix(.controlAccentColor, 0.45 * tintValue(i)).setStroke()
            slot.path.lineWidth = 0.75 + 0.5 * tintValue(i)
            slot.path.stroke()

            let x = slot.path.bounds.midX
            let pegTop = ropeY(x) + 7
            withShadow(blur: 2, alpha: 0.16) {
                colors.peg.color.setFill()
                NSBezierPath(roundedRect: NSRect(x: x - 4, y: pegTop - 24, width: 8, height: 24), xRadius: 3, yRadius: 3).fill()
            }
            theme.edge.setFill()
            NSRect(x: x - 4, y: pegTop - 12, width: 8, height: 1).fill()
            drawLabel(items[i].displayTitle, slot,
                      color: theme.ink.withAlphaComponent(i == hovered ? 1 : reveal.value), glow: false, weight: .medium)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func withShadow(blur: CGFloat, alpha: CGFloat, offset: CGFloat = 1, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: -offset)
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    private var labelGlow = NSColor.white

    /// Draws a slot's label at its centre, rotated by the slot's angle.
    private func drawLabel(_ string: String, _ slot: Slot, color: NSColor, glow: Bool,
                           weight: NSFont.Weight = .semibold, font: NSFont? = nil) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: slot.label.x, yBy: slot.label.y)
        t.rotate(byDegrees: slot.angle)
        if slot.labelScale != 1 { t.scale(by: slot.labelScale) }
        t.concat()
        drawText(string, at: .zero, font: font ?? AppTypography.font(ofSize: slot.fontSize, weight: weight), color: color,
                 maxWidth: slot.maxWidth, glow: glow)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawText(_ string: String, at point: NSPoint, font: NSFont, color: NSColor, maxWidth: CGFloat,
                          glow: Bool = true) {
        guard color.alphaComponent > 0.01 else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if glow {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 2.5
            shadow.shadowOffset = .zero
            shadow.shadowColor = labelGlow.withAlphaComponent(labelGlow.alphaComponent * color.alphaComponent)
            attrs[.shadow] = shadow
        }
        var size = (string as NSString).size(withAttributes: attrs)
        if size.width > maxWidth, maxWidth > 0 {
            // Keep the selected reading size as a floor, then truncate only the longest labels.
            let fitted = max(7 * Prefs.interaction.textSize.scale, font.pointSize * maxWidth / size.width)
            attrs[.font] = NSFont(descriptor: font.fontDescriptor, size: fitted) ?? font
            size = (string as NSString).size(withAttributes: attrs)
        }
        let width = min(size.width, maxWidth)
        let rect = NSRect(x: point.x - width / 2, y: point.y - size.height / 2, width: width, height: size.height)
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    // MARK: Drop target

    /// Updates the hover state for a pointer at `point` (view coordinates). Returns true if a drop there would
    /// apply an item.
    @discardableResult
    func track(_ point: NSPoint) -> Bool {
        guard pressed == nil else { return false }
        pointerInside = true
        if style == .wheel, hovered != nil, pointer != point { needsDisplay = true }
        pointer = point
        if let start = openPoint {
            guard hypot(point.x - start.x, point.y - start.y) >= 10 else { return false }
            openPoint = nil
        }
        hovered = slot(at: point)
        cancelArmed = isLive && visited && hovered == nil
        return hovered != nil
    }

    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        dragInfo = info
        guard track(convert(info.draggingLocation, from: nil)) else { return [] }
        let mask = info.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        return mask.contains(.move) ? .move : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { pointerLeft() }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        setDeepPress(false)
        // The drag finished over the menu without a drop (Esc, or released on the hub): clear away now rather than
        // waiting for the drag watcher's fallback.
        if pressed == nil { DispatchQueue.main.async { [weak self] in self?.onDragEndedWithoutDrop?() } }
    }

    /// The pointer left the menu: nothing is hovered, and releasing out there isn't a cancel on the hub.
    func pointerLeft() {
        guard pressed == nil else { return }
        pointerInside = false
        pointer = nil
        hovered = nil
        cancelArmed = false
    }

    /// Starts a fresh try without changing what is shown as hovered (Settings previews rest on a hovered item, which
    /// mustn't count as the user having visited it).
    func resetVisit() {
        visited = false
        cancelArmed = false
    }

    /// Pushes the hovered item partway in while a Force Click is held during the drag, and lets it back out.
    private func setDeepPress(_ on: Bool) {
        guard on != deepPressed, pressed == nil else { return }
        deepPressed = on && hovered != nil
        press.response = deepPressed ? 0.12 : 0.22
        press.damping = deepPressed ? 1 : 0.7
        press.target = deepPressed ? 0.6 : 0
        kick()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard hovered != nil, pressed == nil else { return false }
        // Let the system shrink the file's drag image into the chosen item (see performDragOperation).
        sender.animatesToDestination = !Motion.reduced
        return true
    }

    /// Where the dragged file's image lands on a drop: a small square on the chosen item.
    private func landing(for index: Int) -> NSRect {
        let slots = slots(settled: true)
        guard slots.indices.contains(index) else { return .zero }
        let p = style == .wheel ? slots[index].label : NSPoint(x: slots[index].path.bounds.midX, y: slots[index].path.bounds.midY)
        return NSRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = hovered, items.indices.contains(index) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let item = items[index]
        if sender.animatesToDestination {
            let target = landing(for: index)
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self], searchOptions: [:]) { item, _, _ in
                item.draggingFrame = target
            }
        }
        // Feedback lands on the drop itself; the action starts on the next run-loop turn.
        beginConfirm(index)
        Feedback.press()
        DispatchQueue.main.async { [weak self] in self?.onDrop?(item, urls) }
        return true
    }
}

/// A Force Click on a Force Touch trackpad during the drag "spring-loads" the hovered item: it sinks in, a real
/// press under the finger (the trackpad gives its own click). Releasing the drag still applies it as usual.
extension WheelView: NSSpringLoadingDestination {
    private func springOptions() -> NSSpringLoadingOptions {
        hovered == nil || pressed != nil ? [] : [.enabled, .continuousActivation, .noHover]
    }

    func springLoadingEntered(_ draggingInfo: NSDraggingInfo) -> NSSpringLoadingOptions { springOptions() }
    func springLoadingUpdated(_ draggingInfo: NSDraggingInfo) -> NSSpringLoadingOptions { springOptions() }
    func springLoadingActivated(_ activated: Bool, draggingInfo: NSDraggingInfo) { setDeepPress(activated) }
    func springLoadingHighlightChanged(_ draggingInfo: NSDraggingInfo) {}
    func springLoadingExited(_ draggingInfo: NSDraggingInfo) { setDeepPress(false) }
}

extension NSView {
    /// A small spring "pop" around the view's centre, from `scale`.
    func popIn(from scale: CGFloat = 0.82) {
        wantsLayer = true
        guard let layer else { return }
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        func scaled(_ s: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(c.x, c.y, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -c.x, -c.y, 0)
        }
        layer.removeAnimation(forKey: "shrink")
        layer.transform = CATransform3DIdentity
        // Crisp, barely-there settle: a menu shouldn't wobble.
        let anim = CASpringAnimation(perceptualDuration: 0.24 / Prefs.interaction.menu.safeSpeed,
                                     bounce: 0.1 * Prefs.interaction.menu.safeBounce)
        anim.keyPath = "transform"
        anim.fromValue = scaled(scale)
        anim.toValue = CATransform3DIdentity
        anim.duration = anim.settlingDuration
        layer.add(anim, forKey: "pop")
    }

    /// Shrinks the view towards its centre over `duration` (paired with a fade by the caller).
    func shrinkAway(to scale: CGFloat, duration: CFTimeInterval) {
        wantsLayer = true
        guard let layer else { return }
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer.presentation()?.transform ?? CATransform3DIdentity
        anim.toValue = t
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.removeAnimation(forKey: "pop")
        layer.add(anim, forKey: "shrink")
    }
}

@MainActor
private final class WheelAccessibilityButton: NSAccessibilityElement {
    var press: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { press?(); return true }
}
