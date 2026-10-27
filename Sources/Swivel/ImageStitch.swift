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

    static func hitArea(in bounds: CGRect, engaged: Bool) -> CGRect {
        let inset: CGFloat = engaged ? 0.03 : 0.12
        return bounds.insetBy(dx: bounds.width * inset, dy: bounds.height * inset)
    }

    func ready(at now: CFTimeInterval) -> Bool { target != nil && now - since >= Self.delay }
}

/// Geometry for two independently moving photo bodies and their soft connecting neck.
/// This never touches exported pixels.
enum RopeStitchJelly {
    static let response: CGFloat = 0.38
    static let damping: CGFloat = 0.72
    static let reach: CGFloat = 30

    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(max(0, max(a.minX - b.maxX, b.minX - a.maxX)),
              max(0, max(a.minY - b.maxY, b.minY - a.maxY)))
    }

    static func mix(_ a: CGRect, _ b: CGRect, _ amount: CGFloat) -> CGRect {
        let t = min(max(amount, 0), 1)
        return CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// The resting preview is already attached while the button is held. Only the source moves;
    /// target selection and cancellation continue to use the real pointer, never this attracted frame.
    static func attached(_ dragged: CGRect, below top: CGRect, strength: CGFloat, within area: CGRect? = nil) -> CGRect {
        let t = min(max(strength, 0), 1)
        var joined = CGRect(x: top.midX - dragged.width / 2, y: top.maxY,
                            width: dragged.width, height: dragged.height)
        if let area { joined.origin.x = min(max(joined.minX, area.minX), area.maxX - joined.width) }
        return mix(dragged, joined, t * t * (3 - 2 * t))
    }

    /// A deliberate bottom-edge contact can be held and released without covering the target's centre.
    static func touchesSeam(_ dragged: CGRect, below top: CGRect, engaged: Bool) -> Bool {
        let overlap = max(0, min(dragged.maxX, top.maxX) - max(dragged.minX, top.minX))
        let distance = dragged.minY - top.maxY
        return overlap >= min(dragged.width, top.width) * 0.6
            && distance >= -min(dragged.height, top.height) * 0.25
            && distance <= (engaged ? 12 : 6)
    }

    /// Ordinary corners remain small. Only the two corners on the joining edge bend into the seam.
    static func bodyPath(in r: CGRect, seamAtBottom: Bool, radius: CGFloat) -> CGPath {
        let small = min(3, min(r.width, r.height) / 2)
        let seam = min(max(small, radius), min(r.width, r.height) / 4)
        let upper = seamAtBottom ? small : seam, lower = seamAtBottom ? seam : small
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + upper, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - upper, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + upper), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - lower))
        p.addQuadCurve(to: CGPoint(x: r.maxX - lower, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + lower, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - lower), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + upper))
        p.addQuadCurve(to: CGPoint(x: r.minX + upper, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }

    /// A broad, shallow concave arc along the joining edges, rather than a neck between round blobs.
    static func bridge(_ top: CGRect, _ bottom: CGRect, strength: CGFloat) -> CGPath? {
        let amount = min(max(strength, 0), 1)
        let overlap = min(top.maxX, bottom.maxX) - max(top.minX, bottom.minX)
        let gap = bottom.minY - top.maxY
        guard amount > 0, overlap > 12, gap >= -1, gap < reach,
              min(top.width, top.height, bottom.width, bottom.height) > 0 else { return nil }
        let bend = min(10, min(top.height, bottom.height) * 0.08) * amount
        let waist = min(5, overlap * 0.035) * amount
        let upper = top.maxY - bend, lower = bottom.minY + bend
        let middle = (top.maxY + bottom.minY) / 2
        let left = (top.minX + bottom.minX) / 2 + waist
        let right = (top.maxX + bottom.maxX) / 2 - waist
        let p = CGMutablePath()
        p.move(to: CGPoint(x: top.minX, y: upper))
        p.addCurve(to: CGPoint(x: left, y: middle),
                   control1: CGPoint(x: top.minX, y: middle), control2: CGPoint(x: left, y: upper))
        p.addCurve(to: CGPoint(x: bottom.minX, y: lower),
                   control1: CGPoint(x: left, y: lower), control2: CGPoint(x: bottom.minX, y: middle))
        p.addLine(to: CGPoint(x: bottom.maxX, y: lower))
        p.addCurve(to: CGPoint(x: right, y: middle),
                   control1: CGPoint(x: bottom.maxX, y: middle), control2: CGPoint(x: right, y: lower))
        p.addCurve(to: CGPoint(x: top.maxX, y: upper),
                   control1: CGPoint(x: right, y: upper), control2: CGPoint(x: top.maxX, y: middle))
        p.closeSubpath()
        return p
    }
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
