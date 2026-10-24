import AppKit
import SceneKit
import simd

/// What grows on a saved code. Every template is built from the code's own modules: seen from straight above, its
/// top surfaces are the unmodified QR code (dark modules carry leaves, flowers or land; light modules stay pale).
enum QRTemplate: String, Codable, CaseIterable, Sendable {
    case tree, bouquet, island
    var title: String { switch self { case .tree: L("Tree"); case .bouquet: L("Bouquet"); case .island: L("Island") } }
    var symbol: String { switch self { case .tree: "tree"; case .bouquet: "camera.macro"; case .island: "beach.umbrella" } }
}

enum QRModules {
    /// The code's modules, row 0 at the top, without the quiet zone.
    static func matrix(_ value: String) throws -> [[Bool]] {
        let code = try QRImage.raw(value)
        guard let image = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(code, from: code.extent.integral) else {
            throw ToolError(L("Could not generate the QR image."))
        }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ToolError(L("Could not generate the QR image.")) }
        // Bitmap memory runs top row first. Trim the generator's own light border.
        let dark = (0..<h).map { y in (0..<w).map { x in pixels[y * w + x] < 128 } }
        let rows = dark.indices.filter { dark[$0].contains(true) }, cols = (0..<w).filter { x in dark.contains { $0[x] } }
        guard let top = rows.first, let bottom = rows.last, let left = cols.first, let right = cols.last else {
            throw ToolError(L("Could not generate the QR image."))
        }
        return (top...bottom).map { y in Array(dark[y][left...right]) }
    }
}

/// One axis-aligned block of the scene, in module units (x to the right, z down the code, y up).
struct QRVoxel: Equatable {
    var x: Float, z: Float, y0: Float, y1: Float, size: Float, color: SIMD3<Float>
    var depth: Float? = nil
    /// Side colour when it differs from the top (soil under grass, the sea under a slab).
    var side: SIMD3<Float>? = nil
}

/// The scene as plain data, so it can be tested without rendering. `ground` and `cover` stay in the top view; `cover`
/// grows when a code appears. `structure` (trunks, stems, paper, boats) fades out on the way to the top view, so only
/// the code's own surfaces are left to scan.
struct QRGardenModel {
    var size: Int
    var margin: Float
    var ground: [QRVoxel] = []
    var cover: [QRVoxel] = []
    var structure: [QRVoxel] = []
    var dark: [[Bool]]

    static func build(_ dark: [[Bool]], template: QRTemplate, season: QRSeason, seed: UInt64) -> QRGardenModel {
        var builder = Builder(dark: dark, season: season, seed: seed)
        switch template {
        case .tree: builder.tree()
        case .bouquet: builder.bouquet()
        case .island: builder.island()
        }
        return builder.model
    }

    /// Top colour seen from straight above at a module, or nil when nothing covers it but the slab.
    func topColor(row: Int, column: Int) -> SIMD3<Float>? {
        let half = Float(size - 1) / 2, x = Float(column) - half, z = Float(row) - half
        return (ground + cover).filter { abs($0.x - x) < $0.size / 2 && abs($0.z - z) < ($0.depth ?? $0.size) / 2 }
            .max { $0.y1 < $1.y1 }?.color
    }
}

private struct Palette {
    var slab: SIMD3<Float>, slabSide: SIMD3<Float>
    var tiles: [SIMD3<Float>]
}

private func rgb(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> { SIMD3(r, g, b) }

private struct Builder {
    let dark: [[Bool]], season: QRSeason
    var state: UInt64
    var model: QRGardenModel
    let n: Int, half: Float
    init(dark: [[Bool]], season: QRSeason, seed: UInt64) {
        self.dark = dark; self.season = season; state = seed | 1
        n = dark.count; half = Float(n - 1) / 2
        model = QRGardenModel(size: n, margin: 2.5, dark: dark)
    }
    mutating func random() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float((state >> 33) & 0xffffff) / Float(0xffffff)
    }
    mutating func pick(_ colors: [SIMD3<Float>]) -> SIMD3<Float> { colors[min(colors.count - 1, Int(random() * Float(colors.count)))] }
    mutating func vary(_ c: SIMD3<Float>, _ amount: Float = 0.06) -> SIMD3<Float> {
        let k = 1 + (random() - 0.5) * 2 * amount
        return simd_clamp(c * k, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
    func position(_ row: Int, _ column: Int) -> (x: Float, z: Float) { (Float(column) - half, Float(row) - half) }
    /// A wobbly outline, so a canopy or a coast isn't a perfect circle.
    mutating func outline() -> (Float) -> Float {
        let p1 = random() * 6.28, p2 = random() * 6.28, p3 = random() * 6.28
        return { a in 1 + 0.09 * sin(3 * a + p1) + 0.06 * sin(5 * a + p2) + 0.04 * sin(8 * a + p3) }
    }

    mutating func slab(_ palette: Palette) {
        let extent = Float(n) + 2 * model.margin
        model.ground.append(QRVoxel(x: 0, z: 0, y0: -0.9, y1: 0, size: extent, color: palette.slab, depth: extent, side: palette.slabSide))
    }

    mutating func tiles(_ palette: Palette, skip: (Int, Int) -> Bool = { _, _ in false }) {
        for r in 0..<n { for c in 0..<n where !dark[r][c] && !skip(r, c) {
            let p = position(r, c)
            model.ground.append(QRVoxel(x: p.x, z: p.z, y0: 0, y1: 0.06 + random() * 0.04, size: 0.96, color: pick(palette.tiles)))
        } }
    }

    mutating func line(from a: SIMD3<Float>, to b: SIMD3<Float>, width: (Float) -> Float, color: SIMD3<Float>, step: Float = 0.35) {
        let length = simd_length(b - a), count = max(1, Int(length / step))
        for i in 0...count {
            let t = Float(i) / Float(count), p = a + (b - a) * t, w = width(t)
            model.structure.append(QRVoxel(x: p.x, z: p.z, y0: p.y - w / 2, y1: p.y + w / 2, size: w, color: vary(color, 0.05)))
        }
    }

    // MARK: Tree

    mutating func tree() {
        let leaves: [SIMD3<Float>], grass: [SIMD3<Float>], fallen: [SIMD3<Float>]
        switch season {
        case .spring:
            leaves = [rgb(0.86, 0.44, 0.58), rgb(0.78, 0.36, 0.52), rgb(0.90, 0.52, 0.64), rgb(0.70, 0.30, 0.46), rgb(0.40, 0.58, 0.26)]
            grass = [rgb(0.36, 0.58, 0.24), rgb(0.30, 0.52, 0.20), rgb(0.42, 0.62, 0.26)]
            fallen = [rgb(0.94, 0.66, 0.74), rgb(0.90, 0.58, 0.68)]
        case .summer:
            leaves = [rgb(0.27, 0.52, 0.18), rgb(0.33, 0.60, 0.20), rgb(0.20, 0.43, 0.15), rgb(0.40, 0.63, 0.22), rgb(0.16, 0.36, 0.14)]
            grass = [rgb(0.32, 0.56, 0.20), rgb(0.26, 0.48, 0.17), rgb(0.40, 0.62, 0.24)]
            fallen = []
        case .autumn:
            leaves = [rgb(0.84, 0.42, 0.10), rgb(0.76, 0.32, 0.09), rgb(0.88, 0.54, 0.14), rgb(0.64, 0.24, 0.10), rgb(0.70, 0.40, 0.10)]
            grass = [rgb(0.62, 0.48, 0.16), rgb(0.54, 0.42, 0.14), rgb(0.66, 0.52, 0.20)]
            fallen = [rgb(0.88, 0.50, 0.14), rgb(0.80, 0.36, 0.10)]
        }
        let palette = Palette(slab: rgb(0.93, 0.91, 0.87), slabSide: rgb(0.62, 0.56, 0.50),
                              tiles: [rgb(0.94, 0.93, 0.90), rgb(0.91, 0.90, 0.87), rgb(0.96, 0.95, 0.92), rgb(0.89, 0.88, 0.85)])
        slab(palette); tiles(palette)
        let size = Float(n), radius = size * 0.40, trunkTop = size * 0.27, dome = size * 0.46
        let wobble = outline()
        for r in 0..<n { for c in 0..<n {
            let p = position(r, c), d = (p.x * p.x + p.z * p.z).squareRoot(), a = atan2(p.z, p.x)
            let reach = radius * wobble(a)
            if d < reach {
                // Leaves over light modules fill the canopy out from the side and fade away from above.
                let filler = !dark[r][c]
                if filler && random() > 0.5 { continue }
                let t = d / reach
                let top = trunkTop + dome * (1 - t * t).squareRoot() * (0.82 + 0.18 * random()) + (filler ? -0.4 : 0.5)
                let bottom = trunkTop + dome * 0.2 * (1 - t) - 0.6
                let layers = max(1, Int(((top - bottom) * (filler ? 0.25 : 0.35 + 0.35 * random())).rounded()))
                for k in 0..<layers where k == 0 || random() > 0.22 {
                    let y1 = top - Float(k) * 1.02
                    let leaf = QRVoxel(x: p.x, z: p.z, y0: y1 - 0.92, y1: y1, size: k == 0 ? 0.94 : 0.9, color: vary(pick(leaves)))
                    if filler { model.structure.append(leaf) } else { model.cover.append(leaf) }
                }
            } else if dark[r][c] {
                let height = 0.3 + random() * 0.4
                model.cover.append(QRVoxel(x: p.x, z: p.z, y0: 0, y1: height, size: 0.94, color: vary(pick(grass))))
                for _ in 0..<(random() > 0.4 ? 2 : 1) {
                    model.cover.append(QRVoxel(x: p.x + (random() - 0.5) * 0.5, z: p.z + (random() - 0.5) * 0.5, y0: height,
                                               y1: height + 0.2 + random() * 0.45, size: 0.22, color: vary(pick(grass), 0.12)))
                }
            }
        } }
        // Trunk with a gentle curve, branches into the canopy, a few roots.
        let bend = random() * 6.28
        var p = SIMD3<Float>(0, 0, 0)
        let trunkHeight = trunkTop + dome * 0.35
        let trunk = rgb(0.45, 0.30, 0.19)
        let steps = Int(trunkHeight / 0.4)
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            p = SIMD3(0.6 * sin(t * 2.4 + bend) * t, t * trunkHeight, 0.5 * cos(t * 2.1 + bend) * t)
            let w = 1.25 - 0.55 * t
            model.structure.append(QRVoxel(x: p.x, z: p.z, y0: p.y - 0.25, y1: p.y + 0.25, size: w, color: vary(trunk, 0.06)))
        }
        for b in 0..<8 {
            let a = Float(b) / 8 * 6.28 + random() * 0.6, start = trunkTop * (0.7 + 0.3 * random())
            let from = SIMD3<Float>(0.6 * sin(start / trunkHeight * 2.4 + bend) * start / trunkHeight, start, 0.5 * cos(start / trunkHeight * 2.1 + bend) * start / trunkHeight)
            let reach = radius * (0.45 + 0.35 * random())
            let to = SIMD3<Float>(cos(a) * reach, trunkTop + dome * (0.25 + 0.3 * random()), sin(a) * reach)
            line(from: from, to: to, width: { 0.6 - 0.35 * $0 }, color: trunk)
        }
        for b in 0..<5 {
            let a = Float(b) / 5 * 6.28 + random()
            line(from: SIMD3(0, 0.5, 0), to: SIMD3(cos(a) * 2.2, 0.08, sin(a) * 2.2), width: { 0.55 - 0.3 * $0 }, color: trunk)
        }
        for _ in 0..<(fallen.isEmpty ? 0 : n * 2) {
            let r = Int(random() * Float(n)), c = Int(random() * Float(n))
            guard !dark[r][c] else { continue }
            let q = position(r, c)
            model.structure.append(QRVoxel(x: q.x + (random() - 0.5) * 0.6, z: q.z + (random() - 0.5) * 0.6, y0: 0.08, y1: 0.13,
                                           size: 0.28, color: pick(fallen)))
        }
    }

    // MARK: Bouquet

    mutating func bouquet() {
        let flowers: [SIMD3<Float>]
        switch season {
        case .spring: flowers = [rgb(0.86, 0.40, 0.56), rgb(0.92, 0.50, 0.42), rgb(0.74, 0.30, 0.50), rgb(0.94, 0.58, 0.30), rgb(0.80, 0.42, 0.70)]
        case .summer: flowers = [rgb(0.36, 0.42, 0.80), rgb(0.56, 0.38, 0.78), rgb(0.30, 0.56, 0.82), rgb(0.82, 0.36, 0.52), rgb(0.94, 0.66, 0.16)]
        case .autumn: flowers = [rgb(0.62, 0.16, 0.24), rgb(0.86, 0.44, 0.14), rgb(0.86, 0.62, 0.16), rgb(0.48, 0.18, 0.32), rgb(0.74, 0.30, 0.18)]
        }
        let leaves = [rgb(0.28, 0.50, 0.26), rgb(0.22, 0.42, 0.24), rgb(0.36, 0.56, 0.30)]
        let palette = Palette(slab: rgb(0.95, 0.93, 0.91), slabSide: rgb(0.78, 0.70, 0.64),
                              tiles: [rgb(0.96, 0.94, 0.92), rgb(0.94, 0.92, 0.90), rgb(0.97, 0.95, 0.94)])
        slab(palette); tiles(palette)
        let size = Float(n), radius = size * 0.38, base = size * 0.40, dome = size * 0.26
        // Flower heads: each module belongs to its nearest bloom, so neighbours share a colour and a rounded top.
        var blooms: [(x: Float, z: Float, color: SIMD3<Float>, leaf: Bool)] = []
        let count = max(8, Int(Float.pi * radius * radius / 12))
        for _ in 0..<count * 4 where blooms.count < count {
            let a = random() * 6.28, d = random().squareRoot() * radius
            let x = cos(a) * d, z = sin(a) * d
            guard blooms.allSatisfy({ ($0.x - x) * ($0.x - x) + ($0.z - z) * ($0.z - z) > 6 }) else { continue }
            let leaf = random() < 0.18
            blooms.append((x, z, leaf ? pick(leaves) : pick(flowers), leaf))
        }
        let wobble = outline()
        for r in 0..<n { for c in 0..<n {
            let p = position(r, c), d = (p.x * p.x + p.z * p.z).squareRoot(), a = atan2(p.z, p.x)
            let reach = radius * wobble(a)
            if d < reach, let bloom = blooms.min(by: { hypot($0.x - p.x, $0.z - p.z) < hypot($1.x - p.x, $1.z - p.z) }) {
                // Petals over light modules round the blooms out from the side and fade away from above.
                let filler = !dark[r][c]
                if filler && random() > 0.55 { continue }
                let t = d / reach, bd = hypot(bloom.x - p.x, bloom.z - p.z)
                let top = base + dome * (1 - t * t).squareRoot() + max(0, 1.3 - bd * 0.5) + random() * 0.25 - (filler ? 0.6 : 0)
                let petal = bloom.leaf ? bloom.color : bloom.color * (1 - min(0.22, bd * 0.06))
                var voxels = [QRVoxel(x: p.x, z: p.z, y0: top - 0.9, y1: top, size: 0.94, color: vary(petal, 0.05)),
                              QRVoxel(x: p.x, z: p.z, y0: top - 2.0, y1: top - 1.0, size: 0.86, color: vary(pick(leaves)))]
                if !bloom.leaf, !filler, bd < 0.8 {  // a raised centre in each bloom
                    voxels.append(QRVoxel(x: p.x, z: p.z, y0: top, y1: top + 0.35, size: 0.5, color: vary(bloom.color * 0.7, 0.04)))
                }
                if filler { model.structure += voxels } else { model.cover += voxels }
            } else if dark[r][c] {
                // Petals and leaves dropped on the table.
                let height = 0.12 + random() * 0.18
                model.cover.append(QRVoxel(x: p.x, z: p.z, y0: 0, y1: height, size: 0.94,
                                           color: vary(random() < 0.55 ? pick(leaves) : pick(flowers))))
            }
        } }
        // Stems gathered at a ribbon, wrapped in paper that opens toward the viewer.
        let knot = SIMD3<Float>(0, size * 0.13, 0)
        for bloom in blooms {
            line(from: SIMD3(bloom.x * 0.75, base - 1, bloom.z * 0.75), to: knot, width: { _ in 0.3 }, color: rgb(0.32, 0.52, 0.24), step: 0.5)
            line(from: knot, to: SIMD3(bloom.x * 0.08, 0.1, bloom.z * 0.08), width: { _ in 0.3 }, color: rgb(0.30, 0.48, 0.22), step: 0.5)
        }
        let kraft = rgb(0.80, 0.64, 0.46), tissue = rgb(0.97, 0.90, 0.88)
        let low = size * 0.10, high = base + dome * 0.5, steps = Int((high - low) / 0.55)
        for i in 0...steps {
            let t = Float(i) / Float(steps), y = low + (high - low) * t
            let ring = 1.3 + (radius * 0.96 - 1.3) * pow(t, 0.8)
            let around = max(8, Int(ring * 6.28 / 0.6))
            for j in 0..<around {
                let a = Float(j) / Float(around) * 6.28
                var gap = a - 0.785; gap = atan2(sin(gap), cos(gap))  // open toward +x +z
                // The paper rises behind the flowers and opens wider toward the viewer as it climbs.
                if abs(gap) < 0.25 + 1.9 * max(0, t - 0.35) { continue }
                let rim = i == steps || abs(abs(gap) - (0.25 + 1.9 * max(0, t - 0.35))) < 0.12
                let color = rim ? rgb(0.88, 0.76, 0.60) : kraft
                model.structure.append(QRVoxel(x: cos(a) * ring, z: sin(a) * ring, y0: y - 0.3, y1: y + 0.3, size: 0.62, color: vary(color, 0.04)))
                if t > 0.7, j % 2 == 0 {
                    model.structure.append(QRVoxel(x: cos(a) * (ring - 0.5), z: sin(a) * (ring - 0.5), y0: y, y1: y + 0.6, size: 0.5, color: vary(tissue, 0.02)))
                }
            }
        }
        let ribbon = season == .summer ? rgb(0.30, 0.38, 0.70) : rgb(0.72, 0.18, 0.26)
        for j in 0..<16 {
            let a = Float(j) / 16 * 6.28
            model.structure.append(QRVoxel(x: cos(a) * 1.6, z: sin(a) * 1.6, y0: knot.y - 0.3, y1: knot.y + 0.4, size: 0.55, color: ribbon))
        }
        for side: Float in [-1, 1] {
            line(from: SIMD3(1.2, knot.y, 1.2), to: SIMD3(1.9 + side * 1.2, knot.y + 1.1, 1.9 - side * 1.2), width: { _ in 0.5 }, color: ribbon)
            line(from: SIMD3(1.2, knot.y, 1.2), to: SIMD3(1.6 + side * 0.6, knot.y - 2.0, 1.6 - side * 0.6), width: { _ in 0.4 }, color: ribbon)
        }
    }

    // MARK: Island

    mutating func island() {
        let green: [SIMD3<Float>], fronds: [SIMD3<Float>]
        switch season {
        case .spring:
            green = [rgb(0.36, 0.60, 0.28), rgb(0.30, 0.54, 0.26), rgb(0.44, 0.64, 0.30), rgb(0.70, 0.40, 0.56)]
            fronds = [rgb(0.30, 0.58, 0.24), rgb(0.38, 0.64, 0.26)]
        case .summer:
            green = [rgb(0.18, 0.50, 0.26), rgb(0.24, 0.56, 0.24), rgb(0.14, 0.42, 0.24), rgb(0.30, 0.58, 0.22)]
            fronds = [rgb(0.20, 0.52, 0.22), rgb(0.28, 0.58, 0.20)]
        case .autumn:
            green = [rgb(0.50, 0.50, 0.20), rgb(0.62, 0.46, 0.16), rgb(0.42, 0.44, 0.18), rgb(0.72, 0.38, 0.14)]
            fronds = [rgb(0.46, 0.50, 0.18), rgb(0.56, 0.52, 0.18)]
        }
        let reef = [rgb(0.14, 0.40, 0.46), rgb(0.12, 0.34, 0.42), rgb(0.20, 0.46, 0.50), rgb(0.30, 0.34, 0.38)]
        let water = [rgb(0.80, 0.92, 0.95), rgb(0.84, 0.94, 0.96), rgb(0.77, 0.90, 0.94)]
        let sand = rgb(0.95, 0.89, 0.74), stone = rgb(0.92, 0.90, 0.85), earth = rgb(0.56, 0.42, 0.28)
        let palette = Palette(slab: rgb(0.80, 0.92, 0.95), slabSide: rgb(0.32, 0.58, 0.72), tiles: water)
        slab(palette)
        let size = Float(n), radius = size * 0.40, peak = size * 0.16
        let wobble = outline()
        var heights = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for r in 0..<n { for c in 0..<n {
            let p = position(r, c), d = (p.x * p.x + p.z * p.z).squareRoot(), a = atan2(p.z, p.x)
            let reach = radius * wobble(a)
            if d < reach {
                let t = d / reach, h = 0.35 + peak * pow(1 - t, 1.4)
                heights[r][c] = h
                if dark[r][c] {
                    model.ground.append(QRVoxel(x: p.x, z: p.z, y0: 0, y1: h, size: 1, color: vary(pick(green)), side: vary(earth, 0.08)))
                    let bush = random() > 0.35 ? 0.3 + random() * 0.7 : 0.12
                    model.cover.append(QRVoxel(x: p.x, z: p.z, y0: h, y1: h + bush, size: 0.94, color: vary(pick(green))))
                } else {
                    model.ground.append(QRVoxel(x: p.x, z: p.z, y0: 0, y1: h, size: 1, color: vary(h < 0.35 + peak * 0.3 ? sand : stone, 0.03)))
                }
            } else if dark[r][c] {
                model.cover.append(QRVoxel(x: p.x, z: p.z, y0: 0, y1: 0.18 + random() * 0.35, size: 0.94, color: vary(pick(reef))))
            } else {
                model.ground.append(QRVoxel(x: p.x, z: p.z, y0: 0, y1: 0.04 + random() * 0.05, size: 0.96, color: pick(water)))
            }
        } }
        // Palms: fronds lie over dark modules only; trunks and coconuts fade away from above.
        let trunk = rgb(0.58, 0.44, 0.28)
        let palms: [(x: Float, z: Float, height: Float, reach: Float)] = [
            (-size * 0.04, size * 0.02, size * 0.42, size * 0.20),
            (size * 0.18, -size * 0.12, size * 0.28, size * 0.13),
            (-size * 0.16, -size * 0.18, size * 0.22, size * 0.11),
        ]
        for palm in palms {
            let groundRow = min(n - 1, max(0, Int((palm.z + half).rounded()))), groundColumn = min(n - 1, max(0, Int((palm.x + half).rounded())))
            let foot = SIMD3<Float>(palm.x, heights[groundRow][groundColumn], palm.z)
            let lean = random() * 6.28
            let crown = foot + SIMD3(cos(lean) * palm.height * 0.18, palm.height, sin(lean) * palm.height * 0.18)
            let mid = (foot + crown) / 2 + SIMD3(cos(lean) * 0.6, 0, sin(lean) * 0.6)
            line(from: foot, to: mid, width: { 0.75 - 0.1 * $0 }, color: trunk, step: 0.3)
            line(from: mid, to: crown, width: { 0.65 - 0.15 * $0 }, color: trunk, step: 0.3)
            for k in 0..<3 {
                let a = Float(k) * 2.1
                model.structure.append(QRVoxel(x: crown.x + cos(a) * 0.45, z: crown.z + sin(a) * 0.45, y0: crown.y - 0.9, y1: crown.y - 0.35,
                                               size: 0.5, color: rgb(0.42, 0.30, 0.16)))
            }
            let arms = 7, turn = random() * 6.28
            for r in 0..<n { for c in 0..<n {
                let p = position(r, c), dx = p.x - crown.x, dz = p.z - crown.z, d = hypot(dx, dz)
                guard d < palm.reach else { continue }
                var off = atan2(dz, dx) - turn
                off = off - (off / (6.28 / Float(arms))).rounded() * (6.28 / Float(arms))
                guard d < 1.6 || abs(off) * d < 1.1 else { continue }
                let y = crown.y + 0.5 - 2.6 * pow(d / palm.reach, 2) * palm.height / (size * 0.42)
                guard y > heights[r][c] + 1.2 else { continue }
                let frond = QRVoxel(x: p.x, z: p.z, y0: y - 0.45, y1: y, size: 0.94, color: vary(pick(fronds)))
                if dark[r][c] { model.cover.append(frond) } else { model.structure.append(frond) }
            }}
        }
        // A small boat on the water.
        let boatX = size * 0.36, boatZ = size * 0.42
        for i in 0..<4 {
            model.structure.append(QRVoxel(x: boatX - 1.2 + Float(i) * 0.8, z: boatZ, y0: 0.1, y1: 0.6, size: 0.8, color: rgb(0.70, 0.40, 0.26)))
        }
        line(from: SIMD3(boatX, 0.6, boatZ), to: SIMD3(boatX, 3.4, boatZ), width: { _ in 0.18 }, color: rgb(0.40, 0.28, 0.18))
        for k in 0..<5 {
            let w = 1.8 - Float(k) * 0.32
            model.structure.append(QRVoxel(x: boatX - w / 2 - 0.15, z: boatZ, y0: 1.0 + Float(k) * 0.5, y1: 1.5 + Float(k) * 0.5,
                                           size: w, color: rgb(0.98, 0.97, 0.94), depth: 0.12))
        }
    }
}

// MARK: - Geometry

enum QRGardenGeometry {
    /// Faces are flat-shaded once here (the light comes from the upper left), so the top faces keep their exact colour
    /// and the scene needs no lights. Side faces darken toward the ground for a little depth.
    static func make(_ boxes: [QRVoxel]) -> SCNGeometry {
        var positions: [SIMD3<Float>] = [], colors: [SIMD4<Float>] = [], indices: [UInt32] = []
        positions.reserveCapacity(boxes.count * 20); colors.reserveCapacity(boxes.count * 20); indices.reserveCapacity(boxes.count * 30)
        func linear(_ c: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(c.x <= 0.04045 ? c.x / 12.92 : pow((c.x + 0.055) / 1.055, 2.4),
                  c.y <= 0.04045 ? c.y / 12.92 : pow((c.y + 0.055) / 1.055, 2.4),
                  c.z <= 0.04045 ? c.z / 12.92 : pow((c.z + 0.055) / 1.055, 2.4))
        }
        for b in boxes {
            let hx = b.size / 2, hz = (b.depth ?? b.size) / 2
            let x0 = b.x - hx, x1 = b.x + hx, z0 = b.z - hz, z1 = b.z + hz, y0 = b.y0, y1 = b.y1
            let top = linear(b.color), side = linear(b.side ?? b.color)
            // Linear colour scales linearly, so each face's shade is applied after one conversion per box.
            let floor: Float = b.y1 - b.y0 > 1.5 ? 0.86 : 0.93, floorLinear = pow(floor, 2.2)
            func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ color: SIMD3<Float>, lower: Float) {
                let base = UInt32(positions.count)
                positions.append(a); positions.append(b); positions.append(c); positions.append(d)
                let low = SIMD4(color * lower, 1), high = SIMD4(color, 1)
                colors.append(low); colors.append(low); colors.append(high); colors.append(high)
                indices.append(base); indices.append(base + 1); indices.append(base + 2)
                indices.append(base); indices.append(base + 2); indices.append(base + 3)
            }
            quad(SIMD3(x0, y1, z1), SIMD3(x1, y1, z1), SIMD3(x1, y1, z0), SIMD3(x0, y1, z0), top, lower: 1)
            quad(SIMD3(x0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1), side * pow(0.86, 2.2), lower: floorLinear)
            quad(SIMD3(x1, y0, z1), SIMD3(x1, y0, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), side * pow(0.70, 2.2), lower: floorLinear)
            quad(SIMD3(x0, y0, z0), SIMD3(x0, y0, z1), SIMD3(x0, y1, z1), SIMD3(x0, y1, z0), side * pow(0.78, 2.2), lower: floorLinear)
            quad(SIMD3(x1, y0, z0), SIMD3(x0, y0, z0), SIMD3(x0, y1, z0), SIMD3(x1, y1, z0), side * pow(0.90, 2.2), lower: floorLinear)
        }
        let vertexData = positions.withUnsafeBytes { Data($0) }, colorData = colors.withUnsafeBytes { Data($0) }
        let vertices = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: positions.count, usesFloatComponents: true,
                                         componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let vertexColors = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                             componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertices, vertexColors], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        geometry.materials = [material]
        return geometry
    }
}

// MARK: - View

/// The library's picture of a code: a small voxel scene grown from the code's modules. A click turns the camera from
/// a three-quarter view to straight above, where the leaves, flowers or land line up into the scannable code.
@MainActor
final class QRGardenView: NSView {
    private(set) var entry: SavedQRCode?
    private let scnView = SCNView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private var groundNode = SCNNode(), coverNode = SCNNode(), structureNode = SCNNode()
    /// Points that bound what the camera must keep in frame.
    private var hull: [SIMD3<Float>] = []
    private var flip = Spring(0, response: 0.75, damping: 1)
    private var grow = Spring(1, response: 0.7, damping: 0.78)
    private lazy var driver: FrameDriver = {
        let driver = FrameDriver(view: self)
        driver.onFrame = { [weak self] dt in
            guard let self else { return false }
            let tuning = Prefs.interaction.tools
            if Motion.reduced { self.flip.snap(self.flip.target); self.grow.snap(self.grow.target) }
            else { self.flip.step(dt, tuning: tuning); self.grow.step(dt, tuning: tuning) }
            self.apply()
            let moving = !self.flip.isSettled || !self.grow.isSettled
            self.scnView.isPlaying = moving
            return moving
        }
        return driver
    }()
    var showsCode: Bool { flip.target == 1 }
    var onToggle: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { entry != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(L("Show QR code or scene"))
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.zNear = 1; camera.zFar = 2000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        for node in [groundNode, coverNode, structureNode] { scene.rootNode.addChildNode(node) }
        scene.background.contents = NSColor.clear
        scnView.scene = scene
        scnView.pointOfView = cameraNode
        scnView.backgroundColor = .clear
        scnView.antialiasingMode = .multisampling4X
        scnView.rendersContinuously = false
        scnView.preferredFramesPerSecond = 120
        scnView.autoresizingMask = [.width, .height]
        scnView.frame = bounds.insetBy(dx: 8, dy: 8)
        addSubview(scnView)
    }
    required init?(coder: NSCoder) { fatalError() }

    func display(_ entry: SavedQRCode?) throws {
        let previous = self.entry
        // Built before anything changes, so a code that can't be generated leaves the view as it was.
        let model = try entry.map { QRGardenModel.build(try QRModules.matrix($0.value), template: $0.template, season: $0.season,
                                                         seed: Self.seed($0.value) ^ Self.seed($0.template.rawValue)) }
        self.entry = entry
        setAccessibilityElement(entry != nil)
        install(model)
        guard let entry else { return }
        flip.snap(0)
        // A new code (or a new template) grows in; a season change just recolours.
        if previous?.id != entry.id || previous?.template != entry.template { grow.snap(0); grow.target = 1 } else { grow.snap(1) }
        apply()
        if window != nil, !Motion.reduced { driver.start() } else { grow.snap(1); apply() }
    }

    private func install(_ model: QRGardenModel?) {
        let nodes = [groundNode, coverNode, structureNode]
        for node in nodes { node.geometry = nil }
        hull = []
        guard let model else { scnView.isHidden = true; return }
        scnView.isHidden = false
        groundNode.geometry = QRGardenGeometry.make(model.ground)
        coverNode.geometry = QRGardenGeometry.make(model.cover)
        structureNode.geometry = QRGardenGeometry.make(model.structure)
        let edge = Float(model.size) / 2 + model.margin
        hull = [-edge, edge].flatMap { x in [-edge, edge].flatMap { z in [SIMD3(x, 0, z), SIMD3(x, -0.9, z)] } }
        for v in model.cover + model.structure { hull.append(SIMD3(v.x, v.y1, v.z)) }
    }

    func setShowsCode(_ value: Bool) {
        flip.target = value ? 1 : 0
        if Motion.reduced || window == nil { flip.snap(flip.target); apply() } else { driver.start() }
        onToggle?(value)
    }

    /// Camera, fade and growth for the current spring values.
    private func apply() {
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        let phase = Float(min(1, max(0, flip.value)))
        let eased = phase * phase * (3 - 2 * phase)
        coverNode.scale = SCNVector3(1, max(0.001, grow.value), 1)
        structureNode.scale = coverNode.scale
        structureNode.opacity = CGFloat(1 - Self.smoothstep(0.45, 0.9, phase))
        let size = scnView.bounds.size == .zero ? CGSize(width: 600, height: 450) : scnView.bounds.size
        cameraNode.simdOrientation = Self.orientation(eased)
        frameCamera(aspect: Float(size.width / max(1, size.height)), padding: 1.06 - 0.02 * eased)
        SCNTransaction.commit()
    }

    static func orientation(_ t: Float) -> simd_quatf {
        let elevation = (32 + 58 * t) * .pi / 180, azimuth = 45 * (1 - t) * .pi / 180
        return simd_quatf(angle: azimuth, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: -elevation, axis: SIMD3(1, 0, 0))
    }
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }

    private func frameCamera(aspect: Float, padding: Float) {
        let q = cameraNode.simdOrientation
        let right = q.act(SIMD3(1, 0, 0)), up = q.act(SIMD3(0, 1, 0)), forward = q.act(SIMD3(0, 0, -1))
        var minR = Float.infinity, maxR = -Float.infinity, minU = Float.infinity, maxU = -Float.infinity
        let grown = Float(max(0.001, grow.value))
        for p in hull {
            let point = SIMD3(p.x, p.y > 0 ? p.y * max(grown, 1) : p.y, p.z)
            let r = simd_dot(point, right), u = simd_dot(point, up)
            minR = min(minR, r); maxR = max(maxR, r); minU = min(minU, u); maxU = max(maxU, u)
        }
        guard minR.isFinite else { return }
        let center = right * (minR + maxR) / 2 + up * (minU + maxU) / 2
        cameraNode.simdPosition = center - forward * 500
        cameraNode.camera?.orthographicScale = Double(max((maxU - minU) / 2, (maxR - minR) / 2 / aspect) * padding)
    }

    /// Renders the scene offscreen, at rest in either view (for checks and exports).
    func snapshot(size: CGSize, showsCode: Bool) -> NSImage { snapshot(size: size, phase: showsCode ? 1 : 0) }
    /// `phase` runs from the three-quarter view (0) to straight above (1).
    func snapshot(size: CGSize, phase: CGFloat) -> NSImage {
        let saved = (flip, grow)
        flip.snap(phase); grow.snap(1)
        let frame = scnView.frame
        scnView.frame = CGRect(origin: .zero, size: size)
        apply()
        let renderer = SCNRenderer(device: scnView.device ?? MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene; renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        scnView.frame = frame
        (flip, grow) = saved
        apply()
        return image
    }

    override func layout() { super.layout(); scnView.frame = bounds.insetBy(dx: 8, dy: 8); apply() }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); toggle() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { toggle() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { toggle(); return true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { driver.stop(); flip.snap(flip.target); grow.snap(grow.target); apply() }
    }
    private func toggle() { guard entry != nil else { return }; Feedback.press(); setShowsCode(!showsCode) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    static func seed(_ text: String) -> UInt64 { text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 } }
}
