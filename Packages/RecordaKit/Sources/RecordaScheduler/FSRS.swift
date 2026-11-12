import Foundation

/// Estado de memória de um card no modelo FSRS.
public struct FSRSMemoryState: Sendable, Equatable {
    /// Estabilidade: dias até a recuperabilidade cair para 90 %.
    public var stability: Double
    /// Dificuldade, de 1 (fácil) a 10 (difícil).
    public var difficulty: Double

    public init(stability: Double, difficulty: Double) {
        self.stability = stability
        self.difficulty = difficulty
    }
}

/// Implementação do FSRS-6 (21 parâmetros), escrita a partir das fórmulas públicas do algoritmo.
///
/// Notas (G): 1 Errei, 2 Difícil, 3 Bom, 4 Fácil.
public struct FSRS: Sendable, Equatable {
    public static let defaultParameters: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722, 0.1666,
        0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]

    public static let minStability = 0.001
    public static let maxStability = 36_500.0
    public static let minDifficulty = 1.0
    public static let maxDifficulty = 10.0

    public let w: [Double]

    /// Aceita 21 parâmetros (FSRS-6), 19 (FSRS-5) ou 17 (FSRS-4.5). Qualquer outro tamanho usa os padrões.
    public init(parameters: [Double] = []) {
        self.w = FSRS.normalized(parameters)
    }

    /// Converte parâmetros de versões anteriores para o formato de 21 valores.
    public static func normalized(_ parameters: [Double]) -> [Double] {
        guard parameters.allSatisfy({ $0.isFinite }) else { return defaultParameters }
        switch parameters.count {
        case 21:
            return parameters
        case 19:
            // FSRS-5: sem o expoente de curto prazo e com decaimento fixo de 0,5.
            return parameters + [0.0, 0.5]
        case 17:
            // FSRS-4.5: outra forma para a dificuldade inicial e para a queda de dificuldade.
            var p = parameters
            p[4] = max(0.0, p[5] * 2.0 + p[4])
            p[5] = log(p[5] * 3.0 + 1.0) / 3.0
            p[6] = p[6] + 0.5
            return p + [0.0, 0.0, 0.0, 0.5]
        default:
            return defaultParameters
        }
    }

    // MARK: Curva de esquecimento

    /// Expoente de decaimento (positivo).
    public var decay: Double { w[20] }

    var factor: Double { pow(0.9, -1.0 / w[20]) - 1.0 }

    /// Probabilidade de lembrar após `elapsedDays` dias.
    public func retrievability(elapsedDays: Double, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1.0 + factor * max(0, elapsedDays) / stability, -w[20])
    }

    /// Intervalo (dias, não arredondado) em que a recuperabilidade atinge `desiredRetention`.
    public func interval(stability: Double, desiredRetention: Double) -> Double {
        let r = min(max(desiredRetention, 0.01), 0.9999)
        return stability / factor * (pow(r, -1.0 / w[20]) - 1.0)
    }

    // MARK: Estado inicial

    func initialDifficultyRaw(_ rating: Int) -> Double {
        w[4] - exp(w[5] * Double(rating - 1)) + 1.0
    }

    public func initialState(rating: Int) -> FSRSMemoryState {
        let g = min(max(rating, 1), 4)
        return FSRSMemoryState(
            stability: FSRS.clampStability(w[g - 1]),
            difficulty: FSRS.clampDifficulty(initialDifficultyRaw(g)))
    }

    static func clampStability(_ s: Double) -> Double { min(max(s, minStability), maxStability) }
    static func clampDifficulty(_ d: Double) -> Double { min(max(d, minDifficulty), maxDifficulty) }

    // MARK: Atualizações

    func nextDifficulty(_ d: Double, rating: Int) -> Double {
        let delta = -w[6] * Double(rating - 3)
        let damped = d + delta * (10.0 - d) / 9.0
        let reverted = w[7] * initialDifficultyRaw(4) + (1.0 - w[7]) * damped
        return FSRS.clampDifficulty(reverted)
    }

    func stabilityAfterRecall(d: Double, s: Double, r: Double, rating: Int) -> Double {
        let hardPenalty = rating == 2 ? w[15] : 1.0
        let easyBonus = rating == 4 ? w[16] : 1.0
        return s * (1.0 + exp(w[8]) * (11.0 - d) * pow(s, -w[9]) * (exp(w[10] * (1.0 - r)) - 1.0) * hardPenalty * easyBonus)
    }

    func stabilityAfterForgetting(d: Double, s: Double, r: Double) -> Double {
        let candidate = w[11] * pow(d, -w[12]) * (pow(s + 1.0, w[13]) - 1.0) * exp(w[14] * (1.0 - r))
        return min(candidate, s / exp(w[17] * w[18]))
    }

    func stabilityShortTerm(s: Double, rating: Int) -> Double {
        var increase = exp(w[17] * (Double(rating) - 3.0 + w[18])) * pow(s, -w[19])
        if rating >= 3 { increase = max(increase, 1.0) }
        return s * increase
    }

    /// Avança o estado de memória com uma resposta.
    ///
    /// - Parameters:
    ///   - state: estado atual, ou `nil` para a primeira resposta do card.
    ///   - elapsedDays: dias inteiros desde a revisão anterior (0 = mesmo dia).
    public func next(state: FSRSMemoryState?, rating: Int, elapsedDays: Double) -> FSRSMemoryState {
        let g = min(max(rating, 1), 4)
        guard let state, state.stability > 0 else { return initialState(rating: g) }
        let s = state.stability
        let d = state.difficulty
        let newStability: Double
        if elapsedDays <= 0 {
            newStability = stabilityShortTerm(s: s, rating: g)
        } else if g == 1 {
            newStability = stabilityAfterForgetting(d: d, s: s, r: retrievability(elapsedDays: elapsedDays, stability: s))
        } else {
            newStability = stabilityAfterRecall(d: d, s: s, r: retrievability(elapsedDays: elapsedDays, stability: s), rating: g)
        }
        return FSRSMemoryState(stability: FSRS.clampStability(newStability), difficulty: nextDifficulty(d, rating: g))
    }

    /// Os quatro estados possíveis (Errei, Difícil, Bom, Fácil).
    public func nextStates(state: FSRSMemoryState?, elapsedDays: Double) -> [FSRSMemoryState] {
        (1...4).map { next(state: state, rating: $0, elapsedDays: elapsedDays) }
    }

    // MARK: Histórico

    /// Uma revisão do histórico: nota e dias desde a revisão anterior.
    public struct Review: Sendable, Equatable {
        public var rating: Int
        public var elapsedDays: Int
        public init(rating: Int, elapsedDays: Int) {
            self.rating = rating
            self.elapsedDays = elapsedDays
        }
    }

    /// Reconstrói o estado de memória a partir do histórico completo de um card.
    public func memoryState(history: [Review]) -> FSRSMemoryState? {
        var state: FSRSMemoryState?
        for review in history {
            state = next(state: state, rating: review.rating, elapsedDays: Double(review.elapsedDays))
        }
        return state
    }

    /// Estima um estado de memória para cards sem histórico utilizável (ex.: importados do SM-2),
    /// a partir do intervalo e da facilidade atuais.
    public func memoryState(fromSM2Ease ease: Double, interval: Double, historicalRetention: Double = 0.9) -> FSRSMemoryState {
        let r = min(max(historicalRetention, 0.7), 0.97)
        // Estabilidade tal que o intervalo atual corresponde à retenção histórica.
        let stability = FSRS.clampStability(max(interval, FSRS.minStability) * factor / (pow(r, -1.0 / w[20]) - 1.0))
        // Inverte a fórmula de crescimento em um acerto "Bom" para achar a dificuldade compatível com a facilidade.
        let growth = max(ease, 1.3) - 1.0
        let denominator = exp(w[8]) * pow(stability, -w[9]) * (exp(w[10] * (1.0 - r)) - 1.0)
        let difficulty = denominator > 0 ? 11.0 - growth / denominator : 5.0
        return FSRSMemoryState(stability: stability, difficulty: FSRS.clampDifficulty(difficulty))
    }
}
