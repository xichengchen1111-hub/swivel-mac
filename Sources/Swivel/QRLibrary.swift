import AppKit
import CoreImage
import ImageIO

enum QRSeason: String, Codable, CaseIterable, Sendable {
    case spring, summer, autumn
    var title: String { switch self { case .spring: L("Spring"); case .summer: L("Summer"); case .autumn: L("Autumn") } }
}

struct SavedQRCode: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var value: String
    var collection: String = ""
    var season: QRSeason = .summer
    var template: QRTemplate = .tree
    var created: Date = Date()
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120 &&
        !value.isEmpty && value.utf8.count <= 2000 && collection.count <= 80
    }
}

extension SavedQRCode {
    /// Libraries saved before templates existed (or by a later version with new ones) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        value = try c.decode(String.self, forKey: .value)
        collection = try c.decodeIfPresent(String.self, forKey: .collection) ?? ""
        season = (try? c.decodeIfPresent(QRSeason.self, forKey: .season)) ?? .summer
        template = (try? c.decodeIfPresent(QRTemplate.self, forKey: .template)) ?? .tree
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
}

enum QRImage {
    static func raw(_ value: String) throws -> CIImage {
        guard !value.isEmpty, value.utf8.count <= 2000, let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw ToolError(L("Enter up to 2,000 bytes of QR content."))
        }
        filter.setValue(Data(value.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw ToolError(L("This content is too long for a QR code.")) }
        return image
    }
    /// Integer scaling and a four-module white quiet zone keep the exported QR reliably scannable.
    static func cgImage(_ value: String, scale: Int = 8) throws -> CGImage {
        let code = try raw(value)
        let extent = code.extent.insetBy(dx: -4, dy: -4)
        let padded = code.composited(over: CIImage(color: .white).cropped(to: extent))
        let image = padded.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let cg = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(image, from: image.extent) else {
            throw ToolError(L("Could not generate the QR image."))
        }
        return cg
    }
    static func png(_ value: String) throws -> Data {
        let buffer = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else { throw ToolError(L("Could not generate the QR image.")) }
        CGImageDestinationAddImage(dest, try cgImage(value), nil)
        guard CGImageDestinationFinalize(dest) else { throw ToolError(L("Could not generate the QR image.")) }
        return buffer as Data
    }
}

/// Only explicitly saved content is retained. Originals are not needed after a QR is imported.
final class QRLibraryStore {
    static let changed = Notification.Name("SwivelQRLibraryChanged")
    /// Set only by the isolated --tool preview entry point; never changes production preferences.
    static var previewDirectory: URL?
    let file: URL
    init(directory: URL? = nil) {
        let root = directory ?? Self.previewDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swivel", isDirectory: true).appendingPathComponent("QRCodes", isDirectory: true)
        file = root.appendingPathComponent("library-v1.json")
    }
    func load() throws -> [SavedQRCode] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let values = try JSONDecoder().decode([SavedQRCode].self, from: Data(contentsOf: file))
        guard values.allSatisfy(\.isValid), Set(values.map(\.id)).count == values.count else { throw ToolError(L("The QR library could not be read. Its saved data was kept.")) }
        return values
    }
    func save(_ values: [SavedQRCode]) throws {
        guard values.allSatisfy(\.isValid), Set(values.map(\.id)).count == values.count else { throw ToolError(L("Check the code name and content.")) }
        let data = try JSONEncoder().encode(values)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        NotificationCenter.default.post(name: Self.changed, object: file)
    }
    @discardableResult func add(_ value: SavedQRCode) throws -> SavedQRCode {
        var values = try load()
        if let existing = values.first(where: { $0.value == value.value && $0.collection == value.collection }) { return existing }
        values.insert(value, at: 0); try save(values); return value
    }
    /// Undo only this window's changes. Files saved or edited by another library window remain intact.
    func revert(before: [SavedQRCode], after: [SavedQRCode]) throws {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        let affected = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        var current = try load()
        for id in affected {
            guard current.first(where: { $0.id == id }) == new[id] else {
                throw ToolError(L("This code changed in another window. Refresh before undoing."))
            }
        }
        current.removeAll { affected.contains($0.id) }
        current += before.filter { affected.contains($0.id) }
        try save(current.sorted { $0.created > $1.created })
    }
}
