import AppKit
import CoreImage
import ImageIO
import Testing
@testable import Swivel

@Suite(.serialized)
struct IDPhotoTests {
    let face = IDFace(bounds: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.45), eyes: CGPoint(x: 0.5, y: 0.65), chin: 0.4, headTop: 0.9)
    @Test func cropKeepsTheHeadAndEyesAtTheirRatiosAndPadsAtEdges() throws {
        let crop = try #require(IDPhoto.crop(image: CGSize(width: 1000, height: 1200), output: CGSize(width: 295, height: 413), face: face))
        #expect(abs(crop.width / crop.height - 295.0 / 413) < 0.000001)
        #expect(abs(600 / crop.height - 0.7) < 0.000001)
        #expect(abs((780 - crop.minY) / crop.height - 0.55) < 0.000001)
        #expect(abs((500 - crop.minX) / crop.width - 0.5) < 0.000001)
        let zoomed = try #require(IDPhoto.crop(image: CGSize(width: 1000, height: 1200), output: CGSize(width: 295, height: 413), face: face, zoom: 1.2, vertical: 0.1))
        #expect(abs(600 / zoomed.height - 0.84) < 0.000001)
        #expect(abs((780 - zoomed.minY) / zoomed.height - 0.65) < 0.000001)
        var edge = face; edge.eyes.x = 0.03
        let padded = try #require(IDPhoto.crop(image: CGSize(width: 1000, height: 1200), output: CGSize(width: 600, height: 600), face: edge))
        #expect(padded.minX < 0 && padded.width == padded.height)
        #expect(IDPhoto.crop(image: .zero, output: CGSize(width: 1, height: 1), face: face) == nil)
        #expect(throws: (any Error).self) { try IDPhoto.singleFace([]) }
        #expect(throws: (any Error).self) { try IDPhoto.singleFace([face, face]) }
    }
    private func synthetic() throws -> (CGImage, CGImage) {
        let w = 128, h = 128
        var pixels = [UInt8](repeating: 255, count: w * h * 4), mask = pixels
        for y in 0..<h { for x in 0..<w {
            var alpha = 0.0
            if (20..<110).contains(y) { alpha = min(1, max(0, min(Double(x - 48) / 4, Double(94 - x) / 4))) }
            let i = (y * w + x) * 4
            pixels[i] = UInt8((220 * alpha).rounded()); pixels[i + 1] = 0; pixels[i + 2] = UInt8((220 * (1 - alpha)).rounded())
            mask[i] = UInt8((255 * alpha).rounded()); mask[i + 1] = mask[i]; mask[i + 2] = mask[i]
        } }
        return (try Retouch.Raster(width: w, height: h, bytes: pixels).image(), try Retouch.Raster(width: w, height: h, bytes: mask).image())
    }
    @Test func backgroundReplacementRemovesOldBlueFromSoftEdgesAndNaiveBlendFails() throws {
        let (image, mask) = try synthetic()
        let output = try IDPhoto.replaceBackground(image, mask: mask, color: SIMD3(1, 1, 1))
        let ctx = CIContext(), extent = CGRect(x: 0, y: 0, width: 128, height: 128)
        let clean = try Retouch.Raster(#require(ctx.createCGImage(output, from: extent)))
        let naive = CIImage(cgImage: image).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: CIImage(cgImage: mask, options: [.colorSpace: NSNull()]),
            kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: extent)])
        let dirty = try Retouch.Raster(#require(ctx.createCGImage(naive, from: extent)))
        for x in [49, 50, 51] {
            let i = (64 * 128 + x) * 4
            #expect(abs(Int(clean.bytes[i + 2]) - Int(clean.bytes[i + 1])) < 6)
        }
        let edge = (64 * 128 + 50) * 4
        let naiveLeak = Int(dirty.bytes[edge + 2]) - Int(dirty.bytes[edge + 1])
        print("ID Photo old-background contamination: naive \(naiveLeak), corrected \(abs(Int(clean.bytes[edge + 2]) - Int(clean.bytes[edge + 1])))")
        // The same six-level tolerance used above must reject the ordinary blend.
        #expect(naiveLeak >= 6)
    }
    @Test func transparentForegroundKeepsSourceAlphaOverEveryBackground() throws {
        let w = 64, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let a = [0, 64, 128, 255][x / 16], i = (y * w + x) * 4
            for (channel, value) in [220, 80, 20].enumerated() { pixels[i + channel] = UInt8((Double(value * a) / 255).rounded()) }
            pixels[i + 3] = UInt8(a)
        } }
        let image = try Retouch.Raster(width: w, height: h, bytes: pixels).image()
        let mask = try Retouch.Raster(width: w, height: h, bytes: [UInt8](repeating: 255, count: w * h * 4)).image()
        let context = CIContext(), extent = CGRect(x: 0, y: 0, width: w, height: h)
        for color in [SIMD3<Double>(1, 1, 1), SIMD3(67.0 / 255, 142.0 / 255, 219.0 / 255), SIMD3(217.0 / 255, 0, 27.0 / 255)] {
            let output = try IDPhoto.replaceBackground(image, mask: mask, color: color)
            let background = CIImage(color: CIColor(red: color.x, green: color.y, blue: color.z))
            let reference = CIImage(cgImage: image).composited(over: background).cropped(to: extent)
            let actual = try Retouch.Raster(#require(context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))))
            let expected = try Retouch.Raster(#require(context.createCGImage(reference, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))))
            for x in [8, 24, 40, 56] {
                let i = (8 * w + x) * 4
                for channel in 0..<3 { #expect(abs(Int(actual.bytes[i + channel]) - Int(expected.bytes[i + channel])) <= 1) }
                #expect(actual.bytes[i + 3] == 255)
            }
        }
    }
    @Test func longSoftHairUsesForegroundSeedsInsteadOfOldBackgroundOrBlack() throws {
        let w = 256, h = 256, headY = 140
        let context = CIContext(), extent = CGRect(x: 0, y: 0, width: w, height: h)
        for length in [40, 100] { for hairWidth in [2, 5] {
            var pixels = [UInt8](repeating: 255, count: w * h * 4), masks = pixels
            for y in 0..<h { for x in 0..<w {
                let head = (80..<150).contains(x) && (headY..<240).contains(y)
                let hair = (110..<(110 + hairWidth)).contains(x) && ((headY - length)..<(headY + 10)).contains(y)
                let alpha = head ? 1.0 : (hair ? 128.0 / 255 : 0)
                let i = (y * w + x) * 4
                pixels[i] = UInt8((220 * alpha).rounded()); pixels[i + 1] = 0; pixels[i + 2] = UInt8((220 * (1 - alpha)).rounded())
                masks[i] = UInt8((255 * alpha).rounded()); masks[i + 1] = masks[i]; masks[i + 2] = masks[i]
            } }
            let image = try Retouch.Raster(width: w, height: h, bytes: pixels).image()
            let mask = try Retouch.Raster(width: w, height: h, bytes: masks).image()
            let output = try IDPhoto.replaceBackground(image, mask: mask, color: SIMD3(1, 1, 1))
            let clean = try Retouch.Raster(#require(context.createCGImage(output, from: extent)))
            let naive = CIImage(cgImage: image).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputMaskImageKey: CIImage(cgImage: mask, options: [.colorSpace: NSNull()]),
                kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: extent)])
            let dirty = try Retouch.Raster(#require(context.createCGImage(naive, from: extent)))
            let i = ((headY - length / 2) * w + 110 + hairWidth / 2) * 4
            #expect(abs(Int(clean.bytes[i + 2]) - Int(clean.bytes[i + 1])) < 6)
            // An opaque black fallback would also pass the blue/green test. Preserve the red foreground too.
            #expect(Int(clean.bytes[i]) - Int(clean.bytes[i + 1]) > 30)
            #expect(Int(dirty.bytes[i + 2]) - Int(dirty.bytes[i + 1]) >= 6)
            let solid = (180 * w + 100) * 4
            #expect(Array(clean.bytes[solid..<solid + 4]) == [220, 0, 0, 255])
        } }
    }
    @Test func noReliableSeedIsAnExplicitErrorAndWorkingSurfacesHaveABudget() throws {
        let image = try Retouch.Raster(width: 32, height: 32, bytes: [UInt8](repeating: 255, count: 32 * 32 * 4)).image()
        let mask = try Retouch.Raster(width: 32, height: 32, bytes: Array(repeating: [UInt8(128), 128, 128, 255], count: 32 * 32).flatMap { $0 }).image()
        do {
            _ = try IDPhoto.replaceBackground(image, mask: mask, color: SIMD3(1, 1, 1))
            Issue.record("A mask without reliable foreground must not silently reuse mixed photo colours")
        } catch {
            #expect(error.localizedDescription == L("Couldn't find a reliable foreground. Choose a clearer portrait."))
        }
        #expect(try IDPhoto.workingEdge(settings: IDPhotoSettings()) == 1400)
        #expect(try IDPhoto.workingEdge(settings: IDPhotoSettings(width: 1000, height: 1500)) == 3000)
        #expect(try IDPhoto.workingEdge(settings: IDPhotoSettings(width: 4000, height: 4000)) == IDPhoto.maxWorkingEdge)
        #expect(throws: (any Error).self) { try IDPhoto.workingEdge(settings: IDPhotoSettings(width: Int.max, height: 1)) }
        for width in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            #expect(throws: (any Error).self) { try IDPhoto.dimensions(preset: 4, width: width, height: 100, millimeters: true, dpi: 1200) }
        }
        #expect(throws: (any Error).self) { try IDPhoto.dimensions(preset: 4, width: 6324.55, height: 6324.55, millimeters: false, dpi: 300) }
        let oversized = try Retouch.Raster(width: IDPhoto.maxWorkingEdge + 1, height: 1,
                                           bytes: [UInt8](repeating: 255, count: (IDPhoto.maxWorkingEdge + 1) * 4)).image()
        #expect(throws: (any Error).self) { try IDPhoto.detect(oversized) }
        #expect(throws: (any Error).self) { try IDPhoto.replaceBackground(oversized, mask: mask, color: SIMD3(1, 1, 1)) }
    }
    @Test func cancelledSaveCreatesNoOutput() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (image, _) = try synthetic()
        let source = try Images.save(image, as: folder.appendingPathComponent("portrait.png"), type: .png, quality: 1)
        let before = try Data(contentsOf: source)
        let worker = Task.detached { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try IDPhoto.save(image, source: source, dpi: 300)
        }
        do { _ = try await worker.value; Issue.record("Cancelled ID Photo save should throw") }
        catch is CancellationError { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [source.lastPathComponent])
        #expect(try Data(contentsOf: source) == before)
    }
    @Test func presetsCustomUnitsAndDPIOutputAreExactAndNeverReplaceTheSource() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (image, mask) = try synthetic()
        let source = try Images.save(image, as: folder.appendingPathComponent("photo.png"), type: .png, quality: 1)
        let original = try Data(contentsOf: source)
        let expected = [(295, 413), (413, 579), (390, 567), (600, 600)]
        for index in 0..<4 {
            let (w, h) = try IDPhoto.dimensions(preset: index, width: 1, height: 1, millimeters: false, dpi: 300)
            #expect(w == expected[index].0 && h == expected[index].1)
            let settings = IDPhotoSettings(width: w, height: h)
            let result = try IDPhoto.render(image, mask: mask, face: face, settings: settings)
            #expect(result.width == w && result.height == h)
            let file = try IDPhoto.save(result, source: source, dpi: 300)
            if index == 0 { #expect(file.lastPathComponent == "photo id.jpg") }
            let decoder = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(decoder, 0, nil) as? [CFString: Any])
            #expect(abs((props[kCGImagePropertyDPIWidth] as? Double ?? 0) - 300) < 0.1)
            #expect(abs((props[kCGImagePropertyDPIHeight] as? Double ?? 0) - 300) < 0.1)
        }
        let mm = try IDPhoto.dimensions(preset: 4, width: 25.4, height: 50.8, millimeters: true, dpi: 300)
        #expect(mm.0 == 300 && mm.1 == 600)
        #expect(throws: (any Error).self) { try IDPhoto.dimensions(preset: 4, width: 10000, height: 10000, millimeters: false, dpi: 300) }
        #expect(try Data(contentsOf: source) == original)
    }
    @Test func blankImageReportsNoFace() throws {
        let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
        let image = try #require(CIContext().createCGImage(CIImage(color: .white).cropped(to: extent), from: extent))
        #expect(throws: (any Error).self) { try IDPhoto.detect(image) }
    }
    @Test @MainActor func menuIDAndTranslationsStayStable() throws {
        let source = URL(fileURLWithPath: "/nonexistent/photo.png")
        let titles = Catalog.defaultItems(for: [source], mode: .tools).map(\.title)
        #expect(titles.firstIndex(of: "ID Photo") == titles.firstIndex(of: "Add BG").map { $0 - 1 })
        #expect(!MCPCatalog.actions(for: [source]).contains { $0.id == "tools.ID Photo" })
        for key in IDPhoto.presetNames + ["ID Photo", "Vertical Position", "DPI", "Pixels", "Millimeters",
            "For convenience only. Follow the issuing authority's requirements for official use."] {
            #expect(Strings.table[key]?.count == 3)
        }
        _ = IDPhotoEditor(source: source)
    }
}
