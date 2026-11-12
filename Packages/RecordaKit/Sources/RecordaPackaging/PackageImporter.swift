import Foundation
import GRDB
import ZIPFoundation
import RecordaCore

public enum NoteUpdatePolicy: Int, Sendable, CaseIterable {
    /// Atualiza a nota existente se a do arquivo for mais recente.
    case ifNewer
    /// Sempre substitui pelo conteúdo do arquivo.
    case always
    /// Nunca altera notas existentes.
    case never
}

public struct PackageImportOptions: Sendable {
    /// Importa agendamento e histórico de revisões (quando o arquivo os contém).
    public var includeScheduling: Bool = true
    public var updateNotes: NoteUpdatePolicy = .ifNewer
    public var includeMedia: Bool = true
    public init() {}
}

public struct PackageImportSummary: Sendable, Equatable {
    public var notesAdded = 0
    public var notesUpdated = 0
    public var notesSkipped = 0
    public var cardsAdded = 0
    public var decksAdded = 0
    public var notetypesAdded = 0
    public var mediaAdded = 0
    public var revlogAdded = 0
    /// Verdadeiro quando a coleção inteira foi substituída (.colpkg).
    public var replacedCollection = false
}

/// Conteúdo extraído de um pacote (.apkg/.colpkg) em uma pasta temporária.
struct ExtractedPackage {
    let folder: URL
    /// Banco no formato do Anki, pronto para abrir.
    let collectionURL: URL?
    /// Cópia nativa do banco do Recorda (presente em backups e exportações completas do próprio app).
    let nativeURL: URL?
    /// Nome do arquivo de mídia → nome da entrada no ZIP.
    let media: [(name: String, entry: String)]
    let mediaCompressed: Bool
    let archiveURL: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: folder)
    }
}

public enum PackageImporter {

    static let nativeEntryName = "recorda.sqlite"

    // MARK: Extração

    static func extract(_ url: URL) throws -> ExtractedPackage {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw PackagingError.invalidPackage("não é um arquivo ZIP válido")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorda-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        func extractEntry(_ name: String) throws -> URL? {
            guard let entry = archive[name] else { return nil }
            let destination = folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
            _ = try archive.extract(entry, to: destination)
            return destination
        }
        func readEntry(_ name: String) throws -> Data? {
            guard let entry = archive[name] else { return nil }
            var data = Data()
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
            return data
        }

        // Versão do pacote (arquivo `meta`, protobuf com o campo 1).
        var packageVersion = 0
        if let meta = try readEntry("meta") {
            packageVersion = ProtoMessage(meta).int(1) ?? 0
            if packageVersion > 3 { throw PackagingError.unsupportedVersion(packageVersion) }
        }

        var collectionURL: URL?
        if let compressed = try extractEntry("collection.anki21b") {
            let plain = folder.appendingPathComponent("collection.sqlite")
            try Zstd.decompressFile(at: compressed, to: plain)
            try? FileManager.default.removeItem(at: compressed)
            collectionURL = plain
        } else if let modern = try extractEntry("collection.anki21") {
            collectionURL = modern
        } else if let legacy = try extractEntry("collection.anki2") {
            collectionURL = legacy
        }
        let nativeURL = try extractEntry(nativeEntryName)
        guard collectionURL != nil || nativeURL != nil else {
            folderCleanup(folder)
            throw PackagingError.invalidPackage("o pacote não contém uma coleção")
        }

        // Mapa de mídia.
        var media: [(String, String)] = []
        var mediaCompressed = false
        if var mediaData = try readEntry("media"), !mediaData.isEmpty {
            if Zstd.isCompressed(mediaData) {
                mediaData = try Zstd.decompress(mediaData)
                mediaCompressed = true
            }
            if let object = try? JSONSerialization.jsonObject(with: mediaData) as? [String: String] {
                // Formato legado: {"0": "imagem.jpg"}
                for (entry, name) in object { media.append((name, entry)) }
            } else {
                // Formato novo: lista protobuf; o índice na lista é o nome da entrada.
                let entries = ProtoMessage(mediaData).messages(1)
                for (index, entry) in entries.enumerated() {
                    guard let name = entry.string(1), !name.isEmpty else { continue }
                    let zipName = entry.int(255).map(String.init) ?? String(index)
                    media.append((name, zipName))
                }
                mediaCompressed = true
            }
        }
        return ExtractedPackage(folder: folder, collectionURL: collectionURL, nativeURL: nativeURL,
                                media: media.map { (name: $0.0, entry: $0.1) }, mediaCompressed: mediaCompressed,
                                archiveURL: url)
    }

    private static func folderCleanup(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Copia os arquivos de mídia do pacote para a pasta da coleção.
    /// Devolve os nomes que precisaram mudar (conflito de conteúdo): original → novo.
    static func importMedia(_ package: ExtractedPackage, into collection: Collection, only wanted: Set<String>?,
                            overwrite: Bool) throws -> (added: Int, renamed: [String: String]) {
        guard !package.media.isEmpty else { return (0, [:]) }
        let archive = try Archive(url: package.archiveURL, accessMode: .read)
        var added = 0
        var renamed: [String: String] = [:]
        for item in package.media {
            let name = item.name.nfc
            if let wanted, !wanted.contains(name) { continue }
            guard let entry = archive[item.entry] else { continue }
            var data = Data()
            _ = try archive.extract(entry) { chunk in data.append(chunk) }
            if package.mediaCompressed && Zstd.isCompressed(data) {
                data = try Zstd.decompress(data)
            }
            let safeName = Collection.sanitizedMediaName(name)
            let target = collection.mediaURL(for: safeName)
            if FileManager.default.fileExists(atPath: target.path) {
                if overwrite {
                    try collection.writeMedia(data: data, exactName: safeName)
                    added += 1
                } else if let existing = try? Data(contentsOf: target), existing != data {
                    let finalName = try collection.addMedia(data: data, preferredName: safeName)
                    if finalName != name { renamed[name] = finalName }
                    added += 1
                }
            } else {
                try collection.writeMedia(data: data, exactName: safeName)
                if safeName != name { renamed[name] = safeName }
                added += 1
            }
        }
        return (added, renamed)
    }

    // MARK: API pública

    /// Detecta o tipo de pacote pela extensão.
    public static func isCollectionPackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "colpkg"
    }

    /// Importa um `.apkg` (mescla) ou `.colpkg` (substitui a coleção).
    public static func importPackage(at url: URL, into collection: Collection,
                                     options: PackageImportOptions = PackageImportOptions()) throws -> PackageImportSummary {
        let package = try extract(url)
        defer { package.cleanup() }
        if isCollectionPackage(url) {
            return try replaceCollection(with: package, in: collection, options: options)
        }
        guard let collectionURL = package.collectionURL else {
            throw PackagingError.invalidPackage("o pacote não contém uma coleção")
        }
        let source = try AnkiSource.open(at: collectionURL)
        defer { try? source.queue.close() }
        return try merge(source, package: package, into: collection, options: options)
    }

    // MARK: Mesclar (.apkg)

    static func notetypeSchemaMatches(_ a: Notetype, _ b: Notetype) -> Bool {
        a.config.kind == b.config.kind
            && a.fields.map { $0.name.lowercased() } == b.fields.map { $0.name.lowercased() }
            && a.templates.map { $0.name.lowercased() } == b.templates.map { $0.name.lowercased() }
    }

    /// Mesma estrutura e mesmo conteúdo (modelos e CSS): pode ser usado no lugar do importado.
    static func notetypeContentMatches(_ a: Notetype, _ b: Notetype) -> Bool {
        notetypeSchemaMatches(a, b)
            && a.templates.map(\.qfmt) == b.templates.map(\.qfmt)
            && a.templates.map(\.afmt) == b.templates.map(\.afmt)
            && a.config.css == b.config.css
            && a.config.sortFieldIdx == b.config.sortFieldIdx
    }

    static func merge(_ source: AnkiSource, package: ExtractedPackage, into collection: Collection,
                      options: PackageImportOptions) throws -> PackageImportSummary {
        var summary = PackageImportSummary()

        // 1. Mídia primeiro (fora da transação do banco), para saber quais nomes mudaram.
        var renamedMedia: [String: String] = [:]
        if options.includeMedia {
            let result = try importMedia(package, into: collection, only: nil, overwrite: false)
            summary.mediaAdded = result.added
            renamedMedia = result.renamed
        }

        // 2. Lê tudo da origem.
        let sourceNotes: [Note] = try source.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, guid, mid, mod, tags, flds FROM notes").map { row in
                Note(id: row["id"], guid: row["guid"], mid: row["mid"], mod: row["mod"], usn: -1,
                     tags: row["tags"] ?? "", flds: row["flds"] ?? "")
            }
        }
        let sourceCards: [Card] = try source.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, nid, did, ord, mod, type, queue, due, ivl, factor, reps, lapses, left, odue, odid, flags, data
                FROM cards
                """).map { row -> Card in
                let type = CardType(rawValue: row["type"] ?? 0) ?? .new
                let queue = CardQueue(rawValue: row["queue"] ?? 0) ?? .new
                return Card(id: row["id"], nid: row["nid"], did: row["did"], ord: row["ord"], mod: row["mod"], usn: -1,
                            type: type, queue: queue, due: row["due"] ?? 0, ivl: row["ivl"] ?? 0, factor: row["factor"] ?? 0,
                            reps: row["reps"] ?? 0, lapses: row["lapses"] ?? 0, left: row["left"] ?? 0,
                            odue: row["odue"] ?? 0, odid: row["odid"] ?? 0, flags: row["flags"] ?? 0, data: row["data"] ?? "")
            }
        }
        var cardsByNote: [NoteID: [Card]] = [:]
        for card in sourceCards { cardsByNote[card.nid, default: []].append(card) }
        let hasScheduling = sourceCards.contains { $0.type != .new }
        let keepScheduling = options.includeScheduling && hasScheduling

        // Diferença de dias entre as duas coleções, para converter vencimentos.
        let sourceRollover = Int(source.config["rollover"] ?? "") ?? 4

        try collection.write { txn in
            let timing = try txn.timing()
            let sourceTiming = SchedTiming.compute(crt: source.crt, now: txn.now, rolloverHour: sourceRollover,
                                                   timeZone: collection.clock.timeZone())
            let dayShift = Int64(timing.today - sourceTiming.today)

            // 3. Predefinições (só com agendamento).
            var configMap: [DeckConfigID: DeckConfigID] = [:]
            if keepScheduling {
                let existing = try txn.allDeckConfigs()
                for imported in source.deckConfigs where imported.id != 1 {
                    if existing.contains(where: { $0.id == imported.id }) {
                        configMap[imported.id] = imported.id
                    } else if let sameName = existing.first(where: { $0.name == imported.name && $0.config == imported.config }) {
                        configMap[imported.id] = sameName.id
                    } else {
                        var copy = imported
                        try txn.saveDeckConfig(&copy)
                        configMap[imported.id] = copy.id
                    }
                }
            }

            // 4. Baralhos: casa por nome; cria os que faltam. Só os que têm cards (ou são ancestrais).
            let usedDeckIDs = Set(sourceCards.map { $0.odid != 0 ? $0.odid : $0.did })
            var deckMap: [DeckID: DeckID] = [:]
            let sourceDecksByID = Dictionary(source.decks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for deckID in usedDeckIDs.sorted() {
                guard let imported = sourceDecksByID[deckID], !imported.isFiltered else { continue }
                if let existing = try txn.deck(named: imported.name), !existing.isFiltered {
                    deckMap[deckID] = existing.id
                    continue
                }
                var name = imported.name
                if try txn.deck(named: name) != nil { name = try txn.availableDeckName(name) }
                var created = try txn.addDeck(named: name)
                created.common.desc = imported.common.desc
                if var normal = created.normal {
                    if keepScheduling, let sourceConfig = imported.configID, let mapped = configMap[sourceConfig] {
                        normal.configID = mapped
                    }
                    created.normal = normal
                }
                try txn.saveDeck(&created)
                deckMap[deckID] = created.id
                summary.decksAdded += 1
            }
            let fallbackDeck = try txn.getOrCreateDeck(named: "Padrão").id

            // 5. Tipos de nota.
            var notetypeMap: [NotetypeID: NotetypeID] = [:]
            var targetNotetypes: [NotetypeID: Notetype] = [:]
            let usedNotetypes = Set(sourceNotes.map(\.mid))
            for imported in source.notetypes where usedNotetypes.contains(imported.id) {
                if let existing = try txn.notetypeIfExists(imported.id) {
                    if notetypeSchemaMatches(existing, imported) {
                        notetypeMap[imported.id] = existing.id
                        if imported.mtimeSecs > existing.mtimeSecs && options.updateNotes != .never {
                            var updated = imported
                            updated.name = existing.name
                            try txn.updateNotetype(updated)
                            targetNotetypes[existing.id] = try txn.notetype(existing.id)
                        } else {
                            targetNotetypes[existing.id] = existing
                        }
                        continue
                    }
                    // Mesmo id, estrutura diferente: procura uma cópia compatível já importada antes.
                    if let twin = try txn.allNotetypes().first(where: {
                        $0.id != existing.id && notetypeContentMatches($0, imported)
                    }) {
                        notetypeMap[imported.id] = twin.id
                        targetNotetypes[twin.id] = twin
                        continue
                    }
                    var copy = imported
                    copy.id = 0
                    try txn.addNotetype(&copy)
                    notetypeMap[imported.id] = copy.id
                    targetNotetypes[copy.id] = copy
                    summary.notetypesAdded += 1
                } else if let same = try txn.allNotetypes().first(where: {
                    $0.name.caseInsensitiveCompare(imported.name) == .orderedSame && notetypeContentMatches($0, imported)
                }) {
                    // Outro id, mas mesmo nome e conteúdo (ex.: tipos padrão criados em cada aparelho).
                    notetypeMap[imported.id] = same.id
                    targetNotetypes[same.id] = same
                } else {
                    var copy = imported
                    // Baralhos de destino dos modelos apontam para ids da origem.
                    for index in copy.config.templates.indices {
                        let target = copy.config.templates[index].targetDeckID
                        copy.config.templates[index].targetDeckID = target == 0 ? 0 : (deckMap[target] ?? 0)
                    }
                    try txn.addNotetype(&copy)
                    notetypeMap[imported.id] = copy.id
                    targetNotetypes[copy.id] = copy
                    summary.notetypesAdded += 1
                }
            }

            // 6. Notas e cards.
            func rewriteMedia(_ fields: String) -> String {
                guard !renamedMedia.isEmpty else { return fields }
                var text = fields
                for (old, new) in renamedMedia where text.contains(old) {
                    text = text.replacingOccurrences(of: old, with: new)
                }
                return text
            }

            func convert(_ source: Card, noteID: NoteID) throws -> Card {
                var card = source
                card.nid = noteID
                card.usn = -1
                card.mod = txn.nowSecs
                // Cards em baralhos filtrados voltam para a origem.
                if card.odid != 0 {
                    card.did = card.odid
                    if card.odue != 0 { card.due = card.odue }
                    card.odid = 0
                    card.odue = 0
                    if card.queue.rawValue >= 0 { card.queue = card.naturalQueue }
                }
                card.did = deckMap[card.did] ?? fallbackDeck
                if keepScheduling {
                    if card.type == .review || card.queue == .dayLearning || (card.type == .relearning && card.due < 1_000_000_000) {
                        card.due += dayShift
                    }
                    if card.queue == .preview { card.queue = card.naturalQueue }
                } else {
                    card.type = .new
                    card.queue = .new
                    card.due = 0
                    card.ivl = 0
                    card.factor = 0
                    card.reps = 0
                    card.lapses = 0
                    card.left = 0
                    card.flags = 0
                    card.data = ""
                }
                return card
            }

            var cardIDMap: [CardID: CardID] = [:]
            var nextCardID = try txn.nextID(in: "cards")
            func freshCardID(preferred: CardID) throws -> CardID {
                if try !(Bool.fetchOne(txn.db, sql: "SELECT EXISTS(SELECT 1 FROM cards WHERE id = ?)", arguments: [preferred]) ?? false) {
                    return preferred
                }
                while try Bool.fetchOne(txn.db, sql: "SELECT EXISTS(SELECT 1 FROM cards WHERE id = ?)", arguments: [nextCardID]) == true {
                    nextCardID += 1
                }
                defer { nextCardID += 1 }
                return nextCardID
            }

            var newPositionBase: Int?
            var allTags = Set<String>()

            for imported in sourceNotes {
                guard let mid = notetypeMap[imported.mid], let notetype = targetNotetypes[mid] else {
                    summary.notesSkipped += 1
                    continue
                }
                var note = imported
                note.mid = mid
                note.flds = rewriteMedia(note.flds)
                if !keepScheduling {
                    note.removeTag("marked")
                    note.removeTag("leech")
                }
                let sourceCardsForNote = (cardsByNote[imported.id] ?? []).sorted { $0.ord < $1.ord }

                let existing = try Note.filter(sql: "guid = ?", arguments: [imported.guid]).fetchOne(txn.db)
                var targetNoteID: NoteID
                var existingOrds = Set<Int>()

                if let existing {
                    targetNoteID = existing.id
                    existingOrds = Set(try Int.fetchAll(txn.db, sql: "SELECT ord FROM cards WHERE nid = ?", arguments: [existing.id]))
                    let shouldUpdate: Bool
                    switch options.updateNotes {
                    case .always: shouldUpdate = true
                    case .never: shouldUpdate = false
                    case .ifNewer: shouldUpdate = imported.mod > existing.mod
                    }
                    if shouldUpdate && existing.mid == mid && (existing.flds != note.flds || existing.tags != note.tags) {
                        var updated = existing
                        updated.flds = note.flds
                        updated.tags = note.tags
                        try txn.updateNote(&updated)
                        summary.notesUpdated += 1
                        existingOrds = Set(try Int.fetchAll(txn.db, sql: "SELECT ord FROM cards WHERE nid = ?", arguments: [existing.id]))
                    } else {
                        summary.notesSkipped += 1
                    }
                    if existing.mid != mid { continue }
                } else {
                    if try Bool.fetchOne(txn.db, sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE id = ?)", arguments: [note.id]) == true {
                        note.id = try txn.nextID(in: "notes")
                    }
                    // Normaliza campos, sfld e csum com o tipo de nota de destino.
                    var values = note.fields.map(\.nfc)
                    if values.count < notetype.fields.count {
                        values += Array(repeating: "", count: notetype.fields.count - values.count)
                    } else if values.count > notetype.fields.count {
                        values = Array(values.prefix(notetype.fields.count))
                    }
                    note.fields = values
                    note.tags = Note.joinTags(note.tagList)
                    note.sfld = Txn.sortFieldValue(values, notetype: notetype)
                    note.csum = Hashing.fieldChecksum(values.first ?? "")
                    note.mod = imported.mod
                    note.usn = -1
                    try note.insert(txn.db)
                    targetNoteID = note.id
                    summary.notesAdded += 1
                }
                allTags.formUnion(note.tagList)

                for sourceCard in sourceCardsForNote where !existingOrds.contains(sourceCard.ord) {
                    var card = try convert(sourceCard, noteID: targetNoteID)
                    if card.type == .new {
                        if newPositionBase == nil { newPositionBase = try txn.reserveNewPositions(sourceNotes.count + 1) }
                        // Mantém a ordem relativa do arquivo para os cards novos.
                        let offset = keepScheduling ? Int(min(max(sourceCard.due, 0), Int64(sourceNotes.count))) : summary.notesAdded
                        card.due = Int64((newPositionBase ?? 1) + offset)
                    }
                    card.id = try freshCardID(preferred: sourceCard.id)
                    try card.insert(txn.db)
                    cardIDMap[sourceCard.id] = card.id
                    existingOrds.insert(card.ord)
                    summary.cardsAdded += 1
                }
            }
            try txn.registerTags(Array(allTags))

            // 7. Histórico de revisões dos cards inseridos.
            if keepScheduling && !cardIDMap.isEmpty {
                let entries: [RevlogEntry] = try source.queue.read { db in
                    try Row.fetchAll(db, sql: "SELECT id, cid, ease, ivl, lastIvl, factor, time, type FROM revlog").compactMap { row -> RevlogEntry? in
                        let cid: Int64 = row["cid"]
                        guard let mapped = cardIDMap[cid] else { return nil }
                        return RevlogEntry(id: row["id"], cid: mapped, usn: -1, ease: row["ease"] ?? 0, ivl: row["ivl"] ?? 0,
                                           lastIvl: row["lastIvl"] ?? 0, factor: row["factor"] ?? 0, time: row["time"] ?? 0,
                                           type: RevlogKind(rawValue: row["type"] ?? 0) ?? .learning)
                    }
                }
                for var entry in entries {
                    while try Bool.fetchOne(txn.db, sql: "SELECT EXISTS(SELECT 1 FROM revlog WHERE id = ?)", arguments: [entry.id]) == true {
                        entry.id += 1
                    }
                    try entry.insert(txn.db)
                    summary.revlogAdded += 1
                }
            }
        }
        return summary
    }

    // MARK: Substituir a coleção (.colpkg)

    static let nativeTables = ["col", "notes", "cards", "revlog", "decks", "deck_config", "notetypes", "tags", "graves", "config"]

    static func replaceCollection(with package: ExtractedPackage, in collection: Collection,
                                  options: PackageImportOptions) throws -> PackageImportSummary {
        var summary = PackageImportSummary()
        summary.replacedCollection = true

        if let nativeURL = package.nativeURL {
            try replaceFromNative(nativeURL, in: collection)
        } else if let collectionURL = package.collectionURL {
            let source = try AnkiSource.open(at: collectionURL)
            defer { try? source.queue.close() }
            try replaceFromAnki(source, in: collection)
        } else {
            throw PackagingError.invalidPackage("o pacote não contém uma coleção")
        }
        if options.includeMedia {
            summary.mediaAdded = try importMedia(package, into: collection, only: nil, overwrite: true).added
        }
        try collection.read { txn in
            summary.notesAdded = try txn.noteCount()
            summary.cardsAdded = try txn.cardCount()
        }
        return summary
    }

    /// Copia todas as tabelas de um banco nativo do Recorda.
    static func replaceFromNative(_ url: URL, in collection: Collection) throws {
        try collection.writer.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS src", arguments: [url.path])
            defer { try? db.execute(sql: "DETACH DATABASE src") }
            try db.inTransaction {
                for table in nativeTables {
                    guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM src.sqlite_master WHERE type = 'table' AND name = ?)",
                                            arguments: [table]) == true else { continue }
                    try db.execute(sql: "DELETE FROM main.\(table)")
                    try db.execute(sql: "INSERT INTO main.\(table) SELECT * FROM src.\(table)")
                }
                let now = Int64(collection.clock.now().timeIntervalSince1970 * 1000)
                // Força sincronização completa após restaurar.
                try db.execute(sql: "UPDATE col SET scm = ?, mod = ?, ls = 0", arguments: [now, now])
                return .commit
            }
        }
    }

    /// Substitui o conteúdo pela coleção no formato do Anki.
    static func replaceFromAnki(_ source: AnkiSource, in collection: Collection) throws {
        let notes: [Row] = try source.queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM notes") }
        let cards: [Row] = try source.queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM cards") }
        let revlog: [Row] = try source.queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM revlog") }

        try collection.write { txn in
            let db = txn.db
            for table in ["notes", "cards", "revlog", "decks", "deck_config", "notetypes", "tags", "graves", "config"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            let nowMs = txn.nowMillis
            try db.execute(sql: "UPDATE col SET crt = ?, scm = ?, mod = ?, usn = 0, ls = 0", arguments: [source.crt, nowMs, nowMs])

            for (key, value) in source.config {
                try ConfigEntry(key: key, usn: -1, mtimeSecs: txn.nowSecs, val: value).save(db)
            }
            // Coleções antigas (agendador v1/v2 sem FSRS) continuam no SM-2 até o usuário optar pelo FSRS.
            if source.config[ConfigKey.fsrsEnabled] == nil {
                try txn.setConfig(ConfigKey.fsrsEnabled, false)
            }

            var configIDs = Set<Int64>()
            for var config in source.deckConfigs {
                config.usn = -1
                try config.save(db)
                configIDs.insert(config.id)
            }
            if !configIDs.contains(1) {
                try DeckConfig(id: 1, name: "Padrão", mtimeSecs: txn.nowSecs).save(db)
            }

            var seenNames = Set<String>()
            for var deck in source.decks {
                var name = deck.name
                var suffix = 2
                while !seenNames.insert(name.lowercased()).inserted {
                    name = "\(deck.name) \(suffix)"
                    suffix += 1
                }
                deck.name = name
                deck.usn = -1
                if var normal = deck.normal, !configIDs.contains(normal.configID) {
                    normal.configID = 1
                    deck.normal = normal
                }
                try deck.save(db)
            }
            if try Deck.fetchCount(db) == 0 {
                try Deck(id: 1, name: "Padrão", mtimeSecs: txn.nowSecs).save(db)
            }

            var notetypesByID: [Int64: Notetype] = [:]
            var seenTypeNames = Set<String>()
            for var notetype in source.notetypes {
                guard !notetype.fields.isEmpty, !notetype.templates.isEmpty else { continue }
                var name = notetype.name
                var suffix = 2
                while !seenTypeNames.insert(name.lowercased()).inserted {
                    name = "\(notetype.name) \(suffix)"
                    suffix += 1
                }
                notetype.name = name
                notetype.usn = -1
                try notetype.save(db)
                notetypesByID[notetype.id] = notetype
            }

            var tags = Set<String>()
            for row in notes {
                var note = Note(id: row["id"], guid: row["guid"] ?? GUID.make(), mid: row["mid"], mod: row["mod"] ?? 0,
                                usn: -1, tags: row["tags"] ?? "", flds: row["flds"] ?? "")
                guard let notetype = notetypesByID[note.mid] else { continue }
                let values = note.fields
                note.tags = Note.joinTags(note.tagList)
                note.sfld = Txn.sortFieldValue(values, notetype: notetype)
                note.csum = Hashing.fieldChecksum(values.first ?? "")
                try note.insert(db)
                tags.formUnion(note.tagList)
            }
            try txn.registerTags(Array(tags))

            for row in cards {
                let card = Card(id: row["id"], nid: row["nid"], did: row["did"], ord: row["ord"] ?? 0, mod: row["mod"] ?? 0,
                                usn: -1, type: CardType(rawValue: row["type"] ?? 0) ?? .new,
                                queue: CardQueue(rawValue: row["queue"] ?? 0) ?? .new, due: row["due"] ?? 0,
                                ivl: row["ivl"] ?? 0, factor: row["factor"] ?? 0, reps: row["reps"] ?? 0,
                                lapses: row["lapses"] ?? 0, left: row["left"] ?? 0, odue: row["odue"] ?? 0,
                                odid: row["odid"] ?? 0, flags: row["flags"] ?? 0, data: row["data"] ?? "")
                try card.insert(db)
            }
            // Cards órfãos (nota ou baralho inexistente) são corrigidos.
            try db.execute(sql: "DELETE FROM cards WHERE nid NOT IN (SELECT id FROM notes)")
            let firstDeck = try Int64.fetchOne(db, sql: "SELECT id FROM decks ORDER BY id LIMIT 1") ?? 1
            try db.execute(sql: "UPDATE cards SET did = ? WHERE did NOT IN (SELECT id FROM decks)", arguments: [firstDeck])
            try db.execute(sql: "UPDATE cards SET odid = 0, odue = 0 WHERE odid != 0 AND odid NOT IN (SELECT id FROM decks)")

            for row in revlog {
                let entry = RevlogEntry(id: row["id"], cid: row["cid"], usn: -1, ease: row["ease"] ?? 0, ivl: row["ivl"] ?? 0,
                                        lastIvl: row["lastIvl"] ?? 0, factor: row["factor"] ?? 0, time: row["time"] ?? 0,
                                        type: RevlogKind(rawValue: row["type"] ?? 0) ?? .learning)
                try entry.insert(db)
            }
        }
    }
}
