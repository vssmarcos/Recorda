import XCTest
import RecordaCore
@testable import RecordaScheduler

final class StateMachineTests: XCTestCase {

    let timing = SchedTiming(now: 1_700_000_000, today: 100, nextDayAt: 1_700_020_000)

    func context(fsrs: Bool, config: DeckConfigData = DeckConfigData(), filtered: FilteredDeck? = nil) -> AnswerContext {
        AnswerContext(config: config, timing: timing, fsrsEnabled: fsrs, fuzzFactor: nil, filtered: filtered)
    }

    func newCard() -> Card {
        Card(id: 1, nid: 1, did: 1, ord: 0, type: .new, queue: .new, due: 7)
    }

    func reviewCard(interval: Int = 10, factor: Int = 2500, dueOffset: Int = 0) -> Card {
        Card(id: 2, nid: 2, did: 1, ord: 0, type: .review, queue: .review, due: Int64(100 + dueOffset),
             ivl: interval, factor: factor, reps: 5)
    }

    // MARK: SM-2

    func testSM2NewCardButtons() {
        let outcomes = StateMachine.outcomes(for: newCard(), context: context(fsrs: false))
        XCTAssertEqual(outcomes.map(\.delaySecs), [60, 330, 600, 4 * 86_400])

        let again = outcomes[0].card
        XCTAssertEqual(again.type, .learning)
        XCTAssertEqual(again.queue, .learning)
        XCTAssertEqual(again.left, 2)
        XCTAssertEqual(again.due, timing.now + 60)
        XCTAssertEqual(again.reps, 1)

        let good = outcomes[2].card
        XCTAssertEqual(good.left, 1)
        XCTAssertEqual(good.due, timing.now + 600)

        let easy = outcomes[3].card
        XCTAssertEqual(easy.type, .review)
        XCTAssertEqual(easy.queue, .review)
        XCTAssertEqual(easy.ivl, 4)
        XCTAssertEqual(easy.due, 104)
        XCTAssertEqual(easy.factor, 2500)

        XCTAssertEqual(outcomes[0].revlogKind, .learning)
        XCTAssertEqual(outcomes[0].revlogInterval, -60)
        XCTAssertEqual(outcomes[3].revlogInterval, 4)
        // O SM-2 não guarda estado de memória; a posição original fica registrada.
        XCTAssertNil(good.cardData.s)
        XCTAssertEqual(good.cardData.pos, 7)
        XCTAssertEqual(good.cardData.lrt, timing.now)
    }

    func testSM2LearningGraduation() {
        var card = newCard()
        card.type = .learning
        card.queue = .learning
        card.left = 1
        card.factor = 2500
        let outcomes = StateMachine.outcomes(for: card, context: context(fsrs: false))
        // Último passo: Errei volta ao início, Difícil repete o passo, Bom gradua, Fácil gradua com intervalo maior.
        XCTAssertEqual(outcomes[0].card.left, 2)
        XCTAssertEqual(outcomes[0].delaySecs, 60)
        XCTAssertEqual(outcomes[1].card.left, 1)
        XCTAssertEqual(outcomes[1].delaySecs, 600)
        XCTAssertEqual(outcomes[2].card.type, .review)
        XCTAssertEqual(outcomes[2].card.ivl, 1)
        XCTAssertEqual(outcomes[2].card.due, 101)
        XCTAssertEqual(outcomes[3].card.ivl, 4)
        XCTAssertEqual(outcomes[2].revlogLastInterval, -600)
    }

    func testSM2ReviewIntervals() {
        let outcomes = StateMachine.outcomes(for: reviewCard(), context: context(fsrs: false))
        // 10 d × 1,2 = 12; 10 d × 2,5 = 25; 10 d × 2,5 × 1,3 = 32,5 → 33.
        XCTAssertEqual(outcomes[1].card.ivl, 12)
        XCTAssertEqual(outcomes[2].card.ivl, 25)
        XCTAssertEqual(outcomes[3].card.ivl, 33)
        XCTAssertEqual(outcomes[1].card.factor, 2350)
        XCTAssertEqual(outcomes[2].card.factor, 2500)
        XCTAssertEqual(outcomes[3].card.factor, 2650)
        XCTAssertEqual(outcomes[2].card.due, 125)
        XCTAssertEqual(outcomes[2].revlogKind, .review)
        XCTAssertEqual(outcomes[2].revlogLastInterval, 10)

        // Lapso: reaprendizado com passo de 10 min, facilidade −20 pp, intervalo mínimo de 1 dia.
        let again = outcomes[0]
        XCTAssertEqual(again.card.type, .relearning)
        XCTAssertEqual(again.card.queue, .learning)
        XCTAssertEqual(again.card.lapses, 1)
        XCTAssertEqual(again.card.factor, 2300)
        XCTAssertEqual(again.card.ivl, 1)
        XCTAssertEqual(again.delaySecs, 600)
        XCTAssertFalse(again.isLeech)
    }

    func testSM2LateReviewGetsBonus() {
        let outcomes = StateMachine.outcomes(for: reviewCard(dueOffset: -4), context: context(fsrs: false))
        // Bom: (10 + 4/2) × 2,5 = 30; Fácil: (10 + 4) × 2,5 × 1,3 = 45,5 → 46.
        XCTAssertEqual(outcomes[1].card.ivl, 12)
        XCTAssertEqual(outcomes[2].card.ivl, 30)
        XCTAssertEqual(outcomes[3].card.ivl, 46)
    }

    func testSM2IntervalsAreStrictlyIncreasingAcrossButtons() {
        // Com intervalo curto, os mínimos garantem Difícil < Bom < Fácil.
        let outcomes = StateMachine.outcomes(for: reviewCard(interval: 1, factor: 1300), context: context(fsrs: false))
        XCTAssertEqual(outcomes[1].card.ivl, 2)
        XCTAssertEqual(outcomes[2].card.ivl, 3)
        XCTAssertEqual(outcomes[3].card.ivl, 4)
    }

    func testSM2RelearningReturnsToReview() {
        var card = reviewCard()
        card.type = .relearning
        card.queue = .learning
        card.left = 1
        card.ivl = 3
        card.lapses = 1
        let outcomes = StateMachine.outcomes(for: card, context: context(fsrs: false))
        XCTAssertEqual(outcomes[2].card.type, .review)
        XCTAssertEqual(outcomes[2].card.ivl, 3)
        XCTAssertEqual(outcomes[3].card.ivl, 4)
        XCTAssertEqual(outcomes[0].card.type, .relearning)
        XCTAssertEqual(outcomes[2].revlogKind, .relearning)
    }

    func testMaximumIntervalIsRespected() {
        var config = DeckConfigData()
        config.maximumReviewInterval = 20
        let outcomes = StateMachine.outcomes(for: reviewCard(), context: context(fsrs: false, config: config))
        XCTAssertEqual(outcomes[2].card.ivl, 20)
        XCTAssertEqual(outcomes[3].card.ivl, 20)
    }

    func testLeechDetection() {
        var card = reviewCard()
        card.lapses = 7
        let outcome = StateMachine.outcome(for: card, rating: .again, context: context(fsrs: false))
        XCTAssertTrue(outcome.isLeech)
        XCTAssertEqual(outcome.card.lapses, 8)

        card.lapses = 8
        XCTAssertFalse(StateMachine.outcome(for: card, rating: .again, context: context(fsrs: false)).isLeech)
        // Depois do limite, avisa de novo a cada metade do limite.
        card.lapses = 11
        XCTAssertTrue(StateMachine.outcome(for: card, rating: .again, context: context(fsrs: false)).isLeech)
    }

    func testInterdayLearningStepUsesDayQueue() {
        var config = DeckConfigData()
        config.learnSteps = [1, 1440 * 2]
        let outcome = StateMachine.outcome(for: newCard(), rating: .good, context: context(fsrs: false, config: config))
        XCTAssertEqual(outcome.card.queue, .dayLearning)
        XCTAssertEqual(outcome.card.due, 102)
        XCTAssertEqual(outcome.delaySecs, 2 * 86_400)
    }

    func testNoLearningStepsGraduatesImmediatelyInSM2() {
        var config = DeckConfigData()
        config.learnSteps = []
        let outcomes = StateMachine.outcomes(for: newCard(), context: context(fsrs: false, config: config))
        XCTAssertEqual(outcomes[2].card.type, .review)
        XCTAssertEqual(outcomes[2].card.ivl, 1)
        XCTAssertEqual(outcomes[3].card.ivl, 4)
    }

    // MARK: FSRS

    func testFSRSNewCardStoresMemoryState() {
        let outcomes = StateMachine.outcomes(for: newCard(), context: context(fsrs: true))
        // Os passos de aprendizado continuam valendo.
        XCTAssertEqual(outcomes.map(\.delaySecs).prefix(3), [60, 330, 600])
        let good = outcomes[2].card.cardData
        XCTAssertEqual(good.s ?? 0, 2.3065, accuracy: 1e-9)
        XCTAssertEqual(good.d ?? 0, 2.118103970459015, accuracy: 1e-9)
        XCTAssertEqual(good.dr, 0.9)
        // Fácil gradua direto com o intervalo do FSRS: S = 8,2956 → 8 dias.
        XCTAssertEqual(outcomes[3].card.type, .review)
        XCTAssertEqual(outcomes[3].card.ivl, 8)
        // Dificuldade no revlog: (D − 1) / 9 × 1000 + 100.
        XCTAssertEqual(outcomes[2].revlogFactor, Int((((2.118103970459015 - 1) / 9) * 1000).rounded()) + 100)
    }

    func testFSRSReviewIntervals() {
        var card = reviewCard()
        var data = CardData(s: 10, d: 5)
        // Última revisão há exatamente 10 dias.
        data.lrt = timing.now - 10 * 86_400
        card.cardData = data
        let outcomes = StateMachine.outcomes(for: card, context: context(fsrs: true))
        // Estabilidades esperadas: 1,392 / 23,247 / 32,027 / 51,254 → intervalos 1, 23, 32, 51.
        XCTAssertEqual(outcomes[0].card.ivl, 1)
        XCTAssertEqual(outcomes[1].card.ivl, 23)
        XCTAssertEqual(outcomes[2].card.ivl, 32)
        XCTAssertEqual(outcomes[3].card.ivl, 51)
        XCTAssertEqual(outcomes[2].card.cardData.s ?? 0, 32.02672948198673, accuracy: 1e-8)
        XCTAssertEqual(outcomes[2].card.cardData.d ?? 0, 4.9902283692968386, accuracy: 1e-8)
        XCTAssertEqual(outcomes[0].card.type, .relearning)
        XCTAssertEqual(outcomes[0].card.cardData.s ?? 0, 1.3919869729546932, accuracy: 1e-8)
    }

    func testFSRSHigherRetentionShortensIntervals() {
        var card = reviewCard()
        card.cardData = CardData(s: 50, d: 5, lrt: timing.now - 10 * 86_400)
        var strict = DeckConfigData()
        strict.desiredRetention = 0.95
        var relaxed = DeckConfigData()
        relaxed.desiredRetention = 0.8
        let short = StateMachine.outcome(for: card, rating: .good, context: context(fsrs: true, config: strict)).card.ivl
        let long = StateMachine.outcome(for: card, rating: .good, context: context(fsrs: true, config: relaxed)).card.ivl
        XCTAssertLessThan(short, long)
    }

    func testFSRSWithoutStepsUsesShortIntervalsFromTheModel() {
        var config = DeckConfigData()
        config.learnSteps = []
        let outcomes = StateMachine.outcomes(for: newCard(), context: context(fsrs: true, config: config))
        // Errei: S = 0,212 dia → menos de meio dia → continua em aprendizado, com atraso em segundos.
        XCTAssertEqual(outcomes[0].card.type, .learning)
        XCTAssertEqual(outcomes[0].delaySecs, Int((0.212 * 86_400).rounded()))
        // Difícil (1,29 d), Bom (2,31 d) e Fácil (8,30 d) viram revisão.
        XCTAssertEqual(outcomes[1].card.ivl, 1)
        XCTAssertEqual(outcomes[2].card.ivl, 2)
        XCTAssertEqual(outcomes[3].card.ivl, 8)
    }

    // MARK: Baralhos filtrados

    func testPreviewDoesNotChangeScheduling() {
        var card = reviewCard(dueOffset: 5)
        card.odid = 1
        card.did = 99
        card.odue = card.due
        card.due = -100_000
        var filtered = FilteredDeck()
        filtered.reschedule = false
        let ctx = context(fsrs: false, filtered: filtered)

        let again = StateMachine.outcome(for: card, rating: .again, context: ctx)
        XCTAssertTrue(again.isPreview)
        XCTAssertEqual(again.card.queue, .preview)
        XCTAssertEqual(again.card.due, timing.now + 60)
        XCTAssertEqual(again.card.ivl, 10)
        XCTAssertEqual(again.card.did, 99)

        let easy = StateMachine.outcome(for: card, rating: .easy, context: ctx)
        XCTAssertEqual(easy.card.did, 1)
        XCTAssertEqual(easy.card.odid, 0)
        XCTAssertEqual(easy.card.due, 105)
        XCTAssertEqual(easy.card.queue, .review)
        XCTAssertEqual(easy.card.ivl, 10)
        XCTAssertEqual(easy.card.reps, 5)
    }

    func testEarlyReviewInFilteredDeckReturnsHome() {
        var card = reviewCard(dueOffset: 5)
        card.odid = 1
        card.did = 99
        card.odue = card.due
        card.due = -100_000
        let outcome = StateMachine.outcome(for: card, rating: .good, context: context(fsrs: false, filtered: FilteredDeck()))
        XCTAssertFalse(outcome.isPreview)
        XCTAssertEqual(outcome.card.did, 1)
        XCTAssertEqual(outcome.card.odid, 0)
        XCTAssertEqual(outcome.card.odue, 0)
        XCTAssertEqual(outcome.revlogKind, .filtered)
        // Antecipada em 5 dias: decorreram 5 dos 10 → max(5 × 2,5; 10) = 12,5 → 13.
        XCTAssertEqual(outcome.card.ivl, 13)
        XCTAssertEqual(outcome.card.due, 113)
    }

    // MARK: Fuzz

    func testFuzzBounds() {
        XCTAssertEqual(Fuzz.delta(2), 0)
        let small = Fuzz.bounds(interval: 2, minimum: 1, maximum: 36_500)
        XCTAssertEqual(small.lower, 2)
        XCTAssertEqual(small.upper, 2)
        // 10 dias: delta = 1 + 0,15 × 4,5 + 0,1 × 3 = 1,975 → [8, 12].
        let ten = Fuzz.bounds(interval: 10, minimum: 1, maximum: 36_500)
        XCTAssertEqual(ten.lower, 8)
        XCTAssertEqual(ten.upper, 12)
        // 100 dias: delta = 1 + 0,675 + 1,3 + 4 = 6,975 → [93, 107].
        let hundred = Fuzz.bounds(interval: 100, minimum: 1, maximum: 36_500)
        XCTAssertEqual(hundred.lower, 93)
        XCTAssertEqual(hundred.upper, 107)
        // Limites externos prevalecem.
        let capped = Fuzz.bounds(interval: 100, minimum: 98, maximum: 101)
        XCTAssertEqual(capped.lower, 98)
        XCTAssertEqual(capped.upper, 101)
    }

    func testFuzzIsDeterministicAndWithinBounds() {
        for cardID in stride(from: Int64(1_600_000_000_000), to: 1_600_000_000_200, by: 7) {
            let factor = Fuzz.factor(cardID: cardID, reps: 3)
            XCTAssertEqual(factor, Fuzz.factor(cardID: cardID, reps: 3))
            XCTAssertGreaterThanOrEqual(factor, 0)
            XCTAssertLessThan(factor, 1)
            let interval = Fuzz.apply(interval: 30, factor: factor, minimum: 1, maximum: 36_500)
            let bounds = Fuzz.bounds(interval: 30, minimum: 1, maximum: 36_500)
            XCTAssertTrue((bounds.lower...bounds.upper).contains(interval))
        }
    }

    func testLoadBalancerPrefersEmptierAndNonEasyDays() {
        // Dia 105 lotado, demais vazios: o balanceador evita o 105.
        let crowded = LoadBalancer(dueCounts: { _ in [105: 500] }, weekday: { _ in 0 }, easyDays: [1, 1, 1, 1, 1, 1, 1])
        for step in 0..<20 {
            let chosen = crowded.chooseInterval(lower: 4, upper: 6, today: 100, factor: (Double(step) + 0.5) / 20.0)
            XCTAssertNotEqual(chosen, 5)
        }
        // Dia fácil "mínimo" praticamente nunca é escolhido.
        let easy = LoadBalancer(dueCounts: { _ in [:] }, weekday: { $0 % 7 }, easyDays: [1, 1, 1, 0, 1, 1, 1])
        // today + 3 = 108 → 108 % 7 = 3 (dia mínimo).
        for step in 0..<20 {
            let chosen = easy.chooseInterval(lower: 7, upper: 9, today: 100, factor: (Double(step) + 0.5) / 20.0)
            XCTAssertNotEqual(chosen, 8)
        }
    }

    func testIntervalFormatting() {
        XCTAssertEqual(IntervalFormat.short(seconds: 30), "<1 min")
        XCTAssertEqual(IntervalFormat.short(seconds: 600), "10 min")
        XCTAssertEqual(IntervalFormat.short(seconds: 2 * 3600), "2 h")
        XCTAssertEqual(IntervalFormat.short(days: 4), "4 d")
        XCTAssertEqual(IntervalFormat.short(days: 45), "1,5 mês")
        XCTAssertEqual(IntervalFormat.short(days: 730), "2 anos")
    }
}
