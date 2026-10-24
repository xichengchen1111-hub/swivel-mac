import CoreGraphics
import Foundation
import ImageIO

/// A committed brush stroke, in upright image coordinates (bottom-left, 0...1).
struct RetouchStroke: Sendable, Equatable {
    var points: [CGPoint]
    var diameter: Double // fraction of the image's longer side
}

/// Original exemplar synthesis, informed by Barnes et al. (2009), randomized patch correspondence, and
/// Wexler et al. (2007), coarse-to-fine completion. No implementation or assets from another project are used.
/// Only fully known patches may donate pixels. A small pyramid supplies a weak guide in large missing areas;
/// the fine pass matches the real boundary and copies texture, rather than averaging its colours away.
enum Retouch {
    struct Raster {
        let width: Int
        let height: Int
        var bytes: [UInt8] // top-down premultiplied RGBA

        init(_ image: CGImage) throws {
            width = image.width; height = image.height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard ok else { throw ToolError(L("Couldn't repair this area.")) }
        }

        init(width: Int, height: Int, bytes: [UInt8]) {
            self.width = width; self.height = height; self.bytes = bytes
        }

        func image() throws -> CGImage {
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw ToolError(L("Couldn't repair this area.")) }
            return image
        }
    }

    // The native canvas copy and the synthesis maps have separate budgets. In particular, a small
    // stroke cannot authorize allocating donor/integral maps for a huge source photograph.
    static let maxSourcePixels = 40_000_000
    static let maxSourceBytes = 320_000_000
    static let maxRegionPixels = 2_000_000

    struct Region {
        var bounds: CGRect // integral, top-down source pixels
        var strokeIndices: [Int]
    }

    /// Separate distant strokes before any raster allocation. Intersecting context windows merge so
    /// one window never treats another window's painted object as usable background.
    static func regions(width: Int, height: Int, strokes: [RetouchStroke],
                        cancelled: () -> Bool = { false }) throws -> [Region] {
        if cancelled() { throw Cancelled() }
        let side = Double(max(width, height)), canvas = CGRect(x: 0, y: 0, width: width, height: height)
        var result: [Region] = []
        for (index, stroke) in strokes.enumerated() where stroke.diameter.isFinite && stroke.diameter > 0 {
            if cancelled() { throw Cancelled() }
            let radius = max(0.5, stroke.diameter * side / 2)
            guard radius.isFinite else { throw ToolError(L("This repair area is too large. Use smaller, separate strokes.")) }
            var painted = CGRect.null
            for (i, point) in stroke.points.enumerated() where point.x.isFinite && point.y.isFinite {
                if i % 256 == 0, cancelled() { throw Cancelled() }
                // The canvas supplies normalized points. Clamping also prevents extreme coordinates
                // from overflowing CGRect arithmetic if another internal caller supplies a bad stroke.
                let x = min(1, max(0, point.x)) * Double(width)
                let y = (1 - min(1, max(0, point.y))) * Double(height)
                painted = painted.union(CGRect(x: x - radius, y: y - radius,
                                               width: 2 * radius + 1, height: 2 * radius + 1))
            }
            guard !painted.isNull else { continue }
            let margin = min(160.0, max(32, max(painted.width, painted.height) * 0.6))
            var region = Region(bounds: painted.insetBy(dx: -margin, dy: -margin).integral.intersection(canvas),
                                strokeIndices: [index])
            guard !region.bounds.isEmpty else { continue }
            // A merge can bridge earlier windows, so reconsider from the beginning after every merge.
            var candidate = 0
            while candidate < result.count {
                if candidate % 32 == 0, cancelled() { throw Cancelled() }
                if region.bounds.intersects(result[candidate].bounds) {
                    let other = result.remove(at: candidate)
                    region.bounds = region.bounds.union(other.bounds)
                    region.strokeIndices += other.strokeIndices
                    candidate = 0
                } else { candidate += 1 }
            }
            guard region.bounds.width * region.bounds.height <= Double(maxRegionPixels) else {
                throw ToolError(L("This repair area is too large. Use smaller, separate strokes."))
            }
            result.append(region)
        }
        return result
    }

    /// A cancellation predicate is also used by previews: a new stroke invalidates even an in-flight synthesis.
    static func render(_ image: CGImage, strokes: [RetouchStroke], cancelled: () -> Bool = { false }) throws -> CGImage {
        if cancelled() { throw Cancelled() }
        guard !strokes.isEmpty else { return image }
        let w = image.width, h = image.height
        guard Double(w) * Double(h) <= Double(maxSourcePixels),
              image.bytesPerRow <= maxSourceBytes / h else {
            throw ToolError(L("This image is too large to retouch. Resize it first."))
        }
        let windows = try regions(width: w, height: h, strokes: strokes, cancelled: cancelled)
        guard !windows.isEmpty else { return image }
        // Scoring is 8-bit sRGB, but the saved pixels are not. A donor map copies the original native
        // pixel (including P3, alpha and 16/32-bit precision) and leaves every unpainted byte untouched.
        guard let space = image.colorSpace, [.rgb, .monochrome].contains(space.model),
              [8, 16, 32].contains(image.bitsPerComponent), image.bitsPerPixel % 8 == 0,
              image.bitsPerPixel > 0, image.bitsPerPixel <= 128 else {
            throw ToolError(L("Retouch can't preserve this image's color format."))
        }
        let bytesPerPixel = image.bitsPerPixel / 8
        // Cropped CGImages may retain the parent's row stride and expose only the used part of
        // their last row. The provider starts at the cropped first pixel; never assume tight rows.
        let nativeLength = (h - 1) * image.bytesPerRow + w * bytesPerPixel
        guard image.bytesPerRow >= w * bytesPerPixel, let original = image.dataProvider?.data,
              CFDataGetLength(original) >= nativeLength, let sourceBytes = CFDataGetBytePtr(original) else {
            throw ToolError(L("Retouch can't preserve this image's color format."))
        }
        var output = Data(bytes: sourceBytes, count: nativeLength)
        let side = Double(max(w, h))
        for window in windows {
            if cancelled() { throw Cancelled() }
            let roi = window.bounds
            guard let crop = image.cropping(to: roi) else { throw ToolError(L("Couldn't repair this area.")) }
            let raster = try Raster(crop), rw = raster.width, rh = raster.height
            var mask = [Bool](repeating: false, count: rw * rh)
            for index in window.strokeIndices {
                let stroke = strokes[index], r = max(0.5, stroke.diameter * side / 2)
                let points = stroke.points.filter { $0.x.isFinite && $0.y.isFinite }.map {
                    CGPoint(x: min(1, max(0, $0.x)) * Double(w) - roi.minX,
                            y: (1 - min(1, max(0, $0.y))) * Double(h) - roi.minY)
                }
                for (i, b) in points.enumerated() {
                    if cancelled() { throw Cancelled() }
                    let a = points[max(0, i - 1)]
                    let box = CGRect(x: min(a.x, b.x) - r, y: min(a.y, b.y) - r,
                                     width: abs(b.x - a.x) + 2 * r + 1, height: abs(b.y - a.y) + 2 * r + 1)
                        .integral.intersection(CGRect(x: 0, y: 0, width: rw, height: rh))
                    guard !box.isEmpty else { continue }
                    let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                    for y in Int(box.minY)..<Int(box.maxY) {
                        if cancelled() { throw Cancelled() }
                        for x in Int(box.minX)..<Int(box.maxX) {
                            let px = Double(x) + 0.5, py = Double(y) + 0.5
                            let t = length > 0 ? min(1, max(0, ((px - a.x) * dx + (py - a.y) * dy) / length)) : 0
                            if pow(px - a.x - t * dx, 2) + pow(py - a.y - t * dy, 2) <= r * r { mask[y * rw + x] = true }
                        }
                    }
                }
            }
            let repaired = try synthesize(raster, mask: mask, cancelled: cancelled)
            let originX = Int(roi.minX), originY = Int(roi.minY)
            try output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                for y in 0..<rh {
                    if cancelled() { throw Cancelled() }
                    for x in 0..<rw where mask[y * rw + x] {
                        let donor = repaired.donors[y * rw + x]
                        guard donor >= 0 else { throw ToolError(L("Couldn't repair this area.")) }
                        let targetOffset = (originY + y) * image.bytesPerRow + (originX + x) * bytesPerPixel
                        let sourceOffset = (originY + donor / rw) * image.bytesPerRow + (originX + donor % rw) * bytesPerPixel
                        destination.baseAddress!.advanced(by: targetOffset)
                            .copyMemory(from: sourceBytes.advanced(by: sourceOffset), byteCount: bytesPerPixel)
                    }
                }
            }
        }
        if cancelled() { throw Cancelled() }
        guard let provider = CGDataProvider(data: output as CFData),
              let result = CGImage(width: w, height: h, bitsPerComponent: image.bitsPerComponent,
                                   bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow,
                                   space: space, bitmapInfo: image.bitmapInfo, provider: provider, decode: image.decode,
                                   shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) else {
            throw ToolError(L("Retouch can't preserve this image's color format."))
        }
        return result
    }

    static func save(_ source: URL, strokes: [RetouchStroke]) throws -> URL {
        guard !strokes.isEmpty else { throw ToolError(L("Nothing to retouch. Paint over an object first.")) }
        try Task.checkCancellation()
        guard let file = CGImageSourceCreateWithURL(source as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any] else {
            throw ToolError(L("Couldn't repair this area."))
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        guard (1...32).contains(depth) else {
            throw ToolError(L("Retouch can't preserve this image's color format."))
        }
        guard width > 0, height > 0, Double(width) * Double(height) <= Double(maxSourcePixels),
              Double(width) * Double(height) * Double(max(1, (depth + 7) / 8)) * 4 <= Double(maxSourceBytes) else {
            throw ToolError(L("This image is too large to retouch. Resize it first."))
        }
        let image = try Images.load(source)
        // ImageIO thumbnails can normalize unusual source layouts; refuse a silent precision reduction.
        guard image.bitsPerComponent >= depth else {
            throw ToolError(L("Retouch can't preserve this image's color format."))
        }
        let result = try render(image, strokes: strokes, cancelled: { Task.isCancelled })
        try Task.checkCancellation()
        let (type, ext) = Images.writableType(for: source)
        return try Images.save(result, as: Paths.preferred(for: source, ext: ext, suffix: " retouched"), type: type, quality: 0.95)
    }

    /// Boundary-first patch completion. The mask is immutable for donor validation; newly completed pixels can
    /// guide a match but can never become source material. Thus the object itself cannot leak back into the hole.
    static func complete(_ input: Raster, mask: [Bool], cancelled: () -> Bool = { false }) throws -> Raster {
        try synthesize(input, mask: mask, cancelled: cancelled).raster
    }

    private struct Completion {
        var raster: Raster
        var donors: [Int]
    }

    private static func synthesize(_ input: Raster, mask: [Bool], cancelled: () -> Bool) throws -> Completion {
        if cancelled() { throw Cancelled() }
        let w = input.width, h = input.height
        guard w > 0, h > 0, Double(w) * Double(h) <= Double(maxRegionPixels),
              mask.count == w * h, input.bytes.count == w * h * 4 else {
            throw ToolError(L("Couldn't repair this area."))
        }
        var known: [Int] = [], hasMask = false
        for p in mask.indices {
            if p % 4096 == 0, cancelled() { throw Cancelled() }
            if mask[p] { hasMask = true } else { known.append(p) }
        }
        guard hasMask else { return Completion(raster: input, donors: []) }
        guard !known.isEmpty else { throw ToolError(L("Leave some background unpainted to repair this area.")) }
        var guide: Raster?
        if max(w, h) > 180, min(w, h) > 16 {
            let nw = max(1, (w + 1) / 2), nh = max(1, (h + 1) / 2)
            var b = [UInt8](repeating: 0, count: nw * nh * 4)
            var m = [Bool](repeating: false, count: nw * nh)
            for y in 0..<nh {
                if cancelled() { throw Cancelled() }
                for x in 0..<nw {
                    var sum = [Int](repeating: 0, count: 4), count = 0
                    for yy in (y * 2)..<min(h, y * 2 + 2) { for xx in (x * 2)..<min(w, x * 2 + 2) {
                        let p = yy * w + xx
                        if mask[p] { m[y * nw + x] = true; continue }
                        count += 1
                        for c in 0..<4 { sum[c] += Int(input.bytes[p * 4 + c]) }
                    } }
                    if count > 0 { for c in 0..<4 { b[(y * nw + x) * 4 + c] = UInt8(sum[c] / count) } }
                }
            }
            // At very high coverage a coarse mask can swallow every donor. Keep the fine-level boundary instead.
            if m.contains(false) { guide = try complete(Raster(width: nw, height: nh, bytes: b), mask: m, cancelled: cancelled) }
        }
        var output = input
        var filled = mask.map { !$0 }
        var donor = [Int](repeating: -1, count: w * h)
        var random: UInt64 = 0x8e73c9b5
        func next(_ upper: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 32) % UInt64(max(1, upper)))
        }
        // Summed mask makes "is this entire source patch known?" an O(1) check.
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            if cancelled() { throw Cancelled() }
            var row = 0
            for x in 0..<w {
                row += mask[y * w + x] ? 1 : 0
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        var radius = min(3, (min(w, h) - 1) / 2)
        var sources: [Int] = []
        while true {
            for (index, p) in known.enumerated() {
                if index % 4096 == 0, cancelled() { throw Cancelled() }
                let x = p % w, y = p / w
                guard x >= radius, x + radius < w, y >= radius, y + radius < h else { continue }
                let a = (y - radius) * (w + 1), b = (y + radius + 1) * (w + 1)
                let l = x - radius, r = x + radius + 1
                if integral[b + r] - integral[b + l] - integral[a + r] + integral[a + l] == 0 { sources.append(p) }
            }
            if !sources.isEmpty || radius == 0 { break }
            radius -= 1
        }
        // Queue each boundary once. A copied patch reveals more of the frontier; no full-image repeated scans.
        var queue: [Int] = [], enqueued = [Bool](repeating: false, count: w * h)
        func neighbours(_ p: Int) -> [Int] {
            let x = p % w, y = p / w
            return [(x > 0 ? p - 1 : -1), (x + 1 < w ? p + 1 : -1),
                    (y > 0 ? p - w : -1), (y + 1 < h ? p + w : -1)].filter { $0 >= 0 }
        }
        for p in mask.indices {
            if p % 4096 == 0, cancelled() { throw Cancelled() }
            if mask[p] && neighbours(p).contains(where: { filled[$0] }) {
                queue.append(p); enqueued[p] = true
            }
        }
        var head = 0
        while head < queue.count {
            if head % 32 == 0, cancelled() { throw Cancelled() }
            let p = queue[head]; head += 1
            if filled[p] { continue }
            let x = p % w, y = p / w
            // Match only known context plus a low-weight coarse guide. Never compare to the erased object.
            var context: [(Int, Int, Double, [UInt8])] = []
            for dy in -radius...radius { for dx in -radius...radius {
                let tx = x + dx, ty = y + dy
                guard tx >= 0, tx < w, ty >= 0, ty < h else { continue }
                let t = ty * w + tx
                if filled[t] {
                    context.append((dx, dy, mask[t] ? 0.6 : 1, Array(output.bytes[(t * 4)..<(t * 4 + 4)])))
                } else if let guide {
                    let g = ((ty / 2) * guide.width + tx / 2) * 4
                    context.append((dx, dy, 0.03, Array(guide.bytes[g..<(g + 4)])))
                }
            } }
            var best = sources[next(sources.count)], score = Double.infinity
            func consider(_ q: Int) {
                guard q >= 0, q < w * h else { return }
                let sx = q % w, sy = q / w
                guard sx >= radius, sx + radius < w, sy >= radius, sy + radius < h else { return }
                let a = (sy - radius) * (w + 1), b = (sy + radius + 1) * (w + 1)
                let l = sx - radius, r = sx + radius + 1
                guard integral[b + r] - integral[b + l] - integral[a + r] + integral[a + l] == 0 else { return }
                var distance = 0.0
                for (dx, dy, weight, value) in context {
                    let j = ((sy + dy) * w + sx + dx) * 4
                    for c in 0..<4 { let d = Double(Int(input.bytes[j + c]) - Int(value[c])); distance += weight * d * d }
                    if distance >= score { return }
                }
                if distance < score { score = distance; best = q }
            }
            // Spatial propagation preserves a stripe/grid phase across an advancing frontier.
            for n in neighbours(p) where filled[n] {
                if donor[n] >= 0 { consider(donor[n] + p - n) }
            }
            for _ in 0..<64 { consider(sources[next(sources.count)]) }
            var reach = max(w, h)
            while reach > 0 {
                let bx = best % w, by = best / w
                let sx = min(w - 1, max(0, bx + next(2 * reach + 1) - reach))
                let sy = min(h - 1, max(0, by + next(2 * reach + 1) - reach))
                consider(sy * w + sx)
                reach /= 2
            }
            // Copy a small patch, retaining every originally unmasked pixel verbatim.
            let copyRadius = max(0, radius - 1)
            for dy in -copyRadius...copyRadius { for dx in -copyRadius...copyRadius {
                let tx = x + dx, ty = y + dy
                guard tx >= 0, tx < w, ty >= 0, ty < h else { continue }
                let t = ty * w + tx
                guard !filled[t] else { continue }
                let s = best + dy * w + dx
                for c in 0..<4 { output.bytes[t * 4 + c] = input.bytes[s * 4 + c] }
                filled[t] = true; donor[t] = s
                for n in neighbours(t) where !filled[n] && !enqueued[n] { queue.append(n); enqueued[n] = true }
            } }
        }
        return Completion(raster: output, donors: donor)
    }
}
