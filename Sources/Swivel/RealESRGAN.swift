import CoreImage
import CoreML
import CryptoKit
import Darwin
import Foundation
import os
import UpscaleModel

/// A cancellable FIFO shared by model loading and all frames. Cancelling a waiter never releases the
/// current owner's lease: synchronous Core ML work must finish before another frame starts.
final class RealESRGANAdmission: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let job: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }
    private struct State { var owner: UUID?; var waiting: [Waiter] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func enter(job: UUID, cancelled: @escaping @Sendable () -> Bool) async throws -> UUID {
        let id = UUID(), interrupted = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<UUID, Error>? = state.withLock { state in
                    guard !Task.isCancelled, !interrupted.withLock({ $0 }), !cancelled() else {
                        return .failure(CancellationError())
                    }
                    if state.owner == nil { state.owner = id; return .success(id) }
                    state.waiting.append(Waiter(id: id, job: job, continuation: continuation))
                    return nil
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: {
            interrupted.withLock { $0 = true }
            self.remove { $0.id == id }
        }
    }
    private func remove(_ predicate: (Waiter) -> Bool) {
        let removed = state.withLock { state -> [Waiter] in
            let removed = state.waiting.filter(predicate)
            state.waiting.removeAll(where: predicate)
            return removed
        }
        for waiter in removed { waiter.continuation.resume(throwing: CancellationError()) }
    }
    func cancel(job: UUID) { remove { $0.job == job } }
    func leave(_ id: UUID) {
        let next = state.withLock { state -> Waiter? in
            guard state.owner == id else { return nil }
            if state.waiting.isEmpty { state.owner = nil; return nil }
            let next = state.waiting.removeFirst(); state.owner = next.id
            return next
        }
        if let next { next.continuation.resume(returning: next.id) }
    }
    var waitingCount: Int { state.withLock { $0.waiting.count } }
}

/// Reads only the pinned model's closed file set. The compiler sees a private, verified copy, never a
/// pathname that an application update or a substituted package can change after its hash is checked.
enum RealESRGANResources {
    struct Snapshot {
        let packageURL: URL
        let directoryURL: URL // Keep the exact URL registered by Paths.temporary, including its directory flag.
    }
    static let maximumBytes: Int64 = 128 * 1_024 * 1_024
    private static func invalid() -> ToolError { ToolError(L("The bundled upscaling model is missing or damaged. Rebuild Swivel.")) }

    static func snapshot(package: URL, expectedFiles: [String: String] = UpscaleModelAssets.expectedFiles) throws -> Snapshot {
        try Task.checkCancellation()
        guard !expectedFiles.isEmpty, expectedFiles.keys.allSatisfy({ path in
            !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
        }) else { throw invalid() }
        var directories: Set<String> = [""]
        for file in expectedFiles.keys {
            var components = file.split(separator: "/").map(String.init)
            components.removeLast()
            while !components.isEmpty { directories.insert(components.joined(separator: "/")); components.removeLast() }
        }
        let source = open(package.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard source >= 0 else { throw invalid() }
        defer { close(source) }
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let root = Paths.temporary(beside: parent.appendingPathComponent("upscale-model"), ext: "")
        guard mkdir(root.path, 0o700) == 0 else {
            TemporaryItems.unregister(root)
            throw ToolError(L("Couldn't create private upscaling model storage."))
        }
        do {
            let target = root.appendingPathComponent("RealESRGAN.mlpackage", isDirectory: true)
            guard mkdir(target.path, 0o700) == 0 else { throw invalid() }
            let destination = open(target.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
            guard destination >= 0 else { throw invalid() }
            defer { close(destination) }
            var seen: Set<String> = [], total: Int64 = 0
            try copyDirectory(source: source, destination: destination, relative: "", expected: expectedFiles,
                              directories: directories, seen: &seen, total: &total)
            guard seen == Set(expectedFiles.keys) else { throw invalid() }
            return Snapshot(packageURL: target, directoryURL: root)
        } catch { Paths.discard(root); throw error }
    }

    private static func copyDirectory(source: Int32, destination: Int32, relative: String,
                                      expected: [String: String], directories: Set<String>,
                                      seen: inout Set<String>, total: inout Int64) throws {
        let duplicate = dup(source)
        guard duplicate >= 0 else { throw invalid() }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw invalid() }
        defer { closedir(stream) }
        errno = 0
        while let entry = readdir(stream) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw invalid() }
            if name == "." || name == ".." { errno = 0; continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard fstatat(source, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw invalid() }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard directories.contains(path), mkdirat(destination, name, 0o700) == 0 else { throw invalid() }
                let child = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw invalid() }
                defer { close(child) }
                let copy = openat(destination, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard copy >= 0 else { throw invalid() }
                defer { close(copy) }
                try copyDirectory(source: child, destination: copy, relative: path, expected: expected,
                                  directories: directories, seen: &seen, total: &total)
            case S_IFREG:
                guard let hash = expected[path], !seen.contains(path) else { throw invalid() }
                try copyFile(source: source, destination: destination, name: name, hash: hash, total: &total)
                seen.insert(path)
            default: throw invalid()
            }
            errno = 0
        }
        guard errno == 0 else { throw invalid() }
    }

    private static func copyFile(source: Int32, destination: Int32, name: String, hash: String, total: inout Int64) throws {
        let input = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw invalid() }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= maximumBytes - total else { throw invalid() }
        total += before.st_size
        let output = openat(destination, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw invalid() }
        defer { close(output) }
        var bytes = [UInt8](repeating: 0, count: 256 * 1_024), length: Int64 = 0, digest = SHA256()
        while true {
            try Task.checkCancellation()
            let amount = read(input, &bytes, bytes.count)
            if amount < 0 { if errno == EINTR { continue }; throw invalid() }
            if amount == 0 { break }
            length += Int64(amount)
            guard length <= before.st_size else { throw invalid() }
            digest.update(data: Data(bytes[0..<amount]))
            try bytes.withUnsafeBytes { buffer in
                var written = 0
                while written < amount {
                    let n = write(output, buffer.baseAddress!.advanced(by: written), amount - written)
                    if n < 0 { if errno == EINTR { continue }; throw invalid() }
                    guard n > 0 else { throw invalid() }
                    written += n
                }
            }
        }
        var after = stat()
        guard fstat(input, &after) == 0, length == before.st_size, after.st_size == before.st_size,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw invalid() }
    }
}

final class RealESRGANEngine: @unchecked Sendable {
    static let core = 128
    static let halo = 64
    static let inputSide = core + 2 * halo
    private static let admission = RealESRGANAdmission()
    // Accessed only while holding the admission lease, including model construction.
    nonisolated(unsafe) private static var cached: ModelHandle?
    private final class ModelHandle: @unchecked Sendable {
        let model: MLModel
        let directory: URL
        init(model: MLModel, directory: URL) { self.model = model; self.directory = directory }
        deinit { Paths.discard(directory) }
    }
    private let handle: ModelHandle
    private let job = UUID()
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private init(handle: ModelHandle) { self.handle = handle }

    static func make() async throws -> RealESRGANEngine {
        let lease = try await admission.enter(job: UUID(), cancelled: { false })
        defer { admission.leave(lease) }
        try Task.checkCancellation()
        if let cached { return RealESRGANEngine(handle: cached) }
        guard let package = UpscaleModelAssets.packageURL else {
            throw ToolError(L("The bundled upscaling model is missing or damaged. Rebuild Swivel."))
        }
        let snapshot = try RealESRGANResources.snapshot(package: package)
        let directory = snapshot.directoryURL
        var retained = false
        defer { if !retained { Paths.discard(directory) } }
        // These native calls are cooperative cancellation boundaries, not interruptible operations.
        try Task.checkCancellation()
        let compiled = try await MLModel.compileModel(at: snapshot.packageURL)
        defer { try? FileManager.default.removeItem(at: compiled) }
        try Task.checkCancellation()
        let privateCompiled = directory.appendingPathComponent("RealESRGAN.mlmodelc", isDirectory: true)
        try FileManager.default.moveItem(at: compiled, to: privateCompiled)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: privateCompiled, configuration: configuration)
        try Task.checkCancellation()
        guard let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              input.pixelsWide == inputSide, input.pixelsHigh == inputSide,
              let output = model.modelDescription.outputDescriptionsByName["upscaled"]?.imageConstraint,
              output.pixelsWide == inputSide * 4, output.pixelsHigh == inputSide * 4 else {
            throw ToolError(L("The bundled upscaling model is missing or damaged. Rebuild Swivel."))
        }
        let handle = ModelHandle(model: model, directory: directory)
        cached = handle; retained = true
        return RealESRGANEngine(handle: handle)
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        Self.admission.cancel(job: job)
    }
    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled.withLock({ $0 }) { throw CancellationError() }
    }
    static func reflectedIndex(_ position: Int, length: Int) -> Int {
        guard length > 1 else { return 0 }
        let period = 2 * (length - 1), value = (position % period + period) % period
        return value < length ? value : period - value
    }

    func render(_ source: CIImage, factor: Int,
                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> CIImage {
        let lease = try await Self.admission.enter(job: job, cancelled: { self.cancelled.withLock { $0 } })
        defer { Self.admission.leave(lease) }
        try checkCancellation()
        let extent = source.extent
        guard extent.origin.x.isFinite, extent.origin.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width.rounded() == extent.width, extent.height.rounded() == extent.height,
              extent.width > 0, extent.height > 0, extent.width * extent.height <= 16_000_000 else {
            throw ToolError(L("Real-ESRGAN input is limited to 16 megapixels. Choose a smaller file."))
        }
        let width = Int(extent.width), height = Int(extent.height)
        let size = try Upscale.dimensions(width: width, height: height, factor: factor)
        let normalized = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let colors = try Upscale.opaqueColors(normalized)
        guard let image = context.createCGImage(colors, from: colors.extent, format: .RGBA8, colorSpace: Self.colorSpace),
              let output = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                     bytesPerRow: Int(size.width) * 4, space: Self.colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError(L("Couldn't allocate an upscaling frame."))
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rasterized = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let canvas = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: Self.colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            canvas.setBlendMode(.copy); canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rasterized else { throw ToolError(L("Couldn't allocate an upscaling frame.")) }
        output.setBlendMode(.copy); output.interpolationQuality = .none
        let columns = (width + Self.core - 1) / Self.core, rows = (height + Self.core - 1) / Self.core
        progress(0)
        for row in 0..<rows { for column in 0..<columns {
            try checkCancellation()
            try autoreleasepool {
                let x = column * Self.core, y = row * Self.core
                let tile = try makeInput(bytes: bytes, width: width, height: height, x: x, y: y)
                let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: tile)])
                try checkCancellation()
                let prediction = try handle.model.prediction(from: provider)
                try checkCancellation()
                guard let pixel = prediction.featureValue(for: "upscaled")?.imageBufferValue else {
                    throw ToolError(L("Couldn't render"))
                }
                var enlarged = CIImage(cvPixelBuffer: pixel, options: [.colorSpace: Self.colorSpace])
                // A 2× job materializes each tile at 2× before stitching. It never allocates a full 4× frame.
                if factor == 2 { enlarged = Upscale.lanczos(enlarged, factor: 0.5) }
                let tileSide = Self.inputSide * factor
                guard let tileImage = context.createCGImage(enlarged, from: CGRect(x: 0, y: 0, width: tileSide, height: tileSide),
                                                          format: .RGBA8, colorSpace: Self.colorSpace),
                      let centre = tileImage.cropping(to: CGRect(x: Self.halo * factor, y: Self.halo * factor,
                                                               width: min(Self.core, width - x) * factor,
                                                               height: min(Self.core, height - y) * factor)) else {
                    throw ToolError(L("Couldn't render"))
                }
                let destination = CGRect(x: x * factor, y: (height - y - min(Self.core, height - y)) * factor,
                                         width: centre.width, height: centre.height)
                output.draw(centre, in: destination)
            }
            progress(Double(row * columns + column + 1) / Double(rows * columns))
        } }
        try checkCancellation()
        guard let stitched = output.makeImage() else { throw ToolError(L("Couldn't render")) }
        let alpha = Upscale.lanczos(normalized, factor: Double(factor))
        let restored = CIImage(cgImage: stitched).applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: alpha])
        guard let result = context.createCGImage(restored, from: CGRect(origin: .zero, size: size),
                                                format: .RGBA8, colorSpace: Self.colorSpace) else { throw ToolError(L("Couldn't render")) }
        try checkCancellation()
        return CIImage(cgImage: result)
    }

    private func makeInput(bytes: [UInt8], width: Int, height: Int, x: Int, y: Int) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                         kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, Self.inputSide, Self.inputSide, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else {
            throw ToolError(L("Couldn't allocate an upscaling frame."))
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixel)?.assumingMemoryBound(to: UInt8.self) else {
            throw ToolError(L("Couldn't allocate an upscaling frame."))
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        for ty in 0..<Self.inputSide {
            let sy = Self.reflectedIndex(y + ty - Self.halo, length: height)
            for tx in 0..<Self.inputSide {
                let sx = Self.reflectedIndex(x + tx - Self.halo, length: width)
                let input = (sy * width + sx) * 4, output = ty * rowBytes + tx * 4
                base[output] = bytes[input + 2]; base[output + 1] = bytes[input + 1]
                base[output + 2] = bytes[input]; base[output + 3] = 255
            }
        }
        CVBufferSetAttachment(pixel, kCVImageBufferCGColorSpaceKey, Self.colorSpace, .shouldPropagate)
        return pixel
    }
}
