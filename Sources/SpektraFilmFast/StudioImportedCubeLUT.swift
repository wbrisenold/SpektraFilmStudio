import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// One LUT engine, two legacy user-facing selectors.  GPU rendering, sidecar
// parsing, tetrahedral interpolation, and cache identity are all owned by
// StudioImportedLUTMetal. This wrapper supplies folder/file selection and
// explicit color contracts; it does NOT compile a duplicate Metal shader.
enum StudioImportedCubeLUTSettings {
    static let folderKey = "SpektraFilmStudio.importedLUT.folder.v1"
    static let fileKey = "SpektraFilmStudio.importedLUT.file.v1"
    static let inputKey = "SpektraFilmStudio.importedLUT.input.v2"
    static let outputKey = "SpektraFilmStudio.importedLUT.output.v2"

    static var isSelected: Bool {
        UserDefaults.standard.string(forKey: StudioSpectralLUT.setting) == "imported-cube"
    }
    static var selectedURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: fileKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // The .cube format does not declare its color space or shaper. A validated
    // .cube.lut.json sidecar is authoritative. With no sidecar, the older
    // imported library safely assumes an encoded-sRGB input/output. If the
    // user explicitly chooses another input/output, pass that exact contract
    // to the SAME Metal kernel instead of implementing color science twice.
    static func explicitContract(for url: URL) throws -> StudioImportedLUT.Contract? {
        let sidecar = URL(fileURLWithPath: url.path + ".lut.json")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            return nil  // The shared importer validates and applies the sidecar.
        }
        let input = UserDefaults.standard.string(forKey: inputKey) ?? "auto"
        let output = UserDefaults.standard.string(forKey: outputKey) ?? "auto"
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let saysSRGB = name.contains("in-srgb") || name.contains("in-s-rgb")
        let saysLinear =
            name.contains("in-rec2020") || name.contains("in-linear") || name.contains("in-scene")
            || name.contains("in-rec-2020")
        if input == "auto" && output == "auto" {
            if saysLinear {
                throw GPULiveError.unavailable(
                    "This LUT filename indicates scene-linear input, but its .cube.lut.json contract is missing. Select explicit LUT input/output in Settings or generate the contract sidecar."
                )
            }
            // Untagged legacy LUTs are sRGB -> sRGB; the visible UI makes
            // that assumption explicit. This also handles filenames IN-sRGB.
            return nil
        }
        guard input != "auto", output != "auto" else {
            throw GPULiveError.unavailable("Set BOTH LUT input and output, or leave BOTH on Automatic")
        }
        if saysSRGB && input != "display-srgb" {
            throw GPULiveError.unavailable(
                "Selected LUT is labeled IN-sRGB, but your LUT input is not Display sRGB. Set input to Display sRGB (or both to Automatic)."
            )
        }
        if saysLinear && input == "display-srgb" {
            throw GPULiveError.unavailable(
                "Selected LUT is labeled scene-linear, but your LUT input is Display sRGB. Set its matching Rec.2020 input/shaper."
            )
        }
        let space: StudioImportedLUT.InputSpace
        let shaper: StudioImportedLUT.Shaper
        switch input {
        case "display-srgb": space = .encodedSRGB; shaper = .encodedSRGB
        case "signed-log-rec2020": space = .linearRec2020; shaper = .signedLog2
        case "linear-rec2020": space = .linearRec2020; shaper = .domainLinear
        default: throw GPULiveError.unavailable("Unknown LUT input contract: \(input)")
        }
        let outSpace: StudioImportedLUT.OutputSpace
        switch output {
        case "display-srgb": outSpace = .encodedSRGB
        case "linear-rec2020": outSpace = .linearRec2020
        default: throw GPULiveError.unavailable("Unknown LUT output contract: \(output)")
        }
        let contract = StudioImportedLUT.Contract(
            version: 1, input: space,
            output: outSpace, shaper: shaper, role: .fullFilmPrint)
        try contract.validate()
        return contract
    }

    static func files(in directory: URL) -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var urls: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "cube" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                urls.append(url)
            }
        }
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// Settings view lives inline in SettingsView.swift (no separate file needed).
