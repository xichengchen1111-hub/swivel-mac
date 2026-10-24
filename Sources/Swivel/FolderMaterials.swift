import AppKit
import CoreText

/// Surfaces a folder can be made of, drawn here from scratch (no bundled artwork): each fills a square and is then
/// cut to the folder's shape and shaded by `FolderIcons.shaded`, so the tab, front and highlights still read.
enum FolderMaterial: String, CaseIterable, Codable, Sendable {
    case plain, kraft, chalkboard, wood, leather, denim, marble, holographic, sunset, neon, blueprint, poster,
         banknote, film, moss, camo, terrazzo, gingham, candy, dots, galaxy, notebook, metal, emojiPattern

    var title: String {
        switch self {
        case .plain: "Plain"
        case .kraft: "Kraft Paper"
        case .chalkboard: "Chalkboard"
        case .wood: "Wood"
        case .leather: "Leather"
        case .denim: "Denim"
        case .marble: "Marble"
        case .holographic: "Holographic"
        case .sunset: "Sunset"
        case .neon: "Neon Grid"
        case .blueprint: "Blueprint"
        case .poster: "Retro Poster"
        case .banknote: "Banknote"
        case .film: "Film Strip"
        case .moss: "Moss"
        case .camo: "Camouflage"
        case .terrazzo: "Terrazzo"
        case .gingham: "Gingham"
        case .candy: "Candy Stripes"
        case .dots: "Polka Dots"
        case .galaxy: "Galaxy"
        case .notebook: "Notebook"
        case .metal: "Brushed Metal"
        case .emojiPattern: "Emoji Pattern"
        }
    }

    /// Whether the editor's colour applies (as the material's own colour).
    var usesTint: Bool { self == .plain || self == .emojiPattern || self == .dots || self == .candy || self == .gingham }

    /// How text is lettered on this material: font name, size factor and colour.
    var lettering: (font: String, scale: CGFloat, color: CGColor) {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 0.92) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        return switch self {
        case .chalkboard: ("ChalkboardSE-Bold", 1, c(0.97, 0.97, 0.93))
        case .poster: ("Futura-CondensedExtraBold", 1.15, c(0.82, 0.2, 0.12))
        case .blueprint, .neon: ("Menlo-Bold", 0.85, self == .neon ? c(1, 0.45, 0.9) : c(1, 1, 1))
        case .banknote: ("Didot-Bold", 0.95, c(0.15, 0.35, 0.2))
        case .kraft, .notebook: ("MarkerFelt-Wide", 1, c(0.18, 0.16, 0.14))
        case .leather, .wood: ("AvenirNext-Heavy", 0.95, c(0.98, 0.9, 0.75))
        case .marble, .terrazzo, .holographic, .metal: ("AvenirNext-DemiBold", 0.95, c(0.2, 0.2, 0.22))
        case .film, .galaxy, .denim, .moss, .camo: ("AvenirNext-Heavy", 0.95, c(1, 1, 1))
        default: ("AvenirNext-Heavy", 0.95, c(1, 1, 1))
        }
    }

    /// The square surface, `size` pixels, before shading. `tint` is the editor's colour when `usesTint`.
    func draw(size: Int, tint: (r: Double, g: Double, b: Double)?, emoji: String) -> CGImage? {
        guard let ctx = FolderIcons.context(size) else { return nil }
        let s = CGFloat(size)
        var rng = SeededRandom(seed: rawValue.unicodeScalars.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1.value) })
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        func fill(_ color: CGColor) { ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s)) }
        func r(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &rng) }
        func gradient(_ colors: [CGColor], from: CGPoint, to: CGPoint) {
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let tinted = tint.map { rgb($0.r, $0.g, $0.b) }
        // The front of the folder (bottom-left origin), where stitching and frames go.
        let front = CGRect(x: s * 0.06, y: s * 0.14, width: s * 0.88, height: s * 0.58)

        switch self {
        case .plain:
            fill(tinted ?? rgb(0.35, 0.65, 0.95))
        case .kraft:
            fill(rgb(0.77, 0.62, 0.43))
            for _ in 0..<900 {
                ctx.setStrokeColor(r(0...1) < 0.5 ? rgb(0.45, 0.32, 0.2, 0.12) : rgb(1, 0.95, 0.85, 0.12))
                ctx.setLineWidth(r(0.6...1.6) * s / 512)
                let p = CGPoint(x: r(0...s), y: r(0...s)), a = r(0...(2 * .pi)), l = r(4...22) * s / 512
                ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x + cos(a) * l, y: p.y + sin(a) * l)); ctx.strokePath()
            }
            Self.grain(ctx, size: size, amount: 0.07, rng: &rng)
        case .chalkboard:
            fill(rgb(0.17, 0.29, 0.24))
            for _ in 0..<40 {
                ctx.setFillColor(rgb(1, 1, 1, r(0.015...0.04)))
                ctx.fillEllipse(in: CGRect(x: r(-0.2...1) * s, y: r(-0.2...1) * s, width: r(0.15...0.5) * s, height: r(0.05...0.2) * s))
            }
            Self.grain(ctx, size: size, amount: 0.06, rng: &rng)
            ctx.setStrokeColor(rgb(0.55, 0.38, 0.22)); ctx.setLineWidth(s * 0.025)
            ctx.stroke(front.insetBy(dx: s * 0.012, dy: s * 0.012))
        case .wood:
            fill(rgb(0.63, 0.43, 0.26))
            var y: CGFloat = 0
            while y < s {
                ctx.setStrokeColor(rgb(0.36, 0.22, 0.12, r(0.12...0.35)))
                ctx.setLineWidth(r(1...5) * s / 512)
                ctx.move(to: CGPoint(x: 0, y: y))
                let phase = r(0...6), amp = r(2...9) * s / 512, freq = r(1.5...4)
                for x in stride(from: CGFloat(0), through: s, by: s / 64) {
                    ctx.addLine(to: CGPoint(x: x, y: y + sin(x / s * freq * .pi + phase) * amp))
                }
                ctx.strokePath()
                y += r(4...14) * s / 512
            }
            Self.grain(ctx, size: size, amount: 0.04, rng: &rng)
        case .leather:
            fill(rgb(0.46, 0.27, 0.16))
            Self.grain(ctx, size: size, amount: 0.12, rng: &rng)
            Self.stitch(ctx, front.insetBy(dx: s * 0.035, dy: s * 0.035), color: rgb(0.95, 0.85, 0.65, 0.9), s: s)
        case .denim:
            fill(rgb(0.22, 0.36, 0.58))
            ctx.setStrokeColor(rgb(0.75, 0.82, 0.95, 0.13)); ctx.setLineWidth(s / 340)
            for i in stride(from: -s, through: s, by: s / 110) {
                ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i + s, y: s)); ctx.strokePath()
            }
            Self.grain(ctx, size: size, amount: 0.09, rng: &rng)
            Self.stitch(ctx, front.insetBy(dx: s * 0.035, dy: s * 0.035), color: rgb(0.93, 0.6, 0.25, 0.95), s: s)
        case .marble:
            fill(rgb(0.95, 0.94, 0.92))
            // A few long veins running corner to corner, each a soft band with a fine line through it.
            for i in 0..<5 {
                let start = CGPoint(x: -0.1 * s, y: r(0.1...0.9) * s), end = CGPoint(x: 1.1 * s, y: r(0.1...0.9) * s)
                let c1 = CGPoint(x: r(0.2...0.45) * s, y: r(0...1) * s), c2 = CGPoint(x: r(0.55...0.8) * s, y: r(0...1) * s)
                for (width, alpha) in [(r(10...22), 0.06), (r(3...6), 0.12), (r(0.8...1.6), i < 2 ? 0.45 : 0.28)] {
                    ctx.setStrokeColor(rgb(0.5, 0.5, 0.53, alpha))
                    ctx.setLineWidth(width * s / 512)
                    ctx.move(to: start); ctx.addCurve(to: end, control1: c1, control2: c2); ctx.strokePath()
                }
            }
            Self.grain(ctx, size: size, amount: 0.02, rng: &rng)
        case .holographic:
            gradient([rgb(1, 0.72, 0.85), rgb(0.78, 0.72, 1), rgb(0.6, 0.9, 1), rgb(0.7, 1, 0.85), rgb(1, 0.88, 0.7)],
                     from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            ctx.setFillColor(rgb(1, 1, 1, 0.25))
            ctx.move(to: CGPoint(x: s * 0.2, y: 0)); ctx.addLine(to: CGPoint(x: s * 0.45, y: 0))
            ctx.addLine(to: CGPoint(x: s * 0.85, y: s)); ctx.addLine(to: CGPoint(x: s * 0.6, y: s)); ctx.fillPath()
        case .sunset:
            gradient([rgb(0.42, 0.2, 0.6), rgb(0.93, 0.36, 0.5), rgb(1, 0.62, 0.3)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: s))
            ctx.setFillColor(rgb(1, 0.9, 0.55, 0.85))
            ctx.fillEllipse(in: CGRect(x: s * 0.6, y: s * 0.45, width: s * 0.22, height: s * 0.22))
        case .neon:
            fill(rgb(0.07, 0.05, 0.13))
            ctx.setStrokeColor(rgb(1, 0.25, 0.85, 0.55)); ctx.setLineWidth(s / 256)
            let horizon = s * 0.62
            for i in 0...12 {  // perspective lines toward a vanishing point
                let x = s * CGFloat(i) / 12
                ctx.move(to: CGPoint(x: s / 2 + (x - s / 2) * 0.12, y: horizon)); ctx.addLine(to: CGPoint(x: (x - s / 2) * 2.4 + s / 2, y: 0)); ctx.strokePath()
            }
            var y = horizon, step = s * 0.02
            while y > 0 { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: s, y: y)); ctx.strokePath(); y -= step; step *= 1.35 }
            ctx.setStrokeColor(rgb(0.3, 0.95, 1, 0.9)); ctx.setLineWidth(s / 128)
            ctx.move(to: CGPoint(x: 0, y: horizon)); ctx.addLine(to: CGPoint(x: s, y: horizon)); ctx.strokePath()
        case .blueprint:
            fill(rgb(0.12, 0.33, 0.62))
            for (step, alpha) in [(s / 32, 0.12), (s / 8, 0.28)] {
                ctx.setStrokeColor(rgb(1, 1, 1, alpha)); ctx.setLineWidth(s / 600 * (alpha > 0.2 ? 2 : 1))
                for v in stride(from: CGFloat(0), through: s, by: step) {
                    ctx.move(to: CGPoint(x: v, y: 0)); ctx.addLine(to: CGPoint(x: v, y: s))
                    ctx.move(to: CGPoint(x: 0, y: v)); ctx.addLine(to: CGPoint(x: s, y: v))
                }
                ctx.strokePath()
            }
        case .poster:
            fill(rgb(0.96, 0.9, 0.78))
            let step = s / 36
            for row in 0...36 {
                for col in 0...36 {
                    let x = CGFloat(col) * step + (row % 2 == 0 ? 0 : step / 2), y = CGFloat(row) * step
                    let d = step * 0.9 * max(0, 1 - (x + (s - y)) / (s * 1.4))
                    guard d > 0.5 else { continue }
                    ctx.setFillColor(rgb(0.95, 0.42, 0.18, 0.9))
                    ctx.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
                }
            }
        case .banknote:
            fill(rgb(0.82, 0.89, 0.77))
            ctx.setLineWidth(s / 700)
            for i in 0..<28 {
                ctx.setStrokeColor(rgb(0.2, 0.45, 0.3, 0.22))
                let phase = CGFloat(i) * 0.4
                ctx.move(to: CGPoint(x: 0, y: s / 2))
                for x in stride(from: CGFloat(0), through: s, by: s / 128) {
                    ctx.addLine(to: CGPoint(x: x, y: s / 2 + sin(x / s * 6 * .pi + phase) * s * 0.18 * cos(x / s * 2 * .pi + phase / 3)))
                }
                ctx.strokePath()
            }
            ctx.setStrokeColor(rgb(0.2, 0.45, 0.3, 0.5)); ctx.setLineWidth(s / 160)
            ctx.stroke(front.insetBy(dx: s * 0.03, dy: s * 0.03))
        case .film:
            fill(rgb(0.1, 0.1, 0.11))
            let hole = s * 0.04, gap = s * 0.075
            for y in [front.maxY - s * 0.07, front.minY + s * 0.03] {
                for x in stride(from: s * 0.06, to: s * 0.94, by: gap) {
                    ctx.setFillColor(rgb(0.92, 0.92, 0.9, 0.95))
                    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: hole, height: hole * 0.9), cornerWidth: hole * 0.2, cornerHeight: hole * 0.2, transform: nil))
                    ctx.fillPath()
                }
            }
            for i in 0..<3 {
                let w = front.width * 0.28
                ctx.setFillColor(rgb(0.3, 0.32, 0.36, 0.9))
                ctx.fill(CGRect(x: front.minX + s * 0.04 + CGFloat(i) * (w + s * 0.02), y: front.minY + s * 0.12, width: w, height: front.height - s * 0.24))
            }
        case .moss:
            gradient([rgb(0.22, 0.42, 0.2), rgb(0.42, 0.6, 0.28)], from: CGPoint(x: 0, y: 0), to: CGPoint(x: s, y: s))
            for _ in 0..<220 {
                ctx.setFillColor(r(0...1) < 0.5 ? rgb(0.15, 0.32, 0.12, 0.25) : rgb(0.65, 0.8, 0.4, 0.2))
                let d = r(6...30) * s / 512
                ctx.fillEllipse(in: CGRect(x: r(0...s), y: r(0...s), width: d, height: d))
            }
            Self.grain(ctx, size: size, amount: 0.1, rng: &rng)
        case .camo:
            fill(rgb(0.45, 0.48, 0.32))
            for color in [rgb(0.3, 0.33, 0.2), rgb(0.6, 0.55, 0.38), rgb(0.18, 0.2, 0.15)] {
                ctx.setFillColor(color)
                for _ in 0..<14 {
                    let c = CGPoint(x: r(0...s), y: r(0...s))
                    for _ in 0..<5 {
                        let w = r(0.06...0.16) * s
                        ctx.fillEllipse(in: CGRect(x: c.x + r(-0.08...0.08) * s, y: c.y + r(-0.05...0.05) * s, width: w, height: w * r(0.5...0.9)))
                    }
                }
            }
        case .terrazzo:
            fill(rgb(0.94, 0.91, 0.86))
            let chips = [rgb(0.93, 0.45, 0.38), rgb(0.2, 0.55, 0.55), rgb(0.95, 0.72, 0.3), rgb(0.25, 0.25, 0.28), rgb(0.7, 0.75, 0.85)]
            for _ in 0..<320 {
                ctx.setFillColor(chips[Int.random(in: 0..<chips.count, using: &rng)])
                let c = CGPoint(x: r(0...s), y: r(0...s)), d = r(4...20) * s / 512
                ctx.move(to: CGPoint(x: c.x + d, y: c.y))
                for k in 1..<5 {
                    let a = CGFloat(k) / 5 * 2 * .pi + r(-0.4...0.4)
                    ctx.addLine(to: CGPoint(x: c.x + cos(a) * d * r(0.5...1), y: c.y + sin(a) * d * r(0.5...1)))
                }
                ctx.fillPath()
            }
        case .gingham:
            fill(rgb(1, 1, 0.98))
            let band = s / 16, color = tinted ?? rgb(0.88, 0.25, 0.3)
            ctx.setFillColor(color.copy(alpha: 0.45)!)
            for v in stride(from: CGFloat(0), to: s, by: band * 2) {
                ctx.fill(CGRect(x: v, y: 0, width: band, height: s))
                ctx.fill(CGRect(x: 0, y: v, width: s, height: band))
            }
        case .candy:
            fill(rgb(1, 0.98, 0.98))
            ctx.setFillColor(tinted ?? rgb(0.95, 0.45, 0.6))
            let band = s / 14
            for i in stride(from: -s, through: s, by: band * 2) {
                ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i + band, y: 0))
                ctx.addLine(to: CGPoint(x: i + band + s, y: s)); ctx.addLine(to: CGPoint(x: i + s, y: s)); ctx.fillPath()
            }
        case .dots:
            fill(tinted ?? rgb(0.45, 0.8, 0.72))
            ctx.setFillColor(rgb(1, 1, 1, 0.9))
            let step = s / 10, d = step * 0.36
            for row in 0...10 {
                for col in 0...10 {
                    let x = CGFloat(col) * step + (row % 2 == 0 ? 0 : step / 2), y = CGFloat(row) * step
                    ctx.fillEllipse(in: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d))
                }
            }
        case .galaxy:
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [rgb(0.55, 0.3, 0.75), rgb(0.2, 0.12, 0.42), rgb(0.05, 0.05, 0.15)] as CFArray, locations: [0, 0.45, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: s * 0.62, y: s * 0.45), startRadius: 0,
                                   endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.8, options: [.drawsAfterEndLocation])
            for _ in 0..<420 {
                let d = r(0...1) < 0.92 ? r(0.8...2.5) * s / 512 : r(3...6) * s / 512
                ctx.setFillColor(rgb(1, 1, 1, r(0.4...1)))
                ctx.fillEllipse(in: CGRect(x: r(0...s), y: r(0...s), width: d, height: d))
            }
        case .notebook:
            fill(rgb(0.99, 0.99, 0.96))
            ctx.setStrokeColor(rgb(0.45, 0.65, 0.9, 0.55)); ctx.setLineWidth(s / 400)
            for y in stride(from: s * 0.06, to: s, by: s / 18) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: s, y: y)) }
            ctx.strokePath()
            ctx.setStrokeColor(rgb(0.9, 0.35, 0.35, 0.7)); ctx.setLineWidth(s / 220)
            ctx.move(to: CGPoint(x: s * 0.16, y: 0)); ctx.addLine(to: CGPoint(x: s * 0.16, y: s)); ctx.strokePath()
        case .metal:
            gradient([rgb(0.82, 0.83, 0.85), rgb(0.58, 0.6, 0.63), rgb(0.78, 0.79, 0.81)], from: CGPoint(x: 0, y: s), to: CGPoint(x: s, y: 0))
            for _ in 0..<700 {
                ctx.setStrokeColor(r(0...1) < 0.5 ? rgb(1, 1, 1, 0.12) : rgb(0.3, 0.3, 0.32, 0.1))
                ctx.setLineWidth(s / 900)
                let y = r(0...s), x = r(-0.2...1) * s
                ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + r(0.1...0.5) * s, y: y)); ctx.strokePath()
            }
        case .emojiPattern:
            let base = tint ?? (0.98, 0.82, 0.45)
            // A pale version of the colour, so the emoji stand out.
            fill(rgb(base.r + (1 - base.r) * 0.55, base.g + (1 - base.g) * 0.55, base.b + (1 - base.b) * 0.55))
            let glyph = emoji.isEmpty ? "⭐️" : emoji
            let font = CTFontCreateWithName("Apple Color Emoji" as CFString, s * 0.085, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: font]))
            let step = s / 7
            for row in 0...7 {
                for col in -1...7 {
                    ctx.saveGState()
                    ctx.translateBy(x: CGFloat(col) * step + (row % 2 == 0 ? 0 : step / 2), y: CGFloat(row) * step)
                    ctx.rotate(by: row % 2 == 0 ? -0.2 : 0.2)
                    ctx.textPosition = CGPoint(x: -s * 0.04, y: -s * 0.03)
                    CTLineDraw(line, ctx)
                    ctx.restoreGState()
                }
            }
        }
        return ctx.makeImage()
    }

    /// Fine random speckle, lighter and darker, `amount` 0…1.
    private static func grain(_ ctx: CGContext, size: Int, amount: Double, rng: inout SeededRandom) {
        guard let data = ctx.data else { return }
        let p = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        for i in 0..<(size * size) {
            let delta = (Double(rng.next() % 1000) / 1000 - 0.5) * 2 * amount * 255
            for k in 0..<3 { p[i * 4 + k] = UInt8(min(max(Double(p[i * 4 + k]) + delta, 0), 255)) }
        }
    }

    /// A dashed seam just inside `rect`.
    private static func stitch(_ ctx: CGContext, _ rect: CGRect, color: CGColor, s: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(s / 140)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [s / 45, s / 70])
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// A small deterministic generator, so a material looks the same every time it's drawn.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Ready-made styles shown in the editor's library: every material, plus a few emoji and lettering combinations.
enum FolderLibrary {
    struct Entry { let title: String; let style: FolderStyle }

    static let entries: [Entry] = {
        var list = [Entry(title: "Plain", style: FolderStyle())]
        list += FolderMaterial.allCases.filter { $0 != .plain && $0 != .emojiPattern }.map { material in
            Entry(title: material.title, style: FolderStyle(material: material))
        }
        func combo(_ title: String, _ material: FolderMaterial, emoji: String, text: String = "", tint: String? = nil) -> Entry {
            var style = FolderStyle(tint: tint, material: material)
            style.badge = .emoji; style.emoji = emoji; style.text = text
            return Entry(title: title, style: style)
        }
        list += [
            combo("Gaming", .neon, emoji: "🎮"), combo("Video", .film, emoji: "🎬"), combo("Finance", .banknote, emoji: "💰"),
            combo("Design", .holographic, emoji: "🎨"), combo("School", .notebook, emoji: "📚"), combo("Travel", .sunset, emoji: "✈️"),
            combo("Code", .blueprint, emoji: "💻"), combo("Ideas", .chalkboard, emoji: "💡", text: "IDEAS"),
            combo("Headphones", .galaxy, emoji: "🎧"), combo("Photos", .kraft, emoji: "📷"),
        ]
        var pattern = FolderStyle(tint: "F2C230", material: .emojiPattern); pattern.emoji = "⭐️"
        list.append(Entry(title: "Emoji Pattern", style: pattern))
        var hearts = FolderStyle(tint: "EC6AA8", material: .emojiPattern); hearts.emoji = "💖"
        list.append(Entry(title: "Hearts", style: hearts))
        var poster = FolderStyle(material: .poster); poster.text = "POSTER DESIGN"
        list.append(Entry(title: "Poster Design", style: poster))
        return list
    }()
}
