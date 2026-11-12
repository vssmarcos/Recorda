import Foundation
import RecordaCore

public enum Rating: Int, Sendable, CaseIterable, Codable {
    case again = 1, hard = 2, good = 3, easy = 4
}

/// Tudo o que o agendador precisa para calcular o próximo estado de um card.
public struct AnswerContext {
    public var config: DeckConfigData
    public var timing: SchedTiming
    public var fsrsEnabled: Bool
    /// `nil` desliga o fuzz (testes e pré-visualizações determinísticas).
    public var fuzzFactor: Double?
    /// Presente quando o card está em um baralho filtrado.
    public var filtered: FilteredDeck?
    public var loadBalancer: LoadBalancer?

    public init(config: DeckConfigData, timing: SchedTiming, fsrsEnabled: Bool, fuzzFactor: Double? = nil,
                filtered: FilteredDeck? = nil, loadBalancer: LoadBalancer? = nil) {
        self.config = config; self.timing = timing; self.fsrsEnabled = fsrsEnabled
        self.fuzzFactor = fuzzFactor; self.filtered = filtered; self.loadBalancer = loadBalancer
    }
}

/// Resultado de aplicar uma resposta a um card (ainda não gravado).
public struct AnswerOutcome: Sendable, Equatable {
    public var rating: Rating
    /// Card com os novos valores de agendamento.
    public var card: Card
    /// Tempo até a próxima exibição, em segundos (para o rótulo do botão).
    public var delaySecs: Int
    public var revlogInterval: Int
    public var revlogLastInterval: Int
    public var revlogFactor: Int
    public var revlogKind: RevlogKind
    /// A resposta transformou o card em sanguessuga.
    public var isLeech: Bool
    /// Resposta de pré-visualização (baralho filtrado sem reagendamento): não altera o agendamento.
    public var isPreview: Bool
}

public enum StateMachine {

    static let learningQueueCutoff: Int64 = 1_000_000_000

    // MARK: API

    /// Calcula os quatro resultados possíveis, na ordem Errei, Difícil, Bom, Fácil.
    public static func outcomes(for card: Card, context: AnswerContext) -> [AnswerOutcome] {
        Rating.allCases.map { outcome(for: card, rating: $0, context: context) }
    }

    public static func outcome(for original: Card, rating: Rating, context ctx: AnswerContext) -> AnswerOutcome {
        // Pré-visualização em baralho filtrado sem reagendamento.
        if original.odid != 0, let filtered = ctx.filtered, !filtered.reschedule {
            return previewOutcome(original, rating: rating, filtered: filtered, ctx: ctx)
        }

        var card = original
        let inFiltered = original.odid != 0
        if inFiltered && original.odue != 0 && original.type != .learning && original.type != .relearning {
            // Dentro do baralho filtrado o vencimento real fica em `odue`.
            card.due = original.odue
        }

        let helper = Calculator(card: card, ctx: ctx)
        var outcome: AnswerOutcome
        switch card.type {
        case .new:
            outcome = helper.answerLearning(rating, isNew: true, relearning: false)
        case .learning:
            outcome = helper.answerLearning(rating, isNew: false, relearning: false)
        case .relearning:
            outcome = helper.answerLearning(rating, isNew: false, relearning: true)
        case .review:
            outcome = helper.answerReview(rating)
        }

        outcome.card.reps = original.reps + 1
        var data = outcome.card.cardData
        data.lrt = ctx.timing.now
        if original.type == .new && data.pos == nil { data.pos = Int(card.due) }
        if ctx.fsrsEnabled {
            data.dr = ctx.config.desiredRetention
        } else {
            data.s = nil
            data.d = nil
            data.dr = nil
        }
        outcome.card.cardData = data

        if inFiltered {
            if outcome.card.queue == .review {
                // Voltou a ser revisão: retorna ao baralho de origem.
                outcome.card.did = original.odid
                outcome.card.odid = 0
                outcome.card.odue = 0
            } else {
                // Continua em aprendizado dentro do baralho filtrado; `due` passa a valer.
                outcome.card.did = original.did
                outcome.card.odid = original.odid
                outcome.card.odue = 0
            }
            if original.type == .review && card.due > Int64(ctx.timing.today) {
                outcome.revlogKind = .filtered
            }
        }
        return outcome
    }

    // MARK: Pré-visualização

    private static func previewOutcome(_ original: Card, rating: Rating, filtered: FilteredDeck, ctx: AnswerContext) -> AnswerOutcome {
        var card = original
        let delay: Int
        switch rating {
        case .again: delay = filtered.previewAgainSecs
        case .hard: delay = filtered.previewHardSecs
        case .good: delay = filtered.previewGoodSecs
        case .easy: delay = 0
        }
        if delay <= 0 {
            card.removeFromFilteredDeck()
        } else {
            if card.odue == 0 { card.odue = card.due }
            card.queue = .preview
            card.due = ctx.timing.now + Int64(delay)
        }
        return AnswerOutcome(rating: rating, card: card, delaySecs: max(delay, 0), revlogInterval: 0,
                             revlogLastInterval: original.type == .review ? original.ivl : 0,
                             revlogFactor: original.factor, revlogKind: .filtered, isLeech: false, isPreview: true)
    }

    // MARK: Cálculo

    struct Calculator {
        let card: Card
        let ctx: AnswerContext
        let fsrs: FSRS
        let today: Int
        let now: Int64

        init(card: Card, ctx: AnswerContext) {
            self.card = card
            self.ctx = ctx
            self.fsrs = FSRS(parameters: ctx.config.fsrsParams)
            self.today = ctx.timing.today
            self.now = ctx.timing.now
        }

        var config: DeckConfigData { ctx.config }
        var maxInterval: Int { max(1, config.maximumReviewInterval) }

        // MARK: FSRS

        /// Dias inteiros (do agendador) desde a última revisão.
        var elapsedDays: Int {
            let data = card.cardData
            if let last = data.lrt, last > 0 {
                let todayStart = ctx.timing.nextDayAt - 86_400
                if last >= todayStart { return 0 }
                return Int((Double(todayStart - last) / 86_400).rounded(.up))
            }
            if card.type == .review {
                return max(0, today - (Int(card.due) - card.ivl))
            }
            return 0
        }

        var currentMemory: FSRSMemoryState? {
            let data = card.cardData
            if let s = data.s, let d = data.d, s > 0 {
                return FSRSMemoryState(stability: s, difficulty: d)
            }
            if card.type == .review || card.type == .relearning {
                // Card sem estado FSRS (vindo do SM-2): estima a partir do intervalo e da facilidade.
                return fsrs.memoryState(fromSM2Ease: Double(max(card.factor, 1300)) / 1000.0,
                                        interval: Double(max(card.ivl, 1)))
            }
            return nil
        }

        func memory(after rating: Rating) -> FSRSMemoryState {
            fsrs.next(state: currentMemory, rating: rating.rawValue, elapsedDays: Double(elapsedDays))
        }

        func fsrsInterval(after rating: Rating) -> Double {
            fsrs.interval(stability: memory(after: rating).stability, desiredRetention: config.desiredRetention)
        }

        // MARK: Intervalos

        /// Arredonda, aplica fuzz/balanceamento e os limites mínimo e máximo.
        func constrain(_ raw: Double, minimum: Int, fuzz: Bool = true) -> Int {
            let minValue = min(max(minimum, 1), maxInterval)
            guard fuzz, let factor = ctx.fuzzFactor, raw >= 2.5 else {
                let rounded = raw.isFinite ? Int(min(raw, Double(maxInterval)).rounded()) : maxInterval
                return min(max(rounded, minValue), maxInterval)
            }
            let (lower, upper) = Fuzz.bounds(interval: raw, minimum: minValue, maximum: maxInterval)
            if let balancer = ctx.loadBalancer {
                return balancer.chooseInterval(lower: lower, upper: upper, today: today, factor: factor)
            }
            return Fuzz.apply(interval: raw, factor: factor, minimum: minValue, maximum: maxInterval)
        }

        func steps(relearning: Bool) -> [Int] {
            (relearning ? config.relearnSteps : config.learnSteps)
                .filter { $0 > 0 }
                .map { max(1, Int(($0 * 60).rounded())) }
        }

        // MARK: Montagem dos estados

        func fsrsFactor(_ memory: FSRSMemoryState) -> Int {
            Int((((memory.difficulty - 1.0) / 9.0) * 1000).rounded()) + 100
        }

        func applyMemory(_ card: inout Card, rating: Rating) {
            guard ctx.fsrsEnabled else { return }
            let state = self.memory(after: rating)
            var data = card.cardData
            data.s = state.stability
            data.d = state.difficulty
            card.cardData = data
        }

        func revlogFactor(for card: Card, rating: Rating) -> Int {
            ctx.fsrsEnabled ? fsrsFactor(memory(after: rating)) : card.factor
        }

        /// Intervalo anterior no formato do revlog (dias positivos ou segundos negativos).
        func lastIntervalForRevlog(relearning: Bool) -> Int {
            switch card.type {
            case .new: return 0
            case .review: return card.ivl
            case .learning, .relearning:
                let all = steps(relearning: relearning)
                guard !all.isEmpty else { return 0 }
                let remaining = min(max(card.remainingSteps, 1), all.count)
                return -all[all.count - remaining]
            }
        }

        func makeLearning(rating: Rating, remaining: Int, delay: Int, relearning: Bool, reviewInterval: Int?,
                          lapses: Int, factor: Int, leech: Bool) -> AnswerOutcome {
            var next = card
            next.type = relearning ? .relearning : .learning
            next.left = remaining
            next.lapses = lapses
            next.factor = factor
            if let reviewInterval { next.ivl = reviewInterval }
            if delay < 86_400 {
                next.queue = .learning
                // Pequena variação (até 25 %, no máximo 5 min) para não agrupar cards de aprendizado.
                var extra = 0
                if let fuzz = ctx.fuzzFactor, delay >= 60 {
                    extra = Int(Double(min(300, delay / 4)) * fuzz)
                }
                next.due = now + Int64(delay + extra)
            } else {
                next.queue = .dayLearning
                next.due = Int64(today + max(1, delay / 86_400))
            }
            next.odue = 0
            applyMemory(&next, rating: rating)
            return AnswerOutcome(
                rating: rating, card: next, delaySecs: delay, revlogInterval: -delay,
                revlogLastInterval: lastIntervalForRevlog(relearning: relearning),
                revlogFactor: revlogFactor(for: next, rating: rating),
                revlogKind: kind(relearning: relearning), isLeech: leech, isPreview: false)
        }

        func makeReview(rating: Rating, interval: Int, factor: Int, lapses: Int, relearning: Bool, leech: Bool) -> AnswerOutcome {
            var next = card
            next.type = .review
            next.queue = .review
            next.ivl = min(max(interval, 1), maxInterval)
            next.due = Int64(today + next.ivl)
            next.left = 0
            next.factor = factor
            next.lapses = lapses
            next.odue = 0
            applyMemory(&next, rating: rating)
            return AnswerOutcome(
                rating: rating, card: next, delaySecs: next.ivl * 86_400, revlogInterval: next.ivl,
                revlogLastInterval: lastIntervalForRevlog(relearning: relearning),
                revlogFactor: revlogFactor(for: next, rating: rating),
                revlogKind: kind(relearning: relearning), isLeech: leech, isPreview: false)
        }

        func kind(relearning: Bool) -> RevlogKind {
            switch card.type {
            case .new, .learning: return .learning
            case .review: return .review
            case .relearning: return .relearning
            }
        }

        var initialFactor: Int { Int((config.initialEase * 1000).rounded()) }

        // MARK: Novo / aprendendo / reaprendendo

        func answerLearning(_ rating: Rating, isNew: Bool, relearning: Bool) -> AnswerOutcome {
            let all = steps(relearning: relearning)
            let factor = card.factor > 0 ? card.factor : initialFactor
            let lapses = card.lapses

            if all.isEmpty {
                return answerWithoutSteps(rating, relearning: relearning, factor: factor)
            }

            let remaining = isNew ? all.count : min(max(card.remainingSteps, 1), all.count)
            let index = all.count - remaining
            let reviewInterval: Int? = relearning ? max(card.ivl, 1) : nil

            switch rating {
            case .again:
                return makeLearning(rating: rating, remaining: all.count, delay: all[0], relearning: relearning,
                                    reviewInterval: reviewInterval, lapses: lapses, factor: factor, leech: false)
            case .hard:
                let delay: Int
                if index == 0 {
                    if all.count > 1 {
                        delay = (all[0] + all[1]) / 2
                    } else {
                        delay = min(all[0] * 3 / 2, all[0] + 86_400)
                    }
                } else {
                    delay = all[index]
                }
                return makeLearning(rating: rating, remaining: remaining, delay: delay, relearning: relearning,
                                    reviewInterval: reviewInterval, lapses: lapses, factor: factor, leech: false)
            case .good:
                if remaining > 1 {
                    let nextRemaining = remaining - 1
                    return makeLearning(rating: rating, remaining: nextRemaining, delay: all[all.count - nextRemaining],
                                        relearning: relearning, reviewInterval: reviewInterval, lapses: lapses,
                                        factor: factor, leech: false)
                }
                return makeReview(rating: rating, interval: graduationInterval(.good, relearning: relearning),
                                  factor: factor, lapses: lapses, relearning: relearning, leech: false)
            case .easy:
                return makeReview(rating: rating, interval: graduationInterval(.easy, relearning: relearning),
                                  factor: factor, lapses: lapses, relearning: relearning, leech: false)
            }
        }

        func graduationInterval(_ rating: Rating, relearning: Bool) -> Int {
            if ctx.fsrsEnabled {
                let good = constrain(fsrsInterval(after: .good), minimum: 1)
                if rating == .easy {
                    return constrain(fsrsInterval(after: .easy), minimum: min(good + 1, maxInterval))
                }
                return good
            }
            if relearning {
                let base = max(card.ivl, 1)
                return min(rating == .easy ? base + 1 : base, maxInterval)
            }
            let good = constrain(Double(config.graduatingIntervalGood), minimum: 1)
            if rating == .easy {
                return constrain(Double(config.graduatingIntervalEasy), minimum: 1)
            }
            return good
        }

        /// Sem passos configurados: o card vai direto para revisão (ou, com FSRS, para um intervalo curto calculado).
        func answerWithoutSteps(_ rating: Rating, relearning: Bool, factor: Int) -> AnswerOutcome {
            if ctx.fsrsEnabled {
                let raw = fsrsInterval(after: rating)
                if raw < 0.5 {
                    let delay = max(60, Int((raw * 86_400).rounded()))
                    return makeLearning(rating: rating, remaining: 0, delay: delay, relearning: relearning,
                                        reviewInterval: relearning ? max(card.ivl, 1) : nil,
                                        lapses: card.lapses, factor: factor, leech: false)
                }
                var minimum = 1
                if rating == .easy {
                    minimum = min(constrain(fsrsInterval(after: .good), minimum: 1) + 1, maxInterval)
                }
                return makeReview(rating: rating, interval: constrain(raw, minimum: minimum), factor: factor,
                                  lapses: card.lapses, relearning: relearning, leech: false)
            }
            let interval: Int
            if relearning {
                interval = min(rating == .easy ? max(card.ivl, 1) + 1 : max(card.ivl, 1), maxInterval)
            } else {
                interval = constrain(Double(rating == .easy ? config.graduatingIntervalEasy : config.graduatingIntervalGood), minimum: 1)
            }
            return makeReview(rating: rating, interval: interval, factor: factor, lapses: card.lapses,
                              relearning: relearning, leech: false)
        }

        // MARK: Revisão

        func isLeech(lapses: Int) -> Bool {
            let threshold = config.leechThreshold
            guard threshold > 0, lapses >= threshold else { return false }
            return (lapses - threshold) % max(threshold / 2, 1) == 0
        }

        func answerReview(_ rating: Rating) -> AnswerOutcome {
            let ease = card.factor > 0 ? card.factor : initialFactor
            switch rating {
            case .again:
                let lapses = card.lapses + 1
                let factor = max(1300, ease - 200)
                let leech = isLeech(lapses: lapses)
                let failInterval: Int
                if ctx.fsrsEnabled {
                    failInterval = constrain(fsrsInterval(after: .again), minimum: config.minimumLapseInterval)
                } else {
                    failInterval = constrain(Double(card.ivl) * config.lapseMultiplier,
                                             minimum: config.minimumLapseInterval, fuzz: false)
                }
                let relearn = steps(relearning: true)
                if relearn.isEmpty {
                    return makeReview(rating: rating, interval: failInterval, factor: factor, lapses: lapses,
                                      relearning: false, leech: leech)
                }
                return makeLearning(rating: rating, remaining: relearn.count, delay: relearn[0], relearning: true,
                                    reviewInterval: failInterval, lapses: lapses, factor: factor, leech: leech)
            case .hard, .good, .easy:
                let intervals = ctx.fsrsEnabled ? fsrsPassingIntervals() : sm2PassingIntervals(ease: ease)
                let interval: Int
                let factor: Int
                switch rating {
                case .hard:
                    interval = intervals.hard
                    factor = max(1300, ease - 150)
                case .good:
                    interval = intervals.good
                    factor = ease
                default:
                    interval = intervals.easy
                    factor = ease + 150
                }
                return makeReview(rating: rating, interval: interval, factor: factor, lapses: card.lapses,
                                  relearning: false, leech: false)
            }
        }

        func fsrsPassingIntervals() -> (hard: Int, good: Int, easy: Int) {
            let hard = constrain(fsrsInterval(after: .hard), minimum: 1)
            let good = constrain(fsrsInterval(after: .good), minimum: min(hard + 1, maxInterval))
            let easy = constrain(fsrsInterval(after: .easy), minimum: min(good + 1, maxInterval))
            return (hard, good, easy)
        }

        func sm2PassingIntervals(ease: Int) -> (hard: Int, good: Int, easy: Int) {
            let current = Double(max(card.ivl, 1))
            let easeFactor = Double(ease) / 1000.0
            let multiplier = config.intervalMultiplier
            let dueDay = Int(card.due)

            if dueDay > today {
                // Revisão antecipada (baralho filtrado): considera só o tempo realmente decorrido.
                let elapsed = max(0.0, current - Double(dueDay - today))
                let hardRaw = max(elapsed * config.hardMultiplier, current * config.hardMultiplier / 2.0)
                let goodRaw = max(elapsed * easeFactor, current)
                let reducedBonus = config.easyMultiplier - (config.easyMultiplier - 1.0) / 2.0
                let easyRaw = max(elapsed * easeFactor, current) * reducedBonus
                let hard = constrain(hardRaw * multiplier, minimum: 1)
                let good = constrain(goodRaw * multiplier, minimum: 1)
                let easy = constrain(easyRaw * multiplier, minimum: 1)
                return (hard, good, easy)
            }

            let daysLate = Double(max(0, today - dueDay))
            let hardFactor = config.hardMultiplier
            let hardMinimum = hardFactor <= 1.0 ? 1 : Int(current) + 1
            let hard = constrain(current * hardFactor * multiplier, minimum: hardMinimum)
            let goodMinimum = hardFactor <= 1.0 ? Int(current) + 1 : hard + 1
            let good = constrain((current + daysLate / 2.0) * easeFactor * multiplier, minimum: goodMinimum)
            let easy = constrain((current + daysLate) * easeFactor * config.easyMultiplier * multiplier, minimum: good + 1)
            return (hard, good, easy)
        }
    }
}
