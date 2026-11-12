import Foundation
import GRDB
import RecordaCore

/// Dados da coleção de que a busca precisa para virar SQL.
public struct SearchContext: Sendable {
    public var decks: [Deck]
    public var notetypes: [Notetype]
    public var deckConfigs: [DeckConfig]
    public var today: Int
    public var nextDayAt: Int64
    public var now: Int64
    public var currentDeckID: DeckID
    public var fsrsDecay: Double

    public init(decks: [Deck], notetypes: [Notetype], deckConfigs: [DeckConfig], today: Int, nextDayAt: Int64,
                now: Int64, currentDeckID: DeckID, fsrsDecay: Double = 0.1542) {
        self.decks = decks; self.notetypes = notetypes; self.deckConfigs = deckConfigs
        self.today = today; self.nextDayAt = nextDayAt; self.now = now
        self.currentDeckID = currentDeckID; self.fsrsDecay = fsrsDecay
    }
}

/// Cláusula WHERE (sobre `cards c JOIN notes n ON n.id = c.nid`) e seus argumentos.
public struct SearchSQL: Sendable {
    public var whereClause: String
    public var arguments: [DatabaseValue]
}

public struct SearchSQLWriter {
    let context: SearchContext
    var arguments: [DatabaseValue] = []

    public init(context: SearchContext) { self.context = context }

    public static func build(_ node: SearchNode, context: SearchContext) throws -> SearchSQL {
        var writer = SearchSQLWriter(context: context)
        let clause = try writer.write(node)
        return SearchSQL(whereClause: clause, arguments: writer.arguments)
    }

    // MARK: Nós

    mutating func write(_ node: SearchNode) throws -> String {
        switch node {
        case .all:
            return "1"
        case .and(let nodes):
            return "(" + (try nodes.map { try write($0) }).joined(separator: " AND ") + ")"
        case .or(let nodes):
            return "(" + (try nodes.map { try write($0) }).joined(separator: " OR ") + ")"
        case .not(let inner):
            return "NOT (" + (try write(inner)) + ")"
        case .text(let text):
            return plainText(text)
        case .keyed(let key, let value):
            return try keyed(key, value)
        }
    }

    mutating func bind(_ value: some DatabaseValueConvertible) -> String {
        arguments.append(value.databaseValue)
        return "?"
    }

    // MARK: Curingas

    /// Converte curingas da busca (`*`, `_`, com escape `\`) em um padrão LIKE.
    static func likePattern(_ text: String) -> String {
        var out = ""
        var escaped = false
        for ch in text {
            if escaped {
                switch ch {
                case "%", "_", "\\": out += "\\" + String(ch)
                default: out.append(ch)
                }
                escaped = false
                continue
            }
            switch ch {
            case "\\": escaped = true
            case "*": out += "%"
            case "%": out += "\\%"
            default: out.append(ch)
            }
        }
        if escaped { out += "\\\\" }
        return out
    }

    /// Converte curingas em uma expressão regular ancorada (para comparar nomes em Swift).
    static func wildcardRegex(_ text: String) -> NSRegularExpression? {
        var pattern = "^"
        var escaped = false
        for ch in text {
            if escaped {
                pattern += NSRegularExpression.escapedPattern(for: String(ch))
                escaped = false
                continue
            }
            switch ch {
            case "\\": escaped = true
            case "*": pattern += ".*"
            case "_": pattern += "."
            default: pattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        pattern += "$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    static func matches(_ regex: NSRegularExpression?, _ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func idList(_ ids: [Int64]) -> String {
        ids.isEmpty ? "NULL" : ids.map(String.init).joined(separator: ",")
    }

    // MARK: Termos

    mutating func plainText(_ text: String) -> String {
        if text.isEmpty { return "1" }
        let pattern = "%" + SearchSQLWriter.likePattern(text) + "%"
        let a = bind(pattern)
        let b = bind(pattern)
        return "(n.sfld LIKE \(a) ESCAPE '\\' OR n.flds LIKE \(b) ESCAPE '\\')"
    }

    mutating func keyed(_ rawKey: String, _ value: String) throws -> String {
        let key = rawKey.lowercased()
        switch key {
        case "deck": return deck(value)
        case "did": return try intList("c.did", value, alsoColumn: "c.odid")
        case "nid": return try intList("c.nid", value)
        case "cid": return try intList("c.id", value)
        case "mid": return try intList("n.mid", value)
        case "tag": return tag(value)
        case "note": return notetype(value)
        case "card": return template(value)
        case "is": return try state(value)
        case "flag":
            guard let flag = Int(value), (0...7).contains(flag) else { throw SearchError.invalidTerm("flag:\(value)") }
            return "(c.flags & 7) = \(flag)"
        case "prop": return try property(value)
        case "rated": return try rated(value)
        case "added":
            let cutoff = try cutoffMillis(value, term: "added")
            return "c.id > \(cutoff)"
        case "edited":
            let cutoff = try cutoffMillis(value, term: "edited") / 1000
            return "n.mod > \(cutoff)"
        case "introduced":
            let cutoff = try cutoffMillis(value, term: "introduced")
            return "c.id IN (SELECT cid FROM revlog WHERE ease > 0 GROUP BY cid HAVING min(id) > \(cutoff))"
        case "resched":
            let cutoff = try cutoffMillis(value, term: "resched")
            return "c.id IN (SELECT cid FROM revlog WHERE type = 4 AND id > \(cutoff))"
        case "re":
            let placeholder = bind(value)
            return "n.flds REGEXP \(placeholder)"
        case "nc":
            let pattern = "%" + SearchSQLWriter.likePattern(HTMLText.withoutCombining(value)) + "%"
            let placeholder = bind(pattern)
            return "nocomb(n.flds) LIKE \(placeholder) ESCAPE '\\'"
        case "w":
            let inner = NSRegularExpression.escapedPattern(for: value)
                .replacingOccurrences(of: "\\*", with: "\\w*")
                .replacingOccurrences(of: "_", with: "\\w")
            let placeholder = bind("\\b" + inner + "\\b")
            return "n.flds REGEXP \(placeholder)"
        case "preset":
            let regex = SearchSQLWriter.wildcardRegex(value)
            let configIDs = Set(context.deckConfigs.filter { SearchSQLWriter.matches(regex, $0.name) }.map(\.id))
            let deckIDs = context.decks.filter { $0.configID.map(configIDs.contains) ?? false }.map(\.id)
            return "(CASE WHEN c.odid != 0 THEN c.odid ELSE c.did END) IN (\(SearchSQLWriter.idList(deckIDs)))"
        case "has-cd":
            return "c.data != ''"
        default:
            return field(name: rawKey, value: value)
        }
    }

    mutating func intList(_ column: String, _ value: String, alsoColumn: String? = nil) throws -> String {
        let ids = value.split(separator: ",").map { Int64($0.trimmingCharacters(in: .whitespaces)) }
        guard !ids.isEmpty, ids.allSatisfy({ $0 != nil }) else { throw SearchError.invalidTerm("\(column):\(value)") }
        let list = SearchSQLWriter.idList(ids.compactMap { $0 })
        if let alsoColumn { return "(\(column) IN (\(list)) OR \(alsoColumn) IN (\(list)))" }
        return "\(column) IN (\(list))"
    }

    func deck(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "filtered" {
            return "c.odid != 0"
        }
        var ids: [Int64] = []
        if lower == "current" {
            if let current = context.decks.first(where: { $0.id == context.currentDeckID }) {
                ids = context.decks.filter { $0.id == current.id || $0.isDescendant(ofName: current.name) }.map(\.id)
            }
        } else {
            let regex = SearchSQLWriter.wildcardRegex(Deck.normalizedName(value))
            let matched = context.decks.filter { SearchSQLWriter.matches(regex, $0.name) }
            var set = Set<Int64>()
            for deck in matched {
                set.insert(deck.id)
                for child in context.decks where child.isDescendant(ofName: deck.name) { set.insert(child.id) }
            }
            ids = Array(set).sorted()
        }
        let list = SearchSQLWriter.idList(ids)
        return "(c.did IN (\(list)) OR c.odid IN (\(list)))"
    }

    mutating func tag(_ value: String) -> String {
        if value.lowercased() == "none" { return "n.tags = ''" }
        if value == "*" || value == "_*" { return "n.tags != ''" }
        let pattern = SearchSQLWriter.likePattern(value)
        let exact = bind("% " + pattern + " %")
        let child = bind("% " + pattern + "::%")
        return "(n.tags LIKE \(exact) ESCAPE '\\' OR n.tags LIKE \(child) ESCAPE '\\')"
    }

    func notetype(_ value: String) -> String {
        let regex = SearchSQLWriter.wildcardRegex(value)
        let ids = context.notetypes.filter { SearchSQLWriter.matches(regex, $0.name) }.map(\.id)
        return "n.mid IN (\(SearchSQLWriter.idList(ids)))"
    }

    func template(_ value: String) -> String {
        if let number = Int(value), number >= 1 {
            return "c.ord = \(number - 1)"
        }
        let regex = SearchSQLWriter.wildcardRegex(value)
        var clauses: [String] = []
        for nt in context.notetypes {
            let ords = nt.templates.filter { SearchSQLWriter.matches(regex, $0.name) }.map(\.ord)
            if ords.isEmpty { continue }
            if nt.isCloze {
                clauses.append("n.mid = \(nt.id)")
            } else {
                clauses.append("(n.mid = \(nt.id) AND c.ord IN (\(ords.map(String.init).joined(separator: ","))))")
            }
        }
        return clauses.isEmpty ? "0" : "(" + clauses.joined(separator: " OR ") + ")"
    }

    func state(_ value: String) throws -> String {
        switch value.lowercased() {
        case "new": return "c.type = 0"
        case "learn": return "c.type IN (1, 3)"
        case "review": return "c.type IN (2, 3)"
        case "due":
            return "((c.queue IN (2, 3) AND c.due <= \(context.today)) OR (c.queue = 1 AND c.due <= \(context.nextDayAt)))"
        case "suspended": return "c.queue = -1"
        case "buried": return "c.queue IN (-2, -3)"
        case "buried-manually": return "c.queue = -3"
        case "buried-sibling": return "c.queue = -2"
        default: throw SearchError.invalidTerm("is:\(value)")
        }
    }

    mutating func property(_ value: String) throws -> String {
        let operators = ["<=", ">=", "!=", "=", "<", ">"]
        var name = ""
        var op = ""
        var operand = ""
        for candidate in operators {
            if let range = value.range(of: candidate) {
                // Escolhe o operador que aparece primeiro; em empate, o mais longo (a lista já está nessa ordem).
                if op.isEmpty || range.lowerBound < value.range(of: op)!.lowerBound {
                    name = String(value[value.startIndex..<range.lowerBound]).lowercased()
                    op = candidate
                    operand = String(value[range.upperBound...])
                }
            }
        }
        guard !op.isEmpty, let number = Double(operand.replacingOccurrences(of: ",", with: ".")) else {
            throw SearchError.invalidTerm("prop:\(value)")
        }
        let realDue = "(CASE WHEN c.odid != 0 AND c.odue != 0 THEN c.odue ELSE c.due END)"
        switch name {
        case "ivl": return "c.ivl \(op) \(Int(number))"
        case "lapses": return "c.lapses \(op) \(Int(number))"
        case "reps": return "c.reps \(op) \(Int(number))"
        case "ease": return "(c.type IN (2, 3) AND c.factor \(op) \(Int((number * 1000).rounded())))"
        case "due":
            return "(c.queue IN (2, 3, -1, -2, -3) AND c.type = 2 AND \(realDue) \(op) \(context.today + Int(number)))"
        case "pos": return "(c.type = 0 AND \(realDue) \(op) \(Int(number)))"
        case "s": return "json_extract(NULLIF(c.data, ''), '$.s') \(op) \(number)"
        case "d":
            // Aceita tanto a escala 1–10 quanto 0–1 (como o Anki mostra).
            let scaled = number <= 1.0 ? number * 9.0 + 1.0 : number
            return "json_extract(NULLIF(c.data, ''), '$.d') \(op) \(scaled)"
        case "r":
            return "(c.type = 2 AND fsrs_r(json_extract(NULLIF(c.data, ''), '$.s'), max(0, \(context.today) - (\(realDue) - c.ivl)), \(context.fsrsDecay)) \(op) \(number))"
        default:
            throw SearchError.invalidTerm("prop:\(value)")
        }
    }

    func cutoffMillis(_ value: String, term: String) throws -> Int64 {
        guard let days = Int(value), days >= 1 else { throw SearchError.invalidTerm("\(term):\(value)") }
        return (context.nextDayAt - Int64(min(days, 36_500)) * 86_400) * 1000
    }

    func rated(_ value: String) throws -> String {
        let parts = value.split(separator: ":").map(String.init)
        guard let first = parts.first, let days = Int(first), days >= 1 else { throw SearchError.invalidTerm("rated:\(value)") }
        let cutoff = (context.nextDayAt - Int64(min(days, 365)) * 86_400) * 1000
        var clause = "c.id IN (SELECT cid FROM revlog WHERE id > \(cutoff) AND ease"
        if parts.count > 1 {
            guard let ease = Int(parts[1]), (1...4).contains(ease) else { throw SearchError.invalidTerm("rated:\(value)") }
            clause += " = \(ease))"
        } else {
            clause += " > 0)"
        }
        return clause
    }

    mutating func field(name: String, value: String) -> String {
        let nameRegex = SearchSQLWriter.wildcardRegex(name)
        var targets: [(mid: Int64, index: Int)] = []
        for nt in context.notetypes {
            for (index, field) in nt.fields.enumerated() where SearchSQLWriter.matches(nameRegex, field.name) {
                targets.append((nt.id, index))
            }
        }
        if targets.isEmpty { return "0" }

        let isRegex = value.lowercased().hasPrefix("re:")
        var clauses: [String] = []
        for target in targets {
            let column = "field_at(n.flds, \(target.index))"
            let condition: String
            if isRegex {
                let placeholder = bind(String(value.dropFirst(3)))
                condition = "\(column) REGEXP \(placeholder)"
            } else if value.isEmpty {
                condition = "\(column) = ''"
            } else {
                let placeholder = bind(SearchSQLWriter.likePattern(value))
                condition = "\(column) LIKE \(placeholder) ESCAPE '\\'"
            }
            clauses.append("(n.mid = \(target.mid) AND \(condition))")
        }
        return "(" + clauses.joined(separator: " OR ") + ")"
    }
}

// MARK: - Ordenação e execução

public enum SearchSortColumn: String, Sendable, CaseIterable, Codable {
    case none, sortField, created, noteModified, cardModified, due, interval, ease, lapses, reps
    case deck, notetype, template, tags, stability, difficulty
}

public struct SearchSort: Sendable, Equatable, Codable {
    public var column: SearchSortColumn
    public var ascending: Bool
    public init(column: SearchSortColumn = .sortField, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

extension Txn {

    public func searchContext() throws -> SearchContext {
        let timing = try self.timing()
        let configs = try allDeckConfigs()
        let params = configs.first(where: { $0.id == 1 })?.config.fsrsParams ?? []
        let decay = params.count == 21 ? params[20] : (params.count == 19 || params.count == 17 ? 0.5 : 0.1542)
        return SearchContext(decks: try allDecks(), notetypes: try allNotetypes(), deckConfigs: configs,
                             today: timing.today, nextDayAt: timing.nextDayAt, now: timing.now,
                             currentDeckID: try currentDeckID(), fsrsDecay: decay)
    }

    private func orderClause(_ sort: SearchSort, context: SearchContext) -> String {
        let direction = sort.ascending ? "ASC" : "DESC"
        func caseList(_ column: String, _ pairs: [(Int64, String)]) -> String {
            // Ordena por nome usando a posição do nome na lista ordenada.
            let sorted = pairs.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            if sorted.isEmpty { return column }
            let whens = sorted.enumerated().map { "WHEN \($0.element.0) THEN \($0.offset)" }.joined(separator: " ")
            return "(CASE \(column) \(whens) ELSE \(sorted.count) END)"
        }
        switch sort.column {
        case .none: return ""
        case .sortField: return "ORDER BY n.sfld COLLATE NOCASE \(direction), c.ord"
        case .created: return "ORDER BY n.id \(direction), c.ord"
        case .noteModified: return "ORDER BY n.mod \(direction), c.ord"
        case .cardModified: return "ORDER BY c.mod \(direction)"
        case .due: return "ORDER BY c.type \(direction), c.due \(direction)"
        case .interval: return "ORDER BY c.ivl \(direction)"
        case .ease: return "ORDER BY (c.type = 0) ASC, c.factor \(direction)"
        case .lapses: return "ORDER BY c.lapses \(direction)"
        case .reps: return "ORDER BY c.reps \(direction)"
        case .deck: return "ORDER BY \(caseList("c.did", context.decks.map { ($0.id, $0.name) })) \(direction), n.sfld COLLATE NOCASE"
        case .notetype: return "ORDER BY \(caseList("n.mid", context.notetypes.map { ($0.id, $0.name) })) \(direction), n.sfld COLLATE NOCASE"
        case .template: return "ORDER BY c.ord \(direction), n.sfld COLLATE NOCASE"
        case .tags: return "ORDER BY n.tags COLLATE NOCASE \(direction)"
        case .stability: return "ORDER BY json_extract(NULLIF(c.data, ''), '$.s') \(direction)"
        case .difficulty: return "ORDER BY json_extract(NULLIF(c.data, ''), '$.d') \(direction)"
        }
    }

    /// Ids dos cards que casam com a busca.
    public func searchCards(_ query: String, sort: SearchSort = SearchSort(column: .none)) throws -> [CardID] {
        let context = try searchContext()
        let sql = try SearchSQLWriter.build(try SearchParser.parse(query), context: context)
        return try Int64.fetchAll(db, sql: """
            SELECT c.id FROM cards c JOIN notes n ON n.id = c.nid
            WHERE \(sql.whereClause) \(orderClause(sort, context: context))
            """, arguments: StatementArguments(sql.arguments))
    }

    /// Ids das notas com ao menos um card que casa com a busca.
    public func searchNotes(_ query: String, sort: SearchSort = SearchSort(column: .none)) throws -> [NoteID] {
        let context = try searchContext()
        let sql = try SearchSQLWriter.build(try SearchParser.parse(query), context: context)
        var seen = Set<NoteID>()
        var result: [NoteID] = []
        let ids = try Int64.fetchAll(db, sql: """
            SELECT c.nid FROM cards c JOIN notes n ON n.id = c.nid
            WHERE \(sql.whereClause) \(orderClause(sort, context: context))
            """, arguments: StatementArguments(sql.arguments))
        for id in ids where seen.insert(id).inserted { result.append(id) }
        return result
    }

    /// Cláusula WHERE pronta para ser embutida em outras consultas (estatísticas, baralhos filtrados).
    public func searchSQL(_ query: String) throws -> SearchSQL {
        try SearchSQLWriter.build(try SearchParser.parse(query), context: try searchContext())
    }
}
