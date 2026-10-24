import AppKit
import AVFoundation
import Testing
@testable import Swivel

/// The editors' hand-feel maths: slider detents and end stops, crop hit-testing, snapping and glide takeover,
/// ⇧ constraints, PDF crop mapping, latest-wins preview rendering, and what Apply may and may not save.
@Suite(.serialized)
@MainActor
struct EditorsFeelTests {
    // MARK: Slider detent

    @Test func testDetentCatchesOnceAndHoldsWithHysteresis() {
        // Exposure: −2…2, neutral 0, so the zone is ±0.06 and it re-arms past ±0.12.
        var detent = Detent(neutral: 0, range: 4, at: 0.5)
        #expect(detent.filter(0.3) == (0.3, false))
        #expect(detent.filter(0.05) == (0, true))        // caught: snaps and taps
        #expect(detent.filter(0.02) == (0, false))       // held: no more taps
        #expect(detent.filter(0.1) == (0.1, false))      // out of the zone, but not re-armed yet
        #expect(detent.filter(0.04) == (0, false))       // back in without a second tap
        #expect(detent.filter(0.2) == (0.2, false))      // clearly away: re-armed
        #expect(detent.filter(-0.03) == (0, true))
    }

    @Test func testDetentTapsWhenAFastDragJumpsAcross() {
        var detent = Detent(neutral: 1, range: 1, at: 1.3)
        let (value, tick) = detent.filter(0.7)
        #expect(value == 0.7 && tick)
    }

    @Test func testDetentDoesNotTapWhenADragStartsOnIt() {
        // The slider builds its detent at each press, from where the value rests.
        var detent = Detent(neutral: 0.12, range: 0.4, at: 0.12)
        #expect(detent.filter(0.123) == (0.12, false))
    }

    @Test func testTrimEndStopsLetTheHandlesReachEverySecond() {
        // A 60-minute clip. The old 1.5 % band pulled everything within 54 s of either end onto it.
        var start = Detent.forSlider(neutral: 0, min: 0, max: 3600, at: 600)
        #expect(start.zone == 0)
        #expect(start.filter(30) == (30, false))       // cutting a 30-second intro works
        #expect(start.filter(0.5) == (0.5, false))
        #expect(start.filter(0) == (0, true))          // arriving exactly at the end: one tap
        #expect(start.filter(0) == (0, false))         // held there (the slider clamps a drag past it): no more
        #expect(start.filter(20) == (20, false))
        #expect(start.filter(0) == (0, false))         // back again within 1.5 %: not re-armed yet
        #expect(start.filter(120) == (120, false))
        #expect(start.filter(0) == (0, true))

        var end = Detent.forSlider(neutral: 3600, min: 0, max: 3600, at: 3600)
        #expect(end.filter(3570) == (3570, false))     // leaving the end doesn't tap
        #expect(end.filter(3500) == (3500, false))
        #expect(end.filter(3599.9) == (3599.9, false))
        #expect(end.filter(3600) == (3600, true))
    }

    @Test func testOnlyDetentsInsideTheRangeAreMagnetic() {
        // Exposure's default is mid-range: still a ±1.5 % band.
        var exposure = Detent.forSlider(neutral: 0, min: -2, max: 2, at: 0.5)
        #expect(abs(exposure.zone - 0.06) < 1e-12)
        #expect(exposure.filter(0.05) == (0, true))
        // Vignette's default is its minimum: a light vignette right next to it can be picked.
        var vignette = Detent.forSlider(neutral: 0, min: 0, max: 2, at: 1)
        #expect(vignette.filter(0.02) == (0.02, false))
        #expect(vignette.filter(0) == (0, true))
    }

    @Test func testTrimLearnsItsLengthAfterOpeningAndItsHandlesReachBothEnds() async throws {
        _ = NSApplication.shared
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tone.caf")
        try makeAudio(at: url, seconds: 2)
        // Building the editor reads nothing, so `present()` counts the window before the asset loads.
        let editor = try await TrimEditor(source: url)
        defer { editor.didClose() }
        #expect(editor.duration == 0)
        try await editor.load()
        #expect(abs(editor.duration - 2) < 0.05)
        #expect(editor.isAudio && editor.window.title == L("Trim Audio"))
        let start = try #require(editor.start), end = try #require(editor.end)
        #expect(start.maxValue == editor.duration && end.maxValue == editor.duration)
        #expect(start.doubleValue == 0 && end.doubleValue == editor.duration)
        var startStop = Detent.forSlider(neutral: try #require(start.neutral), min: start.minValue, max: start.maxValue, at: 1)
        #expect(startStop.filter(0.02) == (0.02, false))
        let nearEnd = editor.duration - 0.02
        var endStop = Detent.forSlider(neutral: try #require(end.neutral), min: end.minValue, max: end.maxValue, at: 1)
        #expect(endStop.filter(nearEnd) == (nearEnd, false))
    }

    // MARK: Crop handles

    @Test func testCropHitPrefersOneEdgePerAxis() {
        let box = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(CropHandle.hit(CGPoint(x: 105, y: 200), box: box, tolerance: 12) == .left)
        #expect(CropHandle.hit(CGPoint(x: 92, y: 95), box: box, tolerance: 12) == .topLeft)
        #expect(CropHandle.hit(CGPoint(x: 395, y: 298), box: box, tolerance: 12) == .bottomRight)
        #expect(CropHandle.hit(CGPoint(x: 250, y: 290), box: box, tolerance: 12) == .bottom)
        #expect(CropHandle.hit(CGPoint(x: 250, y: 200), box: box, tolerance: 12) == .move)
        #expect(CropHandle.hit(CGPoint(x: 80, y: 200), box: box, tolerance: 12) == nil)
    }

    @Test func testTinyCropBoxKeepsAMiddleToMoveBy() {
        // 20 pt box: a 12 pt inward reach would grab both sides at once (the old jitter bug).
        let box = CGRect(x: 100, y: 100, width: 20, height: 20)
        #expect(CropHandle.hit(CGPoint(x: 110, y: 110), box: box, tolerance: 12) == .move)
        #expect(CropHandle.hit(CGPoint(x: 103, y: 110), box: box, tolerance: 12) == .left)
        #expect(CropHandle.hit(CGPoint(x: 117, y: 110), box: box, tolerance: 12) == .right)
        #expect(CropHandle.hit(CGPoint(x: 90, y: 110), box: box, tolerance: 12) == .left)
        #expect(CropHandle.hit(CGPoint(x: 130, y: 130), box: box, tolerance: 12) == .bottomRight)
    }

    // MARK: Crop snapping

    @Test func testSnapPickHoldsTheCurrentTargetALittleLonger() {
        let candidates: [SnapPick.Candidate] = [.init(id: 1, delta: 15), .init(id: 2, delta: -10)]
        // Fresh: the nearest within reach.
        #expect(SnapPick.pick(candidates, previous: nil, enter: 12, leave: 18)?.id == 2)
        // Already holding 1 at 15 (inside 1.5 × reach): keep it, no flicker between targets.
        #expect(SnapPick.pick(candidates, previous: 1, enter: 12, leave: 18)?.id == 1)
        #expect(SnapPick.pick([.init(id: 1, delta: 20)], previous: 1, enter: 12, leave: 18) == nil)
    }

    @Test func testMovingBoxCatchesTheCentreLine() {
        let drag = CropDrag(start: CGRect(x: 100, y: 100, width: 900, height: 800), handle: .move,
                            size: CGSize(width: 3000, height: 2000), enter: 12)
        let result = drag.rect(dx: 946, dy: 0, snapping: true)
        #expect(result.rect.midX == 1500)
        #expect(result.snap.x == 12)
        // ⌘ (no snapping) tracks the pointer 1:1.
        #expect(drag.rect(dx: 946, dy: 0, snapping: false).rect.minX == 1046)
    }

    @Test func testFreeCornerCatchesTheOriginalRatio() {
        let drag = CropDrag(start: CGRect(x: 0, y: 0, width: 1200, height: 1000), handle: .bottomRight,
                            size: CGSize(width: 3000, height: 2000), freeRatios: [1.5, 1], enter: 12)
        let result = drag.rect(dx: 0, dy: -195, snapping: true)
        #expect(result.rect.height == 800)
        #expect(result.snap.y == 100)
    }

    @Test func testEdgeCatchesTheImageEdgeAndThirds() {
        let drag = CropDrag(start: CGRect(x: 0, y: 0, width: 2900, height: 1500), handle: .right,
                            size: CGSize(width: 3000, height: 2000), enter: 12)
        #expect(drag.rect(dx: 92, dy: 0, snapping: true).rect.maxX == 3000)
        let third = drag.rect(dx: -895, dy: 0, snapping: true)
        #expect(third.rect.maxX == 2000 && third.snap.x == 3)
    }

    @Test func testLockedCornerPinsTheOppositeCorner() {
        let size = CGSize(width: 1000, height: 1000)
        let start = CGRect(x: 100, y: 100, width: 400, height: 400)
        let grow = CropDrag(start: start, handle: .bottomRight, size: size, ratio: 1, enter: 6).rect(dx: 100, dy: 0, snapping: true)
        #expect(grow.rect == CGRect(x: 100, y: 100, width: 450, height: 450))
        // Dragged far past the image's corner: stops at the edge, bottom-right stays put.
        let far = CropDrag(start: start, handle: .topLeft, size: size, ratio: 1, enter: 6).rect(dx: -300, dy: -300, snapping: true)
        #expect(far.rect == CGRect(x: 0, y: 0, width: 500, height: 500))
    }

    @Test func testPressDuringARatioGlideStartsFromTheRatio() {
        let size = CGSize(width: 3000, height: 2000)
        // 1:1 chosen: the box glides from 3000 × 2000 to the centred 2000 × 2000 and is pressed partway there.
        let midGlide = CGRect(x: 250, y: 0, width: 2500, height: 2000)
        #expect(CropDrag.fitted(midGlide, to: 1, keeping: .move, in: size) == CGRect(x: 500, y: 0, width: 2000, height: 2000))
        // A grabbed edge or corner stays where it was drawn, under the pointer.
        #expect(CropDrag.fitted(midGlide, to: 1, keeping: .right, in: size) == CGRect(x: 750, y: 0, width: 2000, height: 2000))
        #expect(CropDrag.fitted(midGlide, to: 1, keeping: .topLeft, in: size) == CGRect(x: 250, y: 0, width: 2000, height: 2000))
        // Moving it or dragging a corner from there keeps it square.
        let fitted = CropDrag.fitted(midGlide, to: 1, keeping: .bottomRight, in: size)
        let moved = CropDrag(start: fitted, handle: .move, size: size, ratio: 1, enter: 6).rect(dx: -100, dy: 0, snapping: false).rect
        #expect(moved.width == moved.height)
        let corner = CropDrag(start: fitted, handle: .bottomRight, size: size, ratio: 1, enter: 6).rect(dx: -300, dy: -120, snapping: true).rect
        #expect(corner.width == corner.height)
        // Too tall for 16:9: the width stays, the height follows, within a rounding pixel.
        let wide = CropDrag.fitted(CGRect(x: 0, y: 100, width: 3000, height: 1800), to: 16 / 9, keeping: .move, in: size)
        #expect(wide.width == 3000 && abs(wide.width / wide.height - 16 / 9) < 1 / wide.height)
    }

    @Test func testGrabbingTheBoxMidGlideKeepsTheSelectedRatio() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = CropView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = view
        defer {
            view.stop()
            window.close()
        }
        let proxy = try #require(CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        view.setImage(proxy, pixelSize: CGSize(width: 3000, height: 2000))
        view.layoutSubtreeIfNeeded()
        // Choosing 1:1 glides (unless Reduce Motion is on); nothing has been drawn yet, so the press lands on the
        // full-photo box the glide started from.
        view.setRatio(1)
        let centre = view.convert(NSPoint(x: 300, y: 200), to: nil)
        view.mouseDown(with: mouse(.leftMouseDown, at: centre))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: centre.x + 20, y: centre.y)))
        view.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: centre.x + 20, y: centre.y)))
        #expect(view.crop.width == view.crop.height)
        #expect(view.crop.height == 2000)
    }

    // MARK: Annotate ⇧ constraints

    @Test func testShiftTurnsArrowsToFortyFiveDegrees() {
        let diagonal = MarkConstraint.snap45(from: .zero, to: CGPoint(x: 10, y: 9))
        #expect(diagonal?.direction == 1)
        #expect(abs((diagonal?.point.x ?? 0) - (diagonal?.point.y ?? 1)) < 1e-9)
        let flat = MarkConstraint.snap45(from: .zero, to: CGPoint(x: 10, y: 1))
        #expect(flat?.direction == 0 && abs((flat?.point.y ?? 1)) < 1e-9 && abs((flat?.point.x ?? 0) - 10) < 1e-9)
        #expect(MarkConstraint.snap45(from: .zero, to: CGPoint(x: -10, y: -1))?.direction == 4)
        #expect(MarkConstraint.snap45(from: .zero, to: .zero) == nil)
    }

    @Test func testShiftMakesSquaresAndClampsKeepTheDirection() {
        #expect(MarkConstraint.square(from: .zero, to: CGPoint(x: 10, y: -3)) == CGPoint(x: 10, y: -10))
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(MarkConstraint.clamp(CGPoint(x: 15, y: 5), from: CGPoint(x: 5, y: 5), in: rect) == CGPoint(x: 10, y: 5))
        #expect(MarkConstraint.clamp(CGPoint(x: 13, y: 13), from: CGPoint(x: 4, y: 4), in: rect) == CGPoint(x: 10, y: 10))
    }

    // MARK: PDF crop mapping

    @Test func testPDFCropMapsThroughPageRotation() {
        // The top-left half-width, quarter-height of the page as displayed.
        let unit = CGRect(x: 0, y: 0, width: 0.5, height: 0.25)
        let box = CGRect(x: 0, y: 0, width: 100, height: 200)
        #expect(CropEditor.pageRect(unit, rotation: 0, in: box) == CGRect(x: 0, y: 150, width: 50, height: 50))
        #expect(CropEditor.pageRect(unit, rotation: 90, in: box) == CGRect(x: 0, y: 0, width: 25, height: 100))
        #expect(CropEditor.pageRect(unit, rotation: 180, in: box) == CGRect(x: 50, y: 0, width: 50, height: 50))
        #expect(CropEditor.pageRect(unit, rotation: 270, in: box) == CGRect(x: 75, y: 100, width: 25, height: 100))
        #expect(CropEditor.pageRect(unit, rotation: -90, in: box) == CropEditor.pageRect(unit, rotation: 270, in: box))
    }

    @Test func testRoundingKeepsSnappedEdgesOnTheirLine() {
        let r = CGRect(x: 999.6, y: 10.2, width: 1000.2, height: 5.6).roundedToPixels
        #expect(r == CGRect(x: 1000, y: 10, width: 1000, height: 6))
    }

    // MARK: Live preview

    @Test func testLiveRenderSkipsToTheNewestRequest() async throws {
        var delivered: [Int] = []
        let render = LiveRender<Int> { delivered.append($0) }
        render.request {
            Thread.sleep(forTimeInterval: 0.08)
            return 1
        }
        render.request { 2 }
        render.request { 3 }
        for _ in 0..<50 where delivered.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(delivered == [1, 3])
        render.request { 4 }
        render.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(delivered == [1, 3])
    }

    @Test func testCompressEstimateQueuedBehindTheFirstReusesItsDecode() async throws {
        _ = NSApplication.shared
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.png")
        try makeImage(at: source, width: 1600, height: 1200)
        let editor = try CompressEditor(source: source)
        defer { editor.didClose() }
        try await editor.load()
        editor.update()  // opening: the first estimate decodes the original
        editor.update()  // a control moves while it runs: this one waits its turn
        for _ in 0..<250 where editor.isEstimating { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!editor.isEstimating)
        #expect(editor.decoded.decodeCount == 1)
    }

    // MARK: Saving

    @Test func testSavingCoversTheCanvasAndHoldsUndo() throws {
        _ = NSApplication.shared
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.png")
        try makeImage(at: source)
        let editor = try AnnotateEditor(source: source)
        defer { editor.didClose() }
        let content = try #require(editor.window.contentView)
        editor.window.layoutIfNeeded()
        let canvas = try #require(subview(AnnotateCanvas.self, in: content))
        let centre = canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        // Even the canvas's centre, where the (hidden) loading spinner sits, takes the press.
        #expect(content.hitTest(centre) === canvas)

        let history = try #require(editor.window.undoManager as? EditorUndoManager)
        history.groupsByEvent = false
        let counter = Counter()
        history.beginUndoGrouping()
        history.registerUndo(withTarget: counter, selector: #selector(Counter.bump(_:)), object: nil)
        history.endUndoGrouping()

        editor.setSaving(true)
        #expect(content.hitTest(centre) !== canvas)
        #expect(!history.canUndo)
        _ = editor.window.tryToPerform(Selector(("undo:")), with: nil)
        #expect(counter.count == 0)

        editor.setSaving(false)
        #expect(content.hitTest(centre) === canvas)
        #expect(history.canUndo)
        _ = editor.window.tryToPerform(Selector(("undo:")), with: nil)
        #expect(counter.count == 1)
    }

    // MARK: Redact

    @Test func testRedactApplyWaitsForDetectionBeforeSaving() async throws {
        _ = NSApplication.shared
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("note.png")
        try makeImage(at: source, text: "SECRET PASSWORD 1234")
        let editor = try RedactEditor(source: source)
        defer { editor.didClose() }
        try await editor.load()
        #expect(editor.detectionState == .running)
        // Return pressed straight away, before detection has reported anything.
        let files = try await editor.apply()
        #expect(editor.detectionState == .finished)
        let out = try #require(files.first)
        #expect(out.lastPathComponent == "note redacted.png")
        let before = darkPixels(try Images.load(source)), after = darkPixels(try Images.load(out))
        #expect(before > 500)
        #expect(after * 10 < before)
    }

    @Test func testRedactNeverSavesACopyThatCoversNothing() async throws {
        _ = NSApplication.shared
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let blank = folder.appendingPathComponent("blank.png")
        try makeImage(at: blank)
        let editor = try RedactEditor(source: blank)
        defer { editor.didClose() }
        try await editor.load()
        await #expect(throws: ToolError.self) { try await editor.apply() }
        #expect(editor.detectionState == .finished)

        // Detection cancelled before it could add its boxes (the window closing): nothing is written either.
        let note = folder.appendingPathComponent("note.png")
        try makeImage(at: note, text: "SECRET PASSWORD 1234")
        let closing = try RedactEditor(source: note)
        try await closing.load()
        closing.didClose()
        await #expect(throws: Cancelled.self) { try await closing.apply() }
        #expect(closing.detectionState == .running)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["blank.png", "note.png"])
    }

    // MARK: Helpers

    private final class Counter: NSObject {
        var count = 0
        @objc func bump(_ sender: Any?) { count += 1 }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwivelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeImage(at url: URL, width: Int = 800, height: Int = 400, text: String? = nil) throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        if let text {
            (text as NSString).draw(at: NSPoint(x: 30, y: height / 2),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func makeAudio(at url: URL, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
    }

    /// Pixels darker than mid-grey: black text, and none once it's blurred away.
    private func darkPixels(_ image: CGImage) -> Int {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 100 && pixels[$0 + 1] < 100 && pixels[$0 + 2] < 100 }.count
    }

    private func subview<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        for sub in view.subviews {
            if let match = sub as? T ?? subview(type, in: sub) { return match }
        }
        return nil
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
