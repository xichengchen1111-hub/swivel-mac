import AppKit

/// Native file tools share focus, lifetime, feature gating and busy/error handling.
@MainActor
class FileToolWindow: NSObject, NSWindowDelegate {
    private static var open: [FileToolWindow] = []
    let feature: Feature
    let window: NSWindow
    private var observer: NSObjectProtocol?
    private(set) var isBusy = false
    private var lockedControls: [(NSControl, Bool)] = []

    init(feature: Feature, title: String, size: NSSize) {
        self.feature = feature
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = L(title); window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: min(740, size.width), height: min(560, size.height))
        window.toolbarStyle = .unified; window.level = .floating
        observer = NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.feature.isOn, !self.isBusy else { return }
                self.window.close()
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func install(_ view: NSView) {
        let material = NSVisualEffectView(); material.material = .windowBackground; material.blendingMode = .behindWindow
        window.contentView = material; ToolUI.embed(view, in: material)
    }
    func show() {
        guard feature.isOn else { return }
        Self.open.append(self)
        if NSApp.mainMenu == nil { NSApp.mainMenu = AppWindow.mainMenu() }
        window.center(); NSApp.activate(); window.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) { window.level = .normal }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isBusy }
    func windowWillClose(_ notification: Notification) { Self.open.removeAll { $0 === self }; ToolUI.didClose() }

    func runWork(_ body: @escaping @MainActor () async throws -> Void) {
        guard feature.isOn, !isBusy else { return }
        isBusy = true
        lockControls(window.contentView)
        Task { @MainActor in
            do { try await body(); Feedback.done() }
            catch {
                Feedback.refuse()
                let alert = NSAlert(error: error); await alert.beginSheetModal(for: window)
            }
            isBusy = false
            for (control, enabled) in lockedControls { control.isEnabled = enabled }
            lockedControls.removeAll(); workFinished()
            if !feature.isOn { window.close() }
        }
    }
    func workFinished() {}
    private func lockControls(_ view: NSView?) {
        if let control = view as? NSControl { lockedControls.append((control, control.isEnabled)); control.isEnabled = false }
        view?.subviews.forEach { lockControls($0) }
    }
}
