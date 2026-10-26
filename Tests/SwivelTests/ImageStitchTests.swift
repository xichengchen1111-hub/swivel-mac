import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Swivel

@Suite(.serialized)
struct ImageStitchTests {
    private func image(_ w: Int, _ h: Int, _ color: CGColor) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try #require(ctx.makeImage())
    }

    @Test func intentRequiresAnUninterruptedOverlap() {
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.png")
        var intent = RopeStitchIntent()
        intent.update(a, now: 10)
        #expect(!intent.ready(at: 10.2))
        intent.update(a, now: 10.2) // updates must not restart the dwell
        #expect(intent.ready(at: 10.3))
        intent.update(b, now: 11)
        #expect(!intent.ready(at: 11.1))
        intent.update(nil, now: 11.4)
        #expect(!intent.ready(at: 20))
        intent.update(a, now: 20)
        #expect(!intent.ready(at: 20.1))
    }

    @Test func anEngagedPreviewToleratesSmallPointerMovementWithoutWideningInitialEntry() {
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 100)
        let edge = CGPoint(x: 10, y: 50)
        #expect(!RopeStitchIntent.hitArea(in: bounds, engaged: false).contains(edge))
        #expect(RopeStitchIntent.hitArea(in: bounds, engaged: true).contains(edge))
        #expect(!RopeStitchIntent.hitArea(in: bounds, engaged: true).contains(CGPoint(x: -1, y: 50)))
    }

    @Test func jellyFillsItsWaistAndSettlesWithOneSmallRebound() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 120)
        let contact = RopeStitchJelly.outline(in: bounds, seam: 0.5, progress: 0)
        let merged = RopeStitchJelly.outline(in: bounds, seam: 0.5, progress: 1)
        #expect(!contact.contains(CGPoint(x: 5, y: 60)))
        #expect(merged.contains(CGPoint(x: 5, y: 60)))
        for seam: CGFloat in [0.01, 0.5, 0.99] {
            for step in 0...20 {
                let path = RopeStitchJelly.outline(in: bounds, seam: seam, progress: CGFloat(step) / 20)
                #expect(bounds.contains(path.boundingBoxOfPath))
            }
        }
        var spring = Spring(0, response: RopeStitchJelly.response, damping: RopeStitchJelly.damping)
        spring.target = 1
        var peak: CGFloat = 0
        for _ in 0..<240 {
            spring.step(1 / 240)
            peak = max(peak, spring.value)
            let pulse = sin(.pi * spring.value)
            #expect(1 + 0.1 * pulse >= 0.98 && 1 + 0.1 * pulse <= 1.101)
            #expect(1 - 0.06 * pulse >= 0.939 && 1 - 0.06 * pulse <= 1.02)
        }
        #expect(peak > 1 && peak < 1.06)
        #expect(abs(spring.value - 1) < 0.001)
        #expect(RopeStitchJelly.damping >= 0.6)
    }

    @Test @MainActor func cancellationCrossfadesBackAndCommitSurvivesDragCleanup() throws {
        let a = URL(fileURLWithPath: "/tmp/feel-a.png"), b = URL(fileURLWithPath: "/tmp/feel-b.png")
        let output = URL(fileURLWithPath: "/tmp/feel-stitched.png")
        let thumb = try image(100, 60, CGColor(gray: 0.5, alpha: 1))
        for reduced in [false, true] {
            let view = RopeView(frame: CGRect(x: 0, y: 0, width: 1000, height: 230))
            view.reducedMotionOverride = reduced
            for url in [a, b] { view.markNew(url, arrival: .inPlace, thumbnail: thumb) }
            view.setItems([a, b])
            view.drop(fromHidden: true)
            for _ in 0..<240 { _ = view.advance(1 / 120) }
            let layers = view.layer?.sublayers ?? []
            let match = layers.first { $0.contents != nil && $0.position.x > 200 }
            let target = try #require(match)
            let source = try #require(layers.first { $0.contents != nil && $0.position.x < 200 })
            let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: view.layer)
            view.updateStitchTarget(source: a, point: point)
            for _ in 0..<100 { _ = view.advance(1 / 120) }
            #expect(target.opacity < 0.01)
            // The wider exit area retains the selected target and its original dwell timestamp.
            let edge = target.convert(CGPoint(x: 10, y: 40), to: view.layer)
            view.updateStitchTarget(source: a, point: edge)
            #expect(view.stitchIntent.target == b)
            view.clearStitchTarget()
            #expect(view.stitchIntent.target == nil) // commit cancels immediately, before the reverse animation
            _ = view.advance(1 / 120)
            if !reduced { #expect(target.opacity < 0.2) } // no one-frame flash of the original
            for _ in 0..<100 { _ = view.advance(1 / 120) }
            #expect(target.opacity > 0.99)

            view.updateStitchTarget(source: a, point: point)
            for _ in 0..<100 { _ = view.advance(1 / 120) }
            view.commitStitchPreview()
            view.clearStitchTarget() // both AppKit draggingEnded callbacks must leave the pending result visible
            #expect(view.isCommittingStitch && view.isHandlingPrint)
            for _ in 0..<100 { _ = view.advance(1 / 120) }
            #expect(source.opacity < 0.01 && target.opacity < 0.01)
            if reduced { #expect(!view.needsFrames) } // an export waiting on disk must not spin an idle display link
            let overlay = try #require(view.layer?.sublayers?.first?.sublayers?.first)
            let previewPosition = overlay.position
            view.markNew(output, arrival: .inPlace, thumbnail: try ImageStitch.render(top: thumb, bottom: thumb))
            view.finishStitchPreview(output: output)
            view.setItems([output])
            #expect(!view.isCommittingStitch)
            let result = try #require(view.layer?.sublayers?.last)
            let firstPosition = result.position
            if reduced {
                #expect(firstPosition.x < previewPosition.x - 50)
            } else {
                #expect(abs(firstPosition.x - previewPosition.x) < 0.01)
                #expect(abs(firstPosition.y - previewPosition.y) < 0.01)
            }
            for _ in 0..<240 { _ = view.advance(1 / 120) }
            #expect(result.opacity > 0.99)
            if reduced { #expect(result.position == firstPosition) }
            #expect(result.position.x < previewPosition.x - 50) // slides to its new slot from the merge, not vice versa
        }
    }

    @Test @MainActor func aFailedOrDisabledCommitRestoresBothOriginalPrints() throws {
        let a = URL(fileURLWithPath: "/tmp/recover-a.png"), b = URL(fileURLWithPath: "/tmp/recover-b.png")
        let thumb = try image(100, 60, CGColor(gray: 0.5, alpha: 1))
        let view = RopeView(frame: CGRect(x: 0, y: 0, width: 1000, height: 230))
        view.reducedMotionOverride = true
        for url in [a, b] { view.markNew(url, arrival: .inPlace, thumbnail: thumb) }
        view.setItems([a, b]); view.drop(fromHidden: true)
        for _ in 0..<240 { _ = view.advance(1 / 120) }
        let layers = view.layer?.sublayers ?? []
        let target = try #require(layers.first { $0.contents != nil && $0.position.x > 200 })
        let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: view.layer)
        for force in [false, true] {
            view.updateStitchTarget(source: a, point: point)
            view.commitStitchPreview(); _ = view.advance(1 / 60)
            if force { view.clearStitchTarget(force: true) } else { view.finishStitchPreview() }
            for _ in 0..<240 { _ = view.advance(1 / 120) }
            #expect(!view.isCommittingStitch && view.stitchIntent.target == nil)
            #expect(layers.filter { $0.contents != nil }.allSatisfy { $0.opacity > 0.99 })
        }
    }

    @Test func matchesWidthsWithoutCroppingOrEnlargementAndBoundsTheCanvas() throws {
        let s = try ImageStitch.size(top: CGSize(width: 400, height: 200), bottom: CGSize(width: 200, height: 300))
        #expect(s.width == 200 && s.top == 100 && s.bottom == 300)
        for invalid in [CGSize(width: 0, height: 20), CGSize(width: CGFloat.infinity, height: 20),
                        CGSize(width: 1, height: 32768), CGSize(width: 10000, height: 10000)] {
            #expect(throws: (any Error).self) { try ImageStitch.size(top: invalid, bottom: invalid) }
        }
    }

    @Test func writesTopThenBottomAndRetainsTransparentPixelsAndOriginals() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let top = try Images.save(image(20, 10, CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                                  as: folder.appendingPathComponent("a.png"), type: .png, quality: 1)
        let bottom = try Images.save(image(10, 20, CGColor(red: 0, green: 0, blue: 1, alpha: 0.5)),
                                     as: folder.appendingPathComponent("b.png"), type: .png, quality: 1)
        let originals = try [Data(contentsOf: top), Data(contentsOf: bottom)]
        let first = try ImageStitch.save(top: top, bottom: bottom)
        let saved = try Data(contentsOf: first)
        let second = try ImageStitch.save(top: top, bottom: bottom)
        #expect(first != second)
        #expect(first.deletingLastPathComponent().path == folder.path)
        #expect(try Data(contentsOf: first) == saved)
        #expect(try Data(contentsOf: top) == originals[0])
        #expect(try Data(contentsOf: bottom) == originals[1])
        let result = try Images.load(first)
        #expect(result.width == 10 && result.height == 25)
        let rep = NSBitmapImageRep(cgImage: result)
        let red = try #require(rep.colorAt(x: 5, y: 2)?.usingColorSpace(.sRGB))
        let blue = try #require(rep.colorAt(x: 5, y: 22)?.usingColorSpace(.sRGB))
        #expect(red.redComponent > 0.99 && red.blueComponent < 0.01 && red.alphaComponent > 0.99)
        #expect(blue.blueComponent > 0.99 && blue.redComponent < 0.05 && abs(blue.alphaComponent - 0.5) < 0.01, "blue=\(blue)")
        // A generated image can be stitched again, without overwriting the intermediate.
        let third = try ImageStitch.save(top: first, bottom: bottom)
        #expect(try Images.load(third).height == 45)
        #expect(try Data(contentsOf: first) == saved)
        let link = folder.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: top)
        #expect(throws: (any Error).self) { try ImageStitch.save(top: link, bottom: bottom) }
        #expect(throws: (any Error).self) { try ImageStitch.save(top: top, bottom: top) }
    }

    @Test func honorsOrientationAndRefusesAnimatedSources() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try image(20, 10, CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let rotated = folder.appendingPathComponent("rotated.jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(rotated as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, photo, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let png = try Images.save(photo, as: folder.appendingPathComponent("bottom.png"), type: .png, quality: 1)
        let output = try Images.load(ImageStitch.save(top: rotated, bottom: png))
        #expect(output.width == 10 && output.height == 25)
        // TIFF multi-page is a still-image extension too, but must not silently lose pages.
        let multi = folder.appendingPathComponent("multi.tiff")
        let frames = try #require(CGImageDestinationCreateWithURL(multi as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(frames, photo, nil)
        CGImageDestinationAddImage(frames, photo, nil)
        #expect(CGImageDestinationFinalize(frames))
        #expect(throws: (any Error).self) { try ImageStitch.save(top: multi, bottom: png) }
        #expect(!ImageStitch.supports(folder.appendingPathComponent("clip.mov")))
    }

    @Test func cancellationLeavesOnlyOriginals() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try image(20, 10, CGColor(gray: 0.5, alpha: 1))
        let a = try Images.save(photo, as: folder.appendingPathComponent("a.png"), type: .png, quality: 1)
        let b = try Images.save(photo, as: folder.appendingPathComponent("b.png"), type: .png, quality: 1)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try ImageStitch.save(top: a, bottom: b)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("A cancelled stitch published a file") }
        catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["a.png", "b.png"])
    }

    @Test @MainActor func previewFrames() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIVEL_STITCH_FRAMES"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = URL(fileURLWithPath: "/tmp/stitch-a.png"), b = URL(fileURLWithPath: "/tmp/stitch-b.png")
        for reduced in [false, true] {
            let view = RopeView(frame: CGRect(x: 0, y: 0, width: 650, height: 220))
            view.reducedMotionOverride = reduced
            view.markNew(a, arrival: .inPlace, thumbnail: try image(200, 120, NSColor.systemBlue.cgColor))
            view.markNew(b, arrival: .inPlace, thumbnail: try image(200, 120, NSColor.systemOrange.cgColor))
            view.setItems([a, b])
            view.drop(fromHidden: true)
            for _ in 0..<300 { _ = view.advance(1 / 120) }
            let layers = view.layer?.sublayers ?? []
            let match = layers.first { $0.contents != nil && $0.zPosition < 20 && $0.position.x > 200 }
            let target = try #require(match)
            let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: view.layer)
            for stage in 0..<4 {
                if stage == 1 { view.updateStitchTarget(source: a, point: point, now: CACurrentMediaTime() - 1) }
                if stage == 3 { view.clearStitchTarget() }
                let frames = stage == 1 ? 8 : 100
                for _ in 0..<frames { _ = view.advance(1 / 120) }
                let ctx = try #require(CGContext(data: nil, width: 1300, height: 440, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.scaleBy(x: 2, y: 2)
                ctx.setFillColor(NSColor(white: 0.22, alpha: 1).cgColor)
                ctx.fill(view.bounds)
                ctx.translateBy(x: 0, y: 220)
                ctx.scaleBy(x: 1, y: -1)
                view.layer?.render(in: ctx)
                let result = try #require(ctx.makeImage())
                _ = try Images.save(result, as: folder.appendingPathComponent("\(reduced ? "reduced" : "normal")-\(stage).png"), type: .png, quality: 1)
            }
        }
    }

    @Test @MainActor func overlapPreviewCancelsOnExitRemovalAndLift() throws {
        let a = URL(fileURLWithPath: "/tmp/stitch-a.png"), b = URL(fileURLWithPath: "/tmp/stitch-b.png")
        let thumb = try image(100, 60, CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        let view = RopeView(frame: CGRect(x: 0, y: 0, width: 1000, height: 230))
        view.reducedMotionOverride = true
        view.markNew(a, arrival: .inPlace, thumbnail: thumb)
        view.markNew(b, arrival: .inPlace, thumbnail: thumb)
        view.setItems([a, b])
        view.drop(fromHidden: true)
        for _ in 0..<240 { _ = view.advance(1 / 120) }
        let layers = view.layer?.sublayers ?? []
        let match = layers.first { layer in
            layer.contents != nil && layer.zPosition < 20 && layer.bounds.width > 1 && layer.position.x > 200
        }
        let target = try #require(match)
        let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: view.layer)
        view.updateStitchTarget(source: a, point: point)
        #expect(view.stitchIntent.target == b)
        _ = view.advance(1 / 60)
        #expect(target.opacity == 0) // Reduce Motion shows the preview immediately, without travel/scale.
        view.updateStitchTarget(source: a, point: CGPoint(x: 900, y: 200))
        #expect(view.stitchIntent.target == nil)
        _ = view.advance(1 / 60)
        #expect(target.opacity == 1)
        view.updateStitchTarget(source: a, point: point)
        view.setItems([a])
        #expect(view.stitchIntent.target == nil)
        view.markNew(b, arrival: .inPlace, thumbnail: thumb)
        view.setItems([a, b])
        view.updateStitchTarget(source: a, point: point)
        view.lift {}
        #expect(view.stitchIntent.target == nil)
    }
}
