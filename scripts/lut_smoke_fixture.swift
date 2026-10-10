import Foundation

@main
struct CatalogSmoke {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Film", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let nested = folder.appendingPathComponent("Film/portra.cube")
        try "LUT_3D_SIZE 2\n".write(to: nested, atomically: true, encoding: .utf8)
        let other = folder.appendingPathComponent("BW.cube")
        try "LUT_3D_SIZE 2\n".write(to: other, atomically: true, encoding: .utf8)
        let csv = """
        \u{FEFF}relative_path,film_profile,print_profile,stage,status
        "Film/portra.cube","kodak_portra_400","endura_premier","full_chain",completed
        "BW.cube","Fujifilm, 400","Crystal Archive","negative",completed
        "missing.cube","Not A LUT","Fake Paper","full",failed
        """
        try csv.write(to: folder.appendingPathComponent("LUT_Catalog.csv"), atomically: true, encoding: .utf8)
        let records = StudioLUTCatalog.metadata(for: folder,relativeLUTs:["Film/portra.cube", "BW.cube"])
        guard records.count == 2,
              records["Film/portra.cube"]?.name == "kodak portra 400  ·  endura premier",
              records["BW.cube"]?.name == "Fujifilm, 400  ·  Crystal Archive  ·  negative" else {
            fatalError("LUT catalog parsing mismatch: \(records)")
        }
        let quoted = StudioLUTCatalog.parseCSV("file,film\n\"a,b.cube\",\"Film \"\"A\"\"\"\n")
        guard quoted.count == 2,
              quoted[1] == ["a,b.cube","Film \"A\""] else {
            fatalError("Quoted CSV fields are broken: \(quoted)")
        }
        print("CATALOG_SMOKE_PASS: CSV names, stage, quoted commas, escaped quotes, BOM, relative paths")
    }
}
