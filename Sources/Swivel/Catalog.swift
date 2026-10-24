import AppKit
import UniformTypeIdentifiers

enum FileKind: String, CaseIterable {
    case image, video, audio, pdf, document, archive, folder, other

    var title: String {
        switch self {
        case .image: L("Images")
        case .video: L("Video")
        case .audio: L("Audio")
        case .pdf: L("PDF")
        case .document: L("Documents")
        case .archive: L("Archives")
        case .folder: L("Folders")
        case .other: L("Other files")
        }
    }

    var symbol: String {
        switch self {
        case .image: L("photo")
        case .video: L("film")
        case .audio: L("music.note")
        case .pdf: L("doc.richtext")
        case .document: L("doc.text")
        case .archive: L("archivebox")
        case .folder: L("folder")
        case .other: L("doc")
        }
    }

    /// A made-up file of this kind, for listing a menu's default contents.
    var sampleURLs: [URL] {
        let names: [String] = switch self {
        case .image: ["a.jpg", "b.jpg"]
        case .video: ["a.mov", "b.mov"]
        case .audio: ["a.mp3", "b.mp3"]
        case .pdf: ["a.pdf", "b.pdf"]
        case .document: ["a.docx"]
        case .archive: ["a.zip"]
        case .folder, .other: ["a.unknownext"]
        }
        return names.map { URL(fileURLWithPath: "/nonexistent/\($0)") }
    }

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "rtfd"].contains(ext) { return .document }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return .folder }
        // Disk images conform to "archive" but can't be unpacked with tar; macOS opens them itself.
        if ext == "dmg" || ext == "sparseimage" || ext == "sparsebundle" { return .other }
        // RAR and 7-Zip have no system type unless an app declares one; old-style RAR parts are .r00, .r01…
        if Archives.extractableExtensions.contains(ext) || ext.wholeMatch(of: #/r\d\d/#) != nil { return .archive }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if Docs.readableExtensions.contains(ext) { return .document }
        return .other
    }

    static func of(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(of))
        return kinds.count == 1 ? kinds.first! : .other
    }
}

/// Decides which wheel items a drag gets, per file kind and key.
@MainActor
enum Catalog {
    private static var codeCache: [SavedQRCode]?
    private static var codeObserver: NSObjectProtocol?
    static func savedCodes() -> [SavedQRCode] {
        if codeObserver == nil {
            codeObserver = NotificationCenter.default.addObserver(forName: QRLibraryStore.changed, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { codeCache = nil }
            }
        }
        if codeCache == nil { codeCache = (try? QRLibraryStore().load()) ?? [] }
        return codeCache ?? []
    }
    static func displayTitle(_ id: String) -> String {
        if id == "Arrange PDF Pages" { return L("PDF Pages") }
        if id == "Read QR Codes" { return L("Scan QR") }
        if id == "Float" { return L("Add to Shelf") }
        if id.hasPrefix("qr."), let entry = savedCodes().first(where: { "qr." + $0.id.uuidString == id }) { return entry.name }
        if id.hasPrefix("app."), let target = Prefs.fileAppTargets.first(where: { $0.actionID == id }) {
            return target.name
        }
        if id.hasPrefix("preset."), let preset = Prefs.imagePresets.first(where: { $0.actionID == id }) {
            return preset.displayName
        }
        return L(id)
    }

    static func standaloneItems(for urls: [URL], mode: WheelMode) -> [WheelItem] {
        defaultItems(for: urls, mode: mode).filter {
            ["Extract Text", "Float", "Hang", "Batch Rename", "Arrange PDF Pages", "Read QR Codes", "QR Library"].contains($0.title) || $0.title.hasPrefix("preset.") || $0.title.hasPrefix("app.") || $0.title.hasPrefix("qr.")
        }
    }
    /// The menu for a drag, in the user's order with hidden items removed.
    @MainActor
    static func items(for urls: [URL], mode: WheelMode) -> [WheelItem] {
        Prefs.arrange(defaultItems(for: urls, mode: mode), mode, FileKind.of(urls))
    }

    /// Everything a menu can offer for a kind of file, used by the Customize settings.
    static func allItems(mode: WheelMode, kind: FileKind) -> [String] {
        if mode == .apps {
            guard Feature.appRouting.isOn else { return [] }
            // Customize represents a whole category, not just its sample .jpg/.docx file.
            return Prefs.fileAppTargets.filter { target in
                target.enabled && (target.extensions.isEmpty || target.extensions.contains { ext in
                    FileKind.of(URL(fileURLWithPath: "/nonexistent/file." + ext)) == kind
                })
            }.map(\.actionID)
        }
        let multi = defaultItems(for: kind.sampleURLs, mode: mode).map(\.title)
        let single = defaultItems(for: Array(kind.sampleURLs.prefix(1)), mode: mode).map(\.title)
        return multi + single.filter { !multi.contains($0) }
    }

    static func defaultItems(for urls: [URL], mode: WheelMode) -> [WheelItem] {
        if mode == .custom { return CustomWheel.items(for: urls) }
        if mode == .codes {
            guard Feature.qrCodes.isOn else { return [] }
            return [WheelItem(title: "QR Library") { _ in
                guard Feature.qrCodes.isOn else { throw ToolError(L("This feature is turned off.")) }
                QRLibraryWindow().show(); return ActionResult(message: "")
            }] + savedCodes().map { entry in
                WheelItem(title: "qr." + entry.id.uuidString) { _ in
                    guard Feature.qrCodes.isOn else { throw ToolError(L("This feature is turned off.")) }
                    guard try QRLibraryStore().load().contains(where: { $0.id == entry.id }) else { throw ToolError(L("This saved code was removed. Open the QR Library to refresh.")) }
                    QRLibraryWindow(select: entry.id).show(); return ActionResult(message: "")
                }
            }
        }
        if mode == .apps {
            guard Feature.appRouting.isOn else { return [] }
            return Prefs.fileAppTargets.filter { $0.enabled && (urls.isEmpty || $0.accepts(urls)) }.map { target in
                WheelItem(title: target.actionID) { files in
                    let selected = files.isEmpty ? ToolUI.chooseFiles(folders: true) : files
                    guard !selected.isEmpty else { throw Cancelled() }
                    return try await FileAppRouting.run(target, files: selected)
                }
            }
        }
        guard !urls.isEmpty else { return [] }
        let kind = FileKind.of(urls)
        let sourceExt = Set(urls.map { $0.pathExtension.lowercased() })
        let multi = urls.count > 1

        switch mode {
        case .apps, .codes, .custom: return [] // Handled above, including no-file shortcut wheels.
        case .actions:
            var list = actions(multi: multi)
            if Feature.batchRename.isOn {
                list.append(WheelItem(title: "Batch Rename") { files in
                    guard Feature.batchRename.isOn else { throw ToolError(L("This feature is turned off.")) }
                    BatchRenameWindow(files).show(); return ActionResult(message: "")
                })
            }
            if kind == .image && Feature.clothesline.isOn {
                list.insert(WheelItem(title: "Hang") { urls in
                    guard Feature.clothesline.isOn else { throw ToolError(L("This feature is turned off.")) }
                    Clothesline.shared.hang(urls)
                    return ActionResult(message: urls.count == 1 ? L("Hung on the clothesline") : L("Hung %d images on the clothesline", urls.count))
                }, at: 1)
            }
            if kind == .document { list.append(each("Word Count", urls, Docs.wordCount)) }
            return Feature.shelf.isOn ? list : list.filter { $0.title != "Float" }

        case .convert:
            switch kind {
            case .image:
                var list = Images.outputFormats
                    .filter { !$0.extensions.contains(where: sourceExt.contains) || multi }
                    .map { format in each(format.name, urls) { try await Images.convert($0, to: format) } }
                list.append(WheelItem(title: "PDF") { urls in
                    saved(try await Images.makePDF(urls))
                })
                return list
            case .video:
                return Video.convertItems(sourceExt: sourceExt).map { option in each(option.title, urls, option.run) }
            case .audio:
                return Audio.formats
                    .filter { !sourceExt.contains($0.ext) || $0.name == "ALAC" }
                    .map { format in each(format.name, urls) { try await Audio.convert($0, to: format) } }
            case .pdf:
                return PDFs.convertItems.map { option in each(option.title, urls, option.run) }
            case .document:
                return Docs.formats
                    .filter { !sourceExt.contains($0.ext) }
                    .map { format in each(format.name, urls) { try await Docs.convert($0, to: format) } }
            case .archive:
                return [WheelItem(title: "Extract") { urls in
                    // Dropping every part of a multi-part RAR extracts it once.
                    var seen: Set<URL> = []
                    let selected = urls.filter { url in
                        let first = (try? Archives.volumes(of: url).first) ?? url
                        return seen.insert(first.standardizedFileURL).inserted
                    }
                    return try await each("Extract", selected, Archives.extract).run(selected)
                }]
            case .folder:
                return []  // Change Style and compressing are in the Tools menu.
            case .other:
                return Archives.compressItems
            }

        case .tools:
            switch kind {
            case .image:
                let editors: [WheelItem] = [
                    each("Crop", urls) { try await CropEditor(source: $0).present() },
                    each("Upscale", urls) { try await UpscaleEditor(source: $0).present() },
                    WheelItem(title: "Resize…") { try await Images.resize($0) },
                    each("Compress", urls) { try await CompressEditor(source: $0).present() },
                    each("Edit", urls) { try await AdjustEditor(source: $0).present() },
                    each("ID Photo", urls) { try await IDPhotoEditor(source: $0).present() },
                    each("Add BG", urls) { try await BackgroundEditor(source: $0).present() },
                    each("Remove BG", urls) { try await Cutout.removeBackground($0) },
                    each("Blur BG", urls) { try await BlurBackgroundEditor(source: $0).present() },
                    each("Retouch", urls) { try await RetouchEditor(source: $0).present() },
                    each("Redact", urls) { try await RedactEditor(source: $0).present() },
                    each("Metadata", urls) { try await MetadataEditor(source: $0).present() },
                    each("Annotate", urls) { try await AnnotateEditor(source: $0).present() },
                ]
                var list = editors + Images.toolItems.map { option in each(option.title, urls, option.run) }
                    + [WheelItem(title: "Make PDF") { saved(try await Images.makePDF($0)) }]
                if Feature.qrCodes.isOn {
                    list.insert(WheelItem(title: "Read QR Codes") { files in
                        guard Feature.qrCodes.isOn else { throw ToolError(L("This feature is turned off.")) }
                        QRCodesWindow(files).show(); return ActionResult(message: "")
                    }, at: 0)
                }
                if Feature.textCapture.isOn && !multi {
                    list.insert(WheelItem(title: "Extract Text") { urls in
                        guard Feature.textCapture.isOn, let url = urls.first else { throw ToolError(L("This feature is turned off.")) }
                        TextCaptureWindow.present(url)
                        // The window opening is the feedback; no toast.
                        return ActionResult(message: "")
                    }, at: 0)
                }
                if Feature.imagePresets.isOn {
                    list += Prefs.imagePresets.map { preset in
                        WheelItem(title: preset.actionID) { try await PresetActions.run(preset, urls: $0) }
                    }
                }
                if multi { list.insert(WheelItem(title: "Collage") { saved(try await CollageEditor(urls: $0).present()) }, at: 0) }
                return list
            case .video:
                var list = [each("Trim", urls) { try await TrimEditor(source: $0).present() }]
                    + Video.toolItems.map { option in
                        option.title == "Compress" ? WheelItem(title: "Compress") { try await Video.compress($0) }
                            : each(option.title, urls, option.run)
                    }
                list.insert(each("Upscale", urls) { try await UpscaleEditor(source: $0, video: true).present() }, at: 1)
                if #available(macOS 26, *) {
                    list.insert(WheelItem(title: "Subtitles") { try await TranscriptionEditor.run($0, isVideo: true) }, at: 1)
                }
                if multi { list.insert(WheelItem(title: "Merge") { saved([try await Video.merge($0, audioOnly: false)]) }, at: 0) }
                return list
            case .audio:
                var list = [each("Trim", urls) { try await TrimEditor(source: $0).present() },
                            each("Reduce Noise", urls) { try await NoiseReductionEditor(source: $0).present() }]
                    + Audio.toolItems.map { option in each(option.title, urls, option.run) }
                if #available(macOS 26, *) {
                    list.insert(WheelItem(title: "Transcribe") { try await TranscriptionEditor.run($0, isVideo: false) }, at: 1)
                }
                if multi { list.insert(WheelItem(title: "Merge") { saved([try await Video.merge($0, audioOnly: true)]) }, at: 0) }
                return list
            case .pdf:
                var list = [each("Crop", urls) { try await CropEditor(source: $0).present() }]
                    + PDFs.toolItems.map { option in each(option.title, urls, option.run) }
                if Feature.pdfPages.isOn {
                    list.insert(WheelItem(title: "Arrange PDF Pages") { files in
                        guard Feature.pdfPages.isOn else { throw ToolError(L("This feature is turned off.")) }
                        PDFPagesWindow(files).show(); return ActionResult(message: "")
                    }, at: 0)
                }
                if multi { list.insert(WheelItem(title: "Merge") { saved([try await PDFs.merge($0)]) }, at: 0) }
                return list
            case .document:
                return []  // Word Count is in the Actions menu.
            case .folder:
                return [WheelItem(title: "Change Style") { folders in
                    let editor = try FolderStyleEditor(folders: folders)
                    let changed = try await editor.present()
                    let message = editor.restoredDefault
                        ? (changed.count == 1 ? L("Restored the default folder icon") : L("Restored %d folder icons", changed.count))
                        : (changed.count == 1 ? L("Restyled %@", changed[0].lastPathComponent) : L("Restyled %d folders", changed.count))
                    return ActionResult(message: message)
                }] + Archives.compressItems
            case .archive, .other:
                return Archives.compressItems
            }
        }
    }

    /// An item that runs `work` on each file in turn and collects the outputs.
    static func each(_ title: String, _ urls: [URL],
                     _ work: @escaping @MainActor (URL) async throws -> [URL]) -> WheelItem {
        WheelItem(title: title) { urls in
            var outputs: [URL] = [], failures: [String] = []
            for url in urls {
                do { try Task.checkCancellation(); outputs += try await work(url) }
                catch {
                    if outputs.isEmpty, error is Info || error is Cancelled || error is CancellationError { throw error }
                    let partial = PartialOutputError.wrapping(error, files: [])
                    outputs += partial.files
                    failures += partial.failures.map { "\(url.lastPathComponent): \($0)" }
                    if error is CancellationError || error is Cancelled || Task.isCancelled { break }
                }
            }
            if !failures.isEmpty { throw PartialOutputError(files: outputs, failures: failures) }
            return saved(outputs)
        }
    }

    static func saved(_ files: [URL]) -> ActionResult {
        switch files.count {
        case 0: ActionResult(message: "Done")
        case 1: ActionResult(message: L("Saved %@", files[0].lastPathComponent), files: files)
        default: ActionResult(message: L("Saved %d files", files.count), files: files)
        }
    }

    private static func actions(multi: Bool) -> [WheelItem] {
        [
            WheelItem(title: "AirDrop") { urls in
                guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                    throw ToolError("AirDrop isn't available")
                }
                NSApp.activate()
                service.perform(withItems: urls)
                return ActionResult(message: "Opened AirDrop")
            },
            WheelItem(title: "Float") { urls in
                guard Feature.shelf.isOn else { throw ToolError(L("This feature is turned off.")) }
                Shelf.shared.add(urls)
                return ActionResult(message: "Added to Shelf")
            },
            WheelItem(title: "Copy") { urls in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
                return ActionResult(message: multi ? L("Copied %d files", urls.count) : L("Copied %@", urls[0].lastPathComponent))
            },
            WheelItem(title: "Move") { urls in
                try FileActions.move(urls)
            },
            WheelItem(title: "Copy Path") { urls in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                return ActionResult(message: multi ? L("Copied %d paths", urls.count) : L("Copied path"))
            },
            WheelItem(title: "Terminal") { urls in
                try await FileActions.openTerminal(at: urls[0])
                return ActionResult(message: "Opened in Terminal")
            },
        ]
    }
}

private extension ActionResult {
    func renamed() -> ActionResult {
        var copy = self
        copy.message = files.count == 1 ? L("Moved %@", files[0].lastPathComponent) : L("Moved %d files", files.count)
        return copy
    }
}

/// A titled per-file operation offered on a wheel.
struct FileOption {
    let title: String
    let run: @MainActor (URL) async throws -> [URL]
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum FileActions {
    @MainActor
    static func move(_ urls: [URL]) throws -> ActionResult {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Move Here")
        panel.message = L("Files on another disk will be copied. Their originals are kept.")
        guard panel.runModal() == .OK, let folder = panel.url else { throw Cancelled() }
        var files: [URL] = [], messages: [String] = [], failures: [String] = []
        for url in urls {
            do {
                do {
                    let moved = try Paths.move(url, into: folder)
                    files.append(moved); messages.append(L("Moved %@", moved.lastPathComponent))
                } catch let error where Paths.crossesVolumes(error) {
                    let copied = try Paths.copy(url, into: folder)
                    files.append(copied); messages.append(L("Copied %@ to another disk; the original was kept.", copied.lastPathComponent))
                }
            } catch { failures.append("\(url.path): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { throw PartialOutputError(files: files, failures: messages + failures) }
        return ActionResult(message: messages.joined(separator: "\n"), files: files)
    }

    @MainActor
    static func openTerminal(at url: URL) async throws {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let folder = isFolder ? url : url.deletingLastPathComponent()
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2")
                ?? ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw ToolError("Terminal not found")
        }
        try await ws.open([folder], withApplicationAt: app, configuration: .init())
    }
}

enum Paths {
    /// `folder/name.ext`, or `name 2.ext`, `name 3.ext`… if taken. Only a forecast: another conversion can take the
    /// name before this one writes, so writers claim theirs with `create`, `publish` or `produce` instead.
    static func output(for source: URL, ext: String, suffix: String = "") -> URL {
        unique(preferred(for: source, ext: ext, suffix: suffix))
    }

    /// `folder/name<suffix>.ext` beside `source`, free or not: the name `create`, `publish` and `produce` start from.
    static func preferred(for source: URL, ext: String, suffix: String = "") -> URL {
        let base = source.deletingPathExtension().lastPathComponent + suffix
        return source.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(ext)
    }

    static func unique(_ url: URL) -> URL {
        var n = 1
        while taken(numbered(url, n)) { n += 1 }
        return numbered(url, n)
    }

    /// `url` itself for 1, else `name n.ext`.
    private static func numbered(_ url: URL, _ n: Int) -> URL {
        guard n > 1 else { return url }
        let ext = url.pathExtension
        var candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n)")
        if !ext.isEmpty { candidate.appendPathExtension(ext) }
        return candidate
    }

    /// Writes `data` as a new file at `preferred`, or `name 2.ext`, `name 3.ext`…, and returns where it went.
    /// The write is exclusive (O_EXCL): a name another writer took after Swivel looked is skipped, never replaced.
    static func create(_ data: Data, at preferred: URL) throws -> URL {
        try produce(preferred) { try FileSafety.write(data, to: $0) }
    }

    /// Moves `item` (finished work in a temporary beside `preferred`) to `preferred` or the next free name, and returns
    /// where it went. The rename is exclusive, so it never replaces anything that appeared after the name was chosen.
    static func publish(_ item: URL, as preferred: URL) throws -> URL {
        try claim(preferred) { try renameExclusively(item, to: $0) }
    }

    /// Moves `item` into `folder` under its own name, or `name 2.ext`…, and returns where it went. The rename claims
    /// the name, as `publish` does. Cross-volume moves are refused: deleting a source by path after copying can
    /// delete a newly saved version. The UI explicitly copies across disks and keeps originals instead.
    static func move(_ item: URL, into folder: URL,
                     rename: (URL, URL) throws -> Void = Paths.renameExclusively) throws -> URL {
        try claim(folder.appendingPathComponent(item.lastPathComponent)) { try rename(item, $0) }
    }

    /// Copies `item` into `folder` under its own name, or `name 2.ext`…, and returns where it went. The copy is made
    /// in a hidden temporary in `folder` and then published, so no half-copied file ever holds the name.
    static func copy(_ item: URL, into folder: URL,
                     rename: (URL, URL) throws -> Void = Paths.renameExclusively) throws -> URL {
        let preferred = folder.appendingPathComponent(item.lastPathComponent)
        let root = try FileSafety.privateDirectory(beside: preferred)
        defer { discard(root) }
        let work = root.appendingPathComponent(item.lastPathComponent)
        try FileManager.default.copyItem(at: item, to: work)
        return try claim(preferred) { try rename(work, $0) }
    }

    /// Whether a rename failed because the destination is on another volume.
    static func crossesVolumes(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain && error.code == Int(EXDEV) { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error else { return false }
        return crossesVolumes(underlying)
    }

    /// Lets `make` write an output file into a private directory beside `preferred`, then publishes it.
    /// Tools and exports that would replace an existing file only ever see the temporary, which never outlives the call.
    static func produce(_ preferred: URL, _ make: (URL) throws -> Void) throws -> URL {
        let root = try FileSafety.privateDirectory(beside: preferred)
        defer { discard(root) }
        let work = root.appendingPathComponent("output").appendingPathExtension(preferred.pathExtension)
        try make(work)
        try Task.checkCancellation()
        try FileSafety.makePrivate(work)
        return try publish(work, as: preferred)
    }

    static func produce(_ preferred: URL, _ make: (URL) async throws -> Void) async throws -> URL {
        let root = try FileSafety.privateDirectory(beside: preferred)
        defer { discard(root) }
        let work = root.appendingPathComponent("output").appendingPathExtension(preferred.pathExtension)
        try await make(work)
        try Task.checkCancellation()
        try FileSafety.makePrivate(work)
        return try publish(work, as: preferred)
    }

    /// An unused hidden name beside `url` for work in progress, removed at quit if it's still there; `discard` removes it.
    static func temporary(beside url: URL, ext: String) -> URL {
        let name = ".swivel-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
        let work = url.deletingLastPathComponent().appendingPathComponent(name)
        TemporaryItems.register(work)
        return work
    }

    static func discard(_ temporary: URL) {
        Archives.makeAccessible(temporary)
        do {
            try FileManager.default.removeItem(at: temporary)
            TemporaryItems.unregister(temporary)
        } catch {
            // A failed cleanup stays registered for the orderly shutdown retry.
            if !taken(temporary) { TemporaryItems.unregister(temporary) }
        }
    }

    /// Tries `attempt` at `preferred`, then `name 2.ext`, `name 3.ext`… `attempt` fails with "file exists" rather than
    /// replace anything, and that is the only check: looking first and writing after would leave a gap between the two.
    private static func claim(_ preferred: URL, _ attempt: (URL) throws -> Void) throws -> URL {
        for n in 1...10_000 {
            let candidate = numbered(preferred, n)
            do {
                try attempt(candidate)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw fileError(EEXIST, preferred)
    }

    /// `renamex_np` with RENAME_EXCL. Volumes without it (exFAT, some network shares) answer ENOTSUP; there the name is
    /// claimed by `renameOverPlaceholder` instead.
    static func renameExclusively(_ item: URL, to destination: URL) throws {
        let result = item.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in renamex_np(from!, to!, UInt32(RENAME_EXCL)) }
        }
        guard result != 0 else { return }
        let code = errno
        guard code == ENOTSUP else { throw fileError(code, destination) }
        try renameOverPlaceholder(item, to: destination)
    }

    /// Claims `destination` with an exclusive create (an empty file, or folder for a folder), then renames `item` over
    /// that placeholder. Nothing that was already there is replaced; only Swivel's own placeholder is.
    static func renameOverPlaceholder(_ item: URL, to destination: URL) throws {
        var info = stat()
        guard lstat(item.path, &info) == 0 else { throw fileError(errno, item) }
        let folder = info.st_mode & S_IFMT == S_IFDIR
        if folder {
            guard mkdir(destination.path, 0o700) == 0 else { throw fileError(errno, destination) }
        } else {
            let placeholder = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard placeholder >= 0 else { throw fileError(errno, destination) }
            close(placeholder)
        }
        guard rename(item.path, destination.path) == 0 else {
            let code = errno
            _ = folder ? rmdir(destination.path) : unlink(destination.path)
            throw fileError(code, destination)
        }
    }

    private static func fileError(_ code: Int32, _ url: URL) -> CocoaError {
        let posix = POSIXErrorCode(rawValue: code) ?? .EIO
        let cocoa: CocoaError.Code = switch posix {
        case .EEXIST: .fileWriteFileExists
        case .EACCES, .EPERM: .fileWriteNoPermission
        case .ENOSPC, .EDQUOT: .fileWriteOutOfSpace
        case .EROFS: .fileWriteVolumeReadOnly
        case .ENOENT: .fileNoSuchFile
        default: .fileWriteUnknown
        }
        return CocoaError(cocoa, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: POSIXError(posix)])
    }

    /// Anything at the path counts, a symlink included. `fileExists` follows links, so a dangling one planted under
    /// the predicted output name (for example inside a downloaded archive) would look free and be written through.
    static func taken(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

/// Hidden working folders and files (extraction staging, encodes in progress) to clean up if Swivel quits first.
enum TemporaryItems {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var items: Set<URL> = []
    static func register(_ url: URL) { lock.lock(); items.insert(url); lock.unlock() }
    static func unregister(_ url: URL) { lock.lock(); items.remove(url); lock.unlock() }
    /// At quit: stops running tools first, so nothing writes into a folder while it's removed.
    static func removeAll() {
        Shell.stopAll()
        lock.lock(); let all = items; items = []; lock.unlock()
        for url in all {
            Archives.makeAccessible(url)
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum Shell {
    /// Stops every running tool (Swivel is quitting): children would otherwise keep writing after it's gone.
    static func stopAll() { ShellRun.stopAll(); ShellCapture.stopAll() }

    /// Runs a command-line tool and throws its stderr on failure.
    ///
    /// The tool reads `input` files in order (or an empty stdin), so it never waits on a terminal. Its stderr is
    /// drained while it runs: a tool that writes more than a pipe's 64 KB would otherwise block forever. `watch` is
    /// asked twice a second; returning a message stops the tool and throws that message. Cancelling the task stops it.
    /// `outputLimit` counts what the tool writes to stdout (otherwise discarded) and stops it with the message past
    /// that many bytes.
    static func run(_ tool: String, _ args: [String], in directory: URL? = nil, input: [URL] = [],
                    outputLimit: (bytes: Int64, message: String)? = nil,
                    watch: (@Sendable () -> String?)? = nil) async throws {
        let run = ShellRun(tool: tool, args: args, directory: directory, input: input, outputLimit: outputLimit, watch: watch)
        try await withTaskCancellationHandler {
            try await run.start()
        } onCancel: {
            run.stop(L("Cancelled"))
        }
    }
}

/// One tool run for `Shell.run`; its state is shared with Foundation's callback threads behind a lock.
private final class ShellRun: @unchecked Sendable {
    private let process = Process()
    private let tool: String
    private let input: [URL]
    private let watch: (@Sendable () -> String?)?
    private let outputLimit: (bytes: Int64, message: String)?
    private let lock = NSLock()
    private var errorTail = Data()
    private var outputBytes: Int64 = 0
    private var stopReason: String?
    private var timer: DispatchSourceTimer?
    private static let keptErrorBytes = 16_384

    init(tool: String, args: [String], directory: URL?, input: [URL], outputLimit: (bytes: Int64, message: String)?,
         watch: (@Sendable () -> String?)?) {
        self.tool = tool
        self.input = input
        self.outputLimit = outputLimit
        self.watch = watch
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let directory { process.currentDirectoryURL = directory }
    }

    private static let registry = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: ShellRun] = [:]
    static func stopAll() {
        let all = registry.withLock { Array(running.values) }
        for run in all { run.stop(L("Cancelled")) }
        for run in all where run.process.isRunning { run.process.waitUntilExit() }
    }
    private static func track(_ run: ShellRun, _ active: Bool) {
        registry.withLock { running[ObjectIdentifier(run)] = active ? run : nil }
    }

    func start() async throws {
        Self.track(self, true)
        defer { Self.track(self, false) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let errors = Pipe()
            process.standardError = errors
            let output = outputLimit == nil ? nil : Pipe()
            process.standardOutput = output ?? FileHandle.nullDevice
            output?.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { self?.count(data.count) }
            }
            let feed = input.isEmpty ? nil : Pipe()
            process.standardInput = feed ?? FileHandle.nullDevice
            errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { self?.keep(data) }
            }
            process.terminationHandler = { [self] p in
                errors.fileHandleForReading.readabilityHandler = nil
                if let output {
                    output.fileHandleForReading.readabilityHandler = nil
                    count(output.fileHandleForReading.readDataToEndOfFile().count)
                }
                keep(errors.fileHandleForReading.readDataToEndOfFile())
                lock.lock()
                timer?.cancel()
                let reason = stopReason, text = String(decoding: errorTail, as: UTF8.self)
                lock.unlock()
                if let reason { return cont.resume(throwing: ToolError(reason)) }
                if p.terminationStatus == 0 { return cont.resume() }
                let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = URL(fileURLWithPath: tool).lastPathComponent
                cont.resume(throwing: ToolError(message.isEmpty ? "\(name) failed" : "\(name): \(message)"))
            }
            do { try process.run() } catch {
                errors.fileHandleForReading.readabilityHandler = nil
                output?.fileHandleForReading.readabilityHandler = nil
                return cont.resume(throwing: error)
            }
            lock.lock(); let stoppedEarly = stopReason != nil; lock.unlock()
            if stoppedEarly { process.terminate() }
            if let feed { send(input, to: feed.fileHandleForWriting) }
            if let watch {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
                timer.setEventHandler { [weak self] in if let message = watch() { self?.stop(message) } }
                lock.lock(); self.timer = timer; lock.unlock()
                timer.resume()
            }
        }
    }

    /// Stops the tool; its run then throws `reason` (the first reason given wins).
    func stop(_ reason: String) {
        lock.lock()
        let first = stopReason == nil
        if first { stopReason = reason }
        lock.unlock()
        if process.isRunning { process.terminate() }
        if first {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func count(_ bytes: Int) {
        guard let outputLimit, bytes > 0 else { return }
        lock.lock()
        outputBytes += Int64(bytes)
        let over = outputBytes > outputLimit.bytes
        lock.unlock()
        if over { stop(outputLimit.message) }
    }

    private func keep(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        errorTail.append(data)
        if errorTail.count > Self.keptErrorBytes { errorTail = errorTail.suffix(Self.keptErrorBytes) }
        lock.unlock()
    }

    /// Streams the files into the tool's stdin on a background thread. A tool that exits early just ends the copy:
    /// the write end ignores SIGPIPE, so the write fails instead of killing Swivel.
    private func send(_ files: [URL], to handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        Thread.detachNewThread {
            defer { try? handle.close() }
            for file in files {
                let reader: FileHandle
                do { reader = try FileHandle(forReadingFrom: file) }
                catch { self.stop(error.localizedDescription); return }
                defer { try? reader.close() }
                while true {
                    let chunk: Data
                    do { chunk = try reader.read(upToCount: 1 << 20) ?? Data() }
                    catch { self.stop(error.localizedDescription); return }
                    if chunk.isEmpty { break }
                    do { try handle.write(contentsOf: chunk) } catch { return }
                }
            }
        }
    }
}
