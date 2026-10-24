import AppKit
import IOKit.pwr_mgt

/// Keeps the Mac from idle sleep for a while, like Amphetamine or `caffeinate`, through a power assertion. It needs no
/// permission and ends with Swivel: macOS drops the assertion when the process exits. Closing the lid of a laptop
/// still sleeps it; that would need an administrator setting and isn't offered.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()
    static let changed = Notification.Name("SwivelKeepAwakeChanged")

    /// The choices offered everywhere (menu, settings, Quick Actions); nil means until turned off.
    static let durations: [TimeInterval?] = [30 * 60, 60 * 60, 2 * 60 * 60, 5 * 60 * 60, nil]

    private var assertion: IOPMAssertionID = 0
    private var timer: DispatchSourceTimer?
    /// When it ends; `.distantFuture` until turned off.
    private(set) var until: Date?
    var isActive: Bool { assertion != 0 }

    /// Starts, or restarts with a new length. Ignored while the feature is off.
    func start(for duration: TimeInterval?) {
        guard Feature.keepAwake.isOn else { return }
        releaseAssertion()
        let type = Prefs.keepAwakeDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "Swivel: Keep Awake" as CFString, &id) == kIOReturnSuccess else {
            NotificationCenter.default.post(name: Self.changed, object: nil)  // a session that was running has ended
            return
        }
        assertion = id
        until = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        if let duration {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            // Wall-clock time: an uptime deadline would pause while the Mac sleeps and run past the end time.
            timer.schedule(wallDeadline: .now() + duration)
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.stop() } }
            timer.resume()
            self.timer = timer
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func stop() {
        guard isActive || timer != nil else { return }
        releaseAssertion()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Applies a changed "keep the display on" choice to a running session, keeping its end time.
    func refreshType() {
        guard isActive, let until else { return }
        start(for: until == .distantFuture ? nil : max(1, until.timeIntervalSinceNow))
    }

    private func releaseAssertion() {
        timer?.cancel(); timer = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        until = nil
    }

    /// "Awake for 1 h 20 min more", "Awake until turned off", or nil when off.
    var status: String? {
        guard isActive, let until else { return nil }
        if until == .distantFuture { return L("Awake until turned off") }
        return L("Awake for %@ more", Self.format(until.timeIntervalSinceNow))
    }

    static func title(for duration: TimeInterval?) -> String {
        guard let duration else { return L("Until Turned Off") }
        return L("For %@", format(duration))
    }

    static func format(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.calendar?.locale = Locale(identifier: Language.resolved == .en ? "en" : Language.resolved.rawValue)
        return formatter.string(from: max(60, seconds.rounded(.up))) ?? ""
    }
}

/// Settings page: start a session, see how long is left, and choose whether the display stays on too.
final class KeepAwakePane: Pane {
    private let status = NSTextField(labelWithString: "")
    private let display = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var buttons: [NSButton] = []
    private var stopButton: NSButton!
    private var observer: NSObjectProtocol?

    init() { super.init(size: NSSize(width: 760, height: 380)) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        stack.addArrangedSubview(label("Keep your Mac awake", size: 17, weight: .semibold))
        stack.addArrangedSubview(label("Choose how long. Swivel holds a standard macOS power assertion, the same kind a video player uses, and lets it go when the time is up, when you stop it or when Swivel quits. No permission is needed.", secondary: true))
        status.font = .systemFont(ofSize: 15, weight: .medium)
        stack.addArrangedSubview(status)
        buttons = KeepAwake.durations.enumerated().map { index, duration in
            let button = ToolUI.button(KeepAwake.title(for: duration), target: self, action: #selector(start(_:)))
            button.tag = index
            return button
        }
        stopButton = ToolUI.button("Stop", target: self, action: #selector(stop))
        let row = NSStackView(views: buttons + [stopButton])
        row.spacing = 8
        stack.addArrangedSubview(row)
        display.title = L("Keep the display on too")
        display.target = self; display.action = #selector(displayChanged)
        stack.addArrangedSubview(display)
        stack.addArrangedSubview(label("Also in the menu bar menu and in Quick Actions. Closing a laptop's lid still puts it to sleep.", size: 12, secondary: true))
        observer = NotificationCenter.default.addObserver(forName: KeepAwake.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func refresh() {
        let on = Feature.keepAwake.isOn
        status.stringValue = !on ? L("Turn this feature on above to get started.") : KeepAwake.shared.status ?? L("Your Mac sleeps as usual.")
        status.textColor = KeepAwake.shared.isActive ? .controlAccentColor : .secondaryLabelColor
        for button in buttons { button.isEnabled = on }
        stopButton?.isEnabled = on && KeepAwake.shared.isActive
        display.state = Prefs.keepAwakeDisplay ? .on : .off
    }

    @objc private func start(_ sender: NSButton) { KeepAwake.shared.start(for: KeepAwake.durations[sender.tag]) }
    @objc private func stop() { KeepAwake.shared.stop() }
    @objc private func displayChanged() {
        Prefs.keepAwakeDisplay = display.state == .on
        KeepAwake.shared.refreshType()
    }
}
