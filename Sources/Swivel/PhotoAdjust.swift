import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

private let adjustContext = CIContext(options: [.useSoftwareRenderer: false])

/// Every slider of Edit Photo in one value. Zero is "no change" for all of them; exposure is in EV, the rest run
/// −1…1 (or 0…1 for the ones that only add something).
struct PhotoSettings: Equatable, Sendable {
    var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
    var saturation = 0.0, vibrance = 0.0, warmth = 0.0, tint = 0.0
    var clarity = 0.0, sharpen = 0.0, noise = 0.0, vignette = 0.0

    /// Each field with its range, in slider order; the editor builds its rows from this.
    static let fields: [(name: String, key: WritableKeyPath<PhotoSettings, Double>, range: ClosedRange<Double>)] = [
        ("Exposure", \.exposure, -2...2), ("Contrast", \.contrast, -1...1), ("Highlights", \.highlights, -1...1),
        ("Shadows", \.shadows, -1...1), ("Whites", \.whites, -1...1), ("Blacks", \.blacks, -1...1),
        ("Saturation", \.saturation, -1...1), ("Vibrance", \.vibrance, -1...1), ("Warmth", \.warmth, -1...1),
        ("Tint", \.tint, -1...1),
        ("Clarity", \.clarity, -1...1), ("Sharpen", \.sharpen, 0...1), ("Noise Reduction", \.noise, 0...1),
        ("Vignette", \.vignette, 0...1),
    ]

    var isNeutral: Bool { self == PhotoSettings() }

    /// These settings with `look` laid on top at `amount` (0…1), each field kept inside its range.
    func adding(_ look: PhotoSettings, amount: Double) -> PhotoSettings {
        var result = self
        for field in Self.fields {
            let value = self[keyPath: field.key] + look[keyPath: field.key] * amount
            result[keyPath: field.key] = min(max(value, field.range.lowerBound), field.range.upperBound)
        }
        return result
    }
}

/// A named starting point for Edit Photo. A look sits on top of the sliders with its own strength, so choosing one
/// never moves what the user set by hand.
struct PhotoLook: Sendable {
    let name: String
    let settings: PhotoSettings

    static let all: [PhotoLook] = [
        PhotoLook(name: "Original", settings: PhotoSettings()),
        PhotoLook(name: "Vivid", settings: PhotoSettings(contrast: 0.25, saturation: 0.1, vibrance: 0.45, clarity: 0.2)),
        PhotoLook(name: "Warm", settings: PhotoSettings(highlights: -0.15, vibrance: 0.1, warmth: 0.35)),
        PhotoLook(name: "Cool", settings: PhotoSettings(contrast: 0.1, vibrance: 0.05, warmth: -0.3, tint: -0.05)),
        PhotoLook(name: "Film", settings: PhotoSettings(contrast: 0.15, highlights: -0.35, blacks: 0.3,
                                                        saturation: -0.15, warmth: 0.15, vignette: 0.35)),
        PhotoLook(name: "Faded", settings: PhotoSettings(contrast: -0.2, shadows: 0.2, blacks: 0.5, saturation: -0.25,
                                                         warmth: 0.08)),
        PhotoLook(name: "B&W", settings: PhotoSettings(contrast: 0.15, saturation: -1)),
        PhotoLook(name: "Noir", settings: PhotoSettings(contrast: 0.6, blacks: -0.35, saturation: -1, clarity: 0.3,
                                                        vignette: 0.6)),
    ]
}

/// The Core Image chain behind Edit Photo. Pure, so it can be tested, and resolution-independent: radii follow the
/// image's size, so the small preview looks like the saved photo.
enum PhotoAdjust {
    static func render(_ image: CGImage, _ s: PhotoSettings) -> CGImage? {
        if s.isNeutral { return image }
        let input = CIImage(cgImage: image)
        let output = apply(s, to: input)
        return adjustContext.createCGImage(output, from: input.extent, format: .RGBA8,
                                           colorSpace: image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB))
    }

    static func apply(_ s: PhotoSettings, to input: CIImage) -> CIImage {
        let extent = input.extent
        let edge = max(extent.width, extent.height)
        // Edges are repeated outward, so blurs and local filters don't darken the borders.
        var ci = input.clampedToExtent()

        if s.noise > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = ci
            f.noiseLevel = Float(s.noise * 0.05)
            f.sharpness = Float(0.4 * (1 - s.noise))
            ci = f.outputImage ?? ci
        }
        if s.warmth != 0 || s.tint != 0 {
            // Telling Core Image the light was bluer than it was warms the picture; tint likewise toward magenta.
            let f = CIFilter.temperatureAndTint()
            f.inputImage = ci
            f.neutral = CIVector(x: 6500 + s.warmth * 2500, y: s.tint * 60)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            ci = f.outputImage ?? ci
        }
        if s.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = ci
            f.ev = Float(s.exposure)
            ci = f.outputImage ?? ci
        }
        // Shadows, and pulling highlights down, are local (they look at the neighbourhood, like Lightroom's);
        // brighter highlights, whites and blacks shape a global tone curve.
        if s.shadows != 0 || s.highlights < 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = ci
            f.radius = Float(edge * 0.004)
            f.shadowAmount = Float(s.shadows)
            f.highlightAmount = Float(1 + min(s.highlights, 0))
            ci = f.outputImage ?? ci
        }
        if s.highlights > 0 || s.whites != 0 || s.blacks != 0 {
            let f = CIFilter.toneCurve()
            f.inputImage = ci
            let points = toneCurve(highlights: s.highlights, whites: s.whites, blacks: s.blacks)
            f.point0 = points[0]; f.point1 = points[1]; f.point2 = points[2]; f.point3 = points[3]; f.point4 = points[4]
            ci = f.outputImage ?? ci
        }
        if s.contrast != 0 || s.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = ci
            f.contrast = Float(1 + s.contrast * 0.5)
            f.saturation = Float(1 + s.saturation)
            f.brightness = 0
            ci = f.outputImage ?? ci
        }
        if s.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = ci
            f.amount = Float(s.vibrance)
            ci = f.outputImage ?? ci
        }
        if s.clarity != 0 {
            // A wide, gentle unsharp mask is local contrast; a negative amount softens instead.
            let f = CIFilter.unsharpMask()
            f.inputImage = ci
            f.radius = Float(edge * 0.012)
            f.intensity = Float(s.clarity * 0.6)
            ci = f.outputImage ?? ci
        }
        if s.sharpen > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = ci
            f.sharpness = Float(s.sharpen * 2)
            ci = f.outputImage ?? ci
        }
        ci = ci.cropped(to: extent)
        if s.vignette > 0 {
            let f = CIFilter.vignette()
            f.inputImage = ci
            f.intensity = Float(s.vignette * 2)
            f.radius = 2
            ci = f.outputImage ?? ci
        }
        return ci.cropped(to: extent)
    }

    /// Five points, left to right. Positive blacks lift the black point (a faded look), negative ones crush it;
    /// positive whites clip earlier (brighter), negative ones lower the white point.
    static func toneCurve(highlights: Double, whites: Double, blacks: Double) -> [CGPoint] {
        let black = blacks >= 0 ? CGPoint(x: 0, y: blacks * 0.15) : CGPoint(x: -blacks * 0.12, y: 0)
        let white = whites >= 0 ? CGPoint(x: 1 - whites * 0.15, y: 1) : CGPoint(x: 1, y: 1 + whites * 0.15)
        return [black, CGPoint(x: 0.25, y: 0.25 + blacks * 0.03), CGPoint(x: 0.5, y: 0.5 + whites * 0.02),
                CGPoint(x: 0.75, y: 0.75 + max(highlights, 0) * 0.1 + whites * 0.03), white]
    }

    /// What Auto sets: Core Image's own analysis for highlights, shadows and vibrance, plus an exposure that brings
    /// the average brightness near the middle. Gentle on purpose; the sliders show what it did.
    static func auto(for image: CGImage) -> PhotoSettings {
        let ci = CIImage(cgImage: image)
        var s = PhotoSettings()
        for filter in ci.autoAdjustmentFilters(options: [.redEye: false]) {
            switch filter.name {
            case "CIHighlightShadowAdjust":
                if let h = (filter.value(forKey: "inputHighlightAmount") as? NSNumber)?.doubleValue { s.highlights = h - 1 }
                if let sh = (filter.value(forKey: "inputShadowAmount") as? NSNumber)?.doubleValue { s.shadows = sh }
            case "CIVibrance":
                if let v = (filter.value(forKey: "inputAmount") as? NSNumber)?.doubleValue { s.vibrance = v }
            default: break
            }
        }
        if let mean = meanBrightness(ci), mean > 0.01 {
            // In display (gamma) terms; 2.2 turns the ratio into stops.
            let stops = 2.2 * log2(0.46 / mean) * 0.6
            if abs(stops) > 0.1 { s.exposure = min(max(stops, -1), 1) }
        }
        for field in PhotoSettings.fields {
            let value = (s[keyPath: field.key] * 100).rounded() / 100
            s[keyPath: field.key] = min(max(value, field.range.lowerBound), field.range.upperBound)
        }
        return s
    }

    private static func meanBrightness(_ image: CIImage) -> Double? {
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = image.extent
        guard let output = f.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        adjustContext.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }
}

/// Background blur: the subject stays sharp, everything behind it is blurred.
enum BackgroundBlur {
    /// The subject mask (white = subject) at the image's own size, or nil when Vision finds no subject.
    static func subjectMask(_ image: CGImage) throws -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        // A one-channel buffer: copy it into grey, opaque, so every mask filter reads the same value.
        let red = CIVector(x: 1, y: 0, z: 0, w: 0)
        let raw = CIImage(cvPixelBuffer: buffer)
        // The alpha bias makes the result endless (it's opaque outside too), so it's cropped back.
        let mask = raw.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": red, "inputGVector": red, "inputBVector": red,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: raw.extent)
        guard let image = adjustContext.createCGImage(mask, from: raw.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            throw ToolError(L("Couldn't encode image"))
        }
        return image
    }

    /// `amount` 0…1. The background is blurred without the subject in it (a normalised blur of the background
    /// alone), so no halo of the subject's colours spreads around its edge.
    static func render(_ image: CGImage, mask: CGImage, amount: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        guard amount > 0 else { return image }
        let edge = max(extent.width, extent.height)
        let radius = amount * edge * 0.025
        // The mask arrives at the image's size; scale it if it doesn't (and soften its edge a little).
        // Values, not colours: the mask isn't colour-managed.
        var subject = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
        if subject.extent.size != extent.size {
            subject = subject.transformed(by: CGAffineTransform(scaleX: extent.width / subject.extent.width,
                                                                y: extent.height / subject.extent.height))
        }
        subject = subject.clampedToExtent().applyingGaussianBlur(sigma: max(1, edge * 0.0015)).cropped(to: extent)

        // A normalised blur of the background alone: blur(photo × weight) ÷ blur(weight), with weight = 1 − mask.
        // Each pixel beside the subject then averages only background colours. Everything stays opaque, so no
        // filter's own premultiplying gets in the way.
        // The weight comes from the hard mask grown by a few pixels, so the subject's soft edge (kept for the
        // final blend) doesn't leak its colour into the background either.
        let grown = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(mask.width), y: extent.height / CGFloat(mask.height)))
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(2, edge * 0.004)])
            .cropped(to: extent)
        let weight = grown.applyingFilter("CIColorInvert")
        let blur = { (image: CIImage) in image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent) }
        let weightedBlur = blur(input.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight]))
        let weightBlur = blur(weight)
        let normalised = weightedBlur.applyingFilter("CIDivideBlendMode", parameters: [
            kCIInputImageKey: weightBlur.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0.02, y: 0.02, z: 0.02, w: 1),
            ]),
            kCIInputBackgroundImageKey: weightedBlur,
        ])
        // Where the subject covers nearly everything nearby there's too little background to divide by; the
        // ordinary blur of the whole photo fills in there.
        let trust = weightBlur.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 20, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 20, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 20, w: 0),
        ]).applyingFilter("CIColorClamp")
        let plain = blur(input)
        let filled = normalised.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: plain, kCIInputMaskImageKey: trust,
        ])
        let output = input.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: filled,
            kCIInputMaskImageKey: subject,
        ]).cropped(to: extent)
        return adjustContext.createCGImage(output, from: extent, format: .RGBA8,
                                           colorSpace: image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB))
    }
}
