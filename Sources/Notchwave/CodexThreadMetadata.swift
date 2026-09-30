import Foundation
import SQLite3

struct CodexThreadMetadata: Equatable {
    let title: String?
    let hostID: String?

    static func cleanTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = String(value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(200))
        return title.isEmpty ? nil : title
    }

    static func validHost(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        return value
    }

    static func deepLink(session: String, hostID: String? = nil) -> URL? {
        guard let id = UUID(uuidString: session) else { return nil }
        var url = URLComponents()
        url.scheme = "codex"; url.host = "threads"; url.path = "/" + id.uuidString.lowercased()
        if let host = validHost(hostID), host != "local" {
            url.queryItems = [URLQueryItem(name: "hostId", value: host)]
        }
        return url.url
    }
}

/// Read the desktop's small title catalog, never the conversation body or credentials.
/// Catalog storage is a compatibility fallback and may change in a future Codex release.
struct CodexThreadMetadataReader {
    var home: URL = LocalTool.codexHome()

    func lookup(session: String) -> CodexThreadMetadata? {
        guard let id = UUID(uuidString: session)?.uuidString.lowercased() else { return nil }
        let folder = home.appendingPathComponent("sqlite", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let catalogs = files.filter {
            $0.pathExtension == "db" && ($0.lastPathComponent == "codex.db" || $0.lastPathComponent.hasPrefix("codex-"))
                && !$0.lastPathComponent.hasPrefix("codex-thread-summaries")
        }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in catalogs.prefix(4) {
            if let result = Self.readCatalog(file, session: id) { return result }
        }
        // Older local-only installations expose names in this metadata index.
        let index = home.appendingPathComponent("session_index.jsonl")
        guard let handle = try? FileHandle(forReadingFrom: index) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_194_305), data.count <= 4_194_304,
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.utf8.count <= 16_384 {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  (row["id"] as? String)?.lowercased() == id,
                  let title = CodexThreadMetadata.cleanTitle(row["thread_name"] as? String) else { continue }
            // Do not assert a local host: a moved thread may have an older local index entry.
            return CodexThreadMetadata(title: title, hostID: nil)
        }
        return nil
    }

    static func readCatalog(_ url: URL, session: String) -> CodexThreadMetadata? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 30)
        var statement: OpaquePointer?
        let sql = "SELECT display_title, host_id FROM local_thread_catalog WHERE thread_id = ? AND missing_candidate = 0 ORDER BY source_updated_at DESC LIMIT 2"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, session, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let title = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        let host = sqlite3_column_text(statement, 1).map { String(cString: $0) }
        // If a handoff temporarily leaves two owners, let Codex resolve the host.
        let ambiguousHost = sqlite3_step(statement) == SQLITE_ROW
        return CodexThreadMetadata(title: CodexThreadMetadata.cleanTitle(title),
                                   hostID: ambiguousHost ? nil : CodexThreadMetadata.validHost(host))
    }
}
