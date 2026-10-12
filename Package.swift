// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let nativeLib = root + "/.build/native"
let studioCoreLib = root + "/.build/spektrastudio-core/x86_64-apple-darwin/release"

let package = Package(
    name: "SpektraFilmStudio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SpektraFilmStudio", targets: ["SpektraFilmStudio"])
    ],
    targets: [
        .systemLibrary(
            name: "CSpectraBridge",
            path: "Sources/CSpektraBridge"
        ),
        .systemLibrary(
            name: "CSpektraStudioCore",
            path: "Sources/CSpektraStudioCore"
        ),
        .target(
            name: "RawSpeedBridge",
            path: "Sources/RawSpeedBridge",
            publicHeadersPath: ".",
            cxxSettings: [
                .unsafeFlags(["-I/opt/homebrew/include", "-I/usr/local/include"]),
                .unsafeFlags(["-ULIBRAW_USE_OPENMP"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib"]),
                .linkedLibrary("raw"),
                .linkedLibrary("lcms2"),
                .linkedLibrary("c++"),
            ]
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
            dependencies: ["CSpectraBridge", "CSpektraStudioCore", "RawSpeedBridge", "SemanticMaskNative"],
            path: "Sources/SpektraFilmFast",
            linkerSettings: [
                .unsafeFlags(["-L\(nativeLib)", "-lSpektraFilmNativeCore"]),
                .unsafeFlags(["-L\(studioCoreLib)", "-lspektrastudio_core"]),
                .unsafeFlags(["-L\(root)/Vendor/onnxruntime/lib", "-lonnxruntime", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedLibrary("c++"),
                .linkedLibrary("sqlite3"),
                .linkedLibrary("raw"),
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
        ),
        .testTarget(
            name: "SpektraFilmStudioTests",
            dependencies: ["SpektraFilmStudio", "RawSpeedBridge", "CSpectraBridge"],
            cSettings: [
                .unsafeFlags(["-ISources/CSpectraBridge/include"])
            ],
            linkerSettings: [
                .unsafeFlags(["-L/usr/local/lib", "-lraw"]),
                .linkedLibrary("raw"),
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