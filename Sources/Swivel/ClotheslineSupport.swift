import AppKit
import Carbon
import Quartz

// MARK: - Quick Look

/// An invisible key window that drives the shared Quick Look panel for long-press and force click.
///
/// Given a source frame, the preview grows out of the thing that was pressed and shrinks back into it; when that
/// thing has gone by the time Quick Look closes (the rope lifts), it fades instead. Closing hands focus back to the
/// app (or Swivel window) the user was in, so their keystrokes don't go to the invisible host.
@MainActor
final class QuickLooker: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLooker()
    private var url: URL?
    private var sourceFrame: (() -> NSRect?)?
    private var transitionImage: NSImage?
    private var previousApp: NSRunningApplication?
    private weak var previousKey: NSWindow?
    private lazy var host: NSWindow = {
        let window = QLHostWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.looker = self
        window.isReleasedWhenClosed = false
        return window
    }()

    func show(_ url: URL, from sourceFrame: (() -> NSRect?)? = nil, image: NSImage? = nil) {
        self.url = url
        self.sourceFrame = sourceFrame
        transitionImage = image
        // Remember where the user was, unless Quick Look is already up (then the first answer still holds).
        if !host.isVisible {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if let frontmost, frontmost != NSRunningApplication.current {
                previousApp = frontmost
                previousKey = nil
            } else {
                previousApp = nil
                previousKey = NSApp.keyWindow
            }
        }
        NSApp.activate()
        host.makeKeyAndOrderFront(nil)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// The panel let go of the host. Once it has really closed, put the host away and give focus back, unless
    /// the user has already clicked into another app.
    fileprivate func controlEnded() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true { return }
                self.sourceFrame = nil
                self.transitionImage = nil
                self.host.orderOut(nil)
                if NSApp.isActive {
                    if let app = self.previousApp, !app.isTerminated {
                        NSApp.yieldActivation(to: app)
                        app.activate(from: .current, options: [])
                    } else {
                        self.previousKey?.makeKey()
                    }
                }
                self.previousApp = nil
                self.previousKey = nil
            }
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        MainActor.assumeIsolated { sourceFrame?() ?? .zero }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                                  contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        MainActor.assumeIsolated { sourceFrame?() == nil ? nil : transitionImage }
    }
}

final class QLHostWindow: NSWindow {
    weak var looker: QuickLooker?
    override var canBecomeKey: Bool { true }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = looker
        panel.delegate = looker
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        looker?.controlEnded()
    }
}

// MARK: - Screenshot takeover

/// Points macOS screenshots at the clothesline folder and turns off the floating thumbnail,
/// remembering the user's own settings so they can be put back.
@MainActor
enum ScreenshotTakeover {
    private static let domain = "com.apple.screencapture" as CFString
    private static let session = ScreenshotSession(defaults: .standard, read: { key in
        CFPreferencesCopyAppValue(key as CFString, domain)
    }, write: { key, value in
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
    }, synchronize: { CFPreferencesAppSynchronize(domain) })

    static func enable(into folder: URL) {
        session.enable(into: folder)
    }
    static func isActive(into folder: URL) -> Bool { session.isActive(into: folder) }

    /// Where screenshots went before Swivel took over (the Desktop if the user never changed it).
    static var originalLocation: URL {
        session.originalLocation
    }

    static func restore() {
        session.restore()
    }
}

// MARK: - Global hotkey

/// Carbon registers individual shortcuts without monitoring or injecting keyboard events.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let identifier: UInt32
    private(set) var status: OSStatus = noErr
    private static var nextID: UInt32 = 1
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?

    init(keyCode: UInt32 = UInt32(kVK_ANSI_T), modifiers: UInt32 = UInt32(controlKey | optionKey),
         action: @escaping () -> Void) {
        identifier = Self.nextID
        Self.nextID += 1
        if Self.handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                      key.signature == OSType(0x5357_5654) else { return OSStatus(eventNotHandledErr) }
                let identifier = key.id
                DispatchQueue.main.async { HotKey.actions[identifier]?() }
                return noErr
            }, 1, &spec, nil, &Self.handler)
        }
        guard status == noErr else { return }
        let key = EventHotKeyID(signature: OSType(0x5357_5654), id: identifier)
        status = RegisterEventHotKey(keyCode, modifiers, key, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { Self.actions[identifier] = action }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        Self.actions.removeValue(forKey: identifier)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        let identifier = identifier
        DispatchQueue.main.async { HotKey.actions.removeValue(forKey: identifier) }
    }
}
