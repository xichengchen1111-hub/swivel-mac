import Foundation

/// Data resources for the approved, pinned Real-ESRGAN x4plus model.
public enum UpscaleModelAssets {
    public static var packageURL: URL? {
        packageURL(in: .main)
    }

    public static func packageURL(in application: Bundle) -> URL? {
        if let resources = application.resourceURL {
            let bundleURL = resources.appendingPathComponent("Swivel_UpscaleModel.bundle", isDirectory: true)
            if let bundle = Bundle(url: bundleURL),
               let model = bundle.url(forResource: "RealESRGAN", withExtension: "mlpackage") {
                // Bundle can retain a stale resource URL after an update/removal. The runtime still
                // verifies all model bytes, but a missing package must not trigger a developer fallback.
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: model.path, isDirectory: &directory), directory.boolValue { return model }
            }
        }
        // An installed app must never fall back to a build-machine source path.
        if application.bundleURL.pathExtension == "app" { return nil }
        return Bundle.module.url(forResource: "RealESRGAN", withExtension: "mlpackage")
    }

    /// A closed file set, verified by Swivel before compiling or loading.
    public static let expectedFiles: [String: String] = [
        "Data/com.apple.CoreML/model.mlmodel": "b4b692e2faa4d7608b4bcac2f5ac5f0a506bd9956675a24d852e9d7e038b59e8",
        "Data/com.apple.CoreML/weights/weight.bin": "e1a6e725cbcde351873697efbdd3e6d228c9c6c193bc441a3a6c527c8e078d5f",
        "Manifest.json": "83e4c35c8a1f5038309cd9f57722f5e9eb6c7aecf6dcbed1196998c1b08bff85",
    ]
}
