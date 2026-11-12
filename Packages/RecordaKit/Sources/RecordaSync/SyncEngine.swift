import Foundation
import GRDB
import RecordaCore

public struct SyncOutcome: Sendable, Equatable {
    public enum Mode: String, Sendable { case incremental, fullUpload, fullDownload }
    public var mode: Mode
    public var downloaded = 0
    public var uploaded = 0
    public var deletedLocally = 0
    public var mediaDownloaded = 0
    public var mediaUploaded = 0
}

public enum FullSyncDirection: Sendable { case upload, download }

/// Motor de sincronização baseado em `usn` (-1 = alteração local pendente) e na data de modificação.
///
/// Conflitos por objeto: se o objeto local está pendente e é mais recente que o remoto, o local vence
/// (e será enviado); caso contrário vale o remoto. Exclusões sempre vencem. Mudanças estruturais
/// divergentes (`scm`) exigem sincronização completa em uma direção, escolhida pelo usuário.
public final class SyncEngine: Sendable {
    public let collection: Collection
    public let transport: any SyncTransport
    public let deviceName: String

    /// Chaves de configuração que só existem neste aparelho (não são sincronizadas nem exportadas).
    public static let localPrefix = "_local."
    static let tokenKey = localPrefix + "syncToken"
    static let mediaTokenKey = localPrefix + "syncMediaToken"
    static let syncedSchemaKey = localPrefix + "syncedScm"

    public init(collection: Collection, transport: any SyncTransport, deviceName: String) {
        self.collection = collection
        self.transport = transport
        self.deviceName = deviceName
    }

    // MARK: Estado local

    private struct LocalState: Sendable {
        var schemaModified: Int64
        var created: Int64
        var syncedSchema: Int64?
        var token: Data?
        var mediaToken: Data?
        var hasPendingChanges: Bool
        var isEmpty: Bool
    }

    private func localState() throws -> LocalState {
        try collection.read { txn in
            let meta = try txn.meta()
            let token: String? = try txn.config(SyncEngine.tokenKey)
            let mediaToken: String? = try txn.config(SyncEngine.mediaTokenKey)
            var pending = false
            for table in ["notes", "cards", "revlog", "decks", "deck_config", "notetypes", "graves"] {
                if try Bool.fetchOne(txn.db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE usn = -1)") == true {
                    pending = true
                    break
                }
            }
            return LocalState(
                schemaModified: meta.scm, created: meta.crt,
                syncedSchema: try txn.config(SyncEngine.syncedSchemaKey),
                token: token.flatMap { Data(base64Encoded: $0) },
                mediaToken: mediaToken.flatMap { Data(base64Encoded: $0) },
                hasPendingChanges: pending,
                isEmpty: try txn.cardCount() == 0)
        }
    }

    public var hasPendingChanges: Bool {
        (try? localState().hasPendingChanges) ?? false
    }

    // MARK: Codificação

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Todos os objetos locais (para envio completo) ou só os pendentes.
    private func gather(onlyPending: Bool) throws -> (records: [SyncRecord], deleted: [SyncKey]) {
        try collection.read { txn in
            let db = txn.db
            let filter = onlyPending ? "WHERE usn = -1" : ""
            var records: [SyncRecord] = []
            for item in try Notetype.fetchAll(db, sql: "SELECT * FROM notetypes \(filter)") {
                records.append(SyncRecord(key: SyncKey(kind: .notetype, id: String(item.id)), modified: item.mtimeSecs,
                                          payload: try SyncEngine.encode(item)))
            }
            for item in try DeckConfig.fetchAll(db, sql: "SELECT * FROM deck_config \(filter)") {
                records.append(SyncRecord(key: SyncKey(kind: .deckConfig, id: String(item.id)), modified: item.mtimeSecs,
                                          payload: try SyncEngine.encode(item)))
            }
            for item in try Deck.fetchAll(db, sql: "SELECT * FROM decks \(filter)") {
                records.append(SyncRecord(key: SyncKey(kind: .deck, id: String(item.id)), modified: item.mtimeSecs,
                                          payload: try SyncEngine.encode(item)))
            }
            for item in try Note.fetchAll(db, sql: "SELECT * FROM notes \(filter)") {
                records.append(SyncRecord(key: SyncKey(kind: .note, id: String(item.id)), modified: item.mod,
                                          payload: try SyncEngine.encode(item)))
            }
            for item in try Card.fetchAll(db, sql: "SELECT * FROM cards \(filter)") {
                records.append(SyncRecord(key: SyncKey(kind: .card, id: String(item.id)), modified: item.mod,
                                          payload: try SyncEngine.encode(item)))
            }
            for item in try RevlogEntry.fetchAll(db, sql: "SELECT * FROM revlog \(filter)") {
                records.append(SyncRecord(key: SyncKey(kind: .revlog, id: String(item.id)), modified: item.id / 1000,
                                          payload: try SyncEngine.encode(item)))
            }
            for item in try TagRecord.fetchAll(db, sql: "SELECT * FROM tags \(filter)") {
                records.append(SyncRecord(key: SyncKey(kind: .tag, id: item.tag), modified: 0,
                                          payload: try SyncEngine.encode(item)))
            }
            for item in try ConfigEntry.fetchAll(db, sql: "SELECT * FROM config \(filter)") where !item.key.hasPrefix(SyncEngine.localPrefix) {
                records.append(SyncRecord(key: SyncKey(kind: .config, id: item.key), modified: item.mtimeSecs,
                                          payload: try SyncEngine.encode(item)))
            }
            var deleted: [SyncKey] = []
            if onlyPending {
                for grave in try Grave.fetchAll(db, sql: "SELECT * FROM graves WHERE usn = -1") {
                    let kind: SyncObjectKind
                    switch grave.type {
                    case .card: kind = .card
                    case .note: kind = .note
                    case .deck: kind = .deck
                    case .notetype: kind = .notetype
                    case .deckConfig: kind = .deckConfig
                    }
                    deleted.append(SyncKey(kind: kind, id: String(grave.oid)))
                }
            }
            return (records, deleted)
        }
    }

    // MARK: Aplicar alterações remotas

    private static func table(for kind: SyncObjectKind) -> String {
        switch kind {
        case .notetype: return "notetypes"
        case .deckConfig: return "deck_config"
        case .deck: return "decks"
        case .note: return "notes"
        case .card: return "cards"
        case .revlog: return "revlog"
        case .tag: return "tags"
        case .config: return "config"
        }
    }

    /// Devolve verdadeiro se o registro remoto deve substituir o local.
    private static func remoteWins(db: Database, table: String, idColumn: String, id: some DatabaseValueConvertible,
                                   modColumn: String, remoteModified: Int64) throws -> Bool {
        guard let row = try Row.fetchOne(db, sql: "SELECT usn, \(modColumn) AS m FROM \(table) WHERE \(idColumn) = ?", arguments: [id]) else {
            return true
        }
        let usn: Int = row["usn"]
        let modified: Int64 = row["m"] ?? 0
        if usn == -1 && modified > remoteModified { return false }
        return true
    }

    private func apply(_ changes: SyncChanges, markSynced: Bool = true) throws -> (applied: Int, deleted: Int) {
        var applied = 0
        var deletedCount = 0
        let decoder = JSONDecoder()
        // Ordem de dependência: tipos e baralhos antes de notas e cards.
        let order: [SyncObjectKind: Int] = [.notetype: 0, .deckConfig: 1, .deck: 2, .note: 3, .card: 4, .revlog: 5, .tag: 6, .config: 7]
        let sorted = changes.changed.sorted { (order[$0.key.kind] ?? 9) < (order[$1.key.kind] ?? 9) }

        try collection.write { txn in
            let db = txn.db
            for record in sorted {
                switch record.key.kind {
                case .notetype:
                    var item = try decoder.decode(Notetype.self, from: record.payload)
                    guard try SyncEngine.remoteWins(db: db, table: "notetypes", idColumn: "id", id: item.id,
                                                    modColumn: "mtime_secs", remoteModified: record.modified) else { continue }
                    // Evita colisão de nome com outro tipo de nota local.
                    if let clash = try Notetype.filter(sql: "name = ? COLLATE NOCASE AND id != ?", arguments: [item.name, item.id]).fetchOne(db) {
                        item.name += " (\(clash.id % 1000))"
                    }
                    item.usn = 0
                    try item.save(db)
                case .deckConfig:
                    var item = try decoder.decode(DeckConfig.self, from: record.payload)
                    guard try SyncEngine.remoteWins(db: db, table: "deck_config", idColumn: "id", id: item.id,
                                                    modColumn: "mtime_secs", remoteModified: record.modified) else { continue }
                    item.usn = 0
                    try item.save(db)
                case .deck:
                    var item = try decoder.decode(Deck.self, from: record.payload)
                    guard try SyncEngine.remoteWins(db: db, table: "decks", idColumn: "id", id: item.id,
                                                    modColumn: "mtime_secs", remoteModified: record.modified) else { continue }
                    if let clash = try Deck.filter(sql: "name = ? COLLATE NOCASE AND id != ?", arguments: [item.name, item.id]).fetchOne(db) {
                        // Mesmo nome criado em dois aparelhos: o remoto mantém o nome e o local é renomeado.
                        var renamed = clash
                        renamed.name = clash.name + " (\(clash.id % 1000))"
                        renamed.mtimeSecs = txn.nowSecs
                        renamed.usn = -1
                        try renamed.update(db)
                    }
                    item.usn = 0
                    try item.save(db)
                case .note:
                    var item = try decoder.decode(Note.self, from: record.payload)
                    guard try SyncEngine.remoteWins(db: db, table: "notes", idColumn: "id", id: item.id,
                                                    modColumn: "mod", remoteModified: record.modified) else { continue }
                    item.usn = 0
                    try item.save(db)
                case .card:
                    var item = try decoder.decode(Card.self, from: record.payload)
                    guard try SyncEngine.remoteWins(db: db, table: "cards", idColumn: "id", id: item.id,
                                                    modColumn: "mod", remoteModified: record.modified) else { continue }
                    item.usn = 0
                    try item.save(db)
                case .revlog:
                    var item = try decoder.decode(RevlogEntry.self, from: record.payload)
                    item.usn = 0
                    if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM revlog WHERE id = ?)", arguments: [item.id]) == true { continue }
                    try item.insert(db)
                case .tag:
                    var item = try decoder.decode(TagRecord.self, from: record.payload)
                    item.usn = 0
                    try item.save(db)
                case .config:
                    var item = try decoder.decode(ConfigEntry.self, from: record.payload)
                    if item.key.hasPrefix(SyncEngine.localPrefix) { continue }
                    guard try SyncEngine.remoteWins(db: db, table: "config", idColumn: "key", id: item.key,
                                                    modColumn: "mtime_secs", remoteModified: record.modified) else { continue }
                    item.usn = 0
                    try item.save(db)
                }
                applied += 1
            }

            for key in changes.deleted {
                switch key.kind {
                case .note:
                    guard let id = Int64(key.id) else { continue }
                    try db.execute(sql: "DELETE FROM cards WHERE nid = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM notes WHERE id = ?", arguments: [id])
                case .card, .deckConfig, .notetype, .revlog:
                    guard let id = Int64(key.id) else { continue }
                    try db.execute(sql: "DELETE FROM \(SyncEngine.table(for: key.kind)) WHERE id = ?", arguments: [id])
                case .deck:
                    guard let id = Int64(key.id) else { continue }
                    // Cards que ainda estejam no baralho excluído vão para o baralho padrão.
                    let fallback = try Int64.fetchOne(db, sql: "SELECT id FROM decks WHERE id != ? ORDER BY id LIMIT 1", arguments: [id])
                    if let fallback {
                        try db.execute(sql: "UPDATE cards SET did = ? WHERE did = ?", arguments: [fallback, id])
                        try db.execute(sql: "UPDATE cards SET odid = 0, odue = 0 WHERE odid = ?", arguments: [id])
                        try db.execute(sql: "DELETE FROM decks WHERE id = ?", arguments: [id])
                    }
                case .tag:
                    try db.execute(sql: "DELETE FROM tags WHERE tag = ?", arguments: [key.id])
                case .config:
                    try db.execute(sql: "DELETE FROM config WHERE key = ?", arguments: [key.id])
                }
                if let id = Int64(key.id) {
                    try db.execute(sql: "DELETE FROM graves WHERE oid = ?", arguments: [id])
                }
                deletedCount += 1
            }
            // Notas que ficaram sem tipo (excluído remotamente) não podem permanecer.
            try db.execute(sql: "DELETE FROM cards WHERE nid IN (SELECT id FROM notes WHERE mid NOT IN (SELECT id FROM notetypes))")
            try db.execute(sql: "DELETE FROM notes WHERE mid NOT IN (SELECT id FROM notetypes)")
        }
        return (applied, deletedCount)
    }

    /// Marca como sincronizados os objetos enviados (desde que não tenham mudado de novo no meio-tempo).
    private func markPushed(_ records: [SyncRecord], deleted: [SyncKey]) throws {
        try collection.writer.write { db in
            for record in records {
                let table = SyncEngine.table(for: record.key.kind)
                switch record.key.kind {
                case .tag:
                    try db.execute(sql: "UPDATE tags SET usn = 0 WHERE tag = ? AND usn = -1", arguments: [record.key.id])
                case .config:
                    try db.execute(sql: "UPDATE config SET usn = 0 WHERE key = ? AND usn = -1 AND mtime_secs = ?",
                                   arguments: [record.key.id, record.modified])
                case .revlog:
                    try db.execute(sql: "UPDATE revlog SET usn = 0 WHERE id = ?", arguments: [Int64(record.key.id) ?? 0])
                case .note, .card:
                    try db.execute(sql: "UPDATE \(table) SET usn = 0 WHERE id = ? AND usn = -1 AND mod = ?",
                                   arguments: [Int64(record.key.id) ?? 0, record.modified])
                case .notetype, .deck, .deckConfig:
                    try db.execute(sql: "UPDATE \(table) SET usn = 0 WHERE id = ? AND usn = -1 AND mtime_secs = ?",
                                   arguments: [Int64(record.key.id) ?? 0, record.modified])
                }
            }
            for key in deleted {
                if let id = Int64(key.id) {
                    try db.execute(sql: "DELETE FROM graves WHERE oid = ?", arguments: [id])
                }
            }
        }
    }

    private func saveState(token: Data?, schema: Int64) throws {
        try collection.writer.write { db in
            let txn = Txn(db: db, collection: collection)
            if let token {
                try txn.setConfig(SyncEngine.tokenKey, token.base64EncodedString())
            } else {
                try txn.removeConfig(SyncEngine.tokenKey)
            }
            try txn.setConfig(SyncEngine.syncedSchemaKey, schema)
            try db.execute(sql: "UPDATE col SET ls = ?", arguments: [txn.nowMillis])
            // As chaves locais não devem ficar pendentes de envio.
            try db.execute(sql: "UPDATE config SET usn = 0 WHERE key LIKE '\\_local.%' ESCAPE '\\'")
        }
    }

    // MARK: Sincronização

    /// Sincronização normal. Lança `SyncError.fullSyncRequired` quando é preciso escolher uma direção.
    public func sync() async throws -> SyncOutcome {
        let remoteMeta = try await transport.fetchMeta()
        let state = try localState()

        guard let remoteMeta else {
            // Nada no servidor ainda: primeiro envio.
            return try await fullSync(.upload)
        }

        if state.syncedSchema == nil {
            // Este aparelho nunca sincronizou.
            if state.isEmpty { return try await fullSync(.download) }
            throw SyncError.fullSyncRequired
        }
        let localSchemaChanged = state.schemaModified != state.syncedSchema
        let remoteSchemaChanged = remoteMeta.schemaModified != state.syncedSchema
        if localSchemaChanged && remoteSchemaChanged { throw SyncError.fullSyncRequired }
        if remoteSchemaChanged {
            if state.hasPendingChanges { throw SyncError.fullSyncRequired }
            return try await fullSync(.download)
        }
        if localSchemaChanged {
            // Mudança estrutural só aqui: precisa substituir o conteúdo do servidor.
            throw SyncError.fullSyncRequired
        }

        var outcome = SyncOutcome(mode: .incremental)

        // 1. Baixa e aplica alterações remotas.
        let changes: SyncChanges
        do {
            changes = try await transport.fetchChanges(since: state.token)
        } catch SyncError.tokenExpired {
            if state.hasPendingChanges { throw SyncError.fullSyncRequired }
            return try await fullSync(.download)
        }
        let result = try apply(changes)
        outcome.downloaded = result.applied
        outcome.deletedLocally = result.deleted

        // 2. Envia alterações locais pendentes.
        let pending = try gather(onlyPending: true)
        var token = changes.token
        if !pending.records.isEmpty || !pending.deleted.isEmpty {
            try await transport.push(changed: pending.records, deleted: pending.deleted)
            try markPushed(pending.records, deleted: pending.deleted)
            outcome.uploaded = pending.records.count + pending.deleted.count
            // Avança o marcador para não baixar de volta o que acabou de ser enviado.
            // (Se outro aparelho tiver escrito nesse intervalo, as alterações dele chegam junto e são aplicadas.)
            let echo = try await transport.fetchChanges(since: changes.token)
            let pushedKeys = Set(pending.records.map(\.key))
            let foreign = SyncChanges(changed: echo.changed.filter { !pushedKeys.contains($0.key) },
                                      deleted: echo.deleted.filter { !pending.deleted.contains($0) }, token: echo.token)
            if !foreign.changed.isEmpty || !foreign.deleted.isEmpty {
                let extra = try apply(foreign)
                outcome.downloaded += extra.applied
                outcome.deletedLocally += extra.deleted
            }
            token = echo.token
        }
        try saveState(token: token, schema: remoteMeta.schemaModified)

        // 3. Mídia.
        let media = try await syncMedia(mediaToken: state.mediaToken)
        outcome.mediaDownloaded = media.downloaded
        outcome.mediaUploaded = media.uploaded
        return outcome
    }

    /// Sincronização completa em uma direção.
    public func fullSync(_ direction: FullSyncDirection) async throws -> SyncOutcome {
        switch direction {
        case .upload:
            var outcome = SyncOutcome(mode: .fullUpload)
            let all = try gather(onlyPending: false)
            let state = try localState()
            let meta = SyncMeta(schemaModified: state.schemaModified, collectionCreated: state.created, lastWriter: deviceName)
            try await transport.replaceAll(with: all.records, meta: meta)
            try await collection.writer.write { db in
                for table in ["notes", "cards", "revlog", "decks", "deck_config", "notetypes", "tags", "config"] {
                    try db.execute(sql: "UPDATE \(table) SET usn = 0 WHERE usn = -1")
                }
                try db.execute(sql: "DELETE FROM graves")
            }
            // O marcador passa a apontar para depois do envio.
            let after = try await transport.fetchChanges(since: nil)
            try saveState(token: after.token, schema: meta.schemaModified)
            outcome.uploaded = all.records.count
            // Toda a mídia local sobe.
            try await collection.writer.write { db in
                try db.execute(sql: "UPDATE media_meta SET dirty = 1")
            }
            for name in try collection.allMediaFiles() {
                try await collection.writer.write { db in
                    try db.execute(sql: "INSERT OR IGNORE INTO media_meta (fname, csum, mtime, dirty) VALUES (?, '', 0, 1)", arguments: [name])
                }
            }
            let media = try await syncMedia(mediaToken: nil)
            outcome.mediaUploaded = media.uploaded
            outcome.mediaDownloaded = media.downloaded
            return outcome

        case .download:
            var outcome = SyncOutcome(mode: .fullDownload)
            guard let remoteMeta = try await transport.fetchMeta() else { throw SyncError.server("não há coleção no servidor") }
            let all = try await transport.fetchChanges(since: nil)
            try await collection.writer.write { db in
                for table in ["notes", "cards", "revlog", "decks", "deck_config", "notetypes", "tags", "graves"] {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
                try db.execute(sql: "DELETE FROM config WHERE key NOT LIKE '\\_local.%' ESCAPE '\\'")
                try db.execute(sql: "UPDATE col SET crt = ?, scm = ?", arguments: [remoteMeta.collectionCreated, remoteMeta.schemaModified])
            }
            let result = try apply(SyncChanges(changed: all.changed, deleted: [], token: all.token))
            try collection.write { txn in
                // Uma coleção sempre tem baralho e predefinição padrão.
                if try Deck.fetchCount(txn.db) == 0 { _ = try txn.getOrCreateDeck(named: "Padrão") }
                _ = try txn.deckConfig(1)
                try txn.db.execute(sql: "UPDATE decks SET usn = 0; UPDATE deck_config SET usn = 0")
                try txn.db.execute(sql: "UPDATE col SET scm = ?", arguments: [remoteMeta.schemaModified])
            }
            try saveState(token: all.token, schema: remoteMeta.schemaModified)
            outcome.downloaded = result.applied
            let media = try await syncMedia(mediaToken: nil)
            outcome.mediaDownloaded = media.downloaded
            outcome.mediaUploaded = media.uploaded
            return outcome
        }
    }

    // MARK: Mídia

    private func syncMedia(mediaToken: Data?) async throws -> (downloaded: Int, uploaded: Int) {
        var downloaded = 0
        var uploaded = 0

        // Envia o que mudou localmente.
        let dirty: [String] = try await collection.writer.read { db in
            try String.fetchAll(db, sql: "SELECT fname FROM media_meta WHERE dirty = 1")
        }
        var sent = Set<String>()
        for name in dirty {
            let url = collection.mediaURL(for: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try await transport.uploadMedia(name: name, fileURL: url)
            } else {
                try await transport.deleteMedia(name: name)
            }
            sent.insert(name)
            uploaded += 1
            try await collection.writer.write { db in
                try db.execute(sql: "UPDATE media_meta SET dirty = 0 WHERE fname = ?", arguments: [name])
            }
        }

        // Baixa o que mudou no servidor.
        let changes = try await transport.fetchMediaChanges(since: mediaToken)
        for name in changes.changed where !sent.contains(name) {
            guard let temporary = try await transport.downloadMedia(name: name) else { continue }
            let data = try Data(contentsOf: temporary)
            try? FileManager.default.removeItem(at: temporary)
            let target = collection.mediaURL(for: name)
            if let existing = try? Data(contentsOf: target), existing == data { continue }
            try data.write(to: target, options: .atomic)
            downloaded += 1
        }
        for name in changes.deleted where !sent.contains(name) {
            try? FileManager.default.removeItem(at: collection.mediaURL(for: name))
        }
        let tokenText = changes.token?.base64EncodedString()
        try await collection.writer.write { db in
            let txn = Txn(db: db, collection: self.collection)
            if let tokenText {
                try txn.setConfig(SyncEngine.mediaTokenKey, tokenText)
            } else {
                try txn.removeConfig(SyncEngine.mediaTokenKey)
            }
            try db.execute(sql: "UPDATE config SET usn = 0 WHERE key LIKE '\\_local.%' ESCAPE '\\'")
        }
        return (downloaded, uploaded)
    }
}
