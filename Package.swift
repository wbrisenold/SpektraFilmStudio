// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let nativeLib = root + "/.build/native"

let package = Package(
    name: "SpektraFilmFast",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SpektraFilmFast", targets: ["SpektraFilmFast"])
    ],
    targets: [
        .systemLibrary(
            name: "CSpektraBridge",
            path: "Sources/CSpektraBridge"
        ),
        .executableTarget(
            name: "SpektraFilmFast",
            dependencies: ["CSpektraBridge"],
            path: "Sources/SpektraFilmFast",
            linkerSettings: [
                .unsafeFlags(["-L\(nativeLib)", "-lSpektraFilmNativeCore"]),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("Network"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Vision"),
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
