import AppKit
import AVFoundation
import AVKit
import Accelerate

/// Original STFT spectral subtraction. A credible quiet file segment estimates the noise; when no such segment
/// exists, attenuation stays conservative. Memory is bounded by channels × FFT size, not file duration.
enum NoiseReduction {
    static let size = 2048, hop = 512
    static let logSize = vDSP_Length(11)

    /// A quiet voice segment is not automatically a noise sample. Require useful level separation and reject
    /// concentrated tonal profiles, which may be a held vowel / note. This is a conservative signal heuristic,
    /// not a speech classifier; an uncertain profile must not authorize aggressive subtraction.
    static func isCredibleNoise(quietEnergy: Double, activeEnergy: Double, spectrum: [Float]) -> Bool {
        guard quietEnergy.isFinite, activeEnergy.isFinite, activeEnergy > 1e-16,
              quietEnergy <= activeEnergy * 0.25,
              spectrum.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
        let total = spectrum.reduce(0.0) { $0 + Double($1) }
        guard total > 1e-20 else { return true } // Digital silence cannot subtract audible material.
        let peak = Double(spectrum.max() ?? 0)
        return peak < total * 0.08
    }

    private static func transform(_ real: inout [Float], _ imaginary: inout [Float], setup: FFTSetup, inverse: Bool) {
        real.withUnsafeMutableBufferPointer { r in imaginary.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            vDSP_fft_zip(setup, &split, 1, logSize, FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
        } }
    }

    /// Processes an already decoded PCM file into a CAF, retaining exact frame and channel counts.
    static func processPCM(_ source: URL, to target: URL, strength rawStrength: Double,
                           progress: @Sendable (Double) -> Void = { _ in }) throws {
        let strength = Float(min(1, max(0, rawStrength.isFinite ? rawStrength : 0)))
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat, channels = Int(format.channelCount), length = Int(input.length)
        guard length > 0, let setup = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(size, Int(format.sampleRate / 4)))) else {
            throw ToolError(L("Couldn't encode audio."))
        }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = (0..<size).map { Float(sqrt(0.5 - 0.5 * cos(2 * .pi * (Double($0) + 0.5) / Double(size)))) }
        let quietSize = Int(buffer.frameCapacity)
        var quiet = 0, leastEnergy = Double.infinity, cursor = 0
        var quietEnergy = [Double](repeating: 0, count: channels)
        // A fixed 1 dB histogram gives a robust active-level percentile without storing per-window energies.
        var energies = [[Int]](repeating: [Int](repeating: 0, count: 201), count: channels)
        var analyzed = 0
        let analysisSize = min(quietSize, length)
        // Ignore a final partial window when choosing a profile: a tiny truncated tail is not noise evidence.
        while cursor < length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(quietSize, length - cursor)))
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            var channelEnergy = [Double](repeating: 0, count: channels)
            for c in 0..<channels { for i in 0..<count {
                let value = buffer.floatChannelData![c][i]
                guard value.isFinite else { throw ToolError(L("Couldn't encode audio.")) }
                channelEnergy[c] += Double(value) * Double(value) / Double(count)
            } }
            if count >= analysisSize {
                for c in 0..<channels {
                    let bin = min(200, max(0, Int((10 * log10(max(1e-16, channelEnergy[c])) + 160).rounded(.down))))
                    energies[c][bin] += 1
                }
                analyzed += 1
                let energy = channelEnergy.reduce(0, +) / Double(channels)
                if energy < leastEnergy { leastEnergy = energy; quiet = cursor; quietEnergy = channelEnergy }
            }
            cursor += count
        }
        var noise = [[Float]](repeating: [Float](repeating: 0, count: size / 2 + 1), count: channels)
        var real = [Float](repeating: 0, count: size), imaginary = real
        let quietEnd = min(length, quiet + quietSize)
        var profiles = 0
        for start in stride(from: quiet, to: max(quiet + 1, quietEnd - size + 1), by: hop) {
            try Task.checkCancellation()
            input.framePosition = AVAudioFramePosition(start)
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(size, length - start)))
            for c in 0..<channels {
                for i in 0..<size { real[i] = i < Int(buffer.frameLength) ? buffer.floatChannelData![c][i] * window[i] : 0; imaginary[i] = 0 }
                transform(&real, &imaginary, setup: setup, inverse: false)
                for k in 0...size / 2 {
                    let power = real[k] * real[k] + imaginary[k] * imaginary[k]
                    guard power.isFinite else { throw ToolError(L("Couldn't encode audio.")) }
                    noise[c][k] += power
                }
            }
            profiles += 1
        }
        for c in 0..<channels { for k in 0...size / 2 { noise[c][k] /= Float(max(1, profiles)) } }
        let credible = (0..<channels).map { c -> Bool in
            var count = 0, percentile = 0
            for bin in 0..<energies[c].count {
                count += energies[c][bin]
                if count >= max(1, Int(ceil(Double(analyzed) * 0.8))) { percentile = bin; break }
            }
            let active = pow(10, Double(percentile - 160) / 10)
            return isCredibleNoise(quietEnergy: quietEnergy[c], activeEnergy: active, spectrum: noise[c])
        }
        let floors = credible.map { $0 ? pow(Float(0.01), strength) : pow(Float(10), -3 * strength / 20) }
        let output = try AVAudioFile(forWriting: target, settings: format.settings.merging([AVLinearPCMIsNonInterleaved: false]) { _, new in new })
        var accumulation = [[Float]](repeating: [Float](repeating: 0, count: size), count: channels)
        var weights = [Float](repeating: 0, count: size)
        var previous = [[Float]](repeating: [Float](repeating: 1, count: size / 2 + 1), count: channels)
        let writeBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hop))!
        for start in stride(from: -size + hop, to: length, by: hop) {
            try Task.checkCancellation()
            input.framePosition = AVAudioFramePosition(max(0, start))
            let prefix = max(0, -start), count = min(size - prefix, length - max(0, start))
            try input.read(into: buffer, frameCount: AVAudioFrameCount(max(0, count)))
            for c in 0..<channels {
                for i in 0..<size {
                    let index = i - prefix
                    real[i] = index >= 0 && index < Int(buffer.frameLength) ? buffer.floatChannelData![c][index] * window[i] : 0
                    imaginary[i] = 0
                }
                transform(&real, &imaginary, setup: setup, inverse: false)
                for k in 0...size / 2 {
                    let power = real[k] * real[k] + imaginary[k] * imaginary[k]
                    let estimate = noise[c][k]
                    guard power.isFinite, estimate.isFinite else { throw ToolError(L("Couldn't encode audio.")) }
                    var gain: Float = strength == 0 ? 1 : sqrt(max(floors[c] * floors[c], 1 - (1 + 3 * strength) * estimate / max(1e-15, power)))
                    if strength > 0 {
                        let speed: Float = gain > previous[c][k] ? 0.8 : 0.3
                        gain = speed * gain + (1 - speed) * previous[c][k]
                    }
                    previous[c][k] = gain
                    real[k] *= gain; imaginary[k] *= gain
                    if k > 0 && k < size / 2 { real[size - k] *= gain; imaginary[size - k] *= gain }
                }
                transform(&real, &imaginary, setup: setup, inverse: true)
                for i in 0..<size { accumulation[c][i] += real[i] * window[i] / Float(size) }
            }
            for i in 0..<size { weights[i] += window[i] * window[i] }
            if start >= 0 {
                let count = min(hop, length - start)
                writeBuffer.frameLength = AVAudioFrameCount(count)
                for c in 0..<channels { for i in 0..<count {
                    writeBuffer.floatChannelData![c][i] = accumulation[c][i] / max(weights[i], 1e-10)
                } }
                try output.write(from: writeBuffer)
                progress(Double(start + count) / Double(length))
            }
            for c in 0..<channels {
                for i in 0..<(size - hop) { accumulation[c][i] = accumulation[c][i + hop] }
                for i in (size - hop)..<size { accumulation[c][i] = 0 }
            }
            for i in 0..<(size - hop) { weights[i] = weights[i + hop] }
            for i in (size - hop)..<size { weights[i] = 0 }
        }
    }

    static func cleanedPCM(_ source: URL, strength: Double, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let decoded = try await AudioFiles.decode(source)
        defer { MediaTemporaryFiles.discard(decoded) }
        return try await MediaTemporaryFiles.produce(ext: "caf") { target in
            let worker = Task.detached(priority: .userInitiated) { try processPCM(decoded, to: target, strength: strength, progress: progress) }
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
    }

    static func save(_ source: URL, strength: Double, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let cleaned = try await cleanedPCM(source, strength: strength, progress: progress)
        defer { MediaTemporaryFiles.discard(cleaned) }
        guard let session = AVAssetExportSession(asset: try await Video.safeAsset(cleaned), presetName: AVAssetExportPresetAppleM4A) else {
            throw ToolError(L("Couldn't encode audio."))
        }
        return try await Paths.produce(Paths.preferred(for: source, ext: "m4a", suffix: " clean")) { target in
            try await withTaskCancellationHandler {
                try Task.checkCancellation(); try await session.export(to: target, as: .m4a); try Task.checkCancellation()
            } onCancel: { session.cancelExport() }
        }
    }
}

final class NoiseReductionEditor: Editor {
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private var strength: DetentSlider!
    private let progress = NSProgressIndicator()
    private var task: Task<[URL], Error>?
    init(source: URL) {
        playerView.player = player
        playerView.controlsStyle = .inline
        super.init(title: "Reduce Noise", source: source, canvas: playerView)
        strength = slider(0, 1, 0.75)
        addRow("Strength", strength)
        let hint = NSTextField(wrappingLabelWithString: L("For voice recordings. Preview plays the original; noise reduction is applied when saving."))
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        addRow("", hint)
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 240).isActive = true
        addRow("", progress)
    }
    override func load() async throws { player.replaceCurrentItem(with: AVPlayerItem(asset: try await Video.safeAsset(source))) }
    override func reset() { strength.doubleValue = 0.75 }
    override var canCancelSaving: Bool { true }
    override func cancelSaving() { task?.cancel() }
    override func didClose() { task?.cancel(); player.pause() }
    override func apply() async throws -> [URL] {
        player.pause()
        let source = self.source, strength = strength.doubleValue
        let task = Task { [weak self] in [try await NoiseReduction.save(source, strength: strength) { [weak self] value in
            Task { @MainActor in self?.progress.doubleValue = value }
        }] }
        self.task = task
        defer { self.task = nil }
        return try await task.value
    }
}
