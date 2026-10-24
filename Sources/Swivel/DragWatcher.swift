import AppKit
import os

let log = Logger(subsystem: "local.swivel.app", category: "drag")

enum WheelMode: String, CaseIterable {
    case convert, tools, actions, apps, codes, custom

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .convert: L("Convert")
        case .tools: L("Tools")
        case .actions: L("Actions")
        case .apps: L("App Actions")
        case .codes: L("QR Library")
        case .custom: L("My Wheel")
        }
    }

    var symbol: String {
        switch self { case .convert: "arrow.triangle.2.circlepath"; case .tools: "slider.horizontal.3"; case .actions: "bolt"; case .apps: "arrow.up.forward.app"; case .codes: "qrcode"; case .custom: "star.circle" }
    }

    @MainActor var key: String { Prefs.key(for: self).symbol }
    @MainActor var isAvailable: Bool {
        switch self {
        case .apps: Feature.appRouting.isOn
        case .codes: Feature.qrCodes.isOn
        case .custom: CustomWheel.hasUsablePick
        default: true
        }
    }
    /// The menu a key tap during a drag opens, if any.
    @MainActor static func tapped(_ pressed: NSEvent.ModifierFlags) -> WheelMode? {
        allCases.first { $0.isAvailable && Prefs.key(for: $0).isTapped(in: pressed) }
    }
}

/// Notices when a file drag is in progress anywhere on screen and reports modifier-key taps during it.
///
/// Polls instead of using event monitors for the drag itself: during a drag session the window server swallows most
/// mouse events, and polling the drag pasteboard and modifier state needs no Accessibility permission. Polling is
/// slow while the mouse button is up and switches to every display frame (120 Hz) while it is held; a global
/// mouse-down monitor (which also needs no permission) switches it the moment a press starts.
@MainActor
final class DragWatcher {
    var onKeyTap: ((WheelMode) -> Void)?
    var onDragEnd: (() -> Void)?
    private(set) var urls: [URL] = []
    /// When false, drags are ignored and no wheel opens.
    var isEnabled = true

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var monitors: [Any] = []
    private var wasDown = false
    private var baselineCount = 0
    private var active = false
    private var lastFlags: NSEvent.ModifierFlags = []
    /// Keys pressed after the button went down but before the drag was recognised: a quick user's tap.
    private var earlyTaps: NSEvent.ModifierFlags = []
    /// Keeps the app out of App Nap and timer coalescing while a drag is in progress.
    private var activity: NSObjectProtocol?

    private static let idleInterval = 1.0 / 20
    private static let dragInterval = 1.0 / 120

    func start() {
        schedule(Self.idleInterval)
        let wake: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.interval != Self.dragInterval else { return }
                self.schedule(Self.dragInterval)
                self.tick()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: wake) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in wake(event); return event }) {
            monitors.append(local)
        }
    }

    private func schedule(_ interval: TimeInterval) {
        guard interval != self.interval else { return }
        timer?.invalidate()
        self.interval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval == Self.dragInterval ? 0 : interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let flags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option, .function])
        defer {
            wasDown = down
            lastFlags = flags
        }

        guard down, isEnabled else {
            if active {
                active = false
                urls = []
                endActivity()
                onDragEnd?()
            }
            earlyTaps = []
            schedule(Self.idleInterval)
            return
        }
        schedule(Self.dragInterval)

        if !wasDown {
            baselineCount = dragPasteboard.changeCount
            earlyTaps = []
            log.debug("mouse down, drag pasteboard count \(self.baselineCount)")
            return
        }

        if !active {
            earlyTaps.formUnion(flags.subtracting(lastFlags))
            let count = dragPasteboard.changeCount
            guard count != baselineCount else { return }
            // Keep retrying until the source has finished writing file URLs to the pasteboard.
            let types = dragPasteboard.types?.map(\.rawValue) ?? []
            let found = dragPasteboard.readObjects(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            log.debug("drag pasteboard changed \(count): types \(types, privacy: .public), \(found.count) file URLs")
            guard !found.isEmpty else { return }
            baselineCount = count
            urls = found
            active = true
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "File drag in progress")
            log.info("file drag started: \(found.count) files \(found.map(\.lastPathComponent), privacy: .private)")
            Feedback.prepare()
            // Keys already held when the button went down don't count; one tapped since then (and still held) does.
            let early = earlyTaps.intersection(flags)
            earlyTaps = []
            if let mode = WheelMode.tapped(early) {
                log.info("key tapped before the drag was recognised: \(early.rawValue)")
                onKeyTap?(mode)
            }
            return
        }

        let pressed = flags.subtracting(lastFlags)
        if !pressed.isEmpty { log.info("key tap during drag: \(pressed.rawValue)") }
        if let mode = WheelMode.tapped(pressed) {
            onKeyTap?(mode)
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
