import CoreImage
import CryptoKit
import Darwin
import Foundation
import os
import Testing
import UpscaleModel
@testable import Swivel

@Suite(.serialized)
struct RealESRGANTests {
    @Test func applicationFindsNativeResourceBundleAndNeverFallsBackWhenItIsMissing() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Validation.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let dataBundle = resources.appendingPathComponent("Swivel_UpscaleModel.bundle")
        let model = dataBundle.appendingPathComponent("Contents/Resources/RealESRGAN.mlpackage")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for (url, type) in [(app, "APPL"), (dataBundle, "BNDL")] {
            let info: [String: Any] = ["CFBundleIdentifier": "test.swivel.\(UUID().uuidString)",
                "CFBundlePackageType": type, "CFBundleName": "Validation"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
        let bundle = try #require(Bundle(url: app))
        #expect(UpscaleModelAssets.packageURL(in: bundle)?.path == model.path)
        try FileManager.default.removeItem(at: dataBundle)
        #expect(UpscaleModelAssets.packageURL(in: bundle) == nil)
    }
    private func raster(_ image: CIImage) throws -> Retouch.Raster {
        let context = CIContext()
        return try Retouch.Raster(#require(context.createCGImage(image, from: image.extent)))
    }
    private func flat(width: Int, height: Int, alpha: Double = 1) -> CIImage {
        CIImage(color: CIColor(red: 0.7, green: 0.3, blue: 0.15, alpha: alpha))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
    private func eventually(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
        while !predicate() {
            if clock.now > deadline { throw ToolError("Timed out waiting for fixture") }
            await Task.yield()
        }
    }

    @Test func modelSnapshotHasClosedFilesHashesPrivatePermissionsAndNoLinks() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appendingPathComponent("model.mlpackage", isDirectory: true)
        let nested = package.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let data = Data("Pinned model fixture".utf8), source = nested.appendingPathComponent("weights")
        try data.write(to: source)
        let expected = ["Data/weights": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        let snapshot = try RealESRGANResources.snapshot(package: package, expectedFiles: expected)
        defer { Paths.discard(snapshot.directoryURL) }
        #expect(try Data(contentsOf: snapshot.packageURL.appendingPathComponent("Data/weights")) == data)
        let mode = try FileManager.default.attributesOfItem(atPath: snapshot.directoryURL.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        // Once verified, replacing the original cannot change the compiler's private snapshot.
        try Data("replacement".utf8).write(to: source)
        #expect(try Data(contentsOf: snapshot.packageURL.appendingPathComponent("Data/weights")) == data)
        #expect(throws: (any Error).self) { _ = try RealESRGANResources.snapshot(package: package, expectedFiles: expected) }
        try data.write(to: source)
        let extra = package.appendingPathComponent("unexpected")
        try Data([1]).write(to: extra)
        #expect(throws: (any Error).self) { _ = try RealESRGANResources.snapshot(package: package, expectedFiles: expected) }
        try FileManager.default.removeItem(at: extra)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: snapshot.packageURL.appendingPathComponent("Data/weights"))
        #expect(throws: (any Error).self) { _ = try RealESRGANResources.snapshot(package: package, expectedFiles: expected) }
        try FileManager.default.removeItem(at: source)
        let outside = folder.appendingPathComponent("outside")
        try data.write(to: outside)
        #expect(link(outside.path, source.path) == 0)
        #expect(throws: (any Error).self) { _ = try RealESRGANResources.snapshot(package: package, expectedFiles: expected) }
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: nested)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: snapshot.packageURL.appendingPathComponent("Data"))
        #expect(throws: (any Error).self) { _ = try RealESRGANResources.snapshot(package: package, expectedFiles: expected) }
        #expect(throws: (any Error).self) { _ = try RealESRGANResources.snapshot(package: package, expectedFiles: ["../outside": expected.values.first!]) }
    }

    @Test func modelSnapshotRefusesOversizedSparseFileBeforeReadingIt() throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("oversized")
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #expect(fd >= 0)
        defer { if fd >= 0 { close(fd) } }
        #expect(ftruncate(fd, RealESRGANResources.maximumBytes + 1) == 0)
        #expect(throws: (any Error).self) {
            _ = try RealESRGANResources.snapshot(package: folder, expectedFiles: ["oversized": String(repeating: "0", count: 64)])
        }
    }

    @Test func fifoCancellationRemovesWaitersAndPreservesCurrentLease() async throws {
        let gate = RealESRGANAdmission(), firstJob = UUID(), secondJob = UUID(), thirdJob = UUID()
        let first = try await gate.enter(job: firstJob, cancelled: { false })
        let acquired = OSAllocatedUnfairLock(initialState: false)
        let second = Task { try await gate.enter(job: secondJob, cancelled: { false }) }
        try await eventually { gate.waitingCount == 1 }
        let third = Task {
            let lease = try await gate.enter(job: thirdJob, cancelled: { false })
            acquired.withLock { $0 = true }
            return lease
        }
        try await eventually { gate.waitingCount == 2 }
        second.cancel()
        do { _ = try await second.value; Issue.record("Cancelled waiter acquired a lease") } catch is CancellationError {}
        #expect(gate.waitingCount == 1)
        #expect(!acquired.withLock { $0 })
        gate.leave(UUID()) // An unrelated cancellation/release must not transfer an active lease.
        #expect(!acquired.withLock { $0 })
        gate.leave(first)
        gate.leave(try await third.value)
        let fourthJob = UUID(), blocker = try await gate.enter(job: UUID(), cancelled: { false })
        let fourth = Task { try await gate.enter(job: fourthJob, cancelled: { false }) }
        try await eventually { gate.waitingCount == 1 }
        gate.cancel(job: fourthJob)
        do { _ = try await fourth.value; Issue.record("Cancelled job acquired a lease") } catch is CancellationError {}
        #expect(gate.waitingCount == 0)
        gate.leave(blocker)
        let last = try await gate.enter(job: UUID(), cancelled: { false })
        gate.leave(last)
    }

    @Test func reflectionPaddingHandlesOnePixelAndRepeatedReflections() {
        #expect((-10...10).map { RealESRGANEngine.reflectedIndex($0, length: 1) } == [Int](repeating: 0, count: 21))
        #expect((-4...8).map { RealESRGANEngine.reflectedIndex($0, length: 3) } == [0, 1, 2, 1, 0, 1, 2, 1, 0, 1, 2, 1, 0])
    }

    @Test func bundledModelLoadsLocallyAndPreservesAlphaWithoutDoublePremultiplication() async throws {
        // No conditional skip: missing or changed production resources are a failing build.
        let engine = try await RealESRGANEngine.make()
        let opaque = try raster(await engine.render(flat(width: 17, height: 11), factor: 4))
        let translucent = try raster(await engine.render(flat(width: 17, height: 11, alpha: 0.5), factor: 4))
        #expect(opaque.width == 68 && opaque.height == 44)
        #expect(translucent.width == 68 && translucent.height == 44)
        let centre = (opaque.height / 2 * opaque.width + opaque.width / 2) * 4
        for channel in 0..<3 {
            #expect(abs(Int(translucent.bytes[centre + channel]) * 2 - Int(opaque.bytes[centre + channel])) <= 4)
        }
        #expect(abs(Int(translucent.bytes[centre + 3]) - 128) <= 1)
        let wrong = try raster(CIImage(cgImage: translucent.image()).applyingFilter("CISourceInCompositing",
            parameters: [kCIInputBackgroundImageKey: Upscale.lanczos(flat(width: 17, height: 11, alpha: 0.5), factor: 4)]))
        #expect(abs(Int(wrong.bytes[centre]) - Int(translucent.bytes[centre])) > 25)
        let empty = try raster(await engine.render(flat(width: 1, height: 1, alpha: 0), factor: 2))
        #expect(empty.width == 2 && empty.height == 2)
        #expect(empty.bytes.allSatisfy { $0 == 0 })
        let column = try raster(await engine.render(flat(width: 1, height: 7), factor: 4))
        #expect(column.width == 4 && column.height == 28)
        #expect(stride(from: 3, to: column.bytes.count, by: 4).allSatisfy { column.bytes[$0] == 255 })
    }

    @Test func oddSizeAsymmetricColorsAndTileBoundariesKeepTheirPositions() async throws {
        let width = 257, height = 133
        var source = Retouch.Raster(width: width, height: height, bytes: [UInt8](repeating: 255, count: width * height * 4))
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            source.bytes[i] = UInt8(30 + 170 * x / (width - 1))
            source.bytes[i + 1] = UInt8(25 + 160 * y / (height - 1))
            source.bytes[i + 2] = 60
        } }
        let engine = try await RealESRGANEngine.make()
        let output = try raster(await engine.render(CIImage(cgImage: source.image()), factor: 2))
        #expect(output.width == 514 && output.height == 266)
        func color(_ x: Int, _ y: Int, _ c: Int) -> Int { Int(output.bytes[(y * output.width + x) * 4 + c]) }
        #expect(color(60, 60, 0) + 100 < color(output.width - 60, 60, 0))
        #expect(color(60, 30, 1) + 100 < color(60, output.height - 30, 1))
        // A smooth source must remain smooth across both horizontal and vertical stitching boundaries.
        // A missing, duplicated or flipped core produces a much larger discontinuity.
        for x in [255, 256, 257, 511, 512] { for y in [70, 140, 240] {
            for c in 0..<3 { #expect(abs(color(x, y, c) - color(x - 1, y, c)) <= 12) }
        } }
        for y in [255, 256, 257] { for x in [70, 200, 450] {
            for c in 0..<3 { #expect(abs(color(x, y, c) - color(x, y - 1, c)) <= 12) }
        } }
    }

    @Test func cancellingDuringTilesOrBeforeRenderReturnsNoImageOrFile() async throws {
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let engine = try await RealESRGANEngine.make()
        let image = flat(width: 257, height: 129)
        let task = Task {
            let result = try await engine.render(image, factor: 2) { value in if value > 0 { engine.cancel() } }
            return try await Upscale.finishStill(result, source: folder.appendingPathComponent("unwritten.png"), factor: 2)
        }
        do { _ = try await task.value; Issue.record("Cancelled tile render published an image") } catch is CancellationError {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == before)
        do { _ = try await engine.render(flat(width: 1, height: 1), factor: 2); Issue.record("Cancelled job was reused") }
        catch is CancellationError {}
        let healthy = try await RealESRGANEngine.make()
        #expect(try await healthy.render(flat(width: 1, height: 1), factor: 2).extent.size == CGSize(width: 2, height: 2))
    }
}
