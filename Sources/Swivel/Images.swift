import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ImageFormat {
    let name: String
    let type: UTType
    let ext: String
    var extensions: [String] { type.tags[.filenameExtension] ?? [ext] }
}

enum Images {
    static let outputFormats: [ImageFormat] = {
        let writable = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
        var list = [
            ImageFormat(name: "JPG", type: .jpeg, ext: "jpg"),
            ImageFormat(name: "PNG", type: .png, ext: "png"),
            ImageFormat(name: "HEIC", type: .heic, ext: "heic"),
            ImageFormat(name: "WEBP", type: .webP, ext: "webp"),
            ImageFormat(name: "TIFF", type: .tiff, ext: "tiff"),
            ImageFormat(name: "AVIF", type: UTType("public.avif") ?? .image, ext: "avif"),
            ImageFormat(name: "GIF", type: .gif, ext: "gif"),
            ImageFormat(name: "BMP", type: .bmp, ext: "bmp"),
        ]
        list.removeAll { !writable.contains($0.type.identifier) }
        return list
    }()

    static let toolItems: [FileOption] = [
        FileOption(title: "Resize 50%") { url in
            try await detached { try transform(url, suffix: " small", scale: 0.5) }
        },
        FileOption(title: "Rotate") { url in
            try await detached { try transform(url, suffix: " rotated") { $0.rotatedRight() } }
        },
        FileOption(title: "Flip") { url in
            try await detached { try transform(url, suffix: " flipped") { $0.flippedHorizontally() } }
        },
        FileOption(title: "Grayscale") { url in
            try await detached { try transform(url, suffix: " gray") { $0.grayscale() } }
        },
    ]

    static func convert(_ url: URL, to format: ImageFormat) async throws -> [URL] {
        try await detached {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ToolError(L("Couldn't decode image")) }
            try requireComplete(source)
            let count = CGImageSourceGetCount(source)
            let pages = CGImageSourceGetType(source) as String? == UTType.tiff.identifier
            guard count > 0, count <= 1000, count == 1 || pages else {
                throw ToolError(L("This image contains animation or multiple images. This operation cannot preserve them."))
            }
            var outputs: [URL] = []
            do {
                for index in 0..<count {
                    try Task.checkCancellation()
                    let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
                    try validatePrecision(source, index: index, target: format.type)
                    let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0, height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                    guard width > 0, height > 0, Double(width) * Double(height) <= maxDecodePixels else { throw ToolError(L("Image too large")) }
                    let preferred = Paths.preferred(for: url, ext: format.ext, suffix: count > 1 ? " \(index + 1)" : "")
                    outputs.append(try Paths.produce(preferred) { out in
                        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, format.type.identifier as CFString, 1, nil) else {
                            throw ToolError(L("Couldn't encode image"))
                        }
                        // ImageIO preserves source pixels, orientation, colour profile and supported metadata.
                        // Avoid the 8-bit thumbnail path used for interactive previews.
                        var properties = props
                        properties[kCGImageDestinationLossyCompressionQuality] = 1.0
                        if [.jpeg, .bmp].contains(format.type), props[kCGImagePropertyHasAlpha] as? Bool == true {
                            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw ToolError(L("Couldn't decode image")) }
                            CGImageDestinationAddImage(dest, image.flattened(), properties as CFDictionary)
                        } else { CGImageDestinationAddImageFromSource(dest, source, index, properties as CFDictionary) }
                        guard CGImageDestinationFinalize(dest), let check = CGImageSourceCreateWithURL(out as CFURL, nil),
                              CGImageSourceGetCount(check) == 1, CGImageSourceGetStatus(check) == .statusComplete else {
                            throw ToolError(L("Couldn't encode image"))
                        }
                        let result = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any] ?? [:]
                        guard result[kCGImagePropertyPixelWidth] as? Int == width,
                              result[kCGImagePropertyPixelHeight] as? Int == height,
                              props[kCGImagePropertyIsFloat] as? Bool != true || result[kCGImagePropertyIsFloat] as? Bool == true,
                              (result[kCGImagePropertyDepth] as? Int ?? 8) >= min(8, props[kCGImagePropertyDepth] as? Int ?? 8),
                              (props[kCGImagePropertyDepth] as? Int ?? 8) <= 8 || (result[kCGImagePropertyDepth] as? Int ?? 8) >= (props[kCGImagePropertyDepth] as? Int ?? 8) else {
                            throw ToolError(L("This conversion could not preserve the image dimensions or bit depth."))
                        }
                    })
                }
            } catch { throw PartialOutputError.wrapping(error, files: outputs) }
            return outputs
        }
    }

    static func validatePrecision(_ source: CGImageSource, index: Int = 0, target: UTType? = nil) throws {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let auxiliary = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeDepth,
                         kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte]
        guard !auxiliary.contains(where: { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, $0) != nil }) else {
            throw ToolError(L("This image contains HDR or auxiliary data that this operation cannot preserve."))
        }
        if (props[kCGImagePropertyDepth] as? Int ?? 8) > 8, target != .png && target != .tiff {
            throw ToolError(L("This image has more than 8 bits per channel. Convert to PNG or TIFF to preserve its precision."))
        }
        if props[kCGImagePropertyIsFloat] as? Bool == true, target != .tiff {
            throw ToolError(L("This floating-point image requires TIFF to preserve its precision."))
        }
    }

    static func requireSingleImage(_ source: CGImageSource) throws {
        try requireComplete(source)
        guard CGImageSourceGetCount(source) == 1 else {
            throw ToolError(L("This image contains animation or multiple images. This operation cannot preserve them."))
        }
    }

    static func requireComplete(_ source: CGImageSource) throws {
        guard CGImageSourceGetStatus(source) == .statusComplete else { throw ToolError(L("The image is incomplete or damaged.")) }
    }

    // MARK: Resize

    enum ResizeMode: String, CaseIterable {
        case longEdge, width, height, percent

        var title: String {
            switch self {
            case .longEdge: L("Long edge")
            case .width: L("Width")
            case .height: L("Height")
            case .percent: L("Percent")
            }
        }

        /// The sizes offered in the field's list; the first is the default.
        var suggestions: [Int] {
            self == .percent ? [50, 75, 33, 25, 200] : [1920, 3840, 2560, 2048, 1600, 1280, 1080, 800, 640, 512]
        }

        /// Pixels need at least one; nothing above 20,000 px (or 1,000 %) is sensible.
        var range: ClosedRange<Int> { self == .percent ? 1...1000 : 1...20_000 }
    }

    /// The new size, keeping the aspect ratio, or nil when it would leave the image unchanged (or enlarge it while
    /// `enlarge` is off). Pure, so it can be tested.
    static func resizedSize(width: Int, height: Int, mode: ResizeMode, value: Int, enlarge: Bool) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, mode.range.contains(value) else { return nil }
        let w = Double(width), h = Double(height), v = Double(value)
        let scale: Double = switch mode {
        case .longEdge: v / max(w, h)
        case .width: v / w
        case .height: v / h
        case .percent: v / 100
        }
        guard enlarge || scale < 1 else { return nil }
        // The side that was asked for is exact; the other follows.
        var out = (width: max(1, Int((w * scale).rounded())), height: max(1, Int((h * scale).rounded())))
        switch mode {
        case .width: out.width = value
        case .height: out.height = value
        case .longEdge: if width >= height { out.width = value } else { out.height = value }
        case .percent: break
        }
        return out == (width, height) ? nil : out
    }

    /// Asks once for a size, then resizes every image to it beside the original ("photo 1920×1280.jpg").
    @MainActor
    static func resize(_ urls: [URL]) async throws -> ActionResult {
        let form = ResizeForm(urls: urls)
        NSApp.activate()
        guard form.run() else { throw Cancelled() }
        let (mode, value, enlarge) = (form.mode, form.value, form.enlarge)
        Prefs.resizeMode = mode.rawValue
        Prefs.resizeValue = value
        Prefs.resizeEnlarge = enlarge
        var files: [URL] = [], unchanged = 0
        do { for url in urls {
            if let file = try await detached({ try resizeFile(url, mode: mode, value: value, enlarge: enlarge) }) {
                files.append(file)
            } else {
                unchanged += 1
            }
        } } catch { throw PartialOutputError.wrapping(error, files: files) }
        if files.isEmpty { throw ToolError(L("Already at or below that size.")) }
        var result = Catalog.saved(files)
        if unchanged > 0 { result.message += "\n" + L("%d already at or below that size", unchanged) }
        return result
    }

    static func resizeFile(_ url: URL, mode: ResizeMode, value: Int, enlarge: Bool) throws -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ToolError("Couldn't read \(url.lastPathComponent)") }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = props[kCGImagePropertyPixelWidth] as? Int ?? 0, height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Orientations 5–8 are turned a quarter: the upright picture is the other way round.
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        guard let size = resizedSize(width: width, height: height, mode: mode, value: value, enlarge: enlarge) else { return nil }
        // Only the asked-for side is bounded by the form; the other follows the aspect ratio. An enlargement past
        // this would need gigabytes of memory.
        guard size.width <= 20_000, size.height <= 20_000, Double(size.width) * Double(size.height) <= 120_000_000 else {
            throw ToolError(L("That size is too large. Use at most 20,000 px per side and 120 megapixels."))
        }
        // Shrinking decodes straight at the new size (ImageIO's resampling, and no full-size decode); growing, or
        // a size ImageIO rounded the other way, is drawn exactly.
        var image = try load(url, maxPixels: size.width > width || size.height > height ? nil : max(size.width, size.height))
        if image.width != size.width || image.height != size.height { image = image.scaled(width: size.width, height: size.height) }
        // `scaled` hands back the original when drawing fails; never save that under the new size's name.
        guard image.width == size.width, image.height == size.height else { throw ToolError(L("Couldn't render")) }
        let (type, ext) = writableType(for: url)
        return try save(image, as: Paths.preferred(for: url, ext: ext, suffix: " \(size.width)×\(size.height)"), type: type, quality: 0.92)
    }

    static func makePDF(_ urls: [URL]) async throws -> [URL] {
        let doc = PDFDocument()
        for url in urls {
            try refuseFlood(url)  // NSImage decodes at full size, like `load`
            guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
                throw ToolError("Couldn't read \(url.lastPathComponent)")
            }
            doc.insert(page, at: doc.pageCount)
        }
        return [try PDFs.save(doc, as: Paths.preferred(for: urls[0], ext: "pdf"))]
    }

    // MARK: Helpers

    static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try work() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Leave room for decoder, colour conversion and editing copies, especially on machines with little RAM.
    static let maxDecodePixels = min(120_000_000.0, Double(ProcessInfo.processInfo.physicalMemory) / 64)

    /// Throws for a "pixel flood" file whose full-size decode would claim many gigabytes.
    static func refuseFlood(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ToolError("Couldn't read \(url.lastPathComponent)") }
        try requireSingleImage(source)
        try validatePrecision(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 4096
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 4096
        if Double(width) * Double(height) > maxDecodePixels {
            throw ToolError("\(url.lastPathComponent) is too large to open (\(width) × \(height) px)")
        }
    }

    /// Decodes the image upright (EXIF orientation applied), optionally capped in size.
    static func load(_ url: URL, maxPixels: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ToolError("Couldn't read \(url.lastPathComponent)")
        }
        try requireSingleImage(source)
        try validatePrecision(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 4096
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 4096
        // A full-size decode of a crafted "pixel flood" file would claim many gigabytes.
        if maxPixels == nil, Double(width) * Double(height) > maxDecodePixels {
            throw ToolError("\(url.lastPathComponent) is too large to open (\(width) × \(height) px)")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels ?? max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ToolError("Couldn't decode \(url.lastPathComponent)")
        }
        return image
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double) throws -> Data {
        var image = image
        if [UTType.jpeg, .bmp].contains(type), image.hasAlpha { image = image.flattened() }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ToolError("Can't write \(type.preferredFilenameExtension ?? "this format")")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("Couldn't encode image") }
        return data as Data
    }

    /// Highest fitting quality at each resolution; never returns an oversized result.
    static func fitting(_ image: CGImage, type: UTType, maxBytes: Int) throws
        -> (data: Data, quality: Double, longEdge: Int) {
        let originalEdge = max(image.width, image.height)
        let floor = min(320, originalEdge)
        let lossy = type == .jpeg || type == .heic
        var edge = originalEdge
        var smallest = Int.max
        while true {
            try Task.checkCancellation()
            let scaled = edge == originalEdge ? image : try resized(image, longEdge: edge)
            if lossy {
                let lowData = try encode(scaled, type: type, quality: 0.05)
                smallest = min(smallest, lowData.count)
                if lowData.count <= maxBytes {
                    let highData = try encode(scaled, type: type, quality: 0.95)
                    if highData.count <= maxBytes { return (highData, 0.95, edge) }
                    var low = 0.05, high = 0.95, best = lowData
                    for _ in 0..<7 {
                        try Task.checkCancellation()
                        let mid = (low + high) / 2
                        let data = try encode(scaled, type: type, quality: mid)
                        if data.count <= maxBytes { low = mid; best = data } else { high = mid }
                    }
                    return (best, low, edge)
                }
            } else {
                let data = try encode(scaled, type: type, quality: 1)
                smallest = min(smallest, data.count)
                if data.count <= maxBytes { return (data, 1, edge) }
            }
            if edge == floor { break }
            edge = max(floor, Int(Double(edge) * 0.85))
        }
        throw ToolError(L("Target size cannot be reached. Smallest size: %@.", byteString(smallest)))
    }

    static func resized(_ image: CGImage, longEdge: Int) throws -> CGImage {
        let scale = Double(longEdge) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError(L("Couldn't encode image"))
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ToolError(L("Couldn't encode image")) }
        return result
    }

    /// Encodes `image` and saves it as a new file at `preferred` or the next free name; returns where it went.
    /// (ImageIO writing to a URL would replace a file another conversion saved there after the name was chosen.)
    static func save(_ image: CGImage, as preferred: URL, type: UTType, quality: Double) throws -> URL {
        try Paths.create(try encode(image, type: type, quality: quality), at: preferred)
    }

    private static func sourceType(_ url: URL) -> UTType {
        UTType(filenameExtension: url.pathExtension) ?? .png
    }

    /// The source's own format if ImageIO can write it, else PNG.
    static func writableType(for url: URL) -> (UTType, String) {
        let type = sourceType(url)
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(type.identifier) ? (type, url.pathExtension) : (.png, "png")
    }

    private static func transform(_ url: URL, suffix: String, scale: CGFloat = 1,
                                  _ change: (CGImage) throws -> CGImage = { $0 }) throws -> [URL] {
        var maxPixels: Int?
        if scale != 1 {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else {
                throw ToolError(L("Couldn't decode image"))
            }
            maxPixels = max(1, Int(CGFloat(max(width, height)) * scale))
        }
        let image = try change(try load(url, maxPixels: maxPixels))
        let (type, ext) = writableType(for: url)
        return [try save(image, as: Paths.preferred(for: url, ext: ext, suffix: suffix), type: type, quality: 0.9)]
    }

    private static func compress(_ url: URL) throws -> [URL] {
        let image = try load(url)
        let lossy: Set<String> = ["jpg", "jpeg", "heic", "heif", "webp", "avif"]
        let ext = url.pathExtension.lowercased()
        let (type, outExt): (UTType, String)
        if lossy.contains(ext), Images.outputFormats.contains(where: { $0.extensions.contains(ext) }) {
            (type, outExt) = (sourceType(url), url.pathExtension)
        } else if image.hasAlpha {
            (type, outExt) = (.heic, "heic")
        } else {
            (type, outExt) = (.jpeg, "jpg")
        }
        return [try save(image, as: Paths.preferred(for: url, ext: outExt, suffix: " compressed"), type: type, quality: 0.6)]
    }

    private static func stripMetadata(_ url: URL) throws -> [URL] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else {
            throw ToolError("Couldn't read \(url.lastPathComponent)")
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw ToolError("Can't write this format")
        }
        let removed: [CFString: Any] = [
            kCGImagePropertyExifDictionary: kCFNull!,
            kCGImagePropertyGPSDictionary: kCFNull!,
            kCGImagePropertyIPTCDictionary: kCFNull!,
            kCGImagePropertyTIFFDictionary: kCFNull!,
            kCGImagePropertyMakerAppleDictionary: kCFNull!,
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ]
        CGImageDestinationAddImageFromSource(dest, source, 0, removed as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("Couldn't save") }
        return [try Paths.create(data as Data, at: Paths.preferred(for: url, ext: url.pathExtension, suffix: " clean"))]
    }
}

extension CGImage {
    var hasAlpha: Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(alphaInfo)
    }

    private func redraw(width: Int, height: Int, space: CGColorSpace? = nil, background: CGColor? = nil,
                        bitmapInfo: UInt32? = nil, _ draw: (CGContext) -> Void) -> CGImage {
        let space = space ?? (colorSpace?.model == .rgb ? colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = bitmapInfo ?? CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return self }
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage() ?? self
    }

    /// Exactly `width` × `height`, in the image's own colour space when it's RGB.
    func scaled(width: Int, height: Int) -> CGImage {
        redraw(width: width, height: height, space: colorSpace?.model == .rgb ? colorSpace : nil) {
            $0.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func flattened() -> CGImage {
        redraw(width: width, height: height, background: CGColor(gray: 1, alpha: 1)) {
            $0.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func rotatedRight() -> CGImage {
        redraw(width: height, height: width) { ctx in
            ctx.translateBy(x: 0, y: CGFloat(width))
            ctx.rotate(by: -.pi / 2)
            ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func flippedHorizontally() -> CGImage {
        redraw(width: width, height: height) { ctx in
            ctx.translateBy(x: CGFloat(width), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func grayscale() -> CGImage {
        redraw(width: width, height: height, space: CGColorSpaceCreateDeviceGray(),
               background: CGColor(gray: 1, alpha: 1), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            $0.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}

/// The question Resize… asks: how to measure (long edge, width, height or percent), how big, and whether smaller
/// images may grow. It opens on the last answer, so a repeated resize is one Return.
@MainActor
final class ResizeForm: NSObject, NSComboBoxDelegate {
    private let alert = NSAlert()
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let field = NSComboBox()
    private let unit = NSTextField(labelWithString: "")
    private let enlargeBox: NSButton
    private let modes = Images.ResizeMode.allCases
    private var resizeButton: NSButton!

    init(urls: [URL]) {
        enlargeBox = NSButton(checkboxWithTitle: L("Enlarge smaller images"), target: nil, action: nil)
        super.init()
        alert.messageText = urls.count == 1 ? L("Resize Image") : L("Resize %d Images", urls.count)
        if urls.count == 1, let size = Self.pixelSize(urls[0]) {
            alert.informativeText = L("Now %d × %d px.", size.width, size.height)
        } else {
            alert.informativeText = L("The aspect ratio is kept. Originals stay as they are.")
        }
        modePopup.addItems(withTitles: modes.map(\.title))
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        let mode = Images.ResizeMode(rawValue: Prefs.resizeMode) ?? .longEdge
        modePopup.selectItem(at: modes.firstIndex(of: mode) ?? 0)
        field.usesDataSource = false
        field.completes = false
        field.numberOfVisibleItems = 10
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        field.alignment = .right
        unit.textColor = .secondaryLabelColor
        enlargeBox.state = Prefs.resizeEnlarge ? .on : .off
        let row = NSStackView(views: [modePopup, field, unit])
        row.spacing = 8
        let stack = NSStackView(views: [row, enlargeBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        resizeButton = alert.addButton(withTitle: L("Resize"))
        alert.addButton(withTitle: L("Cancel"))
        fill(mode, value: mode.range.contains(Prefs.resizeValue) ? Prefs.resizeValue : mode.suggestions[0])
    }

    var mode: Images.ResizeMode { modes[max(0, modePopup.indexOfSelectedItem)] }
    var value: Int { Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0 }
    var enlarge: Bool { enlargeBox.state == .on }

    func run() -> Bool {
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn && mode.range.contains(value)
    }

    private func fill(_ mode: Images.ResizeMode, value: Int) {
        field.removeAllItems()
        field.addItems(withObjectValues: mode.suggestions.map { "\($0)" })
        field.stringValue = "\(value)"
        unit.stringValue = mode == .percent ? "%" : L("px")
        validate()
    }

    @objc private func modeChanged() {
        fill(mode, value: mode.suggestions[0])
        field.selectText(nil)
    }

    private func validate() { resizeButton.isEnabled = mode.range.contains(value) }

    func controlTextDidChange(_ obj: Notification) { validate() }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The picked item reaches stringValue only after this returns.
        DispatchQueue.main.async { [weak self] in self?.validate() }
    }

    private static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = props[kCGImagePropertyPixelWidth] as? Int, var height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        return (width, height)
    }
}
