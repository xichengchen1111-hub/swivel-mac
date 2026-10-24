import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Swivel

@Suite(.serialized)
@MainActor
struct ClipboardTests {
    /// A copied print is one clipboard item (pasting it into a chat app sends one attachment, not the file plus a
    /// TIFF), carrying the file and the picture. Uses a private pasteboard, never the user's clipboard.
    @Test func copiedPrintsAreOneItemWithTheFileAndThePicture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-clipboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try #require(ctx.makeImage())
        let pasteboard = NSPasteboard(name: .init("swivel-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        for (name, type) in [("Shot.png", UTType.png), ("Photo.jpg", .jpeg)] {
            let url = dir.appendingPathComponent(name)
            try Images.encode(image, type: type, quality: 0.9).write(to: url)
            pasteboard.clearContents()
            #expect(pasteboard.writeObjects([Clothesline.pasteboardItem(for: url)]))
            let items = try #require(pasteboard.pasteboardItems)
            #expect(items.count == 1, "\(name)")
            #expect(items[0].string(forType: .fileURL).flatMap(URL.init(string:))?.path == url.path)
            #expect(items[0].data(forType: NSPasteboard.PasteboardType(type.identifier)) == (try Data(contentsOf: url)))
            #expect(!items[0].types.contains(.tiff), "\(name) shouldn't carry a TIFF")
            // Apps that ask for PNG get one (the JPEG's is made on request).
            let png = try #require(items[0].data(forType: .png), "\(name)")
            #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }
    }

    /// A print that is a link (say, extracted from an archive) or not really an image puts only its reference on the
    /// clipboard, never the bytes read through the link.
    @Test func linkedOrFakePrintsCopyNoBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swivel-clipboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let secret = dir.appendingPathComponent("secret.txt")
        try Data("PRIVATE KEY".utf8).write(to: secret)
        let link = dir.appendingPathComponent("cute.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let fake = dir.appendingPathComponent("fake.png")
        try Data("PRIVATE KEY".utf8).write(to: fake)
        for url in [link, fake] {
            let item = Clothesline.pasteboardItem(for: url)
            #expect(item.types == [.fileURL], "\(url.lastPathComponent)")
        }
    }

    /// Another app can put anything on the clipboard: an image too big to decode on the main thread isn't hung,
    /// read from its header before decoding; secrets copied from a QR code carry the concealed marker.
    @Test func hugeCopiedImagesAreLeftAloneAndSecretsAreConcealed() throws {
        func png(_ width: Int, _ height: Int) throws -> Data {
            let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(ctx.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents(); pasteboard.setData(try png(9000, 8000), forType: .png)
        #expect(!Clothesline.isSmallEnough(pasteboard, types: pasteboard.types ?? []))
        pasteboard.clearContents(); pasteboard.setData(try png(3000, 2000), forType: .png)
        #expect(Clothesline.isSmallEnough(pasteboard, types: pasteboard.types ?? []))
        pasteboard.clearContents(); pasteboard.setData(Data("not an image".utf8), forType: .init("public.data"))
        #expect(!Clothesline.isSmallEnough(pasteboard, types: pasteboard.types ?? []))
        #expect(DetectedCode.isSecret("WIFI:T:WPA;S:home;P:secret;;") && DetectedCode.isSecret("otpauth://totp/x?secret=A"))
        #expect(!DetectedCode.isSecret("https://example.com"))
    }
}
