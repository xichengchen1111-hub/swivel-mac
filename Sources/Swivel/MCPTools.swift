import AppKit
import AVFoundation
import CryptoKit
import Darwin
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// The tools `Swivel --mcp` offers. Read-only tools answer directly. Anything that writes is planned first
/// (`plan_*`: validated, predicted, no side effects) and carried out by `apply_plan`, which records what it did in
/// the undo log (`MCPHistory`) so `undo` can put it back. Outputs follow the house rules: next to the original,
/// never overwriting, through the same converters the wheel uses.
@MainActor
final class MCPTools {
    let history: MCPHistory
    /// Where undo sends files Swivel created. Tests pass a plain removal so they leave the user's Trash alone.
    let trash: (URL) throws -> Void
    private var plans: [String: MCPPlan] = [:]
    /// The latest apply in line. Hosts may call tools in parallel; two conversions into one folder at once could
    /// both pick the same free name, so applies run one after another.
    private var lastApply: Task<Void, Never>?
    static let planLifetime: TimeInterval = 3600
    static let maxPlans = 100

    init(history: MCPHistory = MCPHistory(),
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.history = history
        self.trash = trash
    }

    /// Swivel's own agent data, and the folders that hold it, are never an input.
    private var protected: [String] { [MCPPaths.resolved(history.directory)] }

    func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let args = try MCPArguments(arguments, allowed: Self.parameters[name] ?? [])
        switch name {
        case "list_actions": return try listActions(args)
        case "inspect_files": return try await inspect(args)
        case "extract_text": return try await extractText(args)
        case "read_codes": return try await readCodes(args)
        case "plan_action": return try planAction(args)
        case "plan_compress": return try await planCompress(args)
        case "plan_rename": return try planRename(args)
        case "plan_move": return try planMove(args)
        case "apply_plan": return try await oneAtATime { try await self.apply(args) }
        case "undo": return try undo(args)
        case "history": return try listHistory(args)
        default: throw ToolError("Unknown tool \(MCPPaths.shown(name))")
        }
    }

    private func paths(_ args: MCPArguments, _ key: String = "paths") throws -> [URL] {
        try MCPPaths.list(args.value(key), name: key, protected: protected)
    }

    // MARK: Read-only tools

    private func listActions(_ args: MCPArguments) throws -> [String: Any] {
        let urls = try paths(args)
        let kind = FileKind.of(urls)
        var other = ["inspect_files", "plan_rename", "plan_move"]
        let kinds = Set(urls.map(FileKind.of))
        if kinds.contains(.image) { other = ["extract_text", "read_codes", "plan_compress"] + other }
        else if kinds.contains(.video) { other = ["plan_compress"] + other }
        return ["kind": kind.rawValue, "paths": urls.map(\.path),
                "actions": MCPCatalog.actions(for: urls).map { action in
                    ["id": action.id, "title": action.title, "menu": action.mode.rawValue, "creates": action.output.summary]
                },
                "other_tools": other]
    }

    private func inspect(_ args: MCPArguments) async throws -> [String: Any] {
        var files: [[String: Any]] = []
        for url in try paths(args) { files.append(await Self.describe(url)) }
        return ["files": files]
    }

    static func describe(_ url: URL) async -> [String: Any] {
        let kind = FileKind.of(url)
        var info: [String: Any] = ["path": url.path, "kind": kind.rawValue]
        var entry = stat()
        if lstat(url.path, &entry) == 0 {
            info["modified"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(entry.st_mtimespec.tv_sec)))
            if entry.st_mode & S_IFMT == S_IFDIR {
                info["items"] = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            } else {
                info["bytes"] = Int64(entry.st_size)
            }
        }
        do {
            switch kind {
            case .image:
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                    throw ToolError("Couldn't read \(url.lastPathComponent)")
                }
                info["width"] = props[kCGImagePropertyPixelWidth] as? Int
                info["height"] = props[kCGImagePropertyPixelHeight] as? Int
                info["has_alpha"] = props[kCGImagePropertyHasAlpha] as? Bool ?? false
                info["frames"] = CGImageSourceGetCount(source)
            case .pdf:
                guard let doc = PDFDocument(url: url) else { throw ToolError("Couldn't open \(url.lastPathComponent)") }
                info["locked"] = doc.isLocked
                if !doc.isLocked { info["pages"] = doc.pageCount }
            case .document:
                let text = try Docs.read(url).string
                info["words"] = text.split { $0.isWhitespace || $0.isNewline }.count
                info["characters"] = text.count
            case .video, .audio:
                let asset = try await Video.safeAsset(url)
                let seconds = try await asset.load(.duration).seconds
                if seconds.isFinite { info["duration_seconds"] = (seconds * 100).rounded() / 100 }
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
                    info["width"] = Int(abs(size.width)); info["height"] = Int(abs(size.height))
                }
            case .archive, .folder, .other:
                break
            }
        } catch {
            info["error"] = error.localizedDescription
        }
        return info
    }

    private func extractText(_ args: MCPArguments) async throws -> [String: Any] {
        let urls = try paths(args)
        try Self.require(urls, are: .image, for: "extract_text")
        var files: [[String: Any]] = []
        for url in urls {
            do { files.append(["path": url.path, "text": try await TextRecognition.recognize(url)]) }
            catch { files.append(["path": url.path, "error": error.localizedDescription]) }
        }
        return ["files": files]
    }

    private func readCodes(_ args: MCPArguments) async throws -> [String: Any] {
        let urls = try paths(args)
        try Self.require(urls, are: .image, for: "read_codes")
        let codes = try await CodeRecognition.recognize(urls)
        return ["codes": codes.map { ["path": $0.source.path, "type": $0.kind, "value": $0.value] }]
    }

    private static func require(_ urls: [URL], are kind: FileKind, for tool: String) throws {
        if let other = urls.first(where: { FileKind.of($0) != kind }) {
            throw ToolError("\(tool) takes images; \(other.lastPathComponent) is \(FileKind.of(other).rawValue)")
        }
    }

    // MARK: Plans

    private func store(_ plan: MCPPlan) {
        let now = Date()
        plans = plans.filter { now.timeIntervalSince($0.value.made) < Self.planLifetime }
        while plans.count >= Self.maxPlans, let oldest = plans.min(by: { $0.value.made < $1.value.made }) {
            plans[oldest.key] = nil
        }
        plans[plan.id] = plan
    }

    private func planned(_ plan: MCPPlan, _ details: [String: Any]) -> [String: Any] {
        store(plan)
        var result = details
        result["plan_id"] = plan.id
        result["action"] = plan.action
        result["inputs"] = plan.inputs.map(\.path)
        result["expires_in_seconds"] = Int(Self.planLifetime)
        result["next"] = "Nothing has changed yet. Call apply_plan with this plan_id to carry it out."
        return result
    }

    private func planAction(_ args: MCPArguments) throws -> [String: Any] {
        let urls = try paths(args)
        let id = try args.string("action", required: true)!
        let actions = MCPCatalog.actions(for: urls)
        // An item that moved from Convert to Tools (ZIP for folders) keeps its old id.
        let moved = id.hasPrefix("convert.") ? "tools." + id.dropFirst("convert.".count) : id
        guard let action = actions.first(where: { $0.id == id }) ?? actions.first(where: { $0.id == moved }) else {
            throw ToolError("“\(MCPPaths.shown(id))” isn't available for these files. Available: \(actions.map(\.id).joined(separator: ", ")). Call list_actions for details.")
        }
        let prediction = try MCPCatalog.predict(action.output, urls)
        let plan = MCPPlan(action: action.id, inputs: try urls.map { try MCPFingerprint.read($0) }, work: .action(action), predicted: prediction.files)
        var details: [String: Any] = ["title": action.title, "will_create": prediction.files.map(\.path)]
        let notes = [prediction.note].compactMap { $0 } + ConversionNotice.messages(title: action.title, urls: urls)
        if !notes.isEmpty { details["note"] = notes.joined(separator: " ") }
        return planned(plan, details)
    }

    private func planCompress(_ args: MCPArguments) async throws -> [String: Any] {
        let urls = try paths(args)
        let target = try args.int("target_bytes", required: true, in: 1_000...1_000_000_000_000)!
        let format = try args.string("format")?.lowercased()
        let formats: [String: (UTType, String)] = ["jpg": (.jpeg, "jpg"), "heic": (.heic, "heic"), "png": (.png, "png")]
        if let format, formats[format] == nil, format != "same" { throw ToolError("format must be same, jpg, heic or png") }
        var jobs: [MCPPlan.Compression] = [], notes = ["Compression may reduce quality, resolution and metadata. Original files are kept unchanged."], reserved = Set<String>()
        for url in urls {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0, size <= target { notes.append("\(url.lastPathComponent) is already \(byteString(size)), under the target.") }
            switch FileKind.of(url) {
            case .image:
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                    throw ToolError("Couldn't read \(url.lastPathComponent)")
                }
                try Images.requireSingleImage(source)
                try Images.validatePrecision(source)
                let ext = url.pathExtension.lowercased()
                let lossy: Set<String> = ["jpg", "jpeg", "heic", "heif", "webp", "avif"]
                let same = Images.writableType(for: url)
                let (type, outExt): (UTType, String)
                if let format, let chosen = formats[format] { (type, outExt) = chosen }
                else if format == "same" || lossy.contains(ext), same.1 == url.pathExtension { (type, outExt) = same }
                else if props[kCGImagePropertyHasAlpha] as? Bool == true { (type, outExt) = (.heic, "heic") }
                else { (type, outExt) = (.jpeg, "jpg") }
                let out = MCPCatalog.unique(url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " compressed").appendingPathExtension(outExt), &reserved)
                jobs.append(.init(source: url, output: out, image: (type, outExt)))
            case .video:
                let asset = try await Video.safeAsset(url)
                let duration = try await asset.load(.duration).seconds
                let audio = try await asset.loadTracks(withMediaType: .audio).first
                _ = try Video.targetBitrates(maxBytes: target, duration: duration, hasAudio: audio != nil)
                let out = MCPCatalog.unique(url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " compressed").appendingPathExtension("mp4"), &reserved)
                jobs.append(.init(source: url, output: out, image: nil))
            default:
                throw ToolError("plan_compress takes images and videos; \(url.lastPathComponent) is \(FileKind.of(url).rawValue). For PDFs use plan_action with tools.Compress.")
            }
        }
        let plan = MCPPlan(action: "compress", inputs: try urls.map { try MCPFingerprint.read($0) }, work: .compress(jobs, target: target), predicted: jobs.map(\.output))
        var details: [String: Any] = ["target_bytes": target, "will_create": jobs.map(\.output.path)]
        if !notes.isEmpty { details["note"] = notes.joined(separator: " ") }
        return planned(plan, details)
    }

    private func planRename(_ args: MCPArguments) throws -> [String: Any] {
        let urls = try paths(args)
        var rules = RenameRules()
        rules.base = try args.string("base_name") ?? ""
        rules.find = try args.string("find") ?? ""
        rules.replacement = try args.string("replace_with") ?? ""
        rules.prefix = try args.string("prefix") ?? ""
        rules.suffix = try args.string("suffix") ?? ""
        rules.number = try args.bool("number") ?? false
        rules.start = try args.int("start", in: 0...99_999_999) ?? 1
        rules.digits = try args.int("digits", in: 1...8) ?? 3
        guard rules != RenameRules() || args.has("start") || args.has("digits") else {
            throw ToolError("Give at least one of base_name, find, prefix, suffix or number")
        }
        // RenamePlan.preview, minus its standardizing (which turns /private/var into /var): the paths stay resolved.
        let preview = RenamePlan.validate(urls.enumerated().map { index, url in
            let name = rules.name(for: url, index: index)
            let issue = !RenamePlan.validName(name) ? L("Invalid name or numbering")
                : name.unicodeScalars.contains(where: Self.isInvisible) ? "Contains invisible or text-direction characters" : nil
            return RenameEntry(source: url, destination: url.deletingLastPathComponent().appendingPathComponent(name),
                               identity: try? FileIdentity.read(url), issue: issue)
        })
        let rows: [[String: Any]] = preview.entries.map { entry in
            var row: [String: Any] = ["from": entry.source.path, "to": entry.destination.path]
            if let issue = entry.issue { row["issue"] = issue }
            if !entry.changes { row["unchanged"] = true }
            return row
        }
        guard preview.canApply else {
            return ["can_apply": false, "renames": rows,
                    "next": preview.entries.contains { $0.issue != nil } ? "Some names conflict or are invalid; change the rules and plan again." : "These rules don't change any name."]
        }
        let plan = MCPPlan(action: "rename", inputs: try urls.map { try MCPFingerprint.read($0) }, work: .rename(preview),
                           predicted: preview.entries.filter(\.changes).map(\.destination))
        return planned(plan, ["can_apply": true, "renames": rows])
    }

    /// Characters that change how a name reads without showing: direction overrides and isolates (U+202A–U+202E,
    /// U+2066–U+2069, so "photo<U+202E>gnp.app" can't pose as a PNG), zero-width spaces and other format or control
    /// characters. Joiners stay, since emoji sequences need them.
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar != "\u{200C}", scalar != "\u{200D}" else { return false }
        switch scalar.properties.generalCategory {
        case .format, .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    private func planMove(_ args: MCPArguments) throws -> [String: Any] {
        let urls = try paths(args)
        guard let raw = try args.string("destination", required: true) else { throw ToolError("destination is required") }
        // Moving things into a folder above the undo log leaves the log where it is; only the log's own folder is out.
        let folder = try MCPPaths.entry(raw, folder: true, protected: protected, ancestors: false)
        var device = stat()
        guard lstat(folder.path, &device) == 0 else { throw ToolError("“\(MCPPaths.shown(raw))” doesn't exist") }
        var reserved = Set<String>(), moves: [(from: URL, to: URL)] = [], rows: [[String: Any]] = [], issues = false
        for url in urls {
            let to = MCPCatalog.unique(folder.appendingPathComponent(url.lastPathComponent), &reserved)
            var row: [String: Any] = ["from": url.path, "to": to.path]
            var entry = stat()
            if url.deletingLastPathComponent().path == folder.path {
                row["issue"] = "Already in this folder"
            } else if folder.path == url.path || folder.path.hasPrefix(url.path + "/") {
                row["issue"] = "Can't move a folder into itself"
            } else if lstat(url.path, &entry) != 0 || entry.st_dev != device.st_dev {
                row["issue"] = "On another disk: Swivel moves items within one disk only"
            }
            if row["issue"] != nil { issues = true }
            rows.append(row)
            moves.append((url, to))
        }
        guard !issues else { return ["can_apply": false, "moves": rows, "next": "Resolve the issues and plan again."] }
        let plan = MCPPlan(action: "move", inputs: try urls.map { try MCPFingerprint.read($0) }, work: .move(moves, into: try MCPFingerprint.read(folder)),
                           predicted: moves.map(\.to))
        return planned(plan, ["can_apply": true, "destination": folder.path, "moves": rows])
    }

    // MARK: Apply and undo

    private func oneAtATime(_ work: @escaping @MainActor () async throws -> [String: Any]) async throws -> [String: Any] {
        let previous = lastApply
        let task = Task { @MainActor () -> Result<[String: Any], Error> in
            await previous?.value
            // Cancelled while waiting its turn: the plan stays unused.
            if Task.isCancelled { return .failure(CancellationError()) }
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        lastApply = Task { _ = await task.value }
        return try await withTaskCancellationHandler { try await task.value.get() } onCancel: { task.cancel() }
    }

    private func apply(_ args: MCPArguments) async throws -> [String: Any] {
        let id = try args.string("plan_id", required: true)!
        guard let plan = plans.removeValue(forKey: id) else {
            throw ToolError("No plan “\(MCPPaths.shown(id))”. A plan runs once and lasts an hour; make a new one with a plan_* tool.")
        }
        guard Date().timeIntervalSince(plan.made) < Self.planLifetime else { throw ToolError("This plan expired. Make a new one.") }
        // The plan described these files as they were; anything since (an edit, a replacement) needs a fresh plan.
        for input in plan.inputs {
            let unchanged = plan.movesFiles ? input.isSameEntry() : input.isCurrent()
            guard unchanged else { throw ToolError("\(input.path) changed since it was planned. Make a new plan.") }
        }
        if case .move(_, let folder) = plan.work {
            // The same folder entry, still a folder (not a link put in its place) and still not the undo log's.
            let now = try? MCPPaths.entry(folder.path, folder: true, protected: protected, ancestors: false)
            guard now?.path == folder.path, folder.isSameEntry() else {
                throw ToolError("The destination \(folder.path) changed since it was planned. Make a new plan.")
            }
        }
        var created: [URL] = [], moves: [MCPHistory.Move] = [], failures: [[String: String]] = []
        var stopped: Error?
        let urls = plan.inputs.map { URL(fileURLWithPath: $0.path, isDirectory: $0.folder) }
        switch plan.work {
        case .action(let action):
            if action.output.perFile {
                for url in urls {
                    if Task.isCancelled { stopped = CancellationError(); break }
                    do { created += try await action.run([url]) }
                    catch {
                        if let partial = error as? PartialOutputError { created += partial.files }
                        failures.append(["path": url.path, "error": error.localizedDescription])
                    }
                }
            } else {
                do { created = try await action.run(urls) } catch {
                    if let partial = error as? PartialOutputError { created += partial.files }
                    stopped = error
                }
            }
        case .compress(let jobs, let target):
            for job in jobs {
                if Task.isCancelled { stopped = CancellationError(); break }
                do { created.append(try await Self.compress(job, target: target)) }
                catch { failures.append(["path": job.source.path, "error": error.localizedDescription]) }
            }
        case .rename(let renamePlan):
            let receipt = try BatchRenamer.execute(renamePlan)
            moves = receipt.entries.map { MCPHistory.Move(from: $0.source.path, to: $0.destination.path, device: $0.identity!.device, inode: $0.identity!.inode) }
        case .move(let planned, _):
            moves = try Self.move(planned)
        }
        var result: [String: Any] = ["action": plan.action]
        if !created.isEmpty || !moves.isEmpty {
            let entry = MCPHistory.Entry(id: UUID().uuidString, date: Date(), action: plan.action, inputs: plan.inputs.map(\.path),
                                         created: created.compactMap { try? MCPFingerprint.read($0, withContents: true) }, moves: moves,
                                         isRename: plan.movesFiles && plan.action == "rename", undone: nil)
            do { try history.update { $0.append(entry) }; result["entry_id"] = entry.id }
            catch { result["warning"] = "Done, but it couldn't be recorded in the undo log: \(error.localizedDescription)" }
        }
        if let stopped {
            // Whatever finished is in the log, so it can still be undone.
            if created.isEmpty { throw stopped }
            failures.append(["path": "", "error": stopped is CancellationError ? "Cancelled" : stopped.localizedDescription])
        }
        if created.isEmpty && moves.isEmpty && !failures.isEmpty {
            throw ToolError(failures.map { "\(URL(fileURLWithPath: $0["path"] ?? "").lastPathComponent): \($0["error"] ?? "")" }.joined(separator: "\n"))
        }
        if !created.isEmpty {
            result["created"] = created.map(\.path)
            result["matches_plan"] = created.map(\.path) == plan.predicted.map(\.path)
        }
        if !moves.isEmpty { result[plan.action == "rename" ? "renamed" : "moved"] = moves.map { ["from": $0.from, "to": $0.to] } }
        if !failures.isEmpty { result["failed"] = failures }
        return result
    }

    private static func compress(_ job: MCPPlan.Compression, target: Int) async throws -> URL {
        guard let (type, ext) = job.image else { return try await Video.compressToTarget(job.source, maxBytes: target) }
        let source = job.source
        return try await Images.detached {
            let data = try Images.fitting(try Images.load(source), type: type, maxBytes: target).data
            return try Paths.create(data, at: Paths.preferred(for: source, ext: ext, suffix: " compressed"))
        }
    }

    /// Exclusive renames within one disk (`Paths.publish`: a name taken since the plan gets the next number, nothing is
    /// replaced, exFAT included). A failure puts back the ones already moved.
    private static func move(_ planned: [(from: URL, to: URL)]) throws -> [MCPHistory.Move] {
        var done: [(MCPHistory.Move, URL, URL)] = []
        do {
            for item in planned {
                let identity = try FileIdentity.read(item.from)
                let destination = try Paths.publish(item.from, as: item.to.deletingLastPathComponent().appendingPathComponent(item.from.lastPathComponent))
                done.append((MCPHistory.Move(from: item.from.path, to: destination.path, device: identity.device, inode: identity.inode), item.from, destination))
            }
        } catch {
            for (_, from, to) in done.reversed() { try? Paths.renameExclusively(to, to: from) }
            throw error
        }
        return done.map(\.0)
    }

    private func undo(_ args: MCPArguments) throws -> [String: Any] {
        let requested = try args.string("entry_id")
        let dryRun = try args.bool("dry_run") ?? false
        return try history.update { entries in
            let index = requested.map { id in entries.firstIndex { $0.id == id } } ?? entries.lastIndex { $0.undone == nil }
            guard let index else {
                throw ToolError(requested == nil ? "Nothing to undo." : "No undo log entry “\(MCPPaths.shown(requested!))”. Call history to see them.")
            }
            let entry = entries[index]
            guard entry.undone == nil else { throw ToolError("That change was already undone.") }
            var restored: [[String: String]] = [], trashed: [String] = [], skipped: [[String: String]] = []
            // What is left to undo; the entry keeps only these, so a later undo retries just them.
            var movesLeft: [MCPHistory.Move] = [], createdLeft: [MCPFingerprint] = []
            if entry.isRename {
                let made = entry.moves.map { RenameEntry(source: URL(fileURLWithPath: $0.from), destination: URL(fileURLWithPath: $0.to),
                                                          identity: FileIdentity(device: $0.device, inode: $0.inode), issue: nil) }
                let back = RenamePlan.validate(made.map { RenameEntry(source: $0.destination, destination: $0.source, identity: $0.identity, issue: nil) })
                let current = made.allSatisfy { (try? FileIdentity.read($0.destination)) == $0.identity }
                if !current {
                    for move in entry.moves { skipped.append(["path": move.to, "reason": "Renamed or moved again since; left as it is"]) }
                } else if let issue = back.entries.compactMap(\.issue).first {
                    for move in entry.moves { skipped.append(["path": move.to, "reason": issue]) }
                } else {
                    do {
                        if !dryRun { _ = try RenameReceipt(entries: made).undo() }
                        restored = entry.moves.map { ["from": $0.to, "to": $0.from] }
                    } catch {
                        for move in entry.moves { skipped.append(["path": move.to, "reason": error.localizedDescription]) }
                    }
                }
                if restored.isEmpty { movesLeft = entry.moves }
            } else {
                for move in entry.moves.reversed() {
                    let now = URL(fileURLWithPath: move.to), original = URL(fileURLWithPath: move.from)
                    guard (try? FileIdentity.read(now)) == FileIdentity(device: move.device, inode: move.inode) else {
                        skipped.append(["path": move.to, "reason": "Moved or replaced since; left as it is"]); movesLeft.insert(move, at: 0); continue
                    }
                    guard !Paths.taken(original) else {
                        skipped.append(["path": move.to, "reason": "Something else now uses \(move.from)"]); movesLeft.insert(move, at: 0); continue
                    }
                    do {
                        if !dryRun { try Paths.renameExclusively(now, to: original) }
                        restored.append(["from": move.to, "to": move.from])
                    } catch { skipped.append(["path": move.to, "reason": error.localizedDescription]); movesLeft.insert(move, at: 0) }
                }
            }
            for file in entry.created.reversed() {
                // A folder logged before its contents were recorded can't be checked; it stays.
                guard file.isCurrent(), !file.folder || file.tree != nil else {
                    skipped.append(["path": file.path, "reason": "Changed or gone since Swivel created it; left as it is"])
                    createdLeft.insert(file, at: 0); continue
                }
                do {
                    if !dryRun { try trash(URL(fileURLWithPath: file.path)) }
                    trashed.append(file.path)
                } catch { skipped.append(["path": file.path, "reason": error.localizedDescription]); createdLeft.insert(file, at: 0) }
            }
            // Done only when nothing was skipped; otherwise the entry stays open with what's left.
            if !dryRun {
                entries[index].moves = movesLeft
                entries[index].created = createdLeft
                if skipped.isEmpty { entries[index].undone = Date() }
            }
            var result: [String: Any] = ["entry_id": entry.id, "action": entry.action, "dry_run": dryRun,
                                         "restored": restored, "moved_to_trash": trashed, "complete": skipped.isEmpty]
            if !skipped.isEmpty {
                result["skipped"] = skipped
                result["next"] = "The skipped items are still in the undo log under this entry_id. Sort them out and call undo again to retry just those."
            }
            return result
        }
    }

    private func listHistory(_ args: MCPArguments) throws -> [String: Any] {
        let limit = try args.int("limit", in: 1...MCPHistory.limit) ?? 20
        let formatter = ISO8601DateFormatter()
        let entries = try history.entries().suffix(limit).reversed().map { entry -> [String: Any] in
            var row: [String: Any] = ["entry_id": entry.id, "date": formatter.string(from: entry.date), "action": entry.action,
                                      "inputs": entry.inputs, "created": entry.created.map(\.path),
                                      "moves": entry.moves.map { ["from": $0.from, "to": $0.to] }]
            if let undone = entry.undone { row["undone"] = formatter.string(from: undone) }
            return row
        }
        return ["entries": Array(entries)]
    }

    // MARK: Definitions

    static var names: Set<String> { Set(definitions.compactMap { $0["name"] as? String }) }

    private static let parameters: [String: Set<String>] = [
        "list_actions": ["paths"], "inspect_files": ["paths"], "extract_text": ["paths"], "read_codes": ["paths"],
        "plan_action": ["action", "paths"], "plan_compress": ["paths", "target_bytes", "format"],
        "plan_rename": ["paths", "base_name", "find", "replace_with", "prefix", "suffix", "number", "start", "digits"],
        "plan_move": ["paths", "destination"], "apply_plan": ["plan_id"], "undo": ["entry_id", "dry_run"], "history": ["limit"],
    ]

    static var definitions: [[String: Any]] {
        let paths: [String: Any] = ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": MCPPaths.maxCount,
                                    "description": "Absolute paths of existing files or folders, e.g. /Users/me/Desktop/photo.png. No ~, relative paths or symbolic links."]
        let readOnly: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]
        let writes: [String: Any] = ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false]
        func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any], required: [String],
                  annotations: [String: Any]) -> [String: Any] {
            ["name": name, "title": title, "description": description, "annotations": annotations.merging(["title": title]) { a, _ in a },
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
        return [
            tool("list_actions", "List Swivel actions",
                 "List what Swivel can do with these files: conversions (convert.*) and tools (tools.*) as action ids for plan_action, plus which other Swivel tools apply. Read-only.",
                 ["paths": paths], required: ["paths"], annotations: readOnly),
            tool("inspect_files", "Inspect files",
                 "Describe files without changing them: kind, size, modification date, image dimensions and transparency, PDF page count, document word count, media duration, folder item count.",
                 ["paths": paths], required: ["paths"], annotations: readOnly),
            tool("extract_text", "Extract text from images",
                 "Recognize text in images with on-device OCR (English, Chinese, Japanese). Returns the text per image. Read-only; nothing leaves this Mac.",
                 ["paths": paths], required: ["paths"], annotations: readOnly),
            tool("read_codes", "Read QR codes and barcodes",
                 "Find QR codes and barcodes in images on this Mac and return each one's type and content. Read-only.",
                 ["paths": paths], required: ["paths"], annotations: readOnly),
            tool("plan_action", "Plan a Swivel action",
                 "Plan one Swivel action on files, by an id from list_actions such as convert.JPG, convert.PDF, tools.Remove BG, tools.Resize 50%, tools.Merge or convert.ZIP. Nothing changes yet: returns a plan_id and the new files it would create next to the originals (existing names get a number; nothing is overwritten). Carry it out with apply_plan.",
                 ["action": ["type": "string", "description": "Action id from list_actions, e.g. convert.JPG"], "paths": paths],
                 required: ["action", "paths"], annotations: readOnly),
            tool("plan_compress", "Plan compressing to a size",
                 "Plan compressing images or videos to fit a file size, e.g. target_bytes 500000 for under 500 KB. Images keep a lossy format (JPG, HEIC, WebP, AVIF), others become JPG (HEIC when transparent), and they shrink only as far as needed; videos become H.264 MP4. Nothing changes yet: returns a plan_id for apply_plan.",
                 ["paths": paths,
                  "target_bytes": ["type": "integer", "minimum": 1000, "description": "Largest size each output may have, in bytes"],
                  "format": ["type": "string", "enum": ["same", "jpg", "heic", "png"], "description": "Image output format (optional; videos are always MP4)"]],
                 required: ["paths", "target_bytes"], annotations: readOnly),
            tool("plan_rename", "Plan renaming files",
                 "Plan renaming files or folders where they are: replace the whole name (base_name), find/replace_with, add prefix or suffix, and optionally number them (-001, -002… in the order of paths). Extensions are kept. Returns each old and new path, and a plan_id when nothing conflicts. Nothing changes until apply_plan.",
                 ["paths": paths,
                  "base_name": ["type": "string", "description": "New name without extension; usually combined with number"],
                  "find": ["type": "string"], "replace_with": ["type": "string"],
                  "prefix": ["type": "string"], "suffix": ["type": "string", "description": "Added before the extension"],
                  "number": ["type": "boolean", "description": "Append -NNN in the order of paths"],
                  "start": ["type": "integer", "minimum": 0, "description": "First number (default 1)"],
                  "digits": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Digits in each number (default 3)"]],
                 required: ["paths"], annotations: readOnly),
            tool("plan_move", "Plan moving files",
                 "Plan moving files or folders into an existing folder on the same disk. Taken names get a number. Returns each old and new path and a plan_id; nothing changes until apply_plan.",
                 ["paths": paths, "destination": ["type": "string", "description": "Absolute path of an existing folder"]],
                 required: ["paths", "destination"], annotations: readOnly),
            tool("apply_plan", "Apply a plan",
                 "Carry out a plan returned by a plan_* tool. A plan runs once, within an hour, and is refused if any input changed since it was planned. Creates new files without overwriting anything, or renames or moves items. Records the change in the undo log and returns what changed with an entry_id.",
                 ["plan_id": ["type": "string"]], required: ["plan_id"], annotations: writes),
            tool("undo", "Undo an applied plan",
                 "Undo an applied plan, the latest one by default: files it created go to the Trash, items it renamed or moved go back. Anything changed since (a created folder counts as changed when anything inside it changed) is left alone and reported as skipped; the entry is marked undone (complete true) only when nothing was skipped. Otherwise it stays in the log holding just the skipped items, so calling undo again retries only those. With dry_run true, only reports what would happen.",
                 ["entry_id": ["type": "string", "description": "From apply_plan or history; default: the latest change not yet undone"],
                  "dry_run": ["type": "boolean"]],
                 required: [], annotations: writes),
            tool("history", "List applied plans",
                 "List recently applied plans from Swivel's undo log, newest first: what each created, renamed or moved, and whether it was undone. Read-only.",
                 ["limit": ["type": "integer", "minimum": 1, "maximum": MCPHistory.limit, "description": "Default 20"]],
                 required: [], annotations: readOnly),
        ]
    }
}

/// A validated, not yet applied change.
struct MCPPlan {
    struct Compression {
        let source: URL
        let output: URL
        /// The image format to write, or nil for a video.
        let image: (UTType, String)?
    }
    enum Work {
        case action(MCPCatalog.Action)
        case compress([Compression], target: Int)
        case rename(RenamePlan)
        /// The destination folder as it was planned, checked again before anything moves.
        case move([(from: URL, to: URL)], into: MCPFingerprint)
    }
    let id = UUID().uuidString
    let made = Date()
    let action: String
    let inputs: [MCPFingerprint]
    let work: Work
    let predicted: [URL]

    var movesFiles: Bool {
        switch work { case .rename, .move: true; default: false }
    }
}

// MARK: - Catalog bridge

/// Which catalog items run without a window, and what each one writes (for plans). The names follow the converters
/// in Images/Media/Documents; `apply_plan` reports whether the result matched the plan.
@MainActor
enum MCPCatalog {
    enum Output {
        /// One file per input: "name<suffix>.<ext>".
        case each(suffix: String, ext: (URL) -> String)
        /// One file for all inputs, at this place before numbering.
        case one(([URL]) -> URL)
        /// Every PDF page as an image: "name.ext", or "name 1.ext", "name 2.ext"… for more pages.
        case pages(ext: String)
        case imagePages(ext: String)
        /// Every PDF page as its own PDF: "name 1.pdf"…
        case split
        /// An archive's contents.
        case extracted

        var perFile: Bool {
            switch self { case .each, .pages, .imagePages, .split: true; case .one, .extracted: false }
        }
        var summary: String {
            switch self {
            case .each: "one new file per input, next to it"
            case .one: "one new file for all inputs, next to the first"
            case .pages, .split: "one new file per PDF page, next to the PDF"
            case .imagePages: "one new file per image or TIFF page, next to the input"
            case .extracted: "the archive's contents, next to it"
            }
        }
    }

    struct Action {
        let id: String
        let mode: WheelMode
        let title: String
        let output: Output
        let run: @MainActor ([URL]) async throws -> [URL]
    }

    /// The menu items an agent may run on these files, with QuickCommand-style ids ("convert.JPG").
    static func actions(for urls: [URL]) -> [Action] {
        let kind = FileKind.of(urls)
        var result: [Action] = [], titles = Set<String>()
        for mode in [WheelMode.convert, .tools] {
            for item in Catalog.defaultItems(for: urls, mode: mode) {
                // The same item in both menus (GIF for video) is listed once, under convert.
                guard let output = output(kind: kind, mode: mode, title: item.title), titles.insert(item.title).inserted else { continue }
                let run: @MainActor ([URL]) async throws -> [URL]
                if item.title.hasPrefix("preset."), let preset = Prefs.imagePresets.first(where: { $0.actionID == item.title }) {
                    // Directly, so a failure is reported to the agent rather than in an alert.
                    run = { urls in
                        var out: [URL] = []
                        do { for url in urls { out.append(try await Images.detached { try preset.apply(to: url) }) } }
                        catch { throw PartialOutputError.wrapping(error, files: out) }
                        return out
                    }
                } else {
                    run = { try await item.run($0).files }
                }
                let title = item.title.hasPrefix("preset.") ? Catalog.displayTitle(item.title) : item.title
                result.append(Action(id: "\(mode.id).\(item.title)", mode: mode, title: title, output: output, run: run))
            }
        }
        return result
    }

    static func output(kind: FileKind, mode: WheelMode, title: String) -> Output? {
        func each(_ suffix: String, _ ext: String) -> Output { .each(suffix: suffix, ext: { _ in ext }) }
        let writable: (URL) -> String = { Images.writableType(for: $0).1 }
        let firstPDF = Output.one { $0[0].deletingLastPathComponent().appendingPathComponent($0[0].deletingPathExtension().lastPathComponent).appendingPathExtension("pdf") }
        func merged(_ name: String) -> Output { .one { $0[0].deletingLastPathComponent().appendingPathComponent(name) } }
        func archive(_ ext: String) -> Output {
            .one { urls in
                let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archive"
                return urls[0].deletingLastPathComponent().appendingPathComponent("\(name).\(ext)")
            }
        }
        func table(_ entries: [String: (String, String)]) -> Output? { entries[title].map { each($0.0, $0.1) } }
        switch (mode, kind) {
        case (.convert, .image):
            if title == "PDF" { return firstPDF }
            return Images.outputFormats.first { $0.name == title }.map { .imagePages(ext: $0.ext) }
        case (.tools, .image):
            switch title {
            case "Remove BG": return each(" cutout", "png")
            case "Resize 50%": return .each(suffix: " small", ext: writable)
            case "Rotate": return .each(suffix: " rotated", ext: writable)
            case "Flip": return .each(suffix: " flipped", ext: writable)
            case "Grayscale": return .each(suffix: " gray", ext: writable)
            case "Make PDF": return firstPDF
            default:
                guard title.hasPrefix("preset."), let preset = Prefs.imagePresets.first(where: { $0.actionID == title }) else { return nil }
                return each(" processed", preset.format.fileExtension)
            }
        case (.convert, .video):
            return table(["MP4": ("", "mp4"), "MOV": ("", "mov"), "HEVC": (" hevc", "mp4"), "M4V": ("", "m4v"), "GIF": ("", "gif"),
                          "M4A": ("", "m4a"), "WAV": ("", "wav"), "PNG Frame": (" frame", "png")])
        case (.tools, .video):
            // Compress asks for a size in an alert; agents use plan_compress. Trim is an editor.
            if title == "Merge" { return merged("Merged.mp4") }
            return table(["1080p": (" 1080p", "mp4"), "720p": (" 720p", "mp4"), "480p": (" 480p", "mp4"), "Mute": (" muted", "mov"),
                          "Extract Audio": ("", "m4a"), "Frame": (" frame", "png"), "GIF": ("", "gif")])
        case (.convert, .audio):
            return Audio.formats.first { $0.name == title }.map { each($0.name == "ALAC" ? " lossless" : "", $0.ext) }
        case (.tools, .audio):
            if title == "Merge" { return merged("Merged.m4a") }
            return table(["Compress": (" compressed", "m4a"), "Mono": (" mono", "m4a"), "Voice Memo": (" voice", "m4a")])
        case (.convert, .pdf):
            if title == "PNG" || title == "JPG" { return .pages(ext: title.lowercased()) }
            return table(["TXT": ("", "txt"), "DOCX": ("", "docx"), "RTF": ("", "rtf"), "HTML": ("", "html")])
        case (.tools, .pdf):
            if title == "Merge" { return merged("Merged.pdf") }
            if title == "Split Pages" { return .split }
            return table(["Compress": (" compressed", "pdf"), "Rotate": (" rotated", "pdf")])
        case (.convert, .document):
            return Docs.formats.first { $0.name == title }.map { each("", $0.ext) }
        case (.convert, .archive):
            return title == "Extract" ? .extracted : nil
        case (_, .archive), (_, .folder), (_, .other):
            return title == "ZIP" ? archive("zip") : title == "TAR.GZ" ? archive("tar.gz") : nil
        default:
            return nil
        }
    }

    /// The files an output would create now, numbered the way `Paths.unique` will number them.
    static func predict(_ output: Output, _ urls: [URL]) throws -> (files: [URL], note: String?) {
        var reserved = Set<String>()
        func named(_ url: URL, _ suffix: String, _ ext: String) -> URL {
            unique(url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix).appendingPathExtension(ext), &reserved)
        }
        switch output {
        case .each(let suffix, let ext):
            return (urls.map { named($0, suffix, ext($0)) }, nil)
        case .imagePages(let ext):
            var files: [URL] = []
            for url in urls {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ToolError("Couldn't read image") }
                let count = CGImageSourceGetCount(source)
                if CGImageSourceGetType(source) as String? != UTType.tiff.identifier { try Images.requireSingleImage(source) }
                guard count > 0, count <= 1000 else { throw ToolError("Too many image pages") }
                for index in 0..<count { try Images.validatePrecision(source, index: index, target: UTType(filenameExtension: ext)) }
                files += count == 1 ? [named(url, "", ext)] : (0..<count).map { named(url, " \($0 + 1)", ext) }
            }
            return (files, files.count > urls.count ? "Every TIFF page is exported separately; no pages are dropped." : nil)
        case .one(let place):
            // Archives take several files by name from one folder (Archives.zip/tar check this too, later).
            if ["zip", "gz"].contains(place(urls).pathExtension), Set(urls.map { $0.deletingLastPathComponent().path }).count > 1 {
                throw ToolError(L("Choose files from one folder to archive them together."))
            }
            return ([unique(place(urls), &reserved)], nil)
        case .pages(let ext):
            var files: [URL] = []
            for url in urls {
                let count = try PDFs.open(url).pageCount
                files += count == 1 ? [named(url, "", ext)] : (0..<count).map { named(url, " \($0 + 1)", ext) }
            }
            return (files, nil)
        case .split:
            var files: [URL] = []
            for url in urls { files += (0..<(try PDFs.open(url).pageCount)).map { named(url, " \($0 + 1)", "pdf") } }
            return (files, nil)
        case .extracted:
            return ([], "The archive's top-level items are placed next to it, keeping their names (taken names get a number). The exact list is known after apply_plan.")
        }
    }

    /// `Paths.unique`, also skipping names this plan already gave out.
    static func unique(_ url: URL, _ reserved: inout Set<String>) -> URL {
        func taken(_ candidate: URL) -> Bool { Paths.taken(candidate) || reserved.contains(candidate.path) }
        var result = url
        if taken(url) {
            let dir = url.deletingLastPathComponent(), ext = url.pathExtension, base = url.deletingPathExtension().lastPathComponent
            var n = 2
            repeat {
                result = dir.appendingPathComponent("\(base) \(n)")
                if !ext.isEmpty { result.appendPathExtension(ext) }
                n += 1
            } while taken(result)
        }
        reserved.insert(result.path)
        return result
    }
}

// MARK: - Paths and fingerprints

/// Checks the paths a host passes before any tool touches them: absolute, plain (no "." or ".." parts), existing,
/// a regular file or folder itself rather than a symbolic link, device or pipe. Folders above may be links (/tmp,
/// /var); the result is the resolved path of the same directory entry.
enum MCPPaths {
    static let maxCount = 200

    static func list(_ value: Any?, name: String = "paths", protected: [String] = []) throws -> [URL] {
        guard let array = value as? [Any], !array.isEmpty else { throw ToolError("\(name) must be a non-empty array of absolute paths") }
        guard array.count <= maxCount else { throw ToolError("At most \(maxCount) paths at a time") }
        var seen = Set<String>(), result: [URL] = []
        for item in array {
            guard let raw = item as? String else { throw ToolError("\(name) must contain strings") }
            let url = try entry(raw, protected: protected)
            if seen.insert(url.path).inserted { result.append(url) }
        }
        return result
    }

    /// `protected` folders (the undo log's) are refused, with anything inside them, hard links to their files and,
    /// unless `ancestors` is false, every folder above them (renaming or moving one would orphan the log).
    static func entry(_ raw: String, folder: Bool = false, protected: [String] = [], ancestors: Bool = true) throws -> URL {
        let shown = shown(raw)
        guard raw.hasPrefix("/") else { throw ToolError("“\(shown)” is not an absolute path. Pass the full path, starting with /.") }
        guard !raw.contains("\0"), raw.utf8.count < Int(PATH_MAX) else { throw ToolError("“\(shown)” is not a valid path") }
        var path = raw
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path != "/", !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ToolError("“\(shown)” must be a plain absolute path, without “.”, “..” or empty parts")
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ToolError("“\(shown)” doesn't exist") }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { throw ToolError("“\(shown)” is a symbolic link. Pass the path of the file it points to.") }
        guard type == S_IFREG || type == S_IFDIR else { throw ToolError("“\(shown)” is not a regular file or folder") }
        if folder, type != S_IFDIR { throw ToolError("“\(shown)” is not a folder") }
        // "photo.png/" names a folder, not the file.
        if raw.hasSuffix("/"), type != S_IFDIR { throw ToolError("“\(shown)” ends in / but is not a folder") }
        guard let resolved = realpath(path, nil) else { throw ToolError("“\(shown)” can't be read") }
        let canonical = String(cString: resolved)
        free(resolved)
        var again = stat()
        guard lstat(canonical, &again) == 0, again.st_dev == info.st_dev, again.st_ino == info.st_ino else {
            throw ToolError("“\(shown)” changed while it was being checked")
        }
        // Compared without case: the usual Mac disk doesn't tell "Library" from "library".
        let folded = canonical.lowercased()
        let guarded = protected.contains { place in
            let place = place.lowercased()
            return folded == place || folded.hasPrefix(place + "/") || (ancestors && place.hasPrefix(folded + "/"))
        }
        if guarded || (type == S_IFREG && info.st_nlink > 1 && protected.contains { holds($0, device: info.st_dev, inode: info.st_ino) }) {
            throw ToolError("“\(shown)” holds Swivel's undo log and can't be used here")
        }
        return URL(fileURLWithPath: canonical, isDirectory: type == S_IFDIR)
    }

    /// Whether this entry is one of the files directly in `folder` (a hard link has no other tell).
    private static func holds(_ folder: String, device: dev_t, inode: ino_t) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains { name in
            var info = stat()
            return lstat(folder + "/" + name, &info) == 0 && info.st_dev == device && info.st_ino == inode
        }
    }

    /// A value from the host, short enough to echo in an error.
    static func shown(_ raw: String, limit: Int = 300) -> String {
        raw.count > limit ? String(raw.prefix(limit)) + "…" : raw
    }
}

extension MCPPaths {
    /// The real path, as `realpath` gives it (`resolvingSymlinksInPath` drops /private instead), for a folder that
    /// may not exist yet.
    static func resolved(_ url: URL) -> String {
        var tail: [String] = [], current = url.standardizedFileURL
        while current.path != "/" {
            if let real = realpath(current.path, nil) {
                defer { free(real) }
                return ([String(cString: real)] + tail.reversed()).joined(separator: "/")
            }
            tail.append(current.lastPathComponent)
            current = current.deletingLastPathComponent()
        }
        return url.standardizedFileURL.path
    }
}

/// A directory entry as it was: the same entry (lstat device and inode), size and modification time.
struct MCPFingerprint: Codable, Equatable, Sendable {
    var path: String
    var device: Int32
    var inode: UInt64
    var size: Int64
    var seconds: Int
    var nanoseconds: Int
    var folder: Bool
    /// For a folder read `withContents`: a digest of everything beneath it, since editing a file inside changes
    /// nothing about the folder's own entry. `unchecked` when it was too big or partly unreadable.
    var tree: String? = nil

    static let unchecked = "unchecked"
    static let maxTreeEntries = 20_000

    static func read(_ url: URL, withContents: Bool = false) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ToolError("\(url.path) is missing") }
        let folder = info.st_mode & S_IFMT == S_IFDIR
        return Self(path: url.path, device: info.st_dev, inode: UInt64(info.st_ino), size: Int64(info.st_size),
                    seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec, folder: folder,
                    tree: folder && withContents ? digest(url.path) : nil)
    }
    /// Still there and unchanged (contents included, when they were read). A folder that couldn't be checked counts
    /// as changed.
    func isCurrent() -> Bool {
        tree != Self.unchecked && (try? Self.read(URL(fileURLWithPath: path), withContents: tree != nil)) == self
    }

    /// Every entry below `path` (relative name, type, inode, size, modification time), without following links or
    /// leaving the disk, sorted and hashed.
    static func digest(_ path: String, limit: Int = maxTreeEntries) -> String {
        guard let root = strdup(path) else { return unchecked }
        defer { free(root) }
        var paths: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return unchecked }
        defer { fts_close(fts) }
        var lines: [String] = []
        while let entry = fts_read(fts) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_DNR, FTS_ERR, FTS_NS: return unchecked
            case FTS_DP: continue
            default:
                guard entry.pointee.fts_level > 0, let info = entry.pointee.fts_statp?.pointee else { continue }
                guard lines.count < limit else { return unchecked }
                let name = String(decoding: String(cString: entry.pointee.fts_path).utf8.dropFirst(path.utf8.count), as: UTF8.self)
                lines.append("\(name)\0\(info.st_mode)\0\(info.st_ino)\0\(info.st_size)\0\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
            }
        }
        let hash = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    /// Still the same entry at this path, whatever happened to its contents.
    func isSameEntry() -> Bool {
        guard let now = try? Self.read(URL(fileURLWithPath: path)) else { return false }
        return now.device == device && now.inode == inode
    }
}

/// Arguments of one tool call, type-checked; unknown names are refused so a typo can't be silently ignored.
struct MCPArguments {
    private let values: [String: Any]

    init(_ values: [String: Any], allowed: Set<String>) throws {
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ToolError("Unknown argument “\(MCPPaths.shown(unknown))”. This tool takes: \(allowed.sorted().joined(separator: ", "))")
        }
        self.values = values
    }

    func has(_ key: String) -> Bool { values[key] != nil && !(values[key] is NSNull) }
    func value(_ key: String) -> Any? { has(key) ? values[key] : nil }

    func string(_ key: String, required: Bool = false) throws -> String? {
        guard has(key) else { if required { throw ToolError("\(key) is required") }; return nil }
        guard let value = values[key] as? String else { throw ToolError("\(key) must be a string") }
        return value
    }

    func int(_ key: String, required: Bool = false, in range: ClosedRange<Int>) throws -> Int? {
        guard has(key) else { if required { throw ToolError("\(key) is required") }; return nil }
        guard let number = values[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(exactly: number.doubleValue), range.contains(value) else {
            throw ToolError("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return value
    }

    func bool(_ key: String) throws -> Bool? {
        guard has(key) else { return nil }
        guard let number = values[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ToolError("\(key) must be true or false") }
        return number.boolValue
    }
}

// MARK: - Undo log

/// What `apply_plan` did, kept so `undo` can reverse it: Application Support/Swivel/Agent History/history.json
/// (owner-only), the last 200 entries. Hosts may run several servers at once, so every change holds a file lock.
/// It stays on this Mac like the files it names.
final class MCPHistory: @unchecked Sendable {
    struct Move: Codable, Equatable, Sendable {
        let from: String
        let to: String
        let device: Int32
        let inode: UInt64
    }
    struct Entry: Codable, Sendable {
        let id: String
        let date: Date
        let action: String
        let inputs: [String]
        /// After a partial undo, only what is still to be undone.
        var created: [MCPFingerprint]
        var moves: [Move]
        /// Renames are undone together, so swapped names work.
        let isRename: Bool
        var undone: Date?
    }

    static let limit = 200
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swivel", isDirectory: true).appendingPathComponent("Agent History", isDirectory: true)
    }
    let directory: URL
    var file: URL { directory.appendingPathComponent("history.json") }

    init(directory: URL = MCPHistory.defaultDirectory) { self.directory = directory }

    func entries() throws -> [Entry] { try locked { read() } }

    func update<T>(_ change: (inout [Entry]) throws -> T) throws -> T {
        try locked {
            var all = read()
            let result = try change(&all)
            if all.count > Self.limit { all.removeFirst(all.count - Self.limit) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Atomic: a new file renamed into place, which replaces rather than follows anything at that name.
            try encoder.encode(all).write(to: file, options: .atomic)
            chmod(file.path, 0o600)
            return result
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("history.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ToolError("Couldn't open Swivel's undo log") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ToolError("Couldn't lock Swivel's undo log") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func read() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let entries = try? decoder.decode([Entry].self, from: data) { return entries }
        // Unreadable: keep it aside for inspection and start a fresh log rather than failing every change.
        _ = try? Paths.publish(file, as: directory.appendingPathComponent("history (unreadable).json"))
        return []
    }
}
