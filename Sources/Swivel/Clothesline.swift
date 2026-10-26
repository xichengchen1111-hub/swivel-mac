import AppKit
import UniformTypeIdentifiers
import AVFoundation
import ImageIO

/// A rope tucked under the menu bar.
///
/// New screenshots first appear as a card in the bottom-right corner, as macOS shows them. Drag the card up
/// (or click it) to hang it on the rope; leave it and it goes to your usual screenshot folder. Moving the
/// pointer to the screen's top edge lowers the rope, and every print can be clicked, opened or dragged away.
@MainActor
final class Clothesline: NSObject {
    static let shared = Clothesline()

    let folder: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Swivel Clothesline", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Where macOS writes screenshots while Swivel has taken them over; each one waits here as a card.
    lazy var incoming: URL = {
        let url = folder.appendingPathComponent("Incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private(set) var items: [URL] = []
    private var stitchedSources: [URL: FileIdentity] = [:] // originals stay on disk; hidden for this session only
    private var stitchTask: Task<Void, Never>?
    var isStitching: Bool { stitchTask != nil }

    func stitch(top: URL, bottom: URL) {
        guard Prefs.clotheslineEnabled, stitchTask == nil, top != bottom,
              items.contains(top), items.contains(bottom) else { return }
        let originalIDs = [top, bottom].reduce(into: [URL: FileIdentity]()) { ids, url in
            if let id = try? FileIdentity.read(url) { ids[url] = id }
        }
        Toast.shared.show("Stitching images…", symbol: "photo.on.rectangle", autoHide: false, spinning: true)
        stitchTask = Task { @MainActor in
            defer { stitchTask = nil }
            do {
                let output = try await Images.detached { try ImageStitch.save(top: top, bottom: bottom) }
                // A completed file is always kept, even if the feature was turned off at the last instant.
                if Prefs.clotheslineEnabled, !Task.isCancelled {
                    stitchedSources.merge(originalIDs) { _, new in new }
                    panel.rope.markNew(output, arrival: .inPlace)
                    reload()
                    show(force: true)
                    if !pinned { leftSince = Date().addingTimeInterval(2.2) }
                }
                Feedback.done()
                Toast.shared.show(L("Saved %@", output.lastPathComponent), symbol: "checkmark.circle.fill", files: [output])
            } catch is CancellationError {
                Toast.shared.hide()
            } catch {
                Feedback.refuse()
                Toast.shared.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .systemRed)
            }
        }
    }

    private(set) var panel = RopePanel()
    private var watches: [DispatchSourceFileSystemObject] = []
    private var settingsObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private(set) var isRunning = false
    private var hoverTimer: Timer?
    private var monitors: [Any] = []
    private var wasAtTopEdge = false
    private var pressedAt: NSPoint?        // where the current click started, for telling a click from a drag
    private var leftSince: Date?
    private var pinned = false              // shown with the hotkey: stays until toggled or clicked away
    private var pasteboardCount = NSPasteboard.general.changeCount
    private var hotKey: HotKey?
    private var seenIncoming: Set<String> = []
    /// Files dropped on the rope whose move runs on the next turn of the run loop, so the card can tell it was hung.
    private var taking: Set<URL> = []
    /// A print is being dragged off the rope (or its context menu is open): the rope stays down.
    var isDraggingItem: Bool { panel.rope.isDraggingItem }
    /// Something is being dragged toward the rope.
    private(set) var isReceiving = false { didSet { panel.rope.isReceiving = isReceiving } }

    static let mediaExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp", "mov", "mp4"]

    func start() {
        guard !isRunning else { return }
        isRunning = true
        reload()
        // Anything left waiting from last time goes where screenshots normally go.
        for url in mediaFiles(in: incoming) { IncomingCard.shared.putAway(url) }
        watch(folder) { [weak self] in self?.reload() }
        watch(incoming) { [weak self] in self?.checkIncoming() }
        hotKey = HotKey { [weak self] in self?.toggle() }
        // The pointer is only watched while the feature is on, wherever the setting gets changed.
        settingsObserver = NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWatching(); self?.reconcileScreenshotTakeover() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown, !self.panel.rope.isLifting else { return }
                self.showing &+= 1
                self.confirmShown(self.showing, rebuilt: false)
            }
        }
        syncWatching()
        reconcileScreenshotTakeover()
    }
    func reconcileScreenshotTakeover() {
        guard isRunning, Prefs.clotheslineEnabled, Prefs.clotheslineTakeover else { return }
        ScreenshotTakeover.enable(into: incoming)
    }

    /// Turning the feature off puts the rope and any waiting card away, stops hanging copies and gives screenshots
    /// back to macOS.
    func setEnabled(_ on: Bool) {
        if !on { stitchTask?.cancel(); panel.rope.clearStitchTarget(); hide() }
        Prefs.clotheslineEnabled = on  // posts Prefs.changed, which starts or stops watching the pointer
        if on {
            if Prefs.clotheslineTakeover { ScreenshotTakeover.enable(into: incoming) }
        } else {
            ScreenshotTakeover.restore()
            putAwayWaiting(animated: true)
        }
        syncWatching()
    }

    /// Called on quit so the user's own screenshot settings come back, and nothing stays behind in the hidden
    /// Incoming folder: a card still up, one queued behind a drag, or one that arrived a moment ago.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        stitchTask?.cancel()
        panel.rope.clearStitchTarget()
        stopWatching()
        watches.forEach { $0.cancel() }; watches.removeAll()
        hotKey?.unregister(); hotKey = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver); self.settingsObserver = nil }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver); self.spaceObserver = nil }
        ScreenshotTakeover.restore()  // first, so a screenshot taken from here on goes straight to the usual folder
        putAwayWaiting(animated: false)
    }

    /// Everything waiting in Incoming goes where screenshots normally go, and the card leaves.
    private func putAwayWaiting(animated: Bool) {
        IncomingCard.shared.putAwayAll(animated: animated)
        for url in mediaFiles(in: incoming) { IncomingCard.shared.putAway(url, animated: false) }
        seenIncoming = []
    }

    // MARK: Watching the pointer

    /// The edge poll and the mouse monitors run only while the clothesline is on, so a switched-off tool doesn't
    /// wake Swivel for every pointer move on the system.
    private func syncWatching() {
        let on = Prefs.clotheslineEnabled
        if on && hoverTimer == nil {
            startWatching()
        } else if !on && hoverTimer != nil {
            stitchTask?.cancel()
            panel.rope.clearStitchTarget()
            stopWatching()
            if isShown && !panel.rope.isLifting { hide() }
        }
    }

    private func startWatching() {
        wasAtTopEdge = false
        pasteboardCount = NSPasteboard.general.changeCount  // what was copied while it was off isn't hung now
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        // Mouse monitors (no Accessibility permission needed) see the pointer reach the top edge or a print on the very
        // next event instead of the next poll, and see clicks that should put the rope away.
        let moved: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.pointerMoved() } }
        let clicked: (NSEvent) -> Void = { [weak self] event in
            let down = event.type == .leftMouseDown, window = event.window
            MainActor.assumeIsolated { self?.mouse(down: down, at: NSEvent.mouseLocation, in: window) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: moved) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in moved(event); return event }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: clicked) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: { event in clicked(event); return event }) {
            monitors.append(local)
        }
    }

    private func stopWatching() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        wasAtTopEdge = false
        pressedAt = nil
    }

    // MARK: Contents

    /// Newest first, by when each file arrived in the folder (falling back to its creation date): a copy keeps its
    /// original creation date, but it was hung just now, so it belongs at the front where the drop animation puts it.
    private func mediaFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files
            // Only plain files: a link or folder planted here would be previewed, opened and copied through.
            .filter { url in
                var info = stat()
                return Self.mediaExtensions.contains(url.pathExtension.lowercased())
                    && lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            }
            .map { url -> (URL, Date) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent < $1.0.lastPathComponent }
            .map(\.0)
    }

    func reload() {
        items = mediaFiles(in: folder).filter { url in
            guard let recorded = stitchedSources[url] else { return true }
            if (try? FileIdentity.read(url)) == recorded { return false }
            // A different file later reusing an original's name must still appear on the rope.
            stitchedSources.removeValue(forKey: url)
            return true
        }
        panel.rope.setItems(items)
        if items.isEmpty && !isReceiving { hide() }
    }

    /// Puts files on the rope: files waiting as a card are moved, anything else is copied. Returns where they
    /// landed. `thumbnails` (from the card) saves decoding the image again.
    @discardableResult
    func receive(_ urls: [URL], arrival: RopeView.Arrival = .fromAbove, thumbnails: [URL: CGImage] = [:]) -> [URL] {
        var landed: [URL] = []
        for url in urls where Self.mediaExtensions.contains(url.pathExtension.lowercased()) {
            let waiting = url.deletingLastPathComponent().standardizedFileURL == incoming.standardizedFileURL
                || IncomingCard.shared.takeSaved(url)
            let destination: URL
            do {
                // Each claims its name as it lands (never over a print that arrived meanwhile), even from another volume.
                destination = waiting ? try Paths.move(url, into: folder) : try Paths.copy(url, into: folder)
            } catch {
                // Nothing to hang for a file that didn't make it; a waiting screenshot still leaves Incoming.
                if waiting { IncomingCard.shared.putAway(url) }
                continue
            }
            panel.rope.markNew(destination, arrival: arrival, thumbnail: thumbnails[url])
            landed.append(destination)
        }
        taking.subtract(urls)
        reload()
        guard !landed.isEmpty else {
            Feedback.refuse()
            return []
        }
        show(force: true)
        if !pinned { leftSince = Date().addingTimeInterval(2.2) }  // stay down long enough to see it land
        return landed
    }

    /// From the ⌃ Actions menu.
    func hang(_ urls: [URL]) { receive(urls) }

    /// The rope accepted a drop of these files; the move follows on the next turn of the run loop.
    func take(_ urls: [URL]) { taking.formUnion(urls) }
    func isTaking(_ url: URL) -> Bool { taking.contains(url) }

    private func checkIncoming() {
        let decision = Self.triage(mediaFiles(in: incoming), seen: seenIncoming, showCard: Prefs.clotheslineEnabled)
        seenIncoming = decision.seen
        for url in decision.putAway { IncomingCard.shared.putAway(url, animated: false) }
        if let newest = decision.card { IncomingCard.shared.present(newest) }
    }

    /// What one look at Incoming (newest first) decides. The card shows one file at a time, so the newest new file
    /// gets it and every other new file goes straight to the usual screenshot folder (with two displays, one capture
    /// writes two files at once); with the clothesline off, they all do. Nothing new is left without a destination.
    static func triage(_ waiting: [URL], seen: Set<String>, showCard: Bool) -> (card: URL?, putAway: [URL], seen: Set<String>) {
        let fresh = waiting.filter { !seen.contains($0.lastPathComponent) }
        let card = showCard ? fresh.first : nil
        return (card, Array(fresh.dropFirst(card == nil ? 0 : 1)), Set(waiting.map(\.lastPathComponent)))
    }

    private func watch(_ directory: URL, _ changed: @escaping @MainActor () -> Void) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler {
            // Screenshots are written in a couple of steps; give the file a moment to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { MainActor.assumeIsolated { changed() } }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watches.append(source)
    }

    /// A small picture of an image or the first frame of a movie.
    /// Made on the main thread, so the picture is checked and scaled from one open source of at most `sourceLimit`
    /// pixels (a 48 MP photo fits): a tiny file claiming a gigantic picture would take seconds or minutes to scale.
    static func thumbnail(_ url: URL, maxPixels: Int, sourceLimit: Double = 60_000_000) -> CGImage? {
        guard ["mov", "mp4"].contains(url.pathExtension.lowercased()) else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  Images.claimedPixels(source).map({ $0 <= sourceLimit }) == true else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
        }
        return movieFrame(url, maxPixels: maxPixels)
    }

    /// A movie's first frame, decoded on another thread; the main thread waits at most `wait` seconds, so a crafted
    /// or slow movie leaves a plain print instead of freezing the rope.
    nonisolated static func movieFrame(_ url: URL, maxPixels: Int, wait: TimeInterval = 0.5) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: Video.openAsset(url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        final class Result: @unchecked Sendable { var image: CGImage? }
        let result = Result(), done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let unsafeGenerator = generator
        DispatchQueue.global(qos: .userInitiated).async {
            result.image = try? unsafeGenerator.copyCGImage(at: .zero, actualTime: nil)
            done.signal()
        }
        guard done.wait(timeout: .now() + wait) == .success else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        return result.image
    }

    /// Still the plain file that was listed: a link or folder put in its place since is never opened, previewed,
    /// copied or dragged out (the app on the other end would read what the link points at).
    nonisolated static func isPlainFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    // MARK: Showing and hiding

    var isShown: Bool { panel.isVisible }

    func toggle() {
        // Caught while it's still lifting, the shortcut brings it back instead of hiding it again.
        // A rope the window server isn't showing counts as hidden: pressing once must bring it back.
        if isShown && !panel.rope.isLifting && Self.reallyShown(panel) { hide() } else { pinned = true; show() }
    }

    func show(force: Bool = false) {
        guard Prefs.clotheslineEnabled else { return }
        // Believed down but not really on this screen and Space (see `confirmShown`): `lower` would see a visible
        // panel and do nothing, so the rope moves into a fresh panel first (even if there's nothing to lower now).
        var rebuilt = false
        if panel.isVisible, !panel.rope.isLifting, !panel.rope.isHandlingPrint, !Self.reallyShown(panel) {
            log.error("Rope was not on screen when asked to show; rebuilding its window: \(CardVisibility(self.panel).summary, privacy: .public)")
            rebuildPanel()
            rebuilt = true
        }
        guard force || !items.isEmpty else { return }
        guard let screen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main else { return }
        let moving = !panel.isVisible || panel.rope.isLifting
        panel.lower(on: screen)
        showing &+= 1
        confirmShown(showing, rebuilt: rebuilt, expectFrames: moving)
    }

    func hide() {
        pinned = false
        leftSince = nil
        // A panel the window server isn't showing may never get the frames that finish lifting it, and the next
        // lowering must not reuse it: swap in a fresh (hidden) one now.
        // (A lift in progress is left marked as lifting; the fresh panel's next lowering starts from hidden.)
        if panel.isVisible, !panel.rope.isHandlingPrint, !Self.reallyShown(panel) {
            log.error("Rope was not on screen when asked to hide; rebuilding its window: \(CardVisibility(self.panel).summary, privacy: .public)")
            rebuildPanel()
            return
        }
        panel.raise()
    }

    /// Counts lowerings and checks, so a check scheduled for an earlier one does nothing.
    private var showing = 0

    /// In long sessions the window server has stopped putting Swivel's panels on the current Space although they
    /// join all Spaces (2026-10-24 for the screenshot card; 2026-10-26 for the rope: screenshots were hung but the
    /// rope never appeared until Swivel was restarted). A moment after each lowering, and when the Space changes,
    /// the rope checks it really is on screen and animating; if not, it logs what it found and moves into a new
    /// panel (or gets a new display link), once. A print being held or dragged off waits until it's let go.
    func confirmShown(_ generation: Int, rebuilt: Bool, expectFrames: Bool = false, framesSince: Int? = nil) {
        let framesBefore = framesSince ?? panel.rope.frames
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkSeconds) { [weak self] in
            guard let self, self.isRunning || Self.checksWhileStopped, self.showing == generation, self.isShown,
                  !self.panel.rope.isLifting, !NSApp.isHidden else { return }
            if self.panel.rope.isHandlingPrint {
                self.confirmShown(generation, rebuilt: rebuilt, expectFrames: false)
                return
            }
            let state = CardVisibility(self.panel)
            if Self.reallyShown(self.panel) {
                if expectFrames, self.panel.rope.frames == framesBefore {
                    // A busy main thread can run this before the first frame: look once more before acting.
                    guard framesSince != nil else {
                        self.confirmShown(generation, rebuilt: rebuilt, expectFrames: true, framesSince: framesBefore)
                        return
                    }
                    log.error("Rope is on screen but drew no frames; restarting its display link: \(state.summary, privacy: .public)")
                    self.panel.rope.restartFrames()
                } else if rebuilt {
                    log.notice("Rope recovered in a new window: \(state.summary, privacy: .public)")
                }
                return
            }
            guard !rebuilt else {
                log.fault("Rope still not on screen after rebuilding its window: \(state.summary, privacy: .public)")
                return
            }
            log.error("Rope was not on screen; rebuilding its window: \(state.summary, privacy: .public)")
            let screen = self.panel.screen ?? self.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
            self.rebuildPanel()
            if let screen { self.panel.lower(on: screen) }
            self.showing &+= 1
            self.confirmShown(self.showing, rebuilt: true, expectFrames: true)
        }
    }
    static let checkSeconds: TimeInterval = 0.4
    /// Tests run the checks without starting the clothesline's watchers.
    static var checksWhileStopped = false

    /// On screen (as the window server lists it) and on the Space the user is looking at. While Swivel itself is
    /// hidden nothing is on screen and nothing needs fixing. Tests replace it.
    static var reallyShown: (NSWindow) -> Bool = { panel in
        if NSApp.isHidden { return true }
        let state = CardVisibility(panel)
        return state.isShown && state.activeSpace
    }

    /// Moves the rope, with its prints, into a fresh panel. The new panel starts hidden; `lower` brings it in.
    func rebuildPanel() {
        let old = panel
        let rope = old.rope
        old.orderOut(nil)
        old.contentView = nil
        panel = RopePanel(rope: rope)
        old.close()
    }

    /// A card is being dragged: lower the rope and keep it down until the drag ends.
    func beginReceiving() {
        isReceiving = true
        show(force: true)
    }

    func endReceiving() {
        isReceiving = false
        // A drop may already have asked to stay down for the landing; don't cut that short.
        let now = Date()
        leftSince = max(leftSince ?? now, now)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
    }

    /// From the mouse monitors, which only exist while the feature is on.
    private func pointerMoved() {
        checkTopEdge(NSEvent.mouseLocation)
        // The rope's frame loop rests while nothing moves; a pointer arriving on or leaving a print wakes it.
        if isShown { panel.rope.pointerMoved() }
    }

    /// Touching the edge reveals immediately. Moving away rearms it, so a menu-bar click or the hide shortcut can
    /// dismiss the rope without it reopening in place.
    private func checkTopEdge(_ point: NSPoint) {
        guard let screen = screen(containing: point) else { return }
        let atTopEdge = point.y >= screen.frame.maxY - 2
        let reachedTopEdge = atTopEdge && !wasAtTopEdge
        wasAtTopEdge = atTopEdge
        if reachedTopEdge && NSEvent.pressedMouseButtons & 1 == 0
            && (!isShown || panel.rope.isLifting || !Self.reallyShown(panel)) {
            show()
        }
    }

    /// Pressing in the menu bar puts the rope away at once. A pinned rope also goes when the user clicks away from
    /// the prints, on the release, and only for a click: a drag that starts elsewhere may be bringing a file to it.
    private func mouse(down: Bool, at point: NSPoint, in window: NSWindow?) {
        // A click on the screenshot card is the card's own (it hangs the screenshot), not a click away from the rope.
        guard isShown, !panel.rope.isLifting, !isDraggingItem, !isReceiving, !IncomingCard.shared.owns(window),
              let screen = screen(containing: point) else {
            pressedAt = nil
            return
        }
        if down {
            pressedAt = point
            if point.y >= screen.frame.maxY - menuBarHeight(screen) { hide() }
        } else if let start = pressedAt {
            pressedAt = nil
            if pinned, hypot(point.x - start.x, point.y - start.y) < 5, !panel.rope.isNear(screenPoint: start) { hide() }
        }
    }

    private func tick() {
        guard Prefs.clotheslineEnabled else {
            wasAtTopEdge = false
            if isShown { hide() }
            return
        }
        checkPasteboard()
        let point = NSEvent.mouseLocation
        checkTopEdge(point)
        guard isShown, let screen = screen(containing: point) else { return }
        // The poll also catches what the monitors don't see, such as a drag from another app passing over a print.
        panel.rope.pointerMoved()
        let inMenuBar = point.y >= screen.frame.maxY - menuBarHeight(screen)

        if isDraggingItem || isReceiving { return }
        // Clicking the menu bar puts the rope away (the click monitors usually got there first).
        if inMenuBar && NSEvent.pressedMouseButtons & 1 != 0 { hide(); return }
        if pinned { return }
        let inStrip = point.y >= panel.frame.minY - 8 && point.x >= panel.frame.minX && point.x <= panel.frame.maxX
        let delay = RopeTuning.hideDelay(overPrint: panel.rope.isOverPrint(screenPoint: point), inMenuBar: inMenuBar,
                                         nearPrints: panel.rope.isNear(screenPoint: point), inStrip: inStrip)
        guard let delay else {
            if let left = leftSince, left > Date() { return }  // still showing off a new arrival
            leftSince = nil
            return
        }
        if leftSince == nil { leftSince = Date() }
        if Date().timeIntervalSince(leftSince!) > delay { hide() }
    }

    // MARK: Copied images

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardCount else { return }
        pasteboardCount = pasteboard.changeCount
        guard Prefs.clotheslineHangCopied, let types = pasteboard.types else { return }
        // Only bare images: skip anything copied with text or files, anything marked private or generated by an app,
        // and Swivel's own copies.
        let skip: Set<NSPasteboard.PasteboardType> = [.string, .fileURL, .URL, .rtf, .html, Self.ownCopyType,
                                                      .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
                                                      .init("org.nspasteboard.AutoGeneratedType")]
        guard types.allSatisfy({ !skip.contains($0) }), Self.isSmallEnough(pasteboard, types: types),
              let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        // Lands in Incoming, so it shows up as a card like a screenshot. It is marked as a copy: left alone, the card
        // is discarded rather than saved where screenshots go (the image is still on the clipboard).
        guard let file = try? Paths.create(png, at: incoming.appendingPathComponent("Copied \(formatter.string(from: Date())).png")) else { return }
        _ = setxattr(file.path, Self.copiedMarker, "1", 1, 0, XATTR_NOFOLLOW)
    }

    /// Copied images are decoded on the main thread, so a huge one (another app can put anything on the clipboard)
    /// is left alone: its size is read from the header first, and an image whose size can't be read isn't hung.
    nonisolated static let maxCopiedPixels = 64_000_000.0
    nonisolated static func isSmallEnough(_ pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        for type in types {
            guard let data = pasteboard.data(forType: type), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Double,
                  let height = properties[kCGImagePropertyPixelHeight] as? Double else { continue }
            return width * height <= maxCopiedPixels
        }
        return false
    }

    /// Marks pasteboard contents Swivel wrote itself, so they aren't hung as copied images.
    nonisolated static let ownCopyType = NSPasteboard.PasteboardType("local.swivel.own-copy")
    nonisolated static let copiedMarker = "local.swivel.copied-image"
    nonisolated static func isCopiedImage(_ url: URL) -> Bool {
        getxattr(url.path, copiedMarker, nil, 0, 0, XATTR_NOFOLLOW) > 0
    }

    // MARK: Item actions

    func copy(_ url: URL) {
        guard Self.isPlainFile(url) else { return reload() }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([Self.pasteboardItem(for: url)])
        pasteboardCount = pasteboard.changeCount  // don't re-hang our own copy
        // Confirmed where the user is looking (on the print), with the name at the bottom of the screen.
        panel.rope.confirmCopy(url)
        Feedback.done()
        Toast.shared.show(L("Copied %@", url.lastPathComponent), symbol: "doc.on.doc")
    }

    /// One clipboard item for a print: the file, plus its picture for apps that paste images rather than files. Two
    /// separate items (the file and an NSImage) made chat apps send two attachments: the file and a large TIFF.
    /// `maxBytes` bounds the picture's bytes read into memory; past it only the file reference is copied.
    nonisolated static func pasteboardItem(for url: URL, maxBytes: Int64 = 256_000_000) -> NSPasteboardItem {
        pasteboardItem(for: url, maxBytes: maxBytes, read: nil)
    }

    /// Several files, with at most `totalBytes` of pictures among them (dozens of large images would otherwise all be
    /// read into memory at once); the rest are copied as references only.
    nonisolated static func pasteboardItems(for urls: [URL], totalBytes: Int64 = 512_000_000) -> [NSPasteboardItem] {
        var left = totalBytes
        return urls.map { url in
            var used: Int64 = 0
            let item = pasteboardItem(for: url, maxBytes: min(256_000_000, left), read: &used)
            left -= used
            return item
        }
    }

    private nonisolated static func pasteboardItem(for url: URL, maxBytes: Int64, read used: UnsafeMutablePointer<Int64>?) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        // Only the print's own regular file, never through a link, and not unbounded: checked and read on one descriptor.
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return item }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return item }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        // Read at most one byte past the limit, in case the file grew after fstat.
        guard maxBytes > 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) <= maxBytes,
              let data = try? handle.read(upToCount: Int(maxBytes) + 1), Int64(data.count) <= maxBytes,
              CGImageSourceCreateWithData(data as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) == true else { return item }
        used?.pointee = Int64(data.count)
        // The file's own bytes under its own type (a PNG screenshot is pasted as that PNG, not re-encoded).
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        // Apps that only take PNG or TIFF get PNG, made only if one of them asks.
        if type != .png, type != .tiff {
            item.setDataProvider(PNGOnDemand(data), forTypes: [.png])
        }
        return item
    }

    func openInPreview(_ url: URL) {
        guard Self.isPlainFile(url) else { return reload() }
        let isMovie = ["mov", "mp4"].contains(url.pathExtension.lowercased())
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: isMovie ? "com.apple.QuickTimePlayerX" : "com.apple.Preview")
        if let app { NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil) } else { NSWorkspace.shared.open(url) }
        // The rope leaves a beat later, so the eye catches the print's pulse first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.hide() }
    }

    /// Quick Look grows out of the print, and the rope lifts once it has started.
    func quickLook(_ url: URL) {
        guard Self.isPlainFile(url) else { return reload() }
        let rope = panel.rope
        let picture = rope.image(of: url).map { NSImage(cgImage: $0, size: NSSize(width: $0.width / 2, height: $0.height / 2)) }
        QuickLooker.shared.show(url, from: { [weak rope] in rope?.screenFrame(of: url) }, image: picture)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.hide() }
    }

    /// Thrown away: the print leaves the rope at once (falling, or shrinking away if it already went to the Trash
    /// as a drag) while the file goes to the Trash.
    func discard(_ url: URL, fall: Bool = true) {
        panel.rope.remove(url, falling: fall)
        NSWorkspace.shared.recycle([url]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.panel.rope.departed(url)
                self?.reload()
            }
        }
    }
}

// MARK: - Tuning

/// The clothesline's motion constants and the small pure helpers behind them, kept together so tests can hold them
/// to the owner's rule: gentle and well damped (damping ratio ≥ 0.6 for anything that swings or bounces), at most
/// two visible oscillations, settled within 1.5 s.
enum RopeTuning {
    /// A mass–spring pair integrated in fixed steps: stiffness `k` and damping `c` per unit mass.
    struct Oscillator {
        let k: CGFloat
        let c: CGFloat
        var dampingRatio: CGFloat { c / (2 * k.squareRoot()) }
        func tuned(_ tuning: MotionTuning) -> Self {
            let stiffness = k * tuning.safeSpeed * tuning.safeSpeed
            return Self(k: stiffness, c: 2 * stiffness.squareRoot() * tuning.damping(dampingRatio))
        }
    }

    static let fall = Oscillator(k: 260, c: 24)        // the whole rope lowering and lifting (ζ ≈ 0.74)
    static let sag = Oscillator(k: 150, c: 16)         // the cord's extra dip in the middle (ζ ≈ 0.65, was 0.37)
    static let swing = Oscillator(k: 34, c: 7.6)       // each print's pendulum on its peg (ζ ≈ 0.65, was 0.51)
    static let arrive = Oscillator(k: 200, c: 20)      // a new print settling onto the rope (ζ ≈ 0.71, was 0.57)
    static let sagCoupling: CGFloat = 0.05             // the cord lags behind the rope's acceleration
    /// Fixed physics step. Each display frame feeds its measured length through an accumulator, so the motion is
    /// the same at 60 or 120 Hz and a late frame doesn't slow it down.
    static let step: CGFloat = 1.0 / 240
    static let maxSteps = 8

    // Nudges, in rad/s: staggered as the rope lowers, trailing as it lifts, and for a new print.
    static let dropKick: ClosedRange<CGFloat> = 0.3...0.5
    static let liftKick: CGFloat = 0.25
    static let arrivalSwingFromAbove: ClosedRange<CGFloat> = 0.5...0.8
    static let arrivalSwingInPlace: ClosedRange<CGFloat> = 0.3...0.5
    static let arrivalHeight: CGFloat = -110           // hung from the menu: falls this far onto the rope

    /// The breeze blows while something happens and for this long after, then dies down (critically damped, over
    /// about two seconds), so a rope left down comes to rest and its frame loop can stop.
    static let breezeHold: CFTimeInterval = 3
    static let breezeFade: CGFloat = 1.2

    // Hover and press, as retargetable springs.
    static let lift = (response: CGFloat(0.34), damping: CGFloat(0.81))      // the old k = 340, c = 30
    static let pressIn = (response: CGFloat(0.1), damping: CGFloat(0.9))
    static let pressOut = (response: CGFloat(0.28), damping: CGFloat(0.8))
    static let slide = (response: CGFloat(0.4), damping: CGFloat(0.9))       // along the rope as a gap opens or closes
    static let fadeIn: CGFloat = 0.14, fadeOut: CGFloat = 0.1                 // opacity and colour (exits are faster)
    static let hoverLift: CGFloat = 6
    static let hoverScale: CGFloat = 0.025
    static let pressSink: CGFloat = 4                  // pressed, a print sinks back toward the rope…
    static let pressScale: CGFloat = 0.035             // …and gives a little (3.5 % from hovered)
    static let chargeScale: CGFloat = 0.03             // held toward Quick Look, it gathers again

    /// Semi-implicit Euler step toward `target`; returns the acceleration so the cord can follow the rope.
    @discardableResult
    static func advance(_ x: inout CGFloat, _ v: inout CGFloat, toward target: CGFloat, _ o: Oscillator,
                        force: CGFloat = 0, h: CGFloat = step) -> CGFloat {
        let a = -o.k * (x - target) - o.c * v + force
        v += a * h
        x += v * h
        return a
    }

    /// Holding a print: it gathers between 0.2 s and 0.55 s, then Quick Look opens.
    static let chargeStart: CFTimeInterval = 0.2, chargeEnd: CFTimeInterval = 0.55
    static func charge(heldFor t: CFTimeInterval) -> CGFloat {
        CGFloat(min(max((t - chargeStart) / (chargeEnd - chargeStart), 0), 1))
    }

    /// How long the rope waits before lifting, or nil to stay. Reaching along the rope for a print gets more time
    /// than leaving it, so it doesn't run away from the pointer on a wide screen.
    static func hideDelay(overPrint: Bool, inMenuBar: Bool, nearPrints: Bool, inStrip: Bool) -> TimeInterval? {
        if overPrint || inMenuBar { return nil }
        if nearPrints { return 1.5 }
        return inStrip ? 1.0 : 0.5
    }

    static let firstSlot: CGFloat = 76, spacing: CGFloat = 22
    static let maxPrint = CGSize(width: 168, height: 112)

    /// Prints hang left-aligned from `firstSlot`, `spacing` apart; `gap` opens room at the front for something about
    /// to be hung. Each print's centre, and whether it fits before the right edge.
    static func slots(widths: [CGFloat], in width: CGFloat, gap: CGFloat = 0) -> [(x: CGFloat, fits: Bool)] {
        var x = firstSlot + gap
        return widths.map { w in
            defer { x += w + spacing }
            return (x + w / 2, x + w < width - 40)
        }
    }

    /// A print's size for a picture of this aspect ratio, white border included.
    static func printSize(aspect: CGFloat) -> CGSize {
        let a = max(aspect, 0.05)
        let h = min(maxPrint.width / a, maxPrint.height)
        return CGSize(width: h * a + 10, height: h + 10)
    }

    /// The rope sags in a parabola, which one quadratic Bézier draws exactly (it used to be ~850 line segments
    /// rebuilt every frame on a 5K display).
    static func ropePath(width: CGFloat, y: CGFloat, sag: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -4, y: y))
        path.addLine(to: CGPoint(x: 0, y: y))
        path.addQuadCurve(to: CGPoint(x: width, y: y), control: CGPoint(x: width / 2, y: y + 2 * sag))
        path.addLine(to: CGPoint(x: width + 4, y: y))
        return path
    }

    /// A CSS-style cubic-Bézier timing curve at `t`, solved by bisection (monotonic for x1, x2 in 0…1).
    static func ease(_ t: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGFloat {
        let t = min(max(t, 0), 1)
        func curve(_ u: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u
        }
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if curve(mid, x1, x2) < t { lo = mid } else { hi = mid }
        }
        return curve((lo + hi) / 2, y1, y2)
    }
}

/// Draws into a bitmap at `scale` with both Core Graphics and AppKit (for text and symbols) available.
@MainActor
private func renderImage(_ size: NSSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
    guard size.width >= 1, size.height >= 1,
          let ctx = CGContext(data: nil, width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)),
                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

// MARK: - Panel

/// A full-width strip under the menu bar. It only catches the mouse over a print (or while something is being
/// dragged to it); everywhere else clicks fall through to the windows below.
final class RopePanel: NSPanel {
    let rope: RopeView
    static let height: CGFloat = 214

    /// `rope` is passed in when the rope moves into a fresh panel (see `Clothesline.rebuildPanel`), prints and all.
    init(rope: RopeView = RopeView()) {
        self.rope = rope
        super.init(contentRect: NSRect(x: 0, y: 0, width: 800, height: Self.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        contentView = rope
    }

    override var canBecomeKey: Bool { false }

    /// Lowers the rope. Caught while it's still lifting, it turns around where it is instead of starting over.
    func lower(on screen: NSScreen) {
        if isVisible && !rope.isLifting { return }
        let frame = NSRect(x: screen.frame.minX, y: screen.visibleFrame.maxY - Self.height, width: screen.frame.width, height: Self.height)
        let fromHidden = !isVisible || frame != self.frame
        if frame != self.frame { setFrame(frame, display: false) }
        rope.drop(fromHidden: fromHidden)  // lays out and draws at this width before the panel is seen
        if !isVisible { orderFrontRegardless() }
        rope.wake()
    }

    func raise() {
        guard isVisible else { return }
        rope.lift { [weak self] in self?.orderOut(nil) }
    }
}

// MARK: - Rope

/// Draws the rope and its prints with Core Animation layers, moved on every display frame by a small physics
/// model: the rope falls on a spring and sags, each print is a damped pendulum on its peg, and a light breeze
/// stirs them for a few seconds after anything happens. Hover, press and sliding along the rope are retargetable
/// springs. Everything is interruptible because the state is simulated, not tweened. Once nothing moves the frame
/// loop stops, and anything that changes the picture wakes it.
final class RopeView: NSView, NSDraggingSource {
    /// How a newly hung print appears.
    enum Arrival {
        case fromAbove   // hung from the Actions menu: drops onto the rope and swings a little
        case inPlace     // dropped on the rope: fades in where the drag image landed
        case handOff     // its card is flying up to it: hidden until `handOff(_:)`
    }

    private final class Print {
        let url: URL
        let layer = CALayer()
        let ring = CALayer()
        let close = CALayer()
        let peg = CALayer()
        let chip = CALayer()           // "Copied"
        var size: CGSize
        var image: CGImage?
        var photo: CGImage?
        var placed = false
        var slot = Spring(0, response: RopeTuning.slide.response, damping: RopeTuning.slide.damping)  // x along the rope
        var tilt: CGFloat = 0          // resting angle, so the line doesn't look ruled
        var angle: CGFloat = 0, angleV: CGFloat = 0
        var drop: CGFloat = 0, dropV: CGFloat = 0
        var lift = Spring(0, response: RopeTuning.lift.response, damping: RopeTuning.lift.damping)
        var hover = Spring(0, response: RopeTuning.fadeIn, damping: 1)       // ring, × and shadow
        var press = Spring(0, response: RopeTuning.pressIn.response, damping: RopeTuning.pressIn.damping)
        var opacity = Spring(1, response: RopeTuning.fadeIn, damping: 1)     // a ghost while dragged off; fades in on arrival
        var flash = Spring(0, response: 0.35, damping: 1)                     // the ring turns green after a copy
        var closePress = Spring(0, response: 0.08, damping: 1)
        var kickAt: CFTimeInterval?, kick: CGFloat = 0
        var awaitingSince: CFTimeInterval?     // its card is still flying here
        var lifted = false                     // being dragged away
        let phase = CGFloat.random(in: 0...(2 * .pi))

        var isTouchable: Bool { !layer.isHidden && awaitingSince == nil && !lifted }

        init(url: URL, size: CGSize) {
            self.url = url
            self.size = size
        }
    }

    private let root = CALayer()
    private let ropeLayer = CAShapeLayer()
    private let stitchLayer = CALayer()
    private let stitchHint = CALayer()
    private var stitchSpring = Spring(0, response: 0.25, damping: 0.85)
    private(set) var stitchIntent = RopeStitchIntent()
    private var stitchReady = false
    private var stitchSize = CGSize.zero

    private var prints: [Print] = []
    private var arrivals: [URL: Arrival] = [:]
    private var thumbnails: [URL: CGImage] = [:]      // handed over by the card so the print needn't decode again
    private var departing: Set<URL> = []              // already off the rope; reloads ignore them until the file goes
    private lazy var driver: FrameDriver = {
        let driver = FrameDriver(view: self)
        driver.onFrame = { [weak self] dt in self?.advance(dt) ?? false }
        return driver
    }()
    private var accumulator: CGFloat = 0
    private var clock: CFTimeInterval = 0

    // Rope state: vertical offset of the whole rope (falls in from above) and extra sag. A hidden rope stays hidden.
    private static let hiddenOffset = -(RopePanel.height + 30)
    private var offset: CGFloat = -RopePanel.height, offsetV: CGFloat = 0, offsetTarget: CGFloat = RopeView.hiddenOffset
    private var sag: CGFloat = 0, sagV: CGFloat = 0
    private var fade = Spring(1, response: 0.16, damping: 1)      // the panel's alpha; animates only under Reduce Motion
    private var highlight = Spring(0, response: 0.12, damping: 1) // something droppable is over the rope
    private var breeze = Spring(0, response: RopeTuning.breezeFade, damping: 1)  // the wind's strength, 0…1
    private var calmAt: CFTimeInterval = 0                        // when the breeze starts to die down
    private var drawnRope: [CGFloat] = []                         // what the rope's path was last built from
    private var insertGap: CGFloat = 0                            // room held open at the front for that drop
    private var onLifted: (() -> Void)?
    private(set) var isLifting = false
    private var hovered: URL?
    private var receivingHighlight = false
    // These change whether the panel catches the mouse, so they wake a resting frame loop.
    var isDraggingItem = false { didSet { if isDraggingItem != oldValue { wake() } } }  // a print is being dragged off (or its context menu is open)
    var isReceiving = false { didSet { if isReceiving != oldValue { wake() } } }        // a card is being dragged toward the rope
    /// For tests and frame renders: a pointer in view coordinates instead of the real mouse, and a fixed motion setting.
    var simulatedPointer: NSPoint?
    var reducedMotionOverride: Bool?
    private var isMotionReduced: Bool { reducedMotionOverride ?? Motion.reduced }

    private static let ropeTop: CGFloat = 18
    private static let restSag: CGFloat = 16
    private static var ropeColor: NSColor { Prefs.clotheslineColors.rope.color }
    private var colorsObserver: NSObjectProtocol?
    private static let tilts: [CGFloat] = [0.018, -0.015, 0.012, -0.02, 0.015, -0.012]

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        ropeLayer.fillColor = nil
        ropeLayer.strokeColor = Self.ropeColor.cgColor
        ropeLayer.lineWidth = 2.6
        ropeLayer.lineCap = .round
        ropeLayer.shadowOpacity = 0.18
        ropeLayer.shadowRadius = 2
        ropeLayer.shadowOffset = CGSize(width: 0, height: 2)
        root.addSublayer(ropeLayer)
        stitchLayer.zPosition = 30
        stitchLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        stitchLayer.contentsScale = 2
        stitchLayer.borderWidth = 2
        stitchLayer.borderColor = NSColor.controlAccentColor.cgColor
        stitchLayer.cornerRadius = 3
        stitchLayer.shadowOpacity = 0.25
        stitchLayer.shadowRadius = 6
        stitchLayer.opacity = 0
        ropeLayer.addSublayer(stitchLayer)
        stitchHint.zPosition = 31
        stitchHint.contentsScale = 2
        stitchHint.opacity = 0
        ropeLayer.addSublayer(stitchHint)
        registerForDraggedTypes([.fileURL])
        colorsObserver = NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshColors() }
        }
    }

    deinit { if let colorsObserver { NotificationCenter.default.removeObserver(colorsObserver) } }

    private func refreshColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for print in prints { print.peg.backgroundColor = Prefs.clotheslineColors.peg.color.cgColor }
        CATransaction.commit()
        drawnRope = [] // colour changes must redraw a resting rope too
        render(reduced: isMotionReduced)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Contents

    func markNew(_ url: URL, arrival: Arrival = .fromAbove, thumbnail: CGImage? = nil) {
        arrivals[url] = arrival
        if let thumbnail { thumbnails[url] = thumbnail }
    }

    func setItems(_ urls: [URL]) {
        let urls = urls.filter { !departing.contains($0) }
        let wanted = Set(urls)
        if let target = stitchIntent.target, !wanted.contains(target) { clearStitchTarget() }
        let existing = Dictionary(prints.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        for print in prints where !wanted.contains(print.url) { retire(print) }
        var fresh: [Print] = []
        prints = urls.map { url in
            if let print = existing[url] { return print }
            let print = makePrint(url)
            fresh.append(print)
            return print
        }
        // A drop's gap closes as the new print takes its place.
        if !receivingHighlight { insertGap = 0 }
        layoutPrints()
        for print in fresh { arrive(print, arrivals[print.url]) }
        arrivals.removeAll()
        thumbnails.removeAll()
        // Place new layers now: otherwise one frame could show them at the origin before the frame loop runs.
        render(reduced: isMotionReduced)
        wake()
    }

    private func arrive(_ print: Print, _ arrival: Arrival?) {
        let reduced = isMotionReduced
        let sign: CGFloat = Bool.random() ? 1 : -1
        switch arrival {
        case .fromAbove? where !reduced:
            // Falls onto the rope, settles and swings a little.
            print.drop = RopeTuning.arrivalHeight
            print.angleV = CGFloat.random(in: RopeTuning.arrivalSwingFromAbove) * sign
        case .handOff?:
            print.awaitingSince = clock
        default:
            // Dropped in place, or a file that appeared some other way: it fades in where it hangs.
            if window?.isVisible == true {
                print.opacity.snap(0)
                print.opacity.target = 1
            }
            if arrival == .inPlace, !reduced { print.angleV = CGFloat.random(in: RopeTuning.arrivalSwingInPlace) * sign }
        }
    }

    private func layoutPrints(snap: Bool = false) {
        let slots = RopeTuning.slots(widths: prints.map(\.size.width), in: bounds.width, gap: insertGap)
        let reduced = isMotionReduced
        let instant = snap || reduced
        for (i, print) in prints.enumerated() {
            print.layer.isHidden = !slots[i].fits
            print.tilt = Self.tilts[i % Self.tilts.count]
            if reduced {
                print.angle = print.tilt  // no swing to a new resting angle
                print.angleV = 0
            }
            if instant || !print.placed {
                print.slot.snap(slots[i].x)
                print.placed = true
            } else {
                print.slot.target = slots[i].x
            }
        }
    }

    private func makePrint(_ url: URL) -> Print {
        let isMovie = ["mov", "mp4"].contains(url.pathExtension.lowercased())
        let thumb = thumbnails[url] ?? Clothesline.thumbnail(url, maxPixels: 400)
        let size = thumb.map { RopeTuning.printSize(aspect: CGFloat($0.width) / CGFloat(max($0.height, 1))) }
            ?? CGSize(width: 160, height: 110)
        let print = Print(url: url, size: size)
        print.photo = isMovie ? nil : thumb
        print.image = Self.renderPrint(thumb, size: size, movie: isMovie)

        let layer = print.layer
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0)  // hangs from the top centre
        layer.contents = print.image
        layer.contentsScale = 2
        layer.shadowOpacity = 0.32
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)

        // Neutral peg; shares its saved colour with the menu template.
        let peg = print.peg
        peg.frame = CGRect(x: size.width / 2 - 5, y: -14, width: 10, height: 28)
        peg.backgroundColor = Prefs.clotheslineColors.peg.color.cgColor
        peg.cornerRadius = 2.5
        peg.shadowOpacity = 0.18
        peg.shadowRadius = 1.5
        peg.shadowOffset = CGSize(width: 0, height: 1)
        peg.shadowPath = CGPath(roundedRect: peg.bounds, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        let spring = CALayer()
        spring.frame = CGRect(x: 0, y: 12, width: 10, height: 2)
        spring.backgroundColor = NSColor(white: 0.62, alpha: 1).cgColor
        peg.addSublayer(spring)
        layer.addSublayer(peg)

        // Ring and × fade with the hover spring instead of snapping on and off.
        print.ring.frame = layer.bounds.insetBy(dx: -2, dy: -2)
        print.ring.borderWidth = 2
        print.ring.cornerRadius = 4
        print.ring.borderColor = NSColor.controlAccentColor.cgColor
        print.ring.opacity = 0
        layer.addSublayer(print.ring)

        print.close.frame = Self.closeFrame(for: size)
        print.close.cornerRadius = 11
        print.close.backgroundColor = NSColor(white: 0.12, alpha: 0.85).cgColor
        let cross = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 7, y: 7)); path.addLine(to: CGPoint(x: 15, y: 15))
        path.move(to: CGPoint(x: 15, y: 7)); path.addLine(to: CGPoint(x: 7, y: 15))
        cross.path = path
        cross.strokeColor = NSColor.white.cgColor
        cross.lineWidth = 1.7
        cross.lineCap = .round
        print.close.addSublayer(cross)
        print.close.opacity = 0
        layer.addSublayer(print.close)

        print.chip.opacity = 0
        print.chip.contentsScale = 2
        layer.addSublayer(print.chip)

        // No implicit fade on insertion: arrivals animate themselves.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(layer)
        CATransaction.commit()
        return print
    }

    private static func renderPrint(_ thumb: CGImage?, size: CGSize, movie: Bool) -> CGImage? {
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let rect = CGRect(origin: .zero, size: size)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(.white)
        ctx.fillPath()
        ctx.interpolationQuality = .high
        if let thumb { ctx.draw(thumb, in: rect.insetBy(dx: 5, dy: 5)) }
        if movie {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 16, y: c.y - 16, width: 32, height: 32))
            ctx.setFillColor(.white)
            ctx.move(to: CGPoint(x: c.x - 5, y: c.y - 8)); ctx.addLine(to: CGPoint(x: c.x + 9, y: c.y)); ctx.addLine(to: CGPoint(x: c.x - 5, y: c.y + 8))
            ctx.closePath()
            ctx.fillPath()
        }
        return ctx.makeImage()
    }

    private func find(_ url: URL) -> Print? { prints.first { $0.url == url } }

    /// The print's picture, for Quick Look's zoom and the card's flight.
    func image(of url: URL) -> CGImage? { find(url)?.image }

    /// Where a print hangs right now in screen coordinates (unrotated), and its angle. Used to land the card's
    /// flight exactly on it, even while the rope is still settling.
    func landing(for url: URL) -> (rect: NSRect, angle: CGFloat)? {
        guard let window, let print = find(url), !print.layer.isHidden else { return nil }
        let x = print.slot.value
        let rect = NSRect(x: x - print.size.width / 2, y: ropeY(x) + 4 + print.drop, width: print.size.width, height: print.size.height)
        return (window.convertToScreen(convert(rect, to: nil)), print.angle)
    }

    /// The print's frame on screen while the rope is down; nil once it has gone (Quick Look then fades instead).
    func screenFrame(of url: URL) -> NSRect? {
        guard window?.isVisible == true, !isLifting, let print = find(url), let window else { return nil }
        let p = print.layer.position
        let rect = NSRect(x: p.x - print.size.width / 2, y: p.y, width: print.size.width, height: print.size.height)
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: Motion

    /// Lowers the rope. From fully hidden it falls in on its spring and the prints get a staggered nudge; caught
    /// while still lifting, it turns around from where it is and keeps its speed. Under Reduce Motion it fades in.
    func drop(fromHidden: Bool) {
        let reduced = isMotionReduced
        isLifting = false
        onLifted = nil
        offsetTarget = 0
        if fromHidden {
            offset = reduced ? 0 : -bounds.height
            offsetV = 0
            sag = 0
            sagV = 0
            accumulator = 0
            // A press whose mouse-up went elsewhere (Quick Look took focus) mustn't keep a print lit.
            downURL = nil
            handled = true
            for print in prints { print.press.snap(0) }
            layoutPrints(snap: true)
            if !reduced {
                for (i, print) in prints.enumerated() {
                    print.kickAt = clock + 0.12 + Double(i) * 0.045
                    print.kick = CGFloat.random(in: RopeTuning.dropKick) * (i % 2 == 0 ? 1 : -1)
                }
            }
            fade.snap(reduced ? 0 : 1)
            breeze.snap(reduced ? 0 : 1)  // already blowing as it comes down
        } else if reduced {
            offset = 0
            offsetV = 0
        }
        fade.target = 1
        stir()
        render(reduced: reduced)
    }

    /// Pulled back up; the prints trail a little behind. Under Reduce Motion it fades out where it is.
    func lift(_ done: @escaping () -> Void) {
        clearStitchTarget()
        isLifting = true
        onLifted = done
        if isMotionReduced {
            fade.target = 0
        } else {
            offsetTarget = Self.hiddenOffset
            for print in prints { print.angleV += CGFloat.random(in: -RopeTuning.liftKick...RopeTuning.liftKick) }
        }
        wake()
    }

    /// Starts the frame loop while the rope is on screen. It stops by itself once nothing moves (see `needsFrames`)
    /// or the rope is put away, so everything that changes what the rope shows calls this.
    func wake() {
        stir()
        if window?.isVisible == true { driver.start() }
    }

    /// A display link belongs to the window it was made for; moved into a fresh panel, the rope makes a new one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        driver.stop()
    }

    /// Display frames drawn so far, so the clothesline can tell a rope that is on screen but never animates.
    private(set) var frames = 0
    /// A print is held or being dragged off: moving the rope to a new panel now would drop the gesture. A press
    /// counts only while the button is down: its mouse-up can go elsewhere (Quick Look takes focus), and a stale
    /// press must not hold off recovery for good.
    var isHandlingPrint: Bool { isDraggingItem || (downURL != nil && NSEvent.pressedMouseButtons & 1 != 0) }
    /// Replaces the frame loop's display link and runs it again.
    func restartFrames() {
        driver.stop()
        wake()
    }

    /// Something happened: the breeze blows for a little while, then dies down.
    private func stir() { calmAt = clock + RopeTuning.breezeHold }

    /// The pointer moved (or the controller's poll came round). The frame loop may be resting, so wake it when the
    /// print under the pointer has changed: hover, the ring, the × and mouse catching then follow.
    func pointerMoved() {
        guard window?.isVisible == true, !driver.isRunning, pointerChangesHover else { return }
        wake()
    }

    /// Whether a frame now would hover a different print (or none).
    var pointerChangesHover: Bool { hoverTarget() != hovered }

    /// Whether anything on the rope is still moving or about to, so the frame loop must keep running. A rope left
    /// down comes to rest once the breeze has died down; under Reduce Motion, as soon as it has faded in.
    var needsFrames: Bool {
        let reduced = isMotionReduced
        let charging = downURL != nil && !handled && !closeDown   // a held print gathers toward Quick Look
        let blowing = !reduced && (clock < calmAt || !breeze.isSettled)
        if isLifting || charging || blowing || !fade.isSettled || !highlight.isSettled
            || !stitchSpring.isSettled || (stitchIntent.target != nil && !stitchReady) { return true }
        let still: CGFloat = 0.01   // points (and points per second): well below a pixel
        if abs(offset - offsetTarget) > still || abs(offsetV) > still || abs(sag) > still || abs(sagV) > still { return true }
        return prints.contains { print in
            print.kickAt != nil || print.awaitingSince != nil
                || !(print.slot.isSettled && print.lift.isSettled && print.hover.isSettled && print.press.isSettled
                     && print.opacity.isSettled && print.flash.isSettled && print.closePress.isSettled)
                || abs(print.angle - rest(of: print, reduced: reduced)) > 1e-4 || abs(print.angleV) > 1e-3
                || abs(print.drop) > still || abs(print.dropV) > still
        }
    }

    /// The angle a print hangs at: its own little tilt, or straight while hovered. Under Reduce Motion it keeps its
    /// tilt, since straightening would turn it.
    private func rest(of print: Print, reduced: Bool) -> CGFloat {
        print.url == hovered && !reduced ? 0 : print.tilt
    }

    func ropeY(_ x: CGFloat) -> CGFloat {
        let t = bounds.width > 0 ? min(max(x / bounds.width, 0), 1) : 0.5
        return Self.ropeTop + offset + (Self.restSag + sag) * 4 * t * (1 - t)
    }

    /// One display frame: physics in fixed steps, springs by the frame's measured length, then the layers.
    /// Returns false once there is nothing left on screen to animate.
    @discardableResult
    func advance(_ dt: CGFloat) -> Bool {
        frames &+= 1
        let reduced = isMotionReduced
        updateHover(reduced: reduced)
        let ready = stitchIntent.ready(at: CACurrentMediaTime())
        if ready != stitchReady {
            stitchReady = ready
            if ready { Feedback.hover(sound: false); setStitchHint("Release to stitch · Originals kept") }
        }
        if reduced { stitchSpring.snap(stitchSpring.target) }
        else { stitchSpring.step(dt, tuning: Prefs.interaction.clothesline) }
        if reduced {
            breeze.snap(0)
        } else {
            breeze.target = clock < calmAt ? 1 : 0
            breeze.step(dt, tuning: Prefs.interaction.clothesline)
        }
        accumulator = min(accumulator + dt, RopeTuning.step * CGFloat(RopeTuning.maxSteps))
        while accumulator >= RopeTuning.step {
            physics(RopeTuning.step, reduced: reduced)
            accumulator -= RopeTuning.step
        }
        for print in prints {
            print.slot.step(dt, tuning: Prefs.interaction.clothesline)
            print.lift.step(dt, tuning: Prefs.interaction.clothesline)
            print.hover.step(dt, tuning: Prefs.interaction.clothesline)
            print.press.step(dt, tuning: Prefs.interaction.clothesline)
            print.opacity.step(dt, tuning: Prefs.interaction.clothesline)
            print.flash.step(dt, tuning: Prefs.interaction.clothesline)
            print.closePress.step(dt, tuning: Prefs.interaction.clothesline)
            // A hand-off that never comes (the flight was cut short) mustn't leave a hole in the rope.
            if let since = print.awaitingSince, clock - since > 1.2 { reveal(print) }
        }
        fade.step(dt, tuning: Prefs.interaction.clothesline)
        highlight.step(dt, tuning: Prefs.interaction.clothesline)
        render(reduced: reduced)
        updateMouseCatching()

        let raised = fade.target == 0 ? fade.value < 0.02 : offset < -bounds.height + 1
        if isLifting && raised {
            isLifting = false
            offset = -bounds.height
            offsetV = 0
            offsetTarget = Self.hiddenOffset
            let done = onLifted
            onLifted = nil
            done?()
            return false
        }
        // At rest the loop stops; a hover change, a press, a drop or an arrival wakes it again.
        return window?.isVisible == true && needsFrames
    }

    private func physics(_ h: CGFloat, reduced: Bool) {
        clock += Double(h)
        // Whole rope: a spring that overshoots a little and settles; the cord lags behind its acceleration, so it
        // dips once in the middle when the rope stops.
        let a = RopeTuning.advance(&offset, &offsetV, toward: offsetTarget, RopeTuning.fall.tuned(Prefs.interaction.clothesline), h: h)
        RopeTuning.advance(&sag, &sagV, toward: 0, RopeTuning.sag.tuned(Prefs.interaction.clothesline), force: -RopeTuning.sagCoupling * a, h: h)
        let t = CGFloat(clock)
        for print in prints {
            if let at = print.kickAt, clock >= at { print.angleV += print.kick; print.kickAt = nil }
            let rest = rest(of: print, reduced: reduced)
            if reduced {
                // Under Reduce Motion a print just hangs at its tilt: no swing on hover, arrival or reordering.
                print.angle = rest
                print.angleV = 0
            } else {
                // Pendulum on its peg, pulled toward its resting tilt (straight when hovered), plus a breeze.
                let wind = breeze.value * (0.07 * sin(1.1 * t + print.phase) + 0.03 * sin(2.7 * t + print.phase * 1.7))
                RopeTuning.advance(&print.angle, &print.angleV, toward: rest, RopeTuning.swing.tuned(Prefs.interaction.clothesline), force: wind, h: h)
            }
            RopeTuning.advance(&print.drop, &print.dropV, toward: 0, RopeTuning.arrive.tuned(Prefs.interaction.clothesline), h: h)
        }
    }

    /// The print hover should show: the one being pressed, or the one under the pointer.
    private func hoverTarget() -> URL? {
        if let held = downURL, !isDraggingItem { return held }  // a press keeps its print lit even if the pointer slips off it
        guard !isLifting, !isDraggingItem,
              let pointer = simulatedPointer ?? window.map({ convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) })
        else { return nil }
        return hit(pointer)?.url
    }

    private func updateHover(reduced: Bool) {
        let now = hoverTarget()
        if now != hovered {
            hovered = now
            stir()
            toolTip = now.map { $0.lastPathComponent + "\n" + L("Click: copy · Double-click: open · Hold: Quick Look · Drag: take it down") + "\n" + L("Drag onto another photo to stitch vertically.") }
        }
        for print in prints {
            let on = print.url == hovered
            print.hover.target = on ? 1 : 0
            print.hover.response = on ? RopeTuning.fadeIn : RopeTuning.fadeOut
            print.lift.target = on && !reduced ? -RopeTuning.hoverLift : 0
        }
    }

    private func render(reduced: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The cord (and its shadow) is rebuilt only when it has moved or changed colour, not for every print's hover.
        let ready = highlight.isSettled ? highlight.target : min(max(highlight.value, 0), 1)
        let shape = [bounds.width, offset, sag, ready]
        let reachedFeedbackTarget = highlight.isSettled && drawnRope.last != ready
        if shape.count != drawnRope.count || reachedFeedbackTarget || zip(shape, drawnRope).contains(where: { abs($0 - $1) > 0.005 }) {
            drawnRope = shape
            let path = RopeTuning.ropePath(width: bounds.width, y: Self.ropeTop + offset, sag: Self.restSag + sag)
            let width = 2.6 + 2.4 * ready
            ropeLayer.path = path
            ropeLayer.lineWidth = width
            // Blue means this drag can be released here, regardless of the chosen idle rope colour.
            ropeLayer.strokeColor = Self.ropeColor.mix(.systemBlue, ready).cgColor
            ropeLayer.shadowColor = NSColor.black.mix(.systemBlue, ready).cgColor
            ropeLayer.shadowOpacity = Float(0.18 + 0.22 * ready)
            ropeLayer.shadowRadius = 2 + 3 * ready
            // An explicit shadow path spares Core Animation an offscreen pass over the rope.
            ropeLayer.shadowPath = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        let now = CACurrentMediaTime()
        for print in prints {
            let p = print.hover.value, press = print.press.value
            var charge: CGFloat = 0
            if print.url == downURL, !handled, !closeDown {
                charge = max(RopeTuning.charge(heldFor: now - downTime), forceCharge)
            }
            let x = print.slot.value
            let sink = reduced ? 0 : RopeTuning.pressSink * press
            print.layer.position = CGPoint(x: x, y: ropeY(x) + 4 + print.lift.value + print.drop + sink)
            let scale = reduced ? 1 : 1 + RopeTuning.hoverScale * p - RopeTuning.pressScale * press + RopeTuning.chargeScale * charge
            print.layer.transform = CATransform3DScale(CATransform3DMakeRotation(print.angle, 0, 0, 1), scale, scale, 1)
            let stitching = print.url == stitchIntent.target ? min(max(stitchSpring.value, 0), 1) : 0
            print.layer.opacity = Float(print.awaitingSince == nil ? print.opacity.value * (1 - stitching) : 0)
            // Coming toward you on hover, pressed flat against the rope on mouse-down.
            print.layer.shadowRadius = max(6 + 3 * p - 4 * press, 1.5)
            print.layer.shadowOffset = CGSize(width: 0, height: max(4 + 3 * p - 2.5 * press, 1))
            print.layer.shadowOpacity = Float(0.32 + 0.06 * p - 0.08 * press)
            let ring = max(p, charge, print.flash.value)
            print.ring.opacity = Float(ring)
            if ring > 0.005 { print.ring.borderColor = NSColor.controlAccentColor.mix(.systemGreen, print.flash.value).cgColor }
            let shown = print.lifted ? 0 : p
            print.close.opacity = Float(shown)
            if shown > 0.005 {
                // It grows in and gives under the finger, except under Reduce Motion (the darker fill still shows a press).
                let s: CGFloat = reduced ? 1 : (0.85 + 0.15 * shown) * (1 - 0.12 * print.closePress.value)
                print.close.transform = CATransform3DMakeScale(s, s, 1)
                print.close.backgroundColor = NSColor(white: 0.12, alpha: 0.85 + 0.15 * print.closePress.value).cgColor
            }
            // Stays on top while it settles back, so it doesn't slip behind a neighbour mid-way.
            print.layer.zPosition = p > 0.05 || press > 0.01 ? 10 : 0
        }
        let join = min(max(stitchSpring.value, 0), 1)
        ropeLayer.zPosition = join > 0.001 ? 20 : 0
        stitchLayer.opacity = Float(join)
        stitchHint.opacity = Float(join)
        if let target = stitchIntent.target.flatMap(find) {
            let x = target.slot.value
            stitchLayer.bounds = CGRect(origin: .zero, size: stitchSize)
            stitchLayer.position = CGPoint(x: x + (reduced ? 0 : 12 * (1 - join)), y: ropeY(x) + 4)
            let scale: CGFloat = reduced ? 1 : 0.92 + 0.08 * join
            stitchLayer.transform = CATransform3DMakeScale(scale, scale, 1)
            stitchHint.position = CGPoint(x: x, y: ropeY(x) + stitchSize.height + 18)
        }
        if let window, abs(window.alphaValue - fade.value) > 0.001 { window.alphaValue = fade.value }
        CATransaction.commit()
    }

    /// Only catch the mouse where it matters, so the strip doesn't block the windows below.
    private func updateMouseCatching() {
        guard let window else { return }
        let ignore = hovered == nil && downURL == nil && !isReceiving && !isDraggingItem && !receivingHighlight
        if window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }

    /// The card has landed: its print appears with a small swing, the rope takes the weight, and the trackpad
    /// confirms it.
    func handOff(_ url: URL) {
        guard let print = find(url), print.awaitingSince != nil else { return }
        reveal(print)
        Feedback.press()
    }

    private func reveal(_ print: Print) {
        print.awaitingSince = nil
        if isMotionReduced {
            print.opacity.snap(0)
            print.opacity.target = 1
        } else {
            print.angleV = CGFloat.random(in: RopeTuning.arrivalSwingInPlace) * (Bool.random() ? 1 : -1)
            sagV += 40
        }
        render(reduced: isMotionReduced)
        wake()
    }

    /// Confirms a click-to-copy on the print itself: a "Copied" chip, the ring flashing green, a small nod.
    func confirmCopy(_ url: URL) {
        guard let print = find(url) else { return }
        let reduced = isMotionReduced
        print.flash.snap(1)
        print.flash.target = 0
        if !reduced { print.angleV += 0.25 }
        let text = L("Copied")
        if let image = Self.chipImage(text) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            print.chip.contents = image
            print.chip.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
            print.chip.position = CGPoint(x: print.size.width / 2, y: print.size.height)
            print.chip.zPosition = 1
            CATransaction.commit()
            // Rises into place over 0.12 s, holds, then fades out.
            let total: CFTimeInterval = 1.17
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, NSNumber(value: 0.12 / total), NSNumber(value: 0.92 / total), 1]
            fade.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
            let group = CAAnimationGroup()
            group.animations = [fade]
            if !reduced {
                let rise = CAKeyframeAnimation(keyPath: "transform.translation.y")
                rise.values = [4, 0, 0, 0]
                rise.keyTimes = fade.keyTimes
                rise.timingFunctions = fade.timingFunctions
                group.animations?.append(rise)
            }
            group.duration = total
            print.chip.add(group, forKey: "copied")
        }
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        wake()
    }

    private static func chipImage(_ text: String) -> CGImage? {
        let attrs: [NSAttributedString.Key: Any] = [.font: AppTypography.font(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold).applying(.init(paletteColors: [.white]))
        let mark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let markWidth = mark.map { $0.size.width + 4 } ?? 0
        let size = NSSize(width: (textSize.width + markWidth + 20).rounded(.up), height: 20 * Prefs.interaction.textSize.scale)
        return renderImage(size, scale: 2) { _ in
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 10, yRadius: 10).fill()
            var x: CGFloat = 10
            if let mark {
                mark.draw(in: NSRect(x: x, y: (size.height - mark.size.height) / 2, width: mark.size.width, height: mark.size.height))
                x += markWidth
            }
            (text as NSString).draw(at: NSPoint(x: x, y: (size.height - textSize.height) / 2), withAttributes: attrs)
        }
    }

    /// Takes a print off the rope now, before its file has gone: it falls (× clicked) or shrinks away (already
    /// dragged to the Trash). Its neighbours close the gap, and reloads ignore it until `departed(_:)`.
    func remove(_ url: URL, falling: Bool) {
        guard let index = prints.firstIndex(where: { $0.url == url }) else { return }
        let print = prints.remove(at: index)
        departing.insert(url)
        if hovered == url { hovered = nil }
        if !isMotionReduced { sagV -= 20 }  // the rope springs up a little as the weight leaves
        layoutPrints()
        if falling { letFall(print) } else { retire(print) }
        wake()
    }

    /// The file has gone, or couldn't be thrown away (then the next reload hangs it again).
    func departed(_ url: URL) { departing.remove(url) }

    /// Discarded: the print drops off the rope, turning a little, and fades on the way down.
    private func letFall(_ print: Print) {
        let layer = print.layer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.zPosition = 20
        print.close.opacity = 0
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let group = CAAnimationGroup()
        if isMotionReduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.opacity
            fade.toValue = 0
            group.animations = [fade]
            group.duration = 0.2
        } else {
            let fall = CABasicAnimation(keyPath: "position.y")
            fall.byValue = 240
            fall.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.byValue = print.angle > 0 ? 0.35 : -0.35
            // Falls first, fades late, so it reads as dropping rather than dissolving.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [layer.opacity, layer.opacity, 0]
            fade.keyTimes = [0, 0.45, 1]
            group.animations = [fall, spin, fade]
            group.duration = 0.42
        }
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "leave")
        CATransaction.commit()
    }

    /// Gone from the folder (moved away, deleted elsewhere): the print shrinks a little and fades where it hangs.
    private func retire(_ print: Print) {
        let layer = print.layer
        if hovered == print.url { hovered = nil }
        guard window?.isVisible == true, !layer.isHidden else {
            layer.removeFromSuperlayer()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.opacity
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade]
        if !isMotionReduced {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: layer.transform)
            shrink.toValue = NSValue(caTransform3D: CATransform3DScale(layer.transform, 0.92, 0.92, 1))
            group.animations?.append(shrink)
        }
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "leave")
        CATransaction.commit()
    }

    // MARK: Hit testing

    /// The × badge in its print's coordinates: centred on the top-right corner, so it reaches 9 pt past the edge.
    private static func closeFrame(for size: CGSize) -> CGRect { CGRect(x: size.width - 13, y: -9, width: 22, height: 22) }

    /// Where a press counts as on the ×: the badge and a little slack around it.
    private static func closeTarget(for size: CGSize) -> CGRect { closeFrame(for: size).insetBy(dx: -3, dy: -3) }

    private func hit(_ point: NSPoint) -> Print? {
        for print in prints.reversed() where print.isTouchable {
            let local = print.layer.convert(point, from: root)
            if print.layer.bounds.insetBy(dx: -4, dy: -14).contains(local) { return print }
            // While the × shows, all of it belongs to its print, so the part past the corner can be pointed at and
            // clicked. A hidden × doesn't widen the print.
            if print.url == hovered, Self.closeTarget(for: print.size).contains(local) { return print }
        }
        return nil
    }

    private func hitsClose(_ print: Print, _ point: NSPoint) -> Bool {
        Self.closeTarget(for: print.size).contains(print.layer.convert(point, from: root))
    }

    func isOverPrint(screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        return hit(convert(window.convertPoint(fromScreen: screenPoint), from: nil)) != nil
    }

    /// Around the prints: 60 pt either side of the visible ones, from the panel's bottom up to the top of the screen.
    func isNear(screenPoint: NSPoint) -> Bool {
        guard let window, window.isVisible, screenPoint.y >= window.frame.minY else { return false }
        let visible = prints.filter { !$0.layer.isHidden }
        guard let first = visible.first, let last = visible.last else { return false }
        let x = screenPoint.x - window.frame.minX
        return x >= first.slot.target - first.size.width / 2 - 60 && x <= last.slot.target + last.size.width / 2 + 60
    }

    // MARK: Gestures

    private var downEvent: NSEvent?
    private var downURL: URL?              // gestures follow the print, not its index, so a reload can't misdirect them
    private var downTime: CFTimeInterval = 0
    private var closeDown = false          // the press began on the ×
    private var forceCharge: CGFloat = 0
    private var longPress: DispatchWorkItem?
    private var singleClick: DispatchWorkItem?
    private var handled = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let print = hit(point), Feature.textCapture.isOn, FileKind.of(print.url) == .image else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: L("Extract Text"), action: #selector(extractPrintText(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = print.url
        menu.addItem(item)
        isDraggingItem = true
        defer { isDraggingItem = false }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func extractPrintText(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        Clothesline.shared.hide()
        TextCaptureWindow.present(url)
    }

    /// Pressed prints sink quickly; released, they spring back a little more slowly. The rope gives under the finger.
    private func setPressed(_ print: Print, _ on: Bool) {
        guard (print.press.target > 0) != on else { return }
        let tune = on ? RopeTuning.pressIn : RopeTuning.pressOut
        print.press.response = tune.response
        print.press.damping = tune.damping
        print.press.target = on ? 1 : 0
        if !isMotionReduced { sagV += on ? 5 : -3 }
        wake()
    }

    /// For tests and frame renders: shows a print pressed or released.
    func previewPress(_ url: URL, _ on: Bool) {
        if let print = find(url) { setPressed(print, on) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        longPress?.cancel()
        handled = false
        closeDown = false
        forceCharge = 0
        downEvent = event
        downTime = CACurrentMediaTime()
        let p = convert(event.locationInWindow, from: nil)
        guard let print = hit(p) else {
            downURL = nil
            handled = true
            wake()
            return
        }
        let url = print.url
        downURL = url
        if hitsClose(print, p) {
            // The × presses in and only discards on release over it, like any button.
            closeDown = true
            print.closePress.target = 1
            wake()
            return
        }
        setPressed(print, true)
        let press = DispatchWorkItem { [weak self] in
            guard let self, !self.handled, self.downURL == url else { return }
            self.handled = true
            Haptics.tick(.levelChange)  // the detent where holding turns into Quick Look
            if let print = self.find(url) { self.setPressed(print, false) }
            Clothesline.shared.quickLook(url)
        }
        longPress = press
        DispatchQueue.main.asyncAfter(deadline: .now() + RopeTuning.chargeEnd, execute: press)
    }

    override func pressureChange(with event: NSEvent) {
        guard !handled, !closeDown, let url = downURL, let print = find(url) else { return }
        if event.stage >= 2 {
            handled = true
            longPress?.cancel()
            setPressed(print, false)
            Clothesline.shared.quickLook(url)  // no haptic of our own: the trackpad already gave the deep click
        } else if event.stage == 1 {
            // Pressing harder sinks the print further; nearing the deep click it gathers as it does when held.
            print.press.target = 0.6 + 0.4 * CGFloat(event.pressure)
            forceCharge = max(0, event.stageTransition)
            wake()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !handled, let down = downEvent, let url = downURL, let print = find(url) else { return }
        if closeDown {
            // Sliding off the × cancels, as with a button.
            print.closePress.target = hitsClose(print, convert(event.locationInWindow, from: nil)) ? 1 : 0
            wake()
            return
        }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        handled = true
        longPress?.cancel()
        setPressed(print, false)
        guard Clothesline.isPlainFile(url) else { return }
        // Unclipped: what stays on the rope dims to a ghost, the rope springs up as the weight leaves, and the
        // trackpad gives a small detent.
        print.lifted = true
        print.opacity.target = 0.3
        if !isMotionReduced { sagV -= 25 }
        Haptics.tick(.alignment)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = print.image.map { NSImage(cgImage: $0, size: print.size) } ?? NSWorkspace.shared.icon(forFile: url.path)
        // The unrotated frame, so the drag image isn't stretched to the tilted print's bounding box.
        let top = print.layer.position
        item.setDraggingFrame(NSRect(x: top.x - print.size.width / 2, y: top.y, width: print.size.width, height: print.size.height),
                              contents: image)
        isDraggingItem = true
        beginDraggingSession(with: [item], event: down, source: self)
        wake()
    }

    override func mouseUp(with event: NSEvent) {
        longPress?.cancel()
        defer {
            downURL = nil
            closeDown = false
            forceCharge = 0
            wake()  // every way out changes the press, the × or what the panel catches
        }
        guard let url = downURL, let print = find(url) else { return }
        if closeDown {
            print.closePress.target = 0
            guard !handled, hitsClose(print, convert(event.locationInWindow, from: nil)) else { return }
            handled = true
            Haptics.tick(.generic)
            Clothesline.shared.discard(url)
            return
        }
        setPressed(print, false)
        guard !handled else { return }
        handled = true
        if event.clickCount >= 2 {
            singleClick?.cancel()
            // A quick pulse toward the viewer, so the eye catches the print before the rope leaves.
            if !isMotionReduced { print.press.velocity -= 14 }
            Clothesline.shared.openInPreview(url)
        } else {
            // Released with a small pop; the copy waits only to tell a click from a double-click.
            if !isMotionReduced { print.lift.velocity -= 60 }
            singleClick?.cancel()
            let click = DispatchWorkItem { Clothesline.shared.copy(url) }
            singleClick = click
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
        }
    }

    // Into an app: a copy (the original stays). Into a folder: moved off the rope. Onto the Trash: discarded.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic, .delete] : [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        clearStitchTarget()
        isDraggingItem = false
        let url = downURL
        downURL = nil
        guard let url, let print = find(url) else { return }
        switch operation {
        case .delete:
            Clothesline.shared.discard(url, fall: false)  // its picture already went into the Trash
        case [], .copy:
            // The original stays: it fills back in where it hangs.
            print.lifted = false
            print.opacity.target = 1
        default:
            // Moved into a folder: once the file has gone the reload lets the print go and the neighbours close up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                if FileManager.default.fileExists(atPath: url.path), let print = self?.find(url) {
                    print.lifted = false
                    print.opacity.target = 1
                }
                Clothesline.shared.reload()
            }
        }
        wake()
    }

    // MARK: Receiving drops (a screenshot card, or images from Finder)

    private var acceptedSequence: Int?
    private var acceptedURLs: [URL] = []
    private var aspects: [URL: CGFloat] = [:]

    /// The drag's media files, read once per drag rather than on every update (pasteboard reads are IPC).
    private func acceptable(_ info: NSDraggingInfo) -> [URL] {
        guard info.draggingSource as? RopeView !== self else { return [] }
        if acceptedSequence != info.draggingSequenceNumber {
            acceptedSequence = info.draggingSequenceNumber
            aspects.removeAll()
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            acceptedURLs = urls.filter { Clothesline.mediaExtensions.contains($0.pathExtension.lowercased()) }
        }
        return acceptedURLs
    }

    /// A file's picture aspect from its header (no decoding), so the gap and the landing match the print to come.
    private func aspect(of url: URL) -> CGFloat {
        if let known = aspects[url] { return known }
        var aspect: CGFloat = 1.5
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            let rotated = ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
            aspect = CGFloat(rotated ? h / w : w / h)
        }
        aspects[url] = aspect
        return aspect
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        if info.draggingSource as? RopeView === self {
            setReceivingHighlight(nil)
            guard let source = downURL, info.draggingSourceOperationMask.contains(.copy),
                  !Clothesline.shared.isStitching, Prefs.clotheslineEnabled else {
                clearStitchTarget()
                updateDraggingItemsForDrag(info)
                return []
            }
            updateStitchTarget(source: source, point: convert(info.draggingLocation, from: nil))
            updateDraggingItemsForDrag(info)
            return stitchIntent.target == nil ? [] : .copy
        }
        clearStitchTarget()
        let urls = acceptable(info)
        let operation = RopeDropFeedback.operation(offered: info.draggingSourceOperationMask, acceptsMedia: !urls.isEmpty)
        setReceivingHighlight(operation.isEmpty ? nil : urls.first)
        return operation
    }

    /// Internal rope-to-rope gestures only; Finder drops keep their ordinary hanging behaviour.
    func updateStitchTarget(source: URL, point: NSPoint, now: CFTimeInterval = CACurrentMediaTime()) {
        guard ImageStitch.supports(source), let bottom = find(source)?.photo, !isLifting else {
            clearStitchTarget(); return
        }
        let target = prints.reversed().first { print in
            guard print.url != source, print.isTouchable, ImageStitch.supports(print.url), print.photo != nil else { return false }
            let local = print.layer.convert(point, from: root)
            return print.layer.bounds.insetBy(dx: print.size.width * 0.12, dy: print.size.height * 0.12).contains(local)
        }
        guard let target, let top = target.photo else { clearStitchTarget(); return }
        guard stitchIntent.target != target.url else { return }
        guard let image = try? ImageStitch.render(top: top, bottom: bottom) else { clearStitchTarget(); return }
        stitchIntent.update(target.url, now: now)
        stitchReady = false
        stitchSize = RopeTuning.printSize(aspect: CGFloat(image.width) / CGFloat(image.height))
        stitchLayer.contents = Self.renderPrint(image, size: stitchSize, movie: false)
        stitchSpring.target = 1
        setStitchHint("Hold briefly to stitch")
        wake()
    }

    private func setStitchHint(_ text: String) {
        let image = Self.chipImage(L(text))
        stitchHint.contents = image
        stitchHint.bounds = CGRect(origin: .zero, size: image.map { CGSize(width: CGFloat($0.width) / 2, height: CGFloat($0.height) / 2) } ?? .zero)
    }

    func clearStitchTarget() {
        stitchIntent.update(nil, now: CACurrentMediaTime())
        stitchReady = false
        stitchSpring.target = 0
        // Keep the image for its fade, but immediately restore the target and cancel the commit.
        wake()
    }

    /// Crossing onto the rope engages it: the cord lights up and dips, the trackpad gives a detent, and room opens
    /// at the front where the print will hang. Leaving undoes it.
    func setReceivingHighlight(_ incoming: URL?) {
        let on = incoming != nil
        guard on != receivingHighlight else { return }
        receivingHighlight = on
        highlight.target = on ? 1 : 0
        if let incoming {
            Haptics.tick(.alignment)
            if !isMotionReduced { sagV += 30 }
            insertGap = RopeTuning.printSize(aspect: aspect(of: incoming)).width + RopeTuning.spacing
        } else {
            insertGap = 0
        }
        layoutPrints()
        wake()
    }

    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {
        guard let sender, sender.draggingSource as? RopeView === self, let url = downURL, let print = find(url) else { return }
        // The composed preview takes over from the floating print. Destination-only changes are restored by
        // AppKit on exit, so dragging onward into Finder or another app keeps the original file/image.
        let image = stitchIntent.target == nil ? print.image.map { NSImage(cgImage: $0, size: print.size) } : nil
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self],
                                      searchOptions: [.urlReadingFileURLsOnly: true]) { item, _, _ in
            item.setDraggingFrame(item.draggingFrame, contents: image)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearStitchTarget(); setReceivingHighlight(nil) }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        clearStitchTarget()
        // A drop keeps its gap until the print arrives (setItems closes it); a cancelled drag closes it now.
        if receivingHighlight { setReceivingHighlight(nil) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !operation(sender).isEmpty else { return false }
        if sender.draggingSource as? RopeView === self {
            sender.animatesToDestination = false
            return stitchIntent.ready(at: CACurrentMediaTime())
        }
        // Let the system slide the drag image into its slot at the front of the rope (see performDragOperation).
        sender.animatesToDestination = !isMotionReduced
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !operation(sender).isEmpty else { return false }
        if sender.draggingSource as? RopeView === self {
            guard let top = stitchIntent.target, let bottom = downURL,
                  stitchIntent.ready(at: CACurrentMediaTime()) else { clearStitchTarget(); return false }
            clearStitchTarget()
            Feedback.press()
            Clothesline.shared.stitch(top: top, bottom: bottom)
            return true
        }
        let urls = acceptable(sender)
        if sender.animatesToDestination {
            var x = RopeTuning.firstSlot
            sender.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self],
                                          searchOptions: [.urlReadingFileURLsOnly: true]) { item, _, _ in
                let size = RopeTuning.printSize(aspect: (item.item as? URL).map { self.aspect(of: $0) } ?? 1.5)
                item.draggingFrame = NSRect(x: x, y: self.ropeY(x + size.width / 2) + 4, width: size.width, height: size.height)
                x += size.width + RopeTuning.spacing
            }
        }
        // The highlight goes; the gap stays open for the print that's about to hang there.
        receivingHighlight = false
        highlight.target = 0
        if !isMotionReduced { sagV += 80 }  // catches the weight
        Feedback.press()
        Clothesline.shared.take(urls)
        let thumbs = IncomingCard.shared.thumbnails(for: urls)
        DispatchQueue.main.async { Clothesline.shared.receive(urls, arrival: .inPlace, thumbnails: thumbs) }
        wake()
        return true
    }
}

/// Readiness is based on the operation the source actually permits, not just its file extension.
enum RopeDropFeedback {
    static func operation(offered: NSDragOperation, acceptsMedia: Bool) -> NSDragOperation {
        guard acceptsMedia else { return [] }
        if offered.contains(.move) { return .move }
        if offered.contains(.copy) { return .copy }
        if offered.contains(.generic) { return .generic }
        return []
    }
}

// MARK: - Screenshot card

/// What the window server and AppKit say about a panel that should be showing. `summary` names no files.
struct CardVisibility {
    var onScreen: Bool          // the window server lists it on screen
    var visible: Bool           // AppKit's isVisible
    var occluded: Bool
    var activeSpace: Bool
    var appHidden: Bool
    var regularApp: Bool
    var alpha: Double
    var frame: NSRect
    var screens: Int

    var isShown: Bool { onScreen && visible }

    @MainActor
    init(_ panel: NSWindow) {
        let number = CGWindowID(max(panel.windowNumber, 0))
        let info = number == 0 ? [] : (CGWindowListCopyWindowInfo(.optionIncludingWindow, number) as? [[String: Any]] ?? [])
        self.init(onScreen: info.first?[kCGWindowIsOnscreen as String] as? Bool ?? false,
                  visible: panel.isVisible,
                  occluded: !panel.occlusionState.contains(.visible),
                  activeSpace: panel.isOnActiveSpace,
                  appHidden: NSApp.isHidden,
                  regularApp: NSApp.activationPolicy() == .regular,
                  alpha: Double(panel.alphaValue),
                  frame: panel.frame,
                  screens: NSScreen.screens.count)
    }

    init(onScreen: Bool, visible: Bool, occluded: Bool, activeSpace: Bool, appHidden: Bool, regularApp: Bool,
         alpha: Double, frame: NSRect, screens: Int) {
        self.onScreen = onScreen; self.visible = visible; self.occluded = occluded; self.activeSpace = activeSpace
        self.appHidden = appHidden; self.regularApp = regularApp; self.alpha = alpha; self.frame = frame
        self.screens = screens
    }

    var summary: String {
        "onScreen=\(onScreen) visible=\(visible) occluded=\(occluded) activeSpace=\(activeSpace) "
            + "appHidden=\(appHidden) regularApp=\(regularApp) alpha=\(String(format: "%.2f", alpha)) "
            + "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) screens=\(screens)"
    }
}

/// The new screenshot, waiting in the bottom-right corner like the system thumbnail. Drag it up to the rope or
/// click it to hang it; drag it into an app or folder like any file; ignore it and it goes to the usual folder.
@MainActor
final class IncomingCard: NSObject, NSDraggingSource {
    static let shared = IncomingCard()

    private var panel: NSPanel
    private let view = IncomingView()
    private(set) var url: URL?
    private var dismissal: DispatchWorkItem?
    private var dragging = false
    private var next: URL?                  // arrived during a drag; shown once the drag ends
    private var presentation = 0
    /// The card's file, already moved where screenshots normally go so a drag out hands over a lasting path. Hanging
    /// it still moves it rather than leaving a copy behind, unless another app took it in the meantime.
    private var savedForDrag: URL?
    /// Whether `url` is the card's screenshot that a drag already saved; it is handed to the rope only once.
    func takeSaved(_ url: URL) -> Bool {
        guard url == savedForDrag else { return false }
        savedForDrag = nil
        return true
    }
    private static let waitSeconds: TimeInterval = 2.5
    private static let resumeSeconds: TimeInterval = 1
    /// Back from a drag into another app (or dropped nowhere): long enough to drag it somewhere else too.
    private static let afterDragSeconds: TimeInterval = 5

    override init() {
        panel = Self.makePanel()
        super.init()
        panel.contentView = view
        view.card = self
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 170),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }

    func present(_ url: URL) {
        // A newer screenshot never pulls the file out from under a drag; it waits until the drag ends.
        if dragging {
            if let waiting = next, waiting != url { release(waiting) }
            next = url
            return
        }
        // Replacing a card that's showing: the old one fades away in place as the new one slides in.
        let ghost = self.url != nil && self.url != url && panel.isVisible ? view.snapshot() : nil
        if let current = self.url, current != url { release(current) }
        pauseDismissal()
        presentation += 1
        self.url = url
        savedForDrag = nil
        view.resetInteraction()
        view.setThumbnail(Clothesline.thumbnail(url, maxPixels: 480))
        let size = view.preferredSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else {
            putAway(url, animated: false)  // nowhere to show it: it goes straight to the usual folder
            return
        }
        // The panel reaches the screen's right edge, so the card slides in from (and out through) the edge itself.
        panel.setFrame(NSRect(x: area.maxX - size.width, y: area.minY + 14, width: size.width, height: size.height), display: false)
        view.layoutCard()
        view.resetInteraction(hovered: NSPointInRect(NSEvent.mouseLocation, view.cardScreenRect))
        if let ghost { view.fadeGhost(ghost) }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        view.enter()
        scheduleDismissal()
        confirmShown(presentation, rebuilt: false)
    }

    /// In a long session the window server once stopped putting this panel on screen (2026-10-24): it was ordered
    /// front at the right frame and never appeared, so every screenshot went to the usual folder unseen until
    /// Swivel was restarted. A moment after each presentation the card checks that it really is on screen; if not,
    /// it logs what it found and shows itself again in a new window, once.
    private func confirmShown(_ generation: Int, rebuilt: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkSeconds) { [weak self] in
            guard let self, self.presentation == generation, self.url != nil, !self.dragging else { return }
            let state = CardVisibility(self.panel)
            if state.isShown {
                if rebuilt { log.notice("Screenshot card recovered in a new window: \(state.summary, privacy: .public)") }
                return
            }
            guard !rebuilt else {
                log.fault("Screenshot card still not on screen after rebuilding its window: \(state.summary, privacy: .public)")
                return
            }
            log.error("Screenshot card was not on screen; rebuilding its window: \(state.summary, privacy: .public)")
            self.rebuildPanel()
            self.confirmShown(generation, rebuilt: true)
        }
    }
    private static let checkSeconds: TimeInterval = 0.4

    /// Moves the card into a fresh panel at the same place and shows it there.
    private func rebuildPanel() {
        let old = panel
        let frame = old.frame
        view.halt()
        old.orderOut(nil)
        old.contentView = nil
        panel = Self.makePanel()
        panel.contentView = view
        panel.setFrame(frame, display: false)
        view.layoutCard()
        view.resetInteraction(hovered: NSPointInRect(NSEvent.mouseLocation, view.cardScreenRect))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        view.enter()
        old.close()
    }

    /// The card's thumbnail, for the rope to reuse instead of decoding the file again.
    func thumbnails(for urls: [URL]) -> [URL: CGImage] {
        guard let url, urls.contains(url), let thumb = view.thumbnail else { return [:] }
        return [url: thumb]
    }

    func pauseDismissal() {
        dismissal?.cancel()
        dismissal = nil
    }

    func resumeDismissal(afterDrag: Bool = false) {
        scheduleDismissal(after: afterDrag ? Self.afterDragSeconds : Self.resumeSeconds)
    }

    private func scheduleDismissal(after delay: TimeInterval? = nil) {
        pauseDismissal()
        guard let url, !dragging, !view.isHovered, !view.isInteracting else { return }
        let generation = presentation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.presentation == generation, self.url == url,
                  !self.dragging, !self.view.isHovered, !self.view.isInteracting else { return }
            self.putAway(url)
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? Self.waitSeconds), execute: work)
    }

    /// Takes the card off screen; its frame loop stops with it, so the next card starts it afresh.
    private func orderOut() {
        panel.orderOut(nil)
        view.halt()
    }

    /// Saves the file where screenshots normally go, and returns where it ended up.
    @discardableResult
    private func release(_ url: URL) -> URL? {
        // Saved already (a drag moved it out first): it stays where it is.
        guard url.deletingLastPathComponent().standardizedFileURL == Clothesline.shared.incoming.standardizedFileURL else { return url }
        // A copied image that wasn't hung is only a temporary file: it never lands on the Desktop by itself.
        if Clothesline.isCopiedImage(url) { try? FileManager.default.removeItem(at: url); return nil }
        return Self.save(url, to: ScreenshotTakeover.originalLocation, otherwise: Clothesline.shared.folder)
    }

    /// Moves a waiting screenshot into `folder` without overwriting anything, even a file that appears there while it
    /// moves; `folder` can be on another volume (`Paths.move`). If that fails (the folder is gone or read-only, or it
    /// is Incoming itself) it hangs on the rope (`fallback`) instead, so it never stays behind in the hidden Incoming
    /// folder. Returns where it went, or nil if neither worked (the next launch tries again). `rename` is for tests.
    nonisolated static func save(_ url: URL, to folder: URL, otherwise fallback: URL,
                                 rename: (URL, URL) throws -> Void = Paths.renameExclusively) -> URL? {
        let home = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        for directory in [folder, fallback] where directory.resolvingSymlinksInPath().path != home {
            if let saved = try? Paths.move(url, into: directory, rename: rename) { return saved }
        }
        return nil
    }

    /// The clothesline is going away (switched off, or Swivel is quitting): the card's file and one queued behind a
    /// drag go where screenshots normally go now, and the card leaves.
    func putAwayAll(animated: Bool) {
        if let waiting = next {
            next = nil
            release(waiting)
        }
        if let url { putAway(url, animated: animated) }
    }

    /// Whether a window is the card's, so a click on it isn't taken for a click away from the rope.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    /// Not wanted on the rope: saved where screenshots normally go, and the card slides away.
    func putAway(_ url: URL, animated: Bool = true) {
        release(url)
        guard url == self.url else { return }
        self.url = nil
        savedForDrag = nil
        pauseDismissal()
        guard animated else { orderOut(); return }
        let generation = presentation
        view.exit { [weak self] in
            guard let self, self.presentation == generation else { return }
            self.orderOut()
        }
    }

    /// Click: the file is hung at once, and the card flies up to its peg to show where it went.
    func hangNow() {
        guard let url else { return }
        let thumbs = thumbnails(for: [url])
        self.url = nil
        pauseDismissal()
        let generation = presentation
        let from = view.photoScreenRect
        let photo = view.photoImage
        let screen = panel.screen ?? NSScreen.main
        let flies = !Motion.reduced && photo != nil && screen != nil
        let hung = Clothesline.shared.receive([url], arrival: flies ? .handOff : .inPlace, thumbnails: thumbs)
        let rope = Clothesline.shared.panel.rope
        guard flies, let destination = hung.first, let photo, let screen else {
            if !hung.isEmpty { Feedback.press() }  // hung in place (Reduce Motion): the click still lands firmly
            view.fadeOut { [weak self] in
                guard let self, self.presentation == generation else { return }
                self.orderOut()
            }
            return
        }
        CardFlight.shared.fly(photo, printImage: rope.image(of: destination), from: from, on: screen,
                              to: { [weak rope] in rope?.landing(for: destination) },
                              started: { [weak self] in
                                  // The flight has drawn its first frame over the card, so the card can go.
                                  guard let self, self.presentation == generation else { return }
                                  self.orderOut()
                              },
                              landed: { [weak rope] in rope?.handOff(destination) })
    }

    /// Double-click: opened to look at, not hung. It's saved where screenshots normally go first and opened from
    /// there, so it doesn't stay behind in the hidden Incoming folder.
    func open() {
        guard let url else { return }
        pauseDismissal()
        self.url = nil
        savedForDrag = nil
        let saved = release(url) ?? url
        let generation = presentation
        view.fadeOut { [weak self] in
            guard let self, self.presentation == generation else { return }
            self.orderOut()
        }
        Clothesline.shared.openInPreview(saved)
    }

    func beginDrag(with event: NSEvent) {
        guard var url, Clothesline.isPlainFile(url) else { return }
        // Another app may read a dropped file long after the drop (a chat attachment is read when it is sent), so
        // the file goes where screenshots normally go before the drag starts, and the path it hands over stays valid.
        if let saved = release(url), saved != url { url = saved; self.url = saved; savedForDrag = saved }
        dragging = true
        pauseDismissal()
        Feedback.prepare()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = view.photoImage.map { NSImage(cgImage: $0, size: view.photoRect.size) } ?? NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(view.photoRect, contents: image)
        view.setDimmed(true)
        Clothesline.shared.beginReceiving()
        view.beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic, .delete] : [.move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        view.resetInteraction(hovered: NSPointInRect(screenPoint, view.cardScreenRect), afterDrag: true)
        Clothesline.shared.endReceiving()
        defer {
            if let waiting = next {
                next = nil
                present(waiting)
            }
        }
        guard let url else {
            view.setDimmed(false)
            return
        }
        if operation == .delete {
            NSWorkspace.shared.recycle([url])
        } else if operation != [] && !Clothesline.shared.isTaking(url) {
            // Another app holds this path now; hanging it later copies instead of moving it out from under that app.
            savedForDrag = nil
        }
        // The rope may have taken it without having moved it yet (that happens on the next turn of the run loop).
        if Clothesline.shared.isTaking(url) || operation == .delete || !FileManager.default.fileExists(atPath: url.path) {
            // Hung on the rope, moved to a folder or thrown away: the card's job is done. A rope drop still needs
            // to know the saved file is the card's when it moves it on the next turn of the run loop.
            if !Clothesline.shared.isTaking(url) { savedForDrag = nil }
            self.url = nil
            pauseDismissal()
            orderOut()
            view.setDimmed(false, animated: false)
        } else {
            // Copied into an app, or dropped nowhere: the card comes back and waits again.
            view.setDimmed(false)
            resumeDismissal(afterDrag: true)
        }
    }
}

/// The card's picture: a photo with a white border over a "Drag up to hang" capsule, drawn as layers so it can
/// slide, lift and press on springs at the display's refresh rate.
final class IncomingView: NSView {
    weak var card: IncomingCard?
    private(set) var thumbnail: CGImage?
    private(set) var photoImage: CGImage?
    private(set) var isHovered = false
    private var downEvent: NSEvent?
    private var dragged = false
    private var singleClick: DispatchWorkItem?
    var isInteracting: Bool { downEvent != nil || singleClick != nil }
    /// For tests and frame renders.
    var reducedMotionOverride: Bool?
    private var isMotionReduced: Bool { reducedMotionOverride ?? Motion.reduced }

    private let cardLayer = CALayer()      // everything that moves together
    private let photoLayer = CALayer()
    private let capsuleLayer = CALayer()
    private lazy var driver: FrameDriver = {
        let driver = FrameDriver(view: self)
        driver.onFrame = { [weak self] dt in self?.advance(dt) ?? false }
        return driver
    }()
    private var slide = Spring(0, response: 0.32, damping: 0.9)    // points to the right of its place
    private var alpha = Spring(1, response: 0.14, damping: 1)
    private var hover = Spring(0, response: 0.25, damping: 0.9)
    private var press = Spring(0, response: RopeTuning.pressIn.response, damping: RopeTuning.pressIn.damping)
    private var ready = Spring(0, response: 0.25, damping: 0.9)    // clicked: lifts a little while it waits to fly
    private var exitProgress: CGFloat?                              // leaving through the screen edge, 0…1
    private var exitFrom: CGFloat = 0
    private var onGone: (() -> Void)?

    /// Room for the hover shadow on the left and top; the photo keeps 22 pt from the screen's right edge.
    static let margin: CGFloat = 24
    static let edgeInset: CGFloat = 22
    private static let exitDuration: CGFloat = 0.22
    private static let maxThumb = NSSize(width: 200, height: 128)
    private static let photoBottom: CGFloat = 34   // the capsule sits below the photo

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.addSublayer(cardLayer)
        cardLayer.addSublayer(photoLayer)
        cardLayer.addSublayer(capsuleLayer)
        photoLayer.shadowColor = NSColor.black.cgColor
        photoLayer.shadowOpacity = 0.35
    }

    required init?(coder: NSCoder) { fatalError() }
    override func isAccessibilityElement() -> Bool { card?.url != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { L("Hang Screenshot") }
    override func accessibilityHelp() -> String? { L("Click to hang this screenshot on the clothesline.") }
    override func accessibilityPerformPress() -> Bool {
        guard let card, card.url != nil else { return false }
        card.hangNow(); return true
    }

    func resetInteraction(hovered: Bool = false, afterDrag: Bool = false) {
        singleClick?.cancel()
        singleClick = nil
        downEvent = nil
        dragged = afterDrag
        isHovered = hovered
        hover.target = hovered ? 1 : 0
        press.target = 0
        ready.target = 0
        wake()
    }

    // MARK: Layout

    private var thumbSize: NSSize {
        guard let thumbnail, thumbnail.width > 0, thumbnail.height > 0 else { return NSSize(width: 180, height: 110) }
        let w = CGFloat(thumbnail.width), h = CGFloat(thumbnail.height)
        let s = min(Self.maxThumb.width / w, Self.maxThumb.height / h)
        return NSSize(width: w * s, height: h * s)
    }

    private var photoSize: NSSize { NSSize(width: thumbSize.width + 8, height: thumbSize.height + 8) }

    private static var hint: String { "↑  " + L("Drag up to hang") }
    private static var hintAttributes: [NSAttributedString.Key: Any] { [.font: AppTypography.font(ofSize: 11, weight: .semibold),
                                                                        .foregroundColor: NSColor.white] }
    private var capsuleSize: NSSize {
        NSSize(width: ((Self.hint as NSString).size(withAttributes: Self.hintAttributes).width + 20).rounded(.up), height: 20 * Prefs.interaction.textSize.scale)
    }

    private var contentSize: NSSize {
        NSSize(width: max(photoSize.width, capsuleSize.width, 154), height: Self.photoBottom + photoSize.height)
    }

    var preferredSize: NSSize {
        NSSize(width: Self.margin + contentSize.width + Self.edgeInset, height: contentSize.height + Self.margin)
    }

    /// The photo and capsule, in view coordinates; only this part tracks hover.
    var contentRect: NSRect { NSRect(origin: NSPoint(x: Self.margin, y: 0), size: contentSize) }

    var photoRect: NSRect {
        let content = contentRect, photo = photoSize
        return NSRect(x: content.minX + (content.width - photo.width) / 2, y: Self.photoBottom, width: photo.width, height: photo.height)
    }

    var cardScreenRect: NSRect { window.map { $0.convertToScreen(convert(contentRect, to: nil)) } ?? .zero }

    /// The photo as it is drawn now, lift and press included.
    var photoScreenRect: NSRect {
        guard let window, let root = layer else { return .zero }
        return window.convertToScreen(convert(root.convert(photoLayer.bounds, from: photoLayer), to: nil))
    }

    private var offscreen: CGFloat { contentSize.width + Self.edgeInset + 24 }

    func setThumbnail(_ image: CGImage?) {
        thumbnail = image
        let scale = window?.backingScaleFactor ?? 2
        let size = photoSize, thumb = thumbSize
        photoImage = renderImage(size, scale: scale) { ctx in
            let rect = CGRect(origin: .zero, size: size)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.setFillColor(.white)
            ctx.fillPath()
            guard let image else { return }
            let inner = CGRect(x: 4, y: 4, width: thumb.width, height: thumb.height)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(image, in: inner)
        }
        let capsule = capsuleSize
        let capsuleImage = renderImage(capsule, scale: scale) { _ in
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: capsule), xRadius: 10, yRadius: 10).fill()
            let text = (Self.hint as NSString).size(withAttributes: Self.hintAttributes)
            (Self.hint as NSString).draw(at: NSPoint(x: 10, y: (capsule.height - text.height) / 2), withAttributes: Self.hintAttributes)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photoLayer.contents = photoImage
        photoLayer.contentsScale = scale
        capsuleLayer.contents = capsuleImage
        capsuleLayer.contentsScale = scale
        CATransaction.commit()
        layoutCard()
    }

    func layoutCard() {
        let content = contentRect, photo = photoSize, capsule = capsuleSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardLayer.bounds = CGRect(origin: .zero, size: content.size)
        cardLayer.position = CGPoint(x: content.midX, y: content.midY)
        photoLayer.frame = CGRect(x: (content.width - photo.width) / 2, y: Self.photoBottom, width: photo.width, height: photo.height)
        photoLayer.shadowPath = CGPath(roundedRect: photoLayer.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        capsuleLayer.frame = CGRect(x: (content.width - capsule.width) / 2, y: 2, width: capsule.width, height: capsule.height)
        CATransaction.commit()
        render()
    }

    // MARK: Motion

    private func wake() {
        if window?.isVisible == true { driver.start() }
    }

    /// Slides in from the screen's right edge like the system's thumbnail (fades in place under Reduce Motion).
    func enter() {
        exitProgress = nil
        onGone = nil
        press.snap(0)
        ready.snap(0)
        hover.snap(isHovered ? 1 : 0)
        alpha.response = 0.14
        if isMotionReduced {
            slide.snap(0)
            alpha.snap(0)
        } else {
            slide.snap(offscreen)
            slide.target = 0
            alpha.snap(1)
        }
        alpha.target = 1
        render()
        wake()
    }

    /// Leaves through the screen edge, accelerating away; an exit is quicker than the entrance.
    func exit(_ done: @escaping () -> Void) {
        onGone = done
        if isMotionReduced {
            alpha.response = 0.1
            alpha.target = 0
        } else {
            exitFrom = slide.value
            exitProgress = 0
        }
        wake()
    }

    /// Fades out where it is (opened, or hung under Reduce Motion).
    func fadeOut(_ done: @escaping () -> Void) {
        onGone = done
        exitProgress = nil
        alpha.response = 0.1
        alpha.target = 0
        wake()
    }

    /// While the card is being dragged it stays behind as a faint outline of where it came from.
    func setDimmed(_ dimmed: Bool, animated: Bool = true) {
        alpha.response = 0.16
        if animated { alpha.target = dimmed ? 0.25 : 1 } else { alpha.snap(dimmed ? 0.25 : 1) }
        render()
        wake()
    }

    /// The card as it looks now, for fading out in place when a newer screenshot replaces it.
    func snapshot() -> (image: CGImage, rect: NSRect)? {
        guard let photoImage, cardLayer.opacity > 0.05, window?.isVisible == true else { return nil }
        return (photoImage, photoScreenRect)
    }

    func fadeGhost(_ ghost: (image: CGImage, rect: NSRect)) {
        guard let window, let root = layer else { return }
        let rect = convert(window.convertFromScreen(ghost.rect), from: nil)
        let layer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = ghost.image
        layer.contentsScale = window.backingScaleFactor
        layer.frame = rect
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: -4)
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        root.insertSublayer(layer, below: cardLayer)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade]
        if !isMotionReduced {
            let sink = CABasicAnimation(keyPath: "position.y")
            sink.byValue = -16
            group.animations?.append(sink)
        }
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "replaced")
        CATransaction.commit()
    }

    /// Stops the frame loop (the card is off screen).
    func halt() { driver.stop() }

    /// One display frame. Returns false when everything has settled.
    @discardableResult
    func advance(_ dt: CGFloat) -> Bool {
        if var progress = exitProgress {
            progress = min(progress + dt * Prefs.interaction.clothesline.safeSpeed / Self.exitDuration, 1)
            exitProgress = progress
            slide.snap(exitFrom.mix(offscreen, RopeTuning.ease(progress, 0.4, 0, 1, 1)))
        } else {
            slide.step(dt, tuning: Prefs.interaction.clothesline)
        }
        alpha.step(dt, tuning: Prefs.interaction.clothesline)
        hover.step(dt, tuning: Prefs.interaction.clothesline)
        press.step(dt, tuning: Prefs.interaction.clothesline)
        ready.step(dt, tuning: Prefs.interaction.clothesline)
        render()
        let gone = exitProgress.map { $0 >= 1 } ?? (alpha.target == 0 && alpha.value < 0.02)
        if gone {
            exitProgress = nil
            let done = onGone
            onGone = nil
            done?()
            return false
        }
        return exitProgress != nil || !(slide.isSettled && alpha.isSettled && hover.isSettled && press.isSettled && ready.isSettled)
    }

    private func render() {
        let reduced = isMotionReduced
        let h = hover.value, p = press.value, r = ready.value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Hover lifts the card 2 pt toward you, a click readies it 4 pt more; a press gives 3 %.
        let lift = reduced ? 0 : 2 * h + 4 * r
        let scale = reduced ? 1 : 1 - 0.03 * p
        cardLayer.transform = CATransform3DScale(CATransform3DMakeTranslation(slide.value, lift, 0), scale, scale, 1)
        cardLayer.opacity = Float(alpha.value)
        photoLayer.shadowRadius = max(7 + 3 * h + 2 * r - 3 * p, 3)
        photoLayer.shadowOffset = CGSize(width: 0, height: -max(4 + 3 * h + 2 * r - 2 * p, 1))
        CATransaction.commit()
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: contentRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        contentRect.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hover.target = 1
        card?.pauseDismissal()
        wake()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hover.target = 0
        card?.resumeDismissal()
        wake()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setPressed(_ on: Bool) {
        let tune = on ? RopeTuning.pressIn : RopeTuning.pressOut
        press.response = tune.response
        press.damping = tune.damping
        press.target = on ? 1 : 0
        wake()
    }

    override func mouseDown(with event: NSEvent) {
        card?.pauseDismissal()
        downEvent = event
        dragged = false
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragged, let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        dragged = true
        singleClick?.cancel()
        singleClick = nil
        setPressed(false)
        card?.beginDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        downEvent = nil
        setPressed(false)
        guard !dragged else { return }
        if event.clickCount >= 2 {
            singleClick?.cancel()
            singleClick = nil
            card?.open()
        } else {
            // Readied at once, so the wait that tells a click from a double-click doesn't feel dead.
            ready.target = 1
            wake()
            let click = DispatchWorkItem { [weak self] in
                self?.singleClick = nil
                self?.card?.hangNow()
            }
            singleClick = click
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
        }
    }
}

// MARK: - Card flight

/// A clicked card's trip from the corner up to its peg. A transparent, click-through panel over the screen carries
/// the photo and aims every frame at the print's live position, so the hand-off lands exactly where the print
/// hangs even while the rope is still settling. On the way the photo turns into the print's own picture.
@MainActor
final class CardFlight {
    static let shared = CardFlight()

    private let panel: NSPanel
    private let host = NSView()
    private let photo = CALayer()
    private let print = CALayer()
    private lazy var driver: FrameDriver = {
        let driver = FrameDriver(view: host)
        driver.onFrame = { [weak self] dt in self?.advance(dt) ?? false }
        return driver
    }()
    private var elapsed: CGFloat = 0
    private var from = NSRect.zero
    private var origin = NSPoint.zero
    private var target: (() -> (rect: NSRect, angle: CGFloat)?)?
    private var started: (() -> Void)?
    private var landed: (() -> Void)?
    private var showingLanding = false
    static let duration: CGFloat = 0.36

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        panel.contentView = host
        photo.anchorPoint = CGPoint(x: 0.5, y: 1)   // the top centre, where the peg will grip
        photo.shadowColor = NSColor.black.cgColor
        photo.shadowOpacity = 0.35
        photo.addSublayer(print)
        root.addSublayer(photo)
    }

    func fly(_ image: CGImage, printImage: CGImage?, from: NSRect, on screen: NSScreen,
             to target: @escaping () -> (rect: NSRect, angle: CGFloat)?,
             started: @escaping () -> Void, landed: @escaping () -> Void) {
        land()  // one still in the air lands at once
        self.from = from
        self.target = target
        self.started = started
        self.landed = landed
        elapsed = 0
        origin = screen.frame.origin
        panel.setFrame(screen.frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.contents = image
        photo.contentsScale = screen.backingScaleFactor
        photo.bounds = CGRect(origin: .zero, size: from.size)
        photo.position = CGPoint(x: from.midX - origin.x, y: from.maxY - origin.y)
        photo.transform = CATransform3DIdentity
        photo.shadowPath = CGPath(roundedRect: photo.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        print.contents = printImage
        print.contentsScale = 2
        print.frame = photo.bounds
        print.opacity = 0
        CATransaction.commit()
        panel.orderFrontRegardless()
        driver.start()
    }

    private func advance(_ dt: CGFloat) -> Bool {
        if showingLanding {
            // The print has been showing for a frame underneath, so nothing blinks when the flight goes.
            showingLanding = false
            panel.orderOut(nil)
            return false
        }
        if let started {
            self.started = nil
            started()
        }
        guard let goal = target?() else {
            land()
            return false
        }
        elapsed += dt * Prefs.interaction.clothesline.safeSpeed
        let t = min(elapsed / Self.duration, 1)
        let e = RopeTuning.ease(t, 0.3, 0, 0.2, 1)
        let scale = CGFloat(1).mix(goal.rect.width / max(from.width, 1), e)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.position = CGPoint(x: from.midX.mix(goal.rect.midX, e) - origin.x, y: from.maxY.mix(goal.rect.maxY, e) - origin.y)
        // The rope's view is flipped, so its clockwise tilt is a negative angle here.
        photo.transform = CATransform3DScale(CATransform3DMakeRotation(-goal.angle * e, 0, 0, 1), scale, scale, 1)
        photo.shadowRadius = CGFloat(7).mix(6, e) / max(scale, 0.1)
        photo.shadowOffset = CGSize(width: 0, height: -4 / max(scale, 0.1))
        print.opacity = Float(min(max((t - 0.55) / 0.45, 0), 1))
        CATransaction.commit()
        if t >= 1 {
            target = nil
            let landed = self.landed
            self.landed = nil
            landed?()
            showingLanding = true
        }
        return true
    }

    /// Ends a flight now: the card goes, the print shows, and the panel is put away.
    private func land() {
        guard target != nil || showingLanding else { return }
        let started = self.started, landed = self.landed
        self.started = nil
        self.landed = nil
        target = nil
        showingLanding = false
        started?()
        landed?()
        driver.stop()
        panel.orderOut(nil)
    }
}

/// Makes a PNG of a copied print only when an app pastes it as PNG. Held until the clipboard changes, since the
/// pasteboard item may not keep its provider alive.
final class PNGOnDemand: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: PNGOnDemand?
    /// The bytes read when the print was copied: the file isn't opened again, so a link swapped in later isn't followed.
    private let data: Data

    init(_ data: Data) {
        self.data = data
        super.init()
        Self.lock.withLock { Self.current = self }
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .png, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              Double(width) * Double(height) <= Images.maxDecodePixels,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary),
              let png = try? Images.encode(image, type: .png, quality: 1) else { return }
        item.setData(png, forType: .png)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        Self.lock.withLock { if Self.current === self { Self.current = nil } }
    }
}
