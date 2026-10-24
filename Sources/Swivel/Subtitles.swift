import AppKit
import AVFoundation
import CoreImage
import CoreText
import Darwin
import Speech

struct TimedWord: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}
struct SubtitleCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

enum Subtitles {
    static func timestamp(_ seconds: Double) -> String {
        let ms = Int64((min(359999.999, max(0, seconds.isFinite ? seconds : 0)) * 1000).rounded())
        return String(format: "%02lld:%02lld:%02lld,%03lld", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }
    static func wrap(_ text: String, limit: Int = 42) -> String {
        var lines: [String] = [], line = ""
        for char in text {
            if char == "\n" { lines.append(line); line = ""; continue }
            if line.count >= limit { lines.append(line); line = "" }
            if !line.isEmpty || !char.isWhitespace { line.append(char) }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
    static func cues(_ words: [TimedWord]) -> [SubtitleCue] {
        let words = words.filter { $0.start.isFinite && $0.end.isFinite && $0.end > max(0, $0.start) && !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
        var cues: [SubtitleCue] = [], start = 0.0, end = 0.0, text = ""
        func flush() {
            guard !text.isEmpty else { return }
            let previous = cues.last?.end ?? 0
            let a = max(previous, start)
            if end > a { cues.append(SubtitleCue(start: a, end: end, text: wrap(text.trimmingCharacters(in: .whitespacesAndNewlines)))) }
            text = ""
        }
        for word in words {
            // Long runs (including a CJK attributed run) are split by grapheme, with proportional timestamps.
            let chars = Array(word.text)
            let pieces = max(1, Int(ceil(max(Double(chars.count) / 42, (word.end - word.start) / 7))))
            for piece in 0..<pieces {
                let a = chars.count * piece / pieces, b = chars.count * (piece + 1) / pieces
                guard b > a else { continue }
                let first = word.start + (word.end - word.start) * Double(piece) / Double(pieces)
                let last = word.start + (word.end - word.start) * Double(piece + 1) / Double(pieces)
                if !text.isEmpty && (first - end > 0.6 || last - start > 7 || text.count + b - a > 84) { flush() }
                if text.isEmpty { start = max(0, first) }
                let fragment = String(chars[a..<b])
                if let previous = text.last, let first = fragment.first,
                   previous.isASCII, previous.isLetter || previous.isNumber,
                   first.isASCII, first.isLetter || first.isNumber { text += " " }
                text += fragment; end = last
                if let c = text.last, ".!?。！？".contains(c) { flush() }
            }
        }
        flush()
        return cues
    }
    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { "\($0.offset + 1)\n\(timestamp($0.element.start)) --> \(timestamp($0.element.end))\n\($0.element.text)\n" }.joined(separator: "\n")
    }
    static let maximumFileBytes = 2_000_000
    private static let maximumCueBytes = 16_384
    private static let maximumLines = 32
    private static let maximumBitmapPixels = 8_000_000

    /// Validate and read the same open file. A pathname check followed by String(contentsOf:) could measure a
    /// link rather than its target, or read a file which grew after the size check. O_NONBLOCK also prevents a
    /// special file from blocking before fstat can reject it.
    static func read(_ url: URL) throws -> [SubtitleCue] {
        guard url.isFileURL, !url.path.contains("\0") else {
            throw ToolError(L("Choose a regular subtitle file, not a link or special file."))
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ELOOP { throw ToolError(L("Choose a regular subtitle file, not a link or special file.")) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw ToolError(L("Choose a regular subtitle file, not a link or special file."))
        }
        guard info.st_size <= maximumFileBytes else { throw ToolError(L("This subtitle file is too large.")) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= maximumFileBytes {
            let wanted = min(buffer.count, maximumFileBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, wanted) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumFileBytes else { throw ToolError(L("This subtitle file is too large.")) }
        guard var text = String(data: data, encoding: .utf8) else {
            throw ToolError(L("This subtitle file is not valid UTF-8."))
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        func time(_ text: String) -> Double? {
            let values = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
            guard values.count == 3 else { return nil }
            let tail = values[2].split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
            func digits(_ value: Substring, count: Int) -> Bool {
                value.count == count && value.allSatisfy { $0.isASCII && $0.isNumber }
            }
            guard tail.count == 2, digits(values[0], count: 2), digits(values[1], count: 2),
                  digits(tail[0], count: 2), digits(tail[1], count: 3),
                  let h = Int(values[0]), let m = Int(values[1]), let sec = Int(tail[0]), let ms = Int(tail[1]),
                  m < 60, sec < 60 else { return nil }
            return Double(h * 3600 + m * 60 + sec) + Double(ms) / 1000
        }
        var blocks: [[String]] = [], block: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !block.isEmpty { blocks.append(block); block = [] }
            } else { block.append(line) }
        }
        if !block.isEmpty { blocks.append(block) }
        var output: [SubtitleCue] = []
        for lines in blocks {
            let index = lines[0].contains("-->") ? 0 : 1
            guard lines.count > index + 1,
                  index == 0 || Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil else {
                throw ToolError(L("This subtitle file is not valid SRT."))
            }
            let pair = lines[index].components(separatedBy: "-->")
            guard pair.count == 2, let a = time(pair[0]), let b = time(pair[1]), b > a else {
                throw ToolError(L("This subtitle file has invalid timing or overlapping cues."))
            }
            let content = lines.dropFirst(index + 1).joined(separator: "\n")
            _ = try boundedLines(content)
            output.append(SubtitleCue(start: a, end: b, text: content))
        }
        output.sort { $0.start < $1.start }
        for (first, next) in zip(output, output.dropFirst()) where next.start < first.end {
            throw ToolError(L("This subtitle file has invalid timing or overlapping cues."))
        }
        return output
    }

    private static func boundedLines(_ text: String) throws -> [String] {
        guard text.utf8.count <= maximumCueBytes else {
            throw ToolError(L("This subtitle is too long to display. Split it into shorter cues."))
        }
        let lines = wrap(text).components(separatedBy: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, lines.count <= maximumLines else {
            throw ToolError(L("This subtitle is too long to display. Split it into shorter cues."))
        }
        return lines
    }

    private struct Layout {
        var width: Int
        var height: Int
        var fontSize: Double
        var lines: [String]
    }
    private static func layout(_ text: String, size: CGSize) throws -> Layout {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 16_384, size.height <= 16_384 else {
            throw ToolError(L("These subtitles cannot fit legibly in the video. Use shorter cues or a larger video."))
        }
        let lines = try boundedLines(text)
        let width = Int(size.width), safeHeight = floor(size.height * 0.84)
        var fontSize = max(10, min(size.width * 0.034, size.height * 0.055))
        let measuringFont = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
        let widest = lines.map {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): measuringFont]))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }.max() ?? 0
        // Fit every line, including CJK glyphs, into the 5% horizontal / 8% vertical safe area. The size floor
        // scales down for small videos, while rejecting a genuinely unreadable wall of text explicitly at export.
        if widest > size.width * 0.9 { fontSize *= size.width * 0.9 / widest }
        fontSize = min(fontSize, safeHeight / (1.35 * Double(lines.count) + 1))
        let minimum = max(3, min(10, min(size.width, size.height) / 64))
        let height = Int(ceil(fontSize * (1.35 * Double(lines.count) + 1)))
        guard fontSize >= minimum, height > 0, height <= maximumBitmapPixels / width else {
            throw ToolError(L("These subtitles cannot fit legibly in the video. Use shorter cues or a larger video."))
        }
        return Layout(width: width, height: height, fontSize: fontSize, lines: lines)
    }

    /// Export calls this with final output dimensions so an unreadable subtitle fails clearly instead of vanishing.
    static func validate(_ cues: [SubtitleCue], size: CGSize) throws {
        for cue in cues { _ = try layout(cue.text, size: size) }
    }

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    static func overlay(_ cue: SubtitleCue, size: CGSize) -> CIImage? {
        overlayBitmap(cue, size: size).map { CIImage(cgImage: $0) }
    }
    /// The shared bitmap is also used for CPU-only verification; it does not require a working CI/GPU renderer.
    static func overlayBitmap(_ cue: SubtitleCue, size: CGSize) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite, cue.text.utf8.count <= maximumCueBytes else { return nil }
        let key = "\(size.width)x\(size.height):\(cue.text)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let layout = try? layout(cue.text, size: size) else { return nil }
        let w = layout.width, height = layout.height, fontSize = layout.fontSize
        guard let ctx = CGContext(data: nil, width: w, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)!
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
        let textLines = layout.lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs)) }
        let textWidth = textLines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0
        let plateWidth = min(Double(w), textWidth + fontSize * 1.2)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(CGPath(roundedRect: CGRect(x: (Double(w) - plateWidth) / 2, y: 0, width: plateWidth, height: Double(height)),
                          cornerWidth: fontSize * 0.25, cornerHeight: fontSize * 0.25, transform: nil))
        ctx.fillPath()
        for (index, line) in textLines.enumerated() {
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.textPosition = CGPoint(x: (Double(w) - width) / 2,
                                      y: Double(height) - fontSize * 1.2 - Double(index) * fontSize * 1.35)
            CTLineDraw(line, ctx)
        }
        guard let image = ctx.makeImage() else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

}

@available(macOS 26, *)
enum LocalTranscription {
    /// Export is started once; cancelExport is its sole concurrent operation, as supported by AVFoundation.
    private struct AudioExport: @unchecked Sendable { let session: AVAssetExportSession }
    static func recognize(_ source: URL, locale: Locale) async throws -> [TimedWord] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ToolError(L("This transcription language is not supported on this Mac."))
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        // A reservation makes already downloaded resources visible to this process. false means already reserved.
        _ = try await AssetInventory.reserve(locale: locale)
        // This service never downloads implicitly. Only the editor's explicit consent path can install resources.
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw ToolError(L("Language resources are not installed."))
        }
        let asset = try await Video.safeAsset(source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw ToolError(L("This file has no audio.")) }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ToolError(L("Couldn't encode audio."))
        }
        let work = AudioExport(session: export)
        let temporary = try await MediaTemporaryFiles.produce(ext: "m4a") { target in
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await work.session.export(to: target, as: .m4a)
                try Task.checkCancellation()
            } onCancel: { work.session.cancelExport() }
        }
        defer { MediaTemporaryFiles.discard(temporary) }
        let audio = try AVAudioFile(forReading: temporary)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let consumer = Task { () throws -> [TimedWord] in
            var words: [TimedWord] = []
            for try await result in transcriber.results where result.isFinal {
                for run in result.text.runs {
                    let range = run.audioTimeRange ?? result.range
                    words.append(TimedWord(text: String(result.text[run.range].characters), start: range.start.seconds, end: range.end.seconds))
                }
            }
            return words
        }
        return try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
                let words = try await consumer.value
                try Task.checkCancellation()
                return words
            } catch {
                await analyzer.cancelAndFinishNow(); consumer.cancel(); throw error
            }
        } onCancel: { consumer.cancel(); Task { await analyzer.cancelAndFinishNow() } }
    }
}

/// Speech resources for one language. A first download is asked for on the window and shows its progress; never silent.
@available(macOS 26, *)
enum SpeechResources {
    @MainActor static func prepare(_ requested: Locale, window: NSWindow,
                                   downloading: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw ToolError(L("This transcription language is not supported on this Mac."))
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        _ = try await AssetInventory.reserve(locale: locale)
        guard await AssetInventory.status(forModules: [module]) != .installed else { return locale }
        let alert = NSAlert()
        alert.messageText = L("Download language resources?")
        alert.informativeText = L("Apple needs to download this language once. Only system resources are downloaded; your audio stays on this Mac.")
        alert.addButton(withTitle: L("Download")); alert.addButton(withTitle: L("Cancel"))
        let answer = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard answer == .alertFirstButtonReturn else { throw Cancelled() }
        try Task.checkCancellation()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            downloading(0)
            let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                let value = p.fractionCompleted
                Task { @MainActor in downloading(value) }
            }
            defer { observation.invalidate() }
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: { request.progress.cancel() }
        }
        try Task.checkCancellation()
        return locale
    }
}

@available(macOS 26, *)
final class TranscriptionEditor: Editor {
    private let message = NSTextField(wrappingLabelWithString: L("Transcription stays on this Mac. Open Trim → Subtitles to embed the SRT in the video; it is picked up automatically."))
    private var language: NSPopUpButton!
    private var extraSRT: NSButton!
    private let progress = NSProgressIndicator()
    private var task: Task<[URL], Error>?
    private let isVideo: Bool

    init(source: URL, isVideo: Bool) {
        self.isVideo = isVideo
        let canvas = NSView()
        super.init(title: isVideo ? "Subtitles" : "Transcribe", source: source, canvas: canvas)
        message.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(message)
        NSLayoutConstraint.activate([message.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            message.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -24)])
        language = popup(Prefs.transcriptionLanguageTitles)
        language.selectItem(at: Prefs.transcriptionLanguages.firstIndex(of: Prefs.transcriptionLanguage) ?? 0)
        addRow("Transcription Language", language)
        extraSRT = checkbox("Also save SRT", false)
        if !isVideo { addRow("", extraSRT) }
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 240).isActive = true
        addRow("", progress)
    }
    static func run(_ sources: [URL], isVideo: Bool) async throws -> ActionResult {
        var outputs: [URL] = []
        for source in sources { outputs += try await TranscriptionEditor(source: source, isVideo: isVideo).present() }
        var result = Catalog.saved(outputs)
        if isVideo { result.message += "\n" + L("Open Trim → Subtitles to embed them in the video.") }
        return result
    }
    override var canCancelSaving: Bool { true }
    override func cancelSaving() { task?.cancel() }
    override func didClose() { task?.cancel() }
    override func apply() async throws -> [URL] {
        Prefs.transcriptionLanguage = Prefs.transcriptionLanguages[max(0, language.indexOfSelectedItem)]
        let source = self.source, isVideo = self.isVideo, extra = extraSRT.state == .on
        let task = Task { [self] () throws -> [URL] in
            let locale = try await SpeechResources.prepare(Prefs.transcriptionLocale, window: window) { [weak self] value in
                self?.message.stringValue = L("Downloading language resources…")
                self?.progress.doubleValue = value
            }
            try Task.checkCancellation()
            message.stringValue = L("Transcribing on this Mac…")
            progress.isIndeterminate = true; progress.startAnimation(nil)
            defer { progress.stopAnimation(nil); progress.isIndeterminate = false }
            let words = try await LocalTranscription.recognize(source, locale: locale)
            guard !words.isEmpty else { throw ToolError(L("No speech was found.")) }
            try Task.checkCancellation()
            var outputs: [URL] = []
            do {
                if !isVideo {
                    outputs.append(try Paths.create(Data(words.map(\.text).joined().utf8), at: Paths.preferred(for: source, ext: "txt")))
                }
                if isVideo || extra {
                    outputs.append(try Paths.create(Data(Subtitles.srt(Subtitles.cues(words)).utf8), at: Paths.preferred(for: source, ext: "srt")))
                }
                return outputs
            } catch {
                for output in outputs { try? FileManager.default.removeItem(at: output) }
                throw error
            }
        }
        self.task = task
        defer { self.task = nil }
        return try await task.value
    }
}
