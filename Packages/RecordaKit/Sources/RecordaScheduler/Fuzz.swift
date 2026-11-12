import Foundation

/// Variação ("fuzz") aplicada aos intervalos de revisão para que cards adicionados juntos não vençam sempre juntos.
public enum Fuzz {

    /// Fator determinístico em [0, 1) derivado do card e do número de respostas.
    /// Ser determinístico garante que o intervalo mostrado no botão seja o mesmo que será aplicado.
    public static func factor(cardID: Int64, reps: Int) -> Double {
        var x = UInt64(bitPattern: cardID) &+ (UInt64(truncatingIfNeeded: reps) &* 0x9E37_79B9_7F4A_7C15)
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x = x ^ (x >> 31)
        return Double(x >> 11) / Double(1 << 53)
    }

    private static let ranges: [(start: Double, end: Double, factor: Double)] = [
        (2.5, 7.0, 0.15),
        (7.0, 20.0, 0.1),
        (20.0, .infinity, 0.05),
    ]

    static func delta(_ interval: Double) -> Double {
        guard interval >= 2.5 else { return 0 }
        return ranges.reduce(1.0) { total, range in
            total + range.factor * max(min(interval, range.end) - range.start, 0)
        }
    }

    /// Menor e maior intervalo admitidos para `interval`, respeitando os limites dados.
    public static func bounds(interval: Double, minimum: Int, maximum: Int) -> (lower: Int, upper: Int) {
        let maxValue = max(maximum, 1)
        let minValue = min(max(minimum, 1), maxValue)
        let clamped = min(max(interval, Double(minValue)), Double(maxValue))
        let d = delta(clamped)
        let lower = min(max(Int((clamped - d).rounded()), minValue), maxValue)
        let upper = min(max(Int((clamped + d).rounded()), minValue), maxValue)
        return (lower, max(lower, upper))
    }

    /// Escolhe um intervalo dentro dos limites usando o fator dado.
    public static func apply(interval: Double, factor: Double, minimum: Int, maximum: Int) -> Int {
        let (lower, upper) = bounds(interval: interval, minimum: minimum, maximum: maximum)
        let span = Double(upper - lower + 1)
        return min(upper, lower + Int((factor * span).rounded(.down)))
    }
}

/// Balanceamento de carga: entre os dias permitidos pelo fuzz, prefere os menos carregados
/// e respeita os "dias fáceis".
public struct LoadBalancer {
    /// Número de revisões já agendadas por dia (índice de dia da coleção).
    public var dueCounts: (ClosedRange<Int>) -> [Int: Int]
    /// Dia da semana (0 = segunda … 6 = domingo) para um índice de dia.
    public var weekday: (Int) -> Int
    /// Segunda a domingo: 1.0 normal, 0.5 reduzido, 0.0 mínimo.
    public var easyDays: [Double]

    public init(dueCounts: @escaping (ClosedRange<Int>) -> [Int: Int], weekday: @escaping (Int) -> Int, easyDays: [Double]) {
        self.dueCounts = dueCounts
        self.weekday = weekday
        self.easyDays = easyDays
    }

    /// Escolhe o intervalo (em dias) entre `lower` e `upper`.
    public func chooseInterval(lower: Int, upper: Int, today: Int, factor: Double) -> Int {
        guard upper > lower else { return lower }
        let counts = dueCounts((today + lower)...(today + upper))
        var weights: [Double] = []
        var total = 0.0
        for interval in lower...upper {
            let day = today + interval
            let count = Double(counts[day] ?? 0)
            let dayIndex = ((weekday(day) % 7) + 7) % 7
            let percentage = dayIndex < easyDays.count ? easyDays[dayIndex] : 1.0
            // "Mínimo" não zera o dia: só o torna muito improvável.
            let easyWeight = percentage <= 0 ? 0.0001 : percentage
            let weight = easyWeight / pow(count + 1.0, 2.15) / Double(interval)
            weights.append(weight)
            total += weight
        }
        guard total > 0 else { return lower }
        var target = factor * total
        for (offset, weight) in weights.enumerated() {
            if target < weight { return lower + offset }
            target -= weight
        }
        return upper
    }
}
