import Foundation
import GRDB
import RecordaCore
import RecordaSearch

/// Opções de "Estudo personalizado".
public enum CustomStudyOption: Sendable, Equatable {
    /// Aumenta o limite de cards novos de hoje.
    case increaseNewLimit(Int)
    /// Aumenta o limite de revisões de hoje.
    case increaseReviewLimit(Int)
    /// Revisa cards esquecidos (Errei) nos últimos N dias.
    case reviewForgotten(days: Int)
    /// Revisa antecipadamente cards que vencem nos próximos N dias.
    case reviewAhead(days: Int)
    /// Pré-visualiza cards novos adicionados nos últimos N dias.
    case previewNew(days: Int)
    /// Estuda por estado do card e/ou tags.
    case cram(kind: CramKind, limit: Int, includeTags: [String], excludeTags: [String])

    public enum CramKind: Int, Sendable, CaseIterable {
        /// Somente cards novos.
        case new
        /// Somente cards vencidos.
        case due
        /// Todos os cards de revisão, em ordem aleatória.
        case review
        /// Todos os cards, em ordem aleatória, sem reagendar.
        case all
    }
}

extension Txn {

    public static let customStudyDeckName = "Sessão de estudo personalizada"

    // MARK: Baralhos filtrados

    private func filteredOrderSQL(_ order: FilteredOrder, today: Int, decay: Double) -> String {
        switch order {
        case .oldestReviewedFirst: return "(SELECT max(id) FROM revlog WHERE cid = c.id) ASC, c.id"
        case .random: return "random()"
        case .intervalsAscending: return "c.ivl ASC, c.id"
        case .intervalsDescending: return "c.ivl DESC, c.id"
        case .lapses: return "c.lapses DESC, c.id"
        case .added: return "n.id ASC, c.ord"
        case .reverseAdded: return "n.id DESC, c.ord"
        case .due: return "c.type ASC, c.due ASC, c.id"
        case .retrievabilityAscending:
            return """
            COALESCE(fsrs_r(json_extract(NULLIF(c.data, ''), '$.s'), max(0, \(today) - (c.due - c.ivl)), \(decay)), \
            1.0 / (1.0 + max(0, \(today) - c.due + c.ivl) * 1.0 / max(c.ivl, 1))) ASC, c.id
            """
        }
    }

    /// Cria um baralho filtrado e já o preenche.
    @discardableResult
    public func createFilteredDeck(named name: String, config: FilteredDeck) throws -> Deck {
        let deck = try addDeck(named: name, filtered: config)
        try rebuildFilteredDeck(deck.id)
        return deck
    }

    /// Esvazia e preenche de novo o baralho filtrado conforme suas buscas. Devolve quantos cards entraram.
    @discardableResult
    public func rebuildFilteredDeck(_ deckID: DeckID) throws -> Int {
        let target = try deck(deckID)
        guard let filtered = target.filtered else {
            throw CollectionError.invalidInput("“\(target.name)” não é um baralho filtrado.")
        }
        try emptyFilteredDeck(deckID)
        let timing = try self.timing()
        let decay = try searchContext().fsrsDecay
        var position = 0
        for term in filtered.terms {
            let trimmed = term.search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.limit > 0 else { continue }
            let sql = try searchSQL(trimmed)
            let ids = try Int64.fetchAll(db, sql: """
                SELECT c.id FROM cards c JOIN notes n ON n.id = c.nid
                WHERE (\(sql.whereClause)) AND c.odid = 0 AND c.did != ? AND c.queue >= 0
                ORDER BY \(filteredOrderSQL(term.order, today: timing.today, decay: decay)) LIMIT ?
                """, arguments: StatementArguments(sql.arguments) + [deckID, term.limit])
            for id in ids {
                var card = try self.card(id)
                card.odid = card.did
                card.odue = card.due
                card.did = deckID
                if card.queue == .new || card.queue == .review {
                    card.due = Int64(-100_000 + position)
                }
                try saveCard(&card)
                position += 1
            }
        }
        return position
    }

    // MARK: Estudo personalizado

    private func extendLimits(deckID: DeckID, new: Int, review: Int) throws {
        let today = try timing().today
        let root = try deck(deckID)
        let family = try deckAndChildren(deckID) + parents(of: root)
        for var member in family {
            guard var normal = member.normal else { continue }
            if new != 0 {
                let current = normal.extendNew.day == today ? normal.extendNew.count : 0
                normal.extendNew = DayCount(day: today, count: current + new)
            }
            if review != 0 {
                let current = normal.extendReview.day == today ? normal.extendReview.count : 0
                normal.extendReview = DayCount(day: today, count: current + review)
            }
            member.normal = normal
            try saveDeck(&member)
        }
    }

    /// Aplica uma opção de estudo personalizado.
    /// Devolve o id do baralho a estudar em seguida (o próprio baralho ou a sessão filtrada criada).
    @discardableResult
    public func customStudy(deckID: DeckID, option: CustomStudyOption) throws -> DeckID {
        switch option {
        case .increaseNewLimit(let amount):
            try extendLimits(deckID: deckID, new: amount, review: 0)
            return deckID
        case .increaseReviewLimit(let amount):
            try extendLimits(deckID: deckID, new: 0, review: amount)
            return deckID
        default:
            break
        }

        let scope = "did:" + Txn.idList(try deckAndChildIDs(deckID))
        var config = FilteredDeck()
        var term = FilteredSearchTerm(search: scope, limit: 99_999, order: .random)

        switch option {
        case .reviewForgotten(let days):
            term.search = "\(scope) rated:\(max(1, days)):1"
            config.reschedule = false
        case .reviewAhead(let days):
            term.search = "\(scope) prop:due<=\(max(1, days))"
            term.order = .due
            config.reschedule = true
        case .previewNew(let days):
            term.search = "\(scope) is:new added:\(max(1, days))"
            term.order = .added
            config.reschedule = false
        case .cram(let kind, let limit, let includeTags, let excludeTags):
            var search = scope
            switch kind {
            case .new:
                search += " is:new"
                term.order = .added
                config.reschedule = true
            case .due:
                search += " is:due"
                term.order = .due
                config.reschedule = true
            case .review:
                search += " -is:new"
                term.order = .random
                config.reschedule = true
            case .all:
                term.order = .random
                config.reschedule = false
            }
            let include = includeTags.filter { !$0.isEmpty }
            if !include.isEmpty {
                search += " (" + include.map { "\"tag:\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: " or ") + ")"
            }
            for tag in excludeTags where !tag.isEmpty {
                search += " -\"tag:\(tag.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            term.search = search
            term.limit = max(1, limit)
        case .increaseNewLimit, .increaseReviewLimit:
            break
        }
        config.terms = [term]

        var session: Deck
        if let existing = try deck(named: Txn.customStudyDeckName), existing.isFiltered {
            session = existing
            session.kind = .filtered(config)
            try saveDeck(&session)
        } else {
            let name = try availableDeckName(Txn.customStudyDeckName)
            session = try addDeck(named: name, filtered: config)
        }
        let moved = try rebuildFilteredDeck(session.id)
        if moved == 0 {
            throw CollectionError.invalidInput("Nenhum card corresponde às opções escolhidas.")
        }
        return session.id
    }
}
