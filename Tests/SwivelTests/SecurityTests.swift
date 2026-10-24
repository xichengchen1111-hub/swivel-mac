import AppKit
import AVFoundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import Vision
@testable import Swivel

/// Regression checks for the 2026-10 security review: output paths, subprocesses, archives and draft links.
@Suite(.serialized)
@MainActor
struct SecurityTests {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aDanglingSymlinkAtTheOutputNameIsNeverWrittenThrough() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try folder(); defer { try? FileManager.default.removeItem(at: outside) }
        let source = dir.appendingPathComponent("note.md")
        try "# hello".write(to: source, atomically: true, encoding: .utf8)
        let target = outside.appendingPathComponent("planted.txt")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("note.txt"), withDestinationURL: target)

        let out = Paths.output(for: source, ext: "txt")
        #expect(out.lastPathComponent == "note 2.txt")
        #expect(Paths.taken(dir.appendingPathComponent("note.txt")))
        #expect(!Paths.taken(dir.appendingPathComponent("missing.txt")))
        // A real conversion lands beside the original and leaves the link's target uncreated.
        let txt = Docs.formats.first { $0.ext == "txt" }!
        let outputs = try await Docs.convert(source, to: txt)
        #expect(outputs.map(\.lastPathComponent) == ["note 2.txt"])
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// Runs `work` twice at the same moment, the way two quick drops on one file do.
    private func twice(_ work: @escaping @Sendable () async throws -> [URL]) async throws -> [URL] {
        try await withThrowingTaskGroup(of: [URL].self) { group in
            for _ in 0..<2 { group.addTask { try await work() } }
            return try await group.reduce(into: []) { $0 += $1 }
        }
    }

    @Test func simultaneousConversionsOfOneFileEachKeepTheirOwnOutput() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        // Noise keeps the encoders busy long enough for both conversions to have picked a name before either writes.
        let width = 1600, height = 1200
        let pixels = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt32.self)
        var seed: UInt32 = 0x9E37_79B9
        for i in 0..<(pixels.bytesPerRow / 4 * height) { seed = seed &* 1_664_525 &+ 1_013_904_223; bytes[i] = seed }
        let photo = dir.appendingPathComponent("photo.png")
        try Images.encode(try #require(pixels.makeImage()), type: .png, quality: 1).write(to: photo)
        let tone = dir.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        pcm.frameLength = 44100
        for i in 0..<44100 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 440 * 2 * .pi / 44100) * 0.2) }
        do { let file = try AVAudioFile(forWriting: tone, settings: format.settings); try file.write(from: pcm) }

        // Both see photo.jpg free; the second to finish must take photo 2.jpg rather than replace the first.
        let jpg = try #require(Images.outputFormats.first { $0.ext == "jpg" })
        let images = try await twice { try await Images.convert(photo, to: jpg) }
        #expect(Set(images.map(\.lastPathComponent)) == ["photo.jpg", "photo 2.jpg"])
        for url in images {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == width)
        }
        // A command-line tool (afconvert), an AVFoundation export and an archiver write a temporary, then publish it.
        let m4a = try #require(Audio.formats.first { $0.name == "M4A" })
        let audio = try await twice { try await Audio.convert(tone, to: m4a) }
        #expect(Set(audio.map(\.lastPathComponent)) == ["tone.m4a", "tone 2.m4a"])
        let exports = try await twice { try await Video.export(tone, AVAssetExportPresetAppleM4A, .m4a, "m4a", suffix: " export") }
        #expect(Set(exports.map(\.lastPathComponent)) == ["tone export.m4a", "tone export 2.m4a"])
        for url in audio + exports {
            let seconds = try await AVURLAsset(url: url).load(.duration).seconds
            #expect(abs(seconds - 1) < 0.1, "\(url.lastPathComponent): \(seconds) s")
        }
        let zips = try await twice { [try await Archives.zip([photo])] }
        #expect(Set(zips.map(\.lastPathComponent)) == ["photo.zip", "photo 2.zip"])
        for url in zips {
            let listing = dir.appendingPathComponent(".listing-\(UUID().uuidString)")
            let copy = dir.appendingPathComponent(".copy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: listing); try? FileManager.default.removeItem(at: copy) }
            try await Shell.run("/bin/sh", ["-c", "/usr/bin/tar -tf \"$1\" > \"$2\"", "sh", url.path, listing.path])
            let files = try String(contentsOf: listing, encoding: .utf8).split(separator: "\n").filter { !$0.hasSuffix("/") }
            // ditto's --keepParent files a single item under its folder's name.
            let entry = try #require(files.first)
            #expect(files.count == 1 && entry.hasSuffix("photo.png"), "\(url.lastPathComponent): \(files)")
            try await Shell.run("/bin/sh", ["-c", "/usr/bin/tar -xOf \"$1\" \"$2\" > \"$3\"", "sh", url.path, String(entry), copy.path])
            #expect(try Data(contentsOf: copy) == Data(contentsOf: photo), "\(url.lastPathComponent)")
        }
        // No temporaries or partial files are left behind.
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(left == Set(["photo.png", "tone.wav"] + (images + audio + exports + zips).map(\.lastPathComponent)))
    }

    @Test func outputNamesAreClaimedByTheWriteItselfNotCheckedBeforehand() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try folder(); defer { try? FileManager.default.removeItem(at: outside) }
        let fm = FileManager.default
        // What another conversion saved after this one chose its name, and a link planted under the next name.
        let preferred = dir.appendingPathComponent("photo.jpg")
        try Data("theirs".utf8).write(to: preferred)
        let planted = outside.appendingPathComponent("planted.jpg")
        try fm.createSymbolicLink(at: dir.appendingPathComponent("photo 2.jpg"), withDestinationURL: planted)

        let written = try Paths.create(Data("ours".utf8), at: preferred)
        #expect(written.lastPathComponent == "photo 3.jpg")
        #expect(try Data(contentsOf: written) == Data("ours".utf8))

        // Finished temporaries, files and folders alike, are published the same way.
        let file = Paths.temporary(beside: preferred, ext: "jpg"); defer { Paths.discard(file) }
        try Data("late".utf8).write(to: file)
        #expect(try Paths.publish(file, as: preferred).lastPathComponent == "photo 4.jpg")
        #expect(!fm.fileExists(atPath: file.path))
        let extracted = dir.appendingPathComponent("Extracted")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: false)
        let folder = Paths.temporary(beside: extracted, ext: ""); defer { Paths.discard(folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let moved = try Paths.publish(folder, as: extracted)
        #expect(moved.lastPathComponent == "Extracted 2")
        #expect(try Data(contentsOf: moved.appendingPathComponent("a.txt")) == Data("inside".utf8))

        // Volumes without RENAME_EXCL (exFAT) claim the name with an exclusive create, then rename over that.
        for isFolder in [false, true] {
            let item = Paths.temporary(beside: preferred, ext: ""); defer { Paths.discard(item) }
            if isFolder {
                try fm.createDirectory(at: item, withIntermediateDirectories: false)
                try Data("child".utf8).write(to: item.appendingPathComponent("child.txt"))
            } else {
                try Data("item".utf8).write(to: item)
            }
            for taken in [preferred, dir.appendingPathComponent("photo 2.jpg"), extracted] {
                do {
                    try Paths.renameOverPlaceholder(item, to: taken)
                    Issue.record("\(taken.lastPathComponent) was replaced")
                } catch let error as CocoaError {
                    #expect(error.code == .fileWriteFileExists)
                }
            }
            let target = dir.appendingPathComponent(isFolder ? "fallback" : "fallback.txt")
            try Paths.renameOverPlaceholder(item, to: target)
            #expect(!fm.fileExists(atPath: item.path))
            let check = isFolder ? target.appendingPathComponent("child.txt") : target
            #expect(try Data(contentsOf: check) == Data((isFolder ? "child" : "item").utf8))
        }

        // Nothing was written through, replaced or left behind.
        #expect(try Data(contentsOf: preferred) == Data("theirs".utf8))
        #expect(try fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("photo 2.jpg").path) == planted.path)
        #expect(!fm.fileExists(atPath: planted.path))
        #expect(try fm.contentsOfDirectory(atPath: extracted.path).isEmpty)
        #expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == ["photo.jpg", "photo 2.jpg", "photo 3.jpg", "photo 4.jpg",
                                                                      "Extracted", "Extracted 2", "fallback.txt", "fallback"])
    }

    /// The rename `Paths.move` uses, with what a test needs around it. Anything leaving `otherVolume` fails with EXDEV, as
    /// it would from another disk. `plant` puts a file under the first name a rename is about to take, the way another
    /// app saving into the folder between Swivel's look and its move would.
    private func renaming(from otherVolume: URL? = nil, planting plant: ((URL) throws -> Void)? = nil) -> (URL, URL) throws -> Void {
        var planted = false
        return { item, destination in
            if item.deletingLastPathComponent().path == otherVolume?.path {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.EXDEV)])
            }
            if let plant, !planted { planted = true; try plant(destination) }
            try Paths.renameExclusively(item, to: destination)
        }
    }

    private func theirs(_ url: URL) throws { try Data("theirs".utf8).write(to: url, options: .withoutOverwriting) }

    private func markCopied(_ url: URL) { _ = setxattr(url.path, Clothesline.copiedMarker, "1", 1, 0, XATTR_NOFOLLOW) }

    @Test func movesAndCopiesClaimTheirNameInTheRenameItself() throws {
        let fm = FileManager.default
        let source = try folder(); defer { try? fm.removeItem(at: source) }
        let destination = try folder(); defer { try? fm.removeItem(at: destination) }
        let rope = try folder(); defer { try? fm.removeItem(at: rope) }
        let outside = try folder(); defer { try? fm.removeItem(at: outside) }
        let link = outside.appendingPathComponent("planted.png")
        try fm.createSymbolicLink(at: destination.appendingPathComponent("Shot 2.png"), withDestinationURL: link)

        // Move here… (Wheel actions): a file saved under the name after the move chose it is skipped, as is a link.
        let shot = source.appendingPathComponent("Shot.png")
        try Data("ours".utf8).write(to: shot)
        let moved = try Paths.move(shot, into: destination, rename: renaming(planting: theirs))
        #expect(moved.lastPathComponent == "Shot 3.png")
        #expect(try Data(contentsOf: moved) == Data("ours".utf8))
        #expect(!fm.fileExists(atPath: shot.path))

        // A file dropped on the rope from elsewhere is copied the same way, and its original stays.
        let print = source.appendingPathComponent("Print.png")
        try Data("print".utf8).write(to: print)
        let copied = try Paths.copy(print, into: destination, rename: renaming(planting: theirs))
        #expect(copied.lastPathComponent == "Print 2.png")
        #expect(try Data(contentsOf: copied) == Data("print".utf8))
        #expect(try Data(contentsOf: print) == Data("print".utf8))

        // The screenshot card saving into the usual folder.
        let card = source.appendingPathComponent("Card.png")
        try Data("card".utf8).write(to: card)
        let saved = IncomingCard.save(card, to: destination, otherwise: rope, rename: renaming(planting: theirs))
        #expect(saved?.lastPathComponent == "Card 2.png")
        #expect(try Data(contentsOf: #require(saved)) == Data("card".utf8))

        // Nothing planted was replaced or written through, and no temporaries are left.
        for name in ["Shot.png", "Print.png", "Card.png"] {
            #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == Data("theirs".utf8), "\(name)")
        }
        #expect(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Shot 2.png").path) == link.path)
        #expect(!fm.fileExists(atPath: link.path))
        #expect(Set(try fm.contentsOfDirectory(atPath: destination.path)) == ["Shot.png", "Shot 2.png", "Shot 3.png", "Print.png",
                                                                              "Print 2.png", "Card.png", "Card 2.png"])
        #expect(try fm.contentsOfDirectory(atPath: source.path) == ["Print.png"])
        #expect(try fm.contentsOfDirectory(atPath: rope.path).isEmpty)
    }

    @Test func crossVolumeCopyNeverDeletesAConcurrentlyReplacedSource() throws {
        let fm = FileManager.default
        let source = try folder(); defer { try? fm.removeItem(at: source) }
        let destination = try folder(); defer { try? fm.removeItem(at: destination) }
        let rope = try folder(); defer { try? fm.removeItem(at: rope) }
        let shot = source.appendingPathComponent("Shot.png")
        try Data("old content".utf8).write(to: shot)
        markCopied(shot)
        #expect(throws: (any Error).self) { try Paths.move(shot, into: destination, rename: renaming(from: source)) }
        #expect(try Data(contentsOf: shot) == Data("old content".utf8))
        #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
        let copied = try Paths.copy(shot, into: destination) { staged, final in
            // An editor atomically saves a newer version just before publishing the already copied bytes.
            try Data("new saved content".utf8).write(to: shot, options: .atomic)
            try Paths.renameExclusively(staged, to: final)
        }
        #expect(try Data(contentsOf: copied) == Data("old content".utf8))
        #expect(try Data(contentsOf: shot) == Data("new saved content".utf8))
        #expect(Clothesline.isCopiedImage(copied))
        let album = source.appendingPathComponent("Album")
        try fm.createDirectory(at: album, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: album.appendingPathComponent("child"))
        let copy = try Paths.copy(album, into: destination)
        #expect(try Data(contentsOf: copy.appendingPathComponent("child")) == Data("child".utf8))
        #expect(fm.fileExists(atPath: album.path))
        let card = source.appendingPathComponent("Card.png")
        try Data("card".utf8).write(to: card)
        let saved = IncomingCard.save(card, to: destination, otherwise: rope) { item, target in
            if target.deletingLastPathComponent().path == destination.path { throw POSIXError(.EXDEV) }
            try Paths.renameExclusively(item, to: target)
        }
        #expect(saved?.path == rope.appendingPathComponent("Card.png").path)
        #expect(try Data(contentsOf: #require(saved)) == Data("card".utf8))
        #expect(!fm.fileExists(atPath: card.path))
        #expect(try fm.subpathsOfDirectory(atPath: destination.path).allSatisfy { !$0.contains(".swivel-") })
    }

    @Test func copiesAcrossVolumesAndMovesWithinExFATKeepOriginalsSafe() throws {
        let volume = try ScratchVolume.exFAT()
        defer { volume.detach() }
        #expect(volume.fileSystem == "exfat")
        let fm = FileManager.default
        let local = try folder(); defer { try? fm.removeItem(at: local) }
        let disk = volume.root

        // Startup disk → exFAT: explicit copy published without RENAME_EXCL (ENOTSUP on exFAT).
        try theirs(disk.appendingPathComponent("Shot.png"))
        let shot = local.appendingPathComponent("Shot.png")
        try Data("ours".utf8).write(to: shot)
        markCopied(shot)
        let moved = try Paths.copy(shot, into: disk)
        #expect(moved.lastPathComponent == "Shot 2.png")
        #expect(try Data(contentsOf: moved) == Data("ours".utf8))
        #expect(Clothesline.isCopiedImage(moved))
        #expect(fm.fileExists(atPath: shot.path))

        // Within exFAT, then back to the startup disk, keeping the attribute all the way.
        let inner = disk.appendingPathComponent("Inner", isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: false)
        try theirs(inner.appendingPathComponent("Shot 2.png"))
        let within = try Paths.move(moved, into: inner)
        #expect(within.lastPathComponent == "Shot 2 2.png")
        let back = try Paths.copy(within, into: local)
        #expect(back.path == local.appendingPathComponent("Shot 2 2.png").path)
        #expect(try Data(contentsOf: back) == Data("ours".utf8))
        #expect(Clothesline.isCopiedImage(back))

        // A folder copy, and a screenshot safely falling back to the local disk.
        try fm.createDirectory(at: disk.appendingPathComponent("Album"), withIntermediateDirectories: false)
        let album = local.appendingPathComponent("Album", isDirectory: true)
        try fm.createDirectory(at: album, withIntermediateDirectories: false)
        try Data("a".utf8).write(to: album.appendingPathComponent("a.png"))
        let movedAlbum = try Paths.copy(album, into: disk)
        #expect(movedAlbum.lastPathComponent == "Album 2")
        #expect(try Data(contentsOf: movedAlbum.appendingPathComponent("a.png")) == Data("a".utf8))
        let incoming = local.appendingPathComponent("Incoming", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: false)
        let card = incoming.appendingPathComponent("Card.png")
        try Data("card".utf8).write(to: card)
        let saved = IncomingCard.save(card, to: disk, otherwise: local)
        #expect(saved?.path == local.appendingPathComponent("Card.png").path)
        #expect(try fm.contentsOfDirectory(atPath: incoming.path).isEmpty)

        // No temporaries (or their AppleDouble shadows) are left on the drive.
        let all = try fm.subpathsOfDirectory(atPath: disk.path)
        #expect(all.filter { $0.contains(".swivel-") }.isEmpty, "\(all)")
        #expect(try Data(contentsOf: disk.appendingPathComponent("Shot.png")) == Data("theirs".utf8))
        #expect(try Data(contentsOf: inner.appendingPathComponent("Shot 2.png")) == Data("theirs".utf8))
    }

    @Test func shellDrainsLargeErrorOutputInsteadOfHanging() async throws {
        let start = Date()
        await #expect(throws: (any Error).self) {
            try await Shell.run("/usr/bin/perl", ["-e", "print STDERR 'x' x 400000; print STDERR 'last words'; exit 3"])
        }
        #expect(Date().timeIntervalSince(start) < 10)
        do {
            try await Shell.run("/usr/bin/perl", ["-e", "print STDERR 'y' x 100000; print STDERR 'tail-marker'; exit 1"])
        } catch {
            let message = error.localizedDescription
            #expect(message.hasSuffix("tail-marker"))
            #expect(message.utf8.count < 20_000)
        }
    }

    @Test func shellGivesToolsAnEmptyInputAndCanStreamFiles() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        // A tool that reads stdin gets end-of-file at once rather than waiting.
        try await Shell.run("/usr/bin/perl", ["-e", "my @all = <STDIN>; exit(scalar(@all) == 0 ? 0 : 1)"])
        let a = dir.appendingPathComponent("a.part"), b = dir.appendingPathComponent("b.part")
        try Data(repeating: 65, count: 3_000_000).write(to: a)
        try Data("tail".utf8).write(to: b)
        let joined = dir.appendingPathComponent("joined")
        try await Shell.run("/usr/bin/tee", [joined.path], input: [a, b])
        let data = try Data(contentsOf: joined)
        #expect(data.count == 3_000_004)
        #expect(data.suffix(4) == Data("tail".utf8))
    }

    @Test func shellWatchStopsAToolWithItsMessage() async throws {
        let start = Date()
        do {
            try await Shell.run("/bin/sleep", ["30"], watch: { "Not enough disk space" })
            Issue.record("The watched tool should have been stopped")
        } catch {
            #expect(error.localizedDescription == "Not enough disk space")
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func draftReferencesShowHiddenCharactersButDecodeToTheExactPath() throws {
        let hidden = String(String.UnicodeScalarView([Unicode.Scalar(0xE0072)!, Unicode.Scalar(0xE0075)!, Unicode.Scalar(0xE006E)!]))
        let names = ["report\u{202E}fdp.txt", "a\u{200B}b.txt", "tag\(hidden).txt", "quote\"back\\slash\nline.txt", "资料 C++ & #1.txt", "smile ❤️.txt"]
        for name in names {
            let path = "/tmp/x/" + name
            let literal = AssistantDraft.visibleJSONString(path)
            let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
            #expect(decoded == path)
            let invisible = literal.unicodeScalars.filter {
                [.format, .control, .privateUse, .unassigned].contains($0.properties.generalCategory)
                    || $0.properties.isDefaultIgnorableCodePoint || $0.properties.isVariationSelector
            }
            #expect(invisible.isEmpty, "\(name) leaves hidden characters in the draft")
        }
        #expect(AssistantDraft.visibleJSONString("/Users/me/a.txt") == "\"/Users/me/a.txt\"")
    }

    @Test func draftLinksEncodePlusSoFormDecodingKeepsThePath() throws {
        let files = [URL(fileURLWithPath: "/Users/me/C++ notes/a+b.txt")]
        for delivery in [FileAppTarget.Delivery.codexDraft, .claudeCodeDraft] {
            let link = try AssistantDraft.url(for: delivery, files: files)
            let query = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
            #expect(!query.contains("+"))
            // Receivers decode like URLSearchParams: "+" is a space, then percent escapes.
            let form = Dictionary(uniqueKeysWithValues: query.split(separator: "&").map { pair -> (String, String) in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let value = parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding!
                return (parts[0], value)
            })
            #expect(form[delivery == .codexDraft ? "path" : "folder"] == "/Users/me/C++ notes")
            #expect(form[delivery == .codexDraft ? "prompt" : "q"]?.contains("\"/Users/me/C++ notes/a+b.txt\"") == true)
        }
    }

    @Test func draftsNeverNameTheHomeFolderOrItsTopFoldersAsTheWorkspace() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in [home, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Downloads")] {
            let link = try AssistantDraft.url(for: .codexDraft, files: [folder.appendingPathComponent("a.txt")])
            let names = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
            #expect(!names.contains("path"), "\(folder.path)")
        }
        let deeper = try AssistantDraft.url(for: .codexDraft, files: [home.appendingPathComponent("Desktop/Project/a.txt")])
        #expect(URLComponents(url: deeper, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "path" } == true)
        let fakeHome = URL(fileURLWithPath: "/Users/someone")
        func narrow(_ path: String) -> Bool { AssistantDraft.isNarrowWorkspace(URL(fileURLWithPath: path), home: fakeHome) }
        for broad in ["/", "/Users", "/Users/someone", "/Users/someone/Pictures", "/Users/someone/Library/Caches", "/Applications", "/tmp",
                      "/Users/other", "/Library/Caches", "/Users/someone/Library/CloudStorage/Dropbox", "/Users/someone/Documents",
                      "/Users/someone/.ssh", "/Users/someone/.config", "/Users/someone/.Trash", "/Users/someone/.ssh/keys",
                      "/Users/someone/Library/CloudStorage/GoogleDrive-a@b.c/My Drive",
                      "/Volumes/Disk", "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs"] {
            #expect(!narrow(broad), "\(broad)")
        }
        for specific in ["/Users/someone/Pictures/Trip", "/Volumes/Disk/Project", "/tmp/notes", "/Users/other/Project",
                         "/Users/someone/myrepo", "/Users/someone/Library/CloudStorage/Dropbox/Work", "/Users/someone/.config/nvim",
                         "/Users/someone/Library/CloudStorage/GoogleDrive-a@b.c/My Drive/Work", "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Work"] {
            #expect(narrow(specific), "\(specific)")
        }
    }

    @Test func extractedLinksMustStayInsideTheArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func tree(_ target: String) throws -> URL {
            let dir = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("sub/real.txt"))
            try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("sub/link").path, withDestinationPath: target)
            return dir
        }
        for good in ["real.txt", "missing.txt", "."] {
            #expect(throws: Never.self) { try Archives.validateExtractedTree(try tree(good), allowMacMetadata: false) }
        }
        // The top, other top-level names (the user's files once published) and __MACOSX are outside the link's item.
        for bad in ["/etc/passwd", "..", "../sub/real.txt", "../sub", "../..", "../id_rsa", "../other/x", "../__MACOSX/x", "../../outside", "../../../../../Users"] {
            #expect(throws: ToolError.self, "\(bad)") { try Archives.validateExtractedTree(try tree(bad), allowMacMetadata: false) }
        }
        // A chain: "up" is a link to the top, so "up/../x" climbs out on disk though it reads as staying inside.
        let chain = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: chain.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: chain.appendingPathComponent("a/b/up").path, withDestinationPath: "../..")
        try FileManager.default.createSymbolicLink(atPath: chain.appendingPathComponent("esc").path, withDestinationPath: "a/b/up/../x")
        #expect(throws: ToolError.self) { try Archives.validateExtractedTree(chain, allowMacMetadata: false) }
        // A top-level link would sit beside the user's own files once published.
        let topLink = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: topLink.appendingPathComponent("A"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: topLink.appendingPathComponent("cute.png").path, withDestinationPath: "A")
        #expect(throws: ToolError.self) { try Archives.validateExtractedTree(topLink, allowMacMetadata: false) }
        // Links that loop forever are refused too.
        let loop = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: loop, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: loop.appendingPathComponent("p").path, withDestinationPath: "q")
        try FileManager.default.createSymbolicLink(atPath: loop.appendingPathComponent("q").path, withDestinationPath: "p")
        #expect(throws: ToolError.self) { try Archives.validateExtractedTree(loop, allowMacMetadata: false) }
    }

    @Test func archiveVerificationStopsPastTheExpandedLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-bomb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 4_000_000).write(to: dir.appendingPathComponent("zeros.bin"))
        let zip = dir.appendingPathComponent("small.zip")
        try await Shell.run("/usr/bin/ditto", ["-c", "-k", dir.appendingPathComponent("zeros.bin").path, zip.path])
        try await Archives.verify(zip)
        await #expect(throws: ToolError.self) { try await Archives.verify(zip, expandedLimit: 1_000_000) }
    }

    @Test func tarKeepsAFileNamedLikeAnArchiveInclusion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-attar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let odd = dir.appendingPathComponent("@notes.txt")
        try Data("mine".utf8).write(to: odd)
        let out = try await Archives.tar([odd])
        let tar = Process(), pipe = Pipe()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-tzf", out.path]
        tar.standardOutput = pipe
        try tar.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0 && listing.contains("@notes.txt"))
    }

    @Test func archiveKindsCoverRarAnd7zButNotDiskImagesOrWebArchives() {
        func kind(_ name: String) -> FileKind { FileKind.of(URL(fileURLWithPath: "/nonexistent/" + name)) }
        for name in ["a.rar", "a.7z", "a.part2.rar", "a.r00", "a.tar.xz", "a.iso", "a.zip", "a.tgz"] { #expect(kind(name) == .archive, "\(name)") }
        #expect(kind("Installer.dmg") == .other)
        #expect(kind("page.webarchive") == .other)
    }

    @Test func multiPartRarSetsAreFoundFromAnyPartAndGapsAreReported() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        for n in 1...3 { try Data([UInt8(n)]).write(to: dir.appendingPathComponent("Holiday.part\(n).rar")) }
        let parts = try Archives.volumes(of: dir.appendingPathComponent("Holiday.part2.rar"))
        #expect(parts.map(\.lastPathComponent) == ["Holiday.part1.rar", "Holiday.part2.rar", "Holiday.part3.rar"])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Holiday.part2.rar"))
        #expect(throws: (any Error).self) { try Archives.volumes(of: dir.appendingPathComponent("Holiday.part3.rar")) }

        for name in ["Old.rar", "Old.r00", "Old.r01"] { try Data([1]).write(to: dir.appendingPathComponent(name)) }
        #expect(try Archives.volumes(of: dir.appendingPathComponent("Old.r01")).map(\.lastPathComponent) == ["Old.rar", "Old.r00", "Old.r01"])
        try Data([1]).write(to: dir.appendingPathComponent("Single.rar"))
        #expect(try Archives.volumes(of: dir.appendingPathComponent("Single.rar")).count == 1)
    }

    @Test func extractedFilesKeepTheDownloadQuarantineAndEncryptedArchivesFailFast() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let content = dir.appendingPathComponent("Tool")
        try FileManager.default.createDirectory(at: content.appendingPathComponent("Inner"), withIntermediateDirectories: true)
        try "run".write(to: content.appendingPathComponent("Inner/run.sh"), atomically: true, encoding: .utf8)
        let archive = dir.appendingPathComponent("Tool.tgz")
        try await Shell.run("/usr/bin/tar", ["-czf", archive.path, "-C", dir.path, "Tool"])
        try FileManager.default.removeItem(at: content)
        let flag = "0081;6716b1c0;Safari;"
        #expect(setxattr(archive.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0)

        let outputs = try await Archives.extract(archive)
        #expect(outputs.map(\.lastPathComponent) == ["Tool"])
        for path in [outputs[0].path, outputs[0].appendingPathComponent("Inner/run.sh").path] {
            #expect(getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0, "\(path) lost its quarantine flag")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".swivel-") })

        // Most downloads hold loose files at the top, not one folder: they extract and keep the flag too.
        let loose = dir.appendingPathComponent("notes.txt")
        try "notes".write(to: loose, atomically: true, encoding: .utf8)
        let zip = dir.appendingPathComponent("Loose.zip")
        try await Shell.run("/usr/bin/zip", ["-q", zip.path, "notes.txt"], in: dir)
        try FileManager.default.removeItem(at: loose)
        #expect(setxattr(zip.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0)
        let looseOutputs = try await Archives.extract(zip)
        #expect(looseOutputs.map(\.lastPathComponent) == ["notes.txt"])
        #expect(looseOutputs.allSatisfy { getxattr($0.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 })

        // An encrypted ZIP under another extension goes through tar: a clear message, at once, no staging left behind.
        let secret = dir.appendingPathComponent("s.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        let encrypted = dir.appendingPathComponent("locked.jar")
        try await Shell.run("/usr/bin/zip", ["-q", "-P", "pw", encrypted.path, "s.txt"], in: dir)
        let start = Date()
        do {
            _ = try await Archives.extract(encrypted)
            Issue.record("An encrypted archive should not extract")
        } catch {
            #expect(error.localizedDescription == L("This archive is password-protected. Swivel can't open encrypted archives yet."))
        }
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".swivel-") })
    }

    @Test func sevenZipArchivesExtractBesideTheOriginal() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let content = dir.appendingPathComponent("Photos 2026")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 200_000).write(to: content.appendingPathComponent("a.raw"))
        try "notes".write(to: content.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
        let archive = dir.appendingPathComponent("Photos 2026.7z")
        try await Shell.run("/usr/bin/tar", ["--format", "7zip", "-cf", archive.path, "-C", dir.path, "Photos 2026"])
        try FileManager.default.removeItem(at: content)
        #expect(FileKind.of(archive) == .archive)
        let outputs = try await Archives.extract(archive)
        #expect(outputs.map(\.lastPathComponent) == ["Photos 2026"])
        #expect(try Data(contentsOf: outputs[0].appendingPathComponent("a.raw")).count == 200_000)
        #expect(try String(contentsOf: outputs[0].appendingPathComponent("说明.txt"), encoding: .utf8) == "notes")
    }

    @Test func webArchivesInDisguiseAreNotReadWithWebKit() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let html = #"<html><body>Hello<iframe src="http://127.0.0.1:9/frame.html"></iframe><img src="file:///etc/hosts"></body></html>"#
        let archive: [String: Any] = ["WebMainResource": ["WebResourceData": Data(html.utf8), "WebResourceMIMEType": "text/html",
                                                          "WebResourceTextEncodingName": "UTF-8", "WebResourceURL": "https://example.com/"]]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        let txt = Docs.formats.first { $0.ext == "txt" }!
        for name in ["report.doc", "report.docx", "report.odt", "report.text"] {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            if let outputs = try? await Docs.convert(url, to: txt) {
                // Whatever the typed reader makes of it, nothing from the web or the disk comes along.
                let text = try String(contentsOf: outputs[0], encoding: .utf8)
                #expect(!text.contains("localhost") && !text.contains("broadcasthost"), "\(name)")
            }
        }
        #expect(FileKind.of(dir.appendingPathComponent("page.webarchive")) == .other)
    }

    @Test func readOnlyAndLockedItemsStillGetTheQuarantineFlag() async throws {
        let dir = try folder()
        defer { Archives.makeAccessible(dir); try? FileManager.default.removeItem(at: dir) }
        // The archive records the awkward modes (an mtree spec), so the fixture itself never needs unreadable folders.
        let payload = dir.appendingPathComponent("payload"), readme = dir.appendingPathComponent("readme")
        try "x".write(to: payload, atomically: true, encoding: .utf8)
        try "r".write(to: readme, atomically: true, encoding: .utf8)
        let spec = """
            #mtree
            Kit type=dir mode=0755
            Kit/readme.txt type=file mode=0444 contents=\(readme.path)
            Kit/locked type=dir mode=0300
            Kit/locked/deeper type=dir mode=0555
            Kit/locked/deeper/payload.command type=file mode=0644 contents=\(payload.path)

            """
        let specFile = dir.appendingPathComponent("spec.mtree")
        try spec.write(to: specFile, atomically: true, encoding: .utf8)
        try await Shell.run("/usr/bin/tar", ["-czf", dir.appendingPathComponent("Kit.tgz").path, "@" + specFile.path], in: dir)
        let archive = dir.appendingPathComponent("Kit.tgz")
        let flag = "0081;6716b1c0;Safari;"
        #expect(setxattr(archive.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0)
        let outputs = try await Archives.extract(archive)
        let root = try #require(outputs.first)
        for relative in ["", "readme.txt", "locked", "locked/deeper", "locked/deeper/payload.command"] {
            let path = relative.isEmpty ? root.path : root.appendingPathComponent(relative).path
            #expect(getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) > 0, "\(relative) has no quarantine flag")
        }
        var info = stat()
        #expect(lstat(root.appendingPathComponent("readme.txt").path, &info) == 0 && info.st_mode & 0o777 == 0o444)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".swivel-") })
    }

    @Test func archivingFilesFromSeveralFoldersIsRefusedNotTruncated() async throws {
        let one = try folder(), two = try folder()
        defer { try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }
        let a = one.appendingPathComponent("a.txt"), b = two.appendingPathComponent("b.txt")
        try "a".write(to: a, atomically: true, encoding: .utf8); try "b".write(to: b, atomically: true, encoding: .utf8)
        await #expect(throws: (any Error).self) { try await Archives.zip([a, b]) }
        await #expect(throws: (any Error).self) { try await Archives.tar([a, b]) }
    }

    @Test func optionLikeFileNamesAreArchivedNotObeyed() async throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["a.dat", "-T", "--use-compress-program=touch pwned"]
        for name in names { try Data(name.utf8).write(to: dir.appendingPathComponent(name)) }
        let urls = names.map { dir.appendingPathComponent($0) }
        let zip = try await Archives.zip(urls)
        let tgz = try await Archives.tar(urls)
        for archive in [zip, tgz] {
            let listing = dir.appendingPathComponent("listing-\(archive.pathExtension).txt")
            try await Shell.run("/bin/sh", ["-c", "/usr/bin/tar -tf \"$1\" > \"$2\"", "sh", archive.path, listing.path])
            let entries = Set(try String(contentsOf: listing, encoding: .utf8).split(separator: "\n").map(String.init))
            #expect(entries == Set(names), "\(archive.lastPathComponent): \(entries)")
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned").path))
    }

    @Test func hugePdfPagesRenderWithinTheBudgetInsteadOfTrapping() throws {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 400_000, height: 300_000), for: .mediaBox)
        let image = try PDFs.render(page, dpi: 300)
        #expect(Double(image.width * image.height) <= PDFs.maxRenderPixels)
        #expect(Double(max(image.width, image.height)) <= PDFs.maxRenderSide)
        page.setBounds(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), for: .mediaBox)
        #expect(throws: (any Error).self) { try PDFs.render(page, dpi: 300) }
    }

    @Test func metadataRemovalLeavesNoLocationInAnyFormat() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let pixels = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(pixels.makeImage())
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Secretville", kCGImagePropertyIPTCSubLocation: "12 Hidden Lane",
                                             kCGImagePropertyIPTCCountryPrimaryLocationName: "Nowhere"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "CameraCo", kCGImagePropertyTIFFArtist: "A. Person"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:21 09:00:00"],
        ]
        for (ext, type) in [("jpg", UTType.jpeg), ("png", .png), ("heic", .heic), ("tiff", .tiff)] {
            let url = dir.appendingPathComponent("photo.\(ext)")
            let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, image, properties as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            let locationOnly = MetadataEditor.Removal(location: true, camera: false, date: false, author: false, everything: false)
            let cleaned = try MetadataEditor.cleaned(url, locationOnly)
            #expect(MetadataEditor.isClean(cleaned, locationOnly), "\(ext)")
            let text = String(decoding: cleaned, as: UTF8.self) + String(decoding: cleaned, as: Unicode.ASCII.self)
            #expect(!text.contains("Secretville") && !text.contains("Hidden Lane"), "\(ext) still names the place")
            let everything = MetadataEditor.Removal(location: false, camera: false, date: false, author: false, everything: true)
            let bare = try MetadataEditor.cleaned(url, everything)
            let bareText = String(decoding: bare, as: Unicode.ASCII.self)
            #expect(!bareText.contains("CameraCo") && !bareText.contains("A. Person") && !bareText.contains("Secretville"), "\(ext)")
        }
    }

    @Test func pixelateAndBlurHideLargeTextToo() throws {
        let size = CGSize(width: 1600, height: 1000)
        let ctx = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(.white); ctx.fill(CGRect(origin: .zero, size: size))
        let line = NSAttributedString(string: "PIN 4096", attributes: [.font: NSFont.boldSystemFont(ofSize: 220), .foregroundColor: NSColor.black])
        let framesetter = CTFramesetterCreateWithAttributedString(line)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(x: 120, y: 300, width: 1400, height: 400), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        let image = try #require(ctx.makeImage())
        func words(_ image: CGImage) throws -> [String] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }
        #expect(try words(image).joined().contains("4096"))
        let box = [CGRect(x: 0.05, y: 0.25, width: 0.9, height: 0.5)]
        for style in [0, 1] {
            let hidden = try #require(RedactEditor.render(image, rects: box, style: style))
            #expect(!(try words(hidden).joined().contains("4096")), "style \(style) leaves the text readable")
        }
    }
}

/// A small exFAT disk image attached for one test, out of Finder's sight: a second volume, and a file system without
/// RENAME_EXCL.
struct ScratchVolume {
    let root: URL
    private let base: URL

    /// Throws hdiutil's own message when this Mac can't make or attach one.
    static func exFAT() throws -> ScratchVolume {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("swivel-volume-\(UUID().uuidString)", isDirectory: true)
        let image = base.appendingPathComponent("scratch.dmg"), root = base.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            // An exFAT label is 11 characters at most; a longer one fails with "Operation not permitted".
            try hdiutil(["create", "-size", "8m", "-fs", "ExFAT", "-volname", "Scratch", "-layout", "NONE", image.path])
            try hdiutil(["attach", "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", root.path, image.path])
        } catch {
            try? fm.removeItem(at: base)
            throw error
        }
        return ScratchVolume(root: root, base: base)
    }

    var fileSystem: String {
        var info = statfs()
        guard statfs(root.path, &info) == 0 else { return "" }
        return withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Removes the image only once it's detached, so nothing is deleted through a mount that is still there.
    func detach() {
        guard (try? Self.hdiutil(["detach", "-force", root.path])) != nil else { return }
        try? FileManager.default.removeItem(at: base)
    }

    private static func hdiutil(_ args: [String]) throws {
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError("hdiutil \(args[0]): \(message)") }
    }
}
