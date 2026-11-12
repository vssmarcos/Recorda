import Foundation

/// Gerador pseudoaleatório determinístico (SplitMix64), para otimização e simulação reprodutíveis.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Valor uniforme em [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

public struct FSRSEvaluation: Sendable, Equatable {
    /// Perda logarítmica média (quanto menor, melhor).
    public var logLoss: Double
    /// Erro quadrático médio entre retenção prevista e observada, por faixas de previsão.
    public var rmseBins: Double
    /// Número de revisões avaliadas.
    public var reviewCount: Int
}

public struct FSRSOptimizationResult: Sendable, Equatable {
    public var parameters: [Double]
    public var before: FSRSEvaluation
    public var after: FSRSEvaluation
    /// Falso se os parâmetros encontrados não superaram os atuais (que foram mantidos).
    public var improved: Bool
}

public enum FSRSOptimizerError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case notEnoughReviews(found: Int, needed: Int)
    case cancelled

    public var description: String {
        switch self {
        case .notEnoughReviews(let found, let needed):
            return "Histórico insuficiente para otimizar: \(found) revisões utilizáveis (mínimo: \(needed))."
        case .cancelled:
            return "Otimização cancelada."
        }
    }

    public var errorDescription: String? { description }
}

/// Ajuste dos parâmetros do FSRS ao histórico de revisões.
///
/// Estratégia: (1) estabilidades iniciais (w0–w3) ajustadas diretamente pela segunda revisão de cada card;
/// (2) descida de gradiente (Adam) com gradientes por diferenças finitas em minilotes de cards,
/// minimizando a perda logarítmica da previsão de acerto. O resultado só é adotado se superar os
/// parâmetros de partida no histórico completo.
public enum FSRSOptimizer {

    public static let minimumReviews = 64

    static let lowerBounds: [Double] = [
        0.001, 0.001, 0.001, 0.001, 1.0, 0.001, 0.001, 0.001, 0.0, 0.0,
        0.001, 0.001, 0.001, 0.001, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.1,
    ]
    static let upperBounds: [Double] = [
        100, 100, 100, 100, 10, 4, 4, 0.75, 4.5, 0.8,
        3.5, 5, 0.25, 0.9, 4, 1, 6, 2, 2, 0.8, 0.8,
    ]

    static func clamp(_ params: [Double]) -> [Double] {
        var out = params
        for i in out.indices { out[i] = min(max(out[i], lowerBounds[i]), upperBounds[i]) }
        // As estabilidades iniciais devem crescer com a nota.
        for i in 1..<4 where out[i] < out[i - 1] { out[i] = out[i - 1] }
        return out
    }

    // MARK: Perda

    /// Soma da perda e número de revisões-alvo para um conjunto de históricos.
    static func lossSum(_ params: [Double], histories: ArraySlice<[FSRS.Review]>) -> (sum: Double, count: Int) {
        let fsrs = FSRS(parameters: params)
        var sum = 0.0
        var count = 0
        for history in histories {
            var state: FSRSMemoryState?
            for review in history {
                if let current = state, review.elapsedDays > 0 {
                    let p = min(max(fsrs.retrievability(elapsedDays: Double(review.elapsedDays), stability: current.stability), 1e-6), 1 - 1e-6)
                    sum += review.rating > 1 ? -log(p) : -log(1 - p)
                    count += 1
                }
                state = fsrs.next(state: state, rating: review.rating, elapsedDays: Double(review.elapsedDays))
            }
        }
        return (sum, count)
    }

    public static func evaluate(parameters: [Double], histories: [[FSRS.Review]]) -> FSRSEvaluation {
        let fsrs = FSRS(parameters: parameters)
        var sum = 0.0
        var count = 0
        let binCount = 20
        var predicted = [Double](repeating: 0, count: binCount)
        var actual = [Double](repeating: 0, count: binCount)
        var sizes = [Int](repeating: 0, count: binCount)
        for history in histories {
            var state: FSRSMemoryState?
            for review in history {
                if let current = state, review.elapsedDays > 0 {
                    let p = min(max(fsrs.retrievability(elapsedDays: Double(review.elapsedDays), stability: current.stability), 1e-6), 1 - 1e-6)
                    let recalled = review.rating > 1
                    sum += recalled ? -log(p) : -log(1 - p)
                    count += 1
                    let bin = min(binCount - 1, Int(p * Double(binCount)))
                    predicted[bin] += p
                    actual[bin] += recalled ? 1 : 0
                    sizes[bin] += 1
                }
                state = fsrs.next(state: state, rating: review.rating, elapsedDays: Double(review.elapsedDays))
            }
        }
        guard count > 0 else { return FSRSEvaluation(logLoss: 0, rmseBins: 0, reviewCount: 0) }
        var squared = 0.0
        for bin in 0..<binCount where sizes[bin] > 0 {
            let n = Double(sizes[bin])
            let difference = predicted[bin] / n - actual[bin] / n
            squared += difference * difference * n
        }
        return FSRSEvaluation(logLoss: sum / Double(count), rmseBins: (squared / Double(count)).squareRoot(), reviewCount: count)
    }

    // MARK: Estabilidades iniciais

    /// Para cada primeira nota, acha a estabilidade que melhor explica o resultado da segunda revisão.
    static func pretrainInitialStability(histories: [[FSRS.Review]], start: [Double]) -> [Double] {
        var params = start
        let decay = start[20]
        let factor = pow(0.9, -1.0 / decay) - 1.0
        for rating in 1...4 {
            // (dias decorridos) → (acertos, total)
            var buckets: [Int: (recalled: Int, total: Int)] = [:]
            for history in histories where history.count >= 2 && history[0].rating == rating {
                // Primeira revisão em outro dia depois da resposta inicial.
                guard let second = history.dropFirst().first(where: { $0.elapsedDays > 0 }) else { continue }
                // Só vale se não houve nova resposta no mesmo dia que alterasse o estado de forma relevante.
                var entry = buckets[second.elapsedDays] ?? (0, 0)
                entry.total += 1
                if second.rating > 1 { entry.recalled += 1 }
                buckets[second.elapsedDays] = entry
            }
            let total = buckets.values.reduce(0) { $0 + $1.total }
            guard total >= 30 else { continue }

            func loss(_ stability: Double) -> Double {
                var sum = 0.0
                for (elapsed, entry) in buckets {
                    let p = min(max(pow(1.0 + factor * Double(elapsed) / stability, -decay), 1e-6), 1 - 1e-6)
                    sum -= Double(entry.recalled) * log(p) + Double(entry.total - entry.recalled) * log(1 - p)
                }
                // Regularização leve em direção ao valor de partida, proporcional à falta de dados.
                let prior = abs(log(stability) - log(start[rating - 1]))
                return sum / Double(total) + prior / Double(total).squareRoot() * 0.1
            }

            // Busca da seção áurea em escala logarítmica.
            var low = log(0.01)
            var high = log(100.0)
            let ratio = (5.0.squareRoot() - 1.0) / 2.0
            var c = high - ratio * (high - low)
            var d = low + ratio * (high - low)
            var lossC = loss(exp(c))
            var lossD = loss(exp(d))
            for _ in 0..<60 {
                if lossC < lossD {
                    high = d
                    d = c
                    lossD = lossC
                    c = high - ratio * (high - low)
                    lossC = loss(exp(c))
                } else {
                    low = c
                    c = d
                    lossC = lossD
                    d = low + ratio * (high - low)
                    lossD = loss(exp(d))
                }
            }
            params[rating - 1] = exp((low + high) / 2.0)
        }
        return clamp(params)
    }

    // MARK: Otimização

    /// Ajusta os parâmetros ao histórico.
    ///
    /// - Parameters:
    ///   - histories: um histórico completo por card.
    ///   - current: parâmetros de partida (vazio = padrão).
    ///   - progress: recebe um valor de 0 a 1; devolver `false` cancela.
    public static func optimize(histories allHistories: [[FSRS.Review]], current: [Double] = [],
                                epochs: Int = 5, batchSize: Int = 256, seed: UInt64 = 2024,
                                progress: (Double) -> Bool = { _ in true }) throws -> FSRSOptimizationResult {
        let histories = allHistories.filter { history in
            history.count >= 2 && history.contains(where: { $0.elapsedDays > 0 })
        }
        let start = FSRS.normalized(current)
        let before = evaluate(parameters: start, histories: histories)
        guard before.reviewCount >= minimumReviews else {
            throw FSRSOptimizerError.notEnoughReviews(found: before.reviewCount, needed: minimumReviews)
        }

        var params = pretrainInitialStability(histories: histories, start: start)
        let defaults = FSRS.defaultParameters
        var generator = SeededGenerator(seed: seed)
        var order = Array(histories.indices)
        let batches = max(1, (histories.count + batchSize - 1) / batchSize)
        // Coleções pequenas têm poucos lotes por época: garante um número mínimo de passos.
        let epochs = max(epochs, (60 + batches - 1) / batches)
        let totalSteps = max(1, epochs * batches)

        // Adam
        var m = [Double](repeating: 0, count: 21)
        var v = [Double](repeating: 0, count: 21)
        let beta1 = 0.9, beta2 = 0.999, epsilon = 1e-8
        let baseRate = 0.04
        let l2 = 0.01
        var step = 0
        var best = params
        var bestLoss = evaluate(parameters: params, histories: histories).logLoss

        for _ in 0..<epochs {
            order.shuffle(using: &generator)
            for batchIndex in 0..<batches {
                step += 1
                guard progress(Double(step) / Double(totalSteps) * 0.95) else { throw FSRSOptimizerError.cancelled }
                let lower = batchIndex * batchSize
                let upper = min(lower + batchSize, order.count)
                let batch = order[lower..<upper].map { histories[$0] }
                let slice = batch[...]

                // Gradiente por diferenças finitas centrais, em escala relativa.
                var gradient = [Double](repeating: 0, count: 21)
                for index in 0..<21 {
                    let h = max(1e-4, abs(params[index]) * 1e-3)
                    var plus = params
                    var minus = params
                    plus[index] = min(params[index] + h, upperBounds[index])
                    minus[index] = max(params[index] - h, lowerBounds[index])
                    let width = plus[index] - minus[index]
                    guard width > 0 else { continue }
                    let a = lossSum(plus, histories: slice)
                    let b = lossSum(minus, histories: slice)
                    guard a.count > 0, b.count > 0 else { continue }
                    let scale = max(defaults[index], 0.1)
                    gradient[index] = (a.sum / Double(a.count) - b.sum / Double(b.count)) / width
                        + l2 * (params[index] - defaults[index]) / (scale * scale) / Double(batches)
                }

                // Taxa de aprendizado com decaimento em cosseno.
                let rate = baseRate * 0.5 * (1.0 + cos(Double.pi * Double(step - 1) / Double(totalSteps)))
                for index in 0..<21 {
                    let g = gradient[index]
                    m[index] = beta1 * m[index] + (1 - beta1) * g
                    v[index] = beta2 * v[index] + (1 - beta2) * g * g
                    let mHat = m[index] / (1 - pow(beta1, Double(step)))
                    let vHat = v[index] / (1 - pow(beta2, Double(step)))
                    // Passo proporcional à magnitude típica do parâmetro.
                    let scale = max(abs(defaults[index]), 0.05)
                    params[index] -= rate * scale * mHat / (vHat.squareRoot() + epsilon)
                }
                params = clamp(params)
            }
            let epochLoss = evaluate(parameters: params, histories: histories).logLoss
            if epochLoss < bestLoss {
                bestLoss = epochLoss
                best = params
            }
        }

        let rounded = best.map { ($0 * 10_000).rounded() / 10_000 }
        let candidate = clamp(rounded)
        let after = evaluate(parameters: candidate, histories: histories)
        _ = progress(1.0)
        if after.logLoss < before.logLoss {
            return FSRSOptimizationResult(parameters: candidate, before: before, after: after, improved: true)
        }
        return FSRSOptimizationResult(parameters: start, before: before, after: before, improved: false)
    }
}
