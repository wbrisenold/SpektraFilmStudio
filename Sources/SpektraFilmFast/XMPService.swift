import Foundation

struct XMPSidecarState: Sendable {
    var rating: Int?
    var flag: ProjectFlag?
    var colorLabel: PhotoColorLabel?
}

/// Minimal Lightroom-friendly XMP interoperability for culling metadata.
///
/// Ratings and color labels use standard XMP fields. Reject maps to xmp:Rating=-1,
/// while Pick/Unflagged are additionally preserved in the SpektraFilm namespace because
/// Adobe's pick flag is catalog state rather than a portable XMP field.
actor XMPService {
    static let shared = XMPService()

    func read(for sourceURL: URL) -> XMPSidecarState? {
        let url = sidecarURL(for: sourceURL)
        guard let data = try? Data(contentsOf: url),
              let xml = String(data: data, encoding: .utf8) else { return nil }

        let rawRating = firstValue(in: xml, patterns: [
            #"xmp:Rating\s*=\s*\"(-?\d+)\""#,
            #"<xmp:Rating>\s*(-?\d+)\s*</xmp:Rating>"#
        ]).flatMap(Int.init)

        let labelString = firstValue(in: xml, patterns: [
            #"xmp:Label\s*=\s*\"([^\"]*)\""#,
            #"<xmp:Label>\s*([^<]*)\s*</xmp:Label>"#
        ])
        let color = labelString.flatMap { value in
            PhotoColorLabel.allCases.first { $0.rawValue.caseInsensitiveCompare(value) == .orderedSame }
        }

        let customFlag = firstValue(in: xml, patterns: [
            #"sf:Flag\s*=\s*\"([^\"]*)\""#,
            #"<sf:Flag>\s*([^<]*)\s*</sf:Flag>"#
        ]).flatMap(ProjectFlag.init(rawValue:))

        let flag: ProjectFlag?
        if rawRating == -1 { flag = .rejected }
        else { flag = customFlag }
        let rating = rawRating.map { max(0, min(5, $0)) }
        return XMPSidecarState(rating: rating, flag: flag, colorLabel: color)
    }

    func write(image: ProjectImageRecord) throws {
        let url = sidecarURL(for: image.url)
        let rating = image.flag == .rejected ? -1 : max(0, min(5, image.rating))
        let label = image.colorLabel?.rawValue ?? ""
        let flag = image.flag.rawValue

        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing.contains("<rdf:Description") {
            let updated = merge(existing: existing, rating: rating, label: label, flag: flag)
            try updated.data(using: .utf8)?.write(to: url, options: .atomic)
            return
        }

        let xml = """
        <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:sf="https://spektrafilm.local/ns/1.0/"
              xmp:Rating="\(rating)"
              xmp:Label="\(escape(label))"
              sf:Flag="\(escape(flag))"/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        guard let data = xml.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        try data.write(to: url, options: .atomic)
    }

    func write(images: [ProjectImageRecord]) -> [(URL, Error)] {
        var failures: [(URL, Error)] = []
        for image in images {
            do { try write(image: image) }
            catch { failures.append((image.url, error)) }
        }
        return failures
    }

    private func sidecarURL(for sourceURL: URL) -> URL {
        sourceURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    private func merge(existing: String, rating: Int, label: String, flag: String) -> String {
        var xml = existing
        xml = replaceAttribute(in: xml, name: "xmp:Rating", value: String(rating))
        xml = replaceAttribute(in: xml, name: "xmp:Label", value: label)
        xml = replaceAttribute(in: xml, name: "sf:Flag", value: flag)
        if !xml.contains("xmlns:sf=") {
            xml = insertAttribute(in: xml, name: "xmlns:sf", value: "https://spektrafilm.local/ns/1.0/")
        }
        return xml
    }

    private func replaceAttribute(in xml: String, name: String, value: String) -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escapedName)\\s*=\\s*\\\"[^\\\"]*\\\"") else { return xml }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        if regex.firstMatch(in: xml, range: range) != nil {
            return regex.stringByReplacingMatches(in: xml, range: range, withTemplate: "\(name)=\"\(escape(value))\"")
        }
        return insertAttribute(in: xml, name: name, value: value)
    }

    private func insertAttribute(in xml: String, name: String, value: String) -> String {
        guard let marker = xml.range(of: "<rdf:Description") else { return xml }
        let insertion = " \(name)=\"\(escape(value))\""
        var result = xml
        result.insert(contentsOf: insertion, at: marker.upperBound)
        return result
    }

    private func firstValue(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: text) else { continue }
            return String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
