import AppKit
import PDFKit
import UniformTypeIdentifiers

struct DocFormat {
    let name: String
    let ext: String
    let type: NSAttributedString.DocumentType?  // nil = PDF
}

enum Docs {
    // Web archives are not read: importing one loads its subresources, including remote URLs and local files.
    static let readableExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "txt", "text", "html", "htm",
                                                  "md", "markdown"]

    static let formats: [DocFormat] = [
        DocFormat(name: "DOCX", ext: "docx", type: .officeOpenXML),
        DocFormat(name: "PDF", ext: "pdf", type: nil),
        DocFormat(name: "RTF", ext: "rtf", type: .rtf),
        DocFormat(name: "TXT", ext: "txt", type: .plain),
        DocFormat(name: "HTML", ext: "html", type: .html),
        DocFormat(name: "ODT", ext: "odt", type: .openDocument),
        DocFormat(name: "DOC", ext: "doc", type: .docFormat),
    ]

    @MainActor
    static func convert(_ url: URL, to format: DocFormat) async throws -> [URL] {
        [try save(try read(url), as: Paths.preferred(for: url, ext: format.ext), format: format)]
    }

    @MainActor
    static func wordCount(_ url: URL) async throws -> [URL] {
        let string = try read(url).string
        let words = string.split { $0.isWhitespace || $0.isNewline }.count
        throw Info(L("%@: %ld words, %ld characters", url.lastPathComponent, words, string.count))
    }

    @MainActor
    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            guard let source = String(data: try FileSafety.read(url, limit: 64 * 1024 * 1024), encoding: .utf8) else {
                throw ToolError(L("Couldn't read document text."))
            }
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return NSAttributedString(try AttributedString(markdown: source, options: options))
        }
        if ext == "rtfd" {
            try checkPackageBudget(url)
            // A package's attachments can be symlinks to any file, which the export would embed. Drop them first.
            let package = try FileWrapper(url: url, options: .immediate)
            removeSymlinks(in: package)
            guard let text = NSAttributedString(rtfdFileWrapper: package, documentAttributes: nil) else {
                throw ToolError("Couldn't read \(url.lastPathComponent)")
            }
            return text
        }
        // The type always comes from the extension. Left to sniff the content, AppKit would read a web archive
        // renamed to .doc or .odt with WebKit, fetching its remote and local resources into the output.
        let types: [String: NSAttributedString.DocumentType] = [
            "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument, "rtf": .rtf,
            "txt": .plain, "text": .plain, "html": .html, "htm": .html,
        ]
        guard let type = types[ext] else { throw ToolError("Can't read \(url.lastPathComponent)") }
        let text = try NSAttributedString(data: FileSafety.read(url, limit: 64 * 1024 * 1024), options: [.documentType: type], documentAttributes: nil)
        // Images and frames in HTML are references to other files or the web: keep the text, never the fetched content.
        return type == .html ? withoutAttachments(text) : text
    }

    private static func checkPackageBudget(_ root: URL) throws {
        var queue = [root], bytes: Int64 = 0, count = 0
        while let item = queue.popLast() {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw POSIXError(.EIO) }
            count += 1
            if info.st_mode & S_IFMT == S_IFREG { bytes += info.st_size }
            guard count <= 10_000, bytes <= 64 * 1024 * 1024 else { throw ToolError(L("This file exceeds the safe reading limit.")) }
            if info.st_mode & S_IFMT == S_IFDIR { queue += try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) }
        }
    }

    private static func removeSymlinks(in wrapper: FileWrapper) {
        for child in (wrapper.fileWrappers ?? [:]).values {
            if child.isSymbolicLink { wrapper.removeFileWrapper(child) }
            else if child.isDirectory { removeSymlinks(in: child) }
        }
    }

    private static func withoutAttachments(_ text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        var ranges: [NSRange] = []
        copy.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        for range in ranges.reversed() { copy.deleteCharacters(in: range) }
        return copy
    }

    /// Saves `text` as a new file at `preferred` or the next free name, and returns where it went.
    @MainActor
    static func save(_ text: NSAttributedString, as preferred: URL, format: DocFormat) throws -> URL {
        // Printing replaces whatever is at its destination, so it prints into a temporary.
        guard let type = format.type else { return try Paths.produce(preferred) { try writePDF(text, to: $0) } }
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .plain || type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attrs)
        return try Paths.create(data, at: preferred)
    }

    /// Lays the text out on US Letter pages and prints it to a PDF file at `out`, replacing anything there.
    @MainActor
    static func writePDF(_ text: NSAttributedString, to out: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        for edge in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: edge] = 54 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.appearance = NSAppearance(named: .aqua)
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let used = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 1
        view.setFrameSize(NSSize(width: width, height: max(used, 1)))

        // Printing into a folder that can't be written never returns (the print session fails with -61 and the
        // operation waits), so check first.
        guard access(out.deletingLastPathComponent().path, W_OK) == 0 else {
            throw ToolError(L("Can't write to the folder %@.", out.deletingLastPathComponent().lastPathComponent))
        }
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else { throw ToolError("Couldn't create PDF") }
    }
}

/// Thrown to report a result that isn't a file (shown in the toast as-is).
struct Info: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum PDFs {
    static let convertItems: [FileOption] = [
        FileOption(title: "PNG") { try await pages($0, as: .png, ext: "png") },
        FileOption(title: "JPG") { try await pages($0, as: .jpeg, ext: "jpg") },
        FileOption(title: "TXT") { try await text($0, format: Docs.formats.first { $0.ext == "txt" }!) },
        FileOption(title: "DOCX") { try await text($0, format: Docs.formats.first { $0.ext == "docx" }!) },
        FileOption(title: "RTF") { try await text($0, format: Docs.formats.first { $0.ext == "rtf" }!) },
        FileOption(title: "HTML") { try await text($0, format: Docs.formats.first { $0.ext == "html" }!) },
    ]

    static let toolItems: [FileOption] = [
        FileOption(title: "Compress") { try compress($0) },
        FileOption(title: "Split Pages") { try split($0) },
        FileOption(title: "Rotate") { try rotate($0) },
        FileOption(title: "Page Count") { url in
            throw Info("\(url.lastPathComponent): \(try open(url).pageCount) pages")
        },
    ]

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(data: try FileSafety.read(url, limit: 256 * 1024 * 1024)) else { throw ToolError("Couldn't open \(url.lastPathComponent)") }
        if doc.isLocked { throw ToolError("\(url.lastPathComponent) is password protected") }
        guard doc.pageCount <= 2000 else { throw ToolError(L("Choose at most 2,000 PDF pages at a time.")) }
        return doc
    }

    @MainActor
    private static func text(_ url: URL, format: DocFormat) async throws -> [URL] {
        let doc = try open(url)
        guard let text = doc.selectionForEntireDocument?.attributedString, text.length > 0 else {
            throw ToolError("No text found in this PDF")
        }
        return [try Docs.save(text, as: Paths.preferred(for: url, ext: format.ext), format: format)]
    }

    /// Renders every page at 300 DPI, next to the original: "name.png" for one page, "name 1.png", "name 2.png"… for more.
    private static func pages(_ url: URL, as type: UTType, ext: String) async throws -> [URL] {
        try await Images.detached {
            let doc = try open(url)
            var outputs: [URL] = []
            do { for index in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: index) else { throw ToolError(L("Couldn't render page")) }
                let suffix = doc.pageCount > 1 ? " \(index + 1)" : ""
                outputs.append(try Images.save(try render(page, dpi: 300), as: Paths.preferred(for: url, ext: ext, suffix: suffix),
                                               type: type, quality: 0.92))
            } } catch { throw PartialOutputError.wrapping(error, files: outputs) }
            return outputs
        }
    }

    /// Bitmaps from PDF pages stay within this budget; a crafted page box can't trap or claim gigabytes.
    static let maxRenderPixels = 150_000_000.0, maxRenderSide = 16_384.0

    static func render(_ page: PDFPage, dpi: CGFloat) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let w = Double(rotated ? box.height : box.width), h = Double(rotated ? box.width : box.height)
        guard w.isFinite, h.isFinite, w > 0, h > 0 else { throw ToolError("Page too large") }
        // Very large pages render at a lower resolution rather than not at all.
        let scale = min(Double(dpi) / 72, maxRenderSide / max(w, h), (maxRenderPixels / (w * h)).squareRoot())
        guard let width = Int(exactly: (w * scale).rounded(.down)), let height = Int(exactly: (h * scale).rounded(.down)),
              width >= 1, height >= 1 else { throw ToolError("Page too large") }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolError("Page too large")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { throw ToolError("Couldn't render page") }
        return image
    }

    static func merge(_ urls: [URL]) async throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            let doc = try open(url)
            guard merged.pageCount + doc.pageCount <= 2000 else { throw ToolError(L("Choose at most 2,000 PDF pages at a time.")) }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        return try save(merged, as: urls[0].deletingLastPathComponent().appendingPathComponent("Merged.pdf"))
    }

    private static func compress(_ url: URL) throws -> [URL] {
        let doc = try open(url)
        return [try save(doc, as: Paths.preferred(for: url, ext: "pdf", suffix: " compressed"),
                         options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])]
    }

    /// One PDF per page, next to the original: "name 1.pdf", "name 2.pdf"…
    private static func split(_ url: URL) throws -> [URL] {
        let doc = try open(url)
        var outputs: [URL] = []
        do { for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { throw ToolError(L("Couldn't render page")) }
            let single = PDFDocument()
            single.insert(page, at: 0)
            outputs.append(try save(single, as: Paths.preferred(for: url, ext: "pdf", suffix: " \(i + 1)")))
        } } catch { throw PartialOutputError.wrapping(error, files: outputs) }
        return outputs
    }

    private static func rotate(_ url: URL) throws -> [URL] {
        let doc = try open(url)
        for i in 0..<doc.pageCount { doc.page(at: i).map { $0.rotation = ($0.rotation + 90) % 360 } }
        return [try save(doc, as: Paths.preferred(for: url, ext: "pdf", suffix: " rotated"))]
    }

    /// Writes a new PDF file at `preferred` or the next free name, never through anything already there
    /// (`PDFDocument.write` follows symlinks). Returns where it went.
    static func save(_ doc: PDFDocument, as preferred: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws -> URL {
        let keyed = Dictionary(uniqueKeysWithValues: options.map { (AnyHashable($0.key.rawValue), $0.value) })
        guard let data = doc.dataRepresentation(options: keyed), let check = PDFDocument(data: data),
              check.pageCount == doc.pageCount else { throw ToolError("Couldn't write PDF") }
        return try Paths.create(data, at: preferred)
    }
}

enum Archives {
    static var compressItems: [WheelItem] {
        [
            WheelItem(title: "ZIP") { urls in Catalog.saved([try await zip(urls)]) },
            WheelItem(title: "TAR.GZ") { urls in Catalog.saved([try await tar(urls)]) },
        ]
    }

    private static func archiveURL(for urls: [URL], ext: String) -> URL {
        let first = urls[0]
        let dir = first.deletingLastPathComponent()
        let name = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        return dir.appendingPathComponent("\(name).\(ext)")
    }

    /// Several files are archived by name from their folder, so they must share it (a name from another folder
    /// would be left out, or pick up a different file of the same name).
    private static func checkOneFolder(_ urls: [URL]) throws {
        guard !urls.isEmpty, Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL }).count == 1 else {
            throw ToolError(L("Choose files from one folder to archive them together."))
        }
    }

    /// The archivers replace (ditto, tar) or add to (zip) an archive already at their output path, so each one
    /// writes a fresh temporary that is published when complete.
    static func zip(_ urls: [URL]) async throws -> URL {
        try checkOneFolder(urls)
        return try await Paths.produce(archiveURL(for: urls, ext: "zip")) { out in
            if urls.count == 1 {
                try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
            } else {
                // ditto preserves resource forks and extended attributes for a selection too.
                let selection = out.deletingLastPathComponent().appendingPathComponent("selection")
                try FileManager.default.createDirectory(at: selection, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                for url in urls {
                    try Task.checkCancellation()
                    try FileManager.default.copyItem(at: url, to: selection.appendingPathComponent(url.lastPathComponent))
                }
                try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", selection.path, out.path])
            }
            try await verify(out)
        }
    }

    static func tar(_ urls: [URL]) async throws -> URL {
        try checkOneFolder(urls)
        try requirePortableMetadata(urls)
        return try await Paths.produce(archiveURL(for: urls, ext: "tar.gz")) { out in
            try await Shell.run("/usr/bin/tar", ["--no-mac-metadata", "-czf", out.path, "-C", urls[0].deletingLastPathComponent().path, "--"]
                                // "./": bsdtar reads a name starting with "@" as another archive to copy, even after "--".
                                + urls.map { $0.lastPathComponent.hasPrefix("@") ? "./" + $0.lastPathComponent : $0.lastPathComponent })
            try await verify(out)
        }
    }

    /// Portable TAR cannot round-trip Mac resource forks through our metadata-isolated extractor.
    /// Refuse that source instead of returning a silently incomplete archive.
    static func requirePortableMetadata(_ urls: [URL]) throws {
        var queue = urls, count = 0
        while let url = queue.popLast() {
            try Task.checkCancellation()
            count += 1
            guard count <= 100_000 else { throw ToolError(L("This archive contains too many items.")) }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
            if info.st_mode & S_IFMT == S_IFLNK { continue }
            let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
            if size < 0, errno != ENOTSUP { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if size > 0 {
                var bytes = [CChar](repeating: 0, count: size)
                guard listxattr(url.path, &bytes, size, XATTR_NOFOLLOW) == size else { throw POSIXError(.EIO) }
                let names = bytes.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                if names.contains(where: { !["com.apple.quarantine", "com.apple.provenance", "com.apple.lastuseddate#PS"].contains($0) }) {
                    throw ToolError(L("This file has Mac metadata that TAR cannot preserve here. Use ZIP instead."))
                }
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                queue += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            }
        }
    }

    /// ditto may succeed despite a bad ZIP CRC. libarchive must read every data byte before publication.
    static func verify(_ archive: URL, watch: (@Sendable () -> String?)? = nil) async throws {
        let start = Date()
        try await Shell.run("/usr/bin/tar", ["-xOf", archive.path, "--no-mac-metadata", "--passphrase", noPassphrase], watch: {
            if Date().timeIntervalSince(start) > 600 { return L("Archive processing took too long and was stopped.") }
            return watch?()
        })
    }

    /// Extensions the system's bsdtar (libarchive) can unpack, beyond what ditto does for ZIP.
    static let extractableExtensions: Set<String> = ["zip", "tar", "tgz", "gz", "rar", "7z", "xz", "txz", "bz2", "tbz",
                                                     "tbz2", "lzma", "lz", "lzh", "lha", "cab", "iso", "xar", "cpio", "jar"]

    /// Free space Extract leaves on the volume; it stops before an archive (or a decompression bomb) fills the disk.
    static let reservedBytes: Int64 = 1_000_000_000

    static func extract(_ url: URL) async throws -> [URL] {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let parts = try volumes(of: url)
        // A pipe or device named like an archive would block the read forever.
        guard isRegularFile(url) else { throw ToolError("Can't read \(url.lastPathComponent)") }
        let folder = parent.path
        guard freeSpace(folder) > reservedBytes else { throw ToolError(L("Not enough free disk space to extract.")) }
        let workspace = try FileSafety.privateDirectory(beside: url)
        defer { makeAccessible(workspace); Paths.discard(workspace) }
        let staging = workspace.appendingPathComponent("contents")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var snapshots: [URL] = []
        for (index, part) in parts.enumerated() {
            let snapshot = workspace.appendingPathComponent("part-\(index)")
            try await Images.detached { try FileSafety.snapshot(part, to: snapshot, reserve: reservedBytes) }
            snapshots.append(snapshot)
        }
        let start = Date()
        let watch: @Sendable () -> String? = {
            if Date().timeIntervalSince(start) > 600 { return L("Archive processing took too long and was stopped.") }
            if freeSpace(folder) < reservedBytes { return L("Stopped: extracting would fill the disk.") }
            return extractionBudgetError(staging)
        }
        do {
            if parts.count > 1 {
                // A multi-part RAR reads as one stream; the first part alone would extract zero-filled files.
                try await Shell.run("/usr/bin/tar", ["-xf", "-", "--no-mac-metadata", "--passphrase", noPassphrase, "-C", staging.path],
                                    input: snapshots, watch: watch)
            } else if url.pathExtension.lowercased() == "zip" {
                try await verify(snapshots[0], watch: watch)
                try await Shell.run("/usr/bin/ditto", ["-x", "-k", snapshots[0].path, staging.path], watch: watch)
            } else {
                // No AppleDouble metadata from the archive: it could replace the quarantine flag or lock its xattrs.
                try await Shell.run("/usr/bin/tar", ["-xf", snapshots[0].path, "--no-mac-metadata", "--passphrase", noPassphrase,
                                                     "-C", staging.path], watch: watch)
            }
        } catch {
            let message = error.localizedDescription
            if message.contains("passphrase") || message.contains("encrypt") || message.contains("Encrypt") {
                throw ToolError(L("This archive is password-protected. Swivel can't open encrypted archives yet."))
            }
            throw error
        }

        // Folders without owner access (mode 000, 300…) could neither be checked, flagged, moved nor cleaned up.
        makeAccessible(staging)
        let contents = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" }
        try validateExtractedTree(staging, allowMacMetadata: url.pathExtension.lowercased() == "zip")
        for snapshot in snapshots { try quarantine(contents, like: snapshot) }
        // Everything lands next to the archive, without an extra wrapping folder.
        var outputs: [URL] = []
        do {
            for item in contents {
                try Task.checkCancellation()
                var info = stat()
                guard lstat(item.path, &info) == 0 else { throw POSIXError(.EIO) }
                if info.st_mode & S_IFMT != S_IFLNK {
                    try FileSafety.makePrivate(item, directory: info.st_mode & S_IFMT == S_IFDIR, preserveExecutable: true)
                }
                outputs.append(try Paths.publish(item, as: parent.appendingPathComponent(item.lastPathComponent)))
            }
        } catch { throw PartialOutputError.wrapping(error, files: outputs) }
        return outputs
    }

    static func validateExtractedTree(_ root: URL, allowMacMetadata: Bool) throws {
        var queue = [root], count = 0, bytes: Int64 = 0
        while let item = queue.popLast() {
            try Task.checkCancellation()
            count += 1
            guard count <= 100_000 else { throw ToolError(L("This archive contains too many items.")) }
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw POSIXError(.EIO) }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: queue += try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            case S_IFREG:
                bytes += max(0, info.st_size)
                guard bytes <= 100_000_000_000 else { throw ToolError(L("The expanded archive exceeds the safety limit.")) }
                if !allowMacMetadata, item.lastPathComponent.hasPrefix("._") {
                    let handle = try FileHandle(forReadingFrom: item)
                    defer { try? handle.close() }
                    if try handle.read(upToCount: 4) == Data([0, 5, 22, 7]) {
                        throw ToolError(L("This archive contains Mac metadata that this extractor cannot restore. Use Archive Utility to preserve it."))
                    }
                }
            case S_IFLNK:
                // A link that leaves the extracted files (an absolute target, or ".." past the top) could later be read
                // through, for example copying "cute.png" pointing at a private key.
                guard linkStaysInside(item, root: root) else {
                    throw ToolError(L("This archive contains a link to a place outside it."))
                }
            default: throw ToolError(L("This archive contains an unsupported special file."))
            }
        }
    }

    /// Follows `link` on disk one component at a time, through any further links, and says whether it stays inside
    /// the top-level item it belongs to. Each top-level item is published on its own beside the archive, next to the
    /// user's files (and may be renamed "A 2"), so a link that reaches the top or another item would then point at
    /// the user's own files: "cute.png" -> "id_rsa". Top-level links and absolute targets are refused. Reading the
    /// target as text isn't enough: "up/../x" cancels "up" even when "up" is itself a link to "..".
    static func linkStaysInside(_ link: URL, root: URL) -> Bool {
        func real(_ url: URL) -> [String]? {
            guard let path = realpath(url.path, nil) else { return nil }
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path)).pathComponents
        }
        guard let top = real(root), var current = real(link.deletingLastPathComponent()),
              current.starts(with: top), current.count > top.count else { return false }
        guard let first = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return false }
        var pending = Array(first.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
        guard !first.hasPrefix("/") else { return false }
        var hops = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                // Never back up to the top, not even to come back in: "../A/x" from inside "A" would read the user's
                // own "A" once this one is published as "A 2".
                guard current.count > top.count + 1 else { return false }
                current.removeLast()
                continue
            }
            let next = current + [part]
            var info = stat()
            if lstat(NSString.path(withComponents: next), &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                hops += 1
                guard hops <= 40, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: NSString.path(withComponents: next)),
                      !target.hasPrefix("/") else { return false }
                pending = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init) + pending
            } else {
                current = next  // A folder, a file or nothing yet: none of them redirect.
            }
        }
        return true
    }

    private static func extractionBudgetError(_ root: URL) -> String? {
        var queue = [root], count = 0, bytes: Int64 = 0
        while let item = queue.popLast() {
            count += 1
            if count > 100_000 { return L("This archive contains too many items.") }
            var info = stat()
            guard lstat(item.path, &info) == 0 else { continue } // writer may be replacing its own staging entries
            if info.st_mode & S_IFMT == S_IFDIR {
                queue += (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
            } else if info.st_mode & S_IFMT == S_IFREG {
                bytes += max(0, info.st_size)
                if bytes > 100_000_000_000 { return L("The expanded archive exceeds the safety limit.") }
            }
        }
        return nil
    }

    /// A made-up passphrase: without one, bsdtar asks for it about ten thousand times on stderr.
    private static let noPassphrase = "swivel-no-passphrase"

    /// Asked fresh every time (a URL's resource values are cached, so they would never change during an extract).
    private static func freeSpace(_ folder: String) -> Int64 {
        var info = statfs()
        guard statfs(folder, &info) == 0 else { return 0 }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// Gives the owner full access to every folder under `root` (never following links), so it can be walked.
    static func makeAccessible(_ root: URL) {
        var queue = [root.path]
        while let path = queue.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            if info.st_mode & 0o700 != 0o700 { chmod(path, (info.st_mode & 0o7777) | 0o700) }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                queue.append((path as NSString).appendingPathComponent(name))
            }
        }
    }

    /// The parts of a multi-part RAR in order (name.part1.rar, name.part2.rar… or name.rar, name.r00, name.r01…),
    /// whichever part was dropped; otherwise just the file.
    static func volumes(of url: URL) throws -> [URL] {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent(), name = url.lastPathComponent
        let lower = name.lowercased()
        if let match = lower.firstMatch(of: #/^(.*)\.part(\d+)\.rar$/#) {
            let stem = String(name.prefix(match.1.count)), width = match.2.count
            var parts: [URL] = []
            for n in 1... {
                let part = dir.appendingPathComponent("\(stem).part\(String(format: "%0\(width)d", n)).rar")
                guard fm.fileExists(atPath: part.path) else { break }
                guard isRegularFile(part) else { throw ToolError("Can't read \(part.lastPathComponent)") }
                parts.append(part)
            }
            let highest = (try? fm.contentsOfDirectory(atPath: dir.path))?.compactMap { file -> Int? in
                guard let m = file.lowercased().firstMatch(of: #/^(.*)\.part(\d+)\.rar$/#), m.1 == match.1 else { return nil }
                return Int(m.2)
            }.max() ?? parts.count
            guard parts.count == highest, !parts.isEmpty else {
                throw ToolError(L("Part %d of this archive is missing.", parts.count + 1))
            }
            return parts
        }
        let isOldStyle = lower.hasSuffix(".rar") || lower.firstMatch(of: #/\.r\d\d$/#) != nil
        guard isOldStyle else { return [url] }
        let stem = String(name.dropLast(4))
        let first = dir.appendingPathComponent(stem + ".rar")
        var parts = [first]
        for n in 0..<1000 {
            let part = dir.appendingPathComponent(stem + String(format: ".r%02d", n))
            guard fm.fileExists(atPath: part.path) else { break }
            guard isRegularFile(part) else { throw ToolError("Can't read \(part.lastPathComponent)") }
            parts.append(part)
        }
        guard fm.fileExists(atPath: first.path) else { throw ToolError(L("Part %d of this archive is missing.", 1)) }
        guard isRegularFile(first) else { throw ToolError("Can't read \(first.lastPathComponent)") }
        return parts
    }

    /// Extracted files keep the archive's "downloaded from the internet" flag, as Archive Utility does, so Gatekeeper
    /// still checks an app inside a downloaded archive. Fails closed: nothing is moved out unless every item got it.
    static func quarantine(_ items: [URL], like archive: URL) throws {
        let name = "com.apple.quarantine"
        let size = getxattr(archive.path, name, nil, 0, 0, 0)
        if size < 0, errno != ENOATTR && errno != ENOTSUP { throw ToolError(L("Couldn't mark the extracted files as downloaded.")) }
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(archive.path, name, &value, size, 0, 0) == size else { throw ToolError(L("Couldn't mark the extracted files as downloaded.")) }
        let failed = ToolError(L("Couldn't mark the extracted files as downloaded."))
        var paths: [String] = [], walkFailed = false
        for item in items {
            paths.append(item.path)
            // Only folders are walked: enumerating a plain file reports "Not a directory", which isn't a failure.
            var info = stat()
            guard lstat(item.path, &info) == 0 else { throw failed }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            let walk = FileManager.default.enumerator(at: item, includingPropertiesForKeys: nil, options: []) { _, _ in
                walkFailed = true
                return false
            }
            while let child = walk?.nextObject() as? URL { paths.append(child.path) }
        }
        guard !walkFailed else { throw failed }
        for path in paths {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw failed }
            if info.st_mode & S_IFMT == S_IFLNK { continue }
            if setxattr(path, name, value, size, 0, XATTR_NOFOLLOW) == 0 { continue }
            // Read-only items (0444 files, 0555 folders) need the owner's write bit for a moment.
            let mode = info.st_mode & 0o7777
            guard chmod(path, mode | 0o200) == 0 else { throw failed }
            let set = setxattr(path, name, value, size, 0, XATTR_NOFOLLOW)
            chmod(path, mode)
            guard set == 0 else { throw failed }
        }
    }
}
