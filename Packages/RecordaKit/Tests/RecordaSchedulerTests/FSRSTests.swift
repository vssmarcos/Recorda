import XCTest
@testable import RecordaScheduler

/// Vetores de referência do FSRS-6 com os parâmetros padrão.
///
/// Os valores foram gerados por um porte independente das fórmulas (em Python) que reproduz
/// a sequência de intervalos do teste de referência público do algoritmo:
/// [0, 2, 11, 46, 163, 498, 0, 0, 2, 4, 7, 12, 21].
final class FSRSTests: XCTestCase {
    let fsrs = FSRS()
    let accuracy = 1e-9

    func testDefaultParameterCount() {
        XCTAssertEqual(FSRS.defaultParameters.count, 21)
        XCTAssertEqual(fsrs.w, FSRS.defaultParameters)
    }

    func testInitialStates() {
        let expected: [(Double, Double)] = [
            (0.212, 6.4133),
            (1.2931, 5.112170705601055),
            (2.3065, 2.118103970459015),
            (8.2956, 1.0),
        ]
        for (index, value) in expected.enumerated() {
            let state = fsrs.initialState(rating: index + 1)
            XCTAssertEqual(state.stability, value.0, accuracy: accuracy)
            XCTAssertEqual(state.difficulty, value.1, accuracy: accuracy)
        }
    }

    func testRetrievability() {
        let cases: [(Double, Double, Double)] = [
            (0, 1, 1.0),
            (1, 1, 0.9),
            (5, 10, 0.9403442888929227),
            (30, 10, 0.8093881035731708),
            (100, 250.5, 0.9503461616734762),
            (3.5, 0.5, 0.7276209271652226),
        ]
        for (elapsed, stability, expected) in cases {
            XCTAssertEqual(fsrs.retrievability(elapsedDays: elapsed, stability: stability), expected, accuracy: accuracy)
        }
    }

    func testIntervalForDesiredRetention() {
        let cases: [(Double, Double, Double)] = [
            (1, 0.9, 1.0),
            (10, 0.9, 10.0),
            (10, 0.8, 33.159597862309816),
            (100, 0.95, 40.2558691989992),
            (2.3065, 0.9, 2.3065),
            (0.212, 0.7, 1.9690371706724088),
        ]
        for (stability, retention, expected) in cases {
            XCTAssertEqual(fsrs.interval(stability: stability, desiredRetention: retention), expected, accuracy: 1e-8)
        }
    }

    /// Com retenção de 90 %, o intervalo é a própria estabilidade.
    func testIntervalAtNinetyPercentEqualsStability() {
        for stability in [0.5, 3.0, 42.0, 900.0] {
            XCTAssertEqual(fsrs.interval(stability: stability, desiredRetention: 0.9), stability, accuracy: 1e-9 * stability + 1e-12)
        }
    }

    func testReviewChain() {
        // (nota, dias decorridos, estabilidade esperada, dificuldade esperada)
        let chain: [(Int, Double, Double, Double)] = [
            (3, 0, 2.3065, 2.118103970459015),
            (3, 2, 10.964332335820703, 2.1112142357853942),
            (4, 11, 77.10745326192736, 1.0),
            (2, 30, 134.778905623465, 4.010608969296839),
            (1, 60, 3.9283586915304154, 8.016556265363716),
            (3, 0, 3.9283586915304154, 8.00376807839519),
            (3, 1, 5.588630120600774, 7.990992679613633),
            (2, 3, 8.132537559616914, 8.651555690283237),
            (4, 10, 23.832024953251672, 8.186196808777565),
            (1, 0, 6.867859400797992, 9.389043594203724),
            (3, 25, 16.306586187824156, 9.374882919906357),
        ]
        var state: FSRSMemoryState?
        for (rating, elapsed, stability, difficulty) in chain {
            let next = fsrs.next(state: state, rating: rating, elapsedDays: elapsed)
            XCTAssertEqual(next.stability, stability, accuracy: 1e-8, "estabilidade após nota \(rating)")
            XCTAssertEqual(next.difficulty, difficulty, accuracy: 1e-8, "dificuldade após nota \(rating)")
            state = next
        }
    }

    func testNextStatesFromKnownState() {
        let start = FSRSMemoryState(stability: 5, difficulty: 5)
        let expected: [Double: [(Double, Double)]] = [
            0: [(1.5968179979869213, 8.341762369296838), (2.7470095889223867, 6.665995369296838),
                (5.0, 4.9902283692968386), (8.129609559916114, 3.3144613692968385)],
            1: [(0.8457261813415671, 8.341762369296838), (6.966099086391093, 6.665995369296838),
                (8.269203668758054, 4.9902283692968386), (11.12289155121696, 3.3144613692968385)],
            5: [(0.953502178130594, 8.341762369296838), (12.43421374353935, 6.665995369296838),
                (17.36151270957657, 4.9902283692968386), (28.151877153765955, 3.3144613692968385)],
            21: [(1.166970390794006, 8.341762369296838), (22.391265452357718, 6.665995369296838),
                 (33.917967163880476, 4.9902283692968386), (59.16046070123174, 3.3144613692968385)],
        ]
        for (elapsed, values) in expected {
            let states = fsrs.nextStates(state: start, elapsedDays: elapsed)
            XCTAssertEqual(states.count, 4)
            for (index, value) in values.enumerated() {
                XCTAssertEqual(states[index].stability, value.0, accuracy: 1e-8, "S, \(elapsed) dias, nota \(index + 1)")
                XCTAssertEqual(states[index].difficulty, value.1, accuracy: 1e-8, "D, \(elapsed) dias, nota \(index + 1)")
            }
        }
    }

    func testMemoryStateFromHistoryMatchesStepByStep() {
        let history = [
            FSRS.Review(rating: 3, elapsedDays: 0), FSRS.Review(rating: 3, elapsedDays: 2),
            FSRS.Review(rating: 4, elapsedDays: 11), FSRS.Review(rating: 2, elapsedDays: 30),
        ]
        let state = fsrs.memoryState(history: history)
        XCTAssertEqual(state?.stability ?? 0, 134.778905623465, accuracy: 1e-8)
        XCTAssertEqual(state?.difficulty ?? 0, 4.010608969296839, accuracy: 1e-8)
        XCTAssertNil(fsrs.memoryState(history: []))
    }

    func testStabilityAndDifficultyStayInRange() {
        var state: FSRSMemoryState?
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<2000 {
            let rating = Int(generator.next() % 4) + 1
            let elapsed = Double(generator.next() % 400)
            let next = fsrs.next(state: state, rating: rating, elapsedDays: elapsed)
            XCTAssertGreaterThanOrEqual(next.stability, FSRS.minStability)
            XCTAssertLessThanOrEqual(next.stability, FSRS.maxStability)
            XCTAssertGreaterThanOrEqual(next.difficulty, 1)
            XCTAssertLessThanOrEqual(next.difficulty, 10)
            state = next
        }
    }

    func testHigherRatingNeverGivesLowerStability() {
        let start = FSRSMemoryState(stability: 12, difficulty: 6)
        for elapsed in [0.0, 1, 7, 30, 200] {
            let states = fsrs.nextStates(state: start, elapsedDays: elapsed)
            XCTAssertLessThan(states[0].stability, states[2].stability)
            XCTAssertLessThanOrEqual(states[1].stability, states[2].stability)
            XCTAssertLessThanOrEqual(states[2].stability, states[3].stability)
            // Dificuldade cai com notas melhores.
            XCTAssertGreaterThan(states[0].difficulty, states[3].difficulty)
        }
    }

    func testParameterMigration() {
        // FSRS-5 (19 parâmetros): ganha expoente de curto prazo 0 e decaimento 0,5.
        let fsrs5 = Array(FSRS.defaultParameters.prefix(19))
        let migrated = FSRS.normalized(fsrs5)
        XCTAssertEqual(migrated.count, 21)
        XCTAssertEqual(migrated[19], 0)
        XCTAssertEqual(migrated[20], 0.5)
        // Com decaimento 0,5 a curva é a do FSRS-4.5/5: R(S, S) = 0,9 e fator 19/81.
        let old = FSRS(parameters: fsrs5)
        XCTAssertEqual(old.retrievability(elapsedDays: 10, stability: 10), 0.9, accuracy: 1e-12)
        XCTAssertEqual(old.factor, 19.0 / 81.0, accuracy: 1e-12)

        // FSRS-4.5 (17 parâmetros).
        let fsrs45 = Array(FSRS.defaultParameters.prefix(17))
        XCTAssertEqual(FSRS.normalized(fsrs45).count, 21)

        // Tamanhos inválidos ou valores não finitos caem nos padrões.
        XCTAssertEqual(FSRS.normalized([1, 2, 3]), FSRS.defaultParameters)
        XCTAssertEqual(FSRS.normalized([Double](repeating: .nan, count: 21)), FSRS.defaultParameters)
        XCTAssertEqual(FSRS.normalized([]), FSRS.defaultParameters)
    }

    func testSM2ConversionGivesConsistentInterval() {
        let state = fsrs.memoryState(fromSM2Ease: 2.5, interval: 30, historicalRetention: 0.9)
        // Com retenção histórica de 90 %, a estabilidade é o próprio intervalo.
        XCTAssertEqual(state.stability, 30, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(state.difficulty, 1)
        XCTAssertLessThanOrEqual(state.difficulty, 10)
    }

    // MARK: Otimizador e simulador

    func testOptimizerRejectsTinyHistory() {
        let histories = [[FSRS.Review(rating: 3, elapsedDays: 0), FSRS.Review(rating: 3, elapsedDays: 2)]]
        XCTAssertThrowsError(try FSRSOptimizer.optimize(histories: histories)) { error in
            guard case FSRSOptimizerError.notEnoughReviews = error else { return XCTFail("erro inesperado: \(error)") }
        }
    }

    /// Gera um histórico sintético a partir de parâmetros conhecidos e verifica que a otimização
    /// não piora a perda em relação aos parâmetros padrão.
    func testOptimizerNeverReturnsWorseParameters() throws {
        var truth = FSRS.defaultParameters
        truth[0] = 0.6; truth[1] = 2.0; truth[2] = 5.0; truth[3] = 15.0
        let model = FSRS(parameters: truth)
        var generator = SeededGenerator(seed: 99)
        var histories: [[FSRS.Review]] = []
        for _ in 0..<300 {
            var history: [FSRS.Review] = []
            var state: FSRSMemoryState?
            var elapsed = 0
            for step in 0..<6 {
                let rating: Int
                if let state, elapsed > 0 {
                    let r = model.retrievability(elapsedDays: Double(elapsed), stability: state.stability)
                    rating = generator.unit() < r ? 3 : 1
                } else {
                    rating = step == 0 ? Int(generator.next() % 4) + 1 : 3
                }
                history.append(FSRS.Review(rating: rating, elapsedDays: elapsed))
                state = model.next(state: state, rating: rating, elapsedDays: Double(elapsed))
                elapsed = max(1, Int(model.interval(stability: state!.stability, desiredRetention: 0.85).rounded()))
            }
            histories.append(history)
        }
        let result = try FSRSOptimizer.optimize(histories: histories, epochs: 2, batchSize: 128)
        XCTAssertEqual(result.parameters.count, 21)
        XCTAssertLessThanOrEqual(result.after.logLoss, result.before.logLoss + 1e-12)
        XCTAssertGreaterThan(result.before.reviewCount, FSRSOptimizer.minimumReviews)
        for (index, value) in result.parameters.enumerated() {
            XCTAssertGreaterThanOrEqual(value, FSRSOptimizer.lowerBounds[index])
            XCTAssertLessThanOrEqual(value, FSRSOptimizer.upperBounds[index])
        }
    }

    func testSimulatorIsDeterministicAndRespectsLimits() {
        var config = SimulatorConfig()
        config.days = 60
        config.newCardsAvailable = 200
        config.newPerDay = 10
        config.reviewsPerDay = 50
        let first = FSRSSimulator.simulate(config: config)
        let second = FSRSSimulator.simulate(config: config)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.days.count, 60)
        XCTAssertEqual(first.days.reduce(0) { $0 + $1.newCards }, 200)
        for day in first.days {
            XCTAssertLessThanOrEqual(day.newCards, 10)
            XCTAssertLessThanOrEqual(day.reviews, 50)
        }
        XCTAssertGreaterThan(first.finalMemorized, 0)
        XCTAssertLessThanOrEqual(first.finalMemorized, 200)
    }

    func testSimulatorHigherRetentionMeansMoreReviews() {
        var low = SimulatorConfig()
        low.days = 180
        low.newCardsAvailable = 300
        low.reviewsPerDay = 9999
        low.desiredRetention = 0.8
        var high = low
        high.desiredRetention = 0.95
        XCTAssertLessThan(FSRSSimulator.simulate(config: low).totalReviews, FSRSSimulator.simulate(config: high).totalReviews)
    }
}
