// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let nativeLib = root + "/.build/native"

let package = Package(
    name: "SpektraFilmStudio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SpektraFilmStudio", targets: ["SpektraFilmStudio"])
    ],
    targets: [
        .systemLibrary(
            name: "CSpektraBridge",
            path: "Sources/CSpektraBridge"
        ),
        .target(
            name: "SemanticMaskNative",
            path: "Sources/SemanticMaskNative",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-I\(root)/Vendor/onnxruntime/include"])],
            linkerSettings: [.unsafeFlags(["-L\(root)/Vendor/onnxruntime/lib", "-lonnxruntime"])]
        ),
        .executableTarget(
            name: "SpektraFilmStudio",
            dependencies: ["CSpektraBridge", "SemanticMaskNative"],
            path: "Sources/SpektraFilmFast",
            linkerSettings: [
                .unsafeFlags(["-L\(nativeLib)", "-lSpektraFilmNativeCore"]),
                .unsafeFlags(["-L\(root)/Vendor/onnxruntime/lib", "-lonnxruntime", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
