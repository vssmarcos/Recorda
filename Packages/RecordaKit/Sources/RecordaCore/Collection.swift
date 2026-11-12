import Foundation
import GRDB

public enum CollectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalidInput(String)
    case deckNameExists(String)
    case filteredDeckCannotHaveChildren
    case lastNotetype
    case lastTemplate
    case lastField
    case noCardsGenerated
    case clozeMissing

    public var description: String {
        switch self {
        case .notFound(let what): return "Não encontrado: \(what)"
        case .invalidInput(let what): return what
        case .deckNameExists(let name): return "Já existe um baralho chamado “\(name)”."
        case .filteredDeckCannotHaveChildren: return "Baralhos filtrados não podem conter outros baralhos."
        case .lastNotetype: return "É preciso manter ao menos um tipo de nota."
        case .lastTemplate: return "O tipo de nota precisa de ao menos um modelo de card."
        case .lastField: return "O tipo de nota precisa de ao menos um campo."
        case .noCardsGenerated: return "Esta nota não geraria nenhum card. Preencha os campos usados na frente do modelo."
        case .clozeMissing: return "Notas de omissão precisam de ao menos uma omissão, como {{c1::texto}}."
        }
    }
}

extension CollectionError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Informações de tempo do agendador para o instante atual.
public struct SchedTiming: Sendable, Equatable {
    /// Epoch em segundos.
    public let now: Int64
    /// Dias decorridos desde a criação da coleção.
    public let today: Int
    /// Epoch (s) em que o próximo dia começa.
    public let nextDayAt: Int64

    public init(now: Int64, today: Int, nextDayAt: Int64) {
        self.now = now; self.today = today; self.nextDayAt = nextDayAt
    }

    public static func compute(crt: Int64, now: Date, rolloverHour: Int, timeZone: TimeZone) -> SchedTiming {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let shift = TimeInterval(rolloverHour * 3600)
        let created = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(crt)).addingTimeInterval(-shift))
        let current = calendar.startOfDay(for: now.addingTimeInterval(-shift))
        let days = calendar.dateComponents([.day], from: created, to: current).day ?? 0
        let nextStart = calendar.date(byAdding: .day, value: 1, to: current) ?? current.addingTimeInterval(86_400)
        return SchedTiming(now: Int64(now.timeIntervalSince1970), today: max(0, days),
                           nextDayAt: Int64(nextStart.timeIntervalSince1970) + Int64(rolloverHour * 3600))
    }

    /// Data (início do dia do agendador) correspondente a um número de dia da coleção.
    public func date(forDay day: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(nextDayAt - 86_400 + Int64(day - today) * 86_400))
    }
}

/// Chaves da tabela `config`.
public enum ConfigKey {
    public static let fsrsEnabled = "fsrs"
    public static let rolloverHour = "rollover"
    public static let learnAheadSecs = "collapseTime"
    public static let nextNewPosition = "nextPos"
    public static let currentDeck = "curDeck"
    public static let currentNotetype = "curModel"
    public static let savedSearches = "savedFilters"
    public static let loadBalancer = "loadBalancerEnabled"
    public static let fuzzEnabled = "fuzzEnabled"
    public static let lastUnburiedDay = "lastUnburied"
    public static let timeboxSecs = "timeLim"
    public static let fsrsShortTermWithSteps = "fsrsShortTermWithStepsEnabled"
    public static let rescheduleOnParamChange = "fsrsReschedule"
}

/// A coleção: banco SQLite + pasta de mídia. Segura para uso entre threads.
public final class Collection: Sendable {
    public let writer: any DatabaseWriter
    public let mediaFolder: URL
    public let databaseURL: URL?
    public let clock: SchedClock

    /// Abre (ou cria) a coleção em `databaseURL`.
    public init(databaseURL: URL, mediaFolder: URL, clock: SchedClock = .system) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLFunctions.register(in: db) }
        self.writer = try DatabasePool(path: databaseURL.path, configuration: configuration)
        self.mediaFolder = mediaFolder
        self.databaseURL = databaseURL
        self.clock = clock
        try bootstrap()
    }

    /// Coleção em memória (testes e pré-visualizações).
    public init(inMemoryWithMediaFolder mediaFolder: URL? = nil, clock: SchedClock = .system) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLFunctions.register(in: db) }
        self.writer = try DatabaseQueue(configuration: configuration)
        let folder = mediaFolder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("recorda-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.mediaFolder = folder
        self.databaseURL = nil
        self.clock = clock
        try bootstrap()
    }

    private func bootstrap() throws {
        try Schema.migrator().migrate(writer)
        try writer.write { db in
            let txn = Txn(db: db, collection: self)
            if try CollectionMeta.fetchOne(db) == nil {
                let now = clock.now()
                // `crt` é alinhado às 4h do dia de criação, como no Anki.
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = clock.timeZone()
                let dayStart = calendar.startOfDay(for: now.addingTimeInterval(-4 * 3600))
                let crt = Int64(dayStart.timeIntervalSince1970) + 4 * 3600
                let ms = Int64(now.timeIntervalSince1970 * 1000)
                try CollectionMeta(id: 1, crt: crt, mod: ms, scm: ms, ver: Schema.version, usn: 0, ls: 0).insert(db)
            }
            if try Deck.fetchCount(db) == 0 {
                try Deck(id: 1, name: "Padrão", mtimeSecs: txn.nowSecs).insert(db)
            }
            if try DeckConfig.fetchCount(db) == 0 {
                try DeckConfig(id: 1, name: "Padrão", mtimeSecs: txn.nowSecs).insert(db)
            }
            if try Notetype.fetchCount(db) == 0 {
                for stock in StockNotetype.allCases {
                    _ = try txn.addStockNotetype(stock)
                }
            }
        }
    }

    // MARK: Acesso

    public func read<T>(_ block: (Txn) throws -> T) throws -> T {
        try writer.read { db in try block(Txn(db: db, collection: self)) }
    }

    /// Executa `block` em uma transação de escrita e atualiza `col.mod`.
    @discardableResult
    public func write<T>(_ block: (Txn) throws -> T) throws -> T {
        try writer.write { db in
            let txn = Txn(db: db, collection: self)
            let result = try block(txn)
            try db.execute(sql: "UPDATE col SET mod = ?", arguments: [txn.nowMillis])
            return result
        }
    }

    public func readAsync<T: Sendable>(_ block: @escaping @Sendable (Txn) throws -> T) async throws -> T {
        try await writer.read { db in try block(Txn(db: db, collection: self)) }
    }

    @discardableResult
    public func writeAsync<T: Sendable>(_ block: @escaping @Sendable (Txn) throws -> T) async throws -> T {
        try await writer.write { db in
            let txn = Txn(db: db, collection: self)
            let result = try block(txn)
            try db.execute(sql: "UPDATE col SET mod = ?", arguments: [txn.nowMillis])
            return result
        }
    }

    /// Fecha o WAL para que o arquivo do banco possa ser copiado com segurança.
    public func checkpoint() throws {
        if let pool = writer as? DatabasePool {
            try pool.writeWithoutTransaction { db in
                _ = try db.checkpoint(.truncate)
            }
        }
    }

    public func close() throws {
        try writer.close()
    }
}

/// Contexto de uma transação: todas as operações de domínio são métodos de `Txn`.
public struct Txn {
    public let db: Database
    public let collection: Collection

    public init(db: Database, collection: Collection) {
        self.db = db
        self.collection = collection
    }

    public var now: Date { collection.clock.now() }
    public var nowSecs: Int64 { Int64(now.timeIntervalSince1970) }
    public var nowMillis: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
    public var mediaFolder: URL { collection.mediaFolder }

    // MARK: Metadados

    public func meta() throws -> CollectionMeta {
        guard let meta = try CollectionMeta.fetchOne(db) else { throw CollectionError.notFound("col") }
        return meta
    }

    public func timing() throws -> SchedTiming {
        let info = try self.meta()
        return SchedTiming.compute(crt: info.crt, now: now, rolloverHour: try rolloverHour(),
                                   timeZone: collection.clock.timeZone())
    }

    /// Marca uma mudança estrutural (exige sincronização completa).
    public func markSchemaModified() throws {
        try db.execute(sql: "UPDATE col SET scm = ?", arguments: [nowMillis])
    }

    /// Gera um id baseado no relógio (ms), garantindo unicidade na tabela.
    public func nextID(in table: String) throws -> Int64 {
        var candidate = nowMillis
        while try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)", arguments: [candidate]) == true {
            candidate += 1
        }
        return candidate
    }

    // MARK: Config

    public func config<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        guard let json = try String.fetchOne(db, sql: "SELECT val FROM config WHERE key = ?", arguments: [key]),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func setConfig<T: Encodable>(_ key: String, _ value: T) throws {
        let data = try JSONEncoder().encode(value)
        let json = String(data: data, encoding: .utf8) ?? "null"
        try ConfigEntry(key: key, usn: -1, mtimeSecs: nowSecs, val: json).save(db)
    }

    public func removeConfig(_ key: String) throws {
        try db.execute(sql: "DELETE FROM config WHERE key = ?", arguments: [key])
    }

    public func fsrsEnabled() throws -> Bool { try config(ConfigKey.fsrsEnabled) ?? true }
    public func rolloverHour() throws -> Int { try config(ConfigKey.rolloverHour) ?? 4 }
    public func learnAheadSecs() throws -> Int { try config(ConfigKey.learnAheadSecs) ?? 1200 }
    public func loadBalancerEnabled() throws -> Bool { try config(ConfigKey.loadBalancer) ?? true }
    public func fuzzEnabled() throws -> Bool { try config(ConfigKey.fuzzEnabled) ?? true }

    /// Reserva `count` posições consecutivas para cards novos e devolve a primeira.
    public func reserveNewPositions(_ count: Int) throws -> Int {
        var next: Int = try config(ConfigKey.nextNewPosition) ?? 0
        if next == 0 {
            let maxDue = try Int.fetchOne(db, sql: "SELECT max(due) FROM cards WHERE type = 0 AND due < 1000000000") ?? 0
            next = maxDue + 1
        }
        try setConfig(ConfigKey.nextNewPosition, next + count)
        return next
    }

    // MARK: Lápides

    public func addGrave(_ oid: Int64, _ kind: GraveKind) throws {
        try Grave(oid: oid, type: kind, usn: -1).save(db)
    }
}
