import AppKit
import Foundation
import Testing
@testable import Swivel

@Suite(.serialized)
struct RetouchTests {
    private func texture(_ width: Int, _ height: Int) -> Retouch.Raster {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let v: UInt8 = (x / 4 + y / 4) % 2 == 0 ? 30 : 220
            let i = (y * width + x) * 4
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
        } }
        return Retouch.Raster(width: width, height: height, bytes: bytes)
    }

    @Test func completionRestoresTextureAndAnAverageFillFails() throws {
        let original = texture(96, 80)
        var damaged = original
        var mask = [Bool](repeating: false, count: 96 * 80)
        for y in 28..<52 { for x in 32..<60 {
            let p = y * 96 + x
            mask[p] = true
            damaged.bytes[p * 4] = 255; damaged.bytes[p * 4 + 1] = 0; damaged.bytes[p * 4 + 2] = 0
        } }
        let repaired = try Retouch.complete(damaged, mask: mask)
        var error = 0.0, averageError = 0.0, n = 0.0
        for p in mask.indices {
            if mask[p] {
                for c in 0..<3 {
                    error += abs(Double(repaired.bytes[p * 4 + c]) - Double(original.bytes[p * 4 + c]))
                    averageError += abs(125 - Double(original.bytes[p * 4 + c]))
                    n += 1
                }
            } else {
                #expect(repaired.bytes[(p * 4)..<(p * 4 + 4)] == original.bytes[(p * 4)..<(p * 4 + 4)])
            }
        }
        print("Retouch texture MAE: \(error / n); average-fill MAE: \(averageError / n)")
        #expect(error / n < 20)
        #expect(averageError / n > 80)
    }

    @Test func edgeMasksLargeCoverageAndOnePixelStayFiniteAndPreserveOutside() throws {
        let input = texture(40, 40)
        var cases = [[Bool]]()
        cases.append((0..<1600).map { $0 % 40 < 5 }) // touches three borders
        cases.append((0..<1600).map { $0 % 40 < 36 }) // 90% painted
        cases.append((0..<1600).map { $0 == 820 })
        cases.append([Bool](repeating: false, count: 1600))
        for mask in cases {
            let output = try Retouch.complete(input, mask: mask)
            #expect(output.bytes.count == input.bytes.count)
            for p in mask.indices where !mask[p] {
                #expect(output.bytes[(p * 4)..<(p * 4 + 4)] == input.bytes[(p * 4)..<(p * 4 + 4)])
            }
        }
        #expect(throws: (any Error).self) { try Retouch.complete(input, mask: [Bool](repeating: true, count: 1600)) }
        #expect(throws: Cancelled.self) { try Retouch.complete(input, mask: cases[0], cancelled: { true }) }
    }

    @Test func pyramidPreservesUnmaskedPixelsAndUsesOnlyBackground() throws {
        var input = texture(256, 192)
        var mask = [Bool](repeating: false, count: 256 * 192)
        for y in 60..<130 { for x in 80..<160 {
            let p = y * 256 + x
            mask[p] = true
            input.bytes[p * 4] = 255; input.bytes[p * 4 + 1] = 0
        } }
        let output = try Retouch.complete(input, mask: mask)
        for p in mask.indices {
            if mask[p] { #expect(output.bytes[p * 4] == output.bytes[p * 4 + 1]) }
            else { #expect(output.bytes[(p * 4)..<(p * 4 + 4)] == input.bytes[(p * 4)..<(p * 4 + 4)]) }
        }
    }

    @Test func strokeCoordinatesFileNamesAndExclusiveOutputs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Swivel-Retouch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var input = texture(160, 100)
        for x in 65..<78 {
            let i = (30 * 160 + x) * 4
            input.bytes[i] = 255; input.bytes[i + 1] = 0; input.bytes[i + 2] = 0
        }
        let source = try Images.save(input.image(), as: folder.appendingPathComponent("photo.png"), type: .png, quality: 1)
        let before = try Data(contentsOf: source)
        let stroke = RetouchStroke(points: [CGPoint(x: 0.4, y: 0.7), CGPoint(x: 0.5, y: 0.7)], diameter: 0.05)
        let one = try Retouch.save(source, strokes: [stroke])
        let firstBytes = try Data(contentsOf: one)
        let two = try Retouch.save(source, strokes: [stroke])
        #expect(one.lastPathComponent == "photo retouched.png")
        #expect(two.lastPathComponent == "photo retouched 2.png")
        #expect(try Data(contentsOf: source) == before)
        #expect(try Data(contentsOf: one) == firstBytes)
        let output = try Retouch.Raster(Images.load(one))
        for x in 65..<78 {
            let i = (30 * 160 + x) * 4
            #expect(output.bytes[i] == output.bytes[i + 1]) // the top-down mark was actually removed
        }
        for y in 0..<100 { for x in 0..<160 where x < 59 || x > 85 || y < 25 || y > 35 {
            let i = (y * 160 + x) * 4
            #expect(output.bytes[i..<(i + 4)] == input.bytes[i..<(i + 4)])
        } }
        let jpeg = try Images.save(input.image(), as: folder.appendingPathComponent("photo.jpg"), type: .jpeg, quality: 1)
        let savedJPEG = try Retouch.save(jpeg, strokes: [stroke])
        #expect(savedJPEG.lastPathComponent == "photo retouched.jpg")
    }

    @Test func cancellationDuringSynthesisStopsAndSavingLeavesNoPartialFile() async throws {
        let input = texture(256, 192)
        let mask = (0..<(256 * 192)).map { $0 % 256 > 80 && $0 % 256 < 180 }
        var polls = 0
        #expect(throws: Cancelled.self) {
            try Retouch.complete(input, mask: mask, cancelled: { polls += 1; return polls > 4 })
        }
        #expect(polls > 4)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Swivel-Retouch-Cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try Images.save(input.image(), as: folder.appendingPathComponent("photo.png"), type: .png, quality: 1)
        let task = Task.detached {
            try Task.checkCancellation()
            return try Retouch.save(source, strokes: [RetouchStroke(points: [CGPoint(x: 0.5, y: 0.5)], diameter: 0.3)])
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled repair unexpectedly saved a file")
        } catch is CancellationError {} catch is Cancelled {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["photo.png"])
    }

    @Test @MainActor func menuOrderTranslationsAndUndoAreStable() throws {
        let source = URL(fileURLWithPath: "/nonexistent/photo.png")
        let titles = Catalog.defaultItems(for: [source], mode: .tools).map(\.title)
        let redact = try #require(titles.firstIndex(of: "Redact"))
        #expect(titles[redact - 1] == "Retouch")
        #expect(!MCPCatalog.actions(for: [source]).contains { $0.id == "tools.Retouch" })
        for key in ["Retouch", "Brush Size", "Show Original", "Paint over an object to repair the background.",
                    "Couldn't repair this area.", "Nothing to retouch. Paint over an object first.",
                    "Leave some background unpainted to repair this area.",
                    "This repair area is too large. Use smaller, separate strokes.",
                    "This image is too large to retouch. Resize it first.",
                    "Retouch can't preserve this image's color format."] {
            let translations = try #require(Strings.table[key])
            #expect(translations.count == 3 && translations.allSatisfy { !$0.isEmpty })
        }
        let editor = try RetouchEditor(source: source)
        // The canvas callback is the same path used by mouse-up, without opening a real window.
        let canvas = try #require(editor.window.contentView?.descendantsForRetouchTest.compactMap { $0 as? RetouchCanvas }.first)
        editor.history.groupsByEvent = false
        editor.history.beginUndoGrouping()
        canvas.onCommit?(RetouchStroke(points: [CGPoint(x: 0.5, y: 0.5)], diameter: 0.02))
        editor.history.endUndoGrouping()
        #expect(editor.strokes.count == 1)
        editor.history.undo()
        #expect(editor.strokes.isEmpty)
        editor.history.redo()
        #expect(editor.strokes.count == 1)
        editor.didClose()
    }

    @Test func nativeP3AndSixteenBitPixelsOutsideTheBrushAreExact() throws {
        let width = 80, height = 60
        let stroke = RetouchStroke(points: [CGPoint(x: 0.5, y: 0.5)], diameter: 0.1)
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for p in 0..<(width * height) {
            bytes[p * 4] = 250; bytes[p * 4 + 1] = 100; bytes[p * 4 + 2] = 20
        }
        let blemish = (30 * width + 40) * 4
        bytes[blemish] = 10; bytes[blemish + 1] = 250; bytes[blemish + 2] = 10
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: p3,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                                         shouldInterpolate: false, intent: .defaultIntent))
        let result = try Retouch.render(image, strokes: [stroke])
        let raw = try #require(result.dataProvider?.data) as Data
        #expect(result.colorSpace?.name == p3.name)
        #expect(result.bitsPerComponent == 8)
        for y in 0..<height { for x in 0..<width where hypot(Double(x) + 0.5 - 40, Double(y) + 0.5 - 30) > 4 {
            let offset = (y * width + x) * 4
            #expect(raw[offset..<(offset + 4)] == Data(bytes[offset..<(offset + 4)]))
        } }
        #expect(raw[blemish..<(blemish + 4)] == Data([250, 100, 20, 255]))
        // A cropped CGImage retains its parent stride; its provider begins at the crop's first
        // pixel and can omit the last row's padding. Native donor offsets must respect both facts.
        let crop = try #require(image.cropping(to: CGRect(x: 8, y: 8, width: 64, height: 44)))
        let cropOriginal = try #require(crop.dataProvider?.data) as Data
        let cropResult = try Retouch.render(crop, strokes: [RetouchStroke(points: [CGPoint(x: 0.5, y: 0.5)], diameter: 0.1)])
        let cropBytes = try #require(cropResult.dataProvider?.data) as Data
        #expect(cropResult.bytesPerRow == crop.bytesPerRow)
        #expect(cropBytes[0..<4] == cropOriginal[0..<4])
        let cropMark = 22 * crop.bytesPerRow + 32 * 4
        #expect(cropBytes[cropMark..<(cropMark + 4)] == Data([250, 100, 20, 255]))
        // Negative control: the previous full-image sRGB round trip clips this colour even in a corner.
        let converted = try Retouch.Raster(image).image()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: p3,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(converted, in: CGRect(x: 0, y: 0, width: width, height: height))
        let clipped = try #require(context.makeImage()?.dataProvider?.data) as Data
        #expect(clipped[0..<4] != Data(bytes[0..<4]))

        var words = [UInt16](repeating: 65535, count: width * height * 4)
        for p in 0..<(width * height) {
            words[p * 4] = 56001; words[p * 4 + 1] = 23003; words[p * 4 + 2] = 1001
        }
        let wordBlemish = (30 * width + 40) * 4
        words[wordBlemish] = 100; words[wordBlemish + 1] = 50000; words[wordBlemish + 2] = 100
        let native = words.withUnsafeBytes { Data($0) }
        let deep = try #require(CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                                        bytesPerRow: width * 8, space: p3,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                                            .union(.byteOrder16Little),
                                        provider: CGDataProvider(data: native as CFData)!, decode: nil,
                                        shouldInterpolate: false, intent: .defaultIntent))
        let deepResult = try Retouch.render(deep, strokes: [stroke])
        let deepBytes = try #require(deepResult.dataProvider?.data) as Data
        #expect(deepResult.bitsPerComponent == 16 && deepResult.bitsPerPixel == 64)
        #expect(deepResult.colorSpace?.name == p3.name)
        for y in 0..<height { for x in 0..<width where hypot(Double(x) + 0.5 - 40, Double(y) + 0.5 - 30) > 4 {
            let offset = (y * width + x) * 8
            #expect(deepBytes[offset..<(offset + 8)] == native[offset..<(offset + 8)])
        } }
        // The copied donor retains low bits too; this is not an 8-bit patch in a 16-bit container.
        #expect(deepBytes[(wordBlemish * 2)..<(wordBlemish * 2 + 8)] == native[0..<8])
    }

    @Test func separatedSmallStrokesHaveBoundedWindowsAndCorrectNativeOffsets() throws {
        let width = 2000, height = 1000
        let strokes = [RetouchStroke(points: [CGPoint(x: 0.05, y: 0.1)], diameter: 0.004),
                       RetouchStroke(points: [CGPoint(x: 0.95, y: 0.9)], diameter: 0.004)]
        let windows = try Retouch.regions(width: width, height: height, strokes: strokes)
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.bounds.width * $0.bounds.height < 6000 })
        let oldUnion = windows.reduce(CGRect.null) { $0.union($1.bounds) }
        #expect(oldUnion.width * oldUnion.height > 1_000_000) // this regression would reject the old shared ROI
        var input = texture(width, height)
        let marks = [(x: 100, y: 900), (x: 1900, y: 100)]
        for mark in marks {
            let offset = (mark.y * width + mark.x) * 4
            input.bytes[offset] = 255; input.bytes[offset + 1] = 0
        }
        let output = try Retouch.render(input.image(), strokes: strokes)
        let raw = try #require(output.dataProvider?.data) as Data
        for mark in marks {
            let offset = (mark.y * width + mark.x) * 4
            #expect(raw[offset] == raw[offset + 1])
        }
        // Native source rows have a different stride from either small crop; compare untouched bytes
        // around both windows and in the large region between them without re-decoding to sRGB.
        for point in [(0, 0), (105, 880), (1800, 80), (1000, 500), (1999, 999)] {
            let offset = (point.1 * width + point.0) * 4
            #expect(raw[offset..<(offset + 4)] == Data(input.bytes[offset..<(offset + 4)]))
        }
        let near = [strokes[0], RetouchStroke(points: [CGPoint(x: 0.06, y: 0.1)], diameter: 0.004)]
        #expect(try Retouch.regions(width: width, height: height, strokes: near).count == 1)
        #expect(throws: (any Error).self) {
            try Retouch.regions(width: 4000, height: 2000,
                                strokes: [RetouchStroke(points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.9)], diameter: 0.15)])
        }
    }

    @Test func planningAndRasterPreparationCanBeCancelled() throws {
        let stroke = RetouchStroke(points: (0..<2048).map { CGPoint(x: 0.5 + Double($0 % 2) * 0.001, y: 0.5) }, diameter: 0.02)
        var planningPolls = 0
        #expect(throws: Cancelled.self) {
            try Retouch.regions(width: 1400, height: 900, strokes: [stroke],
                                cancelled: { planningPolls += 1; return planningPolls > 4 })
        }
        #expect(planningPolls > 4)
        let input = texture(800, 600)
        let mask = (0..<(800 * 600)).map { $0 % 800 > 350 && $0 % 800 < 450 }
        var tablePolls = 0
        #expect(throws: Cancelled.self) {
            try Retouch.complete(input, mask: mask, cancelled: { tablePolls += 1; return tablePolls > 8 })
        }
        #expect(tablePolls > 8)
        var maskPolls = 0
        let image = try input.image()
        #expect(throws: Cancelled.self) {
            try Retouch.render(image, strokes: [RetouchStroke(points: [CGPoint(x: 0.5, y: 0.5)], diameter: 0.2)],
                               cancelled: { maskPolls += 1; return maskPolls > 10 })
        }
        #expect(maskPolls > 10)
    }

    @Test func previewSizedLocalRepairHasATimedMeasurement() throws {
        let input = try texture(1400, 900).image()
        let clock = ContinuousClock()
        let start = clock.now
        _ = try Retouch.render(input, strokes: [RetouchStroke(points: [CGPoint(x: 0.5, y: 0.5)], diameter: 0.04)])
        let elapsed = start.duration(to: clock.now)
        print("Retouch 1400px preview, 56px brush: \(elapsed)")
        #expect(elapsed < .seconds(1))
    }
}

private extension NSView {
    var descendantsForRetouchTest: [NSView] { subviews.flatMap { [$0] + $0.descendantsForRetouchTest } }
}
