import AppKit
import AVFoundation
import CoreImage
import ImageIO
import os

enum Upscale {
    private static let opaqueColorKernel = CIColorKernel(source: """
        kernel vec4 opaqueColors(__sample source, __sample nearby) {
            vec3 color = source.a > 0.000001 ? source.rgb / source.a :
                (nearby.a > 0.000001 ? nearby.rgb / nearby.a : vec3(0.0));
            return vec4(clamp(color, 0.0, 1.0), 1.0);
        }
        """)
    /// Preserve straight colour at soft edges and extend it into transparent neighbours before spatial processing.
    static func opaqueColors(_ image: CIImage) throws -> CIImage {
        let nearby = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 16])
            .cropped(to: image.extent)
        guard let result = opaqueColorKernel?.apply(extent: image.extent, arguments: [image, nearby]) else {
            throw ToolError(L("Couldn't render"))
        }
        return result
    }
    static func dimensions(width: Int, height: Int, factor: Int) throws -> CGSize {
        guard width > 0, height > 0, [2, 4].contains(factor),
              Double(width) * Double(height) * Double(factor * factor) <= 64_000_000,
              Double(width) * Double(factor) <= 16384, Double(height) * Double(factor) <= 16384 else {
            throw ToolError(L("The enlarged image would be too large."))
        }
        return CGSize(width: width * factor, height: height * factor)
    }
    /// A 2× video must stay within what the HEVC encoder writes (8192 × 4320); larger frames would be scaled back down.
    static func videoFits(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && max(size.width, size.height) <= 4096 && min(size.width, size.height) <= 2160
    }
    /// H.264 tops out near 4K, and the HighestQuality preset quietly shrinks anything larger to 3840 × 2160.
    static func videoPreset(for output: CGSize) -> String {
        max(output.width, output.height) <= 3840 && min(output.width, output.height) <= 2160
            ? AVAssetExportPresetHighestQuality : AVAssetExportPresetHEVCHighestQuality
    }
    /// Read metadata and decode through the same ImageIO source, with a hard thumbnail bound even if the source changes.
    static func loadStill(_ source: URL, factor: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard let file = CGImageSourceCreateWithURL(source as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, max(width, height) <= 8192,
              Double(width) * Double(height) <= 16_000_000 else {
            throw ToolError(L("This image is too large to upscale. Use an image up to 16 megapixels."))
        }
        try Images.requireSingleImage(file)
        try Images.validatePrecision(file)
        _ = try dimensions(width: width, height: height, factor: factor)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let result = CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary) else {
            throw ToolError(L("Couldn't render"))
        }
        try Task.checkCancellation()
        _ = try dimensions(width: result.width, height: result.height, factor: factor)
        return result
    }
    static func lanczos(_ image: CIImage, factor: Double) -> CIImage {
        // Resampling a finite image against transparent black leaves a bright outline after back-projection.
        // Extend its actual edge pixels, then restore a finite extent for the next render/scale operation.
        image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
            .cropped(to: image.extent.applying(CGAffineTransform(scaleX: factor, y: factor)))
    }
    static func ordinary(_ image: CGImage, factor: Int) throws -> CGImage {
        let size = try dimensions(width: image.width, height: image.height, factor: factor)
        let output = lanczos(CIImage(cgImage: image), factor: Double(factor))
        guard let cg = CIContext().createCGImage(output, from: CGRect(origin: .zero, size: size)) else { throw ToolError(L("Couldn't render")) }
        return cg
    }
    static func save(_ image: CGImage, source: URL, factor: Int) throws -> URL {
        try Task.checkCancellation()
        let (type, ext) = Images.writableType(for: source)
        let data = try Images.encode(image, type: type, quality: 0.95)
        try Task.checkCancellation()
        // Exclusive publication is the commit point: a later cancellation may return this completed output.
        return try Paths.create(data, at: Paths.preferred(for: source, ext: ext, suffix: " \(factor)x"))
    }
    /// Own the last worker so Cancel reaches both rendering and the check between encoding and publication.
    static func finishStill(_ image: CIImage, source: URL, factor: Int,
                            render: @escaping @Sendable (CIImage) throws -> CGImage = { image in
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { throw ToolError(L("Couldn't render")) }
        return cg
    }) async throws -> URL {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let cg = try render(image)
            try Task.checkCancellation()
            return try save(cg, source: source, factor: factor)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
    static func video(_ source: URL, engine: UpscaleProcessor, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = try await Video.safeAsset(source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ToolError(L("No video track")) }
        let size = try await VideoEdit.uprightSize(of: track)
        let factor = 2
        guard videoFits(size) else { throw ToolError(L("This video is too large to upscale. Use video up to 4096 × 2160.")) }
        let outputSize = try dimensions(width: Int(size.width), height: Int(size.height), factor: factor)
        let work = UpscaleVideoWork(engine: engine)
        defer { work.cancel() }
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let frame = UpscaleVideoFrame(request)
            Task.detached {
                do {
                    try work.checkCancellation()
                    let result = try await engine.render(frame.request.sourceImage, frame.request.compositionTime)
                    try work.checkCancellation()
                    frame.request.finish(with: result, context: nil)
                } catch { frame.request.finish(with: error) }
            }
        }
        composition.renderSize = outputSize
        guard let session = AVAssetExportSession(asset: asset, presetName: videoPreset(for: outputSize)) else { throw ToolError(L("Couldn't encode video.")) }
        session.videoComposition = composition
        session.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let monitor = Task {
            while !Task.isCancelled { progress(Double(session.progress)); try await Task.sleep(for: .milliseconds(100)) }
        }
        defer { monitor.cancel() }
        return try await Paths.produce(Paths.preferred(for: source, ext: "mov", suffix: " 2x")) { temporary in
            try Task.checkCancellation()
            // AVFoundation installs its own synchronous cancellation handler, which can wait for pending
            // composition requests. Keep that task separate so our processor is stopped before it drains.
            let exporter = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                try await session.export(to: temporary, as: .mov)
            }
            try await withTaskCancellationHandler {
                // Always join this worker before Paths.produce removes its temporary, even if already cancelled.
                try await exporter.value
                try Task.checkCancellation()
                // Never publish "2x" for a file the encoder resized on its own.
                let written = try await AVURLAsset(url: temporary).loadTracks(withMediaType: .video).first
                guard let written, try await VideoEdit.uprightSize(of: written) == outputSize else {
                    throw ToolError(L("Couldn't encode video."))
                }
            } onCancel: { work.cancel(); exporter.cancel() }
        }
    }
}

struct UpscaleProcessor: Sendable {
    let render: @Sendable (CIImage, CMTime) async throws -> CIImage
    var cancel: @Sendable () -> Void = {}
}

private final class UpscaleVideoWork: @unchecked Sendable {
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private let engine: UpscaleProcessor
    init(engine: UpscaleProcessor) { self.engine = engine }
    func cancel() { stopped.withLock { $0 = true }; engine.cancel() }
    func checkCancellation() throws { if Task.isCancelled || stopped.withLock({ $0 }) { throw CancellationError() } }
}
/// Each AVFoundation request has one finishing worker; different requests can arrive on different queues.
private final class UpscaleVideoFrame: @unchecked Sendable {
    let request: AVAsynchronousCIImageFilteringRequest
    init(_ request: AVAsynchronousCIImageFilteringRequest) { self.request = request }
}

final class UpscaleEditor: Editor {
    private let preview = ImagePreview()
    private let video: Bool
    private var factors: NSSegmentedControl!
    private let sizeLabel = NSTextField(labelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private var sourceSize = CGSize.zero
    private var task: Task<[URL], Error>?

    init(source: URL, video: Bool = false) {
        self.video = video
        super.init(title: "Upscale", source: source, canvas: preview)
        factors = segments(video ? ["2×"] : ["2×", "4×"])
        addRow("Scale", factors, sizeLabel)
        explanation.stringValue = L("Real-ESRGAN processes files on this Mac. Fine details may be reconstructed.")
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor
        addRow("", explanation)
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 240).isActive = true
        addRow("", progress)
    }
    override func load() async throws {
        let source = self.source
        if video {
            let asset = try await Video.safeAsset(source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ToolError(L("No video track")) }
            sourceSize = try await VideoEdit.uprightSize(of: track)
            guard Upscale.videoFits(sourceSize) else { throw ToolError(L("This video is too large to upscale. Use video up to 4096 × 2160.")) }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1400, height: 1400)
            preview.image = try await generator.image(at: .zero).image
        } else {
            let result = try await Images.detached { () throws -> (CGImage, CGSize) in
                guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      var w = props[kCGImagePropertyPixelWidth] as? Int, var h = props[kCGImagePropertyPixelHeight] as? Int else {
                    throw ToolError(L("Couldn't render"))
                }
                guard w > 0, h > 0, max(w, h) <= 8192, Double(w) * Double(h) <= 16_000_000 else {
                    throw ToolError(L("This image is too large to upscale. Use an image up to 16 megapixels."))
                }
                if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&w, &h) }
                return (try Images.load(source, maxPixels: 1400), CGSize(width: w, height: h))
            }
            preview.image = result.0; sourceSize = result.1
        }
    }
    override func update() {
        let factor = factors.selectedSegment == 1 ? 4 : 2
        sizeLabel.stringValue = "\(Int(sourceSize.width) * factor) × \(Int(sourceSize.height) * factor) px"
    }
    override func reset() { factors.selectedSegment = 0 }
    override var canCancelSaving: Bool { true }
    override func cancelSaving() { task?.cancel() }
    override func didClose() { task?.cancel() }
    override func apply() async throws -> [URL] {
        let factor = factors.selectedSegment == 1 ? 4 : 2, source = self.source, video = self.video
        let size = try Upscale.dimensions(width: Int(sourceSize.width), height: Int(sourceSize.height), factor: factor)
        _ = size
        let task = Task { [self] () throws -> [URL] in
            progress.isIndeterminate = true; progress.startAnimation(nil)
            let engine: RealESRGANEngine
            do { engine = try await RealESRGANEngine.make() }
            catch { progress.stopAnimation(nil); progress.isIndeterminate = false; throw error }
            progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = 0
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if video {
                    let processor = UpscaleProcessor(render: { image, _ in try await engine.render(image, factor: 2) }, cancel: { engine.cancel() })
                    return [try await Upscale.video(source, engine: processor) { [weak self] value in
                        Task { @MainActor in self?.progress.doubleValue = value }
                    }]
                }
                let worker = Task.detached(priority: .userInitiated) { try Upscale.loadStill(source, factor: factor) }
                let image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                let result = try await engine.render(CIImage(cgImage: image), factor: factor) { [weak self] value in
                    Task { @MainActor in self?.progress.doubleValue = value }
                }
                try Task.checkCancellation()
                return [try await Upscale.finishStill(result, source: source, factor: factor)]
            } onCancel: { engine.cancel() }
        }
        self.task = task
        defer { self.task = nil; progress.stopAnimation(nil); progress.isIndeterminate = false }
        return try await task.value
    }
}
