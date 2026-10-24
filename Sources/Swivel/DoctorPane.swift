import AppKit

/// Mac Doctor's own settings. Kept here rather than in Prefs so the feature lives in its own files.
@MainActor
enum DoctorSettings {
    private static let assistantKey = "doctor.assistant"

    /// Whether Mac Doctor may offer to send a report to the assistant set up in Quick Actions. Off by default:
    /// a key saved for Quick Actions is never used by Mac Doctor until the user turns this on.
    static var allowAssistant: Bool {
        get { UserDefaults.standard.bool(forKey: assistantKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: assistantKey)
            NotificationCenter.default.post(name: Prefs.changed, object: nil)
        }
    }
}

/// Mac Doctor's settings page: what it checks, what it never does, and the way into the window.
final class DoctorPane: Pane {
    private var openButton: NSButton!
    private let hint = NSTextField(labelWithString: "")
    private let assistant = NSTextField(wrappingLabelWithString: "")
    private let allow = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    init() { super.init(size: NSSize(width: 760, height: 800)) }
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        stack.addArrangedSubview(label("Check your Mac without changing it", size: 17, weight: .semibold))
        stack.addArrangedSubview(label("Mac Doctor looks at storage and caches, folder sizes, speed and memory, apps that won’t open, external drives, the network, programs that start by themselves, battery and sleep. It explains what it finds in plain words.", secondary: true))
        openButton = ToolUI.button("Open Mac Doctor…", target: self, action: #selector(open))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let row = NSStackView(views: [openButton, hint])
        row.spacing = 10
        stack.addArrangedSubview(row)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(label("Safe by design", size: 13, weight: .semibold))
        for line in [
            "Checks only read. A fix runs only when you choose it and confirm: moving caches to the Trash (you can put them back), ejecting a drive, or opening the right page of System Settings.",
            "No special permissions: no Full Disk Access, Accessibility or Screen Recording. Protected places such as Documents, Mail and other apps’ data are skipped. Commands that need an administrator are shown with an explanation, never run.",
            "It never removes an app’s downloaded flag or turns off Gatekeeper, and never tells you to open an app Apple has blocked.",
            "Only three things use the network, each when you start it: Test Speed (Apple’s network test), App Check (Gatekeeper may ask Apple about notarization) and Ask the Assistant.",
        ] {
            stack.addArrangedSubview(label("• " + L(line), size: 12, secondary: true))
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(label("Assistant (optional)", size: 13, weight: .semibold))
        allow.title = L("Let Mac Doctor ask the assistant to explain results")
        allow.target = self
        allow.action = #selector(allowChanged)
        stack.addArrangedSubview(allow)
        assistant.font = .systemFont(ofSize: 12)
        assistant.textColor = .secondaryLabelColor
        assistant.preferredMaxLayoutWidth = 760 - 64
        stack.addArrangedSubview(assistant)
        stack.addArrangedSubview(ToolUI.button("Assistant Settings…", target: self, action: #selector(assistantSettings)))
        stack.addArrangedSubview(label("Cache list from ClearDisk by Kadir Can Ozden (MIT License).", size: 11, secondary: true))
    }

    override func refresh() {
        let on = Feature.doctor.isOn
        openButton?.isEnabled = on
        hint.stringValue = on ? "" : L("Turn this feature on above to get started.")
        allow.state = DoctorSettings.allowAssistant ? .on : .off
        allow.isEnabled = on
        let settings = Prefs.assistant
        assistant.stringValue = !Assistant.isConfigured
            ? L("Set up a service and key in Quick Actions settings first. Mac Doctor works fully without the assistant.")
            : L("Each time, you see the exact text first: results only, with addresses, user and computer names and serial numbers replaced, and no file names, paths or contents. Names of caches, apps and background items are added only if you tick the box. It is sent to %@ only when you choose Send.", Assistant.host(settings))
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 760 - 64).isActive = true
        return box
    }

    @objc private func open() { DoctorWindow.present() }
    @objc private func allowChanged() { DoctorSettings.allowAssistant = allow.state == .on }
    @objc private func assistantSettings() { AppWindow.shared.show(.quickActions) }
}
