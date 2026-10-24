import AppKit
import CoreImage
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Swivel

/// Edit Photo's sliders and looks, Blur Background and Resize….
@Suite(.serialized)
@MainActor
struct PhotoEditTests {
    // MARK: Helpers

    /// A horizontal grey ramp from black to white, `width` × 8, sRGB.
    private func ramp(width: Int = 256) throws -> CGImage {
        try image(width: width, height: 8) { x, _ in
            let v = UInt8(x * 255 / (width - 1))
            return (v, v, v)
        }
    }

    private func image(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                // Rows in memory run top-down.
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    /// RGBA bytes of `image`, top-down rows, in sRGB.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func rgb(_ data: [UInt8], _ image: CGImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        let i = (y * image.width + x) * 4
        return (Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
    }

    private func rendered(_ settings: PhotoSettings, _ source: CGImage? = nil) throws -> (CGImage, [UInt8]) {
        let input = try source ?? ramp()
        let output = try #require(PhotoAdjust.render(input, settings))
        #expect(output.width == input.width && output.height == input.height)
        return (output, try pixels(output))
    }

    private func folder() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/photo-edit-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Sliders

    @Test func neutralSettingsLeaveThePhotoAlone() throws {
        let input = try ramp()
        #expect(PhotoAdjust.render(input, PhotoSettings()) === input)
    }

    @Test func eachSliderMovesThePictureTheWayItsNameSays() throws {
        let source = try ramp()
        let before = try pixels(source)
        func grey(_ data: [UInt8], _ x: Int) -> Double { let p = rgb(data, source, x: x, y: 4); return (p.r + p.g + p.b) / 3 }

        let (_, brighter) = try rendered(PhotoSettings(exposure: 1))
        #expect(grey(brighter, 128) > grey(before, 128) + 20)

        // Blacks lift the black point; negative ones crush the dark end.
        let (_, lifted) = try rendered(PhotoSettings(blacks: 1))
        #expect(grey(lifted, 0) > 20)
        let (_, crushed) = try rendered(PhotoSettings(blacks: -1))
        #expect(grey(crushed, 20) < grey(before, 20) - 5)

        // Whites clip the bright end earlier; negative ones lower white.
        let (_, whiter) = try rendered(PhotoSettings(whites: 1))
        #expect(grey(whiter, 230) > grey(before, 230) + 5)
        let (_, dimmer) = try rendered(PhotoSettings(whites: -1))
        #expect(grey(dimmer, 255) < 245)

        let (_, higher) = try rendered(PhotoSettings(highlights: 1))
        #expect(grey(higher, 192) > grey(before, 192) + 5)

        let (_, flatter) = try rendered(PhotoSettings(contrast: -1))
        #expect(grey(flatter, 230) - grey(flatter, 25) < grey(before, 230) - grey(before, 25) - 20)
    }

    @Test func shadowsLiftTheDarkAndHighlightsRecoverTheBright() throws {
        // A real scene, not a ramp: dark and bright patches side by side, as the local filter expects.
        let scene = try image(width: 200, height: 100) { x, _ in x < 100 ? (40, 40, 40) : (235, 235, 235) }
        let before = try pixels(scene)
        let (_, lifted) = try rendered(PhotoSettings(shadows: 1), scene)
        #expect(rgb(lifted, scene, x: 50, y: 50).g > rgb(before, scene, x: 50, y: 50).g + 5)
        let (_, recovered) = try rendered(PhotoSettings(highlights: -1), scene)
        #expect(rgb(recovered, scene, x: 150, y: 50).g < rgb(before, scene, x: 150, y: 50).g - 3)
    }

    @Test func colourSlidersPushTheExpectedWay() throws {
        let grey = try image(width: 32, height: 32) { _, _ in (128, 128, 128) }
        let (_, warm) = try rendered(PhotoSettings(warmth: 1), grey)
        let w = rgb(warm, grey, x: 16, y: 16)
        #expect(w.r > w.b + 10)
        let (_, cool) = try rendered(PhotoSettings(warmth: -1), grey)
        let c = rgb(cool, grey, x: 16, y: 16)
        #expect(c.b > c.r + 10)
        // Positive tint is magenta: green falls behind red and blue.
        let (_, magenta) = try rendered(PhotoSettings(tint: 1), grey)
        let m = rgb(magenta, grey, x: 16, y: 16)
        #expect(m.g < (m.r + m.b) / 2 - 3)

        let red = try image(width: 32, height: 32) { _, _ in (200, 60, 50) }
        let (_, washed) = try rendered(PhotoSettings(saturation: -1), red)
        let g = rgb(washed, red, x: 16, y: 16)
        #expect(abs(g.r - g.g) < 3 && abs(g.g - g.b) < 3)
        let (_, richer) = try rendered(PhotoSettings(vibrance: 1), try image(width: 32, height: 32) { _, _ in (150, 120, 110) })
        let v = rgb(richer, red, x: 16, y: 16)
        #expect(v.r - v.b > 150 - 110)
    }

    @Test func effectsRenderAtEveryExtremeWithoutChangingTheSize() throws {
        let noisy = try image(width: 300, height: 200) { x, y in
            let v = UInt8(truncatingIfNeeded: (x * 7919 + y * 104729) % 251)
            return (v, v, v)
        }
        for settings in [PhotoSettings(clarity: 1), PhotoSettings(clarity: -1), PhotoSettings(sharpen: 1),
                         PhotoSettings(noise: 1), PhotoSettings(vignette: 1)] {
            _ = try rendered(settings, noisy)
        }
        // The vignette darkens the corners, not the middle.
        let flat = try image(width: 300, height: 200) { _, _ in (200, 200, 200) }
        let (_, vignetted) = try rendered(PhotoSettings(vignette: 1), flat)
        #expect(rgb(vignetted, flat, x: 2, y: 2).g < rgb(vignetted, flat, x: 150, y: 100).g - 20)
    }

    @Test func toneCurvePointsStayInOrder() {
        for h in [-1.0, 0, 1] {
            for w in [-1.0, 0, 1] {
                for b in [-1.0, 0, 1] {
                    let points = PhotoAdjust.toneCurve(highlights: h, whites: w, blacks: b)
                    #expect(zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x && $0.y <= $1.y })
                    #expect(points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
                }
            }
        }
    }

    // MARK: Looks and Auto

    @Test func looksStackOnTheSlidersAndStayInRange() throws {
        #expect(PhotoLook.all.first?.settings.isNeutral == true)
        #expect(Set(PhotoLook.all.map(\.name)).count == PhotoLook.all.count)
        let bw = try #require(PhotoLook.all.first { $0.name == "B&W" })
        let combined = PhotoSettings(saturation: -0.5).adding(bw.settings, amount: 1)
        #expect(combined.saturation == -1)
        #expect(PhotoSettings(exposure: 0.4).adding(bw.settings, amount: 0).exposure == 0.4)
        #expect(PhotoSettings().adding(bw.settings, amount: 0.5).saturation == -0.5)
        // Every look renders, and B&W really is grey.
        let red = try image(width: 64, height: 64) { _, _ in (200, 60, 50) }
        for look in PhotoLook.all { _ = try rendered(look.settings, red) }
        let (_, grey) = try rendered(bw.settings, red)
        let p = rgb(grey, red, x: 32, y: 32)
        #expect(abs(p.r - p.b) < 3)
        // Translated, like every look's tile label.
        for look in PhotoLook.all { #expect(Strings.table[look.name] != nil) }
        for field in PhotoSettings.fields { #expect(Strings.table[field.name] != nil, "\(field.name)") }
    }

    @Test func autoBrightensADarkPhotoAndDarkensABrightOne() throws {
        let dark = try image(width: 200, height: 150) { x, y in let v = UInt8(15 + (x + y) % 40); return (v, v, v) }
        #expect(PhotoAdjust.auto(for: dark).exposure > 0.2)
        let bright = try image(width: 200, height: 150) { x, y in let v = UInt8(215 + (x + y) % 40); return (v, v, v) }
        #expect(PhotoAdjust.auto(for: bright).exposure < -0.2)
        let auto = PhotoAdjust.auto(for: dark)
        for field in PhotoSettings.fields { #expect(field.range.contains(auto[keyPath: field.key])) }
    }

    // MARK: Blur Background

    @Test func blurKeepsTheSubjectSharpAndLeavesNoHaloAroundIt() throws {
        // A red square (the subject) on a checkerboard of two blues. The background's red channel is the same
        // everywhere, so any red found beside the square has leaked out of the subject.
        let size = 240, inside = 80..<160
        let photo = try image(width: size, height: size) { x, y in
            if inside.contains(x) && inside.contains(y) { return (220, 30, 30) }
            return (x / 8 + y / 8) % 2 == 0 ? (30, 40, 220) : (30, 160, 220)
        }
        let mask = try image(width: size, height: size) { x, y in inside.contains(x) && inside.contains(y) ? (255, 255, 255) : (0, 0, 0) }
        let output = try #require(BackgroundBlur.render(photo, mask: mask, amount: 1))
        #expect(output.width == size && output.height == size)
        let data = try pixels(output), before = try pixels(photo)
        // Subject: unchanged in its middle.
        let centre = rgb(data, output, x: 120, y: 120)
        #expect(abs(centre.r - 220) < 4 && centre.g < 40)
        // Background far from the subject: the checkerboard is blurred towards its average.
        let far = rgb(data, output, x: 20, y: 20), sharp = rgb(before, photo, x: 20, y: 20)
        #expect(abs(far.g - 100) < 25 && abs(far.g - sharp.g) > 35)
        // Just outside the subject: no red bleeding out of it (an ordinary blur puts about 60 here).
        for x in [70, 74, 77] {
            let edge = rgb(data, output, x: x, y: 120)
            #expect(edge.r < 42, "halo at x=\(x): \(edge)")
        }
        // Amount 0 changes nothing.
        #expect(BackgroundBlur.render(photo, mask: mask, amount: 0) === photo)
    }

    @Test func aRealPhotoGetsASubjectMaskAtItsOwnSize() throws {
        // macOS's own account pictures: a parrot that Remove BG finds. (The mask once came back empty because the
        // grey conversion made its extent endless.)
        let url = URL(fileURLWithPath: "/Library/User Pictures/Animals/Parrot.heic")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let photo = try Images.load(url)
        let mask = try #require(try BackgroundBlur.subjectMask(photo))
        #expect(mask.width == photo.width && mask.height == photo.height)
        let data = try pixels(mask)
        // The parrot's eye is subject; the top-left corner (leaves) isn't.
        #expect(rgb(data, mask, x: photo.width / 2, y: photo.height / 2).g > 200)
        #expect(rgb(data, mask, x: 5, y: 5).g < 50)
        let blurred = try #require(BackgroundBlur.render(photo, mask: mask, amount: 0.6))
        #expect(blurred.width == photo.width)
    }

    @Test func blankPhotoHasNoSubjectToBlurAround() throws {
        let blank = try image(width: 256, height: 256) { _, _ in (255, 255, 255) }
        #expect(try BackgroundBlur.subjectMask(blank) == nil)
    }

    // MARK: Resize

    @Test func resizeSizesKeepTheRatioAndHitTheAskedSideExactly() {
        let size = Images.resizedSize
        #expect(size(4000, 3000, .longEdge, 1920, false)! == (1920, 1440))
        #expect(size(3000, 4000, .longEdge, 1920, false)! == (1440, 1920))
        #expect(size(4032, 3024, .width, 1080, false)! == (1080, 810))
        #expect(size(4032, 3024, .height, 1000, false)! == (1333, 1000))
        #expect(size(4000, 3000, .percent, 50, false)! == (2000, 1500))
        #expect(size(3, 1000, .longEdge, 10, false)! == (1, 10))
        // Never enlarges unless asked; the same size is no change at all.
        #expect(size(800, 600, .longEdge, 1920, false) == nil)
        #expect(size(800, 600, .longEdge, 1920, true)! == (1920, 1440))
        #expect(size(800, 600, .percent, 100, true) == nil)
        #expect(size(800, 600, .width, 800, false) == nil)
        // Out of range values are refused.
        #expect(size(800, 600, .width, 0, true) == nil)
        #expect(size(800, 600, .percent, 5000, true) == nil)
        #expect(size(0, 600, .width, 100, true) == nil)
    }

    @Test func resizeWritesBesideTheOriginalAndNeverReplacesAnything() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.png")
        let source = try image(width: 400, height: 300) { x, _ in (UInt8(x % 256), 100, 50) }
        try Images.encode(source, type: .png, quality: 1).write(to: url)

        let first = try #require(try Images.resizeFile(url, mode: .width, value: 200, enlarge: false))
        #expect(first.lastPathComponent == "photo 200×150.png")
        let decoded = try Images.load(first)
        #expect(decoded.width == 200 && decoded.height == 150)
        let second = try #require(try Images.resizeFile(url, mode: .longEdge, value: 200, enlarge: false))
        #expect(second.lastPathComponent == "photo 200×150 2.png")
        // Growing only when allowed.
        #expect(try Images.resizeFile(url, mode: .width, value: 800, enlarge: false) == nil)
        let grown = try #require(try Images.resizeFile(url, mode: .width, value: 800, enlarge: true))
        let big = try Images.load(grown)
        #expect(big.width == 800 && big.height == 600)
        #expect(try Images.load(url).width == 400)
        // Enlarging is bounded on both sides and in total, not just on the side that was typed.
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(throws: ToolError.self) { try Images.resizeFile(url, mode: .height, value: 20_000, enlarge: true) }  // 26,667 wide
        #expect(throws: ToolError.self) { try Images.resizeFile(url, mode: .width, value: 20_000, enlarge: true) }   // 300 MP
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)
    }

    @Test func resizeMeasuresTheUprightPhoto() throws {
        // Stored 400 × 300 but turned a quarter by EXIF (orientation 6): upright it's 300 × 400.
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("turned.jpg")
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image(width: 400, height: 300) { _, _ in (90, 90, 90) },
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        let out = try #require(try Images.resizeFile(url, mode: .width, value: 150, enlarge: false))
        #expect(out.lastPathComponent == "turned 150×200.jpg")
        let decoded = try Images.load(out)
        #expect(decoded.width == 150 && decoded.height == 200)
    }

    // MARK: Menu

    @Test func imageToolsOfferResizeAndBlurNextToTheirNeighbours() throws {
        let titles = Catalog.defaultItems(for: [URL(fileURLWithPath: "/nonexistent/photo.png")], mode: .tools).map(\.title)
        let compress = try #require(titles.firstIndex(of: "Compress"))
        #expect(titles[compress - 1] == "Resize…")
        let remove = try #require(titles.firstIndex(of: "Remove BG"))
        #expect(titles[remove + 1] == "Blur BG")
        #expect(Strings.table["Resize…"] != nil && Strings.table["Blur BG"] != nil)
        // Both ask the user something (a size, a strength), so agents aren't offered them.
        let ids = MCPCatalog.actions(for: [URL(fileURLWithPath: "/nonexistent/photo.png")]).map(\.id)
        #expect(!ids.contains("tools.Resize…") && !ids.contains("tools.Blur BG") && ids.contains("tools.Resize 50%"))
    }
}
