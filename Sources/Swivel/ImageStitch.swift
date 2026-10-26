import AppKit
import ImageIO

/// A deliberate overlap, rather than passing across a neighbour while dragging out of the rope.
struct RopeStitchIntent {
    static let delay: CFTimeInterval = 0.25
    private(set) var target: URL?
    private var since: CFTimeInterval = 0

    mutating func update(_ target: URL?, now: CFTimeInterval) {
        guard self.target != target else { return }
        self.target = target
        since = now
    }

    func ready(at now: CFTimeInterval) -> Bool { target != nil && now - since >= Self.delay }
}

/// Whole images, target above dragged image. No overlap guessing or content cropping.
enum ImageStitch {
    static let pixelLimit = min(40_000_000.0, Images.maxDecodePixels)
    static let edgeLimit = 32_768

    static func supports(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(url.pathExtension.lowercased())
    }

    static func size(top: CGSize, bottom: CGSize) throws -> (width: Int, top: Int, bottom: Int) {
        let values = [top.width, top.height, bottom.width, bottom.height]
        guard values.allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= CGFloat(edgeLimit) }) else {
            throw ToolError(L("Image too large"))
        }
        // Match the narrower width: never enlarge an image, crop or distort it.
        let width = Int(min(top.width, bottom.width))
        let a = max(1, Int((top.height * CGFloat(width) / top.width).rounded()))
        let b = max(1, Int((bottom.height * CGFloat(width) / bottom.width).rounded()))
        guard a + b <= edgeLimit, Double(width) * Double(a + b) <= pixelLimit else {
            throw ToolError(L("Image too large"))
        }
        return (width, a, b)
    }

    static func render(top: CGImage, bottom: CGImage) throws -> CGImage {
        let s = try size(top: CGSize(width: top.width, height: top.height),
                         bottom: CGSize(width: bottom.width, height: bottom.height))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: s.width, height: s.top + s.bottom, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError(L("Image too large"))
        }
        ctx.interpolationQuality = .high
        ctx.draw(top, in: CGRect(x: 0, y: s.bottom, width: s.width, height: s.top))
        ctx.draw(bottom, in: CGRect(x: 0, y: 0, width: s.width, height: s.bottom))
        guard let image = ctx.makeImage() else { throw ToolError(L("Couldn't encode image")) }
        return image
    }

    static func save(top: URL, bottom: URL) throws -> URL {
        guard top != bottom, supports(top), supports(bottom) else { throw ToolError(L("Choose two still images to stitch.")) }
        // Bounded, no-follow local reads. Decode immutable bytes, never a path that can change mid-decode.
        let a = try source(top), b = try source(bottom)
        let sa = try dimensions(a), sb = try dimensions(b)
        _ = try size(top: sa, bottom: sb)
        guard sa.width * sa.height + sb.width * sb.height <= pixelLimit else { throw ToolError(L("Image too large")) }
        try Task.checkCancellation()
        let first = try decode(a), second = try decode(b)
        let result = try render(top: first, bottom: second)
        try Task.checkCancellation()
        return try Images.save(result, as: Paths.preferred(for: top, ext: "png", suffix: " stitched"), type: .png, quality: 1)
    }

    private static func source(_ url: URL) throws -> CGImageSource {
        let data = try FileSafety.read(url, limit: 128_000_000)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ToolError(L("Couldn't decode image")) }
        try Images.requireSingleImage(source)
        try Images.validatePrecision(source) // Reject HDR, auxiliary data, float and >8-bit rather than silently flattening.
        return source
    }

    private static func dimensions(_ source: CGImageSource) throws -> CGSize {
        let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= edgeLimit, h <= edgeLimit else { throw ToolError(L("Image too large")) }
        let rotated = (p[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        return CGSize(width: rotated ? h : w, height: rotated ? w : h)
    }

    private static func decode(_ source: CGImageSource) throws -> CGImage {
        try Task.checkCancellation()
        let s = try dimensions(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(s.width, s.height))
        ] as CFDictionary) else { throw ToolError(L("Couldn't decode image")) }
        return image
    }
}
