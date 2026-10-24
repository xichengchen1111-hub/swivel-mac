import AppKit

/// Settings → General → Agents: what `Swivel --mcp` offers and how to add it to an AI app.
@MainActor
final class MCPSetupView: NSStackView {
    let status = NSTextField(labelWithString: "")
    /// Where the copied setup goes. Tests use a private pasteboard.
    var pasteboard = NSPasteboard.general
    /// Claude Desktop, if installed. Tests replace it.
    var claudeApp: () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: MCPSetupView.claudeBundleID) }
    /// The extension shipped in this app's Resources (build.sh packs it).
    var bundledExtension: () -> URL? = { Bundle.main.url(forResource: "Swivel", withExtension: "mcpb") }
    /// Opens the extension with Claude, which asks the user to install it. Tests record the call instead.
    var openWithApp: (URL, URL) -> Void = { file, app in
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    private var generation = 0

    nonisolated static let claudeBundleID = "com.anthropic.claudefordesktop"
    /// Where the extension's launcher (mcpb/server/swivel-mcp) looks for Swivel, in its order.
    nonisolated static var launcherLocations: [String] {
        ["/Applications/Swivel.app", NSHomeDirectory() + "/Applications/Swivel.app", NSHomeDirectory() + "/Desktop/Swivel.app"]
    }

    init(width: CGFloat = 440) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let blurb = NSTextField(wrappingLabelWithString: L("AI apps such as Claude Desktop, Claude Code, Codex and Cursor can use Swivel's file tools on the files they pass. Changes are planned first, saved next to the originals and can be undone. Nothing listens on the network."))
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = width
        let claude = NSButton(title: L("Install in Claude Desktop"), target: self, action: #selector(installClaude))
        let code = NSButton(title: L("Copy Claude Code Setup"), target: self, action: #selector(copyClaudeCode))
        let codex = NSButton(title: L("Copy Codex Setup"), target: self, action: #selector(copyCodex))
        let first = NSStackView(views: [claude])
        let second = NSStackView(views: [code, codex])
        second.spacing = 8
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        status.preferredMaxLayoutWidth = width
        status.cell?.wraps = true
        for view in [blurb, first, second, status] { addArrangedSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// This copy of Swivel, wherever it's installed.
    nonisolated static var command: String { Bundle.main.executablePath ?? "/Applications/Swivel.app/Contents/MacOS/Swivel" }

    /// For claude_desktop_config.json (Claude → Settings → Developer → Edit Config). Only holds while Claude is
    /// quit: a running Claude rewrites the file from memory and drops entries added meanwhile.
    static func claudeConfig(command: String = command) -> String {
        let config: [String: Any] = ["mcpServers": ["swivel": ["command": command, "args": ["--mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// For Terminal: Claude Code keeps user-scope servers in ~/.claude.json.
    static func claudeCodeCommand(command: String = command) -> String {
        "claude mcp add --scope user swivel -- \(shellQuoted(command)) --mcp"
    }

    /// For ~/.codex/config.toml.
    static func codexConfig(command: String = command) -> String {
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "[mcp_servers.swivel]\ncommand = \"\(quoted)\"\nargs = [\"--mcp\"]\n"
    }

    /// A path as one shell word: left alone when plain, otherwise single-quoted.
    static func shellQuoted(_ text: String) -> String {
        if text.wholeMatch(of: #/[A-Za-z0-9_./+-]+/#) != nil { return text }
        return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The extension's launcher starts an installed Swivel, so it only helps when one is where it looks.
    nonisolated static func launcherFindsSwivel(in locations: [String] = launcherLocations) -> Bool {
        locations.contains { FileManager.default.isExecutableFile(atPath: $0 + "/Contents/MacOS/Swivel") }
    }

    @objc func installClaude() {
        if let app = claudeApp(), let file = bundledExtension(), Self.launcherFindsSwivel() {
            openWithApp(file, app)
            show(L("Opening the Swivel extension in Claude. Click Install there; it stays after Claude restarts."))
        } else {
            copy(Self.claudeConfig(), L("Copied. Quit Claude first (a running Claude rewrites its config file), then add the “swivel” entry to “mcpServers” in claude_desktop_config.json and open Claude again."))
        }
    }

    @objc func copyClaudeCode() {
        copy(Self.claudeCodeCommand(), L("Copied. Paste it into Terminal and press Return, then start a new Claude Code session."))
    }

    @objc func copyCodex() {
        copy(Self.codexConfig(), L("Copied. Add it to ~/.codex/config.toml, then restart Codex."))
    }

    private func copy(_ text: String, _ message: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        show(message)
    }

    private func show(_ message: String) {
        status.stringValue = message
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.generation == current else { return }
            self.status.stringValue = ""
        }
    }
}
