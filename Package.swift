// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Swivel",
    platforms: [.macOS(.v15)],
    targets: [
        // Vendored MIT data for Mac Doctor only; see ThirdParty/ClearDisk/UPSTREAM.md.
        .target(name: "DoctorCatalog", path: "ThirdParty/ClearDisk", exclude: ["LICENSE", "UPSTREAM.md"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        // Owner-approved model data only. Conversion tools and their dependencies are never part of the app.
        .target(name: "UpscaleModel", path: "ThirdParty/RealESRGAN",
                exclude: ["LICENSE", "LICENSE-BasicSR.txt", "NOTICE", "UPSTREAM.md", "convert.py", "rrdbnet.py",
                          "verify_conversion.py", "verify_tiling.py", "requirements-conversion.txt", "requirements-conversion-lock.txt"],
                sources: ["ModelResources.swift"], resources: [.copy("RealESRGAN.mlpackage")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Swivel", dependencies: ["DoctorCatalog", "UpscaleModel"], path: "Sources/Swivel",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SwivelTests", dependencies: ["Swivel", "DoctorCatalog", "UpscaleModel"], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
