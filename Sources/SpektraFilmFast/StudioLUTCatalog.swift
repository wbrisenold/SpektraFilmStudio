import Foundation

// GPL-3.0. External LUT Matrix catalogs are display metadata only.
// Their text is never evaluated or used to change a LUT's color-space contract.
// File identity remains its validated path within the user-selected library.
enum StudioLUTCatalog {
    struct Label: Equatable {
        let name: String
        let film: String
        let paper: String
        let stage: String
    }

    static func metadata(for root: URL, relativeLUTs: [String]) -> [String: Label] {
        let paths = Set(relativeLUTs)
        let byFilename = Dictionary(grouping: relativeLUTs, by: { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
        let fm = FileManager.default
        let base = root.standardizedFileURL
        guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                    options: [.skipsHiddenFiles], errorHandler: nil) else { return [:] }
        var catalogs: [URL] = []
        for case let url as URL in e {
            guard url.lastPathComponent.lowercased() == "lut_catalog.csv",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            catalogs.append(url)
            if catalogs.count >= 32 { break }
        }
        catalogs.sort { $0.path < $1.path }
        var output: [String: Label] = [:]
        for csv in catalogs {
            guard let props = try? csv.resourceValues(forKeys: [.fileSizeKey]),
                  let size = props.fileSize, size > 0, size <= 20_000_000,
                  let content = try? String(contentsOf: csv, encoding: .utf8) else { continue }
            let table = parseCSV(content)
            guard let headers = table.first, table.count > 1 else { continue }
            let h = headers.map(normalizeHeader)
            for row in table.dropFirst() where row.count > 1 {
                func field(_ aliases: [String]) -> String {
                    for alias in aliases {
                        if let index = h.firstIndex(of: normalizeHeader(alias)), index < row.count {
                            let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                            if !value.isEmpty { return String(value.prefix(512)) }
                        }
                    }
                    return ""
                }
                let status = field(["status", "result", "state"]).lowercased()
                if ["failed", "error", "skipped", "pending"].contains(status) { continue }
                let rawPath = field(["relative_path", "lut_path", "file_path", "output_path", "output_file", "lut_file", "filename", "file", "path", "cube_path", "bundle_path"])
                guard !rawPath.isEmpty else { continue }
                let relative = rawPath.replacingOccurrences(of: "\\", with: "/")
                // Catalog data is descriptive, never a trusted filesystem instruction.
                // Do not relabel a valid LUT using an out-of-tree CSV path.
                if relative.hasPrefix("/") || relative.split(separator: "/").contains("..") ||
                   relative.lowercased().hasPrefix("file:") { continue }
                let candidates = [base.appendingPathComponent(relative), csv.deletingLastPathComponent().appendingPathComponent(relative)]
                var matched: String?
                for candidate in candidates {
                    let resolved = candidate.standardizedFileURL
                    guard resolved.path.hasPrefix(base.path + "/") else { continue }
                    let path = String(resolved.path.dropFirst(base.path.count + 1))
                    if paths.contains(path) { matched = path; break }
                }
                if matched == nil {
                    let filename = URL(fileURLWithPath: relative).lastPathComponent.lowercased()
                    if let matches = byFilename[filename], matches.count == 1 { matched = matches[0] }
                }
                guard let path = matched, output[path] == nil else { continue }
                let film = beautify(field(["film_name", "film_display_name", "film_stock", "film_profile", "negative_profile", "film", "negative"]))
                let paper = beautify(field(["paper_name", "print_name", "print_profile", "print_paper", "paper_profile", "print", "paper"]))
                let stage = beautify(field(["pipeline_stage", "stage", "topology", "role", "lut_type", "variant"]))
                let suppliedName = beautify(field(["display_name", "friendly_name", "lut_name", "look_name", "label", "title"]))
                let main = [film, paper].filter { !$0.isEmpty }.joined(separator: "  ·  ")
                let title = !main.isEmpty ? main : (!suppliedName.isEmpty ? suppliedName : beautify(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent))
                let stageLower = stage.lowercased()
                let stageTag = stageLower.contains("full") || stageLower.contains("complete") || stageLower.contains("chain") ? "" : stage
                output[path] = Label(name: stageTag.isEmpty ? title : title + "  ·  " + stageTag,
                                     film: film, paper: paper, stage: stage)
            }
        }
        return output
    }

    // Handles BOM, CRLF, quoted commas, escaped quotes and quoted newlines.
    // Invalid unmatched quotes produce no catalog metadata rather than incorrect mappings.
    static func parseCSV(_ content: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], cell = ""
        var quoted = false
        let characters = Array(content.replacingOccurrences(of: "\u{FEFF}", with: ""))
        var i = 0
        while i < characters.count {
            let ch = characters[i]
            if ch == "\"" {
                if quoted && i + 1 < characters.count && characters[i+1] == "\"" {
                    cell.append("\""); i += 1
                } else { quoted.toggle() }
            } else if ch == "," && !quoted {
                row.append(cell); cell = ""
            } else if (ch == "\n" || ch == "\r") && !quoted {
                if ch == "\r" && i+1 < characters.count && characters[i+1] == "\n" { i += 1 }
                row.append(cell)
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []; cell = ""
            } else { cell.append(ch) }
            i += 1
        }
        if quoted { return [] }
        row.append(cell)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }

    private static func normalizeHeader(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private static func beautify(_ value: String) -> String {
        let transformed = value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return transformed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
