import Foundation

struct LightroomDevelopMappingResult: Sendable {
    var look: RenderLook
    var mappedKeys: Int
    var unmappedKeys: Set<String>
}

/// Best-effort Lightroom Classic/XMP develop translation.
///
/// SpektraFilm preserves the original Lightroom develop payload separately during migration.
/// This mapper only translates controls that have a defensible SpektraFilm analogue.
/// It does not claim pixel parity with Adobe's process version.
enum LightroomDevelopMapper {
    static func map(
        catalogText: String?,
        sidecarURL: URL?,
        base: RenderLook = .defaults()
    ) -> LightroomDevelopMappingResult {
        var look = base
        var values: [String: String] = [:]

        if let catalogText, !catalogText.isEmpty {
            values.merge(parseKeyValues(catalogText)) { _, newer in newer }
        }
        if let sidecarURL,
           let data = try? Data(contentsOf: sidecarURL, options: .mappedIfSafe),
           let text = String(data: data, encoding: .utf8) {
            values.merge(parseKeyValues(text)) { _, newer in newer }
        }

        var mapped = Set<String>()

        func number(_ names: String...) -> Double? {
            for name in names {
                guard let raw = values[name] else { continue }
                let cleaned = raw
                    .replacingOccurrences(of: "+", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Double(cleaned) {
                    mapped.insert(name)
                    return value
                }
            }
            return nil
        }

        func string(_ names: String...) -> String? {
            for name in names {
                if let value = values[name], !value.isEmpty {
                    mapped.insert(name)
                    return value
                }
            }
            return nil
        }

        // Lightroom PV2012 exposure maps to the existing Apple RAW exposure path.
        if let exposure = number("Exposure2012", "Exposure") {
            look.raw.developExposureEV = min(5, max(-5, exposure))
        }

        var tone = look.tone ?? ToneSettings()
        if let contrast = number("Contrast2012", "Contrast") {
            tone.contrast = min(100, max(-100, contrast))
        }
        if let highlights = number("Highlights2012") {
            tone.highlights = min(100, max(-100, highlights))
        } else if let legacyRecovery = number("HighlightRecovery") {
            tone.highlightRecovery = min(100, max(0, legacyRecovery))
        }
        if let shadows = number("Shadows2012") {
            tone.shadows = min(100, max(-100, shadows))
        } else if let fill = number("FillLight") {
            tone.shadows = min(100, max(-100, fill))
        }
        if let whites = number("Whites2012") {
            tone.whites = min(100, max(-100, whites))
        }
        if let blacks = number("Blacks2012", "Blacks") {
            tone.blacks = min(100, max(-100, blacks))
        }
        if let brightness = number("Brightness") {
            tone.brightness = min(100, max(-100, brightness))
        }
        look.tone = tone

        if let temperature = number("Temperature"), temperature >= 1800, temperature <= 50000 {
            look.raw.whiteBalanceMode = .custom
            look.raw.temperature = temperature
            look.raw.temperatureOffsetMired = nil
        }
        if let tint = number("Tint") {
            look.raw.whiteBalanceMode = .custom
            look.raw.tint = min(150, max(-150, tint))
            look.raw.tintOffset = nil
        }
        if let wb = string("WhiteBalance") {
            switch wb.lowercased() {
            case "asshot", "as shot":
                look.raw.whiteBalanceMode = .asShot
            case "auto":
                look.raw.whiteBalanceMode = .auto
            default:
                if values["Temperature"] != nil || values["Tint"] != nil {
                    look.raw.whiteBalanceMode = .custom
                }
            }
        }

        // Lightroom crop coordinates are normalized on the upright image.
        var geometry = look.geometry ?? GeometrySettings()
        if let left = number("CropLeft"),
           let top = number("CropTop"),
           let right = number("CropRight"),
           let bottom = number("CropBottom"),
           right > left, bottom > top {
            geometry.crop = NormalizedCropRect(
                x: min(1, max(0, left)),
                y: min(1, max(0, top)),
                width: min(1, max(0.0001, right - left)),
                height: min(1, max(0.0001, bottom - top))
            )
            geometry.autoCrop = false
        }
        if let angle = number("CropAngle", "StraightenAngle") {
            geometry.rotationDegrees = min(45, max(-45, angle))
        }
        look.geometry = geometry

        if let flipH = number("HasSettings") {
            // Consumed only to avoid classifying this common bookkeeping key as unmapped.
            _ = flipH
        }

        // Preserve the original payload during migration; this list is only for the migration report.
        let interestingPrefixes = [
            "Exposure", "Contrast", "Highlights", "Shadows", "Whites", "Blacks",
            "Brightness", "FillLight", "HighlightRecovery", "Temperature", "Tint",
            "WhiteBalance", "Crop", "Straighten", "Clarity", "Texture", "Dehaze",
            "Saturation", "Vibrance", "ToneCurve", "HueAdjustment", "SaturationAdjustment",
            "LuminanceAdjustment", "Sharpness", "LuminanceSmoothing", "ColorNoiseReduction",
            "LensProfile", "Perspective", "Upright", "Grain", "PostCropVignette",
            "ProcessVersion"
        ]
        let interesting = Set(values.keys.filter { key in
            interestingPrefixes.contains { key.hasPrefix($0) }
        })
        let unmapped = interesting.subtracting(mapped)

        return LightroomDevelopMappingResult(
            look: look,
            mappedKeys: mapped.count,
            unmappedKeys: unmapped
        )
    }

    private static func parseKeyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]

        // XMP attribute form: crs:Exposure2012="+0.75"
        let xmpPattern = #"(?:crs:)?([A-Za-z][A-Za-z0-9_]+)\s*=\s*["']([^"']*)["']"#
        extract(pattern: xmpPattern, from: text) { key, value in
            result[key] = decodeXML(value)
        }

        // Lightroom/Lua-ish table form: Exposure2012 = 0.75 or ["Exposure2012"] = 0.75
        let luaPattern = #"(?:\[\s*["']([A-Za-z][A-Za-z0-9_]+)["']\s*\]|([A-Za-z][A-Za-z0-9_]+))\s*=\s*(?:["']([^"']*)["']|([+\-]?(?:\d+(?:\.\d*)?|\.\d+)))"#
        guard let regex = try? NSRegularExpression(pattern: luaPattern) else { return result }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: text, range: range) {
            let keyRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let valueRange = match.range(at: 3).location != NSNotFound ? match.range(at: 3) : match.range(at: 4)
            guard keyRange.location != NSNotFound, valueRange.location != NSNotFound else { continue }
            result[ns.substring(with: keyRange)] = ns.substring(with: valueRange)
        }

        // XML element form occasionally used by sidecars.
        let elementPattern = #"<crs:([A-Za-z][A-Za-z0-9_]+)>([^<]*)</crs:\1>"#
        extract(pattern: elementPattern, from: text) { key, value in
            result[key] = decodeXML(value)
        }

        return result
    }

    private static func extract(
        pattern: String,
        from text: String,
        body: (String, String) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: text, range: range) where match.numberOfRanges >= 3 {
            let a = match.range(at: 1)
            let b = match.range(at: 2)
            guard a.location != NSNotFound, b.location != NSNotFound else { continue }
            body(ns.substring(with: a), ns.substring(with: b))
        }
    }

    private static func decodeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
