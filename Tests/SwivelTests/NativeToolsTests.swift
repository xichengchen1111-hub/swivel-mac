import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Swivel

@Suite(.serialized)
@MainActor
struct NativeToolsTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwivelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeImage(at url: URL, width: Int = 800, height: Int = 400, orientation: Int = 1, text: String? = nil) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        if let text {
            (text as NSString).draw(at: NSPoint(x: 30, y: height / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.cgImage!, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 27.4, kCGImagePropertyGPSLatitudeRef: "S"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Swivel fixture", kCGImagePropertyTIFFOrientation: orientation]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func testPresetKeepsOriginalAndAvoidsCollisions() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sample.png")
        try makeImage(at: source)
        let original = try Data(contentsOf: source)
        let preset = ImagePreset(id: "test", name: "Test", longEdge: 200, format: .jpeg, quality: 80, stripMetadata: true)
        let first = try preset.apply(to: source)
        let firstData = try Data(contentsOf: first)
        let second = try preset.apply(to: source)
        #expect(first != second)
        #expect(first.deletingLastPathComponent() == folder)
        #expect(second.deletingLastPathComponent() == folder)
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: first) == firstData)
        let decoded = try Images.load(first)
        #expect(decoded.width == 200 && decoded.height == 100)
        #expect(!decoded.hasAlpha)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(first as CFURL, nil)!, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFArtist] == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3)
    }

    @Test func testSmallImagesAreNotEnlargedAndMetadataCanBeKept() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("small.png")
        try makeImage(at: source, width: 120, height: 60)
        let preset = ImagePreset(id: "test", name: "Test", longEdge: 1600, format: .png, quality: 90, stripMetadata: false)
        let result = try preset.apply(to: source)
        let image = try Images.load(result)
        #expect(image.width == 120 && image.height == 60)
        let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(result as CFURL, nil)!, 0, nil) as! [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFArtist] as? String == "Swivel fixture")
    }

    @Test func testPresetCorrectsOrientationAndRejectsInvalidInputWithoutOutput() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("rotated.png")
        try makeImage(at: source, width: 800, height: 400, orientation: 6)
        let preset = ImagePreset(id: "test", name: "Test", longEdge: 200, format: .png, quality: 90, stripMetadata: false)
        let result = try preset.apply(to: source)
        let image = try Images.load(result)
        #expect(image.width == 100 && image.height == 200)
        let badFile = folder.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: badFile)
        #expect(throws: (any Error).self) { try preset.apply(to: badFile) }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("broken processed.png").path))
    }

    @Test func testPresetValidationAndStableIdentifiers() async throws {
        var preset = ImagePreset.starters[0]
        let id = preset.actionID
        preset.name = "更改名字"; preset.nameKey = nil
        #expect(preset.isValid && preset.actionID == id)
        #expect(try JSONDecoder().decode(ImagePreset.self, from: JSONEncoder().encode(preset)) == preset)
        preset.longEdge = -1; #expect(!preset.isValid)
        preset.longEdge = 63; #expect(!preset.isValid)
        preset.longEdge = 0; #expect(preset.isValid)
        preset.name = " "; #expect(!preset.isValid)
    }

    @Test func testShelfReferencesDeduplicateAndNeverDeleteOriginals() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a.txt"), b = folder.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        var shelf = ShelfContents()
        shelf.add([a, a, b, folder, folder.appendingPathComponent("missing")])
        #expect(shelf.urls == [a, b, folder])
        shelf.remove([0, 2]); #expect(shelf.urls == [b])
        shelf.clear(); #expect(shelf.urls.isEmpty)
        #expect(try Data(contentsOf: a) == Data("a".utf8))
        #expect(try Data(contentsOf: b) == Data("b".utf8))
    }

    @Test func testFeatureGatesAndSearchRespectChoices() async throws {
        let defaults = UserDefaults.standard
        let keys = ["enabled", "feature.textCapture", "feature.shelf", "feature.imagePresets", "feature.quickActions", "imagePresets.v1"]
        let before = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, before) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let image = URL(fileURLWithPath: "/tmp/image.png")
        for feature in [Feature.textCapture, .shelf, .imagePresets, .quickActions] { Prefs.setFeatureEnabled(feature, false) }
        #expect(!Catalog.defaultItems(for: [image], mode: .tools).contains { $0.title == "Extract Text" || $0.title.hasPrefix("preset.") })
        #expect(!Catalog.defaultItems(for: [image], mode: .actions).contains { $0.title == "Float" })
        Prefs.setFeatureEnabled(.textCapture, true)
        Prefs.setFeatureEnabled(.imagePresets, true)
        Prefs.imagePresets = ImagePreset.starters
        Prefs.isEnabled = false
        let commands = QuickActions.makeCommands(files: [image])
        #expect(commands.contains { $0.id == "tools.Extract Text" })
        #expect(commands.contains { $0.id == "tools.preset.web" })
        #expect(!commands.contains { $0.id == "tools.Crop" })
        #expect(QuickActions.matching(commands, query: "preset.web").count == 1)
        #expect(QuickActions.matching(commands, query: "NONEXISTENT_ACTION").isEmpty)
        #expect(Catalog.defaultItems(for: [image, image], mode: .tools).allSatisfy { $0.title != "Extract Text" })
        Prefs.setFeatureEnabled(.imagePresets, false)
        #expect(Prefs.imagePresets.count == 3)
    }

    @Test func testFileOCRFindsTextAndHandlesBlankAndInvalidImages() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("text.png")
        try makeImage(at: image, width: 1000, height: 400, text: "SWIVEL 3410")
        let result = try await TextRecognition.recognize(image)
        #expect(result.uppercased().contains("SWIVEL"))
        #expect(result.contains("3410"))
        let blank = folder.appendingPathComponent("blank.png")
        try makeImage(at: blank)
        let blankText = try await TextRecognition.recognize(blank)
        #expect(blankText.isEmpty)
        do {
            _ = try await TextRecognition.recognize(folder.appendingPathComponent("missing.png"))
            Issue.record("Missing images must fail")
        } catch { }
    }

    @Test func testTwoHotkeysDoNotReplaceEachOtherAndConflictsAreReported() async throws {
        let first = HotKey(keyCode: 40, modifiers: 4096 | 512 | 2048) { }
        defer { first.unregister() }
        #expect(first.status == 0)
        let second = HotKey(keyCode: 35, modifiers: 4096 | 512 | 2048) { }
        defer { second.unregister() }
        #expect(second.status == 0)
        let duplicate = HotKey(keyCode: 40, modifiers: 4096 | 512 | 2048) { }
        defer { duplicate.unregister() }
        #expect(duplicate.status != 0)
    }
}
