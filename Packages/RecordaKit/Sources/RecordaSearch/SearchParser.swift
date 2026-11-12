import Foundation

public enum SearchError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case unbalancedParenthesis
    case unterminatedQuote
    case missingOperand(String)
    case invalidTerm(String)

    public var description: String {
        switch self {
        case .unbalancedParenthesis: return "Parênteses não balanceados na busca."
        case .unterminatedQuote: return "Faltou fechar as aspas na busca."
        case .missingOperand(let op): return "“\(op)” precisa de um termo antes e depois."
        case .invalidTerm(let term): return "Termo de busca inválido: \(term)"
        }
    }

    public var errorDescription: String? { description }
}

public indirect enum SearchNode: Equatable, Sendable {
    case all
    case and([SearchNode])
    case or([SearchNode])
    case not(SearchNode)
    /// Texto livre (sem prefixo reconhecido).
    case text(String)
    /// `prefixo:valor`.
    case keyed(key: String, value: String)
}

/// Analisador da sintaxe de busca: termos separados por espaço (E implícito), `or`, `-` para negar,
/// parênteses, aspas e prefixos `chave:valor`.
public enum SearchParser {

    enum Token: Equatable {
        case open, close, or, and, not
        case term(String, quoted: Bool)
    }

    static func tokenize(_ input: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0

        /// Lê até a aspa de fechamento, tratando `\"`.
        func readQuoted() throws -> String {
            var out = ""
            while i < chars.count {
                let ch = chars[i]
                if ch == "\\" && i + 1 < chars.count && chars[i + 1] == "\"" {
                    out.append("\"")
                    i += 2
                    continue
                }
                if ch == "\"" {
                    i += 1
                    return out
                }
                out.append(ch)
                i += 1
            }
            throw SearchError.unterminatedQuote
        }

        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace {
                i += 1
            } else if ch == "(" {
                tokens.append(.open)
                i += 1
            } else if ch == ")" {
                tokens.append(.close)
                i += 1
            } else if ch == "-" && i + 1 < chars.count && !chars[i + 1].isWhitespace {
                tokens.append(.not)
                i += 1
            } else if ch == "\"" {
                i += 1
                tokens.append(.term(try readQuoted(), quoted: true))
            } else {
                var word = ""
                var hadQuote = false
                while i < chars.count {
                    let c = chars[i]
                    if c.isWhitespace || c == "(" || c == ")" { break }
                    if c == "\"" {
                        // prefixo:"valor com espaços"
                        i += 1
                        word += try readQuoted()
                        hadQuote = true
                        continue
                    }
                    if c == "\\" && i + 1 < chars.count && (chars[i + 1] == "(" || chars[i + 1] == ")" || chars[i + 1] == "\"" || chars[i + 1] == "-") {
                        word.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    word.append(c)
                    i += 1
                }
                let lower = word.lowercased()
                if !hadQuote && lower == "or" {
                    tokens.append(.or)
                } else if !hadQuote && lower == "and" {
                    tokens.append(.and)
                } else {
                    tokens.append(.term(word, quoted: false))
                }
            }
        }
        return tokens
    }

    public static func parse(_ input: String) throws -> SearchNode {
        let tokens = try tokenize(input)
        if tokens.isEmpty { return .all }
        var index = 0
        let node = try parseOr(tokens, &index)
        if index < tokens.count { throw SearchError.unbalancedParenthesis }
        return node
    }

    private static func parseOr(_ tokens: [Token], _ index: inout Int) throws -> SearchNode {
        var branches = [try parseAnd(tokens, &index)]
        while index < tokens.count, tokens[index] == .or {
            index += 1
            guard index < tokens.count, tokens[index] != .close else { throw SearchError.missingOperand("or") }
            branches.append(try parseAnd(tokens, &index))
        }
        return branches.count == 1 ? branches[0] : .or(branches)
    }

    private static func parseAnd(_ tokens: [Token], _ index: inout Int) throws -> SearchNode {
        var parts: [SearchNode] = []
        while index < tokens.count {
            switch tokens[index] {
            case .or, .close:
                guard !parts.isEmpty else {
                    throw tokens[index] == .or ? SearchError.missingOperand("or") : SearchError.unbalancedParenthesis
                }
                return parts.count == 1 ? parts[0] : .and(parts)
            case .and:
                guard !parts.isEmpty else { throw SearchError.missingOperand("and") }
                index += 1
                guard index < tokens.count else { throw SearchError.missingOperand("and") }
            default:
                parts.append(try parseUnary(tokens, &index))
            }
        }
        guard !parts.isEmpty else { throw SearchError.missingOperand("and") }
        return parts.count == 1 ? parts[0] : .and(parts)
    }

    private static func parseUnary(_ tokens: [Token], _ index: inout Int) throws -> SearchNode {
        guard index < tokens.count else { throw SearchError.missingOperand("-") }
        switch tokens[index] {
        case .not:
            index += 1
            return .not(try parseUnary(tokens, &index))
        case .open:
            index += 1
            if index < tokens.count, tokens[index] == .close {
                index += 1
                return .all
            }
            let inner = try parseOr(tokens, &index)
            guard index < tokens.count, tokens[index] == .close else { throw SearchError.unbalancedParenthesis }
            index += 1
            return inner
        case .term(let text, let quoted):
            index += 1
            return termNode(text, quoted: quoted)
        case .close:
            throw SearchError.unbalancedParenthesis
        case .or:
            throw SearchError.missingOperand("or")
        case .and:
            throw SearchError.missingOperand("and")
        }
    }

    static func termNode(_ text: String, quoted: Bool) -> SearchNode {
        if text == "*" && !quoted { return .all }
        // Uma chave válida vem antes do primeiro ":" e não contém espaços. "\:" escapa os dois-pontos.
        var key = ""
        var index = text.startIndex
        var found = false
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == ":" {
                    // Dois-pontos literal: não há chave.
                    return .text(text.replacingOccurrences(of: "\\:", with: ":"))
                }
            }
            if ch == ":" {
                found = true
                break
            }
            key.append(ch)
            index = text.index(after: index)
        }
        guard found, !key.isEmpty else { return .text(text) }
        let value = String(text[text.index(after: index)...])
        return .keyed(key: key, value: value)
    }
}
