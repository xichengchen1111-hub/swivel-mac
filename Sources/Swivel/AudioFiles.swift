import AVFoundation
import os

/// File-only PCM decoding shared by media effects. No input device, permissions, or network.
enum AudioFiles {
    /// One worker owns sample reads. The only cross-task operation is cancellation, serialized with reader startup.
    private final class DecoderState: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let gate = OSAllocatedUnfairLock(initialState: (started: false, cancelled: false))
        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) { self.reader = reader; self.output = output }
    }
    /// The standard format only covers mono and stereo; 5.1 and other multichannel tracks keep their channels in order.
    static func pcmFormat(rate: Double, channels: Int) -> AVAudioFormat? {
        if channels <= 2 { return AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
    }
    private static func layoutData(_ channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }
    static func decode(_ source: URL, preservePrecision: Bool = false) async throws -> URL {
        let asset = try await Video.safeAsset(source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let description = try await track.load(.formatDescriptions).first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            throw ToolError(L("This file has no audio."))
        }
        if preservePrecision {
            let floating = stream.mFormatID == kAudioFormatLinearPCM && stream.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let bits = stream.mFormatID == kAudioFormatAppleLossless
                ? ([1: UInt32(16), 2: 20, 3: 24, 4: 32][stream.mFormatFlags] ?? 0) : stream.mBitsPerChannel
            guard floating ? bits <= 32 : bits <= 24 else {
                throw ToolError(L("This soundtrack exceeds the precision supported by video-to-WAV export. Keep or export its original audio track."))
            }
        }
        let rate = stream.mSampleRate, channels = Int(stream.mChannelsPerFrame)
        let duration = try await asset.load(.duration).seconds
        guard rate.isFinite, rate >= 8000, rate <= 384000, (1...16).contains(channels),
              duration.isFinite, duration > 0, duration <= 86400,
              let format = pcmFormat(rate: rate, channels: channels) else {
            throw ToolError(L("This audio format or duration is not supported."))
        }
        let storage = try MediaTemporaryFiles.pcmBudget(rate: rate, channels: channels, duration: duration)
        let totalFrames = Int((duration * rate).rounded())
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
            .merging(channels > 2 ? [AVChannelLayoutKey: layoutData(channels)] : [:]) { _, new in new })
        guard reader.canAdd(output) else { throw ToolError(L("Couldn't encode audio.")) }
        reader.add(output)
        let state = DecoderState(reader: reader, output: output)
        return try await MediaTemporaryFiles.produce(ext: "caf", budgetBytes: storage) { target in
                let worker = Task.detached(priority: .userInitiated) {
                    let reader = state.reader, output = state.output, gate = state.gate
                    let started = try gate.withLockUnchecked { state -> Bool in
                        guard !state.cancelled else { return false }
                        guard reader.startReading() else { throw reader.error ?? ToolError(L("Couldn't encode audio.")) }
                        state.started = true
                        return true
                    }
                    guard started else { throw CancellationError() }
                    let file = try AVAudioFile(forWriting: target, settings: format.settings.merging([AVLinearPCMIsNonInterleaved: false]) { _, new in new })
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                        throw ToolError(L("Couldn't encode audio."))
                    }
                    var written = 0
                    var bytesSinceSpaceCheck: Int64 = 1_048_576
                    func writeBuffer(_ count: Int) throws {
                        try Task.checkCancellation()
                        let bytes = Int64(count * channels * 4)
                        if bytesSinceSpaceCheck >= 1_048_576 {
                            try MediaTemporaryFiles.ensureSpace(at: target, writing: bytes)
                            bytesSinceSpaceCheck = 0
                        }
                        buffer.frameLength = AVAudioFrameCount(count)
                        try file.write(from: buffer)
                        written += count; bytesSinceSpaceCheck += bytes
                    }
                    func silence(until end: Int) throws {
                        while written < end {
                            let count = min(4096, end - written)
                            for c in 0..<channels { buffer.floatChannelData![c].initialize(repeating: 0, count: count) }
                            try writeBuffer(count)
                        }
                    }
                    var interleaved = [Float](repeating: 0, count: 4096 * channels)
                    while true {
                        try Task.checkCancellation()
                        guard let sample = output.copyNextSampleBuffer() else { break }
                        let frames = CMSampleBufferGetNumSamples(sample)
                        guard frames > 0, frames <= 4_000_000, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        guard seconds.isFinite, seconds >= -1, seconds <= duration + 1 else { throw ToolError(L("Invalid audio timing.")) }
                        let packetStart = Int((seconds * rate).rounded())
                        let expected = min(totalFrames, max(0, packetStart))
                        try silence(until: expected)
                        // Do not append overlapping packets or codec priming outside the declared timeline.
                        var offset = min(frames, max(0, written - packetStart))
                        guard CMBlockBufferGetDataLength(block) >= frames * channels * 4 else { throw ToolError(L("Couldn't encode audio.")) }
                        while offset < frames, written < totalFrames {
                            let count = min(4096, frames - offset, totalFrames - written)
                            let code = interleaved.withUnsafeMutableBytes {
                                CMBlockBufferCopyDataBytes(block, atOffset: offset * channels * 4,
                                    dataLength: count * channels * 4, destination: $0.baseAddress!)
                            }
                            guard code == noErr else { throw ToolError(L("Couldn't encode audio.")) }
                            for c in 0..<channels { for i in 0..<count {
                                let sample = interleaved[i * channels + c]
                                guard sample.isFinite else { throw ToolError(L("Invalid audio samples.")) }
                                buffer.floatChannelData![c][i] = sample
                            } }
                            try writeBuffer(count); offset += count
                        }
                    }
                    guard reader.status == .completed else { throw reader.error ?? CancellationError() }
                    try silence(until: totalFrames)
                    try Task.checkCancellation()
                }
                try await withTaskCancellationHandler { try await worker.value } onCancel: {
                    worker.cancel()
                    state.gate.withLockUnchecked { flags in
                        flags.cancelled = true
                        if flags.started, state.reader.status == .reading { state.reader.cancelReading() }
                    }
                }
        }
    }
}
