import Foundation

/// Pure readers for the text Mac Doctor's commands print. They never throw: output they don't recognise reads as
/// "nothing found", and the caller shows that the check was inconclusive.
enum DoctorParse {
    // MARK: tmutil listlocalsnapshots /

    /// Snapshot names, e.g. "com.apple.TimeMachine.2026-10-21-101010.local". The header line is skipped.
    static func snapshots(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Snapshots for") && !$0.contains(" ") }
    }

    /// The date in a Time Machine snapshot name, if it has one.
    static func snapshotDate(_ name: String) -> Date? {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(name[range]))
    }

    // MARK: scutil --dns

    struct Resolver: Equatable, Sendable {
        var nameservers: [String] = []
        var domain: String?
        var searchDomains: [String] = []
        var interface: String?
        var reachable = false
        var isMulticast = false
    }

    /// The main section's resolvers; the "for scoped queries" section repeats them per interface.
    static func resolvers(_ text: String) -> [Resolver] {
        var result: [Resolver] = []
        var current: Resolver?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration (") { break }
            if line.hasPrefix("resolver #") {
                if let current { result.append(current) }
                current = Resolver()
                continue
            }
            guard current != nil, let (key, value) = pair(line) else { continue }
            switch key {
            case _ where key.hasPrefix("nameserver["): current?.nameservers.append(value)
            case _ where key.hasPrefix("search domain["): current?.searchDomains.append(value)
            case "domain": current?.domain = value
            case "if_index":
                if let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
                    current?.interface = String(value[value.index(after: open)..<close])
                }
            case "reach": current?.reachable = value.contains("(Reachable")
            case "options": current?.isMulticast = value.contains("mdns")
            default: break
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// The resolvers macOS asks for ordinary names: no domain of their own, not multicast DNS, with servers.
    static func defaultResolvers(_ text: String) -> [Resolver] {
        resolvers(text).filter { $0.domain == nil && !$0.isMulticast && !$0.nameservers.isEmpty }
    }

    /// "key : value" lines of scutil's dictionaries.
    private static func pair(_ line: String) -> (String, String)? {
        guard let colon = line.range(of: " : ") else { return nil }
        let key = line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
        let value = line[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    enum AddressKind: String, Sendable {
        case loopback, privateNetwork, linkLocal, sharedCarrier, proxyApp, ipv6Global, publicNetwork, unknown
    }

    /// What kind of network a DNS server address belongs to: the home router, a VPN or proxy app, or a public service.
    static func kind(ofAddress address: String) -> AddressKind {
        let host = address.split(separator: "%").first.map(String.init) ?? address
        if host.contains(":") {
            let lower = host.lowercased()
            if lower == "::1" { return .loopback }
            if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") {
                return .linkLocal
            }
            if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return .privateNetwork }
            if publicService(lower) != nil { return .publicNetwork }
            // A global IPv6 address is usually the home router's own, handed out by the provider.
            return lower.first.map { "23".contains($0) } == true ? .ipv6Global : .unknown
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return .unknown }
        switch (parts[0], parts[1]) {
        case (127, _): return .loopback
        case (10, _), (192, 168): return .privateNetwork
        case (172, 16...31): return .privateNetwork
        case (169, 254): return .linkLocal
        case (100, 64...127): return .sharedCarrier
        // Proxy apps in "fake IP" mode answer DNS from this benchmarking range.
        case (198, 18...19): return .proxyApp
        default: return .publicNetwork
        }
    }

    /// Well-known public DNS services, by address.
    static func publicService(_ address: String) -> String? {
        let known: [String: String] = [
            "1.1.1.1": "Cloudflare", "1.0.0.1": "Cloudflare", "2606:4700:4700::1111": "Cloudflare", "2606:4700:4700::1001": "Cloudflare",
            "8.8.8.8": "Google Public DNS", "8.8.4.4": "Google Public DNS", "2001:4860:4860::8888": "Google Public DNS",
            "2001:4860:4860::8844": "Google Public DNS", "9.9.9.9": "Quad9", "149.112.112.112": "Quad9", "2620:fe::fe": "Quad9",
            "2400:3200::1": "AliDNS", "2400:3200:baba::1": "AliDNS", "2402:4e00::": "DNSPod",
            "2620:fe::9": "Quad9", "2620:119:35::35": "OpenDNS", "2620:119:53::53": "OpenDNS",
            "94.140.14.14": "AdGuard DNS", "94.140.15.15": "AdGuard DNS", "2a10:50c0::ad1:ff": "AdGuard DNS",
            "2a10:50c0::ad2:ff": "AdGuard DNS", "45.90.28.0": "NextDNS", "45.90.30.0": "NextDNS",
            "208.67.222.222": "OpenDNS", "208.67.220.220": "OpenDNS",
            "223.5.5.5": "AliDNS", "223.6.6.6": "AliDNS",
            "119.29.29.29": "DNSPod", "180.76.76.76": "Baidu DNS",
            "114.114.114.114": "114DNS", "114.114.115.115": "114DNS",
        ]
        return known[address.lowercased()]
    }

    // MARK: scutil --proxy

    struct Proxy: Equatable, Sendable {
        /// "HTTP", "HTTPS", "SOCKS" with host:port.
        var servers: [(kind: String, address: String)] = []
        var autoConfig: Bool = false

        var isOn: Bool { !servers.isEmpty || autoConfig }

        static func == (a: Self, b: Self) -> Bool {
            a.autoConfig == b.autoConfig && a.servers.map { $0.kind + $0.address } == b.servers.map { $0.kind + $0.address }
        }
    }

    static func proxy(_ text: String) -> Proxy {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            if let (key, value) = pair(raw.trimmingCharacters(in: .whitespaces)) { values[key] = value }
        }
        var result = Proxy()
        for kind in ["HTTP", "HTTPS", "SOCKS"] where values[kind + "Enable"] == "1" {
            let host = values[kind + "Proxy"] ?? ""
            let port = values[kind + "Port"].map { ":" + $0 } ?? ""
            result.servers.append((kind, host + port))
        }
        result.autoConfig = values["ProxyAutoConfigEnable"] == "1" || values["ProxyAutoDiscoveryEnable"] == "1"
        return result
    }

    // MARK: launchctl list

    /// "PID\tStatus\tLabel" rows: label → PID (0 when loaded but not running).
    static func launchdJobs(_ text: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let label = String(fields[2])
            guard !label.isEmpty else { continue }
            result[label] = Int(fields[0]) ?? 0
        }
        return result
    }

    // MARK: top

    struct ProcessUse: Equatable, Sendable {
        let pid: Int
        let cpu: Double
        /// Bytes.
        let memory: Int64
        /// top's command column, at most 16 characters.
        let command: String
    }

    /// The last sample of `top -l N -stats pid,cpu,mem,command`: the first sample's CPU column is not meaningful.
    static func processes(_ text: String) -> [ProcessUse] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") && $0.contains("COMMAND") }) else { return [] }
        var result: [ProcessUse] = []
        for line in lines[(header + 1)...] {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int(fields[0]), let cpu = Double(fields[1]) else { continue }
            result.append(ProcessUse(pid: pid, cpu: cpu, memory: memory(String(fields[2])),
                                     command: fields[3].trimmingCharacters(in: .whitespaces)))
        }
        return result
    }

    /// "2798M-", "86M+", "11K", "1.2G" → bytes.
    static func memory(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let unit = trimmed.last, let value = Double(trimmed.dropLast()) else { return Int64(trimmed) ?? 0 }
        let scale: Double = switch unit {
        case "K": 1024
        case "M": 1_048_576
        case "G": 1_073_741_824
        case "T": 1_099_511_627_776
        default: 1
        }
        return Int64(value * scale)
    }

    // MARK: networkQuality -c

    struct Speed: Equatable, Sendable {
        var download: Double?      // bits per second
        var upload: Double?
        var responsiveness: Double? // round trips per minute under load
        var baseLatency: Double?   // milliseconds
    }

    static func speed(_ data: Data) -> Speed? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            (json[key] as? NSNumber)?.doubleValue ?? (json[key] as? String).flatMap(Double.init)
        }
        let speed = Speed(download: number("dl_throughput"), upload: number("ul_throughput"),
                          responsiveness: number("responsiveness"), baseLatency: number("base_rtt"))
        return speed.download == nil && speed.upload == nil && speed.responsiveness == nil ? nil : speed
    }

    // MARK: spctl --assess --raw

    struct Assessment: Equatable, Sendable {
        enum Verdict: Equatable, Sendable { case accepted, rejected, invalidSignature, revoked }
        var verdict: Verdict
        /// "Apple System", "Mac App Store", "Notarized Developer ID", "Unnotarized Developer ID", "no usable signature"…
        var source: String?
        var error: Int?
        /// spctl's own message for an invalid signature, e.g. "a sealed resource is missing or invalid".
        var message: String?
    }

    static let revokedCertificate = -2147409652   // CSSMERR_TP_CERT_REVOKED
    static let revokedNotarization = -66992       // errSecCSRevokedNotarization

    /// The tools' own messages, without the path they echo at the start of each line ("<path>: message"), so a
    /// folder or app named "Unrevoked" or "not signed at all" can't change the verdict.
    static func messages(_ text: String, app: URL?) -> [String] {
        let prefixes = [app?.path, app.map { DoctorPrivacy.canonical($0.path) }].compactMap { $0 }.map { $0 + ": " }
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = String(raw)
            // "In subcomponent: /path/…" only names a nested item.
            if line.hasPrefix("In subcomponent:") { return nil }
            if let prefix = prefixes.first(where: { line.hasPrefix($0) }) {
                line = String(line.dropFirst(prefix.count))
            } else if app != nil, line.hasPrefix("/") {
                return nil  // another path's line (a nested item): its name could say anything
            } else if app == nil, line.hasPrefix("/"), let range = line.range(of: ": ", options: .backwards) {
                line = String(line[range.upperBound...])  // no app given: drop whatever path leads the line
            }
            // Follow-on lines name files inside the app ("file modified: /x/A.app/…"): keep the words, drop the path.
            if let app, let range = line.range(of: app.path) { line = String(line[..<range.lowerBound]) }
            return line.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The property list on stdout decides; exit 0 is accepted, 3 rejected, 1 a signature spctl couldn't validate.
    /// Exit 2 and 4 are tool errors: nil.
    static func assessment(_ output: DoctorOutput, app: URL? = nil) -> Assessment? {
        let plist = (try? PropertyListSerialization.propertyList(from: output.stdout, format: nil)) as? [String: Any]
        let authority = plist?["assessment:authority"] as? [String: Any]
        let source = authority?["assessment:authority:source"] as? String
        let error = (plist?["assessment:cserror"] as? NSNumber)?.intValue
        let lines = messages(output.errorText, app: app)
        // Only Apple's own error codes count, never the word "revoked" (a folder could be called that).
        let revoked = error == revokedCertificate || error == revokedNotarization
            || lines.contains { $0.contains("CSSMERR_TP_CERT_REVOKED") || $0.contains("errSecCSRevokedNotarization") }
        if revoked { return Assessment(verdict: .revoked, source: source, error: error) }
        switch output.status {
        case 0: return Assessment(verdict: .accepted, source: source, error: error)
        case 3: return Assessment(verdict: (plist?["assessment:verdict"] as? Bool) == true ? .accepted : .rejected,
                                  source: source, error: error)
        case 1:
            let message = lines.last { !$0.isEmpty && $0 != "rejected" }
            return Assessment(verdict: .invalidSignature, source: source, error: error, message: message)
        default: return nil
        }
    }

    // MARK: codesign --verify --deep

    enum Signature: Equatable, Sendable {
        case valid
        case unsigned
        /// Signed by the linker or ad hoc without sealed resources: only the developer can fix it.
        case incomplete
        /// Changed or damaged after it was signed.
        case modified
        case revoked
        case other(String)
    }

    static func signature(_ output: DoctorOutput, app: URL? = nil) -> Signature? {
        if output.timedOut { return nil }
        if output.status == 0 { return .valid }
        let lines = messages(output.errorText, app: app)
        func any(_ needles: [String]) -> Bool { lines.contains { line in needles.contains { line.contains($0) } } }
        if any(["CSSMERR_TP_CERT_REVOKED", "errSecCSRevokedNotarization"]) { return .revoked }
        if any(["not signed at all"]) { return .unsigned }
        if any(["code has no resources but signature indicates they must be present", "resource envelope is obsolete"]) {
            return .incomplete
        }
        if any(["sealed resource is missing or invalid", "invalid signature", "have been modified", "has been modified",
                "file added", "file modified", "nested code is", "unsealed contents", "sealed resource directory is invalid",
                "invalid resource directory", "invalid Info.plist"]) {
            return .modified
        }
        return .other(lines.last ?? "")
    }

    // MARK: com.apple.quarantine

    struct Quarantine: Equatable, Sendable {
        var flags: UInt32
        var date: Date?
        /// The app that downloaded it, e.g. "Safari" or "Google Chrome".
        var agent: String?
        /// The user already chose to open it; Gatekeeper doesn't ask again.
        var approved: Bool { flags & 0x40 != 0 }
    }

    /// "0083;6720b1c2;Safari;UUID": hex flags, hex seconds since 1970, downloading app, event ID.
    static func quarantine(_ value: String) -> Quarantine? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let flags = UInt32(first, radix: 16) else { return nil }
        let date = parts.count > 1 ? UInt64(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        let agent = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        return Quarantine(flags: flags, date: date, agent: agent)
    }

    // MARK: diskutil

    struct Partition: Equatable, Sendable {
        let identifier: String
        let content: String
        let name: String?
        let mountPoint: String?
        let size: Int64
    }

    /// Whole disk identifiers and their partitions (APFS volumes included) from `diskutil list -plist external`.
    /// A disk with no partitions at all has an empty list.
    static func externalDisks(_ data: Data) -> [String: [Partition]] {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [:] }
        var result: [String: [Partition]] = [:]
        for disk in disks {
            guard let id = disk["DeviceIdentifier"] as? String, DoctorCommand.isDiskIdentifier(id) else { continue }
            var list: [Partition] = (disk["Partitions"] as? [[String: Any]] ?? []).compactMap { part in
                guard let pid = part["DeviceIdentifier"] as? String else { return nil }
                return Partition(identifier: pid, content: part["Content"] as? String ?? "",
                                 name: part["VolumeName"] as? String, mountPoint: part["MountPoint"] as? String,
                                 size: (part["Size"] as? NSNumber)?.int64Value ?? 0)
            }
            // APFS volumes carry no Content and the container's Size: name the format, count what they hold.
            list += (disk["APFSVolumes"] as? [[String: Any]] ?? []).compactMap { volume in
                guard let pid = volume["DeviceIdentifier"] as? String else { return nil }
                return Partition(identifier: pid, content: "APFS volume", name: volume["VolumeName"] as? String,
                                 mountPoint: volume["MountPoint"] as? String,
                                 size: (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0)
            }
            // A drive formatted as a whole (no partition map) has its file system on the disk itself.
            if list.isEmpty, let content = disk["Content"] as? String, !content.isEmpty,
               !content.contains("partition_scheme"), disk["APFSPhysicalStores"] == nil {
                list = [Partition(identifier: id, content: content, name: disk["VolumeName"] as? String,
                                  mountPoint: disk["MountPoint"] as? String, size: (disk["Size"] as? NSNumber)?.int64Value ?? 0)]
            }
            result[id] = list
        }
        return result
    }

    struct DiskInfo: Equatable, Sendable {
        let bus: String?
        let isInternal: Bool
        let ejectable: Bool
        var removable = false
        let wholeDisk: String?
        /// For an APFS volume or container: the partition on the physical drive that holds it.
        var physicalStore: String? = nil
        /// A disk image (an opened .dmg, a simulator runtime), not a drive.
        var isImage: Bool { bus == "Disk Image" }
        /// A drive plugged into this Mac: not an image, and not fixed inside it. A card in the built-in SD slot counts
        /// as internal but is ejectable, so it is listed. Holds for APFS containers on such a drive too.
        var isExternalDrive: Bool { !isImage && (!isInternal || ejectable || removable) }
    }

    static func diskInfo(_ data: Data) -> DiskInfo? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let whole = (plist["ParentWholeDisk"] as? String).flatMap { DoctorCommand.isDiskIdentifier($0) ? $0 : nil }
        let store = ((plist["APFSPhysicalStores"] as? [[String: Any]])?.first?["APFSPhysicalStore"] as? String)
            .flatMap { DoctorCommand.isDiskIdentifier($0) ? $0 : nil }
        return DiskInfo(bus: plist["BusProtocol"] as? String, isInternal: plist["Internal"] as? Bool ?? true,
                        ejectable: plist["Ejectable"] as? Bool ?? false, removable: plist["RemovableMedia"] as? Bool ?? false,
                        wholeDisk: whole, physicalStore: store)
    }

    /// "Volume X on disk4s1 failed to unmount: dissented by PID 123 (/usr/sbin/mds)": the process holding a drive.
    static func dissenter(_ output: DoctorOutput) -> (pid: Int, name: String)? {
        let text = output.errorText + "\n" + output.text
        guard let range = text.range(of: #"(?i)dissented by PID (\d+)(?: \(([^)\n]*)\))?"#, options: .regularExpression)
        else { return nil }
        let match = String(text[range])
        let digits = match.drop { !$0.isNumber }.prefix { $0.isNumber }
        var name = ""
        if let open = match.firstIndex(of: "("), let close = match.lastIndex(of: ")"), open < close {
            name = URL(fileURLWithPath: String(match[match.index(after: open)..<close])).lastPathComponent
        }
        return Int(digits).map { ($0, name) }
    }
}
