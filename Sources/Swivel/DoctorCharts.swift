import AppKit

/// A ring of coloured segments, drawn clockwise from twelve o'clock over a grey track, with a value and a caption in
/// the middle. Segment changes glide on critically damped springs (no overshoot); Reduce Motion jumps. Colour is
/// never the only signal: the legend next to it says the same in words.
@MainActor
final class DoctorRing: NSView {
    private var springs: [Spring] = []
    private var colors: [NSColor] = []
    private lazy var driver = FrameDriver(view: self)
    let valueLabel = NSTextField(labelWithString: "")
    let captionLabel = NSTextField(labelWithString: "")
    private let lineWidth: CGFloat = 14

    init(diameter: CGFloat = 144) {
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        valueLabel.lineBreakMode = .byClipping
        valueLabel.alignment = .center
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byTruncatingTail
        let text = ToolUI.stack([valueLabel, captionLabel], spacing: 1)
        text.alignment = .centerX
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.centerXAnchor.constraint(equalTo: centerXAnchor), text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: diameter - lineWidth * 2 - 12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Fractions of the whole circle (0…1), in drawing order.
    func set(_ segments: [(Double, NSColor)], value: String, caption: String, accessibility: String) {
        valueLabel.stringValue = value
        captionLabel.stringValue = caption
        setAccessibilityLabel(accessibility)
        colors = segments.map(\.1)
        let animate = window != nil && !Motion.reduced && springs.count == segments.count
        if springs.count != segments.count { springs = segments.map { _ in Spring(0, response: 0.45, damping: 1) } }
        for (index, segment) in segments.enumerated() {
            let fraction = CGFloat(min(max(segment.0, 0), 1))
            if animate { springs[index].target = fraction } else { springs[index].snap(fraction) }
        }
        needsDisplay = true
        guard animate else { return }
        driver.onFrame = { [weak self] dt in
            guard let self else { return false }
            for index in self.springs.indices { self.springs[index].step(dt) }
            self.needsDisplay = true
            return !self.springs.allSatisfy(\.isSettled)
        }
        driver.start()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { driver.stop(); for index in springs.indices { springs[index].snap(springs[index].target) } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - lineWidth / 2 - 1
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()
        var start: CGFloat = 90
        for (spring, color) in zip(springs, colors) {
            let sweep = max(0, min(spring.value, 1)) * 360
            guard sweep > 0.2 else { continue }
            let end = max(start - sweep, -270)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            arc.lineWidth = lineWidth
            color.setStroke()
            arc.stroke()
            start = end
        }
    }
}

/// A rolling line chart, newest sample on the right, values 0…1 with faint guides at quarters.
@MainActor
final class DoctorLineChart: NSView {
    static let capacity = 60  // two minutes at one sample every two seconds
    private(set) var series: [[Double]] = []
    private var colors: [NSColor] = []

    init(colors: [NSColor], height: CGFloat = 96) {
        self.colors = colors
        series = colors.map { _ in [] }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Replaces the history (kept by the window, so a rebuilt page continues where it was).
    func show(_ history: [[Double]], accessibility: String) {
        series = history
        setAccessibilityLabel(accessibility)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 3)
        NSColor.separatorColor.setStroke()
        for quarter in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = box.minY + box.height * quarter
            let line = NSBezierPath()
            line.move(to: NSPoint(x: box.minX, y: y))
            line.line(to: NSPoint(x: box.maxX, y: y))
            line.lineWidth = quarter == 0 ? 1 : 0.5
            if quarter != 0 { line.setLineDash([2, 3], count: 2, phase: 0) }
            line.stroke()
        }
        if series.allSatisfy({ $0.count < 2 }) {
            let text = NSAttributedString(string: L("Collecting… a line appears within a few seconds."),
                                          attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            text.draw(at: NSPoint(x: box.minX + 6, y: box.midY - 6))
        }
        let step = box.width / CGFloat(Self.capacity - 1)
        for (values, color) in zip(series, colors) where values.count > 1 {
            // Fills from the left until two minutes have been seen, then scrolls with the newest sample on the right.
            let points = values.suffix(Self.capacity).enumerated().map { index, value in
                NSPoint(x: box.minX + CGFloat(index) * step,
                        y: box.minY + box.height * CGFloat(min(max(value, 0), 1)))
            }
            let line = NSBezierPath()
            line.move(to: points[0])
            for point in points.dropFirst() { line.line(to: point) }
            let fill = line.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: points.last!.x, y: box.minY))
            fill.line(to: NSPoint(x: points[0].x, y: box.minY))
            fill.close()
            color.withAlphaComponent(0.12).setFill()
            fill.fill()
            line.lineWidth = 1.6
            line.lineJoinStyle = .round
            color.setStroke()
            line.stroke()
        }
    }
}

/// A coloured dot and a line of text that can be updated in place.
@MainActor
final class DoctorLegendItem: NSStackView {
    let label = NSTextField(labelWithString: "")
    private let dot: DoctorDot

    init(color: NSColor) {
        dot = DoctorDot(color: color)
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        addArrangedSubview(dot)
        addArrangedSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var color: NSColor {
        get { dot.color }
        set { dot.color = newValue }
    }
}

@MainActor
private final class DoctorDot: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 9).isActive = true
        heightAnchor.constraint(equalToConstant: 9).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// The chart panel at the top of Storage, Caches and Slow or Hot. The window owns it and feeds it readings.
@MainActor
final class DoctorChartPanel {
    enum Kind { case disk, caches, memory }

    let kind: Kind
    let view: NSView
    private let ring = DoctorRing()
    private var items: [DoctorLegendItem] = []
    /// The caches page's legend, rebuilt when the list of caches changes.
    private var cacheLegend: NSStackView?
    private var cacheIDs: [String]?
    private var line: DoctorLineChart?
    private var lineItems: [DoctorLegendItem] = []

    static let usedColor = NSColor.systemBlue
    static let purgeableColor = NSColor.systemTeal
    static let selectedColor = NSColor.systemGreen
    static let cpuColor = NSColor.systemBlue
    static let memoryColor = NSColor.systemPurple

    init(_ kind: Kind) {
        self.kind = kind
        var columns: [NSView] = [ring]
        switch kind {
        case .disk:
            items = [DoctorLegendItem(color: Self.usedColor), DoctorLegendItem(color: Self.purgeableColor),
                     DoctorLegendItem(color: .quaternaryLabelColor), DoctorLegendItem(color: Self.selectedColor)]
            columns.append(Self.legend(L("Startup disk"), items))
        case .caches:
            let heading = NSTextField(labelWithString: L("Caches"))
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            let stack = ToolUI.stack([heading], spacing: 6)
            stack.alignment = .leading
            cacheLegend = stack
            columns.append(stack)
        case .memory:
            items = [DoctorLegendItem(color: Self.usedColor), DoctorLegendItem(color: Self.selectedColor),
                     DoctorLegendItem(color: .quaternaryLabelColor), DoctorLegendItem(color: .clear)]
            columns.append(Self.legend(L("Memory"), items))
            let chart = DoctorLineChart(colors: [Self.cpuColor, Self.memoryColor])
            lineItems = [DoctorLegendItem(color: Self.cpuColor), DoctorLegendItem(color: Self.memoryColor)]
            let caption = NSTextField(labelWithString: L("Last 2 minutes, updated every 2 seconds"))
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = .secondaryLabelColor
            let keys = ToolUI.stack(lineItems + [NSView(), caption], vertical: false, spacing: 14)
            let block = ToolUI.stack([chart, keys], spacing: 6)
            chart.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
            keys.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true
            block.setContentHuggingPriority(.defaultLow, for: .horizontal)
            line = chart
            columns.append(block)
        }
        let row = ToolUI.stack(columns, vertical: false, spacing: 22)
        row.alignment = .centerY
        // A plain layer-backed card, constrained edge to edge: an NSBox's autoresizing content view (and a safe area
        // under the title bar) let the chart slide out of its frame in a live window.
        let card = DoctorCard()
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        view = card
    }

    private static func legend(_ title: String, _ items: [DoctorLegendItem]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = ToolUI.stack([heading] + items, spacing: 6)
        stack.alignment = .leading
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }

    /// The startup disk: used, purgeable and free, with the selected items carved out of "used" in green.
    func showDisk(_ space: DoctorStorage.Space?, selected: Int64, inTrash: Bool) {
        guard let space, space.total > 0 else {
            ring.set([], value: "—", caption: L("Not readable"), accessibility: L("The startup disk’s capacity couldn’t be read."))
            return
        }
        let total = Double(space.total)
        let used = max(0, space.total - space.important)
        let chosen = min(selected, used)
        let after = space.important + chosen
        ring.set([(Double(used - chosen) / total, Self.usedColor), (Double(chosen) / total, Self.selectedColor),
                  (Double(space.purgeable) / total, Self.purgeableColor)],
                 value: DoctorFormat.bytes(chosen > 0 ? after : space.important),
                 caption: chosen > 0 ? L("Available after cleaning") : L("Available"),
                 accessibility: L("Startup disk: %@ used, %@ available of %@.", DoctorFormat.bytes(used),
                                  DoctorFormat.bytes(space.important), DoctorFormat.bytes(space.total)))
        items[0].text = L("Used: %@", DoctorFormat.bytes(used))
        items[1].text = L("macOS can free by itself: %@", DoctorFormat.bytes(space.purgeable))
        items[2].text = L("Available: %@ of %@", DoctorFormat.bytes(space.important), DoctorFormat.bytes(space.total))
        items[3].text = chosen > 0
            ? (inTrash ? L("Selected: %@, freed when you empty the Trash", DoctorFormat.bytes(chosen)) : L("Selected: %@", DoctorFormat.bytes(chosen)))
            : ""
        items[3].isHidden = chosen == 0
    }

    /// Colours for one cache each, in size order; green is left out, it means "selected" elsewhere.
    static let cachePalette: [NSColor] = [.systemBlue, .systemPurple, .systemOrange, .systemPink, .systemTeal,
                                          .systemIndigo, .systemYellow, .systemBrown, .systemCyan, .systemRed]
    static let legendLimit = 6

    /// The caches found, one segment each, sized by their share of all caches. With a selection, the selected caches
    /// keep their colour and the others fade, and the middle shows how much is selected.
    func showCaches(_ rows: [DoctorRow], selected: Set<String>) {
        let caches = rows.filter { ($0.bytes ?? 0) > 0 }
        let total = caches.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        guard total > 0 else {
            ring.set([], value: "—", caption: L("Not checked"), accessibility: L("No caches checked yet."))
            rebuildCacheLegend([], total: 0, selected: selected)
            return
        }
        let chosen = caches.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        let segments = caches.enumerated().map { index, row -> (Double, NSColor) in
            let color = Self.cachePalette[index % Self.cachePalette.count]
            let faded = !selected.isEmpty && !selected.contains(row.id)
            return (Double(row.bytes ?? 0) / Double(total), faded ? color.withAlphaComponent(0.22) : color)
        }
        ring.set(segments, value: DoctorFormat.bytes(chosen > 0 ? chosen : total),
                 caption: chosen > 0 ? L("Selected") : L("All caches"),
                 accessibility: L("%d caches use %@; %@ selected.", caches.count, DoctorFormat.bytes(total), DoctorFormat.bytes(chosen)))
        rebuildCacheLegend(caches, total: total, selected: selected)
    }

    private func rebuildCacheLegend(_ caches: [DoctorRow], total: Int64, selected: Set<String>) {
        guard let stack = cacheLegend else { return }
        let ids = caches.map(\.id)
        if ids != cacheIDs {
            cacheIDs = ids
            for view in stack.arrangedSubviews.dropFirst() { stack.removeArrangedSubview(view); view.removeFromSuperview() }
            for (index, row) in caches.prefix(Self.legendLimit).enumerated() {
                let item = DoctorLegendItem(color: Self.cachePalette[index % Self.cachePalette.count])
                item.identifier = .init(row.id)
                stack.addArrangedSubview(item)
            }
            if caches.count > Self.legendLimit {
                let rest = caches.dropFirst(Self.legendLimit)
                let item = DoctorLegendItem(color: .quaternaryLabelColor)
                item.text = L("%d more: %@", rest.count, DoctorFormat.bytes(rest.reduce(0) { $0 + ($1.bytes ?? 0) }))
                stack.addArrangedSubview(item)
            }
            if caches.isEmpty {
                let item = DoctorLegendItem(color: .quaternaryLabelColor)
                item.text = L("Choose Check to see which caches use space")
                stack.addArrangedSubview(item)
            }
        }
        for case let item as DoctorLegendItem in stack.arrangedSubviews {
            guard let id = item.identifier?.rawValue, let row = caches.first(where: { $0.id == id }) else { continue }
            let share = total > 0 ? Int((Double(row.bytes ?? 0) / Double(total) * 100).rounded()) : 0
            item.text = row.title + "  " + DoctorFormat.bytes(row.bytes ?? 0) + " · \(share)%"
            item.label.font = .systemFont(ofSize: 12, weight: selected.contains(id) ? .semibold : .regular)
        }
    }

    /// Memory in use, coloured by memory pressure, with the selected apps carved out in green.
    func showMemory(_ memory: DoctorLive.Memory?, pressure: Int32, swap: Int64, selected: Int64) {
        guard let memory else {
            ring.set([], value: "—", caption: L("Not readable"), accessibility: L("Memory use couldn’t be read."))
            return
        }
        let total = Double(memory.physical)
        let chosen = min(selected, memory.used)
        let (color, word): (NSColor, String) = switch pressure {
        case 4: (.systemRed, L("very tight"))
        case 2: (.systemOrange, L("tight"))
        default: (Self.usedColor, L("fine"))
        }
        ring.set([(Double(memory.used - chosen) / total, color), (Double(chosen) / total, Self.selectedColor)],
                 value: "\(Int((memory.fraction * 100).rounded()))%", caption: L("Memory used"),
                 accessibility: L("Memory: %@ of %@ in use, pressure %@.", DoctorFormat.memory(memory.used),
                                  DoctorFormat.memory(memory.physical), word))
        items[0].color = color
        items[3].color = color
        items[0].text = L("In use: %@ of %@", DoctorFormat.memory(memory.used), DoctorFormat.memory(memory.physical))
        items[1].text = L("Selected apps: about %@", DoctorFormat.memory(chosen))
        items[1].isHidden = chosen == 0
        items[2].text = L("Disk space borrowed as memory: %@", DoctorFormat.memory(swap))
        items[3].text = L("How tight memory is: %@", word)
    }

    /// The rolling history of processor and memory use (0…1 each).
    func showHistory(cpu: [Double], memory: [Double]) {
        guard let line else { return }
        let cpuNow = cpu.last.map { "\(Int(($0 * 100).rounded()))%" } ?? "…"
        let memoryNow = memory.last.map { "\(Int(($0 * 100).rounded()))%" } ?? "…"
        line.show([cpu, memory], accessibility: L("Processor %@, memory %@.", cpuNow, memoryNow))
        lineItems[0].text = L("Processor %@", cpuNow)
        lineItems[1].text = L("Memory %@", memoryNow)
    }
}

/// A rounded card in the system's control background colour, redrawn when the appearance changes.
@MainActor
final class DoctorCard: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 10
        layer.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// The space map: the shown folder's items as boxes sized by the space they use (a squarified treemap), each with
/// the boxes of its own largest items inside. Click a folder's box to look inside it; double-click shows it in Finder.
@MainActor
final class DoctorTreemap: NSView {
    var onOpen: ((DoctorSpaceNode) -> Void)?
    var onHover: ((DoctorSpaceNode?) -> Void)?
    private(set) var node = DoctorSpaceNode(name: "", url: nil, bytes: 0, isFolder: true)
    private var boxes: [(rect: NSRect, node: DoctorSpaceNode, color: NSColor, depth: Int)] = []
    private var hovered: Int?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init(height: CGFloat = 300) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ node: DoctorSpaceNode) {
        self.node = node
        hovered = nil
        setAccessibilityLabel(L("Space map of %@: %@.", node.name, node.children.prefix(5).map { "\($0.name) \(DoctorFormat.bytes($0.bytes))" }.joined(separator: ", ")))
        layoutBoxes()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutBoxes()
    }

    private func layoutBoxes() {
        boxes = []
        let area = bounds.insetBy(dx: 1, dy: 1)
        guard area.width > 4, area.height > 4 else { return }
        let top = Self.squarify(node.children, in: area)
        for (index, (rect, child)) in top.enumerated() {
            let color = DoctorChartPanel.cachePalette[index % DoctorChartPanel.cachePalette.count]
            boxes.append((rect, child, color, 0))
            // One more level inside, below the label, when there is room.
            let inner = rect.insetBy(dx: 3, dy: 3)
            guard child.isFolder, !child.children.isEmpty, inner.width > 60, inner.height > 48 else { continue }
            let body = NSRect(x: inner.minX, y: inner.minY + 18, width: inner.width, height: inner.height - 18)
            for (subRect, grand) in Self.squarify(child.children, in: body) {
                boxes.append((subRect, grand, color, 1))
            }
        }
    }

    /// Squarified treemap (Bruls, Huizing and van Wijk): rows of boxes whose aspect ratios stay close to 1.
    static func squarify(_ nodes: [DoctorSpaceNode], in rect: NSRect) -> [(NSRect, DoctorSpaceNode)] {
        let items = nodes.filter { $0.bytes > 0 }
        let total = items.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        var out: [(NSRect, DoctorSpaceNode)] = []
        var free = rect
        var row: [DoctorSpaceNode] = []
        func worst(_ row: [DoctorSpaceNode], _ side: Double) -> Double {
            let areas = row.map { Double($0.bytes) * scale }
            let sum = areas.reduce(0, +)
            guard sum > 0, side > 0 else { return .infinity }
            return areas.map { max(side * side * $0 / (sum * sum), (sum * sum) / (side * side * $0)) }.max() ?? .infinity
        }
        func place(_ row: [DoctorSpaceNode]) {
            let sum = row.reduce(0.0) { $0 + Double($1.bytes) * scale }
            if free.width >= free.height {
                let width = CGFloat(sum / Double(free.height))
                var y = free.minY
                for item in row {
                    let height = CGFloat(Double(item.bytes) * scale) / width
                    out.append((NSRect(x: free.minX, y: y, width: width, height: height), item))
                    y += height
                }
                free = NSRect(x: free.minX + width, y: free.minY, width: max(0, free.width - width), height: free.height)
            } else {
                let height = CGFloat(sum / Double(free.width))
                var x = free.minX
                for item in row {
                    let width = CGFloat(Double(item.bytes) * scale) / height
                    out.append((NSRect(x: x, y: free.minY, width: width, height: height), item))
                    x += width
                }
                free = NSRect(x: free.minX, y: free.minY + height, width: free.width, height: max(0, free.height - height))
            }
        }
        for item in items {
            let side = Double(min(free.width, free.height))
            if row.isEmpty || worst(row + [item], side) <= worst(row, side) {
                row.append(item)
            } else {
                place(row)
                row = [item]
            }
        }
        if !row.isEmpty { place(row) }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        for (index, box) in boxes.enumerated() {
            let rect = box.rect.insetBy(dx: box.depth == 0 ? 1 : 1.5, dy: box.depth == 0 ? 1 : 1.5)
            guard rect.width > 1, rect.height > 1 else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: box.depth == 0 ? 4 : 2, yRadius: box.depth == 0 ? 4 : 2)
            let alpha: CGFloat = box.depth == 0 ? 0.30 : 0.55
            (index == hovered ? box.color.withAlphaComponent(alpha + 0.25) : box.color.withAlphaComponent(alpha)).setFill()
            path.fill()
            box.color.withAlphaComponent(0.9).setStroke()
            path.lineWidth = box.depth == 0 ? 1 : 0.5
            path.stroke()
            guard box.depth == 0 || (rect.width > 70 && rect.height > 30) else { continue }
            let label = box.node.name + "  " + DoctorFormat.bytes(box.node.bytes)
            let font = NSFont.systemFont(ofSize: box.depth == 0 ? 11.5 : 10, weight: box.depth == 0 ? .semibold : .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let text = NSAttributedString(string: label, attributes: attributes)
            let textRect = NSRect(x: rect.minX + 5, y: rect.minY + 3, width: rect.width - 10, height: 15)
            if textRect.width > 24, rect.height > 16 { text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }
        }
        if boxes.isEmpty {
            let text = NSAttributedString(string: L("Nothing to show here."), attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            text.draw(at: NSPoint(x: 12, y: 12))
        }
    }

    private func box(at point: NSPoint) -> Int? {
        // Inner boxes first: they sit on top of their parent's.
        boxes.indices.reversed().first { boxes[$0].rect.contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let index = box(at: convert(event.locationInWindow, from: nil))
        guard index != hovered else { return }
        hovered = index
        onHover?(index.map { boxes[$0].node })
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        onHover?(nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = box(at: convert(event.locationInWindow, from: nil)) else { return }
        let picked = boxes[index].node
        if event.clickCount >= 2, let url = picked.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        // A click inside a folder's box opens the top-level folder; an inner folder opens directly.
        let target = picked.isFolder && !picked.children.isEmpty ? picked
            : boxes[0..<index].last(where: { $0.depth == 0 && $0.rect.contains(boxes[index].rect.origin) })?.node
        if let target, target.isFolder, !target.children.isEmpty {
            Feedback.press()
            onOpen?(target)
        }
    }
}

/// The space map with the path shown above it and a button to go back up.
@MainActor
final class DoctorMapPanel {
    let view: NSView
    private let map = DoctorTreemap()
    private let path = NSTextField(labelWithString: "")
    private let hover = NSTextField(labelWithString: "")
    private let up: NSButton
    private let picker = NSPopUpButton()
    private var roots: [DoctorSpaceNode] = []
    private var trail: [DoctorSpaceNode] = []
    private let target = Target()

    init() {
        up = ToolUI.button("Up", target: nil, action: nil)
        path.font = .systemFont(ofSize: 13, weight: .semibold)
        path.lineBreakMode = .byTruncatingHead
        hover.font = .systemFont(ofSize: 12)
        hover.textColor = .secondaryLabelColor
        hover.lineBreakMode = .byTruncatingMiddle
        let hint = NSTextField(labelWithString: L("Click a box to look inside; double-click to show it in Finder."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let header = ToolUI.stack([picker, up, path, NSView()], vertical: false, spacing: 8)
        let footer = ToolUI.stack([hover, NSView(), hint], vertical: false, spacing: 8)
        hover.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = ToolUI.stack([header, map, footer], spacing: 8)
        for view in [header, map, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let card = DoctorCard()
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        view = card
        target.panel = self
        up.target = target
        up.action = #selector(Target.goUp)
        picker.target = target
        picker.action = #selector(Target.pick)
        map.onOpen = { [weak self] node in self?.open(node) }
        map.onHover = { [weak self] node in
            self?.hover.stringValue = node.map { $0.name + " — " + DoctorFormat.bytes($0.bytes) + ($0.url.map { "  " + DoctorFormat.path($0) } ?? "") } ?? ""
        }
    }

    /// One map per chosen folder; keeps the place the user had opened when the same folders are shown again.
    func show(_ maps: [DoctorSpaceNode]) {
        let same = maps.map(\.url) == roots.map(\.url)
        roots = maps
        picker.removeAllItems()
        picker.addItems(withTitles: maps.map { $0.name + " — " + DoctorFormat.bytes($0.bytes) })
        picker.isHidden = maps.count < 2
        if !same || trail.isEmpty { trail = maps.first.map { [$0] } ?? [] } else if let first = maps.firstIndex(where: { $0.url == trail.first?.url }) {
            picker.selectItem(at: first)
        }
        refresh()
    }

    fileprivate func open(_ node: DoctorSpaceNode) {
        trail.append(node)
        refresh()
    }

    fileprivate func goUp() {
        guard trail.count > 1 else { return }
        trail.removeLast()
        refresh()
    }

    fileprivate func pick() {
        let index = picker.indexOfSelectedItem
        guard index >= 0, index < roots.count else { return }
        trail = [roots[index]]
        refresh()
    }

    private func refresh() {
        guard let current = trail.last else { map.show(DoctorSpaceNode(name: "", url: nil, bytes: 0, isFolder: true)); return }
        map.show(current)
        up.isEnabled = trail.count > 1
        path.stringValue = trail.map(\.name).joined(separator: " › ") + "  " + DoctorFormat.bytes(current.bytes)
    }

    private final class Target: NSObject {
        weak var panel: DoctorMapPanel?
        @MainActor @objc func goUp() { panel?.goUp() }
        @MainActor @objc func pick() { panel?.pick() }
    }
}
