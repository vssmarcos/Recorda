import Foundation
import GRDB
import ZIPFoundation
import RecordaCore

public struct PackageExportOptions: Sendable {
    /// Baralho a exportar (com sub-baralhos). `nil` = todos.
    public var deckID: DeckID?
    /// Restringe a exportação a estas notas (ex.: seleção do navegador).
    public var noteIDs: [NoteID]?
    public var includeScheduling: Bool = false
    public var includeMedia: Bool = true
    public init(deckID: DeckID? = nil, noteIDs: [NoteID]? = nil, includeScheduling: Bool = false, includeMedia: Bool = true) {
        self.deckID = deckID; self.noteIDs = noteIDs
        self.includeScheduling = includeScheduling; self.includeMedia = includeMedia
    }
}

public struct PackageExportSummary: Sendable, Equatable {
    public var notes = 0
    public var cards = 0
    public var mediaFiles = 0
}

public enum PackageExporter {

    // MARK: Esquema legado

    static let legacySchema = """
    CREATE TABLE col (
        id integer PRIMARY KEY, crt integer NOT NULL, mod integer NOT NULL, scm integer NOT NULL,
        ver integer NOT NULL, dty integer NOT NULL, usn integer NOT NULL, ls integer NOT NULL,
        conf text NOT NULL, models text NOT NULL, decks text NOT NULL, dconf text NOT NULL, tags text NOT NULL
    );
    CREATE TABLE notes (
        id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL, mod integer NOT NULL,
        usn integer NOT NULL, tags text NOT NULL, flds text NOT NULL, sfld integer NOT NULL,
        csum integer NOT NULL, flags integer NOT NULL, data text NOT NULL
    );
    CREATE TABLE cards (
        id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL, ord integer NOT NULL,
        mod integer NOT NULL, usn integer NOT NULL, type integer NOT NULL, queue integer NOT NULL,
        due integer NOT NULL, ivl integer NOT NULL, factor integer NOT NULL, reps integer NOT NULL,
        lapses integer NOT NULL, left integer NOT NULL, odue integer NOT NULL, odid integer NOT NULL,
        flags integer NOT NULL, data text NOT NULL
    );
    CREATE TABLE revlog (
        id integer PRIMARY KEY, cid integer NOT NULL, usn integer NOT NULL, ease integer NOT NULL,
        ivl integer NOT NULL, lastIvl integer NOT NULL, factor integer NOT NULL, time integer NOT NULL,
        type integer NOT NULL
    );
    CREATE TABLE graves (usn integer NOT NULL, oid integer NOT NULL, type integer NOT NULL);
    CREATE INDEX ix_notes_usn ON notes (usn);
    CREATE INDEX ix_cards_usn ON cards (usn);
    CREATE INDEX ix_revlog_usn ON revlog (usn);
    CREATE INDEX ix_cards_nid ON cards (nid);
    CREATE INDEX ix_cards_sched ON cards (did, queue, due);
    CREATE INDEX ix_revlog_cid ON revlog (cid);
    CREATE INDEX ix_notes_csum ON notes (csum);
    """

    // MARK: Conversão para JSON legado

    static func legacyJSON(_ notetype: Notetype) -> [String: Any] {
        let fields: [[String: Any]] = notetype.fields.map { field in
            var object: [String: Any] = [
                "name": field.name, "ord": field.ord, "sticky": field.sticky, "rtl": field.rtl,
                "font": field.fontName, "size": field.fontSize, "description": field.description,
                "plainText": field.plainText, "collapsed": false, "excludeFromSearch": false,
                "preventDeletion": false, "media": [String](),
            ]
            if let tag = field.tag { object["tag"] = tag }
            return object
        }
        let templates: [[String: Any]] = notetype.templates.map { template in
            [
                "name": template.name, "ord": template.ord, "qfmt": template.qfmt, "afmt": template.afmt,
                "bqfmt": template.browserQfmt, "bafmt": template.browserAfmt,
                "did": template.targetDeckID == 0 ? NSNull() : NSNumber(value: template.targetDeckID),
                "bfont": "", "bsize": 0,
            ]
        }
        return [
            "id": notetype.id, "name": notetype.name, "type": notetype.config.kind.rawValue,
            "mod": notetype.mtimeSecs, "usn": -1, "sortf": notetype.config.sortFieldIdx, "did": NSNull(),
            "tmpls": templates, "flds": fields, "css": notetype.config.css,
            "latexPre": notetype.config.latexPre, "latexPost": notetype.config.latexPost,
            "latexsvg": notetype.config.latexSvg, "req": [Any](),
            "originalStockKind": WireEnums.raw(notetype.config.originalStockKind),
        ]
    }

    static func legacyJSON(_ deck: Deck) -> [String: Any] {
        var object: [String: Any] = [
            "id": deck.id, "mod": deck.mtimeSecs, "name": deck.name, "usn": -1,
            "lrnToday": [0, 0], "revToday": [0, 0], "newToday": [0, 0], "timeToday": [0, 0],
            "collapsed": deck.common.collapsed, "browserCollapsed": deck.common.browserCollapsed,
            "desc": deck.common.desc,
        ]
        switch deck.kind {
        case .normal(let normal):
            object["dyn"] = 0
            object["conf"] = normal.configID
            object["extendNew"] = 0
            object["extendRev"] = 0
            if let limit = normal.newLimit { object["newLimit"] = limit }
            if let limit = normal.reviewLimit { object["reviewLimit"] = limit }
        case .filtered(let filtered):
            object["dyn"] = 1
            object["resched"] = filtered.reschedule
            object["terms"] = filtered.terms.map { [$0.search, $0.limit, $0.order.rawValue] as [Any] }
            object["separate"] = true
            object["delays"] = NSNull()
            object["previewDelay"] = 10
            object["previewAgainSecs"] = filtered.previewAgainSecs
            object["previewHardSecs"] = filtered.previewHardSecs
            object["previewGoodSecs"] = filtered.previewGoodSecs
        }
        return object
    }

    static func legacyJSON(_ config: DeckConfig) -> [String: Any] {
        let data = config.config
        var object: [String: Any] = [
            "id": config.id, "mod": config.mtimeSecs, "name": config.name, "usn": -1,
            "maxTaken": data.capAnswerTimeToSecs, "autoplay": !data.disableAutoplay,
            "timer": data.showTimer ? 1 : 0, "replayq": !data.skipQuestionWhenReplayingAnswer, "dyn": false,
            "new": [
                "bury": data.buryNew, "delays": data.learnSteps,
                "initialFactor": Int((data.initialEase * 1000).rounded()),
                "ints": [data.graduatingIntervalGood, data.graduatingIntervalEasy, 0],
                "order": data.newCardInsertOrder == .random ? 0 : 1, "perDay": data.newPerDay,
            ] as [String: Any],
            "rev": [
                "bury": data.buryReviews, "ease4": data.easyMultiplier, "ivlFct": data.intervalMultiplier,
                "maxIvl": data.maximumReviewInterval, "perDay": data.reviewsPerDay,
                "hardFactor": data.hardMultiplier,
            ] as [String: Any],
            "lapse": [
                "delays": data.relearnSteps, "leechAction": data.leechAction == .suspend ? 0 : 1,
                "leechFails": data.leechThreshold, "minInt": data.minimumLapseInterval, "mult": data.lapseMultiplier,
            ] as [String: Any],
        ]
        object["newMix"] = data.newMix.rawValue
        object["interdayLearningMix"] = data.interdayLearningMix.rawValue
        object["reviewOrder"] = WireEnums.raw(data.reviewOrder)
        object["newSortOrder"] = data.newCardSortOrder.rawValue
        object["newGatherPriority"] = WireEnums.raw(data.newCardGatherPriority)
        object["buryInterdayLearning"] = data.buryInterdayLearning
        object["desiredRetention"] = data.desiredRetention
        object["newPerDayMinimum"] = 0
        object["easyDaysPercentages"] = data.easyDaysPercentages
        object["stopTimerOnAnswer"] = data.stopTimerOnAnswer
        object["secondsToShowQuestion"] = data.secondsToShowQuestion
        object["secondsToShowAnswer"] = data.secondsToShowAnswer
        object["questionAction"] = data.questionAction.rawValue
        object["answerAction"] = data.answerAction.rawValue
        object["waitForAudio"] = data.waitForAudio
        object["paramSearch"] = data.paramSearch
        object["newCardsIgnoreReviewLimit"] = data.newCardsIgnoreReviewLimit
        let params = data.fsrsParams
        object["fsrsWeights"] = params.count == 17 ? params : [Double]()
        object["fsrsParams5"] = params.count == 19 ? params : [Double]()
        object["fsrsParams6"] = params.count == 21 ? params : [Double]()
        return object
    }

    static func jsonText(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: Dados a exportar

    struct ExportData {
        var meta: CollectionMeta
        var notes: [Note] = []
        var cards: [Card] = []
        var revlog: [RevlogEntry] = []
        var notetypes: [Notetype] = []
        var decks: [Deck] = []
        var deckConfigs: [DeckConfig] = []
        var config: [String: String] = [:]
        var graves: [Grave] = []
    }

    static func gather(_ txn: Txn, options: PackageExportOptions, fullCollection: Bool) throws -> ExportData {
        var data = ExportData(meta: try txn.meta())
        let db = txn.db

        var conditions: [String] = []
        if !fullCollection, let deckID = options.deckID {
            let ids = Txn.idList(try txn.deckAndChildIDs(deckID))
            conditions.append("(did IN (\(ids)) OR odid IN (\(ids)))")
        }
        var cards = try Card.fetchAll(db, sql: "SELECT * FROM cards" + (conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")))
        if !fullCollection, let noteIDs = options.noteIDs {
            let wanted = Set(noteIDs)
            cards = cards.filter { wanted.contains($0.nid) }
        }

        let allDecks = try txn.allDecks()
        let decksByID = Dictionary(allDecks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        if !fullCollection {
            // Cards em baralhos filtrados são exportados no baralho de origem.
            for index in cards.indices {
                cards[index].removeFromFilteredDeck()
                if cards[index].queue == .preview { cards[index].queue = cards[index].naturalQueue }
            }
            if !options.includeScheduling {
                var position = 0
                var positions: [NoteID: Int] = [:]
                for index in cards.indices {
                    let nid = cards[index].nid
                    if positions[nid] == nil {
                        position += 1
                        positions[nid] = position
                    }
                    cards[index].type = .new
                    cards[index].queue = .new
                    cards[index].due = Int64(positions[nid] ?? position)
                    cards[index].ivl = 0
                    cards[index].factor = 0
                    cards[index].reps = 0
                    cards[index].lapses = 0
                    cards[index].left = 0
                    cards[index].flags = 0
                    cards[index].data = ""
                }
            }
        }
        data.cards = cards

        let noteIDs = Set(cards.map(\.nid))
        if fullCollection {
            data.notes = try Note.fetchAll(db)
        } else {
            for chunk in Array(noteIDs).chunked(500) {
                data.notes += try Note.filter(sql: "id IN (\(Txn.idList(chunk)))").fetchAll(db)
            }
            if !options.includeScheduling {
                for index in data.notes.indices {
                    data.notes[index].removeTag("marked")
                    data.notes[index].removeTag("leech")
                }
            }
        }

        let usedTypes = Set(data.notes.map(\.mid))
        data.notetypes = try txn.allNotetypes().filter { fullCollection || usedTypes.contains($0.id) }

        if fullCollection {
            data.decks = allDecks
            data.deckConfigs = try txn.allDeckConfigs()
            data.revlog = try RevlogEntry.fetchAll(db)
            data.graves = try Grave.fetchAll(db)
            for entry in try ConfigEntry.fetchAll(db) { data.config[entry.key] = entry.val }
        } else {
            var deckIDs = Set(cards.map(\.did))
            for id in Array(deckIDs) {
                if let deck = decksByID[id] {
                    for parent in try txn.parents(of: deck) { deckIDs.insert(parent.id) }
                }
            }
            data.decks = allDecks.filter { deckIDs.contains($0.id) && !$0.isFiltered }
            if options.includeScheduling {
                let configIDs = Set(data.decks.compactMap(\.configID))
                data.deckConfigs = try txn.allDeckConfigs().filter { configIDs.contains($0.id) || $0.id == 1 }
                let cardIDs = cards.map(\.id)
                for chunk in cardIDs.chunked(500) {
                    data.revlog += try RevlogEntry.filter(sql: "cid IN (\(Txn.idList(chunk)))").fetchAll(db)
                }
                for key in [ConfigKey.fsrsEnabled, ConfigKey.rolloverHour, ConfigKey.learnAheadSecs] {
                    if let value = try String.fetchOne(db, sql: "SELECT val FROM config WHERE key = ?", arguments: [key]) {
                        data.config[key] = value
                    }
                }
            } else {
                data.deckConfigs = [DeckConfig(id: 1, name: "Default")]
                for index in data.decks.indices {
                    data.decks[index].normal?.configID = 1
                }
            }
        }
        return data
    }

    /// Grava os dados em um banco SQLite no formato legado (v11).
    static func writeLegacyCollection(_ data: ExportData, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }

        var models: [String: Any] = [:]
        for notetype in data.notetypes { models[String(notetype.id)] = legacyJSON(notetype) }

        var decks: [String: Any] = [:]
        for deck in data.decks { decks[String(deck.id)] = legacyJSON(deck) }
        if decks["1"] == nil {
            // O formato exige a presença do baralho padrão.
            decks["1"] = legacyJSON(Deck(id: 1, name: "Default", mtimeSecs: 0))
        }

        var dconf: [String: Any] = [:]
        for config in data.deckConfigs { dconf[String(config.id)] = legacyJSON(config) }
        if dconf["1"] == nil { dconf["1"] = legacyJSON(DeckConfig(id: 1, name: "Default")) }

        var conf: [String: Any] = [
            "activeDecks": [1], "curDeck": 1, "newSpread": 0, "collapseTime": 1200, "timeLim": 0,
            "estTimes": true, "dueCounts": true, "curModel": NSNull(), "nextPos": 1,
            "sortType": "noteFld", "sortBackwards": false, "addToCur": true, "schedVer": 2, "sched2021": true,
        ]
        for (key, value) in data.config {
            if let bytes = value.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) {
                conf[key] = parsed
            }
        }

        let confText = try jsonText(conf)
        let modelsText = try jsonText(models)
        let decksText = try jsonText(decks)
        let dconfText = try jsonText(dconf)

        try queue.write { db in
            try db.execute(sql: legacySchema)
            try db.execute(sql: """
                INSERT INTO col (id, crt, mod, scm, ver, dty, usn, ls, conf, models, decks, dconf, tags)
                VALUES (1, ?, ?, ?, 11, 0, 0, 0, ?, ?, ?, ?, '{}')
                """, arguments: [data.meta.crt, data.meta.mod, data.meta.scm, confText, modelsText, decksText, dconfText])

            let insertNote = try db.makeStatement(sql: "INSERT INTO notes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            for note in data.notes {
                try insertNote.execute(arguments: [note.id, note.guid, note.mid, note.mod, -1, note.tags, note.flds,
                                                   note.sfld, note.csum, note.flags, note.data])
            }
            let insertCard = try db.makeStatement(sql: "INSERT INTO cards VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            for card in data.cards {
                try insertCard.execute(arguments: [
                    card.id, card.nid, card.did, card.ord, card.mod, -1, card.type.rawValue, card.queue.rawValue,
                    card.due, card.ivl, card.factor, card.reps, card.lapses, card.left, card.odue, card.odid,
                    card.flags, card.data,
                ])
            }
            let insertRevlog = try db.makeStatement(sql: "INSERT INTO revlog VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
            for entry in data.revlog {
                try insertRevlog.execute(arguments: [entry.id, entry.cid, -1, entry.ease, entry.ivl, entry.lastIvl,
                                                     entry.factor, entry.time, entry.type.rawValue])
            }
            for grave in data.graves {
                try db.execute(sql: "INSERT INTO graves VALUES (?, ?, ?)", arguments: [grave.usn, grave.oid, grave.type.rawValue])
            }
        }
    }

    // MARK: Mídia e ZIP

    static func referencedMedia(_ data: ExportData, collection: Collection) -> [String] {
        var names = Set<String>()
        for note in data.notes where note.flds.contains("[sound:") || note.flds.contains("<") {
            for name in HTMLText.mediaReferences(in: note.flds) { names.insert(name.nfc) }
        }
        let files = (try? collection.allMediaFiles()) ?? []
        let underscore = files.filter { $0.hasPrefix("_") }
        for notetype in data.notetypes {
            var sources = [notetype.css]
            for template in notetype.templates { sources += [template.qfmt, template.afmt] }
            for source in sources {
                for name in HTMLText.mediaReferences(in: source) { names.insert(name.nfc) }
                for file in underscore where source.contains(file) { names.insert(file) }
            }
        }
        let onDisk = Set(files)
        return names.filter { onDisk.contains($0) }.sorted()
    }

    static func writeArchive(to destination: URL, workFolder: URL, collectionFile: URL, nativeFile: URL?,
                             mediaNames: [String], collection: Collection) throws {
        try? FileManager.default.removeItem(at: destination)
        let archive = try Archive(url: destination, accessMode: .create)
        try archive.addEntry(with: "collection.anki2", fileURL: collectionFile, compressionMethod: .deflate)
        if let nativeFile {
            try archive.addEntry(with: PackageImporter.nativeEntryName, fileURL: nativeFile, compressionMethod: .deflate)
        }
        var map: [String: String] = [:]
        for (index, name) in mediaNames.enumerated() {
            map[String(index)] = name
            // Imagens e áudio já são comprimidos: armazena sem recomprimir.
            try archive.addEntry(with: String(index), fileURL: collection.mediaURL(for: name), compressionMethod: .none)
        }
        let mapURL = workFolder.appendingPathComponent("media")
        try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]).write(to: mapURL)
        try archive.addEntry(with: "media", fileURL: mapURL, compressionMethod: .deflate)
    }

    // MARK: API pública

    /// Exporta um baralho (ou tudo) como `.apkg`.
    @discardableResult
    public static func exportPackage(from collection: Collection, to destination: URL,
                                     options: PackageExportOptions = PackageExportOptions()) throws -> PackageExportSummary {
        let data = try collection.read { txn in try gather(txn, options: options, fullCollection: false) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("recorda-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let collectionFile = work.appendingPathComponent("collection.anki2")
        try writeLegacyCollection(data, to: collectionFile)
        let media = options.includeMedia ? referencedMedia(data, collection: collection) : []
        try writeArchive(to: destination, workFolder: work, collectionFile: collectionFile, nativeFile: nil,
                         mediaNames: media, collection: collection)
        return PackageExportSummary(notes: data.notes.count, cards: data.cards.count, mediaFiles: media.count)
    }

    /// Exporta a coleção inteira como `.colpkg`.
    /// O pacote leva a coleção no formato legado (compatível com o Anki) e uma cópia nativa sem perdas.
    @discardableResult
    public static func exportCollectionPackage(from collection: Collection, to destination: URL,
                                               includeMedia: Bool) throws -> PackageExportSummary {
        let data = try collection.read { txn in
            try gather(txn, options: PackageExportOptions(includeScheduling: true, includeMedia: includeMedia), fullCollection: true)
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("recorda-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let collectionFile = work.appendingPathComponent("collection.anki2")
        try writeLegacyCollection(data, to: collectionFile)

        let nativeFile = work.appendingPathComponent(PackageImporter.nativeEntryName)
        try collection.writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [nativeFile.path])
        }

        let media = includeMedia ? ((try? collection.allMediaFiles()) ?? []) : []
        try writeArchive(to: destination, workFolder: work, collectionFile: collectionFile, nativeFile: nativeFile,
                         mediaNames: media, collection: collection)
        return PackageExportSummary(notes: data.notes.count, cards: data.cards.count, mediaFiles: media.count)
    }
}
