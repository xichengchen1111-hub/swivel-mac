import AppKit
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Text from the Mac (labels, process names, volume names) made safe to show and to report.
enum DoctorText {
    /// Characters a reader couldn't see are written out as \u{…}, so a name can't disguise itself.
    static func visible(_ text: String, limit: Int = 200) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if out.count >= limit { return out + "…" }
            if scalar == "\n" || scalar == "\t" || scalar == "\r" { out += " "; continue }
            // macOS itself puts these spaces in names (screenshots: "7.16.16 pm"): show a plain space, not a code.
            if scalar == "\u{202F}" || scalar == "\u{00A0}" { out += " "; continue }
            if AssistantDraft.isHidden(scalar) || scalar.properties.generalCategory == .control {
                out += String(format: "\\u{%04X}", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// True when a name hides characters or mixes Latin with look-alike letters (Cyrillic "а" in "com.аpple").
    static func isUnusual(_ text: String) -> Bool {
        if visible(text, limit: .max) != text { return true }
        var latin = false, lookalike = false
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: latin = true
            case 0x0370...0x03FF, 0x0400...0x052F: lookalike = true
            default: break
            }
        }
        return latin && lookalike
    }

    /// A name usable for a new folder: no separators, no invisible characters.
    static func fileName(_ text: String) -> String {
        let cleaned = visible(text, limit: 120).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.hasPrefix(".") ? "_" + cleaned : cleaned
    }

    /// For the assistant report: reverse-DNS style labels only.
    static func reportLabel(_ text: String) -> String {
        text.count <= 128 && text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
            ? text : "<unusual name>"
    }

    /// For the assistant report: short plain process and app names only.
    static func reportName(_ text: String) -> String {
        text.count <= 32 && text.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._()-]*$"#, options: .regularExpression) != nil
            ? text : "<unusual name>"
    }
}

// MARK: - Slow or Hot

enum DoctorPerformance {
    struct Memory: Sendable, Equatable {
        /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
        var pressure: Int32
        var swapUsed: Int64
        var physical: Int64
    }

    /// Time since the last restart, sleep included (systemUptime leaves sleep out).
    static func timeSinceRestart() -> TimeInterval {
        var boot = timeval()
        var length = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &length, nil, 0) == 0, boot.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        return Date().timeIntervalSince1970 - TimeInterval(boot.tv_sec)
    }

    static func memory() -> Memory {
        var level: Int32 = 0
        var length = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) != 0 { level = 0 }
        var swap = xsw_usage()
        var swapLength = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapLength, nil, 0) != 0 { swap = xsw_usage() }
        return Memory(pressure: level, swapUsed: Int64(swap.xsu_used), physical: Int64(ProcessInfo.processInfo.physicalMemory))
    }

    /// What well-known system processes do, so a busy one reads as a reason rather than an alarm. English.
    static let known: [String: String] = [
        "kernel_task": "macOS itself. When it uses a lot, it is often slowing the Mac down on purpose to cool it.",
        "WindowServer": "Draws everything on screen. Many windows, displays or animations make it busier.",
        "mds": "Spotlight is indexing files. It calms down by itself when it has finished.",
        "mds_stores": "Spotlight is indexing files. It calms down by itself when it has finished.",
        "mdworker_shared": "Spotlight is indexing files. It calms down by itself when it has finished.",
        "photoanalysisd": "Photos is analysing your library for faces and search. It runs mostly while the Mac is idle.",
        "mediaanalysisd": "Photos is analysing your library for faces and search. It runs mostly while the Mac is idle.",
        "bird": "iCloud Drive is syncing.",
        "cloudd": "iCloud is syncing.",
        "fileproviderd": "Cloud storage (iCloud Drive, OneDrive, Google Drive) is syncing files.",
        "backupd": "Time Machine is backing up.",
        "softwareupdated": "macOS is checking for or preparing an update.",
        "XProtect": "Apple’s built-in malware protection is checking files.",
        "syspolicyd": "Gatekeeper is checking an app.",
        "corespotlightd": "Spotlight is indexing app content.",
    ]

    /// One row per process, from `top`: busiest first, then largest. System processes included.
    static func check(cpu: [DoctorParse.ProcessUse], memory: [DoctorParse.ProcessUse], state: Memory,
                      thermal: ProcessInfo.ThermalState, uptime: TimeInterval) -> DoctorResult {
        var result = DoctorResult(section: .performance, severity: .ok, badge: "", headline: "")
        let me = Int(getpid())
        let busy = cpu.filter { $0.cpu >= 10 && $0.pid != me && $0.command != "top" }.prefix(6)
        let large = memory.filter { $0.pid != me }.prefix(6)
        func name(_ process: DoctorParse.ProcessUse) -> String {
            NSRunningApplication(processIdentifier: pid_t(process.pid))?.localizedName ?? process.command
        }
        for process in busy {
            let shown = DoctorText.visible(name(process))
            let reason = known[process.command].map(L) ?? L("Processor use over one second. 100% is one full core.")
            result.rows.append(DoctorRow(id: "cpu.\(process.pid)", title: shown, value: L("%d%% CPU", Int(process.cpu.rounded())),
                                         detail: reason, severity: process.cpu >= 80 ? .review : .info))
        }
        for process in large {
            let shown = DoctorText.visible(name(process))
            result.rows.append(DoctorRow(id: "memory.\(process.pid)", title: shown, value: DoctorFormat.bytes(process.memory),
                                         detail: known[process.command].map(L) ?? L("Memory this app is using now."),
                                         severity: .info, bytes: process.memory))
        }
        let hot = busy.first { $0.cpu >= 80 }
        switch state.pressure {
        case 4:
            result.severity = .problem
            result.headline = L("Your Mac is very short of memory. Quit apps you don’t need, starting with the largest.")
        case 2:
            result.severity = .review
            result.headline = L("Your Mac is short of memory, so it is using the disk to make room. Quitting large apps will help.")
        default:
            if let hot {
                result.severity = .review
                result.headline = known[hot.command] != nil
                    ? L("A system task is keeping the processor busy. It usually finishes by itself.")
                    : L("One app is keeping the processor busy. If the Mac feels slow, quit or restart that app.")
            } else {
                result.headline = L("Memory is fine and nothing is keeping the processor busy.")
            }
        }
        result.badge = state.pressure >= 2 ? L("Memory low") : (hot != nil ? L("Busy") : L("Normal"))
        if state.swapUsed > 0 {
            result.notes.append(L("Swap in use: %@ of memory moved to the disk.", DoctorFormat.bytes(state.swapUsed)))
        }
        switch thermal {
        case .serious, .critical:
            result.severity = max(result.severity, thermal == .critical ? .problem : .review)
            result.notes.append(L("The Mac is hot and has slowed itself down to cool off. Check that its vents aren’t covered."))
        case .fair:
            result.notes.append(L("The Mac is warm; macOS may slow it down a little."))
        default: break
        }
        let days = Int(uptime / 86_400)  // since the last restart
        if days >= 14 {
            result.notes.append(L("Your Mac has been running for %d days. Restarting now and then clears memory and finishes updates.", days))
        }
        result.notes.append(L("To quit an app that doesn’t respond, press Option-Command-Esc."))
        let level = switch state.pressure { case 4: L("critical"); case 2: L("warning"); default: L("normal") }
        result.report.append(L("Memory pressure: %@. Swap in use: %@ of %@ memory. Thermal state: %d of 3. Running for %d days.",
                               level, DoctorFormat.bytes(state.swapUsed), DoctorFormat.bytes(state.physical),
                               thermal.rawValue, days))
        result.report.append(L("Busy processes: %d; the busiest uses %d%% CPU.", busy.count, Int(busy.first?.cpu.rounded() ?? 0)))
        result.names += busy.map { "\(DoctorText.reportName(name($0))): \(Int($0.cpu.rounded()))% CPU" }
        result.names += large.map { "\(DoctorText.reportName(name($0))): \(DoctorFormat.bytes($0.memory))" }
        return result
    }
}

// MARK: - Battery & Sleep

enum DoctorBattery {
    struct Health: Sendable, Equatable {
        var cycles: Int
        var designCycles: Int?
        /// Full charge compared with when it was new, 0–1.
        var capacity: Double?
        var onPower: Bool
        var charging: Bool
    }

    static var hasBattery: Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// Read from the battery's own registry entry; no serial numbers are kept.
    static func health() -> Health? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        func int(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue }
        let design = int("DesignCapacity") ?? 0
        let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0
        return Health(cycles: int("CycleCount") ?? 0, designCycles: int("DesignCycleCount9C"),
                      capacity: design > 0 && full > 0 ? min(1.2, Double(full) / Double(design)) : nil,
                      onPower: values["ExternalConnected"] as? Bool ?? false,
                      charging: values["IsCharging"] as? Bool ?? false)
    }

    static func rows(_ health: Health) -> (rows: [DoctorRow], severity: DoctorSeverity, report: String) {
        var rows: [DoctorRow] = []
        var severity = DoctorSeverity.ok
        if let capacity = health.capacity {
            let percent = Int((capacity * 100).rounded())
            let worn = capacity < 0.8
            if worn { severity = .review }
            rows.append(DoctorRow(id: "battery.capacity", title: L("Battery capacity (estimate)"), value: L("about %d%%", percent),
                                  detail: worn ? L("By the battery’s own numbers it holds less than 80% of its original charge. Check its condition in System Settings → Battery → Battery Health.")
                                               : L("How much charge the battery holds compared with when it was new, from its own numbers; System Settings may round it differently."),
                                  severity: worn ? .review : .ok))
        }
        rows.append(DoctorRow(id: "battery.cycles", title: L("Charge cycles"),
                              value: health.designCycles.map { L("%d of %d", health.cycles, $0) } ?? "\(health.cycles)",
                              detail: L("One cycle is a full battery’s worth of use, spread over several charges."), severity: .info))
        rows.append(DoctorRow(id: "battery.state", title: L("Power"),
                              value: health.onPower ? (health.charging ? L("Charging") : L("Connected")) : L("On battery"),
                              detail: L("Keeping it plugged in is fine: macOS learns your routine and holds the charge lower with Optimized Charging or a charge limit in Battery settings."),
                              severity: .info))
        let report = L("Battery: capacity about %d%% of new (estimate), %d charge cycles, %@.", Int(((health.capacity ?? 0) * 100).rounded()),
                       health.cycles, health.onPower ? L("on power") : L("on battery"))
        return (rows, severity, report)
    }
}

enum DoctorPower {
    struct Assertion: Sendable, Equatable {
        let pid: Int
        let process: String
        /// What the assertion really does (AssertionTrueType, which maps old names), e.g. "PreventUserIdleSystemSleep".
        let type: String
        /// The reason the app gave, e.g. "Playing audio". Free text: shown escaped, never reported.
        let name: String
        let since: Date?
        let hasTimeout: Bool
        /// The process lives in /System or /usr.
        let system: Bool
        let ownedBySwivel: Bool
    }

    static let systemSleepTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep"]
    static let displaySleepTypes: Set<String> = ["PreventUserIdleDisplaySleep"]

    /// Same data as `pmset -g assertions`, read in-process. Only active assertions that keep the Mac or its display
    /// awake; the holder is the app it acts for (runningboardd and friends create assertions on behalf of apps).
    static func assertions(ownIDs: Set<UInt32> = []) -> [Assertion] {
        var dictionary: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictionary) == kIOReturnSuccess,
              let all = dictionary?.takeRetainedValue() as? [AnyHashable: Any] else { return [] }
        var result: [Assertion] = []
        let me = Int(getpid())
        for (key, value) in all {
            guard let list = value as? [[String: Any]] else { continue }
            let creator = (key as? NSNumber)?.intValue ?? 0
            for item in list {
                guard (item["AssertLevel"] as? NSNumber)?.intValue == 255 else { continue }
                let type = item["AssertionTrueType"] as? String ?? item["AssertType"] as? String ?? ""
                guard systemSleepTypes.contains(type) || displaySleepTypes.contains(type) else { continue }
                let name = item["AssertName"] as? String ?? ""
                let pid = (item["AssertionOnBehalfOfPID"] as? NSNumber)?.intValue ?? creator
                let processName = processName(pid) ?? item["Process Name"] as? String ?? "PID \(pid)"
                // powerd's own "keep awake while the display is on" is always there and means nothing.
                if processName == "powerd" { continue }
                let id = (item["AssertionId"] as? NSNumber)?.uint32Value ?? 0
                result.append(Assertion(pid: pid, process: processName, type: type, name: name,
                                        since: item["AssertStartWhen"] as? Date,
                                        hasTimeout: ((item["TimeoutSeconds"] as? NSNumber)?.doubleValue ?? 0) > 0,
                                        system: isSystem(pid), ownedBySwivel: creator == me && (ownIDs.isEmpty || ownIDs.contains(id))))
            }
        }
        return result
    }

    private static func processName(_ pid: Int) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let name = app.localizedName { return name }
        var buffer = [CChar](repeating: 0, count: 256)
        return proc_name(pid_t(pid), &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    private static func isSystem(_ pid: Int) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count)) > 0 else { return true }  // not ours to read: system
        let path = String(cString: buffer)
        // Tools someone starts on purpose (caffeinate, anything in /usr/bin) are ordinary holders, not macOS tasks.
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
    }

    static func check(_ assertions: [Assertion], battery: DoctorBattery.Health?, now: Date = Date()) -> DoctorResult {
        var result = DoctorResult(section: .power, severity: .ok, badge: "", headline: "")
        result.panes = [.battery, .lockScreen]
        if let battery {
            let summary = DoctorBattery.rows(battery)
            result.rows += summary.rows
            result.severity = summary.severity
            result.report.append(summary.report)
        }
        var flagged = 0
        for item in assertions.sorted(by: { ($0.since ?? now) < ($1.since ?? now) }) {
            let display = displaySleepTypes.contains(item.type)
            let hours = item.since.map { now.timeIntervalSince($0) / 3600 } ?? 0
            // Long-held by an ordinary app is worth a look; system and temporary ones are normal.
            let long = hours >= 1 && !item.system && !item.hasTimeout && !item.ownedBySwivel
            if long { flagged += 1 }
            var detail = item.name.isEmpty ? "" : "“" + DoctorText.visible(item.name, limit: 120) + "”"
            if let since = item.since { detail += (detail.isEmpty ? "" : " · ") + L("since %@", DoctorFormat.date(since)) }
            if item.ownedBySwivel { detail += " · " + L("This is Swivel’s Keep Awake. Turn it off there.") }
            else if item.system || item.hasTimeout { detail += " · " + L("A macOS task; it lets go by itself.") }
            result.rows.append(DoctorRow(id: "power.\(item.pid).\(item.type).\(item.name.hashValue)",
                                         title: DoctorText.visible(item.process),
                                         value: display ? L("Keeps the display on") : L("Keeps the Mac awake"),
                                         detail: detail, severity: long ? .review : .info))
        }
        let apps = Set(assertions.map(\.process)).count
        if flagged > 0 { result.severity = max(result.severity, .review) }
        if assertions.isEmpty {
            result.headline = L("Nothing is keeping your Mac awake. It sleeps as set in System Settings.")
        } else if flagged == 0 {
            result.headline = L("%d apps are keeping your Mac or its display awake for now. That is normal while a video plays, a call runs or a download finishes.", apps)
        } else {
            result.headline = L("%d apps have kept your Mac awake for over an hour. If it should be asleep, quit them or stop what they are doing.", flagged)
        }
        result.badge = battery.flatMap { $0.capacity.map { L("Battery about %d%%", Int(($0 * 100).rounded())) } }
            ?? (assertions.isEmpty ? L("Normal") : L("%d awake", apps))
        result.notes.append(L("Terminal shows the same list with: pmset -g assertions"))
        result.report.append(L("Apps keeping the Mac awake: %d, held for over an hour by ordinary apps: %d.", apps, flagged))
        result.names += assertions.filter { !$0.system }.map { DoctorText.reportName($0.process) }
        return result
    }
}

// MARK: - Network

enum DoctorNetwork {
    static func check(dns: DoctorOutput?, proxy: DoctorOutput?) -> DoctorResult {
        var result = DoctorResult(section: .network, severity: .ok, badge: "", headline: "")
        result.panes = [.network, .wifi]
        result.adminCommands = [.flushDNS]
        result.ran = [DoctorCommand.dnsConfiguration.displayString, DoctorCommand.proxySettings.displayString]
        let settings = proxy.flatMap { $0.status == 0 ? DoctorParse.proxy($0.text) : nil }
        if let settings, settings.isOn {
            let servers = settings.servers.map { "\($0.kind) \(DoctorText.visible($0.address))" }
            result.rows.append(DoctorRow(id: "proxy", title: L("System proxy"), value: L("On"),
                                         detail: settings.autoConfig && servers.isEmpty ? L("Set by an automatic configuration file.")
                                                 : L("Set by a proxy or VPN app: %@", servers.joined(separator: ", ")),
                                         severity: .info))
            result.notes.append(L("A proxy app is handling your connections. If some websites don’t load, check that app first, or turn it off to test."))
        }
        guard let dns, dns.status == 0 else {
            result.severity = .info
            result.headline = L("Mac Doctor couldn’t read the DNS settings.")
            return result
        }
        let main = DoctorParse.defaultResolvers(dns.text)
        let servers = main.flatMap(\.nameservers)
        var kinds: [DoctorParse.AddressKind] = []
        for (index, server) in servers.enumerated() {
            let kind = DoctorParse.kind(ofAddress: server)
            kinds.append(kind)
            let meaning: String = switch kind {
            case .privateNetwork, .ipv6Global: L("Provided by your router")
            case .loopback: L("Handled by an app on this Mac (often a VPN or filter)")
            case .proxyApp: L("Handled by a proxy app")
            case .linkLocal: L("A device on the local network")
            case .sharedCarrier: L("Your internet provider or a VPN")
            case .publicNetwork: DoctorParse.publicService(server).map { L("Public DNS service: %@", $0) }
                ?? L("A server on the internet, usually your provider’s")
            case .unknown: L("Unrecognised address")
            }
            result.rows.append(DoctorRow(id: "dns.\(index)", title: DoctorText.visible(server), value: meaning,
                                         detail: L("DNS server: finds the address of each website you visit."), severity: .info))
        }
        let corporate = main.contains { !$0.searchDomains.isEmpty }
        if servers.isEmpty {
            result.severity = .problem
            result.headline = L("Your Mac has no DNS server, so websites can’t be found. Check that Wi-Fi or Ethernet is connected.")
            result.badge = L("No DNS")
        } else {
            let chosen = servers.contains { DoctorParse.publicService($0) != nil }
            let viaProxy = kinds.contains(.proxyApp) || kinds.contains(.loopback)
            result.headline = viaProxy ? L("DNS is handled by a VPN, proxy or filter app on this Mac.")
                : chosen ? L("Your Mac uses a public DNS service you or an app chose.")
                : L("DNS comes from your network, as usual.")
            result.badge = settings?.isOn == true ? L("Proxy on") : L("Connected")
            result.notes.append(L("If websites don’t load but other apps work: turn Wi-Fi off and on, restart the router, or try another network. Test Speed shows whether the connection itself is slow."))
        }
        let kindNames = Set(kinds.map(Self.kindName)).sorted().joined(separator: ", ")
        result.report.append(L("DNS servers: %d (%@). Search domains set: %@. System proxy: %@.", servers.count, kindNames,
                               corporate ? L("yes") : L("no"), settings?.isOn == true ? L("on") : L("off")))
        return result
    }

    /// Who provides a DNS server, in a word or two, for the report.
    static func kindName(_ kind: DoctorParse.AddressKind) -> String {
        switch kind {
        case .privateNetwork, .ipv6Global: L("router")
        case .loopback: L("app on this Mac")
        case .proxyApp: L("proxy app")
        case .linkLocal: L("local device")
        case .sharedCarrier: L("provider or VPN")
        case .publicNetwork: L("public DNS")
        case .unknown: L("unknown")
        }
    }

    /// The latest Test Speed run: its numbers, or why there are none.
    struct SpeedOutcome: Sendable, Equatable {
        var speed: DoctorParse.Speed?
        var timedOut = false
        var checked = Date()

        init(_ output: DoctorOutput?) {
            speed = output.flatMap { DoctorParse.speed($0.stdout) }
            timedOut = output?.timedOut == true
        }
    }

    /// The DNS result (or an empty one) with the latest speed test added; built fresh each time, so an old test never
    /// lingers and a new DNS check never drops the speed.
    static func withSpeed(_ dns: DoctorResult?, _ outcome: SpeedOutcome) -> DoctorResult {
        var result = dns ?? DoctorResult(section: .network, severity: .ok, badge: L("Speed tested"), headline: L("Speed test finished."),
                                         checked: outcome.checked)
        result.ran.append(DoctorCommand.networkQuality.displayString)
        guard let speed = outcome.speed else {
            result.notes.insert(outcome.timedOut ? L("The speed test took too long and was stopped.")
                                                 : L("The speed test couldn’t finish. Check that you are online."), at: 0)
            return result
        }
        func mbps(_ bits: Double?) -> String { bits.map { L("%@ Mbps", String(format: "%.1f", $0 / 1_000_000)) } ?? "—" }
        let rpm = speed.responsiveness ?? 0
        let quality = rpm >= 1000 ? L("High") : rpm >= 300 ? L("Medium") : L("Low")
        result.rows.insert(contentsOf: [
            DoctorRow(id: "speed.down", title: L("Download"), value: mbps(speed.download),
                      detail: L("Video calls need about 3 Mbps, 4K video about 25."),
                      severity: (speed.download ?? 0) < 5_000_000 ? .review : .ok),
            DoctorRow(id: "speed.up", title: L("Upload"), value: mbps(speed.upload),
                      detail: L("For sending files and your video in calls."), severity: .info),
            DoctorRow(id: "speed.rpm", title: L("Responsiveness"), value: quality,
                      detail: rpm < 300 ? L("Low: calls and games may lag while the connection is busy.")
                                        : L("How quickly the connection reacts while it is busy."),
                      severity: rpm < 300 ? .review : .info),
        ], at: 0)
        if (speed.download ?? 0) < 5_000_000 || rpm < 300 {
            result.severity = max(result.severity, .review)
            // The Summary shows the headline: make it about what is actually wrong.
            if result.severity == .review {
                result.headline = L("The connection itself is slow or lags while busy. Restart the router or move closer to it; if it stays slow, contact your internet provider.")
            }
        }
        result.speedReport = [L("Speed test: download %@, upload %@, responsiveness %@ (%d round trips per minute).",
                                mbps(speed.download), mbps(speed.upload), quality, Int(rpm))]
        return result
    }
}

// MARK: - External drives

enum DoctorDrives {
    struct Volume: Sendable, Equatable {
        let mountPoint: String
        let format: String
        let readOnly: Bool
        /// False for network shares.
        let local: Bool
        let total: Int64
        let available: Int64
        /// "disk4s1"; empty for network shares.
        var device: String = ""
        /// The physical disk it lives on, filled in from diskutil; volumes that share it eject together.
        var wholeDisk: String?
    }

    struct Unmounted: Sendable, Equatable {
        let identifier: String
        let content: String
        let size: Int64
        /// A disk with no partitions at all: it needs erasing before use.
        var uninitialized = false
    }

    /// Partitions that are never mounted on purpose: firmware, reserved and recovery areas, APFS support volumes.
    static func unmountable(_ content: String, name: String?) -> Bool {
        let hidden = ["EFI", "Apple_APFS", "Apple_Boot", "Apple_APFS_Recovery", "Apple_APFS_ISC", "Microsoft Reserved",
                      "Windows Recovery", "Apple_partition_map", "Apple_Free", "Apple_KernelCoreDump"]
        if hidden.contains(where: { content.contains($0) }) { return true }
        // APFS volumes are listed by type UUID; their support roles are recognisable by name.
        return ["Preboot", "Recovery", "VM", "Update", "xART", "Hardware"].contains(name ?? "")
    }

    /// Mounted volumes under /Volumes, read with getfsstat: no file on any drive is opened, so macOS never asks for
    /// access to removable volumes. Hidden mounts (disk images opened by apps) are left out.
    static func volumes() -> [Volume] {
        let count = Int(getfsstat(nil, 0, MNT_NOWAIT)) + 8  // room for a drive mounted in between
        guard count > 8 else { return [] }
        let buffer = UnsafeMutablePointer<statfs>.allocate(capacity: count)
        defer { buffer.deallocate() }
        let filled = Int(getfsstat(buffer, Int32(count * MemoryLayout<statfs>.stride), MNT_NOWAIT))
        return UnsafeBufferPointer(start: buffer, count: max(0, min(filled, count))).compactMap { info in
            var copy = info
            let mount = withUnsafeBytes(of: &copy.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let type = withUnsafeBytes(of: &copy.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let from = withUnsafeBytes(of: &copy.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard mount.hasPrefix("/Volumes/"), info.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { return nil }
            let block = Int64(info.f_bsize)
            let local = info.f_flags & UInt32(MNT_LOCAL) != 0
            let device = from.hasPrefix("/dev/") ? String(from.dropFirst(5)) : ""
            return Volume(mountPoint: mount, format: type, readOnly: info.f_flags & UInt32(MNT_RDONLY) != 0, local: local,
                          total: Int64(info.f_blocks) * block, available: Int64(info.f_bavail) * block,
                          device: DoctorCommand.isDiskIdentifier(device) ? device : "")
        }
    }

    static func check(_ volumes: [Volume], unmounted: [Unmounted]) -> DoctorResult {
        var result = DoctorResult(section: .drives, severity: .ok, badge: "", headline: "")
        for volume in volumes {
            let name = DoctorText.visible(URL(fileURLWithPath: volume.mountPoint).lastPathComponent)
            var detail: String
            var severity = DoctorSeverity.info
            switch volume.format {
            case "ntfs":
                detail = L("NTFS (Windows). macOS can read it but not write to it. To use it on both Mac and Windows, copy the files off and erase it as exFAT in Disk Utility.")
                severity = .review
            case "exfat": detail = L("exFAT: works on Mac and Windows.")
            case "msdos": detail = L("FAT32: works almost everywhere, but files larger than 4 GB can’t be copied to it.")
            case "apfs": detail = L("APFS: the Mac’s own format.")
            case "hfs": detail = L("Mac OS Extended: an older Mac format.")
            case "smbfs", "afpfs", "nfs", "webdav": detail = L("A shared folder on the network.")
            default: detail = DoctorText.visible(volume.format)
            }
            if volume.readOnly, volume.format != "ntfs" {
                detail += " " + L("It is mounted read-only, so files can’t be added or changed.")
                severity = .review
            }
            // Network shares aren't drives: they disconnect in Finder, not with Eject.
            result.rows.append(DoctorRow(id: (volume.local ? "drive." : "share.") + volume.mountPoint, title: name,
                                         value: L("%@ free of %@", DoctorFormat.bytes(volume.available), DoctorFormat.bytes(volume.total)),
                                         detail: detail, severity: severity, location: URL(fileURLWithPath: volume.mountPoint),
                                         disk: volume.wholeDisk))
            result.severity = max(result.severity, severity)
        }
        for disk in unmounted {
            if disk.uninitialized {
                result.rows.append(DoctorRow(id: "unmounted." + disk.identifier, title: L("Drive with no partitions"), value: "",
                                             detail: L("macOS sees the drive but nothing on it it can read. If it is new, erase it in Disk Utility; if it held files, it may use a format macOS can’t read or need repair."),
                                             severity: .review))
            } else {
                let format = disk.content.contains("Microsoft") ? L("Windows (NTFS or exFAT)")
                    : disk.content.contains("Linux") ? L("Linux")
                    : disk.content == "APFS volume" || disk.content.contains("41504653") ? L("APFS (locked or damaged)")
                    : DoctorText.visible(disk.content)
                result.rows.append(DoctorRow(id: "unmounted." + disk.identifier, title: L("Drive that isn’t mounted"),
                                             value: DoctorFormat.bytes(disk.size),
                                             detail: L("Format: %@. Open Disk Utility, select it and choose Mount. If it can’t be mounted, macOS can’t read this format or the drive needs First Aid.", format),
                                             severity: .review))
            }
            result.severity = max(result.severity, .review)
        }
        if volumes.isEmpty && unmounted.isEmpty {
            result.headline = L("No external drives are connected.")
            result.badge = L("None")
        } else {
            result.headline = unmounted.isEmpty ? L("%d drives are connected.", volumes.count)
                : L("%d drives are connected; %d of them aren’t mounted.", volumes.count + unmounted.count, unmounted.count)
            result.badge = L("%d connected", volumes.count + unmounted.count)
        }
        result.notes.append(L("Select a drive and choose Eject to unplug it safely. If it won’t eject, Mac Doctor tells you which app is using it."))
        result.notes.append(L("If a drive doesn’t show up at all: try another cable or port, check Finder Settings → Sidebar → External disks, and look for it in Disk Utility."))
        result.report.append(volumes.isEmpty && unmounted.isEmpty ? L("External drives: none.")
            : L("External drives: %d mounted (formats: %@), %d read-only, %d not mounted.", volumes.count,
                Set(volumes.map(\.format)).sorted().joined(separator: ", "), volumes.filter(\.readOnly).count, unmounted.count))
        return result
    }

    /// Plain words for whoever stops a drive from ejecting.
    static func holder(_ name: String) -> String {
        switch name {
        case "mds", "mds_stores", "mdworker", "mdworker_shared": L("Spotlight is indexing the drive. Wait a minute and try again.")
        case "backupd": L("Time Machine is backing up to it. Wait until the backup finishes.")
        case "Finder": L("Finder is still using it, for example a window or a copy in progress.")
        case "QuickLookUIService", "quicklookd": L("Quick Look is showing a file from it. Close the preview.")
        case "fseventsd": L("macOS is recording changes on the drive. Try again in a moment.")
        default: L("%@ is using a file on it. Quit that app or close the file, then try again.", DoctorText.visible(name))
        }
    }
}

// MARK: - Background items

enum DoctorBackground {
    struct Item: Sendable, Equatable {
        enum Place: String, Sendable { case userAgents, agents, daemons }
        enum Program: Sendable, Equatable {
            case present, missing, cantCheck, managedByApp, none
        }
        enum Kind: Sendable, Equatable { case regular, inert, unreadable, link, danglingLink }
        let file: URL
        let place: Place
        let kind: Kind
        let label: String
        let program: String?
        let status: Program
        let runsAtLoad: Bool
        let keepsAlive: Bool
        let disabled: Bool
        /// The app it belongs to, when the plist or its program path names one.
        let app: String?
    }

    static func folders(home: URL) -> [(Item.Place, URL)] {
        [(.userAgents, home.appendingPathComponent("Library/LaunchAgents")),
         (.agents, URL(fileURLWithPath: "/Library/LaunchAgents")),
         (.daemons, URL(fileURLWithPath: "/Library/LaunchDaemons"))]
    }

    static let standardPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Reads launchd property lists. Each file is opened without following links and without blocking, must be a
    /// regular file of at most 64 KB, and only string fields are used.
    static func items(home: URL) -> [Item] {
        var result: [Item] = []
        for (place, folder) in folders(home: home) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".plist") {
                result.append(read(folder.appendingPathComponent(name), place: place, home: home))
            }
        }
        return result
    }

    static func read(_ file: URL, place: Item.Place, home: URL) -> Item {
        func item(_ kind: Item.Kind, label: String? = nil) -> Item {
            Item(file: file, place: place, kind: kind, label: label ?? file.deletingPathExtension().lastPathComponent,
                 program: nil, status: .none, runsAtLoad: false, keepsAlive: false, disabled: false, app: nil)
        }
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return item(.unreadable) }
        if info.st_mode & S_IFMT == S_IFLNK {
            // launchd follows links; a link whose target is gone is the leftover this section is for.
            var target = stat()
            return item(stat(file.path, &target) == 0 ? .link : .danglingLink)
        }
        guard let data = readSmallFile(file) else { return item(.unreadable) }
        guard let plist = parse(data) else { return item(.unreadable) }
        let label = plist["Label"] as? String
        let arguments = (plist["ProgramArguments"] as? [Any])?.compactMap { $0 as? String }
        let program = plist["Program"] as? String ?? arguments?.first
        let bundleProgram = plist["BundleProgram"] as? String
        guard label != nil || program != nil || bundleProgram != nil else { return item(.inert) }
        let status: Item.Program = bundleProgram != nil ? .managedByApp : program.map { exists($0, home: home) } ?? .none
        let keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
        return Item(file: file, place: place, kind: .regular, label: label ?? file.deletingPathExtension().lastPathComponent,
                    program: program ?? bundleProgram, status: status,
                    runsAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepsAlive: keepAlive,
                    disabled: plist["Disabled"] as? Bool ?? false,
                    app: owningApp(plist["AssociatedBundleIdentifiers"], program: program))
    }

    /// Opens with O_NOFOLLOW | O_NONBLOCK, so a link or a FIFO planted in place of the file can't redirect or stall it.
    static func readSmallFile(_ url: URL, limit: Int = 64 << 10) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        var data = Data(count: limit + 1)
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, limit + 1) }
        guard count >= 0, count <= limit else { return nil }
        return data.prefix(count)
    }

    /// Property lists nest recursively when parsed: refuse anything nested deeper than any real launchd file.
    static func parse(_ data: Data) -> [String: Any]? {
        if data.starts(with: Array("bplist".utf8)) {
            // Binary lists can't be scanned cheaply; their size is already capped at 64 KB.
        } else {
            var depth = 0, deepest = 0
            let text = String(decoding: data, as: UTF8.self)
            var index = text.startIndex
            while let open = text[index...].firstIndex(of: "<") {
                let rest = text[open...]
                if rest.hasPrefix("<dict>") || rest.hasPrefix("<array>") { depth += 1; deepest = max(deepest, depth) }
                else if rest.hasPrefix("</dict>") || rest.hasPrefix("</array>") { depth -= 1 }
                index = text.index(after: open)
            }
            guard deepest <= 32 else { return nil }
        }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Missing only when it is an absolute path outside protected places, on a mounted volume, and lstat says it is
    /// gone. A bare name is looked up the way launchd does. Anything else is "can't check", never "missing".
    static func exists(_ program: String, home: URL) -> Item.Program {
        var path = program
        if !program.hasPrefix("/") {
            guard !program.contains("/"), !program.isEmpty else { return .cantCheck }
            guard let found = standardPath.map({ $0 + "/" + program }).first(where: { FileManager.default.fileExists(atPath: $0) })
            else { return .cantCheck }
            path = found
        }
        let url = URL(fileURLWithPath: path)
        if DoctorPrivacy.isProtected(url, home: home) { return .cantCheck }
        var info = stat()
        if lstat(path, &info) == 0 { return .present }
        return errno == ENOENT ? .missing : .cantCheck
    }

    private static func owningApp(_ associated: Any?, program: String?) -> String? {
        if let ids = associated as? [String] {
            for id in ids {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    return url.deletingPathExtension().lastPathComponent
                }
            }
        }
        if let program, let range = program.range(of: ".app/") {
            return URL(fileURLWithPath: String(program[..<range.lowerBound])).lastPathComponent
        }
        return nil
    }

    static func check(_ items: [Item], loaded: [String: Int]?, systemLoaded: Set<String>, home: URL) -> DoctorResult {
        var result = DoctorResult(section: .background, severity: .ok, badge: "", headline: "")
        result.panes = [.loginItems]
        result.adminCommands = [.listBackgroundItems]
        var leftovers = 0
        for item in items {
            let place: String = switch item.place {
            case .userAgents: L("Your account")
            case .agents: L("All users")
            case .daemons: L("System (runs without login)")
            }
            var state: String
            var severity = DoctorSeverity.info
            var notes: [String] = []
            switch item.kind {
            case .inert: state = L("Empty")
            case .unreadable: state = L("Can’t read")
            case .link: state = L("Link")
                notes.append(L("This file is a link to another file; Mac Doctor doesn’t follow it."))
            case .danglingLink:
                state = L("Left over")
                severity = .review
                notes.append(L("A link to a file that no longer exists, probably left by an app you removed."))
            case .regular:
                switch item.status {
                case .missing:
                    state = L("App removed")
                    severity = .review
                    notes.append(L("Its program is gone, so this is probably left over from an app you removed."))
                case .managedByApp:
                    state = L("Managed by its app")
                    notes.append(L("Turn it off in System Settings → General → Login Items."))
                default:
                    if let pid = loaded?[item.label] { state = pid > 0 ? L("Running") : L("Loaded") }
                    else if item.place == .daemons, systemLoaded.contains(item.label) { state = L("Loaded") }
                    else if item.disabled { state = L("Turned off") }
                    else { state = item.runsAtLoad || item.keepsAlive ? L("Starts automatically") : L("Starts when needed") }
                    if item.status == .cantCheck { notes.append(L("Its program is in a protected place, so Mac Doctor didn’t check it.")) }
                }
            }
            let label = DoctorText.visible(item.label)
            if DoctorText.isUnusual(item.label) {
                notes.append(L("Its name contains hidden or look-alike characters. Be careful: this is a way to disguise software."))
                severity = .review
            } else if item.label.hasPrefix("com.apple.") {
                notes.append(L("Its name says Apple, but Apple’s own items live in /System. Check where it came from."))
                severity = .review
            }
            // People know apps, not labels: "iMazing helper", with the label in the details.
            let title = item.app.map { L("%@ helper", DoctorText.visible($0)) } ?? label
            var detail = place + (item.app != nil ? " · " + label : "")
            if item.place != .userAgents, item.kind == .danglingLink || item.status == .missing {
                // Mac Doctor can't move it: say so plainly instead of a warning the user can't act on here.
                notes.append(L("A system item: removing it needs an administrator, so Mac Doctor only shows it."))
                state = L("Needs an administrator")
            }
            if let program = item.program { detail += " · " + DoctorText.visible(DoctorFormat.path(URL(fileURLWithPath: program))) }
            if !notes.isEmpty { detail += "\n" + notes.joined(separator: " ") }
            // Only your own leftovers can be moved by Mac Doctor; the others need an administrator.
            let trash: DoctorTrashTarget? = item.place == .userAgents && item.kind == .regular && item.status == .missing
                ? (try? DoctorTrash.homeRelativePath(item.file, home: home)).map {
                    DoctorTrashTarget(path: $0, mode: .item, identity: try? FileIdentity.read(item.file))
                }
                : nil
            if severity >= .review { leftovers += 1 }
            result.rows.append(DoctorRow(id: "bg." + item.file.path, title: title, value: state, detail: detail,
                                         severity: severity, location: item.file, trash: trash))
        }
        result.rows.sort { ($0.severity > $1.severity) || ($0.severity == $1.severity && $0.title < $1.title) }
        if leftovers > 0 { result.severity = .review }
        result.badge = leftovers == 0 ? L("%d items", items.count) : L("%d to review", leftovers)
        result.headline = leftovers == 0
            ? L("%d programs are set to start by themselves. None looks left over.", items.count)
            : L("%d of %d programs that start by themselves look left over or unusual.", leftovers, items.count)
        result.notes.append(L("Apps added in System Settings → General → Login Items aren’t all listed here. Turn them off there."))
        if result.rows.contains(where: { $0.trash != nil }) {
            result.notes.append(L("A leftover in your account can be moved to the Trash. It stops after you log out and back in."))
        }
        if items.contains(where: { $0.place != .userAgents && ($0.status == .missing || $0.kind == .danglingLink) }) {
            result.notes.append(L("Leftovers for all users or the system can only be removed with an administrator password. Show them in Finder and move them to the Trash there."))
        }
        result.report.append(L("Launch agents and daemons: %d (%d in the user’s account); left over or unusual: %d.",
                               items.count, items.filter { $0.place == .userAgents }.count, leftovers))
        result.names += result.rows.filter { $0.severity >= .review }
            .compactMap { row in items.first { "bg." + $0.file.path == row.id }.map { DoctorText.reportLabel($0.label) } }
        return result
    }
}

// MARK: - Apps That Won't Open

enum DoctorApp {
    struct Findings: Sendable, Equatable {
        /// Who signed it, as Gatekeeper's verdict says (the signature's own fields aren't proof: anyone can sign
        /// with a self-made certificate and any team name).
        enum Signer: Sendable, Equatable { case apple, appStore, developerID, unidentified, unknown, adHoc, none }
        var name: String
        var iOSApp: Bool
        var bundleComplete: Bool
        /// From the signature's flags; only used when Gatekeeper gives no source.
        var adHoc: Bool
        var hasSignature: Bool
        var signature: DoctorParse.Signature?
        var assessment: DoctorParse.Assessment?
        var quarantine: DoctorParse.Quarantine?
        var intelOnly: Bool
        var rosettaInstalled: Bool
        var minimumSystem: String?
        var tooNew: Bool
        var temporaryLocation: Bool

        var signer: Signer {
            let source = assessment?.source ?? ""
            if source == "Apple System" { return .apple }
            if source == "Mac App Store" { return .appStore }
            if source.contains("Developer ID") { return .developerID }
            if adHoc { return .adHoc }
            // Without Gatekeeper's answer the signer can't be told; it isn't "unidentified" yet.
            if assessment == nil, hasSignature { return .unknown }
            return hasSignature ? .unidentified : .none
        }
    }

    /// The parts that need no subprocess: bundle layout, the downloaded flag, architecture and minimum macOS.
    /// `app` is already validated and has its links resolved. Nothing here follows a link or opens anything that
    /// isn't a regular file, and Security only looks at a bundle whose program file checked out.
    static func inspect(_ app: URL, home: URL) -> Findings {
        let contents = app.appendingPathComponent("Contents")
        var info = stat()
        let hasContents = lstat(contents.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        let wrapped = lstat(app.appendingPathComponent("Wrapper").path, &info) == 0
            || lstat(app.appendingPathComponent("WrappedBundle").path, &info) == 0
        let plist = hasContents ? DoctorBackground.readSmallFile(contents.appendingPathComponent("Info.plist"), limit: 1 << 20)
            .flatMap { DoctorBackground.parse($0) } ?? [:] : [:]
        // The executable must be a plain name inside Contents/MacOS: a crafted Info.plist can't point elsewhere.
        var executable: URL?
        if let name = plist["CFBundleExecutable"] as? String, !name.contains("/"), name != "..", name != ".",
           DoctorCommand.isPlain(name) {
            let candidate = contents.appendingPathComponent("MacOS").appendingPathComponent(name)
            var macOS = stat()
            if lstat(contents.appendingPathComponent("MacOS").path, &macOS) == 0, macOS.st_mode & S_IFMT == S_IFDIR,
               lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                executable = candidate
            }
        }
        let complete = executable != nil

        var adHoc = false, signed = false
        var code: SecStaticCode?
        if complete, !wrapped, SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code {
            // Signing details only; whether the signature is intact is codesign's job, in a process that can be stopped.
            var signing: CFDictionary?
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
            let details = signing as? [String: Any] ?? [:]
            let flags = (details[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            adHoc = flags & 0x2 != 0  // kSecCodeSignatureAdhoc
            signed = details[kSecCodeInfoIdentifier as String] != nil
        }

        let quarantine: DoctorParse.Quarantine? = {
            let size = getxattr(app.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0, size < 4096 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            guard getxattr(app.path, "com.apple.quarantine", &bytes, size, 0, XATTR_NOFOLLOW) == size else { return nil }
            return DoctorParse.quarantine(String(decoding: bytes, as: UTF8.self))
        }()

        let architectures = executable.map(machOArchitectures) ?? []
        #if arch(arm64)
        let intelOnly = !architectures.isEmpty && !architectures.contains(cpuARM64)
        #else
        let intelOnly = false
        #endif
        let minimum = plist["LSMinimumSystemVersion"] as? String
        let tooNew = minimum.map { required in
            let parts = required.split(separator: ".").compactMap { Int($0) }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = [os.majorVersion, os.minorVersion, os.patchVersion]
            return !parts.isEmpty && !parts.lexicographicallyPrecedes(current) && parts != Array(current.prefix(parts.count))
        } ?? false
        let path = app.path
        let temporary = path.hasPrefix(home.appendingPathComponent("Downloads").path + "/") || path.hasPrefix("/Volumes/")
            || path.contains("/AppTranslocation/")
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        return Findings(name: name, iOSApp: wrapped && !hasContents, bundleComplete: complete, adHoc: adHoc,
                        hasSignature: signed, signature: nil, assessment: nil, quarantine: quarantine, intelOnly: intelOnly,
                        rosettaInstalled: FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime"),
                        minimumSystem: minimum, tooNew: tooNew, temporaryLocation: temporary)
    }

    static let cpuARM64: Int32 = 0x0100000C
    static let cpuX86_64: Int32 = 0x01000007

    /// CPU types in a Mach-O file's header (thin or universal), read without following links or blocking.
    static func machOArchitectures(_ url: URL) -> [Int32] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [] }
        var header = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &header, header.count)
        guard count >= 8 else { return [] }
        func big(_ at: Int) -> UInt32 { at + 4 <= count ? header[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } : 0 }
        func little(_ at: Int) -> UInt32 { at + 4 <= count ? header[at..<at + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } : 0 }
        switch big(0) {
        case 0xCAFEBABE, 0xCAFEBABF:  // universal: big-endian table of architectures
            let entry = big(0) == 0xCAFEBABF ? 32 : 20
            let number = min(Int(big(4)), 16)
            return (0..<number).map { Int32(bitPattern: big(8 + $0 * entry)) }.filter { $0 != 0 }
        case 0xCFFAEDFE, 0xCEFAEDFE:  // thin, little-endian (MH_MAGIC_64 / MH_MAGIC on disk)
            return [Int32(bitPattern: little(4))]
        default:
            return []
        }
    }

    /// The diagnosis, most decisive cause first. Apps Apple blocked are never steered towards Open Anyway, and only an
    /// identified developer's app on its first open gets the Open Anyway steps.
    static func check(_ findings: Findings, app: URL) -> DoctorResult {
        var result = DoctorResult(section: .app, severity: .ok, badge: "", headline: "")
        let name = DoctorText.visible(findings.name)
        result.badge = name
        func row(_ id: String, _ title: String, _ value: String, _ detail: String, _ severity: DoctorSeverity) {
            result.rows.append(DoctorRow(id: "app." + id, title: title, value: value, detail: detail, severity: severity,
                                         location: id == "bundle" ? app : nil))
        }
        row("bundle", L("App"), name, DoctorFormat.path(app), findings.iOSApp || findings.bundleComplete ? .ok : .problem)

        if findings.iOSApp {
            result.severity = .info
            result.headline = L("This is an iPhone or iPad app from the App Store. macOS checks these differently; if it won’t open, delete it and install it again from the App Store.")
            result.report.append(L("App check: an iPhone or iPad app installed from the App Store."))
            return result
        }

        let signer = findings.signer
        let assessment = findings.assessment
        let damaged = findings.signature == .modified
            || (assessment?.verdict == .invalidSignature && findings.signature != .incomplete && findings.signature != .valid)
        let signatureText: (String, String, DoctorSeverity) = switch findings.signature {
        case .valid?: switch signer {
            case .apple: (L("Intact"), L("Signed by Apple."), .ok)
            case .appStore: (L("Intact"), L("Signed for the Mac App Store."), .ok)
            case .developerID: (L("Intact"), L("Signed by an identified developer."), .ok)
            case .adHoc: (L("Intact"), L("Signed, but without a developer identity (ad hoc)."), .review)
            case .unidentified, .none: (L("Intact"), L("Signed, but not by a developer Apple has identified."), .review)
            case .unknown: (L("Intact"), L("Signed. Who signed it shows once Gatekeeper’s check finishes."), .info)
            }
        case .unsigned?: (L("Not signed"), L("macOS can’t tell who made this app or whether it was changed."), .review)
        case .incomplete?: (L("Incomplete"), L("The developer didn’t finish signing this app. Downloading it again won’t help; only the developer can fix it."), .review)
        case .modified?: (L("Changed after signing"), L("Files inside the app were changed or damaged after the developer signed it."), .problem)
        case .revoked?: (L("Revoked"), L("Apple has withdrawn this developer’s certificate."), .problem)
        case .other(let message)?: (L("Not valid"), DoctorText.visible(message), .review)
        case nil: (L("Not checked"), findings.bundleComplete ? L("The signature check didn’t finish.") : L("Not checked, because the app is incomplete."), .info)
        }
        row("signature", L("Signature"), signatureText.0, signatureText.1, signatureText.2)

        let source = assessment?.source ?? ""
        let notarized = source.contains("Notarized") || source == "Mac App Store" || source == "Apple System"
        if let assessment {
            let verdict: String = switch assessment.verdict {
            case .accepted: L("Allowed")
            case .rejected: L("Blocked")
            case .invalidSignature: L("Blocked: invalid signature")
            case .revoked: L("Blocked by Apple")
            }
            // Without the downloaded flag Gatekeeper never stops the app, so a "no" is information, not a block.
            let ungated = assessment.verdict == .rejected && findings.quarantine == nil
            row("gatekeeper", L("Gatekeeper"), ungated ? L("Not approved (not needed)") : verdict,
                source.isEmpty ? L("No source given.") : DoctorText.visible(source),
                assessment.verdict == .accepted || ungated ? (ungated ? .info : .ok) : .review)
            row("notarized", L("Notarized by Apple"), notarized ? L("Yes") : L("No"),
                L("Apple scanned this app for known malware before it was published."), notarized ? .ok : .info)
        } else {
            row("gatekeeper", L("Gatekeeper"), L("Not checked"),
                findings.bundleComplete ? L("Gatekeeper didn’t answer in time.") : L("Not checked, because the app is incomplete."), .info)
        }

        let pendingFirstOpen = findings.quarantine.map { !$0.approved } ?? false
        if let quarantine = findings.quarantine {
            var detail = quarantine.agent.map { L("Downloaded with %@.", DoctorText.visible($0)) } ?? L("Downloaded from the internet.")
            detail += " " + (quarantine.approved ? L("You already chose to open it, so Gatekeeper doesn’t ask again.")
                                                 : L("macOS will check it when it is first opened."))
            row("quarantine", L("Downloaded flag"), quarantine.approved ? L("Allowed by you") : L("Set"), detail, .info)
        } else {
            row("quarantine", L("Downloaded flag"), L("Not set"), L("macOS doesn’t treat it as a download, so Gatekeeper won’t ask about it."), .info)
        }
        if findings.intelOnly {
            row("arch", L("Made for"), L("Intel Macs"),
                findings.rosettaInstalled ? L("It runs through Rosetta, which is installed.")
                                          : L("It needs Rosetta. macOS offers to install it the first time you open the app."), .info)
        }
        if findings.tooNew, let minimum = findings.minimumSystem {
            row("system", L("Needs macOS"), DoctorText.visible(minimum), L("This app needs a newer version of macOS than this Mac has."), .problem)
        }

        let revoked = findings.signature == .revoked || assessment?.verdict == .revoked
        if revoked {
            result.severity = .problem
            result.headline = L("Apple has blocked this app as harmful. Move it to the Trash and don’t open it.")
        } else if !findings.bundleComplete {
            result.severity = .problem
            result.headline = L("The app is incomplete: its program file is missing. Download it again from the developer.")
        } else if damaged {
            result.severity = .problem
            result.headline = L("Files inside the app were changed after the developer signed it, so macOS calls it damaged. Don’t force it open: delete it and download it again from the developer’s website or the App Store.")
        } else if findings.tooNew {
            result.severity = .problem
            result.headline = L("This app needs a newer version of macOS. Update macOS, or ask the developer for a version that runs on this one.")
        } else if findings.signature == .incomplete {
            result.severity = .review
            result.headline = L("The developer didn’t sign this app completely, so macOS may refuse it. Only the developer can fix this.")
        } else if assessment == nil {
            result.severity = .info
            result.headline = L("Gatekeeper’s check didn’t finish, so Mac Doctor can’t say yet whether macOS allows this app. Try again; large apps can take a few minutes.")
        } else if assessment?.verdict == .accepted {
            result.headline = pendingFirstOpen
                ? L("Gatekeeper accepts this app’s signature. The first time you open it, macOS asks once to confirm — that is normal. This is not a malware scan.")
                : L("Gatekeeper accepts this app’s signature. If it still doesn’t open, it may be crashing: try reinstalling it. This is not a malware scan.")
        } else if findings.quarantine == nil {
            // Gatekeeper only checks apps that carry the downloaded flag; this one opens without asking.
            result.severity = .info
            result.headline = L("Gatekeeper wouldn’t approve this app, but it has no downloaded flag, so macOS opens it without asking. If it still won’t open, it may be crashing: try reinstalling it.")
        } else if findings.quarantine?.approved == true {
            result.severity = .info
            result.headline = L("You already allowed this app, so the downloaded flag isn’t why it won’t open. If it quits right away, reinstall it or ask its developer.")
        } else if signer == .developerID, findings.signature != .valid {
            result.severity = .review
            result.headline = L("Gatekeeper blocks it and its signature couldn’t be fully checked. Try again, or download it again from the developer.")
        } else if signer == .developerID, findings.signature == .valid {
            result.severity = .review
            result.headline = L("Gatekeeper blocks it because Apple hasn’t notarized it. Open it only if you got it directly from a developer you trust — malware often asks you to do this.")
            result.notes.append(L("To open it anyway: 1. Try to open the app once and close the message. 2. Open Privacy & Security and scroll down. 3. Choose Open Anyway and enter your password. The button appears for about an hour after the first try."))
            result.panes = [.privacy]
        } else {
            result.severity = .review
            result.headline = L("Gatekeeper blocks it because it isn’t signed by an identified developer, so macOS can’t tell who made it. Only keep it if you trust exactly where it came from.")
        }
        if findings.temporaryLocation {
            result.notes.append(L("Move the app to the Applications folder before opening it. Apps opened from Downloads or a disk image run from a temporary copy and can lose their settings."))
        }
        result.notes.append(L("Mac Doctor never removes the downloaded flag or turns off Gatekeeper: both protect you from damaged and malicious apps."))
        let signature: String = switch findings.signature {
        case .valid?: switch signer {
            case .apple: L("valid, Apple")
            case .appStore: L("valid, Mac App Store")
            case .developerID: L("valid, identified developer")
            default: L("valid, no developer identity")
            }
        case .unsigned?: L("not signed")
        case .incomplete?: L("incomplete")
        case .modified?: L("changed after signing")
        case .revoked?: L("revoked")
        case .other?: L("not valid")
        case nil: L("not checked")
        }
        let verdict: String = switch assessment?.verdict {
        case .accepted?: L("allowed")
        case .rejected?: findings.quarantine == nil ? L("not approved, but not needed (no downloaded flag)") : L("blocked")
        case .invalidSignature?: L("blocked, invalid signature")
        case .revoked?: L("blocked by Apple as harmful")
        case nil: L("not checked")
        }
        func yes(_ value: Bool) -> String { value ? L("yes") : L("no") }
        result.report.append(L("App check (no name sent): signature %@; Gatekeeper %@; notarized %@; downloaded flag %@; Intel only %@; needs newer macOS %@; opened from Downloads or a disk image %@.",
                               signature, verdict, yes(notarized),
                               findings.quarantine.map { $0.approved ? L("set, already allowed") : L("set") } ?? L("not set"),
                               yes(findings.intelOnly), yes(findings.tooNew), yes(findings.temporaryLocation)))
        if revoked { result.report.append(L("Apple has blocked this app as harmful: never suggest opening it.")) }
        return result
    }
}
