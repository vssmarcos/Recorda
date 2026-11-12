import Foundation
import GRDB
import RecordaCore
import RecordaSearch

/// Histórico de um card convertido para o formato do FSRS.
public struct FSRSCardHistory: Sendable, Equatable {
    public var cardID: CardID
    public var reviews: [FSRS.Review]
    /// O histórico começa na primeira resposta do card (não foi truncado).
    public var isComplete: Bool
}

extension Txn {

    /// Lê o revlog e monta o histórico FSRS dos cards selecionados pela cláusula dada.
    ///
    /// Regras de conversão:
    /// - entradas manuais (nota 0) são ignoradas; um "esquecer" (manual com intervalo 0) zera o histórico;
    /// - respostas de pré-visualização em baralhos filtrados são ignoradas;
    /// - o tempo decorrido é a diferença em dias do agendador entre respostas consecutivas.
    public func fsrsHistories(cardFilterSQL: String = "1", arguments: StatementArguments = StatementArguments()) throws -> [FSRSCardHistory] {
        let timing = try self.timing()
        var result: [FSRSCardHistory] = []
        var currentID: CardID = -1
        var reviews: [FSRS.Review] = []
        var complete = false
        var lastDay = 0

        func flush() {
            if currentID != -1 && !reviews.isEmpty {
                result.append(FSRSCardHistory(cardID: currentID, reviews: reviews, isComplete: complete))
            }
            reviews = []
            complete = false
        }

        let cursor = try Row.fetchCursor(db, sql: """
            SELECT r.cid, r.id, r.ease, r.ivl, r.type FROM revlog r
            WHERE r.cid IN (SELECT c.id FROM cards c JOIN notes n ON n.id = c.nid WHERE \(cardFilterSQL))
            ORDER BY r.cid, r.id
            """, arguments: arguments)
        while let row = try cursor.next() {
            let cid: Int64 = row["cid"]
            if cid != currentID {
                flush()
                currentID = cid
            }
            let ease: Int = row["ease"]
            let interval: Int = row["ivl"]
            let kind: Int = row["type"]
            if kind == RevlogKind.manual.rawValue || ease == 0 {
                if interval == 0 {
                    // Card foi reiniciado: o que veio antes não conta.
                    reviews = []
                    complete = false
                }
                continue
            }
            if kind == RevlogKind.filtered.rawValue && interval == 0 { continue }
            guard (1...4).contains(ease) else { continue }
            let id: Int64 = row["id"]
            let day = timing.dayIndex(forEpochSecs: id / 1000)
            if reviews.isEmpty {
                complete = kind == RevlogKind.learning.rawValue
                reviews.append(FSRS.Review(rating: ease, elapsedDays: 0))
            } else {
                reviews.append(FSRS.Review(rating: ease, elapsedDays: max(0, day - lastDay)))
            }
            lastDay = day
        }
        flush()
        return result
    }

    /// Cláusula SQL (sobre `cards c`) que seleciona os cards dos baralhos que usam a predefinição.
    public func presetCardFilterSQL(_ presetID: DeckConfigID) throws -> String {
        let deckIDs = try allDecks().filter { $0.configID == presetID }.map(\.id)
        if deckIDs.isEmpty { return "0" }
        let list = Txn.idList(deckIDs)
        return "(CASE WHEN c.odid != 0 THEN c.odid ELSE c.did END) IN (\(list))"
    }

    /// Recalcula estabilidade e dificuldade de todos os cards (ou só dos de uma predefinição)
    /// a partir do histórico. Usado ao ativar o FSRS ou ao mudar os parâmetros.
    @discardableResult
    public func recomputeMemoryStates(presetID: DeckConfigID? = nil) throws -> Int {
        let presets = try presetID.map { [try deckConfig($0)] } ?? allDeckConfigs()
        var updated = 0
        for preset in presets {
            let filter = try presetCardFilterSQL(preset.id)
            let fsrs = FSRS(parameters: preset.config.fsrsParams)
            var histories: [CardID: FSRSCardHistory] = [:]
            for history in try fsrsHistories(cardFilterSQL: filter) { histories[history.cardID] = history }

            let cards = try Card.fetchAll(db, sql: "SELECT c.* FROM cards c WHERE c.type != 0 AND \(filter)")
            for var card in cards {
                var state: FSRSMemoryState?
                if let history = histories[card.id], history.isComplete {
                    state = fsrs.memoryState(history: history.reviews)
                } else if card.type == .review || card.type == .relearning {
                    state = fsrs.memoryState(fromSM2Ease: Double(max(card.factor, 1300)) / 1000.0,
                                             interval: Double(max(card.ivl, 1)))
                }
                var data = card.cardData
                let before = data
                data.s = state?.stability
                data.d = state?.difficulty
                data.dr = state == nil ? nil : preset.config.desiredRetention
                if data != before {
                    card.cardData = data
                    try saveCard(&card)
                    updated += 1
                }
            }
        }
        return updated
    }

    /// Remove o estado FSRS de todos os cards (ao voltar para o SM-2).
    public func clearMemoryStates() throws {
        let cards = try Card.fetchAll(db, sql: "SELECT * FROM cards WHERE data LIKE '%\"s\"%'")
        for var card in cards {
            var data = card.cardData
            data.s = nil
            data.d = nil
            data.dr = nil
            card.cardData = data
            try saveCard(&card)
        }
    }

    /// Liga ou desliga o FSRS, ajustando os estados de memória.
    public func setFSRSEnabled(_ enabled: Bool) throws {
        try setConfig(ConfigKey.fsrsEnabled, enabled)
        if enabled { try recomputeMemoryStates() } else { try clearMemoryStates() }
    }
}
