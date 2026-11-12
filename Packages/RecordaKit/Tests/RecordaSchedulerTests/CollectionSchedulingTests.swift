import XCTest
import GRDB
import RecordaCore
import RecordaSearch
@testable import RecordaScheduler

final class CollectionSchedulingTests: XCTestCase {

    var clock: TestClock!
    var collection: Collection!

    override func setUpWithError() throws {
        clock = TestClock()
        collection = try Collection(inMemoryWithMediaFolder: nil, clock: clock.clock)
        // Sem fuzz, os intervalos são determinísticos.
        try collection.write { txn in try txn.setConfig(ConfigKey.fuzzEnabled, false) }
    }

    @discardableResult
    func addBasic(_ txn: Txn, _ front: String, _ back: String = "verso", deck: DeckID = 1, type: String = "Básico") throws -> Note {
        let notetype = try XCTUnwrap(try txn.notetype(named: type))
        var note = Note(id: 0, guid: "", mid: notetype.id)
        var fields = [String](repeating: "", count: notetype.fields.count)
        fields[0] = front
        fields[1] = back
        note.fields = fields
        try txn.addNote(&note, deckID: deck)
        return note
    }

    /// Avança o relógio até o card estar vencido.
    func advanceUntilDue(_ card: Card) throws {
        let timing = try collection.read { try $0.timing() }
        switch card.queue {
        case .review, .dayLearning:
            let days = Int(card.due) - timing.today
            if days > 0 { clock.advance(days: Double(days)) }
        case .learning, .preview:
            let due = Date(timeIntervalSince1970: TimeInterval(card.due))
            if due > clock.now { clock.now = due }
        default:
            break
        }
    }

    // MARK: Sequência de referência do FSRS pelo caminho completo (banco + revlog)

    func testFSRSReferenceSequenceEndToEnd() throws {
        let cardID: CardID = try collection.write { txn in
            let note = try self.addBasic(txn, "pergunta")
            return try XCTUnwrap(try txn.cards(ofNote: note.id).first).id
        }
        let ratings: [Rating] = [.good, .good, .good, .good, .good, .good, .again, .again, .good, .good, .good, .good, .good]
        let expected = [0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12, 21]
        var intervals: [Int] = []
        for rating in ratings {
            let before = try collection.read { try $0.card(cardID) }
            try advanceUntilDue(before)
            try collection.write { txn in _ = try txn.answer(cardID: cardID, rating: rating, millisecondsTaken: 5000) }
            let after = try collection.read { try $0.card(cardID) }
            intervals.append(after.queue == .review ? after.ivl : 0)
        }
        XCTAssertEqual(intervals, expected)

        let final = try collection.read { try $0.card(cardID) }
        XCTAssertEqual(final.cardData.s ?? 0, 20.77035728499242, accuracy: 1e-6)
        XCTAssertEqual(final.cardData.d ?? 0, 9.055759917231622, accuracy: 1e-6)
        XCTAssertEqual(final.reps, 13)
        XCTAssertEqual(final.lapses, 1)

        // Cada resposta gerou uma linha de revlog compatível.
        let revlog = try collection.read { txn in
            try RevlogEntry.filter(sql: "cid = ?", arguments: [cardID]).order(sql: "id").fetchAll(txn.db)
        }
        XCTAssertEqual(revlog.count, 13)
        XCTAssertEqual(revlog.map(\.ease), ratings.map(\.rawValue))
        XCTAssertEqual(revlog[0].type, .learning)
        XCTAssertEqual(revlog[0].ivl, -600)
        XCTAssertEqual(revlog[1].ivl, 2)
        XCTAssertEqual(revlog[2].type, .review)
        XCTAssertEqual(revlog[2].lastIvl, 2)
        XCTAssertEqual(revlog[6].type, .review)
        XCTAssertEqual(revlog[6].ivl, -600)
        XCTAssertEqual(revlog[7].type, .relearning)
        XCTAssertTrue(revlog.allSatisfy { $0.time == 5000 && $0.usn == -1 })
        // Com FSRS, o fator do revlog guarda a dificuldade (100–1100).
        XCTAssertTrue(revlog.allSatisfy { (100...1100).contains($0.factor) })

        // O histórico reconstruído do revlog leva ao mesmo estado de memória.
        let histories = try collection.read { try $0.fsrsHistories() }
        XCTAssertEqual(histories.count, 1)
        XCTAssertTrue(histories[0].isComplete)
        XCTAssertEqual(histories[0].reviews.map(\.elapsedDays), [0, 0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12])
        let rebuilt = FSRS().memoryState(history: histories[0].reviews)
        XCTAssertEqual(rebuilt?.stability ?? 0, 20.77035728499242, accuracy: 1e-6)
    }

    func testSM2EndToEnd() throws {
        try collection.write { txn in try txn.setFSRSEnabled(false) }
        let cardID: CardID = try collection.write { txn in
            let note = try self.addBasic(txn, "sm2")
            return try XCTUnwrap(try txn.cards(ofNote: note.id).first).id
        }
        // Bom, Bom → gradua com 1 dia; Bom → 1 × 2,5 = 2,5 → 3 (mínimo: difícil + 1 = 3); Bom → 3 × 2,5 = 7,5 → 8.
        var intervals: [Int] = []
        for _ in 0..<4 {
            try advanceUntilDue(try collection.read { try $0.card(cardID) })
            try collection.write { txn in _ = try txn.answer(cardID: cardID, rating: .good, millisecondsTaken: 1000) }
            let after = try collection.read { try $0.card(cardID) }
            intervals.append(after.queue == .review ? after.ivl : 0)
        }
        XCTAssertEqual(intervals, [0, 1, 3, 8])
        let card = try collection.read { try $0.card(cardID) }
        XCTAssertEqual(card.factor, 2500)
        XCTAssertNil(card.cardData.s)
        let factors = try collection.read { txn in try Int.fetchAll(txn.db, sql: "SELECT factor FROM revlog ORDER BY id") }
        XCTAssertEqual(factors, [2500, 2500, 2500, 2500])
    }

    // MARK: Filas e limites

    func testQueueRespectsDailyNewLimit() throws {
        try collection.write { txn in
            for index in 0..<30 { try self.addBasic(txn, "card \(index)") }
        }
        var queue = try collection.write { try $0.studyQueue(deckID: 1) }
        XCTAssertEqual(queue.counts, DeckCounts(new: 20, learning: 0, review: 0))
        let now = Int64(clock.now.timeIntervalSince1970)
        let first = try XCTUnwrap(queue.next(now: now))
        XCTAssertEqual(first.kind, .new)

        try collection.write { txn in _ = try txn.answer(cardID: first.cardID, rating: .good, millisecondsTaken: 100) }
        queue = try collection.write { try $0.studyQueue(deckID: 1) }
        XCTAssertEqual(queue.counts, DeckCounts(new: 19, learning: 1, review: 0))
        // O card em aprendizado só volta daqui a 10 min; enquanto isso seguem os novos.
        let second = try XCTUnwrap(queue.next(now: now))
        XCTAssertEqual(second.kind, .new)
        XCTAssertNotEqual(second.cardID, first.cardID)

        // Cards novos saem na ordem em que foram adicionados.
        let firstNote = try collection.read { try $0.note(try $0.card(first.cardID).nid) }
        XCTAssertEqual(firstNote.sfld, "card 0")
    }

    func testLearningCardComesBackWhenDueOrWhenNothingElseIsLeft() throws {
        let cardID: CardID = try collection.write { txn in
            let note = try self.addBasic(txn, "único")
            return try XCTUnwrap(try txn.cards(ofNote: note.id).first).id
        }
        try collection.write { txn in _ = try txn.answer(cardID: cardID, rating: .again, millisecondsTaken: 100) }
        let queue = try collection.write { try $0.studyQueue(deckID: 1) }
        let now = Int64(clock.now.timeIntervalSince1970)
        // Vence em 1 min, mas está dentro do limite de aprendizado antecipado (20 min) e não há mais nada.
        XCTAssertEqual(queue.next(now: now)?.cardID, cardID)
        XCTAssertEqual(queue.counts.learning, 1)

        // Com o limite zerado, é preciso esperar.
        try collection.write { txn in try txn.setConfig(ConfigKey.learnAheadSecs, 0) }
        let strict = try collection.write { try $0.studyQueue(deckID: 1) }
        XCTAssertNil(strict.next(now: now))
        XCTAssertEqual(strict.next(now: now + 61)?.cardID, cardID)
        XCTAssertNotNil(strict.nextLearningDue)
    }

    func testChildDeckLimitsAreCappedByParent() throws {
        try collection.write { txn in
            let parent = try txn.addDeck(named: "Idiomas")
            let child = try txn.addDeck(named: "Idiomas::Inglês")
            for index in 0..<15 { try self.addBasic(txn, "pai \(index)", deck: parent.id) }
            for index in 0..<15 { try self.addBasic(txn, "filho \(index)", deck: child.id) }
        }
        let tree = try collection.read { try $0.deckTree() }
        let parent = try XCTUnwrap(tree.first { $0.deck.name == "Idiomas" })
        XCTAssertEqual(parent.children.count, 1)
        XCTAssertEqual(parent.children[0].counts.new, 15)
        XCTAssertEqual(parent.counts.new, 20)
        XCTAssertEqual(parent.totalCards, 30)

        let queue = try collection.write { try $0.studyQueue(deckID: parent.id) }
        XCTAssertEqual(queue.counts.new, 20)

        // Limite "somente hoje" no baralho filho.
        try collection.write { txn in
            var child = try XCTUnwrap(try txn.deck(named: "Idiomas::Inglês"))
            let today = try txn.timing().today
            child.normal?.newLimitToday = DayCount(day: today, count: 3)
            try txn.saveDeck(&child)
        }
        let limited = try collection.read { try $0.deckTree() }
        let limitedParent = try XCTUnwrap(limited.first { $0.deck.name == "Idiomas" })
        XCTAssertEqual(limitedParent.children[0].counts.new, 3)
        XCTAssertEqual(limitedParent.counts.new, 18)
    }

    func testReviewsDueAndReviewLimit() throws {
        let ids: [CardID] = try collection.write { txn in
            var ids: [CardID] = []
            for index in 0..<10 {
                let note = try self.addBasic(txn, "rev \(index)")
                var card = try XCTUnwrap(try txn.cards(ofNote: note.id).first)
                card.type = .review
                card.queue = .review
                card.ivl = 10
                card.factor = 2500
                card.due = Int64(index < 6 ? 0 : 5)   // 6 vencem hoje, 4 daqui a 5 dias
                try txn.saveCard(&card)
                ids.append(card.id)
            }
            return ids
        }
        var queue = try collection.write { try $0.studyQueue(deckID: 1) }
        XCTAssertEqual(queue.counts.review, 6)

        try collection.write { txn in
            var preset = try txn.deckConfig(1)
            preset.config.reviewsPerDay = 4
            try txn.saveDeckConfig(&preset)
        }
        queue = try collection.write { try $0.studyQueue(deckID: 1) }
        XCTAssertEqual(queue.counts.review, 4)

        // Uma resposta consome o limite.
        try collection.write { txn in _ = try txn.answer(cardID: ids[0], rating: .good, millisecondsTaken: 10) }
        queue = try collection.write { try $0.studyQueue(deckID: 1) }
        XCTAssertEqual(queue.counts.review, 3)

        let info = try collection.read { try $0.congratsInfo(deckID: 1) }
        XCTAssertEqual(info.reviewsBeyondLimit, 2)

        // Estudo personalizado: +10 revisões hoje libera o restante.
        try collection.write { txn in _ = try txn.customStudy(deckID: 1, option: .increaseReviewLimit(10)) }
        queue = try collection.write { try $0.studyQueue(deckID: 1) }
        XCTAssertEqual(queue.counts.review, 5)
    }

    // MARK: Desfazer, enterrar, suspender

    func testUndoRestoresCardRevlogAndCounters() throws {
        let cardID: CardID = try collection.write { txn in
            let note = try self.addBasic(txn, "desfazer")
            return try XCTUnwrap(try txn.cards(ofNote: note.id).first).id
        }
        let before = try collection.read { try $0.card(cardID) }
        let undo = try collection.write { try $0.answer(cardID: cardID, rating: .easy, millisecondsTaken: 300) }
        XCTAssertEqual(try collection.read { try $0.card(cardID) }.type, .review)
        XCTAssertEqual(try collection.read { try $0.deck(1) }.common.newStudied, 1)

        try collection.write { try $0.applyUndo(undo) }
        let after = try collection.read { try $0.card(cardID) }
        XCTAssertEqual(after.type, before.type)
        XCTAssertEqual(after.queue, before.queue)
        XCTAssertEqual(after.due, before.due)
        XCTAssertEqual(after.reps, 0)
        XCTAssertEqual(after.data, before.data)
        XCTAssertEqual(try collection.read { try RevlogEntry.fetchCount($0.db) }, 0)
        XCTAssertEqual(try collection.read { try $0.deck(1) }.common.newStudied, 0)
    }

    func testSiblingBuryingAndUnburyNextDay() throws {
        try collection.write { txn in
            var preset = try txn.deckConfig(1)
            preset.config.buryNew = true
            try txn.saveDeckConfig(&preset)
        }
        let cards: [Card] = try collection.write { txn in
            let note = try self.addBasic(txn, "frente", "verso", type: "Básico (e card invertido)")
            return try txn.cards(ofNote: note.id)
        }
        XCTAssertEqual(cards.count, 2)
        try collection.write { txn in _ = try txn.answer(cardID: cards[0].id, rating: .good, millisecondsTaken: 10) }
        XCTAssertEqual(try collection.read { try $0.card(cards[1].id) }.queue, .schedBuried)
        XCTAssertEqual(try collection.read { try $0.buriedCount(inDeck: 1) }.sched, 1)

        clock.advance(days: 1)
        _ = try collection.write { try $0.studyQueue(deckID: 1) }
        XCTAssertEqual(try collection.read { try $0.card(cards[1].id) }.queue, .new)
    }

    func testSuspendBuryAndRestore() throws {
        let cardID: CardID = try collection.write { txn in
            let note = try self.addBasic(txn, "suspender")
            return try XCTUnwrap(try txn.cards(ofNote: note.id).first).id
        }
        let suspend = try collection.write { try $0.suspendCards([cardID]) }
        XCTAssertEqual(try collection.read { try $0.card(cardID) }.queue, .suspended)
        XCTAssertTrue(try collection.write { try $0.studyQueue(deckID: 1) }.isEmpty)
        try collection.write { try $0.applyUndo(suspend) }
        XCTAssertEqual(try collection.read { try $0.card(cardID) }.queue, .new)

        try collection.write { txn in _ = try txn.buryCards([cardID]) }
        XCTAssertEqual(try collection.read { try $0.card(cardID) }.queue, .userBuried)
        XCTAssertEqual(try collection.write { try $0.unburyDeck(1) }, 1)
        XCTAssertEqual(try collection.read { try $0.card(cardID) }.queue, .new)
    }

    func testLeechIsTaggedAndSuspended() throws {
        try collection.write { txn in
            var preset = try txn.deckConfig(1)
            preset.config.leechThreshold = 2
            preset.config.leechAction = .suspend
            try txn.saveDeckConfig(&preset)
        }
        let cardID: CardID = try collection.write { txn in
            let note = try self.addBasic(txn, "sanguessuga")
            var card = try XCTUnwrap(try txn.cards(ofNote: note.id).first)
            card.type = .review
            card.queue = .review
            card.ivl = 5
            card.factor = 2500
            card.lapses = 1
            card.due = 0
            try txn.saveCard(&card)
            return card.id
        }
        try collection.write { txn in _ = try txn.answer(cardID: cardID, rating: .again, millisecondsTaken: 10) }
        let card = try collection.read { try $0.card(cardID) }
        XCTAssertEqual(card.queue, .suspended)
        XCTAssertEqual(card.lapses, 2)
        XCTAssertTrue(try collection.read { try $0.note(card.nid) }.hasTag("leech"))
    }

    // MARK: Reagendamento manual

    func testSetDueDateForgetAndReposition() throws {
        let ids: [CardID] = try collection.write { txn in
            var ids: [CardID] = []
            for index in 0..<3 {
                let note = try self.addBasic(txn, "manual \(index)")
                ids.append(try XCTUnwrap(try txn.cards(ofNote: note.id).first).id)
            }
            return ids
        }
        let positions = try collection.read { txn in try ids.map { try txn.card($0).due } }
        XCTAssertEqual(positions, [1, 2, 3])

        try collection.write { txn in _ = try txn.setDueDate(cardIDs: [ids[0]], days: 5...5, changeInterval: false) }
        var card = try collection.read { try $0.card(ids[0]) }
        XCTAssertEqual(card.type, .review)
        XCTAssertEqual(card.due, 5)
        XCTAssertEqual(card.ivl, 5)
        XCTAssertEqual(card.cardData.pos, 1)
        XCTAssertEqual(try collection.read { try Int.fetchOne($0.db, sql: "SELECT type FROM revlog WHERE cid = ?", arguments: [ids[0]]) }, 4)

        try collection.write { txn in _ = try txn.forgetCards([ids[0]], restorePosition: true, resetCounts: true) }
        card = try collection.read { try $0.card(ids[0]) }
        XCTAssertEqual(card.type, .new)
        XCTAssertEqual(card.queue, .new)
        XCTAssertEqual(card.due, 1)
        XCTAssertEqual(card.ivl, 0)

        try collection.write { txn in _ = try txn.repositionNewCards(ids, start: 100, step: 10, randomize: false, shiftExisting: false) }
        XCTAssertEqual(try collection.read { txn in try ids.map { try txn.card($0).due } }, [100, 110, 120])

        XCTAssertNotNil(Txn.parseDueDateSpec("3"))
        XCTAssertEqual(Txn.parseDueDateSpec("2-7!")?.days, 2...7)
        XCTAssertEqual(Txn.parseDueDateSpec("2-7!")?.changeInterval, true)
        XCTAssertNil(Txn.parseDueDateSpec("abc"))
        XCTAssertNil(Txn.parseDueDateSpec("7-2"))
    }

    // MARK: Baralhos filtrados e estudo personalizado

    func testFilteredDeckBuildAndEmpty() throws {
        let ids: [CardID] = try collection.write { txn in
            var ids: [CardID] = []
            for index in 0..<5 {
                let note = try self.addBasic(txn, "filtrado \(index)")
                var card = try XCTUnwrap(try txn.cards(ofNote: note.id).first)
                card.type = .review
                card.queue = .review
                card.ivl = 10
                card.factor = 2500
                card.due = Int64(3 + index)
                try txn.saveCard(&card)
                ids.append(card.id)
            }
            return ids
        }
        var config = FilteredDeck()
        config.terms = [FilteredSearchTerm(search: "deck:Padrão is:review", limit: 3, order: .due)]
        let deck = try collection.write { try $0.createFilteredDeck(named: "Revisão extra", config: config) }

        let moved = try collection.read { txn in try Card.filter(sql: "did = ?", arguments: [deck.id]).fetchAll(txn.db) }
        XCTAssertEqual(moved.count, 3)
        XCTAssertEqual(Set(moved.map(\.id)), Set(ids.prefix(3)))
        XCTAssertTrue(moved.allSatisfy { $0.odid == 1 && $0.odue >= 3 && $0.due < 0 })

        // Cards ainda não vencidos aparecem para estudo dentro do baralho filtrado.
        let queue = try collection.write { try $0.studyQueue(deckID: deck.id) }
        XCTAssertEqual(queue.counts.review, 3)

        // Responder devolve o card ao baralho de origem com novo agendamento.
        try collection.write { txn in _ = try txn.answer(cardID: ids[0], rating: .good, millisecondsTaken: 10) }
        let answered = try collection.read { try $0.card(ids[0]) }
        XCTAssertEqual(answered.did, 1)
        XCTAssertEqual(answered.odid, 0)
        XCTAssertGreaterThan(answered.due, 3)

        try collection.write { try $0.emptyFilteredDeck(deck.id) }
        let restored = try collection.read { try $0.card(ids[1]) }
        XCTAssertEqual(restored.did, 1)
        XCTAssertEqual(restored.due, 4)
        XCTAssertEqual(restored.odid, 0)
        XCTAssertEqual(restored.queue, .review)

        // Excluir um baralho filtrado não exclui os cards.
        try collection.write { txn in
            try txn.rebuildFilteredDeck(deck.id)
            try txn.removeDeck(deck.id)
        }
        XCTAssertEqual(try collection.read { try $0.cardCount() }, 5)
        XCTAssertTrue(try collection.read { txn in try Card.fetchAll(txn.db).allSatisfy { $0.did == 1 && $0.odid == 0 } })
    }

    func testCustomStudyPreviewNewDoesNotReschedule() throws {
        try collection.write { txn in
            for index in 0..<4 { try self.addBasic(txn, "prévia \(index)") }
        }
        let sessionID = try collection.write { try $0.customStudy(deckID: 1, option: .previewNew(days: 1)) }
        XCTAssertNotEqual(sessionID, 1)
        let session = try collection.read { try $0.deck(sessionID) }
        XCTAssertEqual(session.name, Txn.customStudyDeckName)
        XCTAssertEqual(session.filtered?.reschedule, false)

        let queue = try collection.write { try $0.studyQueue(deckID: sessionID) }
        XCTAssertEqual(queue.counts.new, 4)
        let entry = try XCTUnwrap(queue.next(now: Int64(clock.now.timeIntervalSince1970)))
        try collection.write { txn in _ = try txn.answer(cardID: entry.cardID, rating: .easy, millisecondsTaken: 10) }
        let card = try collection.read { try $0.card(entry.cardID) }
        // Continua novo, de volta ao baralho de origem.
        XCTAssertEqual(card.type, .new)
        XCTAssertEqual(card.did, 1)
        XCTAssertEqual(card.reps, 0)

        // Sem cards correspondentes, a opção falha sem deixar baralho vazio para trás.
        XCTAssertThrowsError(try collection.write { try $0.customStudy(deckID: 1, option: .reviewForgotten(days: 1)) })
    }

    func testRecomputeMemoryStatesWhenEnablingFSRS() throws {
        try collection.write { txn in try txn.setFSRSEnabled(false) }
        let cardID: CardID = try collection.write { txn in
            let note = try self.addBasic(txn, "migração")
            return try XCTUnwrap(try txn.cards(ofNote: note.id).first).id
        }
        for _ in 0..<3 {
            try advanceUntilDue(try collection.read { try $0.card(cardID) })
            try collection.write { txn in _ = try txn.answer(cardID: cardID, rating: .good, millisecondsTaken: 10) }
        }
        XCTAssertNil(try collection.read { try $0.card(cardID) }.cardData.s)
        try collection.write { txn in try txn.setFSRSEnabled(true) }
        let data = try collection.read { try $0.card(cardID) }.cardData
        XCTAssertNotNil(data.s)
        XCTAssertNotNil(data.d)
        // Histórico: Bom (0 d), Bom (0 d), Bom (1 d).
        let expected = FSRS().memoryState(history: [
            FSRS.Review(rating: 3, elapsedDays: 0), FSRS.Review(rating: 3, elapsedDays: 0), FSRS.Review(rating: 3, elapsedDays: 1),
        ])
        XCTAssertEqual(data.s ?? 0, expected?.stability ?? -1, accuracy: 1e-9)
    }
}
