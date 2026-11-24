import AppKit
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Everything the monitor extracted from one pasteboard change, ready to be stored.
struct CapturedPayload {
    var kind: ClipKind
    var hash: String
    var preview: String
    var searchText: String
    var body: String?
    var blobData: Data?
    var blobExtension: String = "bin"
    var rtfData: Data?
    var thumbData: Data?
    /// PNG for thumbnails with transparency, JPEG for everything else.
    var thumbExtension: String = "jpg"
    var byteSize: Int
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var fileCount: Int = 0
    var sourceName: String = ""
    var sourceBundle: String = ""
}

extension Notification.Name {
    static let clipStoreChanged = Notification.Name("com.joymadhu.Clipline.storeChanged")
}

/// SQLite backed clipboard history.
///
/// Rows carry only metadata plus a short preview. Bodies over the inline threshold, images
/// and file lists live in the support folder, which keeps both the database and resident
/// memory small no matter how long the history grows.
final class ClipStore {
    static let shared = ClipStore()

    /// Text longer than this is written to disk instead of the database.
    private let inlineTextLimit = 32_768
    /// Longest preview kept for list rows.
    static let previewLimit = 320
    /// Longest text kept for search matching.
    static let searchLimit = 4_096

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.joymadhu.Clipline.store")

    let supportDirectory: URL
    private let blobsDirectory: URL
    private let thumbsDirectory: URL
    private let databaseURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        supportDirectory = base.appendingPathComponent("Clipline", isDirectory: true)
        blobsDirectory = supportDirectory.appendingPathComponent("blobs", isDirectory: true)
        thumbsDirectory = supportDirectory.appendingPathComponent("thumbs", isDirectory: true)
        databaseURL = supportDirectory.appendingPathComponent("clipline.db")
    }

    // MARK: Lifecycle

    func open() {
        queue.sync {
            let fm = FileManager.default
            for directory in [supportDirectory, blobsDirectory, thumbsDirectory] {
                try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
                // Owner only. The contents are sealed anyway; this keeps other accounts on
                // the Mac from even listing them.
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            guard sqlite3_open_v2(databaseURL.path, &db,
                                  SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                NSLog("Clipline: could not open database at %@", databaseURL.path)
                return
            }
            // Freed pages are zeroed, so a deleted entry's ciphertext does not linger either.
            exec("PRAGMA secure_delete = ON;")
            exec("PRAGMA journal_mode = WAL;")
            exec("PRAGMA synchronous = NORMAL;")
            exec("PRAGMA temp_store = MEMORY;")
            // Keeps the write ahead log from growing without bound between checkpoints.
            exec("PRAGMA journal_size_limit = 1048576;")
            // Keep the page cache small on purpose. History queries are tiny and paged.
            exec("PRAGMA cache_size = -2000;")
            exec("""
            CREATE TABLE IF NOT EXISTS items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,
                hash TEXT NOT NULL,
                preview TEXT NOT NULL,
                search_text TEXT NOT NULL,
                body TEXT,
                blob_name TEXT,
                rtf_name TEXT,
                thumb_name TEXT,
                byte_size INTEGER NOT NULL DEFAULT 0,
                pixel_width INTEGER NOT NULL DEFAULT 0,
                pixel_height INTEGER NOT NULL DEFAULT 0,
                file_count INTEGER NOT NULL DEFAULT 0,
                pinned INTEGER NOT NULL DEFAULT 0,
                pin_order INTEGER NOT NULL DEFAULT 0,
                copied_at REAL NOT NULL,
                created_at REAL NOT NULL,
                use_count INTEGER NOT NULL DEFAULT 1,
                source_name TEXT NOT NULL DEFAULT '',
                source_bundle TEXT NOT NULL DEFAULT '',
                masked INTEGER NOT NULL DEFAULT 0,
                label TEXT NOT NULL DEFAULT ''
            );
            """)
            // Databases from earlier builds predate the masking columns.
            ensureColumn("masked", definition: "INTEGER NOT NULL DEFAULT 0")
            ensureColumn("label", definition: "TEXT NOT NULL DEFAULT ''")
            exec("CREATE INDEX IF NOT EXISTS idx_items_copied ON items(copied_at DESC);")
            exec("CREATE INDEX IF NOT EXISTS idx_items_hash ON items(hash);")
            exec("CREATE INDEX IF NOT EXISTS idx_items_pinned ON items(pinned, pin_order);")
            prepareEncryption()
        }
    }

    // MARK: Encryption

    /// Schema version stored in PRAGMA user_version. 0 is a plain text history from a build
    /// before encryption, 1 is fully sealed.
    private static let encryptedSchemaVersion: Int32 = 1

    /// Caller must already be on the store queue.
    private func prepareEncryption() {
        let vault = ClipVault.shared
        let version = userVersion()
        if version >= Self.encryptedSchemaVersion {
            // A sealed history with a brand new key means the old key is gone, and nothing
            // stored under it can be opened again. Start clean instead of showing blanks.
            if vault.isNewKey {
                audit("storage key missing, discarding unreadable history")
                exec("DELETE FROM items;")
                for directory in [blobsDirectory, thumbsDirectory] {
                    let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                    contents.forEach { try? FileManager.default.removeItem(at: $0) }
                }
                exec("VACUUM;")
            }
            return
        }
        migrateToEncrypted()
    }

    /// Seals every row and file written by a build before encryption, then rewrites the
    /// database so no plain text page survives in the file or its write ahead log.
    /// Caller must already be on the store queue.
    private func migrateToEncrypted() {
        let vault = ClipVault.shared
        struct Row { var id: Int64; var values: [String?] }
        var rows: [Row] = []
        let sql = "SELECT id, hash, preview, search_text, body, source_name, source_bundle, label FROM items;"
        if let statement = prepare(sql) {
            while sqlite3_step(statement) == SQLITE_ROW {
                var values: [String?] = []
                for index in 1...7 {
                    values.append(sqlite3_column_text(statement, Int32(index)).map { String(cString: $0) })
                }
                rows.append(Row(id: sqlite3_column_int64(statement, 0), values: values))
            }
            sqlite3_finalize(statement)
        }

        // Files first, every one in the folders and not only those a row points at: earlier
        // builds left files behind after a delete, and those hold clipboard content too.
        // Sealing rather than deleting keeps an update from losing anything. Each file is
        // sealed in place; a crash midway leaves a mix the reader already copes with, since
        // unsealed data passes through.
        let fm = FileManager.default
        for directory in [blobsDirectory, thumbsDirectory] {
            let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in contents {
                guard let data = try? Data(contentsOf: url), !ClipVault.isSealed(data),
                      let sealed = vault.seal(data) else { continue }
                try? sealed.write(to: url, options: .atomic)
            }
        }

        exec("BEGIN IMMEDIATE;")
        let update = """
        UPDATE items SET hash = ?, preview = ?, search_text = ?, body = ?, source_name = ?,
                         source_bundle = ?, label = ? WHERE id = ?;
        """
        for row in rows {
            guard let statement = prepare(update) else { continue }
            let hash = row.values[0] ?? ""
            bindText(statement, 1, hash.hasPrefix("h1:") ? hash : vault.tag(hash))
            for index in 1..<7 {
                let value = row.values[index]
                let sealed = value.map { ClipVault.isSealedText($0) ? $0 : vault.sealText($0) }
                bindOptionalText(statement, Int32(index + 1), sealed)
            }
            sqlite3_bind_int64(statement, 8, row.id)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        exec("PRAGMA user_version = \(Self.encryptedSchemaVersion);")
        exec("COMMIT;")

        // The old plain text still sits in freed pages and in the write ahead log until the
        // log is folded back and the file rebuilt.
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        exec("VACUUM;")
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        audit("encrypted \(rows.count) existing entries")
    }

    private func userVersion() -> Int32 {
        guard let statement = prepare("PRAGMA user_version;") else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
    }

    /// Writes a stored file sealed. Caller must already be on the store queue.
    private func writeSealed(_ data: Data, to url: URL) -> Bool {
        guard let sealed = ClipVault.shared.seal(data) else { return false }
        return (try? sealed.write(to: url, options: .atomic)) != nil
    }

    private func readSealed(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ClipVault.shared.open(data)
    }

    func close() {
        queue.sync {
            if let db {
                sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
                sqlite3_close_v2(db)
            }
            db = nil
        }
    }

    /// Folds the write ahead log back into the database file. Cheap and worth doing whenever
    /// the app goes idle so the support folder does not sit on stale megabytes.
    func checkpoint() {
        queue.sync {
            guard let db else { return }
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        }
    }

    // MARK: Writing

    /// Stores a captured payload, folding duplicates into the existing row.
    /// Returns the row id of the stored or refreshed item.
    @discardableResult
    func insert(_ payload: CapturedPayload, historyLimit: Int, retentionHours: Int) -> Int64? {
        let id: Int64? = queue.sync {
            guard db != nil else { return nil }
            let now = Date().timeIntervalSince1970
            let vault = ClipVault.shared
            let hash = vault.tag(payload.hash)

            // Fold duplicates: refresh the existing row instead of growing the history.
            if let existing = firstID(matchingHash: hash) {
                let sql = "UPDATE items SET copied_at = ?, use_count = use_count + 1, source_name = ?, source_bundle = ? WHERE id = ?;"
                if let statement = prepare(sql) {
                    sqlite3_bind_double(statement, 1, now)
                    bindText(statement, 2, vault.sealText(payload.sourceName))
                    bindText(statement, 3, vault.sealText(payload.sourceBundle))
                    sqlite3_bind_int64(statement, 4, existing)
                    sqlite3_step(statement)
                    sqlite3_finalize(statement)
                }
                // Duplicates still count as activity, so the retention window is applied here too.
                trim(historyLimit: historyLimit, retentionHours: retentionHours)
                return existing
            }

            var blobName: String?
            var rtfName: String?
            var thumbName: String?
            var inlineBody = payload.body

            if let body = payload.body, body.utf8.count > inlineTextLimit {
                inlineBody = nil
                let name = UUID().uuidString + ".txt"
                if writeSealed(Data(body.utf8), to: blobsDirectory.appendingPathComponent(name)) {
                    blobName = name
                }
            }
            if let data = payload.blobData {
                let name = UUID().uuidString + "." + payload.blobExtension
                if writeSealed(data, to: blobsDirectory.appendingPathComponent(name)) {
                    blobName = name
                }
            }
            if let data = payload.rtfData {
                let name = UUID().uuidString + ".rtf"
                if writeSealed(data, to: blobsDirectory.appendingPathComponent(name)) {
                    rtfName = name
                }
            }
            if let data = payload.thumbData {
                let name = UUID().uuidString + "." + payload.thumbExtension
                if writeSealed(data, to: thumbsDirectory.appendingPathComponent(name)) {
                    thumbName = name
                }
            }

            let sql = """
            INSERT INTO items (kind, hash, preview, search_text, body, blob_name, rtf_name, thumb_name,
                               byte_size, pixel_width, pixel_height, file_count, pinned, pin_order,
                               copied_at, created_at, use_count, source_name, source_bundle)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, 1, ?, ?);
            """
            guard let statement = prepare(sql) else { return nil }
            bindText(statement, 1, payload.kind.rawValue)
            bindText(statement, 2, hash)
            bindText(statement, 3, vault.sealText(payload.preview))
            bindText(statement, 4, vault.sealText(payload.searchText))
            bindOptionalText(statement, 5, inlineBody.map(vault.sealText))
            bindOptionalText(statement, 6, blobName)
            bindOptionalText(statement, 7, rtfName)
            bindOptionalText(statement, 8, thumbName)
            sqlite3_bind_int64(statement, 9, Int64(payload.byteSize))
            sqlite3_bind_int(statement, 10, Int32(payload.pixelWidth))
            sqlite3_bind_int(statement, 11, Int32(payload.pixelHeight))
            sqlite3_bind_int(statement, 12, Int32(payload.fileCount))
            sqlite3_bind_double(statement, 13, now)
            sqlite3_bind_double(statement, 14, now)
            bindText(statement, 15, vault.sealText(payload.sourceName))
            bindText(statement, 16, vault.sealText(payload.sourceBundle))
            let ok = sqlite3_step(statement) == SQLITE_DONE
            sqlite3_finalize(statement)
            guard ok, let db else {
                // The row never landed, so the files it would have owned are already garbage.
                let fm = FileManager.default
                for name in [blobName, rtfName] where name != nil {
                    try? fm.removeItem(at: blobsDirectory.appendingPathComponent(name!))
                }
                if let thumbName {
                    try? fm.removeItem(at: thumbsDirectory.appendingPathComponent(thumbName))
                }
                return nil
            }
            let newID = sqlite3_last_insert_rowid(db)
            trim(historyLimit: historyLimit, retentionHours: retentionHours)
            return newID
        }
        if id != nil { announceChange() }
        return id
    }

    /// Moves an item back to the top of the history after it is pasted again.
    func touch(id: Int64) {
        queue.sync {
            guard let statement = prepare("UPDATE items SET copied_at = ?, use_count = use_count + 1 WHERE id = ?;") else { return }
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(statement, 2, id)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        announceChange()
    }

    /// Masks or unmasks an entry. A masked entry keeps working exactly as before, but the
    /// list shows its name or dots instead of the content, so it is safe on a shared or
    /// recorded screen.
    func setMasked(_ masked: Bool, id: Int64) {
        queue.sync {
            guard let statement = prepare("UPDATE items SET masked = ? WHERE id = ?;") else { return }
            sqlite3_bind_int(statement, 1, masked ? 1 : 0)
            sqlite3_bind_int64(statement, 2, id)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        announceChange()
    }

    /// Names an entry. The name stands in for the content in the list; empty removes it.
    func setLabel(_ label: String, id: Int64) {
        queue.sync {
            guard let statement = prepare("UPDATE items SET label = ? WHERE id = ?;") else { return }
            bindText(statement, 1, ClipVault.shared.sealText(label))
            sqlite3_bind_int64(statement, 2, id)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        announceChange()
    }

    func setPinned(_ pinned: Bool, id: Int64) {
        queue.sync {
            var order = 0
            if pinned, let statement = prepare("SELECT COALESCE(MIN(pin_order), 0) - 1 FROM items WHERE pinned = 1;") {
                if sqlite3_step(statement) == SQLITE_ROW { order = Int(sqlite3_column_int(statement, 0)) }
                sqlite3_finalize(statement)
            }
            guard let statement = prepare("UPDATE items SET pinned = ?, pin_order = ? WHERE id = ?;") else { return }
            sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
            sqlite3_bind_int(statement, 2, Int32(order))
            sqlite3_bind_int64(statement, 3, id)
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
        announceChange()
    }

    /// Removes a row along with its stored files, so a delete reclaims its space straight
    /// away. Deletes are final; copying the content again recreates the entry.
    func delete(id: Int64) {
        audit("delete id=\(id) caller=\(Self.callerHint())")
        queue.sync {
            removeFiles(forIDs: [id])
            if let statement = prepare("DELETE FROM items WHERE id = ?;") {
                sqlite3_bind_int64(statement, 1, id)
                sqlite3_step(statement)
                sqlite3_finalize(statement)
            }
        }
        announceChange()
    }

    /// Clears history. Pinned rows survive unless `includingPinned` is set.
    ///
    /// Deleting the stored files and rewriting the database are both slow enough to matter,
    /// so `reclaimSpace` is skipped on the quit path where there is no time for it.
    func clear(includingPinned: Bool, reclaimSpace: Bool = true) {
        audit("clear includingPinned=\(includingPinned) caller=\(Self.callerHint())")
        queue.sync {
            let condition = includingPinned ? "" : " WHERE pinned = 0"
            var ids: [Int64] = []
            if let statement = prepare("SELECT id FROM items" + condition + ";") {
                while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
                sqlite3_finalize(statement)
            }
            removeFiles(forIDs: ids)
            exec("DELETE FROM items" + condition + ";")
            if reclaimSpace { exec("VACUUM;") }
        }
        announceChange()
    }

    /// Clears history off the main thread, calling back on main when it is done.
    func clearInBackground(includingPinned: Bool, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.clear(includingPinned: includingPinned)
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Applies the history limit and the retention window, deleting orphaned files.
    func trimNow(historyLimit: Int, retentionHours: Int) {
        let removed = queue.sync { trim(historyLimit: historyLimit, retentionHours: retentionHours) }
        if removed > 0 { announceChange() }
    }

    func compact() {
        queue.sync {
            pruneOrphanFiles()
            exec("VACUUM;")
        }
    }

    // MARK: Reading

    func items(filter: ClipFilter, query: String, limit: Int) -> [ClipItem] {
        queue.sync {
            let condition = filter.sqlCondition
            let whereClause = condition.isEmpty ? "" : " WHERE " + condition
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Search text is sealed, so SQLite cannot match it. With a query the rows are
            // opened and matched here instead; the history is capped in the thousands, which
            // keeps this well under a frame.
            let sql = """
            SELECT id, kind, preview, pinned, pin_order, copied_at, created_at, use_count, byte_size,
                   pixel_width, pixel_height, file_count, source_name, source_bundle, thumb_name,
                   (body IS NOT NULL OR blob_name IS NOT NULL), masked, label, search_text
            FROM items\(whereClause)
            ORDER BY pinned DESC, CASE WHEN pinned = 1 THEN pin_order ELSE 0 END ASC, copied_at DESC
            \(trimmed.isEmpty ? "LIMIT ?" : "");
            """
            guard let statement = prepare(sql) else { return [] }
            if trimmed.isEmpty { sqlite3_bind_int(statement, 1, Int32(limit)) }
            var result: [ClipItem] = []
            result.reserveCapacity(min(limit, 256))
            while result.count < limit, sqlite3_step(statement) == SQLITE_ROW {
                let item = readRow(statement)
                if !trimmed.isEmpty {
                    let searchText = ClipVault.shared.openText(column(statement, 18))
                    // The name given to an entry matches too, so a masked "Email" is found by name.
                    guard searchText.lowercased().contains(trimmed) || item.label.lowercased().contains(trimmed) else { continue }
                }
                result.append(item)
            }
            sqlite3_finalize(statement)
            return result
        }
    }

    func item(id: Int64) -> ClipItem? {
        queue.sync {
            let sql = """
            SELECT id, kind, preview, pinned, pin_order, copied_at, created_at, use_count, byte_size,
                   pixel_width, pixel_height, file_count, source_name, source_bundle, thumb_name,
                   (body IS NOT NULL OR blob_name IS NOT NULL), masked, label
            FROM items WHERE id = ?;
            """
            guard let statement = prepare(sql) else { return nil }
            sqlite3_bind_int64(statement, 1, id)
            var item: ClipItem?
            if sqlite3_step(statement) == SQLITE_ROW { item = readRow(statement) }
            sqlite3_finalize(statement)
            return item
        }
    }

    /// Full text for an entry, read from disk when it was too large to inline.
    func body(id: Int64) -> String? {
        queue.sync {
            guard let statement = prepare("SELECT body, blob_name, kind FROM items WHERE id = ?;") else { return nil }
            sqlite3_bind_int64(statement, 1, id)
            var text: String?
            if sqlite3_step(statement) == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 0) {
                    text = ClipVault.shared.openText(String(cString: raw))
                } else if let raw = sqlite3_column_text(statement, 1),
                          let kindRaw = sqlite3_column_text(statement, 2) {
                    let kind = String(cString: kindRaw)
                    let name = String(cString: raw)
                    let textKinds = [ClipKind.text, .link, .color, .file].map(\.rawValue)
                    if textKinds.contains(kind),
                       let data = readSealed(at: blobsDirectory.appendingPathComponent(name)) {
                        text = String(data: data, encoding: .utf8)
                    }
                }
            }
            sqlite3_finalize(statement)
            return text
        }
    }

    /// File paths for a file entry. Stored as JSON, with a fallback for rows written by
    /// earlier builds that joined the paths with newlines.
    func filePaths(id: Int64) -> [URL] {
        guard let body = body(id: id) else { return [] }
        if let data = body.data(using: .utf8),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return body.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// Decrypted bytes of an image entry, with the extension it was captured as.
    func blobData(id: Int64) -> (data: Data, pathExtension: String)? {
        queue.sync {
            guard let statement = prepare("SELECT blob_name FROM items WHERE id = ?;") else { return nil }
            sqlite3_bind_int64(statement, 1, id)
            var result: (Data, String)?
            if sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) {
                let url = blobsDirectory.appendingPathComponent(String(cString: raw))
                if let data = readSealed(at: url) { result = (data, url.pathExtension) }
            }
            sqlite3_finalize(statement)
            return result
        }
    }

    func richTextData(id: Int64) -> Data? {
        queue.sync {
            guard let statement = prepare("SELECT rtf_name FROM items WHERE id = ?;") else { return nil }
            sqlite3_bind_int64(statement, 1, id)
            var data: Data?
            if sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) {
                data = readSealed(at: blobsDirectory.appendingPathComponent(String(cString: raw)))
            }
            sqlite3_finalize(statement)
            return data
        }
    }

    func thumbnailURL(for item: ClipItem) -> URL? {
        guard let name = item.thumbPath else { return nil }
        return thumbsDirectory.appendingPathComponent(name)
    }

    /// Folder for decrypted copies handed to other apps by drag and drop. Emptied on launch
    /// and pruned as the app runs, so a plain copy only lives as long as the drop needs it.
    var dragDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Clipline Drag", isDirectory: true)
    }

    func clearDragDirectory() {
        try? FileManager.default.removeItem(at: dragDirectory)
    }

    /// Writes a decrypted copy of an entry for a drag, under the name the receiving app will
    /// show. Each drag gets a folder of its own, so two drags can share a name.
    func writeDragCopy(_ data: Data, named name: String) -> URL? {
        let folder = dragDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            // Owner only, the same as the support folder.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Removes drag copies older than `age`. Apps read a dropped file straight away, or at
    /// the latest when the message it was dropped into is sent, so an hour is plenty.
    func pruneDragCopies(olderThan age: TimeInterval = 3_600) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        let folders = (try? fm.contentsOfDirectory(at: dragDirectory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    struct Stats {
        var total: Int = 0
        var pinned: Int = 0
        var databaseBytes: Int64 = 0
        var fileBytes: Int64 = 0
        var totalBytes: Int64 { databaseBytes + fileBytes }
    }

    func stats() -> Stats {
        queue.sync {
            var stats = Stats()
            if let statement = prepare("SELECT COUNT(*), COALESCE(SUM(pinned), 0) FROM items;") {
                if sqlite3_step(statement) == SQLITE_ROW {
                    stats.total = Int(sqlite3_column_int(statement, 0))
                    stats.pinned = Int(sqlite3_column_int(statement, 1))
                }
                sqlite3_finalize(statement)
            }
            let fm = FileManager.default
            for name in ["clipline.db", "clipline.db-wal", "clipline.db-shm"] {
                let url = supportDirectory.appendingPathComponent(name)
                stats.databaseBytes += Int64((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
            }
            for directory in [blobsDirectory, thumbsDirectory] {
                let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for url in contents {
                    stats.fileBytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            return stats
        }
    }

    // MARK: Internals

    private func readRow(_ statement: OpaquePointer?) -> ClipItem {
        let kindRaw = column(statement, 1)
        let vault = ClipVault.shared
        return ClipItem(
            id: sqlite3_column_int64(statement, 0),
            kind: ClipKind(rawValue: kindRaw) ?? .text,
            preview: vault.openText(column(statement, 2)),
            pinned: sqlite3_column_int(statement, 3) == 1,
            pinOrder: Int(sqlite3_column_int(statement, 4)),
            copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            useCount: Int(sqlite3_column_int(statement, 7)),
            byteSize: Int(sqlite3_column_int64(statement, 8)),
            pixelWidth: Int(sqlite3_column_int(statement, 9)),
            pixelHeight: Int(sqlite3_column_int(statement, 10)),
            fileCount: Int(sqlite3_column_int(statement, 11)),
            sourceName: vault.openText(column(statement, 12)),
            sourceBundle: vault.openText(column(statement, 13)),
            thumbPath: sqlite3_column_text(statement, 14).map { String(cString: $0) },
            hasBody: sqlite3_column_int(statement, 15) == 1,
            masked: sqlite3_column_int(statement, 16) == 1,
            label: vault.openText(column(statement, 17))
        )
    }

    /// Adds a column an earlier build's database is missing. SQLite has no
    /// "IF NOT EXISTS" for columns, so the table info is checked first.
    private func ensureColumn(_ name: String, definition: String) {
        var exists = false
        if let statement = prepare("PRAGMA table_info(items);") {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 1), String(cString: raw) == name {
                    exists = true
                    break
                }
            }
            sqlite3_finalize(statement)
        }
        if !exists { exec("ALTER TABLE items ADD COLUMN \(name) \(definition);") }
    }

    private func firstID(matchingHash hash: String) -> Int64? {
        guard let statement = prepare("SELECT id FROM items WHERE hash = ? LIMIT 1;") else { return nil }
        bindText(statement, 1, hash)
        var id: Int64?
        if sqlite3_step(statement) == SQLITE_ROW { id = sqlite3_column_int64(statement, 0) }
        sqlite3_finalize(statement)
        return id
    }

    /// Caller must already be on the store queue.
    /// Returns how many rows were removed.
    @discardableResult
    private func trim(historyLimit: Int, retentionHours: Int) -> Int {
        var doomed: [Int64] = []
        if historyLimit > 0,
           let statement = prepare("""
           SELECT id FROM items WHERE pinned = 0 AND id NOT IN
             (SELECT id FROM items WHERE pinned = 0 ORDER BY copied_at DESC LIMIT ?);
           """) {
            sqlite3_bind_int(statement, 1, Int32(historyLimit))
            while sqlite3_step(statement) == SQLITE_ROW { doomed.append(sqlite3_column_int64(statement, 0)) }
            sqlite3_finalize(statement)
        }
        if retentionHours > 0,
           let statement = prepare("SELECT id FROM items WHERE pinned = 0 AND copied_at < ?;") {
            let cutoff = Date().timeIntervalSince1970 - Double(retentionHours) * 3_600
            sqlite3_bind_double(statement, 1, cutoff)
            while sqlite3_step(statement) == SQLITE_ROW { doomed.append(sqlite3_column_int64(statement, 0)) }
            sqlite3_finalize(statement)
        }
        // A row can be both over the limit and past the window.
        doomed = Array(Set(doomed))
        guard !doomed.isEmpty else { return 0 }
        audit("trim removing \(doomed.count) rows limit=\(historyLimit) retentionHours=\(retentionHours) caller=\(Self.callerHint())")
        removeFiles(forIDs: doomed)
        let list = doomed.map(String.init).joined(separator: ",")
        exec("DELETE FROM items WHERE id IN (\(list));")
        return doomed.count
    }

    /// Caller must already be on the store queue.
    private func removeFiles(forIDs ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let list = ids.map(String.init).joined(separator: ",")
        guard let statement = prepare("SELECT blob_name, rtf_name, thumb_name FROM items WHERE id IN (\(list));") else { return }
        let fm = FileManager.default
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) {
                try? fm.removeItem(at: blobsDirectory.appendingPathComponent(String(cString: raw)))
            }
            if let raw = sqlite3_column_text(statement, 1) {
                try? fm.removeItem(at: blobsDirectory.appendingPathComponent(String(cString: raw)))
            }
            if let raw = sqlite3_column_text(statement, 2) {
                try? fm.removeItem(at: thumbsDirectory.appendingPathComponent(String(cString: raw)))
            }
        }
        sqlite3_finalize(statement)
    }

    /// Deletes stored files no row points at any more.
    private func pruneOrphanFiles() {
        var referenced = Set<String>()
        if let statement = prepare("SELECT blob_name, rtf_name, thumb_name FROM items;") {
            while sqlite3_step(statement) == SQLITE_ROW {
                for column in 0..<3 {
                    if let raw = sqlite3_column_text(statement, Int32(column)) { referenced.insert(String(cString: raw)) }
                }
            }
            sqlite3_finalize(statement)
        }
        let fm = FileManager.default
        for directory in [blobsDirectory, thumbsDirectory] {
            let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in contents where !referenced.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// The first few frames of the call stack outside this file, which is enough to tell a
    /// menu action apart from launch housekeeping.
    static func callerHint() -> String {
        Thread.callStackSymbols
            .dropFirst(2)
            .prefix(4)
            .map { symbol -> String in
                let parts = symbol.split(separator: " ").dropFirst(3)
                return parts.prefix(3).joined(separator: " ")
            }
            .joined(separator: " | ")
    }

    /// Records anything that removes entries, with a timestamp and the call site.
    ///
    /// History disappearing is the worst thing this app could do, so every deletion leaves
    /// a trace that can be read back later. The file is trimmed to the last 200 lines.
    func audit(_ message: String, function: String = #function) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  \(function)  \(message)\n"
        let url = supportDirectory.appendingPathComponent("audit.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
            if let existing = try? String(contentsOf: url, encoding: .utf8) {
                let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count > 200 {
                    let trimmed = lines.suffix(200).joined(separator: "\n")
                    try? Data(trimmed.utf8).write(to: url, options: .atomic)
                }
            }
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func announceChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipStoreChanged, object: nil)
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK, let error {
            NSLog("Clipline SQL error: %@", String(cString: error))
            sqlite3_free(error)
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("Clipline could not prepare: %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        return statement
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: raw)
    }
}
