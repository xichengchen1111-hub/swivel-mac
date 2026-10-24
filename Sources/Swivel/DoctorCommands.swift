import Foundation

/// Every command Mac Doctor can run. Each case is a fixed system tool with fixed arguments; the only things spliced
/// in are values checked against a strict pattern first: the path of an app the user picked, a drive's mount point,
/// a disk identifier or a launchd label. No case takes free text or needs an administrator, so there is no code path
/// that could run one of the `DoctorAdminCommand`s shown to the user. Only `eject` changes anything, and only when
/// the user chooses Eject.
enum DoctorCommand: Sendable, Equatable {
    /// APFS local snapshots of the startup volume.
    case localSnapshots
    /// The resolver configuration: which DNS servers macOS uses.
    case dnsConfiguration
    /// The system proxy settings.
    case proxySettings
    /// Jobs loaded in this user's session, as tab-separated PID, status and label.
    case launchdUserJobs
    /// Whether one daemon is loaded (exit status 0) in the system domain.
    case launchdSystemService(String)
    /// Two one-second samples of every process, busiest first (top is installed setuid, so it sees system processes).
    case processCPU
    /// Every process by memory use.
    case processMemory
    /// Apple's network speed test: about 20 seconds of test traffic to Apple's servers.
    case networkQuality
    /// Gatekeeper's verdict on an app, as a property list. It may ask Apple whether the app is notarized.
    case gatekeeperAssessment(URL)
    /// Whether an app's signature is intact. Not --strict: that also fails harmless Finder metadata.
    case codeSignature(URL)
    /// External disks, mounted or not.
    case externalDisks
    /// One disk's details: physical or a disk image, bus, ejectable.
    case diskInfo(String)
    /// Unmounts and ejects the drive holding this volume, as Finder's Eject does. Never forced.
    case eject(URL)

    var tool: String {
        switch self {
        case .localSnapshots: "/usr/bin/tmutil"
        case .dnsConfiguration, .proxySettings: "/usr/sbin/scutil"
        case .launchdUserJobs, .launchdSystemService: "/bin/launchctl"
        case .processCPU, .processMemory: "/usr/bin/top"
        case .networkQuality: "/usr/bin/networkQuality"
        case .gatekeeperAssessment: "/usr/sbin/spctl"
        case .codeSignature: "/usr/bin/codesign"
        case .externalDisks, .diskInfo, .eject: "/usr/sbin/diskutil"
        }
    }

    var arguments: [String] {
        switch self {
        case .localSnapshots: ["listlocalsnapshots", "/"]
        case .dnsConfiguration: ["--dns"]
        case .proxySettings: ["--proxy"]
        case .launchdUserJobs: ["list"]
        case .launchdSystemService(let label): ["print", "system/" + label]
        case .processCPU: ["-l", "2", "-s", "1", "-n", "12", "-o", "cpu", "-stats", "pid,cpu,mem,command"]
        case .processMemory: ["-l", "1", "-n", "12", "-o", "mem", "-stats", "pid,cpu,mem,command"]
        // -c (computer-readable) takes an optional file name, so it goes last.
        case .networkQuality: ["-M", "30", "-c"]
        case .gatekeeperAssessment(let app): ["--assess", "--type", "execute", "--raw", "--no-cache", "--", app.path]
        case .codeSignature(let app): ["--verify", "--deep", "--", app.path]
        case .externalDisks: ["list", "-plist", "external"]
        case .diskInfo(let disk): ["info", "-plist", disk]
        case .eject(let volume): ["eject", volume.path]
        }
    }

    var timeout: TimeInterval {
        switch self {
        case .localSnapshots, .launchdUserJobs, .externalDisks, .diskInfo, .processCPU, .processMemory: 15
        case .dnsConfiguration, .proxySettings, .launchdSystemService: 10
        case .networkQuality: 50
        case .eject: 60
        // Large apps (Xcode is several GB) take a while to hash, more on slower Macs.
        case .gatekeeperAssessment, .codeSignature: 150
        }
    }

    /// The most stdout bytes kept; the rest is read and dropped so the tool never blocks.
    var outputLimit: Int {
        switch self {
        case .launchdSystemService: 4 << 10  // only the exit status matters
        case .launchdUserJobs, .externalDisks, .diskInfo: 1 << 20
        default: 512 << 10
        }
    }

    /// True for the commands that send something over the network, so the UI says so before running them.
    var usesNetwork: Bool {
        switch self {
        case .networkQuality, .gatekeeperAssessment: true
        default: false
        }
    }

    /// True for the one command that changes something (Eject).
    var changesState: Bool {
        if case .eject = self { return true }
        return false
    }

    /// The command as the user could type it, for the "what Mac Doctor ran" details. Paths inside the home folder
    /// start with "~".
    var displayString: String {
        ([tool] + arguments.map(Self.quoted)).joined(separator: " ")
    }

    private static func quoted(_ argument: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shown = argument.hasPrefix(home + "/") ? "~" + argument.dropFirst(home.count) : argument
        let plain = shown.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/._-~:,".contains($0)) }
        return plain ? shown : "'" + DoctorText.visible(shown).replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Validation

    /// No control, line-break or invisible character anywhere: tools echo paths, and a line break in a folder name
    /// could otherwise forge a line of their output.
    static func isPlain(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || scalar == "\u{85}" || scalar == "\u{2028}"
                || scalar == "\u{2029}" || AssistantDraft.isHidden(scalar)
        }
    }

    /// A picked app as the real folder it is (links resolved once, so every check looks at the same thing), or nil
    /// for anything that isn't an existing .app folder with a plain path.
    static func validatedApp(_ url: URL) -> URL? {
        guard url.isFileURL, isPlain(url.path), let real = realpath(url.path, nil) else { return nil }
        defer { free(real) }
        let path = String(cString: real)
        guard path.hasPrefix("/"), isPlain(path), path.lowercased().hasSuffix(".app") else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A mounted volume under /Volumes with a plain name.
    static func validatedVolume(_ url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "Volumes", !parts[2].isEmpty, parts[2] != "..",
              isPlain(path), !path.hasPrefix("-") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// "disk4" or "disk4s1".
    static func isDiskIdentifier(_ text: String) -> Bool {
        text.range(of: #"^disk[0-9]{1,3}(s[0-9]{1,3})?$"#, options: .regularExpression) != nil
    }

    /// Reverse-DNS style labels only, so a label can never reach another launchd domain or read as an option.
    static func isSafeLabel(_ text: String) -> Bool {
        text.count <= 200 && text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}

/// A command only an administrator can run. Mac Doctor never runs these: it shows them, explains them and offers
/// to copy them, so the user decides whether to run them in Terminal. Always compile-time text: never a label, a
/// path, a process name or anything an assistant wrote.
struct DoctorAdminCommand: Sendable, Equatable {
    let command: String
    /// English; translated where it is shown.
    let explanation: String

    /// Private: the three constants below are the only admin commands that can exist.
    private init(command: String, explanation: String) {
        self.command = command
        self.explanation = explanation
    }

    static let deleteLocalSnapshots = DoctorAdminCommand(
        command: "sudo tmutil deletelocalsnapshots /",
        explanation: "Usually not needed: macOS removes local snapshots by itself when space runs low. This deletes all of them at once and asks for an administrator password.")
    static let flushDNS = DoctorAdminCommand(
        command: "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder",
        explanation: "Usually not needed: restarting the Mac does the same. Clears the DNS cache and asks for an administrator password.")
    static let listBackgroundItems = DoctorAdminCommand(
        command: "sudo sfltool dumpbtm",
        explanation: "Lists every login and background item macOS knows about, including other users'. Read-only, but it asks for an administrator password.")

    static let all: [DoctorAdminCommand] = [.deleteLocalSnapshots, .flushDNS, .listBackgroundItems]
}

/// What a finished command printed. A non-zero exit is not an error here: several tools report their findings
/// through it (spctl exits 3 for a rejected app, launchctl 113 for a service that isn't loaded).
struct DoctorOutput: Sendable, Equatable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var truncated = false
    var timedOut = false

    var text: String { String(decoding: stdout, as: UTF8.self) }
    var errorText: String { String(decoding: stderr, as: UTF8.self) }
}

extension Shell {
    /// Runs one of Mac Doctor's fixed commands and returns what it printed.
    static func capture(_ command: DoctorCommand) async throws -> DoctorOutput {
        try await capture(command.tool, command.arguments, timeout: command.timeout, limit: command.outputLimit)
    }

    /// Runs a tool with an empty stdin and a fixed environment, reading stdout (up to `limit` bytes, in order) and
    /// the last 16 KB of stderr while it runs. After `timeout` seconds it is stopped, then killed. Cancelling the
    /// task stops it and throws `CancellationError`.
    static func capture(_ tool: String, _ args: [String], timeout: TimeInterval, limit: Int) async throws -> DoctorOutput {
        // A check that was stopped launches nothing more.
        try Task.checkCancellation()
        let run = ShellCapture(tool: tool, args: args, timeout: timeout, limit: limit)
        return try await withTaskCancellationHandler {
            try await run.start()
        } onCancel: {
            run.cancel()
        }
    }
}

/// One `Shell.capture` run; its state is shared with Foundation's callback threads behind a lock.
final class ShellCapture: @unchecked Sendable {
    private let process = Process()
    private let timeout: TimeInterval
    private let limit: Int
    private let lock = NSLock()
    private var output = Data(), errorTail = Data()
    private var truncated = false, timedOut = false, cancelled = false, finished = false
    private var continuation: CheckedContinuation<DoctorOutput, Error>?
    private var timers: [DispatchSourceTimer] = []
    private var pipes: [Pipe] = []
    private static let keptErrorBytes = 16_384

    init(tool: String, args: [String], timeout: TimeInterval, limit: Int) {
        self.timeout = timeout
        self.limit = limit
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A known environment: nothing inherited (no DYLD_*, no proxy or locale surprises), English output.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                               "HOME": home, "TMPDIR": NSTemporaryDirectory()]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
    }

    private static let registry = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: ShellCapture] = [:]
    /// Stops every running capture (Swivel is quitting).
    static func stopAll() {
        let all = registry.withLock { Array(running.values) }
        for run in all { run.cancel() }
        for run in all where run.process.isRunning { run.process.waitUntilExit() }
    }
    private static func track(_ run: ShellCapture, _ active: Bool) {
        registry.withLock { running[ObjectIdentifier(run)] = active ? run : nil }
    }

    func start() async throws -> DoctorOutput {
        Self.track(self, true)
        defer { Self.track(self, false) }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DoctorOutput, Error>) in
            let out = Pipe(), err = Pipe()
            lock.withLock { continuation = cont; pipes = [out, err] }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
            // Three things must happen before the result is final: the tool exits and both pipes reach EOF.
            // Each pipe's handler runs on its own serial queue, so chunks arrive in order.
            let group = DispatchGroup()
            group.enter(); group.enter(); group.enter()
            out.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; group.leave() } else { self?.keepOutput(data) }
            }
            err.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; group.leave() } else { self?.keepError(data) }
            }
            process.terminationHandler = { [weak self] _ in
                group.leave()
                // A grandchild that inherited a pipe could keep it open forever: give it two seconds.
                self?.after(2) { $0.finish() }
            }
            group.notify(queue: .global(qos: .utility)) { [weak self] in self?.finish() }
            if lock.withLock({ cancelled }) {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                return finish(throwing: CancellationError())
            }
            do { try process.run() } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                return finish(throwing: error)
            }
            if lock.withLock({ cancelled }) { process.terminate() }
            after(timeout) { run in
                run.lock.withLock { run.timedOut = true }
                run.process.terminate()
                run.after(2) { run in
                    if run.process.isRunning { kill(run.process.processIdentifier, SIGKILL) }
                    run.after(2) { $0.finish() }
                }
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        if process.isRunning { process.terminate() }
        after(2) { run in
            if run.process.isRunning { kill(run.process.processIdentifier, SIGKILL) }
            run.finish()
        }
    }

    private func after(_ seconds: TimeInterval, _ work: @escaping @Sendable (ShellCapture) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in if let self { work(self) } }
        lock.withLock { timers.append(timer) }
        timer.resume()
    }

    private func keepOutput(_ data: Data) {
        lock.withLock {
            let room = limit - output.count
            if room >= data.count { output.append(data) } else {
                if room > 0 { output.append(data.prefix(room)) }
                truncated = true
            }
        }
    }

    private func keepError(_ data: Data) {
        lock.withLock {
            errorTail.append(data)
            if errorTail.count > Self.keptErrorBytes { errorTail = errorTail.suffix(Self.keptErrorBytes) }
        }
    }

    private func finish(throwing error: Error? = nil) {
        let (cont, result): (CheckedContinuation<DoctorOutput, Error>?, Result<DoctorOutput, Error>) = lock.withLock {
            guard !finished else { return (nil, .failure(CancellationError())) }
            finished = true
            for timer in timers { timer.cancel() }
            timers = []
            for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
            let cont = continuation
            continuation = nil
            if let error { return (cont, .failure(error)) }
            if cancelled { return (cont, .failure(CancellationError())) }
            let status = process.isRunning ? -1 : process.terminationStatus
            return (cont, .success(DoctorOutput(status: status, stdout: output, stderr: errorTail,
                                                truncated: truncated, timedOut: timedOut)))
        }
        cont?.resume(with: result)
    }
}
