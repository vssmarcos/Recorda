import Foundation

public enum SyncObjectKind: String, Codable, Sendable, CaseIterable {
    case notetype, deckConfig, deck, note, card, revlog, tag, config
}

public struct SyncKey: Codable, Sendable, Hashable {
    public var kind: SyncObjectKind
    /// Id numérico (como texto) ou, para tags e configurações, a própria chave.
    public var id: String

    public init(kind: SyncObjectKind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// Nome único do registro no servidor.
    public var recordName: String { "\(kind.rawValue)|\(id)" }

    public init?(recordName: String) {
        guard let separator = recordName.firstIndex(of: "|"),
              let kind = SyncObjectKind(rawValue: String(recordName[recordName.startIndex..<separator])) else { return nil }
        self.kind = kind
        self.id = String(recordName[recordName.index(after: separator)...])
    }
}

/// Um objeto da coleção em trânsito.
public struct SyncRecord: Codable, Sendable, Equatable {
    public var key: SyncKey
    /// Momento da última modificação (epoch s; para o revlog, o próprio id em ms).
    public var modified: Int64
    /// Objeto codificado em JSON.
    public var payload: Data

    public init(key: SyncKey, modified: Int64, payload: Data) {
        self.key = key
        self.modified = modified
        self.payload = payload
    }
}

/// Metadados da coleção no servidor.
public struct SyncMeta: Codable, Sendable, Equatable {
    /// Identifica a "linhagem" do esquema: muda a cada alteração estrutural ou envio completo.
    public var schemaModified: Int64
    public var collectionCreated: Int64
    public var lastWriter: String

    public init(schemaModified: Int64, collectionCreated: Int64, lastWriter: String) {
        self.schemaModified = schemaModified
        self.collectionCreated = collectionCreated
        self.lastWriter = lastWriter
    }
}

public struct SyncChanges: Sendable {
    public var changed: [SyncRecord]
    public var deleted: [SyncKey]
    /// Marcador opaco a ser enviado na próxima busca.
    public var token: Data?

    public init(changed: [SyncRecord], deleted: [SyncKey], token: Data?) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
    }
}

public struct SyncMediaChanges: Sendable {
    public var changed: [String]
    public var deleted: [String]
    public var token: Data?

    public init(changed: [String], deleted: [String], token: Data?) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
    }
}

public enum SyncError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// As coleções divergiram estruturalmente: o usuário precisa escolher entre enviar ou baixar tudo.
    case fullSyncRequired
    case notSignedIn
    case network(String)
    case server(String)
    /// O marcador de alterações expirou; é preciso baixar tudo de novo.
    case tokenExpired

    public var description: String {
        switch self {
        case .fullSyncRequired:
            return "As coleções deste aparelho e do iCloud divergiram. Escolha qual delas manter."
        case .notSignedIn:
            return "Entre no iCloud em Ajustes para sincronizar."
        case .network(let why): return "Sem conexão com o iCloud: \(why)"
        case .server(let why): return "Erro do servidor de sincronização: \(why)"
        case .tokenExpired: return "O histórico de alterações expirou; é preciso baixar a coleção novamente."
        }
    }

    public var errorDescription: String? { description }
}

/// Abstração do servidor de sincronização.
///
/// O app fornece uma implementação sobre o CloudKit; um servidor compatível com outro protocolo
/// só precisa implementar esta interface.
public protocol SyncTransport: Sendable {
    /// Metadados remotos, ou `nil` se ainda não existe coleção no servidor.
    func fetchMeta() async throws -> SyncMeta?
    /// Alterações desde o marcador (`nil` = tudo).
    func fetchChanges(since token: Data?) async throws -> SyncChanges
    /// Envia alterações incrementais.
    func push(changed: [SyncRecord], deleted: [SyncKey]) async throws
    /// Atualiza só os metadados.
    func saveMeta(_ meta: SyncMeta) async throws
    /// Apaga tudo no servidor e envia a coleção completa.
    func replaceAll(with records: [SyncRecord], meta: SyncMeta) async throws

    // Mídia
    func fetchMediaChanges(since token: Data?) async throws -> SyncMediaChanges
    func uploadMedia(name: String, fileURL: URL) async throws
    func deleteMedia(name: String) async throws
    /// Baixa o arquivo para um local temporário e devolve a URL, ou `nil` se não existir.
    func downloadMedia(name: String) async throws -> URL?
}

/// Transporte em memória, para testes e pré-visualizações.
public actor InMemorySyncTransport: SyncTransport {
    private var meta: SyncMeta?
    private var records: [SyncKey: (record: SyncRecord, sequence: Int)] = [:]
    private var tombstones: [SyncKey: Int] = [:]
    private var media: [String: (data: Data, sequence: Int)] = [:]
    private var mediaTombstones: [String: Int] = [:]
    private var sequence = 0

    public init() {}

    private func nextSequence() -> Int {
        sequence += 1
        return sequence
    }

    private static func token(_ value: Int) -> Data { Data(String(value).utf8) }
    private static func value(_ token: Data?) -> Int {
        guard let token, let text = String(data: token, encoding: .utf8) else { return 0 }
        return Int(text) ?? 0
    }

    public func fetchMeta() async throws -> SyncMeta? { meta }

    public func fetchChanges(since token: Data?) async throws -> SyncChanges {
        let since = InMemorySyncTransport.value(token)
        let changed = records.values.filter { $0.sequence > since }.sorted { $0.sequence < $1.sequence }.map(\.record)
        let deleted = tombstones.filter { $0.value > since }.map(\.key)
        return SyncChanges(changed: changed, deleted: deleted, token: InMemorySyncTransport.token(sequence))
    }

    public func push(changed: [SyncRecord], deleted: [SyncKey]) async throws {
        for record in changed {
            records[record.key] = (record, nextSequence())
            tombstones[record.key] = nil
        }
        for key in deleted {
            records[key] = nil
            tombstones[key] = nextSequence()
        }
    }

    public func saveMeta(_ meta: SyncMeta) async throws { self.meta = meta }

    public func replaceAll(with newRecords: [SyncRecord], meta: SyncMeta) async throws {
        records = [:]
        tombstones = [:]
        for record in newRecords { records[record.key] = (record, nextSequence()) }
        self.meta = meta
    }

    public func fetchMediaChanges(since token: Data?) async throws -> SyncMediaChanges {
        let since = InMemorySyncTransport.value(token)
        return SyncMediaChanges(changed: media.filter { $0.value.sequence > since }.map(\.key).sorted(),
                                deleted: mediaTombstones.filter { $0.value > since }.map(\.key).sorted(),
                                token: InMemorySyncTransport.token(sequence))
    }

    public func uploadMedia(name: String, fileURL: URL) async throws {
        media[name] = (try Data(contentsOf: fileURL), nextSequence())
        mediaTombstones[name] = nil
    }

    public func deleteMedia(name: String) async throws {
        media[name] = nil
        mediaTombstones[name] = nextSequence()
    }

    public func downloadMedia(name: String) async throws -> URL? {
        guard let item = media[name] else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        try item.data.write(to: url)
        return url
    }
}
