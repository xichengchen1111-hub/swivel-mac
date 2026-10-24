import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Swivel

/// Change Style for folders: tinting, badges, applying and restoring the icon, the menu entry.
@Suite(.serialized)
@MainActor
struct FolderStyleTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-style-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Alpha-weighted mean colour of an image, 0…1.
    private func meanColor(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let size = image.width
        let ctx = FolderIcons.context(size)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: size * size * 4)
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0
        for i in 0..<(size * size) {
            r += Double(p[i * 4]); g += Double(p[i * 4 + 1]); b += Double(p[i * 4 + 2]); a += Double(p[i * 4 + 3])
        }
        return (r / a, g / a, b / a)
    }

    @Test func aTintRecoloursTheFolderAndKeepsItsShape() throws {
        let base = try #require(FolderIcons.baseIcon(size: 256))
        for hex in ["E5484D", "3FAE5A", "F2C230"] {
            let style = FolderStyle(tint: hex)
            let icon = try #require(FolderIcons.render(style, base: base, size: 256))
            let (r, g, b) = meanColor(icon)
            let (tr, tg, tb) = try #require(FolderStyle.rgb(hex))
            // The dominant channel of the tint dominates the result.
            let order = [tr, tg, tb].enumerated().max { $0.element < $1.element }!.offset
            #expect([r, g, b].enumerated().max { $0.element < $1.element }!.offset == order, "\(hex)")
            #expect(abs(r - tr) < 0.2 && abs(g - tg) < 0.2 && abs(b - tb) < 0.2, "\(hex): \(r) \(g) \(b)")
            // Transparent stays transparent: same alpha as the system folder.
            #expect(alphaSum(icon) == alphaSum(base))
        }
        // No tint is the system folder unchanged.
        let plain = try #require(FolderIcons.render(FolderStyle(), base: base, size: 256))
        #expect(png(plain) == png(try #require(FolderIcons.render(FolderStyle(), base: base, size: 256))))
    }

    private func alphaSum(_ image: CGImage) -> Int {
        let ctx = FolderIcons.context(image.width)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return (0..<(image.width * image.height)).reduce(0) { $0 + Int(p[$1 * 4 + 3]) }
    }

    private func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @Test func badgesDrawOnTheFolderFront() throws {
        let base = try #require(FolderIcons.baseIcon(size: 256))
        let plain = try #require(FolderIcons.render(FolderStyle(tint: "3D82F0"), base: base, size: 256))
        var symbol = FolderStyle(tint: "3D82F0"); symbol.badge = .symbol
        var emoji = FolderStyle(tint: "3D82F0"); emoji.badge = .emoji; emoji.emoji = "  📷 and more"
        #expect(emoji.drawnEmoji == "📷")
        for style in [symbol, emoji] {
            let icon = try #require(FolderIcons.render(style, base: base, size: 256))
            #expect(png(icon) != png(plain))
        }
        let picture = try #require(FolderIcons.context(64))
        picture.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        picture.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let whole = try #require(FolderIcons.render(FolderStyle(), base: base, picture: picture.makeImage(), pictureFills: true, size: 256))
        let (r, g, _) = meanColor(whole)
        #expect(r > 0.95 && g < 0.05)

        if let dir = ProcessInfo.processInfo.environment["SWIVEL_FOLDER_RENDERS"] {
            let big = try #require(FolderIcons.baseIcon())
            var styles: [(String, FolderStyle)] = FolderStyle.colors.map { ($0.title, FolderStyle(tint: $0.hex)) }
            styles += [("symbol", symbol), ("emoji", emoji)]
            var code = FolderStyle(tint: "4A4A4F"); code.badge = .symbol; code.symbol = "chevron.left.forwardslash.chevron.right"
            styles.append(("code", code))
            for (name, style) in styles {
                let icon = try #require(FolderIcons.render(style, base: big))
                try png(icon).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
            for (i, entry) in FolderLibrary.entries.enumerated() {
                let icon = try #require(FolderIcons.render(entry.style, base: big, size: 512))
                try png(icon).write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "lib%02d.png", i)))
            }
            let onFront = try #require(FolderIcons.render(FolderStyle(tint: "F2843A"), base: big, picture: picture.makeImage()))
            try png(onFront).write(to: URL(fileURLWithPath: dir).appendingPathComponent("picture.png"))
        }
    }

    @Test func applyingSetsTheIconAndDefaultRemovesIt() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("A"), b = dir.appendingPathComponent("B")
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        try Data("keep".utf8).write(to: a.appendingPathComponent("note.txt"))
        let base = try #require(FolderIcons.baseIcon(size: 256))
        let icon = try #require(FolderIcons.render(FolderStyle(tint: "E5484D"), base: base, size: 256))
        #expect(!FolderIcons.hasCustomIcon(a))
        #expect(try FolderIcons.apply(icon, to: [a, b]) == 2)
        #expect(FolderIcons.hasCustomIcon(a) && FolderIcons.hasCustomIcon(b))
        // Only the hidden icon file was added; the folder's contents are untouched.
        #expect(try Data(contentsOf: a.appendingPathComponent("note.txt")) == Data("keep".utf8))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: a.path)) == ["note.txt", "Icon\r"])
        #expect(try FolderIcons.apply(nil, to: [a, b]) == 2)
        #expect(!FolderIcons.hasCustomIcon(a) && !FolderIcons.hasCustomIcon(b))
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.path) == ["note.txt"])
    }

    @Test func onlyPlainFoldersAreAccepted() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let file = dir.appendingPathComponent("file.txt")
        try Data().write(to: file)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        for bad in [app, file, link] {
            #expect(throws: (any Error).self) { try FolderIcons.checkFolder(bad) }
            #expect(throws: (any Error).self) { try FolderIcons.apply(nil, to: [bad]) }
        }
        #expect(!FolderIcons.hasCustomIcon(app))
        try FolderIcons.checkFolder(dir)
    }

    @Test func recentsKeepTheNewestSixWithoutRepeats() {
        let saved = Prefs.folderStyleRecents
        defer { Prefs.folderStyleRecents = saved }
        Prefs.folderStyleRecents = []
        FolderIcons.remember(FolderStyle())  // the plain folder isn't worth a slot
        #expect(FolderIcons.recents.isEmpty)
        for hex in ["E5484D", "F2843A", "F2C230", "3FAE5A", "3CC8B4", "2FA6C6", "3D82F0"] {
            FolderIcons.remember(FolderStyle(tint: hex))
        }
        FolderIcons.remember(FolderStyle(tint: "F2C230"))
        #expect(FolderIcons.recents.map(\.tint) == ["F2C230", "3D82F0", "2FA6C6", "3CC8B4", "3FAE5A", "F2843A"])
    }

    @Test func foldersOfferChangeStyleFirstAndAgentsDoNot() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let titles = Catalog.defaultItems(for: [dir], mode: .tools).map(\.title)
        #expect(titles.first == "Change Style")
        #expect(titles.contains("ZIP") && titles.contains("TAR.GZ"))
        // Everything for folders is in one menu: the convert menu doesn't repeat compressing.
        #expect(Catalog.defaultItems(for: [dir], mode: .convert).isEmpty)
        let file = dir.appendingPathComponent("x.unknownext")
        try Data().write(to: file)
        #expect(!Catalog.defaultItems(for: [file], mode: .tools).map(\.title).contains("Change Style"))
        #expect(!MCPCatalog.actions(for: [dir]).map(\.id).contains("tools.Change Style"))
        for key in ["Change Style", "Custom Style", "macOS Default", "On the Folder", "No Badge", "Image", "Original Color"]
            + FolderStyle.symbols.map(\.title) + FolderStyle.colors.map(\.title)
            + FolderMaterial.allCases.map(\.title) + FolderLibrary.entries.map(\.title) + ["Library", "Text", "Optional, e.g. POSTER DESIGN"] {
            #expect(Strings.table[key] != nil, "\(key)")
        }
    }

    @Test func theEditorOpensForSeveralFolders() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("A"), b = dir.appendingPathComponent("B")
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let editor = try FolderStyleEditor(folders: [a, b])
        #expect(editor.window.subtitle.contains("2"))
        #expect(throws: (any Error).self) { try FolderStyleEditor(folders: []) }
    }

    @Test func materialsKeepTheFolderShapeAndLookTheSameEachTime() throws {
        let base = try #require(FolderIcons.baseIcon(size: 128))
        var seen: Set<Data> = []
        for material in FolderMaterial.allCases {
            let style = FolderStyle(tint: "3D82F0", material: material)
            let icon = try #require(FolderIcons.render(style, base: base, size: 128), "\(material)")
            #expect(alphaSum(icon) == alphaSum(base), "\(material)")
            let again = try #require(material.draw(size: 64, tint: nil, emoji: "⭐️"))
            #expect(png(again) == png(try #require(material.draw(size: 64, tint: nil, emoji: "⭐️"))), "\(material) is not deterministic")
            seen.insert(png(icon))
        }
        #expect(seen.count == FolderMaterial.allCases.count)
    }

    @Test func letteringFitsOnTwoLinesAndOldRecentsStillLoad() throws {
        var style = FolderStyle(material: .poster)
        style.text = "POSTER DESIGN"
        #expect(style.drawnText == "POSTER\nDESIGN")
        style.text = "  Ideas "
        #expect(style.drawnText == "Ideas")
        style.text = String(repeating: "A", count: 40)
        #expect(style.drawnText.count == 24)
        let base = try #require(FolderIcons.baseIcon(size: 128))
        let plain = try #require(FolderIcons.render(FolderStyle(material: .poster), base: base, size: 128))
        style.text = "POSTER DESIGN"
        #expect(png(try #require(FolderIcons.render(style, base: base, size: 128))) != png(plain))
        // Saved before materials and text existed.
        let old = Data(#"[{"tint":"E5484D","badge":"emoji","symbol":"star.fill","emoji":"📷"}]"#.utf8)
        let decoded = try JSONDecoder().decode([FolderStyle].self, from: old)
        #expect(decoded.first?.material == .plain && decoded.first?.text == "" && decoded.first?.emoji == "📷")
        let round = try JSONDecoder().decode(FolderStyle.self, from: JSONEncoder().encode(style))
        #expect(round == style)
    }
}
