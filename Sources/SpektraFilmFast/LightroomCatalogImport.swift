import Foundation
import SQLite3

/// Read-only Lightroom Classic .lrcat reader. It never modifies Adobe's database.
struct LightroomCatalogImport: Sendable {
    struct Photo: Sendable, Hashable {
        var imageID: Int64
        var rootFileID: Int64
        var masterImageID: Int64?
        var copyName: String?
        var absolutePath: String
        var fileName: String
        var captureTime: String?
        var pick: Int
        var rating: Int
        var colorLabel: String?
        var latestDevelopText: String?
        var processVersion: String?
        var keywords: [String]
        var collectionIDs: [Int64]
    }

    struct Collection: Sendable, Hashable {
        var id: Int64
        var parentID: Int64?
        var name: String
    }

    struct Snapshot: Sendable {
        var photos: [Photo]
        var collections: [Collection]
        var warnings: [String]
    }

    enum ImportError: LocalizedError {
        case notLRCat
        case openFailed(String)
        case unsupportedSchema([String])

        var errorDescription: String? {
            switch self {
            case .notLRCat: return "Choose a Lightroom Classic .lrcat catalog."
            case .openFailed(let message): return "Could not open Lightroom catalog: \(message)"
            case .unsupportedSchema(let missing): return "Unsupported Lightroom catalog schema. Missing: \(missing.joined(separator: ", "))."
            }
        }
    }

    func read(_ url: URL) throws -> Snapshot {
        guard url.pathExtension.lowercased() == "lrcat" else { throw ImportError.notLRCat }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let db { sqlite3_close(db) }
            throw ImportError.openFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        let tables = try tableNames(db)
        let required = ["Adobe_images", "AgLibraryFile", "AgLibraryFolder", "AgLibraryRootFolder"]
        let missing = required.filter { !tables.contains($0) }
        guard missing.isEmpty else { throw ImportError.unsupportedSchema(missing) }

        var warnings: [String] = []
        var photos = try readPhotos(db)
        let keywords = try readKeywordMembership(db, tables: tables)
        let memberships = try readCollectionMembership(db, tables: tables)
        let develop = try readLatestDevelop(db, tables: tables, warnings: &warnings)

        for i in photos.indices {
            let id = photos[i].imageID
            photos[i].keywords = keywords[id, default: []]
            photos[i].collectionIDs = memberships[id, default: []]
            if let d = develop[id] {
                photos[i].latestDevelopText = d.0
                photos[i].processVersion = d.1
            }
        }

        return Snapshot(
            photos: photos,
            collections: try readCollections(db, tables: tables),
            warnings: warnings
        )
    }

    private func tableNames(_ db: OpaquePointer) throws -> Set<String> {
        var out = Set<String>()
        try rows(db, "SELECT name FROM sqlite_master WHERE type='table'") { s in
            if let p = sqlite3_column_text(s, 0) { out.insert(String(cString: p)) }
        }
        return out
    }

    private func columns(_ db: OpaquePointer, table: String) throws -> Set<String> {
        var out = Set<String>()
        try rows(db, "PRAGMA table_info(\(quoted(table)))") { s in
            if let p = sqlite3_column_text(s, 1) { out.insert(String(cString: p)) }
        }
        return out
    }

    private func readPhotos(_ db: OpaquePointer) throws -> [Photo] {
        let ic = try columns(db, table: "Adobe_images")
        let fc = try columns(db, table: "AgLibraryFile")
        func i(_ name: String, _ fallback: String = "NULL") -> String { ic.contains(name) ? "i.\(quoted(name))" : fallback }
        let base = fc.contains("baseName") ? "f.baseName" : (fc.contains("basename") ? "f.basename" : "''")
        let ext = fc.contains("extension") ? "f.extension" : "NULL"

        let sql = """
        SELECT i.id_local, i.rootFile, \(i("masterImage")), \(i("copyName")),
               COALESCE(r.absolutePath,''), COALESCE(o.pathFromRoot,''), COALESCE(\(base),''), \(ext),
               \(i("captureTime")), COALESCE(\(i("pick","0")),0), COALESCE(\(i("rating","0")),0), \(i("colorLabels"))
        FROM Adobe_images i
        JOIN AgLibraryFile f ON f.id_local = i.rootFile
        JOIN AgLibraryFolder o ON o.id_local = f.folder
        JOIN AgLibraryRootFolder r ON r.id_local = o.rootFolder
        ORDER BY i.id_local
        """

        var out: [Photo] = []
        try rows(db, sql) { s in
            let baseName = text(s, 6) ?? ""
            let extensionName = text(s, 7)
            let fileName = extensionName?.isEmpty == false ? "\(baseName).\(extensionName!)" : baseName
            let path = URL(fileURLWithPath: text(s, 4) ?? "")
                .appendingPathComponent(text(s, 5) ?? "", isDirectory: true)
                .appendingPathComponent(fileName)
                .standardizedFileURL.path
            out.append(.init(
                imageID: sqlite3_column_int64(s, 0),
                rootFileID: sqlite3_column_int64(s, 1),
                masterImageID: nullableInt64(s, 2),
                copyName: text(s, 3),
                absolutePath: path,
                fileName: fileName,
                captureTime: text(s, 8),
                pick: Int(sqlite3_column_int(s, 9)),
                rating: Int(sqlite3_column_int(s, 10)),
                colorLabel: text(s, 11),
                latestDevelopText: nil,
                processVersion: nil,
                keywords: [],
                collectionIDs: []
            ))
        }
        return out
    }

    private func readLatestDevelop(_ db: OpaquePointer, tables: Set<String>, warnings: inout [String]) throws -> [Int64:(String?,String?)] {
        guard tables.contains("Adobe_imageDevelopSettings") else {
            warnings.append("No Adobe_imageDevelopSettings table; develop settings were skipped.")
            return [:]
        }
        let cols = try columns(db, table: "Adobe_imageDevelopSettings")
        guard cols.contains("image"), cols.contains("text") else { return [:] }
        let pv = cols.contains("processVersion") ? "d.processVersion" : "NULL"
        let sql = """
        SELECT d.image, d.text, \(pv)
        FROM Adobe_imageDevelopSettings d
        JOIN (SELECT image, MAX(rowid) newest FROM Adobe_imageDevelopSettings GROUP BY image) x
          ON x.newest = d.rowid
        """
        var out: [Int64:(String?,String?)] = [:]
        try rows(db, sql) { s in out[sqlite3_column_int64(s,0)] = (text(s,1), text(s,2)) }
        return out
    }

    private func readKeywordMembership(_ db: OpaquePointer, tables: Set<String>) throws -> [Int64:[String]] {
        guard tables.contains("AgLibraryKeyword"), tables.contains("AgLibraryKeywordImage") else { return [:] }
        let kc = try columns(db, table: "AgLibraryKeyword")
        guard let name = ["name","lc_name"].first(where: { kc.contains($0) }) else { return [:] }
        var out: [Int64:[String]] = [:]
        try rows(db, "SELECT m.image,k.\(quoted(name)) FROM AgLibraryKeywordImage m JOIN AgLibraryKeyword k ON k.id_local=m.tag") { s in
            if let keyword = text(s,1), !keyword.isEmpty { out[sqlite3_column_int64(s,0), default: []].append(keyword) }
        }
        return out
    }

    private func readCollections(_ db: OpaquePointer, tables: Set<String>) throws -> [Collection] {
        guard tables.contains("AgLibraryCollection") else { return [] }
        let c = try columns(db, table: "AgLibraryCollection")
        let parent = c.contains("parent") ? "parent" : "NULL"
        var out: [Collection] = []
        try rows(db, "SELECT id_local,\(parent),name FROM AgLibraryCollection ORDER BY id_local") { s in
            out.append(.init(id: sqlite3_column_int64(s,0), parentID: nullableInt64(s,1), name: text(s,2) ?? "Untitled Collection"))
        }
        return out
    }

    private func readCollectionMembership(_ db: OpaquePointer, tables: Set<String>) throws -> [Int64:[Int64]] {
        guard tables.contains("AgLibraryCollectionImage") else { return [:] }
        let c = try columns(db, table: "AgLibraryCollectionImage")
        guard let image = ["image","imageId"].first(where: { c.contains($0) }),
              let collection = ["collection","collectionId"].first(where: { c.contains($0) }) else { return [:] }
        var out: [Int64:[Int64]] = [:]
        try rows(db, "SELECT \(quoted(image)),\(quoted(collection)) FROM AgLibraryCollectionImage") { s in
            out[sqlite3_column_int64(s,0), default: []].append(sqlite3_column_int64(s,1))
        }
        return out
    }

    private func rows(_ db: OpaquePointer, _ sql: String, body: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ImportError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { try body(stmt) }
            else if rc == SQLITE_DONE { return }
            else { throw ImportError.openFailed(String(cString: sqlite3_errmsg(db))) }
        }
    }

    private func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt,index) != SQLITE_NULL, let p = sqlite3_column_text(stmt,index) else { return nil }
        return String(cString:p)
    }
    private func nullableInt64(_ stmt: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(stmt,index) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt,index)
    }
}
