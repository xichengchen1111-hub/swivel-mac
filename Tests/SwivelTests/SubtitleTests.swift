import AppKit
import AVFoundation
import CoreImage
import Darwin
import Speech
import Testing
@testable import Swivel

@Suite(.serialized)
struct SubtitleTests {
    @Test func srtFormatsSplitsSentencesPausesAndLongCJKRuns() {
        #expect(Subtitles.timestamp(3661.234) == "01:01:01,234")
        #expect(Subtitles.timestamp(59.9998) == "00:01:00,000")
        #expect(Subtitles.timestamp(-5) == "00:00:00,000")
        #expect(Subtitles.srt(Subtitles.cues([])).isEmpty)
        let words = [TimedWord(text: "Hello", start: 0, end: 1), TimedWord(text: "world.", start: 1.1, end: 2),
                     TimedWord(text: "Again!", start: 3, end: 4)]
        let cues = Subtitles.cues(words)
        #expect(cues.count == 2 && cues[0].text == "Hello world.")
        #expect(Subtitles.srt(cues).contains("2\n00:00:03,000 --> 00:00:04,000\nAgain!"))
        let cjk = Subtitles.cues([TimedWord(text: String(repeating: "你好日本語", count: 30), start: 0, end: 25)])
        #expect(cjk.count >= 4)
        #expect(cjk.allSatisfy { $0.end - $0.start <= 7 && $0.text.split(separator: "\n").allSatisfy { $0.count <= 42 } })
        #expect(zip(cjk, cjk.dropFirst()).allSatisfy { $0.end <= $1.start })
        let overlapping = Subtitles.cues([TimedWord(text: "one.", start: 0, end: 3), TimedWord(text: "two.", start: 2, end: 4)])
        #expect(overlapping[1].start == 3)
        #expect(Subtitles.cues([TimedWord(text: "bad", start: .nan, end: 2)]).isEmpty)
    }

    @Test func importedSRTAndBurnedFrameRespectTheSourceTimeline() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Swivel-SRT-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cues = [SubtitleCue(start: 5, end: 6, text: "Hello 世界")]
        let url = try Paths.create(Data(Subtitles.srt(cues).utf8), at: folder.appendingPathComponent("clip.srt"))
        #expect(try Subtitles.read(url) == cues)
        var settings = VideoSettings()
        settings.start = 4; settings.end = 8; settings.speed = 2; settings.subtitles = cues
        #expect(!settings.isTrimOnly)
        let base = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        let context = CIContext()
        func bytes(at time: Double) -> [UInt8] {
            let frame = VideoEdit.frame(base, settings, outputTime: time)
            var bytes = [UInt8](repeating: 0, count: 640 * 360 * 4)
            context.render(frame, toBitmap: &bytes, rowBytes: 640 * 4, bounds: base.extent, format: .RGBA8, colorSpace: nil)
            return bytes
        }
        let before = bytes(at: 0), during = bytes(at: 0.6), after = bytes(at: 1.1)
        #expect(before == after && before != during)
        // Safe bottom margin is clear.
        #expect(Array(during.prefix(640 * 20 * 4)) == Array(before.prefix(640 * 20 * 4)))
        let cjk = try #require(Subtitles.overlay(SubtitleCue(start: 0, end: 1, text: String(repeating: "你", count: 42)),
                                                  size: CGSize(width: 640, height: 360)))
        let glyphs = try Retouch.Raster(#require(context.createCGImage(cjk, from: cjk.extent)))
        var whiteColumns: [Int] = []
        for y in 0..<glyphs.height { for x in 0..<glyphs.width {
            let i = (y * glyphs.width + x) * 4
            if glyphs.bytes[i] > 200 && glyphs.bytes[i + 3] > 200 { whiteColumns.append(x) }
        } }
        #expect(!whiteColumns.isEmpty && (whiteColumns.min() ?? 0) >= 16 && (whiteColumns.max() ?? 640) < 624)

    }

    @Test func importedSRTSupportsWhitespaceSeparatorsBOMAndCRLFAndRejectsBadTiming() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Swivel-SRT-Parse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = "\u{FEFF}1\r\n00:00:00,000 --> 00:00:01,000\r\nFirst\r\n \t\r\n2\r\n00:00:01,000 --> 00:00:02,000\r\nSecond\r\n"
        let url = try Paths.create(Data(text.utf8), at: folder.appendingPathComponent("windows.srt"))
        #expect(try Subtitles.read(url) == [SubtitleCue(start: 0, end: 1, text: "First"),
                                          SubtitleCue(start: 1, end: 2, text: "Second")])
        let cr = try Paths.create(Data("1\r00:00:03,000 --> 00:00:04,000\rThird\r".utf8),
                                  at: folder.appendingPathComponent("classic.srt"))
        #expect(try Subtitles.read(cr) == [SubtitleCue(start: 3, end: 4, text: "Third")])
        let invalid = ["00:00:NaN --> 00:00:02,000", "00:00:00,000 --> 00:00:inf",
                       "00:00:02,000 --> 00:00:01,000", "00:60:00,000 --> 01:01:00,000",
                       "00:00:00,000 --> 00:00:00,000"]
        for (index, timing) in invalid.enumerated() {
            let bad = try Paths.create(Data("1\n\(timing)\nBad".utf8),
                                       at: folder.appendingPathComponent("bad-\(index).srt"))
            #expect(throws: ToolError.self) { try Subtitles.read(bad) }
        }
        let overlap = try Paths.create(Data("1\n00:00:00,000 --> 00:00:03,000\nFirst\n\n2\n00:00:01,000 --> 00:00:02,000\nSecond".utf8),
                                       at: folder.appendingPathComponent("overlap.srt"))
        #expect(throws: ToolError.self) { try Subtitles.read(overlap) }
    }

    @Test func subtitleReadsRejectLinksSpecialFilesOversizedInputsAndInvalidUTF8() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Swivel-SRT-Bounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let content = Data("1\n00:00:00,000 --> 00:00:01,000\nWhole\n\n".utf8)
        var exact = content
        exact.append(Data(repeating: 32, count: Subtitles.maximumFileBytes - exact.count))
        let boundary = try Paths.create(exact, at: folder.appendingPathComponent("boundary.srt"))
        #expect(try Subtitles.read(boundary) == [SubtitleCue(start: 0, end: 1, text: "Whole")])
        let oversized = try Paths.create(exact + Data([32]), at: folder.appendingPathComponent("oversized.srt"))
        #expect(throws: ToolError.self) { try Subtitles.read(oversized) }
        // The link's own length is tiny, but the target's actual bytes exceed the cap. Both are rejected rather
        // than following it, independent of URLResourceValues' platform-specific symlink size semantics.
        let link = folder.appendingPathComponent("short-link.srt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: oversized)
        let linkSize = try #require(link.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(linkSize < Subtitles.maximumFileBytes)
        #expect(throws: (any Error).self) { try Subtitles.read(link) }
        let invalid = try Paths.create(Data([0xff, 0xfe, 0x00]), at: folder.appendingPathComponent("invalid.srt"))
        #expect(throws: ToolError.self) { try Subtitles.read(invalid) }
        let fifo = folder.appendingPathComponent("pipe.srt")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try Subtitles.read(fifo) }
        #expect(throws: ToolError.self) { try Subtitles.read(folder) }
    }

    @Test func longCaptionKeepsItsLastLineAndRefusesUnreadableOrExcessiveText() throws {
        let size = CGSize(width: 640, height: 360)
        let common = String(repeating: "A", count: 126)
        let finalA = SubtitleCue(start: 0, end: 4, text: common + "HIDDEN TEXT")
        let finalB = SubtitleCue(start: 0, end: 4, text: common + "IIIIIIIIIII")
        let a = try #require(Subtitles.overlayBitmap(finalA, size: size))
        let b = try #require(Subtitles.overlayBitmap(finalB, size: size))
        let dataA = try #require(a.dataProvider?.data) as Data
        let dataB = try #require(b.dataProvider?.data) as Data
        // Identical first three lines and equal-height bitmaps: only the formerly discarded fourth line differs.
        #expect(a.height == b.height && dataA != dataB)
        #expect(dataA.contains { $0 > 200 }) // fail if the CPU renderer silently returned an empty image
        #expect(Double(a.height) <= size.height * 0.84 + 1)
        try Subtitles.validate([finalA], size: size)
        for output in [CGSize(width: 512, height: 512), CGSize(width: 1280, height: 720), CGSize(width: 360, height: 640)] {
            let cjk = SubtitleCue(start: 0, end: 1, text: String(repeating: "你", count: 84))
            try Subtitles.validate([cjk], size: output)
            #expect(Subtitles.overlayBitmap(cjk, size: output) != nil)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Swivel-SRT-Long-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = try Paths.create(Data(Subtitles.srt([finalA]).utf8), at: folder.appendingPathComponent("long.srt"))
        #expect(try Subtitles.read(kept) == [finalA])
        let excessive = try Paths.create(Data(Subtitles.srt([SubtitleCue(start: 0, end: 1, text: String(repeating: "B", count: 2100))]).utf8),
                                         at: folder.appendingPathComponent("excessive.srt"))
        #expect(throws: ToolError.self) { try Subtitles.read(excessive) }
        #expect(throws: ToolError.self) { try Subtitles.validate([finalA], size: CGSize(width: 8, height: 8)) }
        #expect(Subtitles.overlayBitmap(finalA, size: CGSize(width: CGFloat.infinity, height: 360)) == nil)
    }

    @Test @MainActor func trimPicksUpTheSRTBesideTheVideoWithoutTickingIt() async throws {
        _ = NSApplication.shared
        let folder = try MediaBatchFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = try await MediaBatchFixtures.video(in: folder)
        let srt = movie.deletingPathExtension().appendingPathExtension("srt")
        try Subtitles.srt([SubtitleCue(start: 0.1, end: 0.8, text: "Hello")]).write(to: srt, atomically: true, encoding: .utf8)
        let editor = try await TrimEditor(source: movie)
        defer { editor.didClose() }
        try await editor.load()
        #expect(editor.subtitleCues.map(\.text) == ["Hello"])
        #expect(editor.burnSubtitles.state == .off)
        // Without a file beside it, nothing is loaded and embedding can't be ticked.
        try FileManager.default.removeItem(at: srt)
        let plain = try await TrimEditor(source: movie)
        defer { plain.didClose() }
        try await plain.load()
        plain.update()
        #expect(plain.subtitleCues.isEmpty && !plain.burnSubtitles.isEnabled)
    }
    @Test @MainActor func menuPlacementAvailabilityAndTranslations() throws {
        for (ext, title) in [("mp4", "Subtitles"), ("m4a", "Transcribe")] {
            let url = URL(fileURLWithPath: "/nonexistent/clip.\(ext)")
            let titles = Catalog.defaultItems(for: [url], mode: .tools).map(\.title)
            if #available(macOS 26, *) {
                let trim = try #require(titles.firstIndex(of: "Trim"))
                let added = try #require(titles.firstIndex(of: title))
                #expect(added == trim + 1)
            } else { #expect(!titles.contains(title)) }
            #expect(!MCPCatalog.actions(for: [url]).contains { $0.id == "tools.\(title)" })
        }
        for key in ["Subtitles", "Transcribe", "Transcription Language", "Follow App Language", "Also save SRT", "Embed subtitles in the video (hard subtitles)",
                    "Choose Subtitle File (.srt)…", "Generate from Speech", "Found %@ next to the video.", "Recognizing speech on this Mac…",
                    "%d subtitles ready.", "Generated from speech", "Subtitles are still being generated."] {
            #expect(Strings.table[key]?.count == 3)
        }
    }

    @Test(.enabled("Needs macOS 26 and an installed English speech model") { await installedEnglishSpeech() })
    func localSpeechRecognizesAKnownEnglishFileWithoutDownloading() async throws {
        if #available(macOS 26, *) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Swivel-Speech-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = try await Paths.produce(folder.appendingPathComponent("known.aiff")) { output in
                try await Shell.run("/usr/bin/say", ["-v", "Samantha", "-o", output.path, "--", "The purple bicycle is beside the yellow house."])
            }
            let before = try Data(contentsOf: source)
            let words = try await LocalTranscription.recognize(source, locale: Locale(identifier: "en-US"))
            let text = words.map(\.text).joined().lowercased()
            print("Local speech fixture: \(text)")
            #expect(text.contains("bicycle") && text.contains("yellow"))
            #expect(words.allSatisfy { $0.start.isFinite && $0.end > $0.start })
            #expect(try Data(contentsOf: source) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["known.aiff"])
        }
    }
}

private func installedEnglishSpeech() async -> Bool {
    if #available(macOS 26, *) {
        return await SpeechTranscriber.installedLocales.contains { $0.identifier == "en_US" || $0.identifier == "en-US" }
    }
    return false
}
