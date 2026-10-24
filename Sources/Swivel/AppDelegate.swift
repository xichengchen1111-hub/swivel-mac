import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let watcher = DragWatcher()
    private let wheel = WheelController()
    private var statusItem: NSStatusItem!
    private var lastReopen = Date.distantPast
    private weak var keepAwakeItem: NSMenuItem?
    private var launchToast: Toast { Toast.shared }
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill`, `killall` and logout send SIGTERM rather than asking AppKit to quit: quit normally, so screenshots
        // go back where they used to and temporary files are removed (applicationWillTerminate).
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        // Any local process can post a distributed notification, so a burst only brings the window forward once.
        DistributedNotificationCenter.default().addObserver(forName: AppInstance.reopen, object: Bundle.main.bundleIdentifier, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastReopen) > 2 else { return }
                self.lastReopen = Date()
                Clothesline.shared.reconcileScreenshotTakeover(); AppWindow.shared.show()
            }
        }
        setUpStatusItem()
        watcher.onKeyTap = { [weak self] mode in
            guard let self else { return }
            self.wheel.keyTapped(mode, urls: self.watcher.urls)
        }
        watcher.onDragEnd = { [weak self] in self?.wheel.dragEnded() }
        watcher.start()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            TrackpadActuator.refreshAfterWake()
            Clothesline.shared.reconcileScreenshotTakeover()
        }
        QuickActions.shared.syncSettings()
        ShortcutWheel.shared.sync()
        CustomWheelLauncher.shared.sync()
        Clothesline.shared.start()
        if ProcessInfo.processInfo.environment["SWIVEL_SHOW_ROPE"] != nil {  // for testing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Clothesline.shared.toggle() }
        }
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildMenu()
                QuickActions.shared.syncSettings()
                ShortcutWheel.shared.sync()
                CustomWheelLauncher.shared.sync()
            }
        }
        NotificationCenter.default.addObserver(forName: KeepAwake.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildMenu() }
        }

        // Opened by hand (Finder, Launchpad, Spotlight): show the window. Started at login: stay in the menu bar.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
        if atLogin {
            if Prefs.isEnabled { launchToast.show(L("Swivel is running — drag a file, then tap %@", Prefs.key(for: .convert).symbol), symbol: "circle.circle") }
        } else {
            // SWIVEL_TAB=<0-5> opens a specific page (for testing): general, shortcuts, style, customize, clothesline, overview.
            let tab = ProcessInfo.processInfo.environment["SWIVEL_TAB"].flatMap(Int.init).flatMap(AppWindow.Tab.init)
            AppWindow.shared.show(tab)
            if tab == nil { askAboutScreenshots() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Clothesline.shared.stop()
        TemporaryItems.removeAll()
    }
    func applicationDidBecomeActive(_ notification: Notification) { ShortcutWheel.shared.sync(); Clothesline.shared.reconcileScreenshotTakeover() }

    /// First launch: ask before redirecting screenshots.
    private func askAboutScreenshots() {
        guard !Prefs.clotheslineAsked else { return }
        Prefs.clotheslineAsked = true
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("Hang your screenshots on the clothesline?")
        alert.informativeText = L("""
            New screenshots will skip the desktop and hang on a rope under the menu bar. \
            Move the pointer to the top edge of the screen to lower it. The floating thumbnail is turned off while this is on; \
            your own settings come back if you turn it off or quit Swivel.
            """)
        alert.addButton(withTitle: L("Take Over Screenshots"))
        alert.addButton(withTitle: L("Not Now"))
        if alert.runModal() == .alertFirstButtonReturn {
            Prefs.clotheslineTakeover = true
            ScreenshotTakeover.enable(into: Clothesline.shared.incoming)
        }
    }

    /// Opening the app again while it runs brings up the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Clothesline.shared.reconcileScreenshotTakeover()
        AppWindow.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func setUpStatusItem() {
        // New items are added at the far left of the status area, which on notched Macs with a crowded
        // menu bar lands behind the notch. Start among the right-hand icons instead; ⌘-dragging the icon
        // later saves the user's own position under the same key.
        let positionKey = "NSStatusItem Preferred Position Swivel"
        if UserDefaults.standard.object(forKey: positionKey) == nil { UserDefaults.standard.set(330.0, forKey: positionKey) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Swivel"
        rebuildMenu()
    }

    /// Rebuilt whenever settings change, so the key names and option lists always match.
    private func rebuildMenu() {
        let wheelOn = Feature.wheel.isOn, ropeOn = Feature.clothesline.isOn
        let anyOn = Feature.allCases.contains { $0.isOn }
        watcher.isEnabled = wheelOn
        // A filled ring while Keep Awake holds the Mac awake, so it's visible without opening the menu.
        statusItem.button?.image = NSImage(systemSymbolName: !anyOn ? "circle.dashed" : KeepAwake.shared.isActive ? "circle.circle.fill" : "circle.circle",
                                           accessibilityDescription: "Swivel")
        statusItem.button?.appearsDisabled = !anyOn
        let keys = WheelMode.allCases.filter { Prefs.key(for: $0) != .off && ($0 != .custom || $0.isAvailable) }
            .map { "\(Prefs.key(for: $0).symbol) \($0.title)" }.joined(separator: " · ")
        var tip: [String] = []
        if wheelOn { tip.append(L("Wheel: drag a file, then tap %@", keys)) }
        if ropeOn { tip.append(L("Clothesline: move to the top edge, or press ⌃⌥T")) }
        if let awake = KeepAwake.shared.status { tip.append(awake) }
        statusItem.button?.toolTip = tip.isEmpty ? L(anyOn ? "Swivel — open the menu to use your enabled tools." : "Swivel — everything is off. Open this menu to turn a feature on.") : tip.joined(separator: "\n")

        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: L("Swivel"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        // Quick switches, one per feature.
        for (i, feature) in Feature.allCases.enumerated() {
            let item = add(to: menu, feature.title, #selector(toggleFeature(_:)))
            item.tag = i
            item.state = feature.isOn ? .on : .off
            item.image = NSImage(systemSymbolName: feature.symbol, accessibilityDescription: nil)
            item.toolTip = feature.blurb
        }

        if wheelOn {
            menu.addItem(.separator())
            let how = NSMenuItem(title: L("Wheel — drag a file, keep holding, then tap a key:"), action: nil, keyEquivalent: "")
            how.isEnabled = false
            menu.addItem(how)
            for (mode, title, symbol) in [(WheelMode.convert, "Convert formats", "arrow.triangle.2.circlepath"),
                                          (.tools, "File tools", "slider.horizontal.3"),
                                          (.actions, "File actions", "bolt"), (.apps, "App Actions", "arrow.up.forward.app"), (.codes, "QR Library", "qrcode")] {
                let item = NSMenuItem(title: "\(Prefs.key(for: mode).title) — \(L(title))", action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                item.submenu = Self.guide(for: mode)
                menu.addItem(item)
            }
            if !Prefs.customWheelItems.isEmpty {
                let key = Prefs.key(for: .custom), shortcut = Prefs.customWheelShortcut.map { "  " + $0.title } ?? ""
                let item = NSMenuItem(title: (key == .off ? L("My Wheel") : "\(key.title) — \(L("My Wheel"))") + shortcut,
                                      action: #selector(showMyWheel), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: WheelMode.custom.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            add(to: menu, L("Menu Style: %@…", Prefs.style.title), #selector(openStyle))

        }

        if Feature.shelf.isOn { add(to: menu, "Show Shelf", #selector(showShelf)) }
        if Feature.textCapture.isOn { add(to: menu, "Extract Text…", #selector(extractText)) }
        if Feature.imagePresets.isOn { add(to: menu, "Image Presets…", #selector(openPresets)) }
        if Feature.quickActions.isOn { add(to: menu, "Show Quick Actions", #selector(showQuickActions)) }
        if Feature.batchRename.isOn { add(to: menu, "Batch Rename…", #selector(batchRename)) }
        if Feature.pdfPages.isOn { add(to: menu, "PDF Pages…", #selector(pdfPages)) }
        if Feature.qrCodes.isOn { add(to: menu, "Read QR Codes…", #selector(readCodes)) }
        if Feature.qrCodes.isOn { add(to: menu, "QR Library…", #selector(openCodeLibrary)) }
        if Feature.wheel.isOn && Prefs.shortcutWheelEnabled { add(to: menu, "Show Tool Wheel", #selector(showToolWheel)) }
        if Feature.appRouting.isOn { add(to: menu, "App Actions…", #selector(appActions)) }
        if Feature.doctor.isOn { add(to: menu, "Mac Doctor…", #selector(openDoctor)) }
        if Feature.keepAwake.isOn {
            let item = NSMenuItem(title: keepAwakeTitle, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: KeepAwake.shared.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: nil)
            item.submenu = keepAwakeMenu()
            menu.addItem(item)
            keepAwakeItem = item
        }

        if ropeOn {
            menu.addItem(.separator())
            add(to: menu, "Show Clothesline", #selector(toggleRope), key: "t").keyEquivalentModifierMask = [.control, .option]
            add(to: menu, "Hang New Screenshots", #selector(toggleTakeover)).state = Prefs.clotheslineTakeover ? .on : .off
            add(to: menu, "Hang Copied Images", #selector(toggleHangCopied)).state = Prefs.clotheslineHangCopied ? .on : .off
        }

        menu.addItem(.separator())
        add(to: menu, "Haptic Feedback", #selector(toggleHaptics)).state = Prefs.haptics ? .on : .off
        add(to: menu, "Sound Effects", #selector(toggleSounds)).state = Prefs.soundEffects ? .on : .off
        menu.addItem(.separator())
        add(to: menu, "Feel & Text…", #selector(openFeel))
        add(to: menu, "Open Swivel…", #selector(openWindow), key: ",")
        add(to: menu, "Open at Login", #selector(toggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit Swivel"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    private var keepAwakeTitle: String { KeepAwake.shared.status.map { L("Keep Awake — %@", $0) } ?? L("Keep Awake") }

    /// The time left changes while the menu is closed; it's brought up to date as the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) { keepAwakeItem?.title = keepAwakeTitle }

    private func keepAwakeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        add(to: menu, "Off", #selector(stopKeepingAwake)).state = KeepAwake.shared.isActive ? .off : .on
        for (i, duration) in KeepAwake.durations.enumerated() {
            let item = NSMenuItem(title: KeepAwake.title(for: duration), action: #selector(keepAwake(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(to: menu, "Keep the Display On", #selector(toggleKeepAwakeDisplay)).state = Prefs.keepAwakeDisplay ? .on : .off
        return menu
    }

    @objc private func keepAwake(_ sender: NSMenuItem) {
        KeepAwake.shared.start(for: KeepAwake.durations[sender.tag])
        if let status = KeepAwake.shared.status { launchToast.show(status, symbol: "cup.and.saucer.fill") }
    }
    @objc private func stopKeepingAwake() { KeepAwake.shared.stop() }
    @objc private func toggleKeepAwakeDisplay() {
        Prefs.keepAwakeDisplay.toggle()
        KeepAwake.shared.refreshType()
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    /// One row per file kind listing exactly what that key's menu offers, in the user's order.
    private static func guide(for mode: WheelMode) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let kinds: [FileKind] = mode == .actions ? [.other] : [.image, .video, .audio, .pdf, .document, .archive, .other]
        for kind in kinds {
            let titles = Catalog.items(for: kind.sampleURLs, mode: mode).map { $0.displayTitle }
            guard !titles.isEmpty else { continue }
            let label = mode == .actions ? L("Any file or folder") : kind.title
            let item = NSMenuItem(title: "\(label):  \(titles.joined(separator: " · "))", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: mode == .actions ? "doc.on.doc" : kind.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let customize = NSMenuItem(title: L("Customize…"), action: #selector(AppDelegate.openCustomize), keyEquivalent: "")
        customize.target = NSApp.delegate
        menu.addItem(customize)
        return menu
    }

    @objc private func toggleFeature(_ sender: NSMenuItem) {
        let feature = Feature.allCases[sender.tag]
        feature.isOn.toggle()
        Feedback.toggle(feature.isOn)
        launchToast.show(L(feature.isOn ? "%@ is on" : "%@ is off", feature.title), symbol: feature.isOn ? feature.symbol : "circle.dashed")
    }

    @objc private func toggleHangCopied() { Prefs.clotheslineHangCopied.toggle() }
    @objc private func toggleHaptics() { Prefs.haptics.toggle() }
    @objc private func toggleSounds() { Prefs.soundEffects.toggle() }

    @objc private func openWindow() { AppWindow.shared.show(.overview) }
    @objc private func openFeel() { AppWindow.shared.show(.feel) }

    @objc private func openStyle() { AppWindow.shared.show(.style) }
    @objc fileprivate func openCustomize() { AppWindow.shared.show(.customize) }
    @objc private func toggleRope() { Clothesline.shared.toggle() }

    @objc private func toggleTakeover() {
        Prefs.clotheslineTakeover.toggle()
        if Prefs.clotheslineTakeover && Prefs.clotheslineEnabled { ScreenshotTakeover.enable(into: Clothesline.shared.incoming) } else { ScreenshotTakeover.restore() }
    }
    @objc private func extractText() {
        if let url = ToolUI.chooseFiles(imagesOnly: true, multiple: false).first { TextCaptureWindow.present(url) }
    }
    @objc private func openPresets() { AppWindow.shared.show(.imagePresets) }
    @objc private func showQuickActions() { QuickActions.shared.show() }
    @objc private func showShelf() { Shelf.shared.show() }
    @objc private func batchRename() { FileActionsPane.chooseAndOpen(.batchRename) }
    @objc private func pdfPages() { FileActionsPane.chooseAndOpen(.pdfPages) }
    @objc private func readCodes() { FileActionsPane.chooseAndOpen(.qrCodes) }
    @objc private func appActions() { AppWindow.shared.show(.appRouting) }
    @objc private func openDoctor() { DoctorWindow.present() }
    @objc private func openCodeLibrary() { QRLibraryWindow().show() }
    @objc private func showMyWheel() { CustomWheelLauncher.shared.show() }
    @objc private func showToolWheel() { ShortcutWheel.shared.show() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        rebuildMenu()
    }
}
