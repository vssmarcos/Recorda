import XCTest
import GRDB
@testable import RecordaCore

final class CollectionTests: XCTestCase {

    var clock: TestClock!
    var collection: Collection!

    override func setUpWithError() throws {
        clock = TestClock()
        collection = try Collection(inMemoryWithMediaFolder: nil, clock: clock.clock)
    }

    func makeNote(_ txn: Txn, type: String, _ fields: [String], tags: [String] = [], deck: DeckID = 1) throws -> (Note, [Card]) {
        let notetype = try XCTUnwrap(try txn.notetype(named: type))
        var note = Note(id: 0, guid: "", mid: notetype.id)
        note.fields = fields
        note.tagList = tags
        let cards = try txn.addNote(&note, deckID: deck)
        return (note, cards)
    }

    // MARK: Estado inicial

    func testBootstrapCreatesDefaults() throws {
        try collection.read { txn in
            XCTAssertEqual(try txn.allDecks().map(\.name), ["Padrão"])
            XCTAssertEqual(try txn.allDeckConfigs().count, 1)
            let names = Set(try txn.allNotetypes().map(\.name))
            XCTAssertEqual(names, [
                "Básico", "Básico (e card invertido)", "Básico (card invertido opcional)",
                "Básico (digite a resposta)", "Omissão de palavras", "Oclusão de imagem",
            ])
            XCTAssertTrue(try txn.fsrsEnabled())
            XCTAssertEqual(try txn.rolloverHour(), 4)
            let timing = try txn.timing()
            XCTAssertEqual(timing.today, 0)
            XCTAssertGreaterThan(timing.nextDayAt, timing.now)
            XCTAssertLessThanOrEqual(timing.nextDayAt - timing.now, 86_400)
        }
    }

    func testTimingAdvancesAtRollover() {
        let zone = TimeZone(identifier: "America/Sao_Paulo")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func date(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2024, month: 3, day: day, hour: hour))!
        }
        let crt = Int64(date(10, 4).timeIntervalSince1970)
        // 3h59 do dia 11 ainda é o "dia 0"; às 4h vira o dia 1.
        XCTAssertEqual(SchedTiming.compute(crt: crt, now: date(11, 3), rolloverHour: 4, timeZone: zone).today, 0)
        XCTAssertEqual(SchedTiming.compute(crt: crt, now: date(11, 4), rolloverHour: 4, timeZone: zone).today, 1)
        XCTAssertEqual(SchedTiming.compute(crt: crt, now: date(20, 12), rolloverHour: 4, timeZone: zone).today, 10)
        let timing = SchedTiming.compute(crt: crt, now: date(11, 12), rolloverHour: 4, timeZone: zone)
        XCTAssertEqual(timing.nextDayAt, Int64(date(12, 4).timeIntervalSince1970))
        XCTAssertEqual(timing.date(forDay: 1), date(11, 4))
    }

    // MARK: Notas e geração de cards

    func testBasicNoteGeneratesOneCard() throws {
        try collection.write { txn in
            let (note, cards) = try self.makeNote(txn, type: "Básico", ["<b>Olá</b> mundo", "Hello"], tags: ["saudação", "Inglês"])
            XCTAssertEqual(cards.count, 1)
            XCTAssertEqual(cards[0].type, .new)
            XCTAssertEqual(cards[0].queue, .new)
            XCTAssertEqual(cards[0].due, 1)
            XCTAssertEqual(cards[0].did, 1)
            XCTAssertEqual(note.sfld, "Olá mundo")
            XCTAssertEqual(note.tags, " Inglês saudação ")
            XCTAssertEqual(note.usn, -1)
            XCTAssertFalse(note.guid.isEmpty)
            XCTAssertEqual(note.csum, Hashing.fieldChecksum("<b>Olá</b> mundo"))
            XCTAssertEqual(try txn.allTags(), ["Inglês", "saudação"])
        }
    }

    func testChecksumMatchesReferenceAlgorithm() {
        // 8 primeiros dígitos hexadecimais do SHA-1 de "hello" = aaf4c61d.
        XCTAssertEqual(Hashing.fieldChecksum("hello"), 0xaaf4c61d)
        XCTAssertEqual(Hashing.fieldChecksum("<i>hello</i>"), 0xaaf4c61d)
        XCTAssertEqual(Hashing.sha1Hex("hello"), "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
    }

    func testReversedAndOptionalReversed() throws {
        try collection.write { txn in
            let (_, both) = try self.makeNote(txn, type: "Básico (e card invertido)", ["a", "b"])
            XCTAssertEqual(both.map(\.ord), [0, 1])
            // Irmãos compartilham a posição de card novo.
            XCTAssertEqual(both[0].due, both[1].due)

            let (_, withoutReverse) = try self.makeNote(txn, type: "Básico (card invertido opcional)", ["a", "b", ""])
            XCTAssertEqual(withoutReverse.map(\.ord), [0])
            var (note, _) = try self.makeNote(txn, type: "Básico (card invertido opcional)", ["c", "d", ""])
            // Preencher o campo "Adicionar inverso" cria o segundo card.
            var fields = note.fields
            fields[2] = "s"
            note.fields = fields
            try txn.updateNote(&note)
            XCTAssertEqual(try txn.cards(ofNote: note.id).map(\.ord), [0, 1])
        }
    }

    func testEmptyFrontIsRejected() throws {
        XCTAssertThrowsError(try collection.write { txn in _ = try self.makeNote(txn, type: "Básico", ["", "só verso"]) }) {
            XCTAssertEqual($0 as? CollectionError, .noCardsGenerated)
        }
        XCTAssertThrowsError(try collection.write { txn in _ = try self.makeNote(txn, type: "Omissão de palavras", ["sem omissão", ""]) }) {
            XCTAssertEqual($0 as? CollectionError, .clozeMissing)
        }
        XCTAssertEqual(try collection.read { try $0.noteCount() }, 0)
    }

    func testClozeCardsFollowTheText() throws {
        try collection.write { txn in
            var (note, cards) = try self.makeNote(txn, type: "Omissão de palavras", ["{{c1::um}} {{c3::três}}", ""])
            XCTAssertEqual(cards.map(\.ord), [0, 2])

            var fields = note.fields
            fields[0] = "{{c1::um}} {{c2::dois}} {{c3::três}}"
            note.fields = fields
            try txn.updateNote(&note)
            XCTAssertEqual(try txn.cards(ofNote: note.id).map(\.ord), [0, 1, 2])

            // Remover uma omissão não exclui o card na hora: ele aparece em "cards vazios".
            fields[0] = "{{c1::um}} dois {{c3::três}}"
            note.fields = fields
            try txn.updateNote(&note)
            XCTAssertEqual(try txn.cards(ofNote: note.id).count, 3)
            let empty = try txn.emptyCards()
            XCTAssertEqual(empty.count, 1)
            XCTAssertEqual(empty[0].ordinals, [1])
            XCTAssertFalse(empty[0].wouldDeleteNote)
            try txn.removeCards(empty[0].cardIDs)
            XCTAssertEqual(try txn.cards(ofNote: note.id).map(\.ord), [0, 2])
            XCTAssertEqual(try txn.noteCount(), 1)
        }
    }

    func testRemovingLastCardRemovesNoteAndLeavesGraves() throws {
        try collection.write { txn in
            let (note, cards) = try self.makeNote(txn, type: "Básico", ["x", "y"])
            try txn.removeCards(cards.map(\.id))
            XCTAssertNil(try txn.noteIfExists(note.id))
            let graves = try Grave.fetchAll(txn.db)
            XCTAssertEqual(Set(graves.map(\.type)), [.card, .note])
            XCTAssertTrue(graves.allSatisfy { $0.usn == -1 })
        }
    }

    func testDuplicateDetection() throws {
        try collection.write { txn in
            let (note, _) = try self.makeNote(txn, type: "Básico", ["<b>Brasil</b>", "Brasília"])
            XCTAssertEqual(try txn.duplicateNoteIDs(firstField: "Brasil", notetypeID: note.mid), [note.id])
            XCTAssertEqual(try txn.duplicateNoteIDs(firstField: "<i>Brasil</i>", notetypeID: note.mid), [note.id])
            XCTAssertEqual(try txn.duplicateNoteIDs(firstField: "Brasil", notetypeID: note.mid, excluding: note.id), [])
            XCTAssertEqual(try txn.duplicateNoteIDs(firstField: "Argentina", notetypeID: note.mid), [])
            XCTAssertEqual(try txn.duplicateNoteIDs(firstField: "", notetypeID: note.mid), [])

            _ = try self.makeNote(txn, type: "Básico", ["Brasil", "outro"])
            let groups = try txn.findDuplicates(fieldName: "Frente")
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups[0].value, "Brasil")
            XCTAssertEqual(groups[0].noteIDs.count, 2)
        }
    }

    // MARK: Tags, buscar e substituir

    func testTagOperations() throws {
        try collection.write { txn in
            let (first, _) = try self.makeNote(txn, type: "Básico", ["a", "b"], tags: ["idioma::inglês", "verbo"])
            let (second, _) = try self.makeNote(txn, type: "Básico", ["c", "d"], tags: ["idioma"])

            XCTAssertEqual(try txn.addTags(["novo", "verbo"], toNotes: [first.id, second.id]), 2)
            XCTAssertEqual(try txn.note(first.id).tagList, ["idioma::inglês", "novo", "verbo"])
            XCTAssertEqual(try txn.removeTags(["VERBO"], fromNotes: [first.id, second.id]), 2)
            XCTAssertFalse(try txn.note(first.id).hasTag("verbo"))

            XCTAssertEqual(try txn.renameTag("idioma", to: "língua"), 2)
            XCTAssertEqual(try txn.note(first.id).tagList, ["língua::inglês", "novo"])
            XCTAssertEqual(try txn.note(second.id).tagList, ["língua", "novo"])
            XCTAssertFalse(try txn.allTags().contains("idioma"))

            XCTAssertEqual(try txn.deleteTag("língua"), 2)
            XCTAssertEqual(try txn.note(first.id).tagList, ["novo"])
            XCTAssertGreaterThan(try txn.clearUnusedTags(), 0)
            XCTAssertEqual(try txn.allTags(), ["novo"])
        }
    }

    func testFindAndReplace() throws {
        try collection.write { txn in
            let (first, _) = try self.makeNote(txn, type: "Básico", ["cor: Azul", "color azul"])
            let (second, _) = try self.makeNote(txn, type: "Básico", ["nada", "aqui"])
            let ids = [first.id, second.id]

            XCTAssertEqual(try txn.findAndReplace(noteIDs: ids, search: "azul", replacement: "verde", isRegex: false,
                                                  matchCase: false, fieldName: nil), 1)
            XCTAssertEqual(try txn.note(first.id).fields, ["cor: verde", "color verde"])
            XCTAssertEqual(try txn.note(first.id).sfld, "cor: verde")

            XCTAssertEqual(try txn.findAndReplace(noteIDs: ids, search: "VERDE", replacement: "x", isRegex: false,
                                                  matchCase: true, fieldName: nil), 0)
            XCTAssertEqual(try txn.findAndReplace(noteIDs: ids, search: "(\\w+): (\\w+)", replacement: "$2 = $1", isRegex: true,
                                                  matchCase: false, fieldName: "Frente"), 1)
            XCTAssertEqual(try txn.note(first.id).fields, ["verde = cor", "color verde"])
            XCTAssertThrowsError(try txn.findAndReplace(noteIDs: ids, search: "(", replacement: "", isRegex: true,
                                                        matchCase: false, fieldName: nil))
        }
    }

    // MARK: Baralhos

    func testDeckHierarchy() throws {
        try collection.write { txn in
            let child = try txn.addDeck(named: " Idiomas :: Inglês ::Verbos")
            XCTAssertEqual(child.name, "Idiomas::Inglês::Verbos")
            XCTAssertEqual(try txn.allDecks().map(\.name), ["Idiomas", "Idiomas::Inglês", "Idiomas::Inglês::Verbos", "Padrão"])
            XCTAssertThrowsError(try txn.addDeck(named: "idiomas")) {
                XCTAssertEqual($0 as? CollectionError, .deckNameExists("idiomas"))
            }

            let root = try XCTUnwrap(try txn.deck(named: "Idiomas"))
            try txn.renameDeck(root.id, to: "Línguas")
            XCTAssertEqual(try txn.allDecks().map(\.name), ["Línguas", "Línguas::Inglês", "Línguas::Inglês::Verbos", "Padrão"])

            // Mover para dentro de outro baralho e de volta para a raiz.
            let english = try XCTUnwrap(try txn.deck(named: "Línguas::Inglês"))
            try txn.reparentDeck(english.id, under: 1)
            XCTAssertNotNil(try txn.deck(named: "Padrão::Inglês::Verbos"))
            try txn.reparentDeck(english.id, under: nil)
            XCTAssertNotNil(try txn.deck(named: "Inglês::Verbos"))
            XCTAssertThrowsError(try txn.reparentDeck(english.id, under: child.id))

            XCTAssertEqual(try txn.parents(of: try txn.deck(child.id)).map(\.name), ["Inglês"])
            XCTAssertEqual(try txn.deckAndChildIDs(english.id).count, 2)
        }
    }

    func testRemovingDeckRemovesCardsAndChildren() throws {
        try collection.write { txn in
            let parent = try txn.addDeck(named: "A")
            let child = try txn.addDeck(named: "A::B")
            _ = try self.makeNote(txn, type: "Básico", ["1", "x"], deck: parent.id)
            _ = try self.makeNote(txn, type: "Básico", ["2", "x"], deck: child.id)
            let (kept, _) = try self.makeNote(txn, type: "Básico", ["3", "x"], deck: 1)
            try txn.removeDeck(parent.id)
            XCTAssertEqual(try txn.allDecks().map(\.name), ["Padrão"])
            XCTAssertEqual(try txn.noteCount(), 1)
            XCTAssertNotNil(try txn.noteIfExists(kept.id))

            // O último baralho nunca some: o padrão é recriado.
            try txn.removeDeck(1)
            XCTAssertEqual(try txn.allDecks().count, 1)
            XCTAssertEqual(try txn.cardCount(), 0)
        }
    }

    func testMoveCardsBetweenDecks() throws {
        try collection.write { txn in
            let target = try txn.addDeck(named: "Destino")
            let (_, cards) = try self.makeNote(txn, type: "Básico", ["m", "n"])
            try txn.moveCards(cards.map(\.id), toDeck: target.id)
            XCTAssertEqual(try txn.card(cards[0].id).did, target.id)
            let filtered = try txn.addDeck(named: "Filtrado", filtered: FilteredDeck())
            XCTAssertThrowsError(try txn.moveCards(cards.map(\.id), toDeck: filtered.id))
            XCTAssertThrowsError(try txn.addDeck(named: "Filtrado::Filho")) {
                XCTAssertEqual($0 as? CollectionError, .filteredDeckCannotHaveChildren)
            }
        }
    }

    func testDeckConfigAssignmentAndRemoval() throws {
        try collection.write { txn in
            var preset = try txn.addDeckConfig(named: "Intensivo", cloning: 1)
            preset.config.newPerDay = 50
            try txn.saveDeckConfig(&preset)
            let deck = try txn.addDeck(named: "Vestibular")
            try txn.setDeckConfig(preset.id, forDecks: [deck.id])
            XCTAssertEqual(try txn.deckConfig(forDeck: deck.id).config.newPerDay, 50)
            XCTAssertEqual(try txn.deckConfigUsage()[preset.id], 1)

            try txn.removeDeckConfig(preset.id)
            XCTAssertEqual(try txn.deckConfig(forDeck: deck.id).id, 1)
            XCTAssertThrowsError(try txn.removeDeckConfig(1))
        }
    }

    func testDeckConfigDecodingToleratesMissingKeys() throws {
        let json = #"{"newPerDay": 7, "learnSteps": [5]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DeckConfigData.self, from: json)
        XCTAssertEqual(decoded.newPerDay, 7)
        XCTAssertEqual(decoded.learnSteps, [5])
        XCTAssertEqual(decoded.reviewsPerDay, 200)
        XCTAssertEqual(decoded.desiredRetention, 0.9)
    }

    // MARK: Tipos de nota

    func testEditingNotetypeFieldsRewritesNotes() throws {
        try collection.write { txn in
            let (note, _) = try self.makeNote(txn, type: "Básico", ["frente", "verso"])
            var notetype = try txn.notetype(note.mid)

            // Novo campo no meio, campos originais trocados de lugar.
            notetype.config.fields = [
                NoteField(ord: 0, name: "Verso"),
                NoteField(ord: 1, name: "Exemplo"),
                NoteField(ord: 2, name: "Frente"),
            ]
            try txn.updateNotetype(notetype, fieldOrigins: [1, nil, 0])
            let updated = try txn.note(note.id)
            XCTAssertEqual(updated.fields, ["verso", "", "frente"])
            XCTAssertEqual(updated.sfld, "verso")
            XCTAssertEqual(updated.csum, Hashing.fieldChecksum("verso"))

            // Renomear um campo atualiza os modelos.
            notetype = try txn.notetype(note.mid)
            notetype.renameField(at: 2, to: "Pergunta")
            XCTAssertEqual(notetype.templates[0].qfmt, "{{Pergunta}}")
            XCTAssertTrue(notetype.templates[0].afmt.contains("{{Verso}}"))
            try txn.updateNotetype(notetype)
            XCTAssertTrue(try txn.notetype(note.mid).templateProblems().isEmpty)

            // Remover um campo remove as referências a ele.
            notetype.removeField(at: 0)
            XCTAssertEqual(notetype.fieldNames, ["Exemplo", "Pergunta"])
            XCTAssertFalse(notetype.templates[0].afmt.contains("Verso"))
        }
    }

    func testAddingAndRemovingTemplates() throws {
        try collection.write { txn in
            let (note, _) = try self.makeNote(txn, type: "Básico", ["frente", "verso"])
            var notetype = try txn.notetype(note.mid)
            notetype.config.templates.append(CardTemplate(ord: 1, name: "Inverso", qfmt: "{{Verso}}", afmt: "{{Frente}}"))
            try txn.updateNotetype(notetype, templateOrigins: [0, nil])
            XCTAssertEqual(try txn.cards(ofNote: note.id).map(\.ord), [0, 1])

            // Remove o primeiro modelo: o card restante passa a ser o de índice 0.
            notetype = try txn.notetype(note.mid)
            notetype.config.templates.removeFirst()
            try txn.updateNotetype(notetype, templateOrigins: [1])
            let cards = try txn.cards(ofNote: note.id)
            XCTAssertEqual(cards.map(\.ord), [0])
            XCTAssertEqual(try txn.notetype(note.mid).templates.map(\.name), ["Inverso"])
        }
    }

    func testChangeNotetypeWithFieldMapping() throws {
        try collection.write { txn in
            let (note, _) = try self.makeNote(txn, type: "Básico (e card invertido)", ["frente", "verso"])
            let target = try XCTUnwrap(try txn.notetype(named: "Básico"))
            // Inverte os campos e mantém só o card do segundo modelo.
            try txn.changeNotetype(noteIDs: [note.id], to: target.id, fieldMap: [1, 0], templateMap: [1])
            let changed = try txn.note(note.id)
            XCTAssertEqual(changed.mid, target.id)
            XCTAssertEqual(changed.fields, ["verso", "frente"])
            let cards = try txn.cards(ofNote: note.id)
            XCTAssertEqual(cards.map(\.ord), [0])
        }
    }

    func testTemplateProblemsAreReported() {
        var notetype = Notetype.stock(.basic)
        XCTAssertTrue(notetype.templateProblems().isEmpty)
        notetype.config.templates[0].qfmt = "{{Inexistente}} {{#Frente}}"
        XCTAssertEqual(notetype.templateProblems().count, 1)
        notetype.config.templates[0].qfmt = "{{Inexistente}}"
        XCTAssertTrue(notetype.templateProblems()[0].contains("Inexistente"))
        var cloze = Notetype.stock(.cloze)
        XCTAssertTrue(cloze.templateProblems().isEmpty)
        cloze.config.templates[0].qfmt = "{{Texto}}"
        XCTAssertFalse(cloze.templateProblems().isEmpty)
        XCTAssertTrue(Notetype.stock(.imageOcclusion).templateProblems().isEmpty)
    }

    // MARK: Renderização

    func testRenderBasicAndTypeAnswer() throws {
        try collection.write { txn in
            let (_, cards) = try self.makeNote(txn, type: "Básico (digite a resposta)", ["Capital do Brasil? [sound:q.mp3]", "<b>Brasília</b>"])
            let rendered = try txn.render(card: cards[0])
            XCTAssertNotNil(rendered.typeAnswer)
            XCTAssertEqual(rendered.expectedTypedAnswer, "Brasília")
            XCTAssertEqual(rendered.questionAudio, [.sound(filename: "q.mp3")])
            XCTAssertTrue(rendered.questionForDisplay.contains("<input type=\"text\" id=\"typeans\""))
            XCTAssertTrue(rendered.answerForDisplay(typed: "Brasília").contains("typeGood"))
            XCTAssertTrue(rendered.answerForDisplay(typed: "Brasilia").contains("typeBad"))
            XCTAssertFalse(rendered.isCloze)
        }
    }

    func testRenderClozeCards() throws {
        try collection.write { txn in
            let (_, cards) = try self.makeNote(txn, type: "Omissão de palavras", ["{{c1::Lisboa}} fica em {{c2::Portugal}}", "extra"])
            let first = try txn.render(card: cards[0])
            XCTAssertTrue(first.questionHTML.contains("[...]</span> fica em <span class=\"cloze-inactive\""))
            XCTAssertTrue(first.answerHTML.contains("<span class=\"cloze\" data-ordinal=\"1\">Lisboa</span>"))
            XCTAssertTrue(first.answerHTML.contains("extra"))
            let second = try txn.render(card: cards[1])
            XCTAssertTrue(second.questionHTML.contains("data-cloze=\"Portugal\""))
            XCTAssertTrue(second.isCloze)
            XCTAssertTrue(first.css.contains(".cloze"))
        }
    }

    // MARK: Mídia e verificação

    func testMediaNamingAndCheck() throws {
        let first = try collection.addMedia(data: Data("abc".utf8), preferredName: "som/../figura?.png")
        XCTAssertEqual(first, "figura.png")
        // Mesmo nome e mesmo conteúdo: reaproveita. Conteúdo diferente: novo nome.
        XCTAssertEqual(try collection.addMedia(data: Data("abc".utf8), preferredName: "figura.png"), "figura.png")
        let other = try collection.addMedia(data: Data("xyz".utf8), preferredName: "figura.png")
        XCTAssertNotEqual(other, "figura.png")
        XCTAssertTrue(other.hasSuffix(".png"))
        _ = try collection.addMedia(data: Data("sem uso".utf8), preferredName: "orfao.mp3")

        try collection.write { txn in
            _ = try self.makeNote(txn, type: "Básico", ["<img src=\"figura.png\"> [sound:falta.mp3]", "x"])
        }
        let report = try collection.checkMedia()
        XCTAssertEqual(report.missing, ["falta.mp3"])
        XCTAssertEqual(Set(report.unused), [other, "orfao.mp3"])
        XCTAssertEqual(report.totalFiles, 3)
        XCTAssertEqual(report.notesWithMissing.count, 1)

        try collection.deleteMedia(report.unused)
        XCTAssertEqual(try collection.allMediaFiles(), ["figura.png"])
        XCTAssertEqual(HTMLText.mediaReferences(in: "<img src='a b.jpg'><audio src=c.mp3></audio><img src=\"https://x/y.png\">"), ["a b.jpg", "c.mp3"])
    }

    func testCheckDatabaseRepairsInconsistencies() throws {
        let noteID: NoteID = try collection.write { txn in
            let (note, cards) = try self.makeNote(txn, type: "Básico", ["íntegro", "ok"])
            // Corrompe de propósito: card em baralho inexistente, sfld errado, card órfão.
            try txn.db.execute(sql: "UPDATE cards SET did = 999 WHERE id = ?", arguments: [cards[0].id])
            try txn.db.execute(sql: "UPDATE notes SET sfld = 'errado', flds = 'íntegro' WHERE id = ?", arguments: [note.id])
            try Card(id: 5, nid: 123_456, did: 1, ord: 0).insert(txn.db)
            return note.id
        }
        let report = try collection.write { try $0.checkDatabase() }
        XCTAssertFalse(report.isClean)
        XCTAssertGreaterThanOrEqual(report.problems.count, 3)
        try collection.read { txn in
            let note = try txn.note(noteID)
            XCTAssertEqual(note.fields.count, 2)
            XCTAssertEqual(note.sfld, "íntegro")
            XCTAssertEqual(try txn.cards(ofNote: noteID).first?.did, 1)
            XCTAssertNil(try txn.cardIfExists(5))
        }
        XCTAssertTrue(try collection.write { try $0.checkDatabase() }.isClean)
    }

    func testHTMLHelpers() {
        XCTAssertEqual(HTMLText.strip("<p>a &amp; b&nbsp;&#233;&#x41;</p><!-- c --><style>x{}</style>"), "a & b éA")
        XCTAssertEqual(HTMLText.stripToLine("um<br>dois<div>três</div> [sound:x.mp3]"), "um dois três")
        XCTAssertEqual(HTMLText.stripPreservingMedia("<img src=\"foto.jpg\">").trimmingCharacters(in: .whitespaces), "foto.jpg")
        XCTAssertEqual(HTMLText.escape("a<b & \"c\""), "a&lt;b &amp; &quot;c&quot;")
        XCTAssertEqual(Note.joinTags(["b", "a", "B", " c d "]), " a b c_d ")
        XCTAssertEqual(Deck.normalizedName(" A ::  :: B "), "A::B")
        XCTAssertEqual([1, 2, 3, 4, 5].chunked(2), [[1, 2], [3, 4], [5]])
        let guid = GUID.make()
        XCTAssertFalse(guid.isEmpty)
        XCTAssertLessThanOrEqual(guid.count, 11)
    }
}
