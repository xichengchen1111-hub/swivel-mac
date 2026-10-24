import AppKit

/// Sidebar of pages on the left (Overview, each feature, General), the selected page on the right.
@MainActor
final class BundleSplit: NSSplitViewController {
    enum Page: Int, CaseIterable { case overview, wheel, clothesline, textCapture, shelf, imagePresets, quickActions, batchRename, pdfPages, qrCodes, appRouting, keepAwake, doctor, general, feel }

    private let sidebar = SidebarList()
    private let detail = NSViewController()
    private lazy var pages: [Page: NSViewController] = [
        .overview: OverviewPage(),
        .wheel: WheelPage(),
        .clothesline: FeaturePage(.clothesline, content: ClotheslinePane()),
        .textCapture: FeaturePage(.textCapture, content: TextCapturePane()),
        .shelf: FeaturePage(.shelf, content: ShelfPane()),
        .imagePresets: FeaturePage(.imagePresets, content: ImagePresetsPane()),
        .quickActions: FeaturePage(.quickActions, content: QuickActionsPane()),
        .batchRename: FeaturePage(.batchRename, content: FileActionsPane(.batchRename)),
        .pdfPages: FeaturePage(.pdfPages, content: FileActionsPane(.pdfPages)),
        .qrCodes: FeaturePage(.qrCodes, content: FileActionsPane(.qrCodes)),
        .appRouting: FeaturePage(.appRouting, content: AppActionsPane()),
        .keepAwake: FeaturePage(.keepAwake, content: KeepAwakePane()),
        .doctor: FeaturePage(.doctor, content: DoctorPane()),
        .general: GeneralPane(),
        .feel: FeelPane(),
    ]
    private var current: NSViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        detail.view = NSView()
        sidebar.onSelect = { [weak self] page in self?.showPage(page) }
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 210
        side.maximumThickness = 260
        side.canCollapse = false
        addSplitViewItem(side)
        addSplitViewItem(NSSplitViewItem(viewController: detail))
        showPage(.overview)
    }

    func select(_ tab: AppWindow.Tab) {
        _ = view
        switch tab {
        case .overview: showPage(.overview)
        case .general: showPage(.general)
        case .feel: showPage(.feel)
        case .clothesline: showPage(.clothesline)
        case .textCapture: showPage(.textCapture)
        case .shelf: showPage(.shelf)
        case .imagePresets: showPage(.imagePresets)
        case .quickActions: showPage(.quickActions)
        case .batchRename: showPage(.batchRename)
        case .pdfPages: showPage(.pdfPages)
        case .qrCodes: showPage(.qrCodes)
        case .appRouting: showPage(.appRouting)
        case .keepAwake: showPage(.keepAwake)
        case .doctor: showPage(.doctor)
        case .shortcuts, .style, .customize, .colors:
            showPage(.wheel)
            (pages[.wheel] as? WheelPage)?.select(tab)
        }
    }

    func showPage(_ page: Page) {
        sidebar.select(page)
        guard let vc = pages[page], vc !== current else { return }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        detail.addChild(vc)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(vc.view)
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        detail.view.subviews.forEach { $0.removeFromSuperview() }
        detail.view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            vc.view.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            vc.view.topAnchor.constraint(equalTo: document.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            vc.view.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            vc.view.widthAnchor.constraint(equalToConstant: max(vc.preferredContentSize.width, 600)),
            vc.view.heightAnchor.constraint(equalToConstant: max(vc.preferredContentSize.height, 300)),
        ])
        current = vc
        view.window?.title = L("Swivel — %@", SidebarList.title(page))
    }
}

final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Sidebar

@MainActor
final class SidebarList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((BundleSplit.Page) -> Void)?
    private let table = NSTableView()
    private var selecting = false
    private var dots: [BundleSplit.Page: StatusDot] = [:]

    static func title(_ page: BundleSplit.Page) -> String {
        switch page {
        case .overview: L("Overview")
        case .wheel: Feature.wheel.title
        case .clothesline: Feature.clothesline.title
        case .textCapture: Feature.textCapture.title
        case .shelf: Feature.shelf.title
        case .imagePresets: Feature.imagePresets.title
        case .quickActions: Feature.quickActions.title
        case .batchRename: Feature.batchRename.title
        case .pdfPages: Feature.pdfPages.title
        case .qrCodes: Feature.qrCodes.title
        case .appRouting: Feature.appRouting.title
        case .keepAwake: Feature.keepAwake.title
        case .doctor: Feature.doctor.title
        case .general: L("General")
        case .feel: L("Feel & Text")
        }
    }

    private static func symbol(_ page: BundleSplit.Page) -> String {
        switch page {
        case .overview: "square.grid.2x2"
        case .wheel: Feature.wheel.symbol
        case .clothesline: Feature.clothesline.symbol
        case .textCapture: Feature.textCapture.symbol
        case .shelf: Feature.shelf.symbol
        case .imagePresets: Feature.imagePresets.symbol
        case .quickActions: Feature.quickActions.symbol
        case .batchRename: Feature.batchRename.symbol
        case .pdfPages: Feature.pdfPages.symbol
        case .qrCodes: Feature.qrCodes.symbol
        case .appRouting: Feature.appRouting.symbol
        case .keepAwake: Feature.keepAwake.symbol
        case .doctor: Feature.doctor.symbol
        case .general: "gearshape"
        case .feel: "slider.horizontal.3"
        }
    }

    private static func feature(_ page: BundleSplit.Page) -> Feature? {
        switch page {
        case .wheel: .wheel
        case .clothesline: .clothesline
        case .textCapture: .textCapture
        case .shelf: .shelf
        case .imagePresets: .imagePresets
        case .quickActions: .quickActions
        case .batchRename: .batchRename
        case .pdfPages: .pdfPages
        case .qrCodes: .qrCodes
        case .appRouting: .appRouting
        case .keepAwake: .keepAwake
        case .doctor: .doctor
        default: nil
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        view = scroll
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDots() }
        }
    }

    /// Only the dots follow the switches. Reloading the table here rebuilt every row on any settings change, which
    /// could flash the selection.
    private func refreshDots() {
        for (page, dot) in dots {
            if let feature = Self.feature(page) { dot.setOn(feature.isOn, animated: true) }
        }
    }

    func select(_ page: BundleSplit.Page) {
        _ = view
        selecting = true
        table.selectRowIndexes([page.rawValue], byExtendingSelection: false)
        selecting = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { BundleSplit.Page.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let page = BundleSplit.Page.allCases[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbol(page), accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        let name = NSTextField(labelWithString: Self.title(page))
        name.font = .systemFont(ofSize: 13)
        var views: [NSView] = [icon, name]
        if let feature = Self.feature(page) {
            let dot = StatusDot()
            dot.setOn(feature.isOn, animated: false)
            dots[page] = dot
            views.append(dot)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, table.selectedRow >= 0 else { return }
        onSelect?(BundleSplit.Page.allCases[table.selectedRow])
    }
}

/// A feature's small status dot, like PowerToys' enabled indicator. It fades along with the switch instead of
/// popping, and resolves its colour per appearance (a stored CGColor would stay light or dark).
final class StatusDot: NSView {
    private(set) var isOn = false
    private var configured = false
    private var fadeNext = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 7).isActive = true
        heightAnchor.constraint(equalToConstant: 7).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func setOn(_ on: Bool, animated: Bool) {
        guard on != isOn || !configured else { return }
        isOn = on
        configured = true
        fadeNext = animated && window != nil
        toolTip = on ? L("On") : L("Off")
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 3.5
        let color = (isOn ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        if fadeNext {
            fadeNext = false
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            fade.toValue = color
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "fade")
        }
        layer.backgroundColor = color
    }
}

// MARK: - Feature header

/// Icon, title, description and an on/off switch for one feature.
@MainActor
final class FeatureHeader: NSView {
    private let feature: Feature
    private let toggle = NSSwitch()
    private let state = NSTextField(labelWithString: L(""))

    init(_ feature: Feature, compact: Bool = false) {
        self.feature = feature
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: feature.symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: compact ? 22 : 30, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: compact ? 34 : 44).isActive = true
        let title = NSTextField(labelWithString: feature.title)
        title.font = .systemFont(ofSize: compact ? 15 : 22, weight: .bold)
        let blurb = NSTextField(wrappingLabelWithString: feature.blurb)
        blurb.textColor = .secondaryLabelColor
        blurb.font = .systemFont(ofSize: compact ? 12 : 13)
        blurb.preferredMaxLayoutWidth = compact ? 400 : 560
        let text = NSStackView(views: [title, blurb])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        toggle.setAccessibilityLabel(feature.title)
        toggle.target = self
        toggle.action = #selector(flipped)
        state.font = .systemFont(ofSize: 12)
        state.textColor = .secondaryLabelColor
        let right = NSStackView(views: [state, toggle])
        right.spacing = 8
        let row = NSStackView(views: [icon, text, right])
        row.spacing = 14
        row.alignment = .centerY
        row.distribution = .fill
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        right.setContentHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        toggle.state = feature.isOn ? .on : .off
        state.stringValue = feature.isOn ? L("On") : L("Off")
    }

    @objc private func flipped() {
        feature.isOn = toggle.state == .on
        Feedback.toggle(feature.isOn)
    }
}

// MARK: - Pages

/// Overview: one card per feature with its switch and a link to its settings.
final class OverviewPage: Pane {
    init() { super.init(size: NSSize(width: 820, height: 2120)) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        stack.addArrangedSubview(label("Swivel", size: 26, weight: .bold))
        stack.addArrangedSubview(label("A bundle of small Mac tools. Turn on the ones you want — each works on its own.", secondary: true))
        for (feature, page) in [(Feature.wheel, BundleSplit.Page.wheel), (.clothesline, .clothesline), (.textCapture, .textCapture), (.shelf, .shelf), (.imagePresets, .imagePresets), (.quickActions, .quickActions), (.batchRename, .batchRename), (.pdfPages, .pdfPages), (.qrCodes, .qrCodes), (.appRouting, .appRouting), (.keepAwake, .keepAwake), (.doctor, .doctor)] {
            let card = CardView()
            let header = FeatureHeader(feature, compact: true)
            let settings = NSButton(title: L("Settings…"), target: self, action: #selector(openSettings(_:)))
            settings.tag = page.rawValue
            settings.bezelStyle = .push
            let content = NSStackView(views: [header, settings])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 10
            header.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            content.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
                content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
                content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
                content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            ])
            card.translatesAutoresizingMaskIntoConstraints = false
            card.widthAnchor.constraint(equalToConstant: 740).isActive = true
            stack.addArrangedSubview(card)
        }
        stack.addArrangedSubview(label("You can also switch features on and off from the ◎ menu in the menu bar.", size: 11, secondary: true))
    }

    @objc private func openSettings(_ sender: NSButton) {
        guard let page = BundleSplit.Page(rawValue: sender.tag),
              let split = view.window?.contentViewController as? BundleSplit else { return }
        split.showPage(page)
    }
}

/// A rounded card that follows light and dark mode.
final class CardView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

/// A feature's page: header with the switch, then that feature's settings.
final class FeaturePage: NSViewController {
    private let feature: Feature
    private let content: NSViewController

    init(_ feature: Feature, content: NSViewController) {
        self.feature = feature
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let header = FeatureHeader(feature)
        header.translatesAutoresizingMaskIntoConstraints = false
        addChild(content)
        let body = content.view
        body.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(separator)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.topAnchor.constraint(equalTo: separator.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: content.preferredContentSize.width),
            body.heightAnchor.constraint(equalToConstant: content.preferredContentSize.height),
        ])
        view = root
        preferredContentSize = NSSize(width: max(content.preferredContentSize.width, 760),
                                      height: content.preferredContentSize.height + 110)
    }
}

/// The Wheel's page: switch, then Shortcuts / Style / Customize.
final class WheelPage: NSViewController {
    private let sections: [(String, NSViewController)] = [("Shortcuts", ShortcutsPane()), ("Style", StylePane()),
                                                           ("Customize", CustomizePane()), ("Colors", TemplateColorsPane())]
    private let picker = NSSegmentedControl()
    private let holder = NSView()
    private var heightConstraint: NSLayoutConstraint?

    override func loadView() {
        let root = NSView()
        let header = FeatureHeader(.wheel)
        picker.segmentCount = sections.count
        for (i, section) in sections.enumerated() { picker.setLabel(L(section.0), forSegment: i) }
        picker.trackingMode = .selectOne
        picker.selectedSegment = 0
        picker.target = self
        picker.action = #selector(picked)
        for view in [header, picker, holder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        heightConstraint = holder.heightAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            picker.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            picker.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            holder.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            holder.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 4),
            heightConstraint!,
        ])
        view = root
        let widest = sections.map { $0.1.preferredContentSize.width }.max() ?? 0
        preferredContentSize = NSSize(width: max(widest, 820), height: 760)
        show(0)
    }

    func select(_ tab: AppWindow.Tab) {
        _ = view
        let index = switch tab {
        case .style: 1
        case .customize: 2
        case .colors: 3
        default: 0
        }
        picker.selectedSegment = index
        show(index)
    }

    @objc private func picked() { show(picker.selectedSegment) }

    private func show(_ index: Int) {
        holder.subviews.forEach { $0.removeFromSuperview() }
        children.forEach { $0.removeFromParent() }
        let vc = sections[index].1
        addChild(vc)
        let body = vc.view
        body.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            body.topAnchor.constraint(equalTo: holder.topAnchor),
            body.widthAnchor.constraint(equalToConstant: vc.preferredContentSize.width),
            body.heightAnchor.constraint(equalToConstant: vc.preferredContentSize.height),
        ])
        heightConstraint?.constant = vc.preferredContentSize.height
    }
}
