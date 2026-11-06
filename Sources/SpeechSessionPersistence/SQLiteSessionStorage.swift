import Foundation
import SQLite3

/// Connections are short-lived: no lock survives actor suspension, import or phone locking.
/// Each collection row is updated only when its encoded contents change.
struct SQLiteSessionStorage {
    static let filename = "patient.sqlite"
    let directory: URL
    private let tables = ["records", "folders", "topics", "care_team", "preferences", "care_plans", "occurrences", "source_revisions", "processing_receipts", "medication_products", "metadata"]
    private var url: URL { directory.appendingPathComponent(Self.filename) }
    private func connection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }; throw SessionStoreError.ioFailed("Could not open saved records.")
        }
        defer { sqlite3_close(db) }
        var versionStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &versionStatement, nil) == SQLITE_OK,
              sqlite3_step(versionStatement) == SQLITE_ROW else { sqlite3_finalize(versionStatement); throw SessionStoreError.decodingFailed }
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard version <= 1 else { throw SessionStoreError.decodingFailed }
        sqlite3_busy_timeout(db, 5000)
        try execute(db, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
        for table in tables {
            try execute(db, "CREATE TABLE IF NOT EXISTS \(table)(id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload TEXT NOT NULL)")
        }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return try body(db)
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SessionStoreError.ioFailed("Could not commit saved records.") }
    }
    private func rows(_ db: OpaquePointer, table: String) throws -> [(String, String)] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id,payload FROM \(table) ORDER BY position,id", -1, &statement, nil) == SQLITE_OK else { throw SessionStoreError.decodingFailed }
        defer { sqlite3_finalize(statement) }
        var result: [(String,String)] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let id = sqlite3_column_text(statement,0), let payload = sqlite3_column_text(statement,1) else { throw SessionStoreError.decodingFailed }
            result.append((String(cString:id),String(cString:payload)))
        }
    }
    private func read(_ db: OpaquePointer) throws -> Data? {
        let meta = try rows(db, table:"metadata")
        guard let root = meta.first(where: {$0.0 == "envelope"}) else {
            var statement:OpaquePointer?;defer {sqlite3_finalize(statement)}
            guard sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&statement,nil)==SQLITE_OK,sqlite3_step(statement)==SQLITE_ROW,sqlite3_column_int(statement,0)==0 else {throw SessionStoreError.decodingFailed}
            return nil
        }
        guard var object = try JSONSerialization.jsonObject(with:Data(root.1.utf8)) as? [String:Any] else {throw SessionStoreError.decodingFailed}
        let mapping = [("sessions","records"),("folders","folders"),("topics","topics"),("careTeam","care_team"),("preferences","preferences"),("carePlanCards","care_plans"),("medicationProducts","medication_products")]
        for (key,table) in mapping { object[key] = try rows(db, table:table).map { try JSONSerialization.jsonObject(with:Data($0.1.utf8)) } }
        var sessions = object["sessions"] as? [[String:Any]] ?? []
        for i in sessions.indices {
            for field in ["summaryEntries","summaryRevisions"] {
                if sessions[i].removeValue(forKey:"_sqlite_"+field) as? Bool == true {sessions[i][field]=[Any]()}
            }
        }
        for (table,field) in [("occurrences","summaryEntries"),("source_revisions","summaryRevisions"),("processing_receipts","summaryRun")] {
            for (key,payload) in try rows(db,table:table) {
                let value=try JSONSerialization.jsonObject(with:Data(payload.utf8),options:.fragmentsAllowed)
                if key == "update" {object["recordUpdate"]=value;continue}
                let recordID=String(key.split(separator:"/")[0])
                guard let i=sessions.firstIndex(where:{($0["id"] as? String)==recordID}) else {throw SessionStoreError.decodingFailed}
                if field == "summaryRun" {sessions[i][field]=value}
                else {var values=sessions[i][field] as? [Any] ?? [];values.append(value);sessions[i][field]=values}
            }
        }
        object["sessions"] = sessions
        return try JSONSerialization.data(withJSONObject:object, options:.sortedKeys)
    }
    func load() throws -> Data? {
        try connection { db in
            try execute(db,"BEGIN")
            do {let value=try read(db);try execute(db,"COMMIT");return value}
            catch {try? execute(db,"ROLLBACK");throw error}
        }
    }
    func save(_ data: Data) throws {
        try connection { db in
            try execute(db,"BEGIN IMMEDIATE")
            do {
                guard var object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw SessionStoreError.decodingFailed }
                var collections: [String:[(String,Any)]] = [:]
                for (key,table) in [("sessions","records"),("folders","folders"),("topics","topics"),("careTeam","care_team"),("preferences","preferences"),("carePlanCards","care_plans"),("medicationProducts","medication_products")] {
                    let values = object.removeValue(forKey:key) as? [[String:Any]] ?? []
                    var seen = Set<String>()
                    collections[table] = try values.map { value in
                        guard let id = value["id"] as? String, seen.insert(id).inserted else { throw SessionStoreError.decodingFailed }
                        var item = value
                        if table == "records" {
                            for (field,child) in [("summaryEntries","occurrences"),("summaryRevisions","source_revisions"),("summaryRun","processing_receipts")] {
                                if let nested = item.removeValue(forKey:field) {
                                    if let values=nested as? [[String:Any]],field != "summaryRun" {
                                        item["_sqlite_"+field]=true
                                        for (index,value) in values.enumerated() {
                                            let identity=field == "summaryEntries" ? (value["id"] as? String ?? String(index)):String(index)
                                            collections[child,default:[]].append((id+"/"+identity,value))
                                        }
                                    }else{collections[child,default:[]].append((id,nested))}
                                }
                            }
                        }
                        return (id,item)
                    }
                }
                if let receipt=object.removeValue(forKey:"recordUpdate") {collections["processing_receipts",default:[]].append(("update",receipt))}
                collections["metadata"] = [("envelope",object)]
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for table in tables {
                    let values = collections[table] ?? []
                    var remaining = Set(try rows(db,table:table).map(\.0))
                    for (position,pair) in values.enumerated() {
                        let payload = String(decoding:try JSONSerialization.data(withJSONObject:pair.1,options:[.sortedKeys,.fragmentsAllowed]),as:UTF8.self)
                        var statement: OpaquePointer?
                        let sql = "INSERT INTO \(table)(id,position,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET position=excluded.position,payload=excluded.payload WHERE position<>excluded.position OR payload<>excluded.payload"
                        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK else { throw SessionStoreError.encodingFailed }
                        defer { sqlite3_finalize(statement) }
                        sqlite3_bind_text(statement,1,pair.0,-1,transient); sqlite3_bind_int64(statement,2,Int64(position)); sqlite3_bind_text(statement,3,payload,-1,transient)
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw SessionStoreError.ioFailed("Could not save record.") }
                        remaining.remove(pair.0)
                    }
                    for id in remaining {
                        var statement: OpaquePointer?
                        guard sqlite3_prepare_v2(db,"DELETE FROM \(table) WHERE id=?",-1,&statement,nil) == SQLITE_OK else { throw SessionStoreError.encodingFailed }
                        defer { sqlite3_finalize(statement) }
                        sqlite3_bind_text(statement,1,id,-1,transient)
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw SessionStoreError.ioFailed("Could not remove record.") }
                    }
                }
                // Verify the full reconstructed envelope, including source text and patient preferences, before commit.
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard let roundTrip = try read(db), try decoder.decode(SessionsEnvelope.self,from:roundTrip) == decoder.decode(SessionsEnvelope.self,from:data) else { throw SessionStoreError.decodingFailed }
                try execute(db,"PRAGMA user_version=1")
                try execute(db,"COMMIT")
            } catch { try? execute(db,"ROLLBACK"); throw error }
        }
    }
}
