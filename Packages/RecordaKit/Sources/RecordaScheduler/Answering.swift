import Foundation
import GRDB
import RecordaCore

/// Instantâneo do que precisa ser restaurado para desfazer uma operação.
public struct UndoStep: Sendable {
    public enum Kind: String, Sendable {
        case answer, bury, suspend, unsuspend, delete, flag, mark, setDue, forget, reposition, edit, move, other
    }

    public var kind: Kind
    /// Versões anteriores de cards alterados.
    public var cards: [Card] = []
    /// Versões anteriores de notas alteradas.
    public var notes: [Note] = []
    /// Versões anteriores de baralhos alterados (contadores do dia).
    public var decks: [Deck] = []
    /// Entradas de revlog criadas pela operação.
    public var revlogIDs: [Int64] = []
    /// Cards e notas excluídos pela operação.
    public var deletedCards: [Card] = []
    public var deletedNotes: [Note] = []
    /// Card em foco (para a tela de estudo voltar a ele).
    public var focusCardID: CardID?

    public init(kind: Kind) { self.kind = kind }

    public var isEmpty: Bool {
        cards.isEmpty && notes.isEmpty && decks.isEmpty && revlogIDs.isEmpty && deletedCards.isEmpty && deletedNotes.isEmpty
    }
}

extension SchedTiming {
    /// Índice de dia (do agendador) em que caiu um instante passado.
    public func dayIndex(forEpochSecs secs: Int64) -> Int {
        let todayStart = nextDayAt - 86_400
        if secs >= todayStart { return today + Int((secs - todayStart) / 86_400) }
        return today - Int((Double(todayStart - secs) / 86_400).rounded(.up))
    }

    /// Dia da semana, 0 = segunda … 6 = domingo.
    public func weekdayIndex(forDay day: Int, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Meio do dia do agendador, para não cair na virada.
        let midday = self.date(forDay: day).addingTimeInterval(12 * 3600)
        let weekday = calendar.component(.weekday, from: midday) // 1 = domingo
        return (weekday + 5) % 7
    }
}

extension Txn {

    // MARK: Contexto

    public func answerContext(for card: Card, timing: SchedTiming? = nil) throws -> AnswerContext {
        let timing = try timing ?? self.timing()
        let preset = try deckConfig(forDeck: card.homeDeckID)
        var filtered: FilteredDeck?
        if card.odid != 0 { filtered = try deckIfExists(card.did)?.filtered }
        let fuzz = try fuzzEnabled() ? Fuzz.factor(cardID: card.id, reps: card.reps) : nil
        var balancer: LoadBalancer?
        if fuzz != nil, try loadBalancerEnabled() {
            let database = db
            let zone = collection.clock.timeZone()
            balancer = LoadBalancer(
                dueCounts: { range in
                    var counts: [Int: Int] = [:]
                    let rows = (try? Row.fetchAll(database, sql: """
                        SELECT due, count(*) AS n FROM cards
                        WHERE queue = 2 AND due BETWEEN ? AND ? GROUP BY due
                        """, arguments: [range.lowerBound, range.upperBound])) ?? []
                    for row in rows { counts[Int(row["due"] as Int64)] = row["n"] }
                    return counts
                },
                weekday: { day in timing.weekdayIndex(forDay: day, timeZone: zone) },
                easyDays: preset.config.easyDaysPercentages)
        }
        return AnswerContext(config: preset.config, timing: timing, fsrsEnabled: try fsrsEnabled(),
                             fuzzFactor: fuzz, filtered: filtered, loadBalancer: balancer)
    }

    /// Os quatro resultados possíveis para o card (para os rótulos dos botões).
    public func outcomes(for card: Card) throws -> [AnswerOutcome] {
        StateMachine.outcomes(for: card, context: try answerContext(for: card))
    }

    // MARK: Responder

    /// Aplica a resposta: grava o card, o revlog, contadores do dia, sanguessugas e enterra irmãos.
    @discardableResult
    public func answer(cardID: CardID, rating: Rating, millisecondsTaken: Int) throws -> UndoStep {
        let original = try card(cardID)
        let timing = try self.timing()
        let ctx = try answerContext(for: original, timing: timing)
        let outcome = StateMachine.outcome(for: original, rating: rating, context: ctx)

        var undo = UndoStep(kind: .answer)
        undo.focusCardID = cardID
        undo.cards.append(original)

        var updated = outcome.card
        if outcome.isLeech {
            var leechNote = try note(original.nid)
            if !leechNote.hasTag("leech") {
                undo.notes.append(leechNote)
                leechNote.addTag("leech")
                leechNote.mod = nowSecs
                leechNote.usn = -1
                try leechNote.update(db)
                try registerTags(["leech"])
            }
            if ctx.config.leechAction == .suspend {
                updated.removeFromFilteredDeck()
                updated.queue = .suspended
            }
        }
        try saveCard(&updated)

        // Revlog
        let cap = max(1, ctx.config.capAnswerTimeToSecs) * 1000
        var revlogID = nowMillis
        while try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM revlog WHERE id = ?)", arguments: [revlogID]) == true {
            revlogID += 1
        }
        let entry = RevlogEntry(id: revlogID, cid: cardID, usn: -1, ease: rating.rawValue,
                                ivl: outcome.revlogInterval, lastIvl: outcome.revlogLastInterval,
                                factor: outcome.revlogFactor, time: min(max(millisecondsTaken, 0), cap),
                                type: outcome.revlogKind)
        try entry.insert(db)
        undo.revlogIDs.append(revlogID)

        // Contadores do dia (baralho de origem, ancestrais e, se for o caso, o baralho filtrado).
        var deckIDs: [DeckID] = []
        if let home = try deckIfExists(original.homeDeckID) {
            deckIDs = try parents(of: home).map(\.id) + [home.id]
        }
        if original.odid != 0 { deckIDs.append(original.did) }
        for deckID in deckIDs {
            guard var deck = try deckIfExists(deckID) else { continue }
            undo.decks.append(deck)
            if deck.common.lastDayStudied != timing.today {
                deck.common.lastDayStudied = timing.today
                deck.common.newStudied = 0
                deck.common.reviewStudied = 0
                deck.common.learningStudied = 0
                deck.common.millisecondsStudied = 0
            }
            if !outcome.isPreview {
                switch original.type {
                case .new: deck.common.newStudied += 1
                case .review: deck.common.reviewStudied += 1
                case .learning, .relearning: deck.common.learningStudied += 1
                }
            }
            deck.common.millisecondsStudied += entry.time
            try saveDeck(&deck)
        }

        // Enterrar irmãos
        if !outcome.isPreview {
            var queues: [Int] = []
            if ctx.config.buryNew { queues.append(CardQueue.new.rawValue) }
            if ctx.config.buryReviews { queues.append(CardQueue.review.rawValue) }
            if ctx.config.buryInterdayLearning { queues.append(CardQueue.dayLearning.rawValue) }
            if !queues.isEmpty {
                let siblings = try Card.filter(
                    sql: "nid = ? AND id != ? AND queue IN (\(queues.map(String.init).joined(separator: ",")))",
                    arguments: [original.nid, cardID]).fetchAll(db)
                for var sibling in siblings {
                    undo.cards.append(sibling)
                    sibling.queue = .schedBuried
                    try saveCard(&sibling)
                }
            }
        }
        return undo
    }

    // MARK: Desfazer

    /// Restaura o estado anterior registrado em `step`.
    public func applyUndo(_ step: UndoStep) throws {
        for id in step.revlogIDs {
            try db.execute(sql: "DELETE FROM revlog WHERE id = ?", arguments: [id])
        }
        for var note in step.deletedNotes {
            note.usn = -1
            try note.save(db)
            try db.execute(sql: "DELETE FROM graves WHERE oid = ? AND type = ?", arguments: [note.id, GraveKind.note.rawValue])
        }
        for var card in step.deletedCards {
            card.usn = -1
            try card.save(db)
            try db.execute(sql: "DELETE FROM graves WHERE oid = ? AND type = ?", arguments: [card.id, GraveKind.card.rawValue])
        }
        for var note in step.notes {
            note.usn = -1
            note.mod = nowSecs
            try note.save(db)
        }
        for var card in step.cards {
            card.usn = -1
            card.mod = nowSecs
            try card.save(db)
        }
        for var deck in step.decks {
            deck.usn = -1
            deck.mtimeSecs = nowSecs
            try deck.save(db)
        }
    }

    // MARK: Enterrar / suspender

    private func snapshot(_ ids: [CardID]) throws -> [Card] { try cards(ids) }

    /// Enterra cards até o dia seguinte.
    @discardableResult
    public func buryCards(_ ids: [CardID], byUser: Bool = true) throws -> UndoStep {
        var undo = UndoStep(kind: .bury)
        for var card in try snapshot(ids) where card.queue.rawValue >= 0 {
            undo.cards.append(card)
            card.queue = byUser ? .userBuried : .schedBuried
            try saveCard(&card)
        }
        return undo
    }

    @discardableResult
    public func buryNotes(_ noteIDs: [NoteID]) throws -> UndoStep {
        try buryCards(try cardIDs(ofNotes: noteIDs))
    }

    @discardableResult
    public func suspendCards(_ ids: [CardID]) throws -> UndoStep {
        var undo = UndoStep(kind: .suspend)
        for var card in try snapshot(ids) where card.queue != .suspended {
            undo.cards.append(card)
            card.removeFromFilteredDeck()
            card.queue = .suspended
            try saveCard(&card)
        }
        return undo
    }

    @discardableResult
    public func suspendNotes(_ noteIDs: [NoteID]) throws -> UndoStep {
        try suspendCards(try cardIDs(ofNotes: noteIDs))
    }

    /// Reativa cards suspensos ou enterrados.
    @discardableResult
    public func restoreCards(_ ids: [CardID]) throws -> UndoStep {
        var undo = UndoStep(kind: .unsuspend)
        for var card in try snapshot(ids) where card.queue.rawValue < 0 {
            undo.cards.append(card)
            card.queue = card.naturalQueue
            try saveCard(&card)
        }
        return undo
    }

    /// Desenterra os cards de um baralho (e sub-baralhos).
    @discardableResult
    public func unburyDeck(_ deckID: DeckID, userBuried: Bool = true, schedBuried: Bool = true) throws -> Int {
        var queues: [Int] = []
        if userBuried { queues.append(CardQueue.userBuried.rawValue) }
        if schedBuried { queues.append(CardQueue.schedBuried.rawValue) }
        guard !queues.isEmpty else { return 0 }
        let deckIDs = try deckAndChildIDs(deckID)
        let ids = try Int64.fetchAll(db, sql: """
            SELECT id FROM cards WHERE did IN (\(Txn.idList(deckIDs)))
            AND queue IN (\(queues.map(String.init).joined(separator: ",")))
            """)
        return try restoreCards(ids).cards.count
    }

    public func buriedCount(inDeck deckID: DeckID) throws -> (user: Int, sched: Int) {
        let deckIDs = Txn.idList(try deckAndChildIDs(deckID))
        let user = try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE did IN (\(deckIDs)) AND queue = -3") ?? 0
        let sched = try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE did IN (\(deckIDs)) AND queue = -2") ?? 0
        return (user, sched)
    }

    /// No primeiro acesso de um novo dia, desenterra tudo.
    public func unburyIfNewDay() throws {
        let today = try timing().today
        let last: Int = try config(ConfigKey.lastUnburiedDay) ?? -1
        guard last < today else { return }
        try db.execute(sql: """
            UPDATE cards SET mod = ?, usn = -1, queue = CASE
                WHEN type = 0 THEN 0
                WHEN type = 2 THEN 2
                WHEN due > 1000000000 THEN 1
                ELSE 3 END
            WHERE queue IN (-2, -3)
            """, arguments: [nowSecs])
        try setConfig(ConfigKey.lastUnburiedDay, today)
    }

    // MARK: Excluir com desfazer

    @discardableResult
    public func deleteNotes(_ noteIDs: [NoteID]) throws -> UndoStep {
        var undo = UndoStep(kind: .delete)
        for chunk in noteIDs.chunked(500) {
            undo.deletedNotes += try Note.filter(sql: "id IN (\(Txn.idList(chunk)))").fetchAll(db)
            undo.deletedCards += try Card.filter(sql: "nid IN (\(Txn.idList(chunk)))").fetchAll(db)
        }
        try removeNotes(noteIDs)
        return undo
    }

    // MARK: Sinalizador e marcação

    @discardableResult
    public func setFlagUndoable(_ flag: Int, cardIDs: [CardID]) throws -> UndoStep {
        var undo = UndoStep(kind: .flag)
        undo.cards = try snapshot(cardIDs)
        try setFlag(flag, cardIDs: cardIDs)
        return undo
    }

    /// Alterna a tag "marked" nas notas.
    @discardableResult
    public func toggleMarked(noteIDs: [NoteID]) throws -> UndoStep {
        var undo = UndoStep(kind: .mark)
        for id in noteIDs {
            var current = try note(id)
            undo.notes.append(current)
            if current.hasTag("marked") { current.removeTag("marked") } else { current.addTag("marked") }
            current.mod = nowSecs
            current.usn = -1
            try current.update(db)
        }
        try registerTags(["marked"])
        return undo
    }

    // MARK: Reagendamento manual

    private func insertManualRevlog(for card: Card, lastInterval: Int, offset: Int64) throws -> Int64 {
        var id = nowMillis + offset
        while try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM revlog WHERE id = ?)", arguments: [id]) == true {
            id += 1
        }
        try RevlogEntry(id: id, cid: card.id, usn: -1, ease: 0, ivl: card.type == .review ? card.ivl : 0,
                        lastIvl: lastInterval, factor: card.factor, time: 0, type: .manual).insert(db)
        return id
    }

    /// Define o vencimento para daqui a `days` dias (sorteado dentro da faixa).
    /// Com `changeInterval`, o intervalo do card também passa a ser esse número de dias.
    @discardableResult
    public func setDueDate(cardIDs: [CardID], days: ClosedRange<Int>, changeInterval: Bool) throws -> UndoStep {
        var undo = UndoStep(kind: .setDue)
        let timing = try self.timing()
        var offset: Int64 = 0
        for var card in try snapshot(cardIDs) {
            undo.cards.append(card)
            let previousInterval = card.type == .review ? card.ivl : 0
            let chosen = max(0, Int.random(in: days))
            let preset = try deckConfig(forDeck: card.homeDeckID)
            card.removeFromFilteredDeck()
            if card.type != .review || changeInterval {
                card.ivl = max(1, chosen)
            }
            if card.type != .review {
                card.factor = card.factor > 0 ? card.factor : Int((preset.config.initialEase * 1000).rounded())
                var data = card.cardData
                if card.type == .new && data.pos == nil { data.pos = Int(card.due) }
                card.cardData = data
            }
            card.type = .review
            card.queue = card.queue == .suspended ? .suspended : .review
            card.due = Int64(timing.today + chosen)
            card.left = 0
            try saveCard(&card)
            undo.revlogIDs.append(try insertManualRevlog(for: card, lastInterval: previousInterval, offset: offset))
            offset += 1
        }
        return undo
    }

    /// Analisa a entrada de "definir vencimento": "5", "5-7", "5!" ou "5-7!".
    public static func parseDueDateSpec(_ text: String) -> (days: ClosedRange<Int>, changeInterval: Bool)? {
        var spec = text.trimmingCharacters(in: .whitespaces)
        var force = false
        if spec.hasSuffix("!") {
            force = true
            spec.removeLast()
        }
        let parts = spec.split(separator: "-", omittingEmptySubsequences: true).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 1, let single = parts[0], single >= 0 { return (single...single, force) }
        if parts.count == 2, let low = parts[0], let high = parts[1], low >= 0, high >= low { return (low...high, force) }
        return nil
    }

    /// Transforma os cards em novos outra vez.
    @discardableResult
    public func forgetCards(_ cardIDs: [CardID], restorePosition: Bool, resetCounts: Bool) throws -> UndoStep {
        var undo = UndoStep(kind: .forget)
        var offset: Int64 = 0
        let targets = try snapshot(cardIDs).filter { $0.type != .new || $0.odid != 0 }
        guard !targets.isEmpty else { return undo }
        var nextPosition = try reserveNewPositions(targets.count)
        for var card in targets.sorted(by: { $0.id < $1.id }) {
            undo.cards.append(card)
            let previousInterval = card.type == .review ? card.ivl : 0
            let wasNew = card.type == .new
            card.removeFromFilteredDeck()
            if !wasNew {
                var data = card.cardData
                let original = data.pos
                data = CardData(pos: nil)
                card.cardData = data
                if restorePosition, let original {
                    card.due = Int64(original)
                } else {
                    card.due = Int64(nextPosition)
                    nextPosition += 1
                }
                card.type = .new
                card.queue = card.queue == .suspended ? .suspended : .new
                card.ivl = 0
                card.factor = 0
                card.left = 0
                if resetCounts {
                    card.reps = 0
                    card.lapses = 0
                }
            }
            try saveCard(&card)
            if !wasNew {
                var logged = card
                logged.ivl = 0
                undo.revlogIDs.append(try insertManualRevlog(for: logged, lastInterval: previousInterval, offset: offset))
                offset += 1
            }
        }
        return undo
    }

    /// Reposiciona cards novos na fila. Irmãos recebem a mesma posição.
    @discardableResult
    public func repositionNewCards(_ cardIDs: [CardID], start: Int, step: Int, randomize: Bool, shiftExisting: Bool) throws -> UndoStep {
        var undo = UndoStep(kind: .reposition)
        let targets = try snapshot(cardIDs).filter { $0.type == .new }
        guard !targets.isEmpty else { return undo }
        var noteOrder: [NoteID] = []
        var seen = Set<NoteID>()
        for card in targets.sorted(by: { ($0.due, $0.id) < ($1.due, $1.id) }) where seen.insert(card.nid).inserted {
            noteOrder.append(card.nid)
        }
        if randomize { noteOrder.shuffle() }
        let stride = max(1, step)
        var positions: [NoteID: Int] = [:]
        for (index, nid) in noteOrder.enumerated() { positions[nid] = start + index * stride }

        if shiftExisting {
            let shift = noteOrder.count * stride
            let ids = Txn.idList(targets.map(\.id))
            let affected = try Card.filter(sql: "type = 0 AND due >= ? AND id NOT IN (\(ids))", arguments: [start]).fetchAll(db)
            for var card in affected {
                undo.cards.append(card)
                card.due += Int64(shift)
                try saveCard(&card)
            }
        }
        for var card in targets {
            undo.cards.append(card)
            if card.odid != 0 { card.odue = Int64(positions[card.nid] ?? start) } else { card.due = Int64(positions[card.nid] ?? start) }
            try saveCard(&card)
        }
        let highest = (positions.values.max() ?? start) + 1
        let current: Int = try config(ConfigKey.nextNewPosition) ?? 0
        if highest > current { try setConfig(ConfigKey.nextNewPosition, highest) }
        return undo
    }
}
