import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Swivel

/// The clothesline's motion: gentle and well damped (the owner's rule), interruptible, and laid out so a drop lands
/// where the print will hang. Set SWIVEL_ROPE_FRAMES=<folder> to also render filmstrips of the rope and the card.
@Suite(.serialized)
@MainActor
struct ClotheslineFeelTests {
    // MARK: Physics

    /// One oscillator from (x0, v0) toward 0, stepped exactly as the rope steps it.
    private func simulate(_ o: RopeTuning.Oscillator, x0: CGFloat, v0: CGFloat, seconds: CGFloat = 3) -> [CGFloat] {
        var x = x0, v = v0
        return (0..<Int(seconds / RopeTuning.step)).map { _ in
            RopeTuning.advance(&x, &v, toward: 0, o)
            return x
        }
    }

    /// Turning points bigger than `visible`, and the time after which the motion stays below it.
    private func swings(_ xs: [CGFloat], visible: CGFloat) -> (count: Int, settled: CGFloat) {
        var count = 0
        for i in 1..<(xs.count - 1) where abs(xs[i]) > visible && (xs[i] - xs[i - 1]) * (xs[i + 1] - xs[i]) <= 0 {
            count += 1
        }
        let last = xs.lastIndex { abs($0) > visible } ?? -1
        return (count, CGFloat(last + 1) * RopeTuning.step)
    }

    @Test func testEverythingThatSwingsIsWellDamped() {
        for (name, o) in [("sag", RopeTuning.sag), ("swing", RopeTuning.swing), ("arrive", RopeTuning.arrive)] {
            #expect(o.dampingRatio >= 0.6, "\(name) ζ = \(o.dampingRatio)")
        }
        #expect(RopeTuning.fall.dampingRatio >= 0.7)
        for (name, d) in [("lift", RopeTuning.lift.damping), ("press out", RopeTuning.pressOut.damping), ("slide", RopeTuning.slide.damping)] {
            #expect(d >= 0.6, "\(name) damping \(d)")
        }
    }

    @Test func testStrongestSwingIsSmallAndSettlesWithinTwoOscillations() {
        let kick = max(RopeTuning.arrivalSwingFromAbove.upperBound, RopeTuning.dropKick.upperBound)
        let angles = simulate(RopeTuning.swing, x0: 0, v0: kick)
        let halfDegree = 0.5 * CGFloat.pi / 180
        let result = swings(angles, visible: halfDegree)
        #expect((angles.map(abs).max() ?? 0) < 4 * .pi / 180, "peak swing too large")
        #expect(result.count <= 2, "\(result.count) visible swings")
        #expect(result.settled <= 1.5, "settles after \(result.settled) s")
    }

    @Test func testNewPrintFallsOntoTheRopeAndSettles() {
        let drop = simulate(RopeTuning.arrive, x0: RopeTuning.arrivalHeight, v0: 0)
        let result = swings(drop, visible: 0.5)
        #expect(result.count <= 2)
        #expect((drop.max() ?? 0) < 6, "bounces \(drop.max() ?? 0) pt below the rope")
        #expect(result.settled <= 1.5)
    }

    @Test func testRopeLowersWithASingleGentleDipInTheCord() {
        var offset = -RopePanel.height, offsetV: CGFloat = 0, sag: CGFloat = 0, sagV: CGFloat = 0
        var offsets: [CGFloat] = [], sags: [CGFloat] = []
        for _ in 0..<Int(3 / RopeTuning.step) {
            let a = RopeTuning.advance(&offset, &offsetV, toward: 0, RopeTuning.fall)
            RopeTuning.advance(&sag, &sagV, toward: 0, RopeTuning.sag, force: -RopeTuning.sagCoupling * a)
            offsets.append(offset)
            sags.append(sag)
        }
        #expect((offsets.max() ?? 0) < 6, "rope overshoots \(offsets.max() ?? 0) pt")
        #expect(swings(offsets, visible: 0.5).settled <= 1.0)
        let cord = swings(sags, visible: 0.5)
        #expect((sags.map(abs).max() ?? 0) < 4, "cord dips \(sags.map(abs).max() ?? 0) pt")
        #expect(cord.count <= 2 && cord.settled <= 1.5, "cord: \(cord)")
    }

    // MARK: Pure helpers

    @Test func testSlotsOpenRoomAtTheFrontForADrop() {
        let plain = RopeTuning.slots(widths: [100, 120, 80], in: 520)
        #expect(plain.map(\.x) == [126, 258, 380])
        #expect(plain.map(\.fits) == [true, true, true])
        let gapped = RopeTuning.slots(widths: [100, 120, 80], in: 520, gap: 122)
        #expect(gapped.map(\.x) == [248, 380, 502])
        #expect(gapped.map(\.fits) == [true, true, false])   // pushed past the right edge
    }

    @Test func testPrintSizeFitsThePictureInsideTheMaximum() {
        #expect(RopeTuning.printSize(aspect: 1.5) == CGSize(width: 178, height: 122))
        #expect(RopeTuning.printSize(aspect: 3) == CGSize(width: 178, height: 66))
        #expect(RopeTuning.printSize(aspect: 0.5) == CGSize(width: 66, height: 122))
    }

    @Test func testRopePathIsExactlyTheSagParabola() {
        let width: CGFloat = 1440, y: CGFloat = 18, sag: CGFloat = 16
        var points: [CGPoint] = []
        RopeTuning.ropePath(width: width, y: y, sag: sag).applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .addQuadCurveToPoint: points = [e.points[0], e.points[1]]
            default: break
            }
        }
        #expect(points.count == 2)
        let control = points[0], end = points[1]
        for t in stride(from: CGFloat(0), through: 1, by: 0.125) {
            let x = 2 * t * (1 - t) * control.x + t * t * end.x
            let by = (1 - t) * (1 - t) * y + 2 * t * (1 - t) * control.y + t * t * end.y
            let u = x / width
            #expect(abs(by - (y + sag * 4 * u * (1 - u))) < 1e-6, "off the parabola at t = \(t)")
        }
    }

    @Test func testTimingCurvesAreMonotonicAndHitTheirEnds() {
        for curve in [(0.3, 0.0, 0.2, 1.0), (0.4, 0.0, 1.0, 1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            var last: CGFloat = 0
            for i in 0...100 {
                let v = RopeTuning.ease(CGFloat(i) / 100, curve.0, curve.1, curve.2, curve.3)
                #expect(v >= last - 1e-6)
                last = v
            }
            #expect(abs(RopeTuning.ease(0, curve.0, curve.1, curve.2, curve.3)) < 1e-4)
            #expect(abs(RopeTuning.ease(1, curve.0, curve.1, curve.2, curve.3) - 1) < 1e-4)
        }
        #expect(RopeTuning.ease(0.5, 0.4, 0, 1, 1) < 0.5)   // an exit accelerates away
        #expect(RopeTuning.ease(0.5, 0.3, 0, 0.2, 1) > 0.5)  // the flight arrives gently
    }

    @Test func testHoldingGathersFromAFifthOfASecond() {
        #expect(RopeTuning.charge(heldFor: 0.1) == 0)
        #expect(abs(RopeTuning.charge(heldFor: 0.375) - 0.5) < 1e-6)
        #expect(RopeTuning.charge(heldFor: 0.9) == 1)
    }

    @Test func testRopeWaitsLongerWhileThePointerReachesAlongIt() {
        #expect(RopeTuning.hideDelay(overPrint: true, inMenuBar: false, nearPrints: true, inStrip: true) == nil)
        #expect(RopeTuning.hideDelay(overPrint: false, inMenuBar: true, nearPrints: false, inStrip: false) == nil)
        #expect(RopeTuning.hideDelay(overPrint: false, inMenuBar: false, nearPrints: true, inStrip: true) == 1.5)
        #expect(RopeTuning.hideDelay(overPrint: false, inMenuBar: false, nearPrints: false, inStrip: true) == 1.0)
        #expect(RopeTuning.hideDelay(overPrint: false, inMenuBar: false, nearPrints: false, inStrip: false) == 0.5)
    }

    // MARK: The rope view

    private nonisolated static let fixtures: [URL] = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-rope-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let specs: [(Int, Int, CGFloat)] = [(1600, 1000, 0.58), (900, 1200, 0.08), (1200, 1200, 0.33), (1800, 900, 0.85)]
        return specs.enumerated().map { n, spec in
            let url = folder.appendingPathComponent("print-\(n).png")
            if !FileManager.default.fileExists(atPath: url.path),
               let ctx = CGContext(data: nil, width: spec.0, height: spec.1, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(NSColor(calibratedHue: spec.2, saturation: 0.5, brightness: 0.9, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: spec.0, height: spec.1))
                ctx.setFillColor(NSColor(calibratedHue: spec.2, saturation: 0.7, brightness: 0.55, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 0, y: spec.1 * 2 / 3, width: spec.0, height: spec.1 / 3))  // a darker top band
                if let image = ctx.makeImage(),
                   let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
            return url
        }
    }()

    private func rope(_ urls: [URL] = Array(fixtures.prefix(3)), reduced: Bool = false) -> RopeView {
        let view = RopeView(frame: NSRect(x: 0, y: 0, width: 900, height: RopePanel.height))
        view.unregisterDraggedTypes()
        view.reducedMotionOverride = reduced
        view.setItems(urls)
        return view
    }

    private func run(_ view: RopeView, for seconds: CGFloat, fps: CGFloat = 120) {
        for _ in 0..<Int(seconds * fps) { view.advance(1 / fps) }
    }

    /// The print layers, in rope order (the rope's own shape layer comes first).
    private func printLayers(_ view: RopeView) -> [CALayer] { Array(view.layer!.sublayers!.dropFirst()) }

    @Test func testReadyDropTurnsRopeBlueThenRestoresTheChosenColor() throws {
        let old = Prefs.clotheslineColors
        defer { Prefs.clotheslineColors = old }
        var colors = old
        colors.rope = RopeColorPreset.sage.rgb!
        Prefs.clotheslineColors = colors
        for reduced in [false, true] {
            let view = rope(reduced: reduced)
            view.drop(fromHidden: true)
            run(view, for: 0.5)
            let cord = try #require(view.layer?.sublayers?.first as? CAShapeLayer)
            var frames: [(String, CGImage)] = []
            if Self.framesFolder != nil, let image = snapshot(view.layer!, size: view.bounds.size, flipped: true) { frames.append(("idle", image)) }
            view.setReceivingHighlight(Self.fixtures[0])
            run(view, for: 0.5)
            let ready = try #require(cord.strokeColor.flatMap(NSColor.init(cgColor:))).usingColorSpace(.sRGB)!
            let blue = NSColor.systemBlue.usingColorSpace(.sRGB)!
            #expect(abs(ready.redComponent - blue.redComponent) < 0.005)
            #expect(abs(ready.blueComponent - blue.blueComponent) < 0.005)
            #expect(cord.lineWidth > 4.9)
            #expect(cord.shadowOpacity > 0.39)
            #expect(Prefs.clotheslineColors == colors)
            if Self.framesFolder != nil, let image = snapshot(view.layer!, size: view.bounds.size, flipped: true) { frames.append(("release to hang", image)) }
            view.setReceivingHighlight(nil)
            run(view, for: 0.5)
            #expect(cord.strokeColor == colors.rope.color.cgColor)
            #expect(abs(cord.lineWidth - 2.6) < 0.01)
            #expect(cord.shadowOpacity < 0.19)
            if let folder = Self.framesFolder, let image = snapshot(view.layer!, size: view.bounds.size, flipped: true) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                frames.append(("restored", image))
                strip(frames, to: folder.appendingPathComponent("rope-ready-\(reduced ? "reduced" : "normal").png"))
            }
        }
    }

    @Test func testReadyDropRequiresSupportedMediaAndAPermittedOperation() {
        #expect(RopeDropFeedback.operation(offered: [.copy, .move], acceptsMedia: true) == .move)
        #expect(RopeDropFeedback.operation(offered: .copy, acceptsMedia: true) == .copy)
        #expect(RopeDropFeedback.operation(offered: .generic, acceptsMedia: true) == .generic)
        for offered: NSDragOperation in [[], .delete, .link] {
            #expect(RopeDropFeedback.operation(offered: offered, acceptsMedia: true).isEmpty)
        }
        #expect(RopeDropFeedback.operation(offered: [.copy, .move], acceptsMedia: false).isEmpty)
    }

    @Test func testHiddenRopeStaysHiddenUntilLowered() {
        let view = rope()
        run(view, for: 1)
        #expect(view.ropeY(450) < 0, "the hidden simulation lowered the rope")
        view.drop(fromHidden: true)
        run(view, for: 1.2)
        #expect(abs(view.ropeY(0) - 18) < 0.5)
    }

    @Test func testLoweringWhileLiftingTurnsAroundWithoutAJump() {
        let view = rope()
        view.drop(fromHidden: true)
        run(view, for: 1.2)
        var lifted = false
        view.lift { lifted = true }
        run(view, for: 0.08)
        let earlier = view.ropeY(450)
        view.advance(1.0 / 120)
        let before = view.ropeY(450)
        #expect(before < 18 && before > -RopePanel.height)
        view.drop(fromHidden: false)
        #expect(view.ropeY(450) == before)            // no teleport back to the top
        view.advance(1.0 / 120)
        // It carries on at the speed it had (only the pull changes direction), then turns around.
        #expect(abs((view.ropeY(450) - before) - (before - earlier)) < 6)
        run(view, for: 1.5)
        #expect(abs(view.ropeY(0) - 18) < 0.5 && !lifted)
    }

    @Test func testLiftFinishesAndHandsBack() {
        let view = rope()
        view.drop(fromHidden: true)
        run(view, for: 1)
        var lifted = false
        view.lift { lifted = true }
        run(view, for: 1)
        #expect(lifted && !view.isLifting)
    }

    @Test func testHoverLiftsAPrintAndAPressSinksIt() {
        let view = rope()
        view.drop(fromHidden: true)
        run(view, for: 1.5)
        let layer = printLayers(view)[0]
        let restY = layer.position.y
        view.simulatedPointer = NSPoint(x: layer.position.x, y: layer.position.y + layer.bounds.height / 2)
        run(view, for: 0.8)
        let hoverY = layer.position.y, hoverScale = layer.value(forKeyPath: "transform.scale.x") as? CGFloat ?? 1
        #expect(abs(hoverY - (restY - RopeTuning.hoverLift)) < 0.3)
        #expect(abs(hoverScale - (1 + RopeTuning.hoverScale)) < 0.003)
        #expect(layer.sublayers![1].opacity > 0.99)     // the ring is fully in
        view.previewPress(Self.fixtures[0], true)
        run(view, for: 0.3)
        let pressScale = layer.value(forKeyPath: "transform.scale.x") as? CGFloat ?? 1
        #expect(abs(layer.position.y - (hoverY + RopeTuning.pressSink)) < 0.3)
        #expect(pressScale < hoverScale && pressScale / hoverScale >= 0.95)
        view.previewPress(Self.fixtures[0], false)
        run(view, for: 0.8)
        #expect(abs(layer.position.y - hoverY) < 0.3)
        view.simulatedPointer = nil
        run(view, for: 0.8)
        #expect(abs(layer.position.y - restY) < 0.3 && layer.sublayers![1].opacity < 0.01)
    }

    @Test func testReduceMotionKeepsTheHighlightButNotTheMovement() {
        let view = rope(reduced: true)
        view.drop(fromHidden: true)
        #expect(abs(view.ropeY(0) - 18) < 0.001)       // no fall: it fades in place
        run(view, for: 0.5)
        let layer = printLayers(view)[0]
        let restY = layer.position.y, restTransform = layer.transform
        view.simulatedPointer = NSPoint(x: layer.position.x, y: layer.position.y + layer.bounds.height / 2)
        run(view, for: 0.5)
        #expect(layer.position.y == restY)
        #expect(layer.sublayers![1].opacity > 0.99)
        // It keeps its tilt instead of swinging straight, and the × appears at full size instead of growing in.
        #expect(CATransform3DEqualToTransform(layer.transform, restTransform))
        #expect(CATransform3DIsIdentity(layer.sublayers![2].transform))
        #expect(layer.sublayers![2].opacity > 0.99)
    }

    @Test func testTheWholeCloseButtonKeepsItsPrintHovered() {
        let view = rope(reduced: true)
        view.drop(fromHidden: true)
        run(view, for: 0.5)
        let layer = printLayers(view)[0], close = layer.sublayers![2]
        let w = layer.bounds.width
        // The × reaches 9 pt past the print's corner; aim near its right edge, beyond the print itself.
        let edge = layer.convert(CGPoint(x: w + 7, y: 2), to: view.layer!)
        view.simulatedPointer = edge
        run(view, for: 0.3)
        #expect(close.opacity < 0.01, "a hidden × mustn't widen the print")
        view.simulatedPointer = layer.convert(CGPoint(x: w / 2, y: layer.bounds.height / 2), to: view.layer!)
        run(view, for: 0.3)
        #expect(close.opacity > 0.99)
        view.simulatedPointer = edge
        run(view, for: 0.3)
        #expect(close.opacity > 0.99, "the × faded under the pointer")
    }

    @Test func testFrameLoopRestsOnceNothingMoves() {
        // Reduce Motion: nothing to animate once the rope has faded in.
        let still = rope(reduced: true)
        still.drop(fromHidden: true)
        run(still, for: 1)
        #expect(!still.needsFrames)

        // Otherwise the breeze blows for a few seconds after the rope comes down, then dies down and it rests.
        let view = rope()
        view.drop(fromHidden: true)
        run(view, for: 1.5)
        #expect(view.needsFrames, "the breeze stopped too soon")
        run(view, for: 8)
        #expect(!view.needsFrames)
        // Anything that happens starts it again, until that has settled too.
        view.previewPress(Self.fixtures[0], true)
        #expect(view.needsFrames)
        run(view, for: 0.3)
        view.previewPress(Self.fixtures[0], false)
        run(view, for: 8)
        #expect(!view.needsFrames)
    }

    @Test func testPointerWakesARestingRopeOnlyWhenTheHoverChanges() {
        let view = rope(reduced: true)
        view.drop(fromHidden: true)
        run(view, for: 1)
        let layer = printLayers(view)[0]
        #expect(!view.pointerChangesHover)
        view.simulatedPointer = NSPoint(x: 8, y: RopePanel.height - 8)        // empty strip below the rope
        #expect(!view.pointerChangesHover)
        view.simulatedPointer = NSPoint(x: layer.position.x, y: layer.position.y + layer.bounds.height / 2)
        #expect(view.pointerChangesHover)
        run(view, for: 0.5)
        #expect(!view.pointerChangesHover && !view.needsFrames)              // hovered and settled: resting again
        view.simulatedPointer = NSPoint(x: layer.position.x + 10, y: layer.position.y + layer.bounds.height / 3)
        #expect(!view.pointerChangesHover)                                    // moving about on the same print
        view.simulatedPointer = NSPoint(x: 8, y: RopePanel.height - 8)
        #expect(view.pointerChangesHover)                                     // leaving it must wake the loop
    }

    @Test func testRemovedPrintLeavesAtOnceAndItsNeighboursCloseUp() {
        let urls = Array(Self.fixtures.prefix(3))
        let view = rope(urls)
        view.drop(fromHidden: true)
        run(view, for: 1)
        let second = printLayers(view)[1]
        view.remove(urls[0], falling: true)
        view.setItems(urls)                             // a reload before the Trash has it changes nothing
        run(view, for: 1.2)
        #expect(abs(second.position.x - (RopeTuning.firstSlot + second.bounds.width / 2)) < 0.5)
        view.departed(urls[0])
        view.setItems(urls)                             // recycling failed: it comes back
        #expect(printLayers(view).count >= 3)
    }

    // MARK: Incoming hand-off: every screenshot ends up in the usual folder or on the rope

    @Test func testEveryNewScreenshotGetsTheCardOrGoesToTheUsualFolder() {
        let incoming = URL(fileURLWithPath: "/tmp/Incoming", isDirectory: true)
        let second = incoming.appendingPathComponent("Screenshot (2).png")
        let first = incoming.appendingPathComponent("Screenshot (1).png")
        let card = incoming.appendingPathComponent("Earlier.png")
        // Two displays: one capture writes two files that arrive in the same look. The card takes the newest; the
        // other must not be marked seen and forgotten.
        let both = Clothesline.triage([second, first, card], seen: ["Earlier.png"], showCard: true)
        #expect(both.card == second)
        #expect(both.putAway == [first])
        #expect(both.seen == ["Screenshot (2).png", "Screenshot (1).png", "Earlier.png"])
        // Nothing new: nothing happens (the card's own file is the card's business).
        let none = Clothesline.triage([card], seen: ["Earlier.png"], showCard: true)
        #expect(none.card == nil && none.putAway.isEmpty)
        // With the clothesline off, no card: every new file goes straight to the usual folder.
        let off = Clothesline.triage([second, first], seen: [], showCard: false)
        #expect(off.card == nil && off.putAway == [second, first])
    }

    /// The card checks it really reached the screen (it once silently didn't). A panel that was never ordered in
    /// must read as not shown, one ordered front as shown, and the logged summary carries no file names.
    @Test func testTheCardCanTellWhetherItReallyReachedTheScreen() {
        let panel = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 120, height: 90),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(!CardVisibility(panel).isShown)
        panel.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))  // the card checks after the same pause
        let shown = CardVisibility(panel)
        #expect(shown.visible)
        #expect(shown.onScreen)
        #expect(shown.isShown)
        panel.orderOut(nil)
        #expect(!CardVisibility(panel).isShown)
        // AppKit thinking it is visible is not enough: the window server has to list it.
        let lost = CardVisibility(onScreen: false, visible: true, occluded: false, activeSpace: true, appHidden: false,
                                  regularApp: true, alpha: 1, frame: NSRect(x: 1287, y: 88, width: 225, height: 194), screens: 1)
        #expect(!lost.isShown)
        #expect(lost.summary == "onScreen=false visible=true occluded=false activeSpace=true appHidden=false regularApp=true alpha=1.00 frame=1287,88 225x194 screens=1")
    }

    @Test func testAWaitingScreenshotIsSavedAndNeverLeftBehind() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("swivel-incoming-\(UUID().uuidString)", isDirectory: true)
        let incoming = root.appendingPathComponent("Incoming", isDirectory: true)
        let usual = root.appendingPathComponent("Desktop", isDirectory: true)
        let ropeFolder = root.appendingPathComponent("Swivel Clothesline", isDirectory: true)
        for folder in [incoming, usual, ropeFolder] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        func waiting(_ name: String) throws -> URL {
            let url = incoming.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }

        // Saved in the usual folder, next to (never over) a file of the same name.
        try Data("older".utf8).write(to: usual.appendingPathComponent("Shot.png"))
        let saved = IncomingCard.save(try waiting("Shot.png"), to: usual, otherwise: ropeFolder)
        #expect(saved?.path == usual.appendingPathComponent("Shot 2.png").path)
        #expect(try String(contentsOf: usual.appendingPathComponent("Shot.png"), encoding: .utf8) == "older")
        #expect(try String(contentsOf: usual.appendingPathComponent("Shot 2.png"), encoding: .utf8) == "Shot.png")

        // The usual folder is gone (an unplugged drive): it hangs on the rope instead of staying hidden.
        let gone = root.appendingPathComponent("Unplugged/Screenshots", isDirectory: true)
        let rescued = IncomingCard.save(try waiting("Other.png"), to: gone, otherwise: ropeFolder)
        #expect(rescued?.path == ropeFolder.appendingPathComponent("Other.png").path)

        // The usual folder is Incoming itself (settings never restored): moving it in place would strand it.
        let looped = IncomingCard.save(try waiting("Loop.png"), to: incoming, otherwise: ropeFolder)
        #expect(looped?.path == ropeFolder.appendingPathComponent("Loop.png").path)

        #expect(try fm.contentsOfDirectory(atPath: incoming.path).isEmpty)
    }

    // MARK: Filmstrips for review (only with SWIVEL_ROPE_FRAMES set)

    private nonisolated static let framesFolder = ProcessInfo.processInfo.environment["SWIVEL_ROPE_FRAMES"].map { URL(fileURLWithPath: $0) }

    private func snapshot(_ layer: CALayer, size: CGSize, flipped: Bool) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        ctx.setFillColor(NSColor(srgbRed: 0.36, green: 0.52, blue: 0.72, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        if flipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    private func strip(_ frames: [(String, CGImage)], to url: URL) {
        guard let first = frames.first?.1 else { return }
        let w = first.width, h = first.height, label = 36
        guard let ctx = CGContext(data: nil, width: w, height: (h + label) * frames.count, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: (h + label) * frames.count))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, frame) in frames.enumerated() {
            let y = (h + label) * (frames.count - 1 - i)
            ctx.draw(frame.1, in: CGRect(x: 0, y: y, width: w, height: h))
            (frame.0 as NSString).draw(at: NSPoint(x: 8, y: y + h + 8), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
        }
        NSGraphicsContext.restoreGraphicsState()
        if let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    @Test(.enabled(if: framesFolder != nil)) func testRenderRopeFilmstrips() throws {
        let folder = try #require(Self.framesFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = rope(Array(Self.fixtures.prefix(3)))
        let size = view.bounds.size
        var frames: [(String, CGImage)] = []
        var t: CGFloat = 0
        func capture(_ name: String, every: CGFloat, for seconds: CGFloat) {
            var next: CGFloat = 0
            var elapsed: CGFloat = 0
            while elapsed <= seconds + 1e-6 {
                if elapsed >= next - 1e-6, let image = snapshot(view.layer!, size: size, flipped: true) {
                    frames.append((String(format: "%@ t=%.3f", name, Double(t)), image))
                    next += every
                }
                view.advance(1.0 / 120)
                elapsed += 1.0 / 120
                t += 1.0 / 120
            }
        }
        view.drop(fromHidden: true)
        capture("drop", every: 0.05, for: 0.6)
        strip(frames, to: folder.appendingPathComponent("rope-1-drop.png")); frames = []
        let first = printLayers(view)[1]
        view.simulatedPointer = NSPoint(x: first.position.x, y: first.position.y + first.bounds.height / 2)
        capture("hover", every: 0.05, for: 0.3)
        view.previewPress(Self.fixtures[1], true)
        capture("press", every: 0.033, for: 0.15)
        view.previewPress(Self.fixtures[1], false)
        capture("release", every: 0.05, for: 0.3)
        view.confirmCopy(Self.fixtures[1])
        // The chip only shows through its animation, which a layer render skips; keep its picture to look at.
        if let chip = printLayers(view)[1].sublayers?.last?.contents, CFGetTypeID(chip as CFTypeRef) == CGImage.typeID,
           let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent("rope-chip.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, chip as! CGImage, nil)
            CGImageDestinationFinalize(dest)
        }
        capture("copied", every: 0.1, for: 0.4)
        strip(frames, to: folder.appendingPathComponent("rope-2-hover-press-copy.png")); frames = []
        view.simulatedPointer = nil
        view.markNew(Self.fixtures[3], arrival: .fromAbove)
        view.setItems([Self.fixtures[3]] + Array(Self.fixtures.prefix(3)))
        capture("arrive", every: 0.06, for: 0.9)
        strip(frames, to: folder.appendingPathComponent("rope-3-arrive.png")); frames = []
        view.lift {}
        capture("lift", every: 0.05, for: 0.35)
        strip(frames, to: folder.appendingPathComponent("rope-4-lift.png"))
    }

    @Test(.enabled(if: framesFolder != nil)) func testRenderCardFilmstrip() throws {
        let folder = try #require(Self.framesFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = IncomingView(frame: .zero)
        view.reducedMotionOverride = false
        view.setThumbnail(Clothesline.thumbnail(Self.fixtures[0], maxPixels: 480))
        let panelSize = NSSize(width: view.preferredSize.width + 60, height: view.preferredSize.height)
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutCard()
        var frames: [(String, CGImage)] = []
        func capture(_ name: String, every: CGFloat, for seconds: CGFloat) {
            var next: CGFloat = 0, elapsed: CGFloat = 0
            while elapsed <= seconds + 1e-6 {
                if elapsed >= next - 1e-6, let image = snapshot(view.layer!, size: panelSize, flipped: false) {
                    frames.append((String(format: "%@ %.2f", name, Double(elapsed)), image))
                    next += every
                }
                view.advance(1.0 / 120)
                elapsed += 1.0 / 120
            }
        }
        view.enter()
        capture("enter", every: 0.05, for: 0.4)
        view.resetInteraction(hovered: true)
        capture("hover", every: 0.1, for: 0.3)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 80), modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: down)
        capture("press", every: 0.05, for: 0.15)
        view.resetInteraction(hovered: true)
        capture("release", every: 0.1, for: 0.3)
        view.exit {}
        capture("exit", every: 0.05, for: 0.25)
        strip(frames, to: folder.appendingPathComponent("card.png"))
    }
}
