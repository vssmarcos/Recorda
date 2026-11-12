import XCTest
import GRDB
import ZIPFoundation
import libzstd
import RecordaCore
import RecordaScheduler
@testable import RecordaPackaging

/// Escritor mínimo de protobuf, só para montar arquivos de teste no formato novo.
struct ProtoWriter {
    var data = Data()

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func uint(_ field: Int, _ value: UInt64) {
        varint(UInt64(field << 3))
        varint(value)
    }

    mutating func bool(_ field: Int, _ value: Bool) { uint(field, value ? 1 : 0) }

    mutating func bytes(_ field: Int, _ value: Data) {
        varint(UInt64(field << 3 | 2))
        varint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }

    mutating func float(_ field: Int, _ value: Float) {
        varint(UInt64(field << 3 | 5))
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func packedFloats(_ field: Int, _ values: [Float]) {
        var inner = Data()
        for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { inner.append(contentsOf: $0) } }
        bytes(field, inner)
    }
}

func zstdCompress(_ input: Data) -> Data {
    let bound = ZSTD_compressBound(input.count)
    var output = Data(count: bound)
    let written = output.withUnsafeMutableBytes { out in
        input.withUnsafeBytes { src in
            ZSTD_compress(out.baseAddress, bound, src.baseAddress, input.count, 3)
        }
    }
    precondition(ZSTD_isError(written) == 0)
    return output.prefix(written)
}

final class PackagingTests: XCTestCase {

    var clock: TestClock!
    var source: Collection!
    var workFolder: URL!

    override func setUpWithError() throws {
        clock = TestClock()
        source = try Collection(inMemoryWithMediaFolder: nil, clock: clock.clock)
        try source.write { txn in try txn.setConfig(ConfigKey.fuzzEnabled, false) }
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("recorda-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workFolder)
    }

    func newCollection(daysLater: Double = 0) throws -> Collection {
        let other = TestClock(start: clock.now.addingTimeInterval(daysLater * 86_400))
        let collection = try Collection(inMemoryWithMediaFolder: nil, clock: other.clock)
        try collection.write { txn in try txn.setConfig(ConfigKey.fuzzEnabled, false) }
        return collection
    }

    @discardableResult
    func add(_ collection: Collection, type: String = "Básico", _ fields: [String], deck: String = "Padrão", tags: [String] = []) throws -> (Note, [Card]) {
        try collection.write { txn in
            let notetype = try XCTUnwrap(try txn.notetype(named: type))
            let deckID = try txn.getOrCreateDeck(named: deck).id
            var note = Note(id: 0, guid: "", mid: notetype.id)
            note.fields = fields
            note.tagList = tags
            let cards = try txn.addNote(&note, deckID: deckID)
            return (note, cards)
        }
    }

    /// Popula a coleção de origem: dois baralhos, mídia, um card com histórico.
    func populateSource() throws -> (reviewed: CardID, noteGUIDs: [String]) {
        _ = try source.addMedia(data: Data("PNGDATA".utf8), preferredName: "mapa.png")
        _ = try source.addMedia(data: Data("MP3".utf8), preferredName: "som.mp3")
        _ = try source.addMedia(data: Data("nada".utf8), preferredName: "nao-usado.jpg")

        let (first, firstCards) = try add(source, ["Capital da França <img src=\"mapa.png\">", "Paris [sound:som.mp3]"],
                                          deck: "Geografia::Europa", tags: ["capitais", "marked"])
        let (second, _) = try add(source, type: "Omissão de palavras", ["{{c1::Tóquio}} é a capital do {{c2::Japão}}", ""],
                                  deck: "Geografia::Ásia")
        let (third, _) = try add(source, type: "Básico (e card invertido)", ["um", "one"], deck: "Padrão")

        // Estuda o primeiro card até virar revisão.
        let cardID = firstCards[0].id
        try source.write { txn in _ = try txn.answer(cardID: cardID, rating: .good, millisecondsTaken: 3000) }
        clock.advance(seconds: 600)
        try source.write { txn in _ = try txn.answer(cardID: cardID, rating: .good, millisecondsTaken: 2000) }
        return (cardID, [first.guid, second.guid, third.guid])
    }

    // MARK: .apkg

    func testExportAndImportWithoutScheduling() throws {
        let info = try populateSource()
        let url = workFolder.appendingPathComponent("geo.apkg")
        let deckID = try source.read { try XCTUnwrap(try $0.deck(named: "Geografia")).id }
        let exported = try PackageExporter.exportPackage(from: source, to: url, options: PackageExportOptions(deckID: deckID))
        XCTAssertEqual(exported, PackageExportSummary(notes: 2, cards: 3, mediaFiles: 2))

        let target = try newCollection()
        let summary = try PackageImporter.importPackage(at: url, into: target)
        XCTAssertEqual(summary.notesAdded, 2)
        XCTAssertEqual(summary.cardsAdded, 3)
        XCTAssertEqual(summary.mediaAdded, 2)
        XCTAssertEqual(summary.revlogAdded, 0)
        XCTAssertEqual(summary.decksAdded, 2)
        XCTAssertFalse(summary.replacedCollection)

        try target.read { txn in
            XCTAssertEqual(try txn.noteCount(), 2)
            XCTAssertEqual(Set(try txn.allDecks().map(\.name)), ["Geografia", "Geografia::Europa", "Geografia::Ásia", "Padrão"])
            let cards = try Card.fetchAll(txn.db)
            XCTAssertTrue(cards.allSatisfy { $0.type == .new && $0.queue == .new && $0.reps == 0 && $0.ivl == 0 && $0.data.isEmpty })
            XCTAssertEqual(try RevlogEntry.fetchCount(txn.db), 0)

            let note = try XCTUnwrap(try Note.filter(sql: "guid = ?", arguments: [info.noteGUIDs[0]]).fetchOne(txn.db))
            XCTAssertEqual(note.fields, ["Capital da França <img src=\"mapa.png\">", "Paris [sound:som.mp3]"])
            // Sem agendamento, as tags de estado (marked/leech) não viajam.
            XCTAssertEqual(note.tagList, ["capitais"])
            XCTAssertEqual(note.sfld, "Capital da França mapa.png")
            let europe = try XCTUnwrap(try txn.deck(named: "Geografia::Europa"))
            XCTAssertEqual(try txn.cards(ofNote: note.id).map(\.did), [europe.id])

            let cloze = try XCTUnwrap(try Note.filter(sql: "guid = ?", arguments: [info.noteGUIDs[1]]).fetchOne(txn.db))
            XCTAssertEqual(try txn.cards(ofNote: cloze.id).map(\.ord), [0, 1])
            // O tipo de nota já existia com a mesma estrutura: não é duplicado.
            XCTAssertEqual(try txn.allNotetypes().count, 6)
        }
        XCTAssertEqual(try target.allMediaFiles(), ["mapa.png", "som.mp3"])
        XCTAssertEqual(try Data(contentsOf: target.mediaURL(for: "mapa.png")), Data("PNGDATA".utf8))
    }

    func testExportedPackageHasLegacyLayout() throws {
        _ = try populateSource()
        let url = workFolder.appendingPathComponent("tudo.apkg")
        try PackageExporter.exportPackage(from: source, to: url, options: PackageExportOptions(includeScheduling: true))
        let archive = try Archive(url: url, accessMode: .read)
        XCTAssertNotNil(archive["collection.anki2"])
        XCTAssertNotNil(archive["media"])
        XCTAssertNotNil(archive["0"])
        XCTAssertNil(archive[PackageImporter.nativeEntryName])

        // O banco legado tem a linha `col` com JSON de modelos, baralhos e predefinições.
        let package = try PackageImporter.extract(url)
        defer { package.cleanup() }
        let reader = try AnkiSource.open(at: try XCTUnwrap(package.collectionURL))
        XCTAssertEqual(reader.schemaVersion, 11)
        XCTAssertEqual(reader.notetypes.count, 3)
        XCTAssertTrue(reader.decks.contains { $0.name == "Geografia::Europa" })
        XCTAssertTrue(reader.decks.contains { $0.id == 1 })
        XCTAssertEqual(reader.deckConfigs.first { $0.id == 1 }?.config.learnSteps, [1, 10])
        XCTAssertEqual(reader.config["schedVer"], "2")
        XCTAssertEqual(Set(package.media.map(\.name)), ["mapa.png", "som.mp3"])
        let ver = try reader.queue.read { db in try Int.fetchOne(db, sql: "SELECT ver FROM col") }
        XCTAssertEqual(ver, 11)
        try reader.queue.close()
    }

    func testImportWithSchedulingShiftsDueDates() throws {
        let info = try populateSource()
        let before = try source.read { try $0.card(info.reviewed) }
        XCTAssertEqual(before.type, .review)
        XCTAssertEqual(before.ivl, 2)
        XCTAssertEqual(before.due, 2)

        let url = workFolder.appendingPathComponent("agendado.apkg")
        try PackageExporter.exportPackage(from: source, to: url, options: PackageExportOptions(includeScheduling: true))

        // A coleção de destino "nasce" um dia depois: o dia 2 da origem é o dia 1 do destino.
        let target = try newCollection(daysLater: 1)
        let summary = try PackageImporter.importPackage(at: url, into: target)
        XCTAssertEqual(summary.notesAdded, 3)
        XCTAssertEqual(summary.cardsAdded, 5)
        XCTAssertEqual(summary.revlogAdded, 2)

        try target.read { txn in
            let note = try XCTUnwrap(try Note.filter(sql: "guid = ?", arguments: [info.noteGUIDs[0]]).fetchOne(txn.db))
            let card = try XCTUnwrap(try txn.cards(ofNote: note.id).first)
            XCTAssertEqual(card.type, .review)
            XCTAssertEqual(card.ivl, 2)
            XCTAssertEqual(card.due, 1)
            XCTAssertEqual(card.reps, 2)
            XCTAssertEqual(card.cardData.s ?? 0, before.cardData.s ?? -1, accuracy: 1e-9)
            XCTAssertTrue(note.hasTag("marked"))
            XCTAssertEqual(try Int.fetchAll(txn.db, sql: "SELECT ease FROM revlog WHERE cid = ? ORDER BY id", arguments: [card.id]), [3, 3])
        }
    }

    func testReimportDoesNotDuplicateAndRespectsUpdatePolicy() throws {
        let info = try populateSource()
        let url = workFolder.appendingPathComponent("v1.apkg")
        try PackageExporter.exportPackage(from: source, to: url)
        let target = try newCollection()
        _ = try PackageImporter.importPackage(at: url, into: target)

        let again = try PackageImporter.importPackage(at: url, into: target)
        XCTAssertEqual(again.notesAdded, 0)
        XCTAssertEqual(again.cardsAdded, 0)
        XCTAssertEqual(again.notesSkipped, 3)
        XCTAssertEqual(try target.read { try $0.noteCount() }, 3)

        // Edita na origem (mais tarde) e exporta de novo.
        clock.advance(seconds: 3600)
        try source.write { txn in
            var note = try XCTUnwrap(try Note.filter(sql: "guid = ?", arguments: [info.noteGUIDs[2]]).fetchOne(txn.db))
            note.fields = ["um (editado)", "one"]
            try txn.updateNote(&note)
        }
        let second = workFolder.appendingPathComponent("v2.apkg")
        try PackageExporter.exportPackage(from: source, to: second)

        var never = PackageImportOptions()
        never.updateNotes = .never
        XCTAssertEqual(try PackageImporter.importPackage(at: second, into: target, options: never).notesUpdated, 0)
        let updated = try PackageImporter.importPackage(at: second, into: target)
        XCTAssertEqual(updated.notesUpdated, 1)
        XCTAssertEqual(updated.notesAdded, 0)
        let fields = try target.read { txn in
            try XCTUnwrap(try Note.filter(sql: "guid = ?", arguments: [info.noteGUIDs[2]]).fetchOne(txn.db)).fields
        }
        XCTAssertEqual(fields, ["um (editado)", "one"])
    }

    func testNotetypeWithSameIDButDifferentFieldsIsCopied() throws {
        _ = try add(source, ["frente", "verso"])
        let target = try newCollection()
        // No destino, o tipo "Básico" com o mesmo id ganha um campo extra.
        let basicID = try source.read { try XCTUnwrap(try $0.notetype(named: "Básico")).id }
        try target.write { txn in
            // Garante o mesmo id nos dois lados (as coleções de teste nascem em instantes diferentes).
            var local = try XCTUnwrap(try txn.notetype(named: "Básico"))
            try txn.db.execute(sql: "UPDATE notetypes SET id = ? WHERE id = ?", arguments: [basicID, local.id])
            local = try txn.notetype(basicID)
            local.config.fields.append(NoteField(ord: 2, name: "Extra"))
            try txn.updateNotetype(local, fieldOrigins: [0, 1, nil])
        }
        let url = workFolder.appendingPathComponent("conflito.apkg")
        try PackageExporter.exportPackage(from: source, to: url)
        let summary = try PackageImporter.importPackage(at: url, into: target)
        XCTAssertEqual(summary.notetypesAdded, 1)
        try target.read { txn in
            let note = try XCTUnwrap(try Note.fetchOne(txn.db))
            XCTAssertNotEqual(note.mid, basicID)
            XCTAssertEqual(try txn.notetype(note.mid).fieldNames, ["Frente", "Verso"])
            XCTAssertEqual(note.fields, ["frente", "verso"])
        }
        // Importar de novo reaproveita a cópia em vez de criar outra.
        let again = try PackageImporter.importPackage(at: url, into: target)
        XCTAssertEqual(again.notetypesAdded, 0)
    }

    func testMediaNameConflictRewritesReferences() throws {
        _ = try source.addMedia(data: Data("ORIGEM".utf8), preferredName: "foto.jpg")
        let (note, _) = try add(source, ["<img src=\"foto.jpg\">", "x"])
        let url = workFolder.appendingPathComponent("midia.apkg")
        try PackageExporter.exportPackage(from: source, to: url)

        let target = try newCollection()
        _ = try target.addMedia(data: Data("DESTINO".utf8), preferredName: "foto.jpg")
        let summary = try PackageImporter.importPackage(at: url, into: target)
        XCTAssertEqual(summary.mediaAdded, 1)
        let imported = try target.read { txn in
            try XCTUnwrap(try Note.filter(sql: "guid = ?", arguments: [note.guid]).fetchOne(txn.db))
        }
        let reference = try XCTUnwrap(HTMLText.mediaReferences(in: imported.flds).first)
        XCTAssertNotEqual(reference, "foto.jpg")
        XCTAssertEqual(try Data(contentsOf: target.mediaURL(for: reference)), Data("ORIGEM".utf8))
        XCTAssertEqual(try Data(contentsOf: target.mediaURL(for: "foto.jpg")), Data("DESTINO".utf8))
    }

    // MARK: .colpkg

    func testCollectionPackageRoundTripIsLossless() throws {
        let info = try populateSource()
        try source.write { txn in
            var preset = try txn.deckConfig(1)
            preset.config.newPerDay = 33
            preset.config.desiredRetention = 0.87
            preset.config.fsrsParams = FSRS.defaultParameters
            try txn.saveDeckConfig(&preset)
            var config = FilteredDeck()
            config.terms = [FilteredSearchTerm(search: "is:review", limit: 10, order: .due)]
            try txn.createFilteredDeck(named: "Sessão", config: config)
            try txn.setConfig(ConfigKey.rolloverHour, 3)
        }
        let url = workFolder.appendingPathComponent("tudo.colpkg")
        let exported = try PackageExporter.exportCollectionPackage(from: source, to: url, includeMedia: true)
        XCTAssertEqual(exported.notes, 3)
        XCTAssertEqual(exported.mediaFiles, 3)

        let target = try newCollection(daysLater: 4)
        _ = try add(target, ["será substituída", "x"])
        let summary = try PackageImporter.importPackage(at: url, into: target)
        XCTAssertTrue(summary.replacedCollection)
        XCTAssertEqual(summary.notesAdded, 3)
        XCTAssertEqual(summary.mediaAdded, 3)

        let sourceMeta = try source.read { try $0.meta() }
        try target.read { txn in
            XCTAssertEqual(try txn.meta().crt, sourceMeta.crt)
            XCTAssertNotEqual(try txn.meta().scm, sourceMeta.scm)
            XCTAssertEqual(try txn.deckConfig(1).config.newPerDay, 33)
            XCTAssertEqual(try txn.deckConfig(1).config.desiredRetention, 0.87)
            XCTAssertEqual(try txn.rolloverHour(), 3)
            let session = try XCTUnwrap(try txn.deck(named: "Sessão"))
            XCTAssertEqual(session.filtered?.terms.first?.search, "is:review")
            // O card revisado continua dentro do baralho filtrado, com o vencimento original guardado.
            let card = try txn.card(info.reviewed)
            XCTAssertEqual(card.did, session.id)
            XCTAssertEqual(card.odue, 2)
            XCTAssertEqual(try RevlogEntry.fetchCount(txn.db), 2)
            XCTAssertEqual(try txn.noteCount(), 3)
        }
        XCTAssertEqual(try target.allMediaFiles().count, 3)
    }

    func testLegacyCollectionReplacePath() throws {
        let info = try populateSource()
        let data = try source.read { txn in
            try PackageExporter.gather(txn, options: PackageExportOptions(includeScheduling: true), fullCollection: true)
        }
        let file = workFolder.appendingPathComponent("collection.anki2")
        try PackageExporter.writeLegacyCollection(data, to: file)

        let target = try newCollection(daysLater: 2)
        let reader = try AnkiSource.open(at: file)
        try PackageImporter.replaceFromAnki(reader, in: target)
        try reader.queue.close()

        try target.read { txn in
            XCTAssertEqual(try txn.noteCount(), 3)
            XCTAssertEqual(try txn.cardCount(), 5)
            XCTAssertEqual(Set(try txn.allDecks().map(\.name)), ["Geografia", "Geografia::Europa", "Geografia::Ásia", "Padrão"])
            let card = try txn.card(info.reviewed)
            XCTAssertEqual(card.type, .review)
            // Mesma data de criação da coleção: os dias de vencimento não mudam.
            XCTAssertEqual(card.due, 2)
            XCTAssertEqual(try txn.timing().today, 2)
            XCTAssertTrue(try txn.fsrsEnabled())
            XCTAssertEqual(try txn.allNotetypes().count, 6)
            let note = try txn.note(card.nid)
            XCTAssertEqual(note.sfld, "Capital da França mapa.png")
        }
    }

    // MARK: Formato novo (zstd + protobuf)

    func testZstdRoundTrip() throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        let compressed = zstdCompress(payload)
        XCTAssertTrue(Zstd.isCompressed(compressed))
        XCTAssertFalse(Zstd.isCompressed(payload))
        XCTAssertEqual(try Zstd.decompress(compressed), payload)

        let input = workFolder.appendingPathComponent("in.zst")
        let output = workFolder.appendingPathComponent("out.bin")
        try compressed.write(to: input)
        try Zstd.decompressFile(at: input, to: output)
        XCTAssertEqual(try Data(contentsOf: output), payload)
        XCTAssertThrowsError(try Zstd.decompress(Data([0x28, 0xB5, 0x2F, 0xFD, 0xFF, 0xFF, 0xFF])))
    }

    func testProtoReaderDecodesDeckConfig() {
        var writer = ProtoWriter()
        writer.packedFloats(1, [1, 10, 1440])
        writer.packedFloats(2, [10])
        writer.packedFloats(6, FSRS.defaultParameters.map { Float($0) })
        writer.uint(9, 25)
        writer.uint(10, 150)
        writer.float(11, 2.3)
        writer.uint(16, 1000)
        writer.uint(18, 2)
        writer.uint(19, 5)
        writer.uint(21, 1)
        writer.uint(22, 6)
        writer.bool(27, true)
        writer.uint(30, 2)
        writer.uint(33, 8)
        writer.uint(34, 5)
        writer.float(37, 0.85)

        let config = AnkiSource.deckConfigData(from: ProtoMessage(writer.data))
        XCTAssertEqual(config.learnSteps, [1, 10, 1440])
        XCTAssertEqual(config.relearnSteps, [10])
        XCTAssertEqual(config.fsrsParams.count, 21)
        XCTAssertEqual(config.fsrsParams[0], 0.212, accuracy: 1e-4)
        XCTAssertEqual(config.newPerDay, 25)
        XCTAssertEqual(config.reviewsPerDay, 150)
        XCTAssertEqual(config.initialEase, 2.3, accuracy: 1e-4)
        XCTAssertEqual(config.maximumReviewInterval, 1000)
        XCTAssertEqual(config.graduatingIntervalGood, 2)
        XCTAssertEqual(config.graduatingIntervalEasy, 5)
        XCTAssertEqual(config.leechAction, .tagOnly)
        XCTAssertEqual(config.leechThreshold, 6)
        XCTAssertTrue(config.buryNew)
        XCTAssertFalse(config.buryReviews)
        XCTAssertEqual(config.newMix, .beforeReviews)
        XCTAssertEqual(config.reviewOrder, .random)
        XCTAssertEqual(config.newCardGatherPriority, .deckThenRandomNotes)
        XCTAssertEqual(config.desiredRetention, 0.85, accuracy: 1e-4)
    }

    /// Monta à mão um pacote no formato novo (coleção v18 comprimida com zstd, mídia em protobuf) e importa.
    func testImportModernPackage() throws {
        let dbURL = workFolder.appendingPathComponent("v18.sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(collation: DatabaseCollation("unicase") { $0.caseInsensitiveCompare($1) })
        }
        let queue = try DatabaseQueue(path: dbURL.path, configuration: configuration)
        let crt = try source.read { try $0.meta().crt }

        var notetypeConfig = ProtoWriter()
        notetypeConfig.uint(1, 0)
        notetypeConfig.string(3, ".card { color: red; }")
        var frontConfig = ProtoWriter()
        frontConfig.string(3, "Helvetica")
        frontConfig.uint(4, 18)
        var templateConfig = ProtoWriter()
        templateConfig.string(1, "{{Pergunta}}")
        templateConfig.string(2, "{{FrontSide}}<hr id=answer>{{Resposta}}")

        var normal = ProtoWriter()
        normal.uint(1, 1)
        var kind = ProtoWriter()
        kind.bytes(1, normal.data)

        var presetConfig = ProtoWriter()
        presetConfig.packedFloats(1, [2, 20])
        presetConfig.uint(9, 12)
        presetConfig.uint(10, 99)

        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE col (id integer PRIMARY KEY, crt integer NOT NULL, mod integer NOT NULL, scm integer NOT NULL,
                    ver integer NOT NULL, dty integer NOT NULL, usn integer NOT NULL, ls integer NOT NULL, conf text NOT NULL,
                    models text NOT NULL, decks text NOT NULL, dconf text NOT NULL, tags text NOT NULL);
                CREATE TABLE notes (id integer PRIMARY KEY, guid text NOT NULL, mid integer NOT NULL, mod integer NOT NULL,
                    usn integer NOT NULL, tags text NOT NULL, flds text NOT NULL, sfld integer NOT NULL, csum integer NOT NULL,
                    flags integer NOT NULL, data text NOT NULL);
                CREATE TABLE cards (id integer PRIMARY KEY, nid integer NOT NULL, did integer NOT NULL, ord integer NOT NULL,
                    mod integer NOT NULL, usn integer NOT NULL, type integer NOT NULL, queue integer NOT NULL, due integer NOT NULL,
                    ivl integer NOT NULL, factor integer NOT NULL, reps integer NOT NULL, lapses integer NOT NULL, left integer NOT NULL,
                    odue integer NOT NULL, odid integer NOT NULL, flags integer NOT NULL, data text NOT NULL);
                CREATE TABLE revlog (id integer PRIMARY KEY, cid integer NOT NULL, usn integer NOT NULL, ease integer NOT NULL,
                    ivl integer NOT NULL, lastIvl integer NOT NULL, factor integer NOT NULL, time integer NOT NULL, type integer NOT NULL);
                CREATE TABLE deck_config (id integer PRIMARY KEY NOT NULL, name text NOT NULL COLLATE unicase,
                    mtime_secs integer NOT NULL, usn integer NOT NULL, config blob NOT NULL);
                CREATE TABLE config (KEY text NOT NULL PRIMARY KEY, usn integer NOT NULL, mtime_secs integer NOT NULL, val blob NOT NULL) WITHOUT ROWID;
                CREATE TABLE fields (ntid integer NOT NULL, ord integer NOT NULL, name text NOT NULL COLLATE unicase,
                    config blob NOT NULL, PRIMARY KEY (ntid, ord)) WITHOUT ROWID;
                CREATE TABLE templates (ntid integer NOT NULL, ord integer NOT NULL, name text NOT NULL COLLATE unicase,
                    mtime_secs integer NOT NULL, usn integer NOT NULL, config blob NOT NULL, PRIMARY KEY (ntid, ord)) WITHOUT ROWID;
                CREATE TABLE notetypes (id integer NOT NULL PRIMARY KEY, name text NOT NULL COLLATE unicase,
                    mtime_secs integer NOT NULL, usn integer NOT NULL, config blob NOT NULL);
                CREATE TABLE decks (id integer PRIMARY KEY NOT NULL, name text NOT NULL COLLATE unicase,
                    mtime_secs integer NOT NULL, usn integer NOT NULL, common blob NOT NULL, kind blob NOT NULL);
                """)
            try db.execute(sql: "INSERT INTO col VALUES (1, ?, 0, 0, 18, 0, 0, 0, '', '', '', '', '')", arguments: [crt])
            try db.execute(sql: "INSERT INTO notetypes VALUES (777, 'Pergunta e resposta', 10, 0, ?)", arguments: [notetypeConfig.data])
            try db.execute(sql: "INSERT INTO fields VALUES (777, 0, 'Pergunta', ?)", arguments: [frontConfig.data])
            try db.execute(sql: "INSERT INTO fields VALUES (777, 1, 'Resposta', ?)", arguments: [Data()])
            try db.execute(sql: "INSERT INTO templates VALUES (777, 0, 'Cartão', 10, 0, ?)", arguments: [templateConfig.data])
            try db.execute(sql: "INSERT INTO decks VALUES (1, 'Default', 0, 0, ?, ?)", arguments: [Data(), kind.data])
            try db.execute(sql: "INSERT INTO decks VALUES (55, ?, 0, 0, ?, ?)", arguments: ["Química\u{1f}Orgânica", Data(), kind.data])
            try db.execute(sql: "INSERT INTO deck_config VALUES (1, 'Default', 0, 0, ?)", arguments: [presetConfig.data])
            try db.execute(sql: "INSERT INTO config VALUES ('rollover', 0, 0, ?)", arguments: [Data("4".utf8)])
            try db.execute(sql: """
                INSERT INTO notes VALUES (9001, 'guid-moderno', 777, 100, 0, ' química ', ?, 'Fórmula da água', 0, 0, '')
                """, arguments: ["Fórmula da água <img src=\"h2o.png\">\u{1f}H₂O"])
            try db.execute(sql: "INSERT INTO cards VALUES (9101, 9001, 55, 0, 100, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, '')")
        }
        try queue.close()

        // Monta o ZIP: meta (versão 3), coleção comprimida, lista de mídia em protobuf e o arquivo "0".
        var meta = ProtoWriter()
        meta.uint(1, 3)
        var entry = ProtoWriter()
        entry.string(1, "h2o.png")
        entry.uint(2, 4)
        var entries = ProtoWriter()
        entries.bytes(1, entry.data)

        func write(_ data: Data, _ name: String) throws -> URL {
            let url = workFolder.appendingPathComponent("zip-" + name)
            try data.write(to: url)
            return url
        }
        let packageURL = workFolder.appendingPathComponent("moderno.apkg")
        let archive = try Archive(url: packageURL, accessMode: .create)
        try archive.addEntry(with: "meta", fileURL: try write(meta.data, "meta"))
        try archive.addEntry(with: "collection.anki21b", fileURL: try write(zstdCompress(try Data(contentsOf: dbURL)), "col"))
        try archive.addEntry(with: "media", fileURL: try write(zstdCompress(entries.data), "media"))
        try archive.addEntry(with: "0", fileURL: try write(zstdCompress(Data("H2O!".utf8)), "0"))

        let target = try newCollection()
        let summary = try PackageImporter.importPackage(at: packageURL, into: target)
        XCTAssertEqual(summary.notesAdded, 1)
        XCTAssertEqual(summary.cardsAdded, 1)
        XCTAssertEqual(summary.notetypesAdded, 1)
        XCTAssertEqual(summary.mediaAdded, 1)

        try target.read { txn in
            let notetype = try txn.notetype(777)
            XCTAssertEqual(notetype.name, "Pergunta e resposta")
            XCTAssertEqual(notetype.fieldNames, ["Pergunta", "Resposta"])
            XCTAssertEqual(notetype.fields[0].fontName, "Helvetica")
            XCTAssertEqual(notetype.fields[0].fontSize, 18)
            XCTAssertEqual(notetype.templates[0].qfmt, "{{Pergunta}}")
            XCTAssertEqual(notetype.css, ".card { color: red; }")
            let deck = try XCTUnwrap(try txn.deck(named: "Química::Orgânica"))
            let note = try txn.note(9001)
            XCTAssertEqual(note.fields[1], "H₂O")
            XCTAssertEqual(note.tagList, ["química"])
            let card = try txn.card(9101)
            XCTAssertEqual(card.did, deck.id)
            XCTAssertEqual(card.type, .new)
            let rendered = try txn.render(card: card)
            XCTAssertTrue(rendered.answerHTML.contains("H₂O"))
        }
        XCTAssertEqual(try Data(contentsOf: target.mediaURL(for: "h2o.png")), Data("H2O!".utf8))

        // Versões futuras do formato são recusadas com erro claro.
        var future = ProtoWriter()
        future.uint(1, 9)
        let futureURL = workFolder.appendingPathComponent("futuro.apkg")
        let futureArchive = try Archive(url: futureURL, accessMode: .create)
        try futureArchive.addEntry(with: "meta", fileURL: try write(future.data, "meta9"))
        XCTAssertThrowsError(try PackageImporter.importPackage(at: futureURL, into: target)) {
            XCTAssertEqual($0 as? PackagingError, .unsupportedVersion(9))
        }
    }

    func testInvalidFilesAreRejected() throws {
        let notZip = workFolder.appendingPathComponent("lixo.apkg")
        try Data("isto não é um zip".utf8).write(to: notZip)
        let target = try newCollection()
        XCTAssertThrowsError(try PackageImporter.importPackage(at: notZip, into: target))

        let empty = workFolder.appendingPathComponent("vazio.apkg")
        let archive = try Archive(url: empty, accessMode: .create)
        let dummy = workFolder.appendingPathComponent("dummy.txt")
        try Data("x".utf8).write(to: dummy)
        try archive.addEntry(with: "leiame.txt", fileURL: dummy)
        XCTAssertThrowsError(try PackageImporter.importPackage(at: empty, into: target))
    }

    func testLegacyDeckConfigJSON() throws {
        let json = """
        {"id": 5, "name": "Antiga", "mod": 9, "usn": 0, "maxTaken": 45, "autoplay": false, "timer": 1, "replayq": true,
         "new": {"perDay": 15, "delays": [1, 5, 30], "ints": [2, 6, 7], "initialFactor": 2300, "order": 0, "bury": true},
         "rev": {"perDay": 80, "ease4": 1.4, "ivlFct": 0.9, "maxIvl": 365, "hardFactor": 1.1, "bury": false},
         "lapse": {"delays": [15], "mult": 0.5, "minInt": 2, "leechFails": 5, "leechAction": 0},
         "desiredRetention": 0.92, "reviewOrder": 3, "newGatherPriority": 2}
        """
        let config = AnkiSource.deckConfig(fromLegacy: try XCTUnwrap(JSONObject(text: json)), fallbackID: 0)
        XCTAssertEqual(config.id, 5)
        XCTAssertEqual(config.name, "Antiga")
        let data = config.config
        XCTAssertEqual(data.newPerDay, 15)
        XCTAssertEqual(data.learnSteps, [1, 5, 30])
        XCTAssertEqual(data.graduatingIntervalGood, 2)
        XCTAssertEqual(data.graduatingIntervalEasy, 6)
        XCTAssertEqual(data.initialEase, 2.3)
        XCTAssertEqual(data.newCardInsertOrder, .random)
        XCTAssertTrue(data.buryNew)
        XCTAssertEqual(data.reviewsPerDay, 80)
        XCTAssertEqual(data.easyMultiplier, 1.4)
        XCTAssertEqual(data.intervalMultiplier, 0.9)
        XCTAssertEqual(data.maximumReviewInterval, 365)
        XCTAssertEqual(data.hardMultiplier, 1.1)
        XCTAssertEqual(data.relearnSteps, [15])
        XCTAssertEqual(data.lapseMultiplier, 0.5)
        XCTAssertEqual(data.minimumLapseInterval, 2)
        XCTAssertEqual(data.leechThreshold, 5)
        XCTAssertEqual(data.leechAction, .suspend)
        XCTAssertEqual(data.capAnswerTimeToSecs, 45)
        XCTAssertTrue(data.showTimer)
        XCTAssertTrue(data.disableAutoplay)
        XCTAssertEqual(data.desiredRetention, 0.92)
        XCTAssertEqual(data.reviewOrder, .intervalsAscending)
        XCTAssertEqual(data.newCardGatherPriority, .highestPosition)

        // Ida e volta pelo JSON legado preserva a predefinição.
        var original = DeckConfig(id: 9, name: "Ida e volta")
        original.config.fsrsParams = FSRS.defaultParameters
        original.config.newCardGatherPriority = .deckThenRandomNotes
        original.config.reviewOrder = .retrievabilityDescending
        original.config.easyDaysPercentages = [1, 1, 0.5, 1, 1, 0, 0]
        original.config.learnSteps = []
        let text = try PackageExporter.jsonText(PackageExporter.legacyJSON(original))
        let back = AnkiSource.deckConfig(fromLegacy: try XCTUnwrap(JSONObject(text: text)), fallbackID: 0)
        XCTAssertEqual(back.config, original.config)
    }

    // MARK: Texto / CSV

    func testCSVParsing() {
        let rows = TextImporter.parseRecords("a;b;c\n\"com ; ponto\";\"aspas \"\"duplas\"\"\";\"duas\nlinhas\"\r\n\n;só segundo;\n", delimiter: ";")
        XCTAssertEqual(rows, [
            ["a", "b", "c"],
            ["com ; ponto", "aspas \"duplas\"", "duas\nlinhas"],
            ["", "só segundo", ""],
        ])
        XCTAssertEqual(TextImporter.parseRecords("um\tdois", delimiter: "\t"), [["um", "dois"]])
    }

    func testPreviewDetectsHeadersAndDelimiter() {
        let text = "#separator:Semicolon\n#html:true\n#notetype:Básico\n#deck:Idiomas::Inglês\n#tags:importado lote1\n#columns:Frente;Verso;Marcadores\n#tags column:3\ncasa;<b>house</b>;substantivo\ncarro;car;\n"
        let preview = TextImporter.preview(text: text)
        XCTAssertEqual(preview.delimiter, ";")
        XCTAssertTrue(preview.isHTML)
        XCTAssertEqual(preview.notetypeName, "Básico")
        XCTAssertEqual(preview.deckName, "Idiomas::Inglês")
        XCTAssertEqual(preview.globalTags, ["importado", "lote1"])
        XCTAssertEqual(preview.columnNames, ["Frente", "Verso", "Marcadores"])
        XCTAssertEqual(preview.tagsColumn, 2)
        XCTAssertEqual(preview.rows, [["casa", "<b>house</b>", "substantivo"], ["carro", "car", ""]])
        XCTAssertEqual(preview.columnCount, 3)
        XCTAssertEqual(TextImporter.suggestedColumns(preview: preview, notetype: Notetype.stock(.basic)), [.field(0), .field(1), .tags])

        let tabbed = TextImporter.preview(text: "gato\tcat\ncão\tdog\n")
        XCTAssertEqual(tabbed.delimiter, "\t")
        XCTAssertFalse(tabbed.isHTML)
        XCTAssertEqual(tabbed.rows.count, 2)
        XCTAssertEqual(TextImporter.preview(text: "a,b\nc,d").delimiter, ",")
        XCTAssertEqual(TextImporter.decode(Data([0xEF, 0xBB, 0xBF]) + Data("olá".utf8)), "olá")
    }

    func testTextImportAddsUpdatesAndSkips() throws {
        let target = try newCollection()
        let (basicID, deckID): (NotetypeID, DeckID) = try target.write { txn in
            (try XCTUnwrap(try txn.notetype(named: "Básico")).id, try txn.getOrCreateDeck(named: "Importados").id)
        }
        var options = TextImportOptions(delimiter: ";", isHTML: false, notetypeID: basicID, deckID: deckID,
                                        columns: [.field(0), .field(1), .tags])
        options.extraTags = ["csv"]
        let rows = [["casa", "house <1>\nlinha", "substantivo imóvel"], ["carro", "car", ""], ["", "", ""], ["", "sem frente", ""]]
        let first = try TextImporter.importRows(rows, into: target, options: options)
        XCTAssertEqual(first, TextImportSummary(added: 2, updated: 0, skippedDuplicates: 0, skippedEmpty: 1, failed: 1))
        try target.read { txn in
            let note = try txn.note(try XCTUnwrap(try txn.duplicateNoteIDs(firstField: "casa", notetypeID: basicID).first))
            // Texto puro é escapado e as quebras viram <br>.
            XCTAssertEqual(note.fields[1], "house &lt;1&gt;<br>linha")
            XCTAssertEqual(note.tagList, ["csv", "imóvel", "substantivo"])
            XCTAssertEqual(try txn.cards(ofNote: note.id).first?.did, deckID)
        }

        // Mesmo primeiro campo: atualiza (padrão), ignora ou duplica conforme a política.
        let changed = [["casa", "home", ""]]
        options.duplicatePolicy = .skip
        XCTAssertEqual(try TextImporter.importRows(changed, into: target, options: options).skippedDuplicates, 1)
        options.duplicatePolicy = .update
        XCTAssertEqual(try TextImporter.importRows(changed, into: target, options: options).updated, 1)
        XCTAssertEqual(try target.read { try $0.noteCount() }, 2)
        options.duplicatePolicy = .keepBoth
        XCTAssertEqual(try TextImporter.importRows(changed, into: target, options: options).added, 1)
        XCTAssertEqual(try target.read { try $0.noteCount() }, 3)
    }

    // MARK: Backups

    func testBackupCreateListPruneAndRestore() throws {
        let info = try populateSource()
        let manager = BackupManager(folder: workFolder.appendingPathComponent("backups"), minimumInterval: 600, maximumCount: 3)
        XCTAssertTrue(manager.list().isEmpty)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try XCTUnwrap(try manager.createIfNeeded(from: source, now: start))
        XCTAssertGreaterThan(first.bytes, 0)
        // Cedo demais para outro backup automático.
        XCTAssertNil(try manager.createIfNeeded(from: source, now: start.addingTimeInterval(60)))
        XCTAssertEqual(manager.list().count, 1)

        // Estraga a coleção e restaura.
        try source.write { txn in try txn.removeNotes(try Int64.fetchAll(txn.db, sql: "SELECT id FROM notes")) }
        XCTAssertEqual(try source.read { try $0.noteCount() }, 0)
        try manager.restore(first, into: source)
        XCTAssertEqual(try source.read { try $0.noteCount() }, 3)
        XCTAssertEqual(try source.read { try $0.card(info.reviewed) }.type, .review)
        // A restauração guarda antes um backup do estado atual.
        XCTAssertEqual(manager.list().count, 2)

        for day in 1...6 {
            _ = try manager.create(from: source, now: start.addingTimeInterval(Double(day) * 86_400))
        }
        XCTAssertLessThanOrEqual(manager.list().count, 3)
        XCTAssertEqual(manager.list().first?.date, start.addingTimeInterval(6 * 86_400))
    }
}
