import Foundation
import GRDB
import RecordaCore

/// Card já existente, visto pelo simulador.
public struct SimulatedCard: Sendable, Equatable {
    public var stability: Double
    public var difficulty: Double
    /// Dias (a partir de hoje = 0) até o vencimento; negativo = atrasado.
    public var dueInDays: Int
    /// Há quantos dias foi a última revisão.
    public var daysSinceLastReview: Int

    public init(stability: Double, difficulty: Double, dueInDays: Int, daysSinceLastReview: Int) {
        self.stability = stability; self.difficulty = difficulty
        self.dueInDays = dueInDays; self.daysSinceLastReview = daysSinceLastReview
    }
}

public struct SimulatorConfig: Sendable, Equatable {
    public var parameters: [Double] = []
    public var desiredRetention: Double = 0.9
    public var days: Int = 365
    /// Cards novos ainda não estudados que entrarão ao longo da simulação.
    public var newCardsAvailable: Int = 0
    public var newPerDay: Int = 20
    public var reviewsPerDay: Int = 200
    public var maximumInterval: Int = 36_500
    public var newCardsIgnoreReviewLimit: Bool = false
    /// Probabilidades da primeira nota de um card novo (Errei, Difícil, Bom, Fácil).
    public var firstRatingProbabilities: [Double] = [0.24, 0.094, 0.495, 0.171]
    /// Probabilidades de Difícil, Bom e Fácil quando o card é lembrado.
    public var recallRatingProbabilities: [Double] = [0.224, 0.631, 0.145]
    /// Segundos gastos, em média, por tipo de resposta.
    public var secondsPerNewCard: Double = 20
    public var secondsPerRecall: Double = 8
    public var secondsPerLapse: Double = 25
    public var seed: UInt64 = 42

    public init() {}
}

public struct SimulatedDay: Sendable, Equatable, Identifiable {
    public var day: Int
    public var reviews: Int
    public var newCards: Int
    public var seconds: Double
    /// Soma da recuperabilidade de todos os cards já estudados ("cards memorizados").
    public var memorized: Double
    public var id: Int { day }
}

public struct SimulationResult: Sendable, Equatable {
    public var days: [SimulatedDay]
    public var totalReviews: Int { days.reduce(0) { $0 + $1.reviews } }
    public var totalSeconds: Double { days.reduce(0) { $0 + $1.seconds } }
    public var finalMemorized: Double { days.last?.memorized ?? 0 }
    public var averageSecondsPerDay: Double { days.isEmpty ? 0 : totalSeconds / Double(days.count) }
}

/// Simulador de carga de trabalho: projeta revisões, tempo e retenção para uma configuração.
public enum FSRSSimulator {

    private struct State {
        var stability: Double
        var difficulty: Double
        var due: Int
        var lastReview: Int
    }

    private static func pick(_ probabilities: [Double], _ generator: inout SeededGenerator) -> Int {
        let total = probabilities.reduce(0, +)
        guard total > 0 else { return 0 }
        var target = generator.unit() * total
        for (index, p) in probabilities.enumerated() {
            if target < p { return index }
            target -= p
        }
        return probabilities.count - 1
    }

    public static func simulate(config: SimulatorConfig, existing: [SimulatedCard] = []) -> SimulationResult {
        let fsrs = FSRS(parameters: config.parameters)
        var generator = SeededGenerator(seed: config.seed)
        var cards: [State] = existing.map {
            State(stability: max($0.stability, FSRS.minStability), difficulty: $0.difficulty,
                  due: $0.dueInDays, lastReview: -max(0, $0.daysSinceLastReview))
        }
        var remainingNew = max(0, config.newCardsAvailable)
        let maxInterval = max(1, config.maximumInterval)
        var result: [SimulatedDay] = []
        result.reserveCapacity(max(0, config.days))

        func nextInterval(_ stability: Double) -> Int {
            let raw = fsrs.interval(stability: stability, desiredRetention: config.desiredRetention)
            return min(max(Int(raw.rounded()), 1), maxInterval)
        }

        for day in 0..<max(0, config.days) {
            var reviews = 0
            var seconds = 0.0

            // Revisões vencidas, das mais atrasadas para as menos.
            var dueIndices: [Int] = []
            for index in cards.indices where cards[index].due <= day { dueIndices.append(index) }
            dueIndices.sort { cards[$0].due < cards[$1].due }
            for index in dueIndices.prefix(max(0, config.reviewsPerDay)) {
                var card = cards[index]
                let elapsed = Double(max(0, day - card.lastReview))
                let retrievability = fsrs.retrievability(elapsedDays: elapsed, stability: card.stability)
                let rating: Int
                if generator.unit() < retrievability {
                    rating = 2 + pick(config.recallRatingProbabilities, &generator)
                    seconds += config.secondsPerRecall
                } else {
                    rating = 1
                    seconds += config.secondsPerLapse
                }
                let next = fsrs.next(state: FSRSMemoryState(stability: card.stability, difficulty: card.difficulty),
                                     rating: rating, elapsedDays: elapsed)
                card.stability = next.stability
                card.difficulty = next.difficulty
                card.lastReview = day
                card.due = day + nextInterval(next.stability)
                cards[index] = card
                reviews += 1
            }

            // Cards novos.
            var newToday = min(config.newPerDay, remainingNew)
            if !config.newCardsIgnoreReviewLimit {
                newToday = min(newToday, max(0, config.reviewsPerDay - reviews))
            }
            for _ in 0..<max(0, newToday) {
                let rating = 1 + pick(config.firstRatingProbabilities, &generator)
                let state = fsrs.initialState(rating: rating)
                cards.append(State(stability: state.stability, difficulty: state.difficulty,
                                   due: day + nextInterval(state.stability), lastReview: day))
                seconds += config.secondsPerNewCard
            }
            remainingNew -= max(0, newToday)

            var memorized = 0.0
            for card in cards {
                memorized += fsrs.retrievability(elapsedDays: Double(max(0, day - card.lastReview)), stability: card.stability)
            }
            result.append(SimulatedDay(day: day, reviews: reviews, newCards: max(0, newToday), seconds: seconds, memorized: memorized))
        }
        return SimulationResult(days: result)
    }
}

extension Txn {
    /// Monta a entrada do simulador a partir dos cards que usam a predefinição.
    public func simulatorInput(presetID: DeckConfigID) throws -> (config: SimulatorConfig, existing: [SimulatedCard]) {
        let preset = try deckConfig(presetID)
        let timing = try self.timing()
        let fsrs = FSRS(parameters: preset.config.fsrsParams)
        let filter = try presetCardFilterSQL(presetID)

        var config = SimulatorConfig()
        config.parameters = preset.config.fsrsParams
        config.desiredRetention = preset.config.desiredRetention
        config.newPerDay = preset.config.newPerDay
        config.reviewsPerDay = preset.config.reviewsPerDay
        config.maximumInterval = preset.config.maximumReviewInterval
        config.newCardsIgnoreReviewLimit = preset.config.newCardsIgnoreReviewLimit
        config.newCardsAvailable = try Int.fetchOne(db, sql: "SELECT count(*) FROM cards c WHERE c.type = 0 AND c.queue != -1 AND \(filter)") ?? 0

        var existing: [SimulatedCard] = []
        let cards = try Card.fetchAll(db, sql: "SELECT c.* FROM cards c WHERE c.type IN (2, 3) AND c.queue != -1 AND \(filter)")
        for card in cards {
            let data = card.cardData
            let state: FSRSMemoryState
            if let s = data.s, let d = data.d, s > 0 {
                state = FSRSMemoryState(stability: s, difficulty: d)
            } else {
                state = fsrs.memoryState(fromSM2Ease: Double(max(card.factor, 1300)) / 1000.0, interval: Double(max(card.ivl, 1)))
            }
            let realDue = card.odid != 0 && card.odue != 0 ? card.odue : card.due
            let dueIn = card.type == .review ? Int(realDue) - timing.today : 0
            let last = data.lrt.map { timing.today - timing.dayIndex(forEpochSecs: $0) } ?? max(0, card.ivl - dueIn)
            existing.append(SimulatedCard(stability: state.stability, difficulty: state.difficulty,
                                          dueInDays: dueIn, daysSinceLastReview: max(0, last)))
        }

        // Estima tempos e distribuição de notas a partir do histórico recente, quando há dados.
        let cutoff = (timing.now - 90 * 86_400) * 1000
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.type AS kind, r.ease AS ease, count(*) AS n, avg(r.time) AS ms FROM revlog r
            WHERE r.id > ? AND r.ease BETWEEN 1 AND 4 AND r.type IN (0, 1)
            AND r.cid IN (SELECT c.id FROM cards c WHERE \(filter))
            GROUP BY r.type, r.ease
            """, arguments: [cutoff])
        var recallCounts = [Double](repeating: 0, count: 3)
        var recallTime = 0.0, recallN = 0.0, lapseTime = 0.0, lapseN = 0.0, learnTime = 0.0, learnN = 0.0
        for row in rows {
            let kind: Int = row["kind"]
            let ease: Int = row["ease"]
            let n: Double = row["n"]
            let ms: Double = row["ms"] ?? 0
            if kind == 1 {
                if ease == 1 {
                    lapseTime += ms * n
                    lapseN += n
                } else {
                    recallCounts[ease - 2] += n
                    recallTime += ms * n
                    recallN += n
                }
            } else {
                learnTime += ms * n
                learnN += n
            }
        }
        if recallN >= 100 {
            config.recallRatingProbabilities = recallCounts.map { $0 / recallN }
            config.secondsPerRecall = max(1, recallTime / recallN / 1000)
        }
        if lapseN >= 20 {
            // Um lapso custa a resposta errada mais os passos de reaprendizado.
            config.secondsPerLapse = max(1, lapseTime / lapseN / 1000) * 2.5
        }
        if learnN >= 100 {
            // Um card novo costuma exigir algumas respostas no primeiro dia.
            config.secondsPerNewCard = max(1, learnTime / learnN / 1000) * 2.5
        }
        return (config, existing)
    }
}
