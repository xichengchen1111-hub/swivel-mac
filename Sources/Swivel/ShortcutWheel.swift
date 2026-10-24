import AppKit
import Carbon

enum WheelShortcut: String, CaseIterable {
    case space, j, w
    var title: String { switch self { case .space: "⌃⌥ Space"; case .j: "⌃⌥ J"; case .w: "⌃⌥ W" } }
    var keyCode: UInt32 { switch self { case .space: UInt32(kVK_Space); case .j: UInt32(kVK_ANSI_J); case .w: UInt32(kVK_ANSI_W) } }
    func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown && !event.isARepeat && UInt32(event.keyCode) == keyCode &&
        event.modifierFlags.intersection([.control, .option, .command, .shift]) == [.control, .option]
    }
}

/// Carbon registration can succeed for an input-source shortcut that macOS still consumes first.
/// Check the system's enabled symbolic shortcuts before reporting that a shortcut is ready.
enum SystemShortcuts {
    struct Key: Equatable { var code: UInt32; var modifiers: UInt32; var enabled: Bool }
    static func contains(code: UInt32, modifiers: UInt32, in keys: [Key]) -> Bool {
        keys.contains { $0.enabled && $0.code == code && $0.modifiers == modifiers }
    }
    @MainActor static func current() -> [Key] {
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr, let values = raw?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return values.compactMap { row in
            guard let code = row[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let modifiers = row[kHISymbolicHotKeyModifiers as String] as? NSNumber,
                  let enabled = row[kHISymbolicHotKeyEnabled as String] as? NSNumber else { return nil }
            return Key(code: code.uint32Value, modifiers: modifiers.uint32Value, enabled: enabled.boolValue)
        }
    }
}

@MainActor
final class ShortcutWheel {
    static let shared = ShortcutWheel()
    static let changed = Notification.Name("SwivelShortcutWheelChanged")
    private let wheel = WheelController()
    private var hotKey: HotKey?
    private var registered: WheelShortcut?
    private var localMonitor: Any?
    private(set) var available = true
    private(set) var reservedBySystem = false
    func sync() {
        guard Feature.wheel.isOn && Prefs.shortcutWheelEnabled else {
            hotKey?.unregister(); hotKey = nil; registered = nil
            if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
            wheel.dismiss(); return
        }
        let key = Prefs.wheelShortcut
        let reserved = SystemShortcuts.contains(code: key.keyCode, modifiers: UInt32(controlKey | optionKey), in: SystemShortcuts.current())
        if registered != key || reservedBySystem != reserved || (!reserved && !available) {
            hotKey?.unregister()
            hotKey = nil
            if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
            reservedBySystem = reserved
            if !reserved {
                hotKey = HotKey(keyCode: key.keyCode, modifiers: UInt32(controlKey | optionKey)) { [weak self] in self?.show() }
            }
            registered = key; available = !reserved && hotKey?.status == noErr
            if available {
                // Also accept ordinary AppKit key events while Swivel owns focus. Global Carbon
                // hotkeys consume their key event, so this fallback does not run a physical press twice.
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard key.matches(event), NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return event }
                    self?.show(); return nil
                }
            }
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }
    func show() {
        guard Feature.wheel.isOn, Prefs.shortcutWheelEnabled else { return }
        if wheel.isVisible { wheel.dismiss(); return }
        wheel.showClickable(items())
    }
    func items() -> [WheelItem] {
        var items: [WheelItem] = []
        for (feature, title) in [(Feature.batchRename, "Batch Rename"), (.pdfPages, "Arrange PDF Pages"), (.qrCodes, "Read QR Codes")] where feature.isOn {
            items.append(WheelItem(title: title) { _ in
                guard feature.isOn else { throw ToolError(L("This feature is turned off.")) }
                FileActionsPane.chooseAndOpen(feature); return ActionResult(message: "")
            })
        }
        if Feature.qrCodes.isOn {
            items.append(WheelItem(title: "QR Library") { _ in
                guard Feature.qrCodes.isOn else { throw ToolError(L("This feature is turned off.")) }
                QRLibraryWindow().show(); return ActionResult(message: "")
            })
        }
        if Feature.appRouting.isOn {
            items.append(WheelItem(title: "App Actions") { _ in
                guard Feature.appRouting.isOn else { throw ToolError(L("This feature is turned off.")) }
                let apps = Catalog.items(for: [], mode: .apps)
                if apps.isEmpty { AppWindow.shared.show(.appRouting) } else { self.wheel.showClickable(apps, mode: .apps) }
                return ActionResult(message: "")
            })
        }
        items.append(WheelItem(title: "Open Swivel…") { _ in AppWindow.shared.show(); return ActionResult(message: "") })
        return items
    }
}
