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
        var result = mix(dragged, joined, t * t * (3 - 2 * t))
        // Give the two edges time to stretch into each other before closing their gap.
        let close = min(max((t - 0.55) / 0.45, 0), 1)
        result.origin.y = dragged.minY + (joined.minY - dragged.minY) * close * close * (3 - 2 * close)
        return result
    }

    /// A deliberate bottom-edge contact can be held and released without covering the target's centre.
    static func touchesSeam(_ dragged: CGRect, below top: CGRect, engaged: Bool) -> Bool {
        let overlap = max(0, min(dragged.maxX, top.maxX) - max(dragged.minX, top.minX))
        let distance = dragged.minY - top.maxY
        return overlap >= min(dragged.width, top.width) * 0.6
            && distance >= -min(dragged.height, top.height) * 0.25
            && distance <= (engaged ? 12 : 6)
    }

    /// Both surfaces use the same displacement. They first meet at the centre and the
    /// joined span then spreads sideways; no separate white connector covers the photos.
    struct Melt {
        let top: CGRect
        let bottom: CGRect
        let amount: CGFloat
        var gap: CGFloat { bottom.minY - top.maxY }
        var left: CGFloat { max(top.minX, bottom.minX) }
        var right: CGFloat { min(top.maxX, bottom.maxX) }
        var isFacing: Bool { gap >= -0.01 && gap < reach && right - left > 12 }
        var extent: CGFloat { offset(at: (left + right) / 2) }

        func offset(at x: CGFloat) -> CGFloat {
            guard isFacing, gap > 0.01, amount > 0, x > left, x < right else { return 0 }
            let halfGap = gap / 2
            let spread = (right - left) / 2 * (0.25 + 0.75 * amount)
            let distance = (x - (left + right) / 2) / max(1, spread)
            let profile = CGFloat(exp(-4 * pow(Double(distance), 4)))
            let capacity = (halfGap + 8 * sin(.pi * amount)) * amount * profile
            let t = min(max(capacity / halfGap, 0), 1)
            return halfGap * t * t * (3 - 2 * t)
        }

        func path(upper: Bool) -> CGPath {
            let r = upper ? top : bottom
            let outer = min(3, min(r.width, r.height) / 2)
            let seam = outer * (1 - amount)
            let first = upper ? outer : seam, last = upper ? seam : outer
            let p = CGMutablePath()
            func edge(_ x: CGFloat) -> CGPoint {
                CGPoint(x: x, y: upper ? r.maxY + offset(at: x) : r.minY - offset(at: x))
            }
            p.move(to: CGPoint(x: r.minX + first, y: r.minY))
            if upper { p.addLine(to: CGPoint(x: r.maxX - first, y: r.minY)) }
            else {
                for i in 0...64 {
                    let x = r.minX + first + (r.width - 2 * first) * CGFloat(i) / 64
                    p.addLine(to: edge(x))
                }
            }
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + first), control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - last))
            p.addQuadCurve(to: CGPoint(x: r.maxX - last, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
            if upper {
                for i in 0...64 {
                    let x = r.maxX - last - (r.width - 2 * last) * CGFloat(i) / 64
                    p.addLine(to: edge(x))
                }
            } else { p.addLine(to: CGPoint(x: r.minX + last, y: r.maxY)) }
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - last), control: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + first))
            p.addQuadCurve(to: CGPoint(x: r.minX + first, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            p.closeSubpath()
            return p
        }
    }

    /// One small premultiplied texture per photo, reused while dragging. Only the narrow
    /// edge band is resampled; a single bitmap avoids seams between independently composited strips.
    struct Texture {
        let width: Int, height: Int
        let pixels: [UInt8]
        init?(_ image: CGImage) {
            let scale = min(1, 512 / CGFloat(max(image.width, image.height)))
            width = max(1, Int(CGFloat(image.width) * scale))
            height = max(1, Int(CGFloat(image.height) * scale))
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let w = width, h = height
            let made = data.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard made else { return nil }
            pixels = data
        }

        func band(photo: CGRect, bodyOrigin: CGPoint, surface: Melt, upper: Bool, scale: CGFloat) -> (image: CGImage, frame: CGRect)? {
            guard surface.extent > 0.01, photo.width > 0, photo.height > 0 else { return nil }
            let band = min(28, photo.height * 0.28)
            let frame = CGRect(x: photo.minX, y: upper ? photo.maxY - band : photo.minY - surface.extent,
                               width: photo.width, height: band + surface.extent)
            let density = min(max(scale, 1), 2)
            let w = Int(ceil(frame.width * density)), h = Int(ceil(frame.height * density))
            guard w > 0, h > 0, w <= 1024, h <= 256 else { return nil }
            let imageAspect = CGFloat(width) / CGFloat(height), shownAspect = photo.width / photo.height
            let tw = min(1, shownAspect / imageAspect), th = min(1, imageAspect / shownAspect)
            let tx = (1 - tw) / 2, ty = (1 - th) / 2
            var data = [UInt8](repeating: 0, count: w * h * 4)
            for x in 0..<w {
                let u = (CGFloat(x) + 0.5) / CGFloat(w)
                let stretch = surface.offset(at: bodyOrigin.x + frame.minX + u * frame.width)
                let sx = min(max((tx + u * tw) * CGFloat(width) - 0.5, 0), CGFloat(width - 1))
                let x0 = Int(sx), x1 = min(x0 + 1, width - 1), fx = sx - CGFloat(x0)
                for y in 0..<h {
                    let position = (CGFloat(y) + 0.5) / CGFloat(h) * frame.height
                    let v = upper ? position : position - (surface.extent - stretch)
                    guard v >= 0, v <= band + stretch else { continue }
                    let unit = (upper ? photo.height - band : 0) / photo.height + v / (band + stretch) * band / photo.height
                    let sy = min(max((ty + unit * th) * CGFloat(height) - 0.5, 0), CGFloat(height - 1))
                    let y0 = Int(sy), y1 = min(y0 + 1, height - 1), fy = sy - CGFloat(y0)
                    for c in 0..<4 {
                        let a = CGFloat(pixels[(y0 * width + x0) * 4 + c]) * (1 - fx) + CGFloat(pixels[(y0 * width + x1) * 4 + c]) * fx
                        let b = CGFloat(pixels[(y1 * width + x0) * 4 + c]) * (1 - fx) + CGFloat(pixels[(y1 * width + x1) * 4 + c]) * fx
                        data[(y * w + x) * 4 + c] = UInt8(min(max((a * (1 - fy) + b * fy).rounded(), 0), 255))
                    }
                }
            }
            guard let provider = CGDataProvider(data: Data(data) as CFData),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            return (image, frame)
        }
    }

    static func melt(top: CGRect, bottom: CGRect, strength: CGFloat) -> Melt {
        Melt(top: top, bottom: bottom, amount: min(max(strength, 0), 1))
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
