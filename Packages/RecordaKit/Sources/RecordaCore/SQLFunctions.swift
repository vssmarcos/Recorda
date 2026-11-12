import Foundation
import GRDB

/// Funções SQL auxiliares usadas pela busca e pelas estatísticas.
enum SQLFunctions {

    private final class RegexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: NSRegularExpression] = [:]

        func regex(_ pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = cache[pattern] { return cached }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                return nil
            }
            if cache.count > 64 { cache.removeAll() }
            cache[pattern] = regex
            return regex
        }
    }

    private static let regexCache = RegexCache()

    static func register(in db: Database) throws {
        // regexp(padrão, texto) — habilita o operador REGEXP.
        db.add(function: DatabaseFunction("regexp", argumentCount: 2, pure: true) { values in
            guard let pattern = String.fromDatabaseValue(values[0]),
                  let text = String.fromDatabaseValue(values[1]),
                  let regex = regexCache.regex(pattern) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        })

        // field_at(flds, índice) — n-ésimo campo da nota.
        db.add(function: DatabaseFunction("field_at", argumentCount: 2, pure: true) { values in
            guard let flds = String.fromDatabaseValue(values[0]),
                  let index = Int.fromDatabaseValue(values[1]) else { return nil }
            let parts = flds.components(separatedBy: Note.fieldSeparator)
            return index >= 0 && index < parts.count ? parts[index] : ""
        })

        db.add(function: DatabaseFunction("strip_html", argumentCount: 1, pure: true) { values in
            guard let text = String.fromDatabaseValue(values[0]) else { return nil }
            return HTMLText.strip(text)
        })

        // nocomb(texto) — remove diacríticos.
        db.add(function: DatabaseFunction("nocomb", argumentCount: 1, pure: true) { values in
            guard let text = String.fromDatabaseValue(values[0]) else { return nil }
            return HTMLText.withoutCombining(text)
        })

        // fsrs_r(estabilidade, dias decorridos, decaimento) — recuperabilidade prevista.
        db.add(function: DatabaseFunction("fsrs_r", argumentCount: 3, pure: true) { values in
            guard let stability = Double.fromDatabaseValue(values[0]),
                  let elapsed = Double.fromDatabaseValue(values[1]), stability > 0 else { return nil }
            let decay = Double.fromDatabaseValue(values[2]) ?? 0.1542
            let factor = pow(0.9, -1.0 / decay) - 1.0
            return pow(1.0 + factor * max(0, elapsed) / stability, -decay)
        })
    }
}
