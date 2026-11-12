import Foundation

/// Formatação compacta de intervalos (rótulos dos botões de resposta, navegador, estatísticas).
public enum IntervalFormat {

    private static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
    }

    /// Ex.: "<1 min", "10 min", "2 h", "3 d", "1,5 mês", "2,1 anos".
    public static func short(seconds: Int) -> String {
        let secs = Double(max(0, seconds))
        if secs < 60 { return secs < 1 ? "agora" : "<1 min" }
        if secs < 3600 { return "\(Int((secs / 60).rounded())) min" }
        if secs < 86_400 { return "\(number(secs / 3600)) h" }
        let days = secs / 86_400
        if days < 30 { return "\(Int(days.rounded())) d" }
        if days < 365 {
            let months = days / 30
            return "\(number(months)) \(months >= 1.95 ? "meses" : "mês")"
        }
        let years = days / 365
        return "\(number(years)) \(years >= 1.95 ? "anos" : "ano")"
    }

    public static func short(days: Int) -> String {
        short(seconds: days * 86_400)
    }

    /// Duração de estudo, ex.: "45 s", "12 min", "1,5 h".
    public static func duration(seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3600 { return "\(number(seconds / 60)) min" }
        return "\(number(seconds / 3600)) h"
    }
}
