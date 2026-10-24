import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

struct IDFace: Sendable {
    var bounds: CGRect
    var eyes: CGPoint
    var chin: Double
    var headTop: Double
}
struct IDPhotoSettings: Sendable {
    var width = 295, height = 413, dpi = 300
    var background = SIMD3<Double>(1, 1, 1)
    var zoom = 1.0
    var vertical = 0.0
}

enum IDPhoto {
    /// Bound all Vision masks and colour-propagation surfaces independently of the source file's dimensions.
    static let maxWorkingEdge = 4096
    static let presetNames = ["One inch (295 × 413)", "Two inch (413 × 579)", "Passport (33 × 48 mm)", "US Visa (600 × 600)", "Custom"]
    static func dimensions(preset: Int, width: Double, height: Double, millimeters: Bool, dpi: Int) throws -> (Int, Int) {
        guard (72...1200).contains(dpi), width.isFinite, height.isFinite else { throw ToolError(L("Choose a DPI from 72 to 1200 and valid dimensions.")) }
        let w: Double, h: Double
        switch preset {
        case 0: (w, h) = (295, 413)
        case 1: (w, h) = (413, 579)
        case 2: (w, h) = (33 / 25.4 * Double(dpi), 48 / 25.4 * Double(dpi))
        case 3: (w, h) = (600, 600)
        default:
            let scale = millimeters ? Double(dpi) / 25.4 : 1
            (w, h) = (width * scale, height * scale)
        }
        guard w >= 1, h >= 1, w <= 10000, h <= 10000, w * h <= 40_000_000 else {
            throw ToolError(L("Choose positive dimensions below 40 megapixels and 10000 pixels per side."))
        }
        let result = (Int(w.rounded()), Int(h.rounded()))
        guard result.0 * result.1 <= 40_000_000 else {
            throw ToolError(L("Choose positive dimensions below 40 megapixels and 10000 pixels per side."))
        }
        return result
    }

    static func workingEdge(settings: IDPhotoSettings) throws -> Int {
        _ = try dimensions(preset: 4, width: Double(settings.width), height: Double(settings.height), millimeters: false, dpi: settings.dpi)
        return min(maxWorkingEdge, max(1400, max(settings.width, settings.height) * 2))
    }
    private static func checkWorkingSize(_ image: CGImage) throws {
        guard image.width <= maxWorkingEdge, image.height <= maxWorkingEdge else {
            throw ToolError(L("ID Photo can process images up to 4096 pixels per side."))
        }
    }

    /// Source-pixel crop with the head at 70% height and eyes 45% down from the top. Out-of-photo portions are
    /// deliberately padded with the selected background, retaining the face proportions instead of stretching/clamping.
    static func crop(image: CGSize, output: CGSize, face: IDFace, zoom: Double = 1, vertical: Double = 0) -> CGRect? {
        let values = [image.width, image.height, output.width, output.height, face.eyes.x, face.eyes.y,
                      face.chin, face.headTop, zoom, vertical]
        guard values.allSatisfy(\.isFinite), image.width > 0, image.height > 0, output.width > 0, output.height > 0,
              face.headTop > face.chin, zoom > 0 else { return nil }
        let head = (face.headTop - face.chin) * image.height
        let scale = output.height * 0.7 / head * min(2, max(0.5, zoom))
        let width = output.width / scale, height = output.height / scale
        let x = face.eyes.x * image.width - width * 0.5
        let y = face.eyes.y * image.height - height * (0.55 + min(0.3, max(-0.3, vertical)))
        return CGRect(x: x, y: y, width: width, height: height)
    }
    static func singleFace(_ faces: [IDFace]) throws -> IDFace {
        guard !faces.isEmpty else { throw ToolError(L("No face found. Choose a clear portrait facing the camera.")) }
        guard faces.count == 1 else { throw ToolError(L("More than one face found. Choose a photo with just one person.")) }
        return faces[0]
    }
    static func detect(_ image: CGImage) throws -> (IDFace, CGImage) {
        try checkWorkingSize(image)
        try Task.checkCancellation()
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        try Task.checkCancellation()
        let observations = request.results ?? []
        guard observations.count == 1 else {
            if observations.isEmpty { throw ToolError(L("No face found. Choose a clear portrait facing the camera.")) }
            throw ToolError(L("More than one face found. Choose a photo with just one person."))
        }
        let observation = observations[0], bounds = observation.boundingBox
        guard let landmarks = observation.landmarks, let left = landmarks.leftEye?.normalizedPoints,
              let right = landmarks.rightEye?.normalizedPoints, let contour = landmarks.faceContour?.normalizedPoints,
              !left.isEmpty, !right.isEmpty, let chin = contour.map(\.y).min() else {
            throw ToolError(L("Couldn't locate the eyes and chin. Choose a clearer portrait."))
        }
        let eyes = left + right
        let eye = CGPoint(x: eyes.map(\.x).reduce(0, +) / Double(eyes.count), y: eyes.map(\.y).reduce(0, +) / Double(eyes.count))
        let face = IDFace(bounds: bounds, eyes: CGPoint(x: bounds.minX + eye.x * bounds.width, y: bounds.minY + eye.y * bounds.height),
                          chin: bounds.minY + chin * bounds.height, headTop: min(1, bounds.maxY + bounds.height * 0.1))
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([segmentation])
        try Task.checkCancellation()
        guard let buffer = segmentation.results?.first?.pixelBuffer else { throw ToolError(L("No subject found in this image.")) }
        let raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: Double(image.width) / raw.extent.width,
                                                           y: Double(image.height) / raw.extent.height))
        guard let mask = context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                               format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { throw ToolError(L("Couldn't render")) }
        try Task.checkCancellation()
        return (face, mask)
    }

    private static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let context = CIContext(options: [.workingColorSpace: workingSpace])
    private static let seed = CIColorKernel(source: """
        kernel vec4 interior(__sample photo, __sample mask) {
            float weight = smoothstep(0.8, 0.98, mask.r);
            // Kernel samples are premultiplied. Keep their original alpha in the normalized seed weights.
            return vec4(photo.rgb * weight, photo.a * weight);
        }
        """)
    private static let pullForeground = CIColorKernel(source: """
        kernel vec4 pullForeground(__sample seed, __sample coarse) {
            if (seed.a <= 0.0001) { return vec4(coarse.rgb, 1.0); }
            vec3 local = seed.rgb / seed.a;
            float trust = smoothstep(0.0001, 0.02, seed.a);
            return vec4(mix(coarse.rgb, local, trust), 1.0);
        }
        """)
    /// A bounded push/pull pyramid carries reliable foreground colours along thin, low-confidence hair.
    /// Its coarsest fallback contains foreground seeds only; old, already mixed background pixels never donate.
    private static func foregroundGuide(_ seeds: CIImage, extent: CGRect, radius: Double) throws -> CIImage {
        let average = seeds.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(average, toBitmap: bytes.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: workingSpace)
        }
        guard pixel.allSatisfy(\.isFinite), pixel[3] > 0.000000000001 else {
            throw ToolError(L("Couldn't find a reliable foreground. Choose a clearer portrait."))
        }
        guard let fallback = CIColor(red: Double(pixel[0] / pixel[3]), green: Double(pixel[1] / pixel[3]), blue: Double(pixel[2] / pixel[3]),
                                     alpha: 1, colorSpace: workingSpace), let pullForeground else {
            throw ToolError(L("Couldn't render"))
        }
        // Materialize the one-pixel reduction as a constant: leaving a reduction inside the later sampled-kernel
        // graph can make Core Image apply a local ROI and turn its distant fallback black.
        var filled = CIImage(color: fallback).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        var level = seeds.clampedToExtent().applyingGaussianBlur(sigma: radius * 3).cropped(to: extent)
        var levels = [level]
        while max(level.extent.width, level.extent.height) > 32 {
            try Task.checkCancellation()
            let smaller = CGRect(x: 0, y: 0, width: ceil(level.extent.width / 2), height: ceil(level.extent.height / 2))
            level = level.clampedToExtent().applyingGaussianBlur(sigma: 1)
                .transformed(by: CGAffineTransform(scaleX: smaller.width / level.extent.width, y: smaller.height / level.extent.height))
                .cropped(to: smaller)
            levels.append(level)
        }
        for level in levels.reversed() {
            try Task.checkCancellation()
            let coarse = filled.clampedToExtent().transformed(by: CGAffineTransform(scaleX: level.extent.width / filled.extent.width,
                                                                                    y: level.extent.height / filled.extent.height))
                .cropped(to: level.extent)
            guard let next = pullForeground.apply(extent: level.extent, arguments: [level, coarse]) else { throw ToolError(L("Couldn't render")) }
            filled = next
        }
        return filled
    }
    /// Normalized foreground colour propagation prevents the previous background contaminating soft hair edges.
    static func replaceBackground(_ image: CGImage, mask: CGImage, color: SIMD3<Double>) throws -> CIImage {
        try checkWorkingSize(image)
        try Task.checkCancellation()
        let photo = CIImage(cgImage: image), extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let raw = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
        let hard = raw.transformed(by: CGAffineTransform(scaleX: extent.width / raw.extent.width, y: extent.height / raw.extent.height)).cropped(to: extent)
        guard let seeds = seed?.apply(extent: extent, arguments: [photo, hard]) else { throw ToolError(L("Couldn't render")) }
        let radius = max(1, min(3, max(extent.width, extent.height) * 0.001))
        let propagated = try foregroundGuide(seeds, extent: extent, radius: radius)
        let feathered = hard.clampedToExtent().applyingGaussianBlur(sigma: radius * 0.5).cropped(to: extent)
        // Kernel colour inputs are linear working-space values, converted from the user's sRGB choice.
        let bg = CIImage(color: CIColor(red: color.x, green: color.y, blue: color.z)).cropped(to: extent)
        // Pass the background as a sampled image so Core Image performs the same colour management on both inputs.
        guard let result = sampledComposite?.apply(extent: extent, arguments: [photo, propagated, hard, feathered, bg]) else {
            throw ToolError(L("Couldn't render"))
        }
        return result
    }
    private static let sampledComposite = CIColorKernel(source: """
        kernel vec4 replaceBackground(__sample photo, __sample foregroundGuide, __sample hardMask, __sample softMask, __sample background) {
            vec3 foreground = foregroundGuide.rgb;
            if (hardMask.r > 0.98 && photo.a > 0.0001) { foreground = photo.rgb / photo.a; }
            float alpha = clamp(softMask.r, 0.0, 1.0) * photo.a;
            return vec4(foreground * alpha + background.rgb * (1.0 - alpha), 1.0);
        }
        """)
    static func render(_ image: CGImage, mask: CGImage, face: IDFace, settings: IDPhotoSettings) throws -> CGImage {
        try Task.checkCancellation()
        _ = try dimensions(preset: 4, width: Double(settings.width), height: Double(settings.height), millimeters: false, dpi: settings.dpi)
        guard let crop = crop(image: CGSize(width: image.width, height: image.height), output: CGSize(width: settings.width, height: settings.height),
                              face: face, zoom: settings.zoom, vertical: settings.vertical) else { throw ToolError(L("Couldn't render")) }
        let recolored = try replaceBackground(image, mask: mask, color: settings.background)
        let rect = CGRect(x: 0, y: 0, width: settings.width, height: settings.height)
        let picture = recolored.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: rect.width / crop.width, y: rect.height / crop.height))
        let background = CIImage(color: CIColor(red: settings.background.x, green: settings.background.y, blue: settings.background.z)).cropped(to: rect)
        guard let result = context.createCGImage(picture.composited(over: background).cropped(to: rect), from: rect,
                                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw ToolError(L("Couldn't render")) }
        try Task.checkCancellation()
        return result
    }
    static func save(_ image: CGImage, source: URL, dpi: Int) throws -> URL {
        try Task.checkCancellation()
        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw ToolError(L("Couldn't encode image")) }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFXDensity: dpi, kCGImagePropertyJFIFYDensity: dpi,
                                          kCGImagePropertyJFIFDensityUnit: 1]] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw ToolError(L("Couldn't encode image")) }
        try Task.checkCancellation()
        return try Paths.create(bytes as Data, at: Paths.preferred(for: source, ext: "jpg", suffix: " id"))
    }
}

final class IDPhotoEditor: Editor {
    private let preview = ImagePreview()
    private var small: CGImage?
    private var mask: CGImage?
    private var face: IDFace?
    private var preset: NSPopUpButton!
    private var width: NSTextField!, height: NSTextField!, dpi: NSTextField!
    private var units: NSPopUpButton!, background: NSPopUpButton!
    private let colorWell = NSColorWell(style: .minimal)
    private var zoom: DetentSlider!, vertical: DetentSlider!
    private let status = NSTextField(wrappingLabelWithString: "")
    private var saveTask: Task<[URL], Error>?
    private lazy var renderer = LiveRender<Result<CGImage, Error>> { [weak self] result in
        switch result {
        case .success(let image): self?.preview.image = image; self?.status.stringValue = ""
        case .failure(let error): self?.status.stringValue = error.localizedDescription
        }
    }
    init(source: URL) {
        super.init(title: "ID Photo", source: source, canvas: preview)
        window.setContentSize(NSSize(width: 620, height: 790))
        preset = popup(IDPhoto.presetNames)
        addRow("Size", preset)
        width = numberField(295); height = numberField(413)
        units = popup(["Pixels", "Millimeters"])
        addRow("Custom", width, NSTextField(labelWithString: "×"), height, units)
        dpi = numberField(300)
        addRow("DPI", dpi)
        background = popup(["White", "Blue", "Red", "Custom"])
        colorWell.color = .white; colorWell.target = self; colorWell.action = #selector(customColorChanged)
        addRow("Background", background, colorWell)
        zoom = slider(0.7, 1.5, 1); vertical = slider(-0.2, 0.2, 0)
        addRow("Zoom", zoom)
        addRow("Vertical Position", vertical)
        let disclaimer = NSTextField(wrappingLabelWithString: L("For convenience only. Follow the issuing authority's requirements for official use."))
        disclaimer.font = .systemFont(ofSize: 11); disclaimer.textColor = .secondaryLabelColor
        addRow("", disclaimer)
        status.textColor = .systemRed; status.font = .systemFont(ofSize: 11)
        addRow("", status)
    }
    private func settings() throws -> IDPhotoSettings {
        let (w, h) = try IDPhoto.dimensions(preset: preset.indexOfSelectedItem, width: width.doubleValue, height: height.doubleValue,
                                           millimeters: units.indexOfSelectedItem == 1, dpi: dpi.integerValue)
        let color: NSColor
        switch background.indexOfSelectedItem {
        case 0: color = .white
        case 1: color = NSColor(srgbRed: 67/255, green: 142/255, blue: 219/255, alpha: 1)
        case 2: color = NSColor(srgbRed: 217/255, green: 0, blue: 27/255, alpha: 1)
        default: color = colorWell.color.usingColorSpace(.sRGB) ?? .white
        }
        let rgb = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return IDPhotoSettings(width: w, height: h, dpi: dpi.integerValue,
                               background: SIMD3(rgb.redComponent, rgb.greenComponent, rgb.blueComponent),
                               zoom: zoom.doubleValue, vertical: vertical.doubleValue)
    }
    @objc private func customColorChanged() { background.selectItem(at: 3); update() }
    override func load() async throws {
        let source = self.source
        let data = try await Images.detached { () throws -> (CGImage, IDFace, CGImage) in
            let image = try Images.load(source, maxPixels: 1400)
            let (face, mask) = try IDPhoto.detect(image)
            return (image, face, mask)
        }
        small = data.0; face = data.1; mask = data.2
        preview.image = data.0
    }
    override func update() {
        let custom = preset.indexOfSelectedItem == 4
        for control in [width!, height!, units!] as [NSControl] { control.isEnabled = custom && !isSaving }
        guard let small, let mask, let face else { return }
        do {
            var settings = try settings()
            let scale = min(1, 1000 / Double(max(settings.width, settings.height)))
            settings.width = max(1, Int((Double(settings.width) * scale).rounded()))
            settings.height = max(1, Int((Double(settings.height) * scale).rounded()))
            renderer.cancel()
            renderer.request { [settings] in Result { try IDPhoto.render(small, mask: mask, face: face, settings: settings) } }
        } catch { renderer.cancel(); status.stringValue = error.localizedDescription }
    }
    override func reset() {
        preset.selectItem(at: 0); width.integerValue = 295; height.integerValue = 413; units.selectItem(at: 0)
        dpi.integerValue = 300; background.selectItem(at: 0); colorWell.color = .white; zoom.doubleValue = 1; vertical.doubleValue = 0
    }
    override var canCancelSaving: Bool { true }
    override func cancelSaving() { saveTask?.cancel() }
    override func didClose() { renderer.cancel(); saveTask?.cancel() }
    override func apply() async throws -> [URL] {
        let settings = try settings(), source = self.source
        let edge = try IDPhoto.workingEdge(settings: settings)
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image = try Images.load(source, maxPixels: edge)
            try Task.checkCancellation()
            let (face, mask) = try IDPhoto.detect(image)
            let output = try IDPhoto.render(image, mask: mask, face: face, settings: settings)
            return [try IDPhoto.save(output, source: source, dpi: settings.dpi)]
        }
        saveTask = worker
        defer { saveTask = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
