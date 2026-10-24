import Foundation
import Vision
import CoreImage

/// Local foreground extraction. The canvas and its orientation are preserved.
enum Cutout {
    static func maskedImage(_ image: CGImage) throws -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances,
                                                          from: handler, croppedToInstancesExtent: false)
        let result = CIImage(cvPixelBuffer: buffer)
        guard let output = CIContext().createCGImage(result, from: result.extent) else {
            throw ToolError(L("Couldn't encode image"))
        }
        return output
    }

    static func removeBackground(_ url: URL) async throws -> [URL] {
        try await Images.detached {
            guard let image = try maskedImage(Images.load(url)) else {
                throw ToolError(L("No subject found in this image."))
            }
            return [try Images.save(image, as: Paths.preferred(for: url, ext: "png", suffix: " cutout"), type: .png, quality: 1)]
        }
    }
}
