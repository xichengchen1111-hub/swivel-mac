import AppKit
import AVFoundation
import CoreImage
import os
import Testing
import UniformTypeIdentifiers
@testable import Swivel

@Suite(.serialized)
struct UpscaleTests {
    @Test func fallbackSizesNamesAndOriginalBytes() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try #require(CIContext().createCGImage(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80)), from: CGRect(x: 0, y: 0, width: 120, height: 80)))
        for (ext, type) in [("png", UTType.png), ("jpg", UTType.jpeg)] {
            let source = try Images.save(original, as: folder.appendingPathComponent("photo.\(ext)"), type: type, quality: 1)
            let before = try Data(contentsOf: source)
            for factor in [2, 4] {
                let out = try Upscale.save(Upscale.ordinary(original, factor: factor), source: source, factor: factor)
                #expect(out.lastPathComponent == "photo \(factor)x.\(ext)")
                let decoded = try Images.load(out)
                #expect(decoded.width == 120 * factor && decoded.height == 80 * factor)
            }
            #expect(try Data(contentsOf: source) == before)
        }
        #expect(throws: (any Error).self) { try Upscale.dimensions(width: 50000, height: 50000, factor: 4) }
        #expect(throws: (any Error).self) { try Upscale.dimensions(width: 8193, height: 1, factor: 2) }
        #expect(throws: (any Error).self) { try Upscale.dimensions(width: 4001, height: 4000, factor: 2) }
        // Video: H.264 above 4K is silently shrunk to 3840 × 2160, so larger 2× output switches to HEVC.
        #expect(Upscale.videoFits(CGSize(width: 3840, height: 2160)) && Upscale.videoFits(CGSize(width: 2160, height: 4096)))
        #expect(!Upscale.videoFits(CGSize(width: 4097, height: 2160)) && !Upscale.videoFits(CGSize(width: 3000, height: 3000)))
        #expect(Upscale.videoPreset(for: CGSize(width: 3840, height: 2160)) == AVAssetExportPresetHighestQuality)
        #expect(Upscale.videoPreset(for: CGSize(width: 4800, height: 2700)) == AVAssetExportPresetHEVCHighestQuality)
        #expect(Upscale.videoPreset(for: CGSize(width: 2160, height: 3840)) == AVAssetExportPresetHighestQuality)
    }
    @Test @MainActor func menusKeepImageAndVideoActionsNearResizeAndCompression() throws {
        let image = URL(fileURLWithPath: "/nonexistent/photo.png"), video = URL(fileURLWithPath: "/nonexistent/clip.mov")
        let titles = Catalog.defaultItems(for: [image], mode: .tools).map(\.title)
        #expect(try #require(titles.firstIndex(of: "Upscale")) + 1 == #require(titles.firstIndex(of: "Resize…")))
        let movies = Catalog.defaultItems(for: [video], mode: .tools).map(\.title)
        #expect(try #require(movies.firstIndex(of: "Upscale")) + 1 == #require(movies.firstIndex(of: "Compress")))
        for source in [image, video] { #expect(!MCPCatalog.actions(for: [source]).contains { $0.id == "tools.Upscale" }) }
        #expect(Strings.table["Upscale"]?.count == 3)
    }
    @Test func videoLargerThanFullHDKeepsItsDoubledSize() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await MediaBatchFixtures.video(in: folder, seconds: 0.25, width: 2400, height: 1350)
        let output = try await Upscale.video(source, engine: UpscaleProcessor(render: { image, _ in Upscale.lanczos(image, factor: 2) })) { _ in }
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        #expect(try await VideoEdit.uprightSize(of: track) == CGSize(width: 4800, height: 2700))
    }
    @Test func cancellingAVideoEnlargementLeavesNoPartialOutput() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await MediaBatchFixtures.video(in: folder)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let task = Task {
            try await Upscale.video(source, engine: UpscaleProcessor(render: { image, _ in Upscale.lanczos(image, factor: 2) })) { _ in }
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled upscale unexpectedly completed") }
        catch is CancellationError {} catch {
            #expect((error as NSError).domain == AVFoundationErrorDomain)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
    }

    @Test func cancellingAfterTheFirstVideoFrameStartsStopsProcessingAndPublication() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try await MediaBatchFixtures.video(in: folder)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let bytes = try Data(contentsOf: source)
        let first = OSAllocatedUnfairLock(initialState: true), cancelled = OSAllocatedUnfairLock(initialState: false)
        let gate = UpscaleRenderGate()
        let task = Task {
            try await Upscale.video(source, engine: UpscaleProcessor(render: { image, _ in
                let shouldWait = first.withLock { value -> Bool in let wasFirst = value; value = false; return wasFirst }
                if shouldWait { gate.blockRenderer() }
                return Upscale.lanczos(image, factor: 2)
            }, cancel: {
                cancelled.withLock { $0 = true }
                // AVFoundation may synchronously drain requests while cancelling. The processor must
                // receive Cancel before that drain, so release this deliberately suspended frame here.
                gate.releaseRenderer()
            })) { _ in }
        }
        defer { gate.releaseRenderer(); task.cancel() }
        try await gate.waitForRenderer()
        task.cancel()
        do { _ = try await task.value; Issue.record("A video cancelled during frame processing was published") }
        catch is CancellationError {} catch { #expect((error as NSError).domain == AVFoundationErrorDomain) }
        #expect(cancelled.withLock { $0 })
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func cancellingTheFinalStillWorkerBeforeEncodingPublishesNothing() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let cg = try #require(CIContext().createCGImage(image, from: image.extent))
        let source = try Images.save(cg, as: folder.appendingPathComponent("photo.png"), type: .png, quality: 1)
        let original = try Data(contentsOf: source)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let gate = UpscaleRenderGate()
        let task = Task {
            try await Upscale.finishStill(image, source: source, factor: 2) { _ in
                gate.blockRenderer()
                return cg
            }
        }
        defer { gate.releaseRenderer(); task.cancel() }
        try await gate.waitForRenderer()
        task.cancel()
        gate.releaseRenderer()
        do { _ = try await task.value; Issue.record("Cancelled still worker published an output") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == files)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func lanczosBackProjectionKeepsOpaqueBordersAndFiniteDimensions() throws {
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        let projected = Upscale.lanczos(Upscale.lanczos(Upscale.lanczos(source, factor: 4), factor: 0.25), factor: 4)
        #expect(projected.extent == CGRect(x: 0, y: 0, width: 128, height: 96))
        let cg = try #require(CIContext().createCGImage(projected, from: projected.extent))
        let bytes = try Retouch.Raster(cg).bytes
        var maxColorError = 0, minAlpha = 255
        for i in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 { maxColorError = max(maxColorError, abs(Int(bytes[i + channel]) - 128)) }
            minAlpha = min(minAlpha, Int(bytes[i + 3]))
        }
        #expect(maxColorError <= 2 && minAlpha == 255)
    }

    @Test func realModelStillPipelineKeepsFormatsNamesSourceAndDimensions() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var raster = Retouch.Raster(width: 65, height: 47, bytes: [UInt8](repeating: 255, count: 65 * 47 * 4))
        for y in 0..<47 { for x in 0..<65 {
            let i = (y * 65 + x) * 4
            raster.bytes[i] = UInt8(x * 3); raster.bytes[i + 1] = UInt8(y * 4); raster.bytes[i + 2] = 60
        } }
        for (ext, type) in [("png", UTType.png), ("jpg", UTType.jpeg)] {
            let source = try Images.save(raster.image(), as: folder.appendingPathComponent("photo.\(ext)"), type: type, quality: 1)
            let before = try Data(contentsOf: source)
            for factor in [2,4] {
                let engine = try await RealESRGANEngine.make()
                let input = try Upscale.loadStill(source, factor: factor)
                let result = try await engine.render(CIImage(cgImage: input), factor: factor)
                let output = try await Upscale.finishStill(result, source: source, factor: factor)
                let read = try Images.load(output)
                #expect(output.lastPathComponent == "photo \(factor)x.\(ext)")
                #expect(read.width == 65 * factor && read.height == 47 * factor)
                #expect(try Data(contentsOf: source) == before)
            }
        }
        for key in ["Real-ESRGAN processes files on this Mac. Fine details may be reconstructed.",
                    "This image is too large to upscale. Use an image up to 16 megapixels.",
                    "This video is too large to upscale. Use video up to 4096 × 2160."] {
            let values = try #require(Strings.table[key]); #expect(values.count == 3 && values.allSatisfy { !$0.isEmpty })
        }
    }

    @Test func realVideoUpscaleKeepsSoundDurationSourceAndMatchesProcessedPixels() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try MediaBatchFixtures.tone(in: folder, seconds: 0.5)
        let source = try await MediaBatchFixtures.video(in: folder, seconds: 0.5, audio: audio)
        let before = try Data(contentsOf: source)
        let engine = try await RealESRGANEngine.make()
        let requestInput = OSAllocatedUnfairLock<CGImage?>(initialState: nil)
        let output = try await Upscale.video(source, engine: UpscaleProcessor(render: { frame, _ in
            requestInput.withLock { value in
                if value == nil {
                    value = CIContext().createCGImage(frame, from: frame.extent, format: .RGBA8,
                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                }
            }
            return try await engine.render(frame, factor: 2)
        }, cancel: { engine.cancel() })) { _ in }
        let asset = try await Video.safeAsset(output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 640, height: 480))
        #expect(try await abs(asset.load(.duration).seconds - 0.5) < 0.02)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try Data(contentsOf: source) == before)
        #expect(output.lastPathComponent == "clip 2x.mov")
        let resultGenerator = AVAssetImageGenerator(asset: asset); resultGenerator.appliesPreferredTrackTransform = true
        let actual = try await resultGenerator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        let compositionInput = try #require(requestInput.withLock { $0 })
        // AVAssetImageGenerator on this fixture returns an untagged CGImage, unlike the colour-managed CI
        // composition input. Independently process that actual decoded input so a colour-space mismatch in the
        // test fixture cannot disguise itself as model/export error. This fixture has identical frames.
        let secondEngine = try await RealESRGANEngine.make()
        let fromComposition = try await secondEngine.render(CIImage(cgImage: compositionInput), factor: 2)
        let secondCG = try #require(CIContext().createCGImage(fromComposition, from: fromComposition.extent))
        let a = try Retouch.Raster(actual).bytes, b = try Retouch.Raster(secondCG).bytes
        let rmse = sqrt(zip(a,b).reduce(0.0) { $0 + pow(Double($1.0)-Double($1.1), 2) } / Double(a.count))
        print("Real-ESRGAN final-video RMSE vs independently processed composition input: \(rmse)")
        #expect(a.count == b.count && rmse < 8)
    }
}

private final class UpscaleRenderGate: @unchecked Sendable {
    private let began = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    func blockRenderer() { began.signal(); proceed.wait() }
    func releaseRenderer() { proceed.signal() }
    func waitForRenderer() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                if self.began.wait(timeout: .now() + 10) == .success { continuation.resume() }
                else { continuation.resume(throwing: ToolError("Timed out waiting for the renderer")) }
            }
        }
    }
}
