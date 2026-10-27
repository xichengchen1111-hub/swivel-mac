import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Swivel

@Suite(.serialized)
@MainActor
struct StitchContactTests {
    private let source = URL(fileURLWithPath: "/tmp/contact-source.png")
    private let target = URL(fileURLWithPath: "/tmp/contact-target.png")
    private let output = URL(fileURLWithPath: "/tmp/contact-joined.png")

    private func screenshot(_ title: String, color: NSColor) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: 360, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 360, height: 240))
        ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 170, width: 360, height: 70))
        for i in 0..<4 {
            ctx.setFillColor(NSColor(white: 0.7 + CGFloat(i) * 0.045, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 24, y: 130 - i * 29, width: 250 - i * 30, height: 9))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (title as NSString).draw(at: CGPoint(x: 24, y: 190), withAttributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return try #require(ctx.makeImage())
    }

    private func scene() throws -> (RopeView, CALayer, CALayer, CGImage, CGImage) {
        let a = try screenshot("SCREENSHOT A", color: .systemBlue)
        let b = try screenshot("SCREENSHOT B", color: .systemOrange)
        let view = RopeView(frame: CGRect(x: 0, y: 0, width: 650, height: RopePanel.stitchHeight))
        view.reducedMotionOverride = false
        view.markNew(source, arrival: .inPlace, thumbnail: a)
        view.markNew(target, arrival: .inPlace, thumbnail: b)
        view.setItems([source, target]); view.drop(fromHidden: true)
        for _ in 0..<600 { _ = view.advance(1 / 120) }
        let photos = (view.layer?.sublayers ?? []).filter { $0.contents != nil }
        return (view, try #require(photos.first), try #require(photos.last), a, b)
    }

    @Test func nearContactKeepsTwoBodiesAndNeverArmsAnOutsideDrop() throws {
        let (view, a, b, _, _) = try scene()
        let near = CGPoint(x: b.frame.minX - a.bounds.width / 2 - 15, y: b.frame.midY)
        view.updateStitchTarget(source: source, point: near)
        for _ in 0..<80 { _ = view.advance(1 / 120) }
        #expect(view.stitchIntent.target == nil)
        let overlay = try #require(view.layer?.sublayers?.first?.sublayers?.first)
        let bodies = try #require(overlay.sublayers)
        #expect((bodies[0] as? CAShapeLayer)?.path == nil) // side proximity does not join unrelated edges
        #expect(abs(bodies[1].bounds.width - b.bounds.width) < 0.01)
        #expect(abs(bodies[2].bounds.width - a.bounds.width) < 0.01)
        #expect(bodies[3].opacity == 0) // the combined thumbnail is not shown during contact
        view.commitStitchPreview()
        #expect(!view.isCommittingStitch)

        let centre = b.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), to: view.layer)
        view.updateStitchTarget(source: source, point: centre, now: CACurrentMediaTime() - 1)
        _ = view.advance(1 / 60)
        #expect(view.stitchHintText == "Release to stitch · Originals kept")
        view.updateStitchTarget(source: source, point: near)
        #expect(view.stitchIntent.target == nil)
        view.updateStitchTarget(source: source, point: centre)
        #expect(view.stitchHintText == "Hold briefly to stitch")
        #expect(!view.stitchIntent.ready(at: CACurrentMediaTime()))
    }

    @Test func heldEdgeIsAlreadyOneContourAndReleaseDoesNotRejoin() throws {
        for reduced in [false, true] {
            let (view, a, b, _, _) = try scene()
            view.reducedMotionOverride = reduced
            let edge = CGPoint(x: b.frame.midX, y: b.frame.maxY + a.bounds.height / 2)
            view.updateStitchTarget(source: source, point: edge, now: CACurrentMediaTime() - 1)
            for _ in 0..<180 { _ = view.advance(1 / 120) }
            #expect(view.stitchIntent.target == target && !view.isCommittingStitch)
            #expect(view.stitchHintText == "Release to stitch · Originals kept")
            let overlay = try #require(view.layer?.sublayers?.first?.sublayers?.first)
            let bodies = try #require(overlay.sublayers)
            let top = bodies[1].frame, bottom = bodies[2].frame
            #expect(abs(top.maxY - bottom.minY) < 0.01)
            #expect(abs(top.midX - bottom.midX) < 0.01)
            #expect(top.size == b.bounds.size && bottom.size == a.bounds.size)
            #expect(CATransform3DIsIdentity(bodies[1].transform) && CATransform3DIsIdentity(bodies[2].transform))
            #expect((bodies[0] as? CAShapeLayer)?.path != nil)
            // A held seam is only a preview. Pulling away cancels without submitting work.
            view.updateStitchTarget(source: source, point: CGPoint(x: -100, y: 300))
            view.commitStitchPreview()
            #expect(!view.isCommittingStitch && view.stitchIntent.target == nil)
            // Release starts from the exact attached geometry; it never flashes back to separate bodies.
            view.updateStitchTarget(source: source, point: edge, now: CACurrentMediaTime() - 1)
            for _ in 0..<180 { _ = view.advance(1 / 120) }
            let beforeTop = bodies[1].frame, beforeBottom = bodies[2].frame
            view.commitStitchPreview()
            _ = view.advance(0)
            if !reduced {
                #expect(bodies[1].frame == beforeTop && bodies[2].frame == beforeBottom)
                #expect(bodies[3].opacity == 0)
            }
            #expect(view.isCommittingStitch)
            view.clearStitchTarget(force: true)
        }
    }

    @Test func completedFileHasABoundedHandoffEvenWithoutDisplayFrames() async throws {
        let (view, _, b, _, _) = try scene()
        let centre = b.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), to: view.layer)
        view.updateStitchTarget(source: source, point: centre)
        _ = view.advance(1 / 60)
        view.commitStitchPreview()
        var handoffs = 0
        view.onStitchHandoff = { handoffs += 1 }
        view.finishStitchPreview(output: output)
        view.finishStitchPreview() // the worker's defer must not erase a successful queued result
        #expect(view.isCommittingStitch && handoffs == 0)
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline && handoffs == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(handoffs == 1 && !view.isCommittingStitch)
    }

    @Test func downwardContactFitsExpandedPanelAndItsTopNeverMoves() throws {
        let (view, a, b, _, _) = try scene()
        let panel = RopePanel(rope: view)
        defer { panel.orderOut(nil) }
        let top = panel.frame.maxY
        panel.setStitchTracking(true)
        #expect(panel.frame.maxY == top)
        #expect(view.bounds.height == RopePanel.stitchHeight)
        view.isDraggingItem = true
        defer { view.isDraggingItem = false }
        view.drop(fromHidden: true)
        for _ in 0..<240 { _ = view.advance(1 / 120) }
        let below = CGPoint(x: b.frame.midX, y: b.frame.maxY + a.bounds.height / 2 + 15)
        view.updateStitchTarget(source: source, point: below)
        for _ in 0..<100 { _ = view.advance(1 / 120) }
        let overlay = try #require(view.layer?.sublayers?.first?.sublayers?.first)
        let bottom = try #require(overlay.sublayers?[2])
        let bodyOnRope = overlay.convert(bottom.frame, to: view.layer)
        #expect(bodyOnRope.maxY > RopePanel.height)
        #expect(bodyOnRope.maxY < view.bounds.height)
        #expect(bottom.opacity > 0.99 && view.stitchIntent.target == nil)
        view.lift {}
        #expect(panel.frame.height == RopePanel.height && panel.frame.maxY == top)
    }

    @Test func renderContinuousContactFilms() throws {
        guard let path = ProcessInfo.processInfo.environment["SWIVEL_STITCH_CONTACT_FILMS"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for below in [false, true] {
            let (view, a, b, first, second) = try scene()
            let url = folder.appendingPathComponent(below ? "contact-below.gif" : "contact-side.gif")
            let gif = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 200, nil))
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let from = below ? CGPoint(x: b.frame.midX, y: b.frame.maxY + a.bounds.height / 2 + 24)
                : CGPoint(x: a.frame.midX, y: a.frame.midY)
            let to = CGPoint(x: b.frame.midX, y: b.frame.maxY + a.bounds.height / 2)
            let merged = try ImageStitch.render(top: second, bottom: first)
            if !below {
                _ = try Images.save(first, as: folder.appendingPathComponent("fixture-a.png"), type: .png, quality: 1)
                _ = try Images.save(second, as: folder.appendingPathComponent("fixture-b.png"), type: .png, quality: 1)
            }
            view.onStitchHandoff = { [weak view] in view?.setItems([output]) }
            for frame in 0..<200 {
                if frame >= 10 && frame < 112 {
                    let t = min(CGFloat(frame - 10) / 36, 1)
                    let eased = t * t * (3 - 2 * t)
                    view.updateStitchTarget(source: source, point: CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased), now: 0)
                }
                if frame == 112 { view.commitStitchPreview() }
                if frame == 113 {
                    view.markNew(output, arrival: .inPlace, thumbnail: merged)
                    view.finishStitchPreview(output: output)
                }
                _ = view.advance(1 / 50)
                let ctx = try #require(CGContext(data: nil, width: 650, height: Int(RopePanel.stitchHeight), bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.setFillColor(NSColor(white: 0.18, alpha: 1).cgColor); ctx.fill(view.bounds)
                ctx.translateBy(x: 0, y: view.bounds.height); ctx.scaleBy(x: 1, y: -1)
                view.layer?.render(in: ctx)
                let image = try #require(ctx.makeImage())
                CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.02]] as CFDictionary)
                if [18, 36, 60, 100, 112, 130, 160].contains(frame) {
                    _ = try Images.save(image, as: folder.appendingPathComponent("\(below ? "below" : "side")-\(frame).png"), type: .png, quality: 1)
                }
            }
            #expect(CGImageDestinationFinalize(gif))
        }
    }
}
