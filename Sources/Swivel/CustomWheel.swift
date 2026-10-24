import AppKit
import Carbon

/// My Wheel: actions the user picks from every other menu, in their own order. It opens with its own key during a
/// drag (showing only the picked actions that fit the dragged files), or with a recorded shortcut and no drag.
@MainActor
enum CustomWheel {
    /// Menus whose items can go on My Wheel.
    nonisolated static let sources: [WheelMode] = [.convert, .tools, .actions, .apps, .codes]

    /// One picked action: the menu it comes from and its stable title there (the ID that menu's Customize saves).
    /// Stored as "convert/JPG", "tools/Compress", "apps/app.<id>".
    struct Ref: Hashable {
        let mode: WheelMode
        let title: String
        var id: String { mode.id + "/" + title }
        init(_ mode: WheelMode, _ title: String) { self.mode = mode; self.title = title }
        init?(id: String) {
            guard let slash = id.firstIndex(of: "/"), let mode = WheelMode(rawValue: String(id[..<slash])),
                  CustomWheel.sources.contains(mode) else { return nil }
            let title = String(id[id.index(after: slash)...])
            guard !title.isEmpty, title.count <= 200 else { return nil }
            self.init(mode, title)
        }
    }

    static var refs: [Ref] { Prefs.customWheelItems.compactMap(Ref.init(id:)) }

    /// Everything that can go on My Wheel now, in menu order. Tools that are off offer nothing.
    static func candidates() -> [Ref] {
        var seen = Set<Ref>(), result: [Ref] = []
        for mode in sources {
            let titles = mode == .apps || mode == .codes ? Catalog.defaultItems(for: [], mode: mode).map(\.title)
                                                         : FileKind.allCases.flatMap { Catalog.allItems(mode: mode, kind: $0) }
            for title in titles where seen.insert(Ref(mode, title)).inserted { result.append(Ref(mode, title)) }
        }
        return result
    }

    /// Whether any picked action still leads somewhere: an app target, preset or saved code that was removed (or a tool
    /// that is off) offers nothing, so My Wheel's key doesn't open an empty menu. Cheap checks first; a menu's full
    /// list is built only for the first plain title that needs it.
    static var hasUsablePick: Bool {
        var menus: [WheelMode: Set<String>] = [:]
        return refs.contains { ref in
            switch ref.mode {
            case .apps:
                return Feature.appRouting.isOn && Prefs.fileAppTargets.contains { $0.enabled && $0.actionID == ref.title }
            case .codes:
                return Feature.qrCodes.isOn && (ref.title == "QR Library" || Catalog.savedCodes().contains { "qr." + $0.id.uuidString == ref.title })
            default:
                if ref.title.hasPrefix("preset.") { return Prefs.imagePresets.contains { $0.actionID == ref.title } }
                if menus[ref.mode] == nil { menus[ref.mode] = Set(FileKind.allCases.flatMap { Catalog.allItems(mode: ref.mode, kind: $0) }) }
                return menus[ref.mode]?.contains(ref.title) == true
            }
        }
    }

    /// "Convert · JPG", for the settings list.
    static func label(_ ref: Ref) -> String { ref.mode.title + " · " + Catalog.displayTitle(ref.title) }

    /// My Wheel for these files: the picked actions that fit them, in the user's order. With no files (opened by the
    /// shortcut), every picked action that is available; one that needs files asks for them when it's chosen.
    static func items(for urls: [URL]) -> [WheelItem] {
        let picked = refs
        guard !picked.isEmpty else { return [] }
        if urls.isEmpty {
            let available = Set(candidates())
            return picked.filter(available.contains).compactMap(withoutFiles)
        }
        var menus: [WheelMode: [WheelItem]] = [:]
        return picked.compactMap { ref in
            if menus[ref.mode] == nil { menus[ref.mode] = Catalog.defaultItems(for: urls, mode: ref.mode) }
            return menus[ref.mode]?.first { $0.title == ref.title }
        }
    }

    private static func withoutFiles(_ ref: Ref) -> WheelItem? {
        // App actions ask for files themselves; saved codes and the QR Library need none.
        if ref.mode == .apps || ref.mode == .codes { return Catalog.defaultItems(for: [], mode: ref.mode).first { $0.title == ref.title } }
        return WheelItem(title: ref.title) { files in
            let chosen = files.isEmpty ? ToolUI.chooseFiles(folders: true) : files
            guard !chosen.isEmpty else { throw Cancelled() }
            // Which actions apply depends on the files, so look the action up again for the ones chosen.
            guard let item = Catalog.defaultItems(for: chosen, mode: ref.mode).first(where: { $0.title == ref.title }) else {
                throw ToolError(L("“%@” can’t be used with these files.", Catalog.displayTitle(ref.title)))
            }
            return try await item.perform(chosen)
        }
    }
}

/// A recorded keyboard shortcut: one key plus two modifiers (⌃⌥, ⌘⇧, ⌃⌘…), or a function key plus ⌘, ⌃ or ⌥ (Carbon
/// modifier bits, as RegisterEventHotKey and the system's symbolic hot keys use them). A global hot key takes its keys
/// from every app, so ⌘ or ⌃ with one key (⌘C, ⌘Q, ⌘Tab…) and ⌥ or ⌥⇧ (which type accented characters) are refused.
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// What the key showed when it was recorded ("M", "Space", "F5").
    var key: String

    static let allowedModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)
    var isValid: Bool {
        keyCode < 128 && modifiers & ~Self.allowedModifiers == 0 && Self.modifierProblem(modifiers, keyCode: keyCode) == nil &&
            !key.isEmpty && key.count <= 12 && !key.unicodeScalars.contains(where: AssistantDraft.isHidden)
    }

    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// Why these modifiers can't make a global shortcut with this key, or nil when they can.
    static func modifierProblem(_ modifiers: UInt32, keyCode: UInt32) -> String? {
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return L("Include ⌘, ⌃ or ⌥ in the shortcut.") }
        if functionKeys.contains(Int(keyCode)) { return nil }
        let option = UInt32(optionKey), shift = UInt32(shiftKey)
        if modifiers == option || modifiers == option | shift { return L("⌥ and ⇧ type special characters. Add ⌃ or ⌘ to the shortcut.") }
        if modifiers.nonzeroBitCount < 2 { return L("Apps use ⌘ or ⌃ with one key. Add another modifier, such as ⌃⌥ or ⌘⇧, or use a function key.") }
        return nil
    }

    var title: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + " " + key
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    private static let names: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The shortcut a key press makes, or why it can't be one.
    static func recorded(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> Result<KeyCombo, ToolError> {
        let modifiers = carbon(flags)
        if let problem = modifierProblem(modifiers, keyCode: UInt32(keyCode)) { return .failure(ToolError(problem)) }
        let key = names[Int(keyCode)] ?? (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let combo = KeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers, key: key)
        return combo.isValid ? .success(combo) : .failure(ToolError(L("This key can’t be used. Try a letter, number or function key.")))
    }

    func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown && !event.isARepeat && UInt32(event.keyCode) == keyCode && Self.carbon(event.modifierFlags) == modifiers
    }

    /// Whether another Swivel shortcut is set to the same keys, whether or not its tool is on now: turning that tool on
    /// later must not leave both shortcuts fighting over the keys (My Wheel's gives way).
    @MainActor var isUsedBySwivel: Bool {
        let controlOption = UInt32(controlKey | optionKey)
        if modifiers == controlOption, keyCode == Prefs.wheelShortcut.keyCode { return true }
        if modifiers == Prefs.quickShortcut.modifiers, keyCode == Prefs.quickShortcut.keyCode { return true }
        if modifiers == controlOption, keyCode == UInt32(kVK_ANSI_T) { return true }
        return false
    }
}

/// Registers My Wheel's shortcut and opens the clickable wheel with it.
@MainActor
final class CustomWheelLauncher {
    static let shared = CustomWheelLauncher()
    static let changed = Notification.Name("SwivelCustomWheelChanged")
    enum Status { case none, ready, reservedBySystem, usedBySwivel, unavailable }

    private let wheel = WheelController()
    private var hotKey: HotKey?
    private var localMonitor: Any?
    private var registered: (combo: KeyCombo, reserved: Bool, used: Bool)?
    private(set) var status = Status.none
    /// While a shortcut is being recorded the current one stays quiet, so pressing it again records it.
    var isRecording = false { didSet { sync() } }

    func sync() {
        guard Feature.wheel.isOn, !isRecording, let combo = Prefs.customWheelShortcut else {
            tearDown()
            update(.none)
            return
        }
        let reserved = SystemShortcuts.contains(code: combo.keyCode, modifiers: combo.modifiers, in: SystemShortcuts.current())
        let used = combo.isUsedBySwivel
        if let registered, registered.combo == combo, registered.reserved == reserved, registered.used == used, status != .unavailable { return }
        let wasHolding = hotKey != nil
        tearDown()
        registered = (combo, reserved, used)
        if reserved { update(.reservedBySystem); return }
        if used {
            update(.usedBySwivel)
            // The other shortcut may have failed to register while this one still held the keys: let it try again.
            if wasHolding { QuickActions.shared.syncSettings(); ShortcutWheel.shared.sync() }
            return
        }
        hotKey = HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in self?.show() }
        guard hotKey?.status == noErr else { update(.unavailable); return }
        // Also take the keys while Swivel itself has focus, as the tool wheel does.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isRecording, combo.matches(event), NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return event }
            self.show(); return nil
        }
        update(.ready)
    }

    private func tearDown() {
        hotKey?.unregister(); hotKey = nil; registered = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }

    private func update(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Opens My Wheel under the pointer (or closes it if it's open). With nothing picked yet, opens its settings.
    func show() {
        guard Feature.wheel.isOn else { return }
        if wheel.isVisible { wheel.dismiss(); return }
        let items = CustomWheel.items(for: [])
        guard !items.isEmpty else { CustomizePane.open(.custom); return }
        wheel.showClickable(items, mode: .custom)
    }
}

/// A button that records a shortcut: click, then press the keys (Esc cancels, clicking again stops).
@MainActor
final class ShortcutRecorder: NSStackView {
    private let button = NSButton(title: "", target: nil, action: nil)
    private let clear = NSButton(title: L("Clear"), target: nil, action: nil)
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// Says why a press wasn't taken, or nil when it was.
    var onProblem: ((String?) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 8
        button.bezelStyle = .push; clear.bezelStyle = .push
        button.target = self; button.action = #selector(toggle)
        clear.target = self; clear.action = #selector(clearShortcut)
        button.setAccessibilityLabel(L("Keyboard shortcut"))
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        addArrangedSubview(button); addArrangedSubview(clear)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    var isRecording: Bool { monitor != nil }

    func refresh() {
        button.title = isRecording ? L("Type a shortcut…") : Prefs.customWheelShortcut?.title ?? L("Record Shortcut")
        clear.isEnabled = !isRecording && Prefs.customWheelShortcut != nil
    }

    @objc private func toggle() { isRecording ? stop() : start() }

    private func start() {
        onProblem?(nil)
        CustomWheelLauncher.shared.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                // A click anywhere but this button ends recording (the button's own click toggles it).
                if event.window !== self.window || !self.button.frame.contains(self.convert(event.locationInWindow, from: nil)) { self.stop() }
                return event
            }
            // Only presses in the recorder's own window are taken; anything else ends recording and goes on its way.
            guard let window = self.window, event.window === window, window.isKeyWindow else { self.stop(); return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            switch KeyCombo.recorded(keyCode: event.keyCode, flags: event.modifierFlags, characters: event.charactersIgnoringModifiers) {
            case .success(let combo) where combo.isUsedBySwivel:
                self.onProblem?(L("Another Swivel shortcut uses these keys. Choose a different one."))
            case .success(let combo):
                self.stop()
                Prefs.customWheelShortcut = combo
            case .failure(let problem):
                self.onProblem?(problem.message)
            }
            return nil
        }
        // Switching to another window or app ends recording, so keys typed there are never swallowed.
        let center = NotificationCenter.default
        let end: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        observers = [center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: end)]
        if let window { observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: end)) }
        window?.makeFirstResponder(nil)
        refresh()
    }

    private func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        CustomWheelLauncher.shared.isRecording = false
        refresh()
    }

    @objc private func clearShortcut() { Prefs.customWheelShortcut = nil; onProblem?(nil) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, isRecording { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
}
