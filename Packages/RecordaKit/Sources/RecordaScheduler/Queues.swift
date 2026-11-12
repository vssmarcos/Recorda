import Foundation
import GRDB
import RecordaCore

public struct DeckCounts: Sendable, Equatable {
    public var new: Int
    public var learning: Int
    public var review: Int

    public init(new: Int = 0, learning: Int = 0, review: Int = 0) {
        self.new = new; self.learning = learning; self.review = review
    }

    public var total: Int { new + learning + review }
}

/// Nó da árvore de baralhos, com os contadores do dia já limitados.
public struct DeckTreeNode: Sendable, Identifiable, Equatable {
    public var deck: Deck
    public var counts: DeckCounts
    public var children: [DeckTreeNode]
    /// Total de cards no baralho e nos sub-baralhos.
    public var totalCards: Int

    public var id: DeckID { deck.id }
    public var level: Int { deck.level }

    /// Lista achatada respeitando o estado recolhido/expandido.
    public func flattened(respectingCollapsed: Bool = true) -> [DeckTreeNode] {
        var result = [self]
        if !(respectingCollapsed && deck.common.collapsed) {
            for child in children { result += child.flattened(respectingCollapsed: respectingCollapsed) }
        }
        return result
    }
}

public enum QueueEntryKind: Int, Sendable {
    case new, review, dayLearning, learning, preview
}

public struct QueueEntry: Sendable, Equatable, Identifiable {
    public var cardID: CardID
    public var kind: QueueEntryKind
    /// Para aprendizado intradiário e pré-visualização: epoch (s) do vencimento.
    public var due: Int64
    public var id: CardID { cardID }
}

/// Fila de estudo do dia para um baralho.
public struct StudyQueue: Sendable, Equatable {
    /// Novos, revisões e aprendizado interdiário, já na ordem de exibição.
    public var main: [QueueEntry]
    /// Aprendizado intradiário, por ordem de vencimento.
    public var intraday: [QueueEntry]
    public var learnAheadSecs: Int
    public var nextDayAt: Int64

    public var counts: DeckCounts {
        var counts = DeckCounts()
        for entry in main {
            switch entry.kind {
            case .new: counts.new += 1
            case .review: counts.review += 1
            default: counts.learning += 1
            }
        }
        counts.learning += intraday.filter { $0.due < nextDayAt }.count
        return counts
    }

    /// Próximo card a mostrar no instante `now`, ou `nil` se não houver nada por ora.
    public func next(now: Int64) -> QueueEntry? {
        if let first = intraday.first, first.due <= now { return first }
        if let first = main.first { return first }
        if let first = intraday.first, first.due <= now + Int64(learnAheadSecs) { return first }
        return nil
    }

    /// Vencimento do próximo card em aprendizado ainda hoje (para "volte em X minutos").
    public var nextLearningDue: Int64? {
        intraday.first(where: { $0.due < nextDayAt })?.due
    }

    public var isEmpty: Bool { main.isEmpty && intraday.isEmpty }
}

/// Situação de um baralho quando não há mais nada a estudar agora.
public struct CongratsInfo: Sendable, Equatable {
    public var isFiltered: Bool
    /// Há cards novos disponíveis além do limite diário.
    public var newCardsBeyondLimit: Int
    /// Há revisões vencidas além do limite diário.
    public var reviewsBeyondLimit: Int
    public var userBuried: Int
    public var schedBuried: Int
    /// Segundos até o próximo card em aprendizado, se houver algum hoje.
    public var secondsUntilNextLearning: Int?
}

enum QueueHash {
    /// Valor pseudoaleatório estável para (id, semente).
    static func value(_ id: Int64, seed: Int) -> Double { Fuzz.factor(cardID: id, reps: seed) }

    /// Expressão SQL equivalente (não precisa coincidir com `value`; só precisa ser estável no dia).
    static func sql(_ column: String, seed: Int) -> String {
        "(((\(column) % 1000003) * 7919 + \(abs(seed) % 100_000) * 104729) % 1000003)"
    }
}

struct DeckLimits {
    var new: Int
    var review: Int
    var newIgnoresReviewLimit: Bool
    static let unlimited = 1_000_000_000
}

extension Txn {

    // MARK: Limites

    func remainingLimits(for deck: Deck, config: DeckConfigData, today: Int) -> DeckLimits {
        guard let normal = deck.normal else {
            return DeckLimits(new: DeckLimits.unlimited, review: DeckLimits.unlimited, newIgnoresReviewLimit: true)
        }
        var newLimit = normal.newLimit ?? config.newPerDay
        var reviewLimit = normal.reviewLimit ?? config.reviewsPerDay
        if let onlyToday = normal.newLimitToday, onlyToday.day == today { newLimit = onlyToday.count }
        if let onlyToday = normal.reviewLimitToday, onlyToday.day == today { reviewLimit = onlyToday.count }
        if normal.extendNew.day == today { newLimit += normal.extendNew.count }
        if normal.extendReview.day == today { reviewLimit += normal.extendReview.count }
        let studiedToday = deck.common.lastDayStudied == today
        let newDone = studiedToday ? deck.common.newStudied : 0
        let reviewDone = studiedToday ? deck.common.reviewStudied : 0
        return DeckLimits(new: max(0, newLimit - newDone), review: max(0, reviewLimit - reviewDone),
                          newIgnoresReviewLimit: config.newCardsIgnoreReviewLimit)
    }

    private func configsByID() throws -> [DeckConfigID: DeckConfigData] {
        var result: [DeckConfigID: DeckConfigData] = [:]
        for config in try allDeckConfigs() { result[config.id] = config.config }
        return result
    }

    private func config(for deck: Deck, in configs: [DeckConfigID: DeckConfigData]) -> DeckConfigData {
        if let id = deck.configID, let config = configs[id] { return config }
        return configs[1] ?? DeckConfigData()
    }

    // MARK: Árvore de baralhos

    private struct RawCounts {
        var new = 0, review = 0, dayLearning = 0, intraday = 0, total = 0
    }

    public func deckTree() throws -> [DeckTreeNode] {
        let timing = try self.timing()
        let decks = try allDecks()
        let configs = try configsByID()

        var raw: [DeckID: RawCounts] = [:]
        let rows = try Row.fetchAll(db, sql: """
            SELECT did,
                sum(queue = 0) AS n,
                sum(queue = 2 AND due <= ?) AS r,
                sum(queue = 3 AND due <= ?) AS dl,
                sum((queue = 1 AND due < ?) OR queue = 4) AS l,
                count(*) AS t
            FROM cards GROUP BY did
            """, arguments: [timing.today, timing.today, timing.nextDayAt])
        for row in rows {
            raw[row["did"]] = RawCounts(new: row["n"] ?? 0, review: row["r"] ?? 0, dayLearning: row["dl"] ?? 0,
                                        intraday: row["l"] ?? 0, total: row["t"] ?? 0)
        }

        // `decks` está em ordem hierárquica: os filhos de um baralho vêm logo depois dele.
        var index = 0
        func build(level: Int, prefix: String?) -> [DeckTreeNode] {
            var nodes: [DeckTreeNode] = []
            while index < decks.count {
                let deck = decks[index]
                if let prefix, !deck.isDescendant(ofName: prefix) { break }
                index += 1
                let children = build(level: level + 1, prefix: deck.name)
                let own = raw[deck.id] ?? RawCounts()
                let limits = remainingLimits(for: deck, config: config(for: deck, in: configs), today: timing.today)
                let childNew = children.reduce(0) { $0 + $1.counts.new }
                let childReview = children.reduce(0) { $0 + $1.counts.review }
                let childLearning = children.reduce(0) { $0 + $1.counts.learning }
                let review = min(limits.review, own.review + childReview)
                var new = min(limits.new, own.new + childNew)
                if !limits.newIgnoresReviewLimit { new = min(new, max(0, limits.review - review)) }
                let counts = DeckCounts(new: new, learning: own.intraday + own.dayLearning + childLearning, review: review)
                let total = own.total + children.reduce(0) { $0 + $1.totalCards }
                nodes.append(DeckTreeNode(deck: deck, counts: counts, children: children, totalCards: total))
            }
            return nodes
        }
        return build(level: 0, prefix: nil)
    }

    /// Contadores de um único baralho (com sub-baralhos).
    public func counts(forDeck deckID: DeckID) throws -> DeckCounts {
        func find(_ nodes: [DeckTreeNode]) -> DeckTreeNode? {
            for node in nodes {
                if node.id == deckID { return node }
                if let found = find(node.children) { return found }
            }
            return nil
        }
        return find(try deckTree())?.counts ?? DeckCounts()
    }

    // MARK: Fila de estudo

    private struct Candidate {
        var id: CardID
        var nid: NoteID
        var did: DeckID
        var ord: Int
        var due: Int64
        var key: Double
    }

    private func reviewKeySQL(_ order: ReviewCardOrder, today: Int, fsrs: Bool, decay: Double) -> String {
        let realDue = "(CASE WHEN odid != 0 AND odue != 0 THEN odue ELSE due END)"
        switch order {
        case .day, .dayThenDeck, .deckThenDay:
            return "due"
        case .intervalsAscending:
            return "ivl"
        case .intervalsDescending:
            return "-ivl"
        case .easeAscending:
            return fsrs ? "-COALESCE(json_extract(NULLIF(data, ''), '$.d'), 5.0)" : "factor"
        case .easeDescending:
            return fsrs ? "COALESCE(json_extract(NULLIF(data, ''), '$.d'), 5.0)" : "-factor"
        case .retrievabilityAscending, .retrievabilityDescending:
            let sm2 = "(1.0 / (1.0 + max(0, \(today) - \(realDue) + ivl) * 1.0 / max(ivl, 1)))"
            let expression: String
            if fsrs {
                expression = "COALESCE(fsrs_r(json_extract(NULLIF(data, ''), '$.s'), max(0, \(today) - (\(realDue) - ivl)), \(decay)), \(sm2))"
            } else {
                expression = sm2
            }
            return order == .retrievabilityAscending ? expression : "-\(expression)"
        case .random:
            return QueueHash.sql("id", seed: today)
        case .added:
            return "id"
        case .reverseAdded:
            return "-id"
        }
    }

    /// Monta a fila do dia para o baralho (e sub-baralhos), respeitando limites e ordem de exibição.
    public func studyQueue(deckID: DeckID) throws -> StudyQueue {
        try unburyIfNewDay()
        let timing = try self.timing()
        let today = timing.today
        let decks = try deckAndChildren(deckID)
        guard let root = decks.first else {
            return StudyQueue(main: [], intraday: [], learnAheadSecs: 0, nextDayAt: timing.nextDayAt)
        }
        let configs = try configsByID()
        let rootConfig = config(for: root, in: configs)
        let fsrs = try fsrsEnabled()
        let decay = FSRS(parameters: rootConfig.fsrsParams).decay

        // Limites restantes e cadeia de ancestrais (dentro da seleção) de cada baralho.
        var limits: [DeckID: DeckLimits] = [:]
        var chains: [DeckID: [DeckID]] = [:]
        var deckIndex: [DeckID: Int] = [:]
        var idByName: [String: DeckID] = [:]
        for (index, deck) in decks.enumerated() {
            limits[deck.id] = remainingLimits(for: deck, config: config(for: deck, in: configs), today: today)
            deckIndex[deck.id] = index
            idByName[deck.name.lowercased()] = deck.id
        }
        let rootDepth = root.components.count
        for deck in decks {
            let parts = deck.components
            var chain: [DeckID] = []
            if parts.count >= rootDepth {
                for depth in rootDepth...parts.count {
                    let name = parts.prefix(depth).joined(separator: Deck.separator).lowercased()
                    if let id = idByName[name] { chain.append(id) }
                }
            }
            if chain.isEmpty { chain = [deck.id] }
            chains[deck.id] = chain
        }

        func reviewRoom(_ deckID: DeckID) -> Int {
            (chains[deckID] ?? [deckID]).map { limits[$0]?.review ?? 0 }.min() ?? 0
        }
        func newRoom(_ deckID: DeckID) -> Int {
            (chains[deckID] ?? [deckID]).map { id -> Int in
                guard let limit = limits[id] else { return 0 }
                return limit.newIgnoresReviewLimit ? limit.new : min(limit.new, limit.review)
            }.min() ?? 0
        }

        // --- Revisões ---
        let keySQL = reviewKeySQL(rootConfig.reviewOrder, today: today, fsrs: fsrs, decay: decay)
        var reviewCandidates: [Candidate] = []
        for deck in decks {
            let room = reviewRoom(deck.id)
            guard room > 0 else { continue }
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, nid, did, ord, due, (\(keySQL)) AS k FROM cards
                WHERE did = ? AND queue = 2 AND due <= ? ORDER BY k, id LIMIT ?
                """, arguments: [deck.id, today, room])
            for row in rows {
                reviewCandidates.append(Candidate(id: row["id"], nid: row["nid"], did: row["did"], ord: row["ord"],
                                                  due: row["due"], key: row["k"] ?? 0))
            }
        }
        let seed = today
        switch rootConfig.reviewOrder {
        case .day:
            reviewCandidates.sort { ($0.key, QueueHash.value($0.id, seed: seed)) < ($1.key, QueueHash.value($1.id, seed: seed)) }
        case .dayThenDeck:
            reviewCandidates.sort {
                ($0.key, deckIndex[$0.did] ?? 0, QueueHash.value($0.id, seed: seed)) < ($1.key, deckIndex[$1.did] ?? 0, QueueHash.value($1.id, seed: seed))
            }
        case .deckThenDay:
            reviewCandidates.sort {
                (deckIndex[$0.did] ?? 0, $0.key, QueueHash.value($0.id, seed: seed)) < (deckIndex[$1.did] ?? 0, $1.key, QueueHash.value($1.id, seed: seed))
            }
        default:
            reviewCandidates.sort { ($0.key, $0.id) < ($1.key, $1.id) }
        }
        var reviews: [QueueEntry] = []
        for candidate in reviewCandidates where reviewRoom(candidate.did) > 0 {
            for id in chains[candidate.did] ?? [candidate.did] { limits[id]?.review -= 1 }
            reviews.append(QueueEntry(cardID: candidate.id, kind: .review, due: candidate.due))
        }

        // --- Aprendizado interdiário ---
        let deckList = Txn.idList(decks.map(\.id))
        let dayLearning = try Row.fetchAll(db, sql: """
            SELECT id, due FROM cards WHERE did IN (\(deckList)) AND queue = 3 AND due <= ? ORDER BY due, id
            """, arguments: [today]).map { QueueEntry(cardID: $0["id"], kind: .dayLearning, due: $0["due"]) }

        // --- Novos ---
        let gather = rootConfig.newCardGatherPriority
        let newOrderSQL: String
        switch gather {
        case .deck, .lowestPosition: newOrderSQL = "due, ord, id"
        case .highestPosition: newOrderSQL = "due DESC, ord, id"
        case .deckThenRandomNotes, .randomNotes: newOrderSQL = "\(QueueHash.sql("nid", seed: today)), nid, ord"
        case .randomCards: newOrderSQL = "\(QueueHash.sql("id", seed: today)), id"
        }
        var newCandidates: [Candidate] = []
        for deck in decks {
            let room = newRoom(deck.id)
            guard room > 0 else { continue }
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, nid, did, ord, due FROM cards WHERE did = ? AND queue = 0 ORDER BY \(newOrderSQL) LIMIT ?
                """, arguments: [deck.id, room])
            for row in rows {
                newCandidates.append(Candidate(id: row["id"], nid: row["nid"], did: row["did"], ord: row["ord"],
                                               due: row["due"], key: 0))
            }
        }
        switch gather {
        case .deck, .deckThenRandomNotes:
            break
        case .lowestPosition:
            newCandidates.sort { ($0.due, $0.ord, $0.id) < ($1.due, $1.ord, $1.id) }
        case .highestPosition:
            newCandidates.sort { (-$0.due, $0.ord, $0.id) < (-$1.due, $1.ord, $1.id) }
        case .randomNotes:
            newCandidates.sort { (QueueHash.value($0.nid, seed: seed), $0.ord) < (QueueHash.value($1.nid, seed: seed), $1.ord) }
        case .randomCards:
            newCandidates.sort { QueueHash.value($0.id, seed: seed) < QueueHash.value($1.id, seed: seed) }
        }
        var gatheredNew: [Candidate] = []
        for candidate in newCandidates where newRoom(candidate.did) > 0 {
            for id in chains[candidate.did] ?? [candidate.did] {
                limits[id]?.new -= 1
                if limits[id]?.newIgnoresReviewLimit == false { limits[id]?.review -= 1 }
            }
            gatheredNew.append(candidate)
        }
        switch rootConfig.newCardSortOrder {
        case .template:
            // Ordenação estável por modelo, preservando a ordem de coleta.
            gatheredNew = gatheredNew.enumerated().sorted { ($0.element.ord, $0.offset) < ($1.element.ord, $1.offset) }.map(\.element)
        case .noSort:
            break
        case .templateThenRandom:
            gatheredNew.sort { ($0.ord, QueueHash.value($0.id, seed: seed)) < ($1.ord, QueueHash.value($1.id, seed: seed)) }
        case .randomNoteThenTemplate:
            gatheredNew.sort { (QueueHash.value($0.nid, seed: seed), $0.ord) < (QueueHash.value($1.nid, seed: seed), $1.ord) }
        case .randomCard:
            gatheredNew.sort { QueueHash.value($0.id, seed: seed) < QueueHash.value($1.id, seed: seed) }
        }
        let newEntries = gatheredNew.map { QueueEntry(cardID: $0.id, kind: .new, due: $0.due) }

        // --- Mistura ---
        var main = Txn.combine(reviews, dayLearning, mix: rootConfig.interdayLearningMix)
        main = Txn.combine(main, newEntries, mix: rootConfig.newMix)

        // --- Aprendizado intradiário e pré-visualização ---
        let intraday = try Row.fetchAll(db, sql: """
            SELECT id, due, queue FROM cards WHERE did IN (\(deckList)) AND queue IN (1, 4) ORDER BY due, id
            """).map { row -> QueueEntry in
                let queue: Int = row["queue"]
                return QueueEntry(cardID: row["id"], kind: queue == 4 ? .preview : .learning, due: row["due"])
            }

        return StudyQueue(main: main, intraday: intraday, learnAheadSecs: try learnAheadSecs(), nextDayAt: timing.nextDayAt)
    }

    /// Junta `extra` a `base` conforme a opção de mistura.
    static func combine(_ base: [QueueEntry], _ extra: [QueueEntry], mix: ReviewMix) -> [QueueEntry] {
        if extra.isEmpty { return base }
        if base.isEmpty { return extra }
        switch mix {
        case .afterReviews: return base + extra
        case .beforeReviews: return extra + base
        case .mixWithReviews:
            // Distribui `extra` uniformemente ao longo de `base`.
            var positioned: [(Double, Int, QueueEntry)] = []
            for (index, entry) in base.enumerated() {
                positioned.append(((Double(index) + 0.5) / Double(base.count), 0, entry))
            }
            for (index, entry) in extra.enumerated() {
                positioned.append(((Double(index) + 0.5) / Double(extra.count), 1, entry))
            }
            positioned.sort { ($0.0, $0.1) < ($1.0, $1.1) }
            return positioned.map(\.2)
        }
    }

    // MARK: Fim da sessão

    public func congratsInfo(deckID: DeckID) throws -> CongratsInfo {
        let timing = try self.timing()
        let decks = try deckAndChildren(deckID)
        let deckList = Txn.idList(decks.map(\.id))
        let counts = try self.counts(forDeck: deckID)
        let availableNew = try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE did IN (\(deckList)) AND queue = 0") ?? 0
        let availableReview = try Int.fetchOne(db, sql: "SELECT count(*) FROM cards WHERE did IN (\(deckList)) AND queue = 2 AND due <= ?",
                                               arguments: [timing.today]) ?? 0
        let buried = try buriedCount(inDeck: deckID)
        let nextLearning = try Int64.fetchOne(db, sql: """
            SELECT min(due) FROM cards WHERE did IN (\(deckList)) AND queue = 1 AND due < ?
            """, arguments: [timing.nextDayAt])
        return CongratsInfo(
            isFiltered: decks.first?.isFiltered ?? false,
            newCardsBeyondLimit: max(0, availableNew - counts.new),
            reviewsBeyondLimit: max(0, availableReview - counts.review),
            userBuried: buried.user, schedBuried: buried.sched,
            secondsUntilNextLearning: nextLearning.map { max(0, Int($0 - timing.now)) })
    }
}
